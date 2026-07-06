#!/bin/bash
# 
# CXL RAS Error Injection - Direct Raw CCI Mailbox Injection
# 
# Description:
#   Sends CCI opcodes directly to the CXL device via the CXL_MEM_SEND_COMMAND
#   ioctl with CXL_MEM_COMMAND_ID_RAW, bypassing all kernel driver wrappers.
#   Injects poison (opcode 0x4301) at a target DPA, then immediately clears
#   it (opcode 0x4302).
#

set -e

DEVICE="/dev/cxl/mem1"
RAW_ALLOW="/sys/kernel/debug/cxl/mbox/raw_allow_all"
WORKDIR="$(mktemp -d)"
SRC="$WORKDIR/cxl_raw_poison.c"
BIN="$WORKDIR/cxl_raw_poison"

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

if [ "$EUID" -ne 0 ]; then
    echo "[-] Error: Please run this script as root."
    exit 1
fi

if ! command -v gcc >/dev/null 2>&1; then
    echo "[-] Error: gcc not found. Install a compiler (e.g. apt install gcc)."
    exit 1
fi

if [ ! -e "$DEVICE" ]; then
    echo "[-] Error: $DEVICE not found. Is the CXL device attached/named mem1?"
    exit 1
fi

echo "[+] Step 1: Enabling raw CCI mailbox commands"
if [ -f "$RAW_ALLOW" ]; then
    echo Y > "$RAW_ALLOW"
else
    echo "[-] Warning: $RAW_ALLOW not present; continuing, ioctl may be rejected."
fi

echo "[+] Step 2: Writing and compiling raw CCI mailbox injector"
cat > "$SRC" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdint.h>
#include <sys/ioctl.h>

#define CXL_MEM_SEND_COMMAND _IOWR(0xCE, 2, struct cxl_send_command)
#define CXL_MEM_COMMAND_ID_RAW 2

#define CXL_MBOX_OP_INJECT_POISON 0x4301
#define CXL_MBOX_OP_CLEAR_POISON  0x4302

struct cxl_send_command {
    uint32_t id; uint32_t flags;
    union { struct { uint16_t opcode; uint16_t rsvd; } raw; uint32_t rsvd; };
    uint32_t retval;
    struct { uint32_t size; uint32_t rsvd; uint64_t payload; } in;
    struct { uint32_t size; uint32_t rsvd; uint64_t payload; } out;
};

int send_raw(int fd, uint16_t opcode, void *in_buf, uint32_t in_size) {
    struct cxl_send_command cmd = {0};
    cmd.id = CXL_MEM_COMMAND_ID_RAW; cmd.raw.opcode = opcode;
    if (in_buf) { cmd.in.size = in_size; cmd.in.payload = (uint64_t)(uintptr_t)in_buf; }
    int ret = ioctl(fd, CXL_MEM_SEND_COMMAND, &cmd);
    if (ret < 0) { perror("ioctl"); return -1; }
    printf("  retval: 0x%x %s\n", cmd.retval,
           cmd.retval == 0 ? "(SUCCESS)" : "(ERROR)");
    return cmd.retval;
}

int main() {
    int fd = open("/dev/cxl/mem1", O_RDWR);
    if (fd < 0) { perror("/dev/cxl/mem1"); return 1; }
    printf("=== CXL Raw CCI Poison via opcode 0x4301 ===\n\n");

    uint64_t *dpa = calloc(1, sizeof(uint64_t));
    if (!dpa) { perror("calloc"); close(fd); return 1; }
    *dpa = 0x50000;

    printf("[*] INJECT_POISON (0x4301) at DPA 0x%lx:\n", *dpa);
    int ret = send_raw(fd, CXL_MBOX_OP_INJECT_POISON, dpa, sizeof(*dpa));
    if (ret == 0) {
        printf("[+] Poison injected via raw CCI mailbox!\n\n");
        uint8_t clear_pl[72] = {0};
        memcpy(clear_pl, dpa, 8);
        printf("[*] CLEAR_POISON (0x4302) at DPA 0x%lx:\n", *dpa);
        send_raw(fd, CXL_MBOX_OP_CLEAR_POISON, clear_pl, sizeof(clear_pl));
    }
    free(dpa);
    close(fd);
    return 0;
}
EOF

gcc -O2 -o "$BIN" "$SRC"

echo "[+] Step 3: Running raw CCI mailbox injector against $DEVICE"
"$BIN"

echo "[+] Done."