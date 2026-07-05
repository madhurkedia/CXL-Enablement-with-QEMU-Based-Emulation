#!/bin/bash
# 
# Uncorrectable Fatal AER (guest-side)
#
# Description:
#   Forks a child process that mmaps /dev/dax0.0 and continuously reads a
#   known pattern from CXL memory. After 5 seconds, the parent injects an
#   uncorrectable FATAL PCIe AER error (PCI_ERR_UNC_DLP, Data Link Protocol
#   Error) via /dev/aer_inject on the target device. After 5 more seconds the
#   child is stopped and results are reported.
#
#   WARNING: this deliberately takes the target CXL device offline for the
#   rest of the session, matching what a fatal AER does on real hardware. A
#   VM/host restart is expected to be required to recover the device
#   afterward.
# 

set -e

WORKDIR="$(mktemp -d)"
SRC="$WORKDIR/aer_uncorrectable.c"
BIN="$WORKDIR/aer_uncorrectable"

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

DAX_DEV="dax0.0"
DAX_PATH="/dev/$DAX_DEV"
REGION="region0"
DECODER="decoder0.0"
MEMDEV="mem1"

get_dax_mode() {
    daxctl list -d "$DAX_DEV" 2>/dev/null | grep -o '"mode":"[a-z-]*"' | cut -d'"' -f4
}

if ! command -v daxctl >/dev/null 2>&1 || ! command -v cxl >/dev/null 2>&1; then
    echo "[-] Error: daxctl/cxl tools not found, cannot set up the DAX device."
    exit 1
fi

if [ ! -e "$DAX_PATH" ]; then
    echo "[!] $DAX_PATH not found. No CXL region exists yet on this boot."
    echo "    -> Preventing new memory blocks from auto-onlining as system-ram"
    echo offline > /sys/devices/system/memory/auto_online_blocks 2>/dev/null || true

    echo "    -> Creating region on $MEMDEV via $DECODER..."
    if ! cxl create-region -d "$DECODER" -m "$MEMDEV" -t ram; then
        echo "[-] Error: cxl create-region failed. Check decoder/memdev names with:"
        echo "      cxl list -D   /   cxl list -M"
        exit 1
    fi
    sleep 1
fi

if [ ! -e "$DAX_PATH" ]; then
    echo "[-] Error: $DAX_PATH still not present after creating the region."
    exit 1
fi

DAX_MODE="$(get_dax_mode)"

if [ "$DAX_MODE" != "devdax" ]; then
    echo "[!] $DAX_PATH is in '$DAX_MODE' mode, not 'devdax'. Trying reconfigure..."
    daxctl reconfigure-device --mode=devdax "$DAX_DEV" >/dev/null 2>&1 || true
    DAX_MODE="$(get_dax_mode)"
fi

if [ "$DAX_MODE" != "devdax" ]; then
    echo "[-] Error: $DAX_PATH is stuck in '$DAX_MODE' mode and cannot be safely"
    echo "    switched to devdax without risking a kernel panic."
    echo ""
    echo "    Required fix: power-cycle (hard reset) the VM, then BEFORE running"
    echo "    anything else that touches mem1/region0/dax0.0, run:"
    echo "      echo offline | sudo tee /sys/devices/system/memory/auto_online_blocks"
    echo "    and only then rerun this script."
    exit 1
fi

echo "[+] $DAX_PATH is in devdax mode."

echo "[+] Step 1: Ensuring aer-inject kernel module is loaded"
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

echo "[!] WARNING: this will take the CXL device offline for the rest of the"
echo "    session. A VM restart is expected to be required afterward."
read -r -p "    Continue? [y/N] " CONFIRM
case "$CONFIRM" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 0 ;;
esac

echo "[+] Step 2: Writing and compiling uncorrectable fatal AER injector"
cat > "$SRC" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/wait.h>

#define MAP_SIZE (2 * 1024 * 1024UL)

struct aer_error_inj {
    uint8_t  bus;
    uint8_t  dev;
    uint8_t  fn;
    uint32_t uncor_status;
    uint32_t cor_status;
    uint32_t header_log0;
    uint32_t header_log1;
    uint32_t header_log2;
    uint32_t header_log3;
    uint32_t domain;
};

