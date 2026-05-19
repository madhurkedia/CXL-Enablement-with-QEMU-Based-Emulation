#!/usr/bin/env python3
"""
CXL Memory Poison Injector (Host Side)
Tested: QEMU 9.2.90, CXL Type-3 persistent memory device
Usage: python3 inject_poison.py
Requires: QEMU launched with -qmp unix:/tmp/qmp-sock,server,nowait
"""
import socket, json

# Connect to QEMU's control socket
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect("/tmp/qmp-sock")

# Read greeting
data = sock.recv(4096)
print("QEMU says:", json.loads(data)["QMP"]["version"]["qemu"])

# Handshake
sock.sendall(b'{"execute":"qmp_capabilities"}\n')
sock.recv(4096)  # ack

# THE POISON INJECTION
cmd = {
    "execute": "cxl-inject-poison",
    "arguments": {
        "path": "/machine/peripheral/cxlpmem0",  # CXL device
        "start": 128,                             # address 0x80 
        "length": 64                              # 64 bytes 
    }
}

sock.sendall((json.dumps(cmd) + "\n").encode())
response = json.loads(sock.recv(4096))

if "return" in response:
    print("Poison injected at address 0x80")
else:
    print("Failed:", response["error"]["desc"])

sock.close()
