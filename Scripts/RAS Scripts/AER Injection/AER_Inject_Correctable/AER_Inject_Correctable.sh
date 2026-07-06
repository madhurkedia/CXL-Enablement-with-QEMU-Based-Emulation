#!/bin/bash
# 
# Correctable PCIe AER Injection (guest-side)
#
# Description:
#   Runs entirely inside the guest. Writes an aer_error_inj struct to
#   /dev/aer_inject to inject a correctable PCIe AER error (BadDLLP,
#   PCI_ERR_COR_BAD_DLLP = 0x0080) on the target PCI device, exercising the
#   guest kernel's own AER module rather than QEMU's host-side QMP interface.
#

set -e

WORKDIR="$(mktemp -d)"
SRC="$WORKDIR/aer_inject_write.c"
BIN="$WORKDIR/aer_inject_write"

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

echo "[+] Step 1: Ensuring aer-inject kernel module is loaded..."
if ! lsmod | grep -q '^aer_inject'; then
    modprobe aer-inject || {
        echo "[-] Error: could not load aer-inject module."
        exit 1
    }
fi

if [ ! -e /dev/aer_inject ]; then
    echo "[-] Error: /dev/aer_inject not found even after modprobe."
    exit 1
fi

echo "[+] Step 2: Writing and compiling correctable AER injector."
cat > "$SRC" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdint.h>

struct aer_error_inj {
    uint8_t  bus; uint8_t dev; uint8_t fn;
    uint32_t uncor_status; uint32_t cor_status;
    uint32_t header_log0; uint32_t header_log1;
    uint32_t header_log2; uint32_t header_log3;
    uint32_t domain;
};

#define PCI_ERR_COR_BAD_DLLP 0x0080

int main() {
    int fd = open("/dev/aer_inject", O_WRONLY);
    if (fd < 0) { perror("open /dev/aer_inject"); return 1; }
    struct aer_error_inj einj;
    memset(&einj, 0, sizeof(einj));
    einj.bus = 0x0e; einj.dev = 0x00; einj.fn = 0x00;
    einj.cor_status = PCI_ERR_COR_BAD_DLLP; einj.domain = 0;
    printf("[*] Injecting correctable AER on 0000:0e:00.0\n");
    ssize_t ret = write(fd, &einj, sizeof(einj));
    if (ret < 0) perror("write");
    else printf("[*] Done. Bytes written: %zd\n", ret);
    close(fd);
    return ret < 0 ? 1 : 0;
}
EOF

gcc -O2 -o "$BIN" "$SRC"

echo "[+] Step 3: Running correctable AER injector"
"$BIN"

echo "[+] Step 4: Check kernel log for the correctable AER report:"
echo "    dmesg | grep -i aer"

echo "[+] Done."
