#!/usr/bin/env python3
import socket, json, sys

QMP_HOST = "127.0.0.1"
QMP_PORT = 4444

DEVICES = {
    "cxl0": "/machine/peripheral/cxl0",
    "cxl1": "/machine/peripheral/cxl1",
}

def recv_line(s, buf):
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            raise ConnectionError("QMP connection closed")
        buf += chunk
    raw, buf = buf.split(b"\n", 1)
    return json.loads(raw.decode()), buf

def send(s, obj):
    s.sendall((json.dumps(obj) + "\n").encode())

def main():
    device_name = sys.argv[1] if len(sys.argv) > 1 else "cxl1"
    dpa_arg     = sys.argv[2] if len(sys.argv) > 2 else "0x1000"

    if device_name not in DEVICES:
        print(f"Error: unknown device '{device_name}'. Choose from: {', '.join(DEVICES)}")
        sys.exit(1)

    try:
        dpa = int(dpa_arg, 0)
    except ValueError:
        print(f"Error: invalid DPA '{dpa_arg}'")
        sys.exit(1)

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.connect((QMP_HOST, QMP_PORT))
    except ConnectionRefusedError:
        print(f"Error: cannot connect to QMP at {QMP_HOST}:{QMP_PORT}")
        sys.exit(1)

    buf = b""
    greeting, buf = recv_line(s, buf)
    ver = greeting["QMP"]["version"]["qemu"]
    print(f"QEMU {ver['major']}.{ver['minor']}.{ver['micro']}")
    send(s, {"execute": "qmp_capabilities"})
    _, buf = recv_line(s, buf)

    send(s, {
        "execute": "cxl-inject-general-media-event",
        "arguments": {
            "path":             DEVICES[device_name],
            "log":              "warning",
            "flags":            1,
            "dpa":              dpa,
            "descriptor":       0,
            "type":             2,
            "transaction-type": 0,
            "channel":          0,
            "rank":             0,
            "device":           0,
            "component-id":     "00000000-0000-0000-0000-000000000000"
        }
    })

    resp, _ = recv_line(s, buf)
    s.close()

    if "return" in resp:
        print(f"SUCCESS: general media event injected on {device_name} dpa={hex(dpa)}")
        print("Guest: cat /sys/kernel/debug/tracing/trace | grep cxl_general_media")
    else:
        print(f"FAILED: {resp.get('error', {}).get('desc', 'unknown')}")
        sys.exit(1)

if __name__ == "__main__":
    main()