#define PCI_ERR_UNC_DLP 0x00000010

volatile int sigbus_caught = 0;
volatile int keep_running  = 1;

void handle_sigbus(int sig, siginfo_t *info, void *ctx) {
    sigbus_caught++;
    fprintf(stderr, "\n[!] SIGBUS at %p count: %d\n", info->si_addr, sigbus_caught);
}

void run_active_memory() {
    struct sigaction sa = {0};
    sa.sa_sigaction = handle_sigbus; sa.sa_flags = SA_SIGINFO;
    sigaction(SIGBUS, &sa, NULL);
    int fd = open("/dev/dax0.0", O_RDWR);
    if (fd < 0) { perror("open /dev/dax0.0"); exit(1); }
    void *map = mmap(NULL, MAP_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) { perror("mmap"); exit(1); }
    printf("[*] Child PID %d: CXL DAX mapped at %p\n", getpid(), map);
    uint64_t *ptr = (uint64_t *)map;
    for (size_t i = 0; i < 512; i++) ptr[i] = 0xDEADBEEF00000000UL | i;
    printf("[*] Child: pattern written, reading in loop...\n");
    fflush(stdout);
    uint64_t passes = 0;
    while (keep_running) {
        for (size_t i = 0; i < 512; i++) {
            uint64_t val = ptr[i];
            if (val != (0xDEADBEEF00000000UL | i))
                printf("[!] Mismatch at %zu: 0x%lx\n", i, val);
        }
        passes++;
        if (passes % 200 == 0) {
            printf("[.] %lu passes SIGBUS: %d\n", passes, sigbus_caught);
            fflush(stdout);
        }
        usleep(1000);
    }
    munmap(map, MAP_SIZE); close(fd);
    exit(sigbus_caught > 0 ? 2 : 0);
}

void inject_uncorrectable_aer() {
    int fd = open("/dev/aer_inject", O_WRONLY);
    if (fd < 0) { perror("open /dev/aer_inject"); return; }
    struct aer_error_inj einj; memset(&einj, 0, sizeof(einj));
    einj.bus = 0x0e; einj.dev = 0x00; einj.fn = 0x00;
    einj.uncor_status = PCI_ERR_UNC_DLP; einj.domain = 0;
    printf("[*] Injecting UNCORRECTABLE FATAL AER on 0000:0e:00.0\n");
    ssize_t ret = write(fd, &einj, sizeof(einj));
    if (ret < 0) perror("write /dev/aer_inject");
    else printf("[*] Uncorrectable AER injection sent.\n");
    close(fd);
}

int main() {
    printf("   CXL Uncorrectable Fatal AER Experiment   \n\n");
    pid_t child = fork();
    if (child == 0) { run_active_memory(); return 0; }
    printf("[*] Parent: waiting 5s while child reads CXL memory...\n");
    sleep(5);
    printf("\n[*] Parent: injecting UNCORRECTABLE FATAL AER\n");
    inject_uncorrectable_aer();
    printf("[*] Parent: waiting 5s post-injection\n");
    sleep(5);
    keep_running = 0; sleep(1);
    kill(child, SIGTERM);
    int status; waitpid(child, &status, 0);
    printf("\n    Results    \n");
    if (WIFEXITED(status))
        printf("[*] Child exit: %d %s\n", WEXITSTATUS(status),
               WEXITSTATUS(status) == 2 ? "(SIGBUS caught)" : "(no SIGBUS)");
    else if (WIFSIGNALED(status))
        printf("[!] Child killed by signal: %d\n", WTERMSIG(status));
    printf("[*] Check: dmesg | grep -i aer\n");
    return 0;
}
EOF

gcc -O2 -o "$BIN" "$SRC"

echo "[+] Step 3: Running uncorrectable fatal AER experiment"
"$BIN"

echo "[+] Step 4: Verify device state (expected to be offline until restart):"
echo "    cxl list -d mem1"
echo "    dmesg | grep -i aer"

echo "[+] Done."
