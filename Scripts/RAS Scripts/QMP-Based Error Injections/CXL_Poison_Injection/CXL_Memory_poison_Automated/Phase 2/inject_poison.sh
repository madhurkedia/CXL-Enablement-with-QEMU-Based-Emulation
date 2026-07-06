#!/bin/bash

set -e

QMP_SOCKET_PATH="/tmp/qmp-sock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POISON_SCRIPT="$SCRIPT_DIR/poison_attack.py"

#  Colour helpers 
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

log_info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

#  Pre-flight checks 


log_info "Checking for Python3"
if ! command -v python3 &>/dev/null; then
    log_error "python3 not found. Please install it and retry."
    exit 1
fi
log_success "Python3 found: $(python3 --version)"

log_info "Checking QMP socket at $QMP_SOCKET_PATH"
if [ ! -S "$QMP_SOCKET_PATH" ]; then
    log_error "QMP socket not found at $QMP_SOCKET_PATH"
    log_warn  "Make sure QEMU is running with: -qmp unix:$QMP_SOCKET_PATH,server=on,wait=off"
    exit 1
fi
log_success "QMP socket found."

#  Write the Python injection payload 
log_info "Writing poison_attack.py"

cat > "$POISON_SCRIPT" << 'PYEOF'
import socket
import json
import time
import sys

QMP_SOCKET_PATH = "/tmp/qmp-sock"

def inject_cxl_poison():
    print("  --> Initiating OS-First Self-Recovery Validation")
    time.sleep(0.5)
    print("  --> Firing Tier 2 Data Poisoning Strike (DPA: 0x1000, Length: 64 bytes)")
    time.sleep(0.5)

    payload = {
        "execute": "cxl-inject-poison",
        "arguments": {
            "path": "/machine/peripheral/cxl-mem1",
            "start": 4096,   # DPA 0x1000
            "length": 64     # One cacheline (0x40)
        }
    }

    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(QMP_SOCKET_PATH)

        # Read QMP greeting banner
        greeting = client.recv(4096)
        print(f"  [QMP Greeting received: {len(greeting)} bytes]")

        # Negotiate capabilities
        caps = {"execute": "qmp_capabilities"}
        client.sendall((json.dumps(caps) + '\n').encode('utf-8'))
        client.recv(4096)
        print("  [QMP capabilities negotiated]")

        # Send poison command
        client.sendall((json.dumps(payload) + '\n').encode('utf-8'))
        response_bytes = client.recv(4096)
        response_str = response_bytes.decode('utf-8').strip()

        print("\n  Hardware Emulation Response:")
        print("  " + response_str)

        if '"return": {}' in response_str:
            print("\n  [SUCCESS] Poison injected at DPA 0x1000 (64-byte cacheline).")
        else:
            print("\n  [WARNING] Unexpected response — check QOM path or device config.")

        client.close()

    except FileNotFoundError:
        print(f"\n[ERROR] QMP socket not found at {QMP_SOCKET_PATH}")
        print("Ensure QEMU is running with: -qmp unix:/tmp/qmp-sock,server=on,wait=off")
        sys.exit(1)
    except Exception as e:
        print(f"\n[ERROR] Unexpected error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    inject_cxl_poison()
PYEOF

log_success "poison_attack.py written to $POISON_SCRIPT"

#  Execute 
echo ""
log_info "Executing poison injection..."
python3 "$POISON_SCRIPT"
log_success "Injection phase complete."
log_info  "Now run detect_recover.sh INSIDE the Guest VM to detect and recover."
echo ""
