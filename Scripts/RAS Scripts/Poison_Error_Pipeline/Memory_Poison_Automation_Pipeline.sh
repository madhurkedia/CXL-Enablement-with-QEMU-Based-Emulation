
#  CXL Memory Fault Injection Framework
#
# Description:
#   End-to-end automation pipeline for CXL memory fault injection and
#   RAS (Reliability, Availability, Serviceability) validation.
#
#   This script bootstraps a self-contained Python framework under
#   ~/cxl-fault-injector/ and immediately executes it. The framework:
#
#     1. Environment Checks  – Validates kernel version (requires 6.0+)
#                              and Python 3 availability.
#     2. Device Discovery    – Queries attached CXL memory devices via
#                              `cxl list --memdevs` and builds a topology map.
#     3. Strategy Engine     – Selects target DPA (Device Physical Addresses)
#                              using one of two strategies:
#                                • random_strategy  – one random cache-line
#                                • sweep            – sequential cache-line scan
#     4. Fault Injection     – Poisons selected DPAs via
#                              `cxl inject-media-poison`.
#     5. Detection           – Verifies the poison appears in
#                              `cxl list --media-errors` output.
#     6. Reporting           – Prints a live per-target pass/fail summary.
#
#  Usage:  chmod +x cxl_fault_injector.sh && sudo ./cxl_fault_injector.sh
#          or with options:
#          sudo ./cxl_fault_injector.sh --strategy sweep --limit 5




set -e

# colours
GREEN="\033[92m"; YELLOW="\033[93m"; RED="\033[91m"; CYAN="\033[96m"; BOLD="\033[1m"; RESET="\033[0m"
ok()   { echo -e "  ${GREEN}[ok]${RESET}   $*"; }
warn() { echo -e "  ${YELLOW}[warn]${RESET} $*"; }
fail() { echo -e "  ${RED}[fail]${RESET} $*"; }
info() { echo -e "  [info] $*"; }



# root check 
if [[ $EUID -ne 0 ]]; then
  fail "This script must be run as root."
  echo -e "  Try:  ${YELLOW}sudo $0 $*${RESET}"
  exit 1
fi
ok "Running as root"

# python check 
if command -v python3 &>/dev/null; then
  ok "python3 found: $(python3 --version)"
else
  fail "python3 not found. Install it and retry."
  exit 1
fi

# create project directory 
INSTALL_DIR="$HOME/cxl-fault-injector"
info "Install directory: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"/{utils,discovery,strategy,injection,detection,reporting,logs}

#  write __init__.py files 
for pkg in utils discovery strategy injection detection reporting; do
  touch "$INSTALL_DIR/$pkg/__init__.py"
done

ok "Directory structure created"


# utils/checks.py 
cat > "$INSTALL_DIR/utils/checks.py" << 'PYEOF'
import  platform

GREEN  = "\033[92m"; YELLOW = "\033[93m"; RED = "\033[91m"; CYAN = "\033[96m"; BOLD = "\033[1m"; RESET = "\033[0m"
def ok(msg):   print(f"  {GREEN}[pass]{RESET} {msg}")
def warn(msg): print(f"  {YELLOW}[warn]{RESET} {msg}")
def fail(msg): print(f"  {RED}[fail]{RESET} {msg}")
def info(msg): print(f"  [info] {msg}")


def check_kernel():
    print("\n-- checking kernel version")
    raw = platform.release(); info(f"kernel: {raw}")
    try:
        parts = raw.split("."); major, minor = int(parts[0]), int(parts[1])
    except (IndexError, ValueError):
        warn("could not parse kernel version, continuing anyway"); return "unknown", True
    ver = f"{major}.{minor}"
    if major > 6 or (major == 6 and minor >= 5):
        ok(f"kernel {ver} -- full cxl inject support"); return ver, True
    elif major == 6:
        warn(f"kernel {ver} -- partial support"); return ver, True
    else:
        fail(f"kernel {ver} -- too old, need 6.0+"); return ver, False


def all_checks():
    out = {}
    ver, ok_flag = check_kernel()
    out["kernel_version"] = ver
    if not ok_flag:
        print(f"\n{RED}kernel too old, exiting.{RESET}"); return None
    print(f"\n{CYAN}{BOLD}  checks done{RESET}")
    return out

if __name__ == "__main__":
    all_checks()
PYEOF

# discovery/discover.py 
cat > "$INSTALL_DIR/discovery/discover.py" << 'PYEOF'
import  json, subprocess

from utils.checks import ok, warn, fail, info, CYAN, BOLD, RESET


def list_devices_via_cli():
    print("\n-- querying cxl-cli for memory devices")
    try:
        r = subprocess.run(["cxl", "list", "--memdevs"], capture_output=True, text=True, timeout=10)
        if r.returncode != 0 or not r.stdout.strip():
            warn("cxl-cli returned no devices")
            return []
        data = json.loads(r.stdout.strip())
        if isinstance(data, dict):
            data = [data]
        ok(f"cxl-cli found {len(data)} device(s)")
        return data
    except (FileNotFoundError, json.JSONDecodeError):
        warn("cxl-cli unavailable or returned invalid output")
        return []

def build_topology(cli_devices):
    print("\n-- building topology map")
    devices = []
    total = 0
    for d in cli_devices:
        name = d.get("memdev")
        if not name:
            continue
        
        size = d.get("ram_size", 0)
        devices.append({
            "name": name,
            "dpa_start": "0x0",
            "dpa_end" : hex(size),
            "size_bytes": size,
            "size_gb": round(size/ (1024 ** 3), 2),
        })
        total+=size
    topology = {
        "total_devices": len(devices),
        "total_cxl_memory_gb": round(total/(1024**3),2),
        "devices": devices
    }
    ok(f"topology ready: {len(devices)} device(s), {topology['total_cxl_memory_gb']} GB total")
    return topology

def discovery():
    cli_devices = list_devices_via_cli()
    topo = build_topology(cli_devices)
    print(f"\n{CYAN}{BOLD}  discovery complete{RESET}")
    print(json.dumps(topo, indent=2))
    return topo

if __name__ == "__main__":
    discovery()
PYEOF

# strategy/strategy.py 
cat > "$INSTALL_DIR/strategy/strategy.py" << 'PYEOF'
import random

from utils.checks import ok, warn, fail, info

CACHELINE = 64

def align(addr):
    return (addr // CACHELINE) * CACHELINE



def random_strategy(device):
    info(f"strategy random on {device['name']}")
    start = int(device["dpa_start"], 16)
    end = int(device["dpa_end"], 16)
    pool = []
    addr = align(start + CACHELINE)
    while addr < end and len(pool) < 100_000:
        pool.append(addr)
        addr += CACHELINE
    chosen = random.choice(pool)
    ok(f"selected dpa: {hex(chosen)} on {device['name']}")
    return [{"device": device["name"], "dpa": hex(chosen), "strategy": "random_strategy"}]

def sweep(device, limit=None):
    info(f"strategy sweep on {device['name']}" + (f" (limit {limit})" if limit else ""))
    start = int(device["dpa_start"], 16)
    end = int(device["dpa_end"], 16)
    targets = []
    addr = align(start + CACHELINE)
    while addr < end:
        targets.append({"device": device["name"], "dpa": hex(addr), "strategy": "sweep"})
        addr += CACHELINE
        if limit and len(targets) >= limit:
            break
    ok(f"sweep generated {len(targets)} target(s) on {device['name']}")
    return targets


def strategy(topology, strategy="random_strategy", device_name=None,
             limit=None):
    devices = topology["devices"]
    if device_name and device_name != "all":
        devices = [d for d in devices if d["name"] == device_name]
        if not devices:
            fail(f"device '{device_name}' not in topology")
            return []
    if strategy == "random_strategy":
        targets = [t for d in devices for t in random_strategy(d)]
    elif strategy == "sweep":
        targets = [t for d in devices for t in sweep(d, limit=limit)]
    else:
        fail(f"unknown strategy '{strategy}'")
        return []
    return targets
PYEOF

# injection/inject.py 
cat > "$INSTALL_DIR/injection/inject.py" << 'PYEOF'
import  subprocess, time

from utils.checks import ok, warn, fail, info


def inject_cli(device_name, dpa):
    info(f"injecting via cxl-cli: {device_name} @ {dpa}")
    try:
        r = subprocess.run(["cxl", "inject-media-poison", device_name, "-a", str(dpa)],
                           capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            ok("cxl-cli injection accepted")
            return True, "cxl-cli"
        warn(f"cxl-cli injection failed: {r.stderr.strip()}")
        return False, "cxl-cli"
    except FileNotFoundError:
        warn("cxl-cli not found")
        return False, "cxl-cli"
    except subprocess.TimeoutExpired:
        warn("cxl-cli injection timed out")
        return False, "cxl-cli"


def injection(device, dpa):
    result = {
        "device": device["name"], "dpa": dpa,
        "injected": False, "injection_time": None
    }
    print(f"\n  target: {device['name']} @ {dpa}")
    success, method = inject_cli(device["name"], dpa)
    if not success:
        fail("all injection methods failed")
        return result
    result["injected"] = True
    result["injection_method"] = method
    result["injection_time"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    return result


if __name__ == "__main__":
    import json
    from discovery.discover import discovery
    from strategy.strategy  import strategy
    topo = discovery()
    targets = strategy(topo, strategy="random_strategy")
    for t in targets:
        device = next(d for d in topo["devices"] if d["name"] == t["device"])
        result = injection(device, t["dpa"])
        print("\n-- injection result --")
        print(json.dumps(result, indent=2))
PYEOF

# detection/detect.py 
cat > "$INSTALL_DIR/detection/detect.py" << 'PYEOF'
import  sys, subprocess, json

from utils.checks import ok, warn, fail, info


def to_int(val):
    """Convert any address format (hex, decimal, octal) to integer."""
    if isinstance(val, int):
        return val
    s = str(val).strip()
    if s.startswith("0x") or s.startswith("0X"):
        return int(s, 16)
    elif s.startswith("0o") or s.startswith("0O"):
        return int(s, 8)
    else:
        return int(s)

def detection_check(device_name, dpa):
    info(f"detection check on {device_name}")
    try:
        r = subprocess.run(["cxl", "list", "--media-errors", "-m", device_name],
                           capture_output=True, text=True, timeout=10)

        raw = r.stdout.strip()
        target_addr = to_int(dpa)

        data = json.loads(raw) if raw else []
        if isinstance(data, dict):
            data = [data]
        for dev in data:
            for err in dev.get("media_errors", []):
                if to_int(err.get("offset", -1)) == target_addr:
                    ok(f"poisoned memory found: {dpa}")
                    return { "result": "HIT",
                            "dpa_found": dpa }
        warn(f"poisoned memory not found: {dpa}")
        return { "result": "MISS",
                "dpa_found": None }
    except Exception as e:
        warn(f"error -- {e}")
        return { "result": "ERROR",
                "dpa_found": None }

def detection(device_name, dpa):
    print(f"\n  detection: {device_name} @ {dpa}")

    result = detection_check(device_name, dpa)
    return {
        "device": device_name, "dpa": dpa,
        "detection_check": result,
    }

if __name__ == "__main__":
    from utils.checks       import all_checks
    from discovery.discover import discovery
    from strategy.strategy  import strategy
    from injection.inject   import injection
    checks = all_checks()
    topo = discovery()
    targets = strategy(topo, strategy="random_strategy")
    for t in targets:
        device = next(d for d in topo["devices"] if d["name"] == t["device"])
        inj = injection(device, t["dpa"])
        det = detection(device["name"], t["dpa"])
        print("\n-- detection result --")
        print(json.dumps(det, indent=2))
PYEOF

# reporting/report.py 
cat > "$INSTALL_DIR/reporting/report.py" << 'PYEOF'
import os, json, time

from utils.checks import ok, fail, info, GREEN, RED, CYAN, RESET, BOLD

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def generate_run_id():
    return f"cxl-fi-{time.strftime('%Y%m%d-%H%M%S')}"

def print_live_result(inj, det):
    device = inj["device"]
    dpa = inj["dpa"]
    print(f"\n  result: {device} @ {dpa}")
    print(f"  {'-'*43}")

    if inj["injected"]:
        ok(f"injected via {inj.get('injection_method', 'unknown')}")
    else:
        fail("injection failed")

    det_result = det["detection_check"]["result"]

    if det_result == "HIT":
        ok(f"detection: {dpa} found in poison list")
    else:
        fail(f"detection: {det_result}")

    print(f"  {'-'*43}")

    if inj["injected"] and det_result == "HIT":
        print(f"  {GREEN}{BOLD}overall: pass{RESET}")
    else:
        print(f"  {RED}{BOLD}overall: fail{RESET}")

def build_report(run_id, checks, topology, strategy, all_inj, all_det):
    results = []
    passed = 0
    failed = 0
    for inj, det in zip(all_inj, all_det):
        det_result = det["detection_check"]["result"]
        overall = "PASS" if inj["injected"] and det_result == "HIT" else "FAIL"
        results.append({
            "device": inj["device"], "dpa": inj["dpa"],
            "injection": {"method": inj.get("injection_method"),
                          "timestamp": inj.get("injection_time")},
            "detection": det["detection_check"],
            "overall": overall
        })
        if overall == "PASS":
            passed += 1
        else:
            failed += 1
    return {
        "run_id": run_id, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "environment": {"kernel": checks.get("kernel_version")},
        "topology": {"total_devices": topology["total_devices"]},
        "strategy": strategy, "results": results,
        "summary": {"total_targets": len(results), "passed": passed, "failed": failed}
    }

def print_summary(report):
    s = report["summary"]
    print(f"\n  run summary -- {report['run_id']}")
    print(f"  {'-'*43}")
    print(f"  strategy   : {report['strategy']}")
    print(f"  kernel     : {report['environment']['kernel']}")
    print(f"  {'-'*43}")
    print(f"  total   : {s['total_targets']}")
    print(f"  {GREEN}passed  : {s['passed']}{RESET}")
    print(f"  {RED}failed  : {s['failed']}{RESET}")
    print(f"  {'-'*43}")
    if s["failed"] == 0:
        print(f"  {GREEN}{BOLD}all tests passed{RESET}")
    else:
        print(f"  {RED}{BOLD}some tests failed{RESET}")

def save_report(report, output_path=None):
    if not output_path:
        log_dir = os.path.join(BASE_DIR, "logs")
        os.makedirs(log_dir, exist_ok=True)
        output_path = os.path.join(log_dir, f"{report['run_id']}.json")
    with open(output_path, "w") as f:
        json.dump(report, f, indent=2)
    ok(f"report saved: {output_path}")
    return output_path
PYEOF

# main.py 
cat > "$INSTALL_DIR/main.py" << 'PYEOF'
import os, sys, argparse, json

from utils.checks       import all_checks
from discovery.discover import discovery
from strategy.strategy  import strategy
from injection.inject   import injection
from detection.detect   import detection
from reporting.report   import (
    generate_run_id, print_live_result,
    build_report, print_summary, save_report
)

from utils.checks import GREEN, YELLOW, RED, CYAN, BOLD, RESET

def parse_args():
    parser = argparse.ArgumentParser(
        prog="cxl-fault-injector",
        description="cxl memory fault injection framework",
        formatter_class=argparse.RawTextHelpFormatter,
        epilog="""
examples:
  sudo python3 main.py
  sudo python3 main.py --strategy random_strategy --device mem0
  sudo python3 main.py --strategy sweep --limit 5
  sudo python3 main.py --strategy random_strategy --output /tmp/report.json
        """
    )
    parser.add_argument("--strategy",  choices=["random_strategy","sweep"], default="random_strategy")
    parser.add_argument("--device",    default="all")
    parser.add_argument("--limit",     type=int, default=None)
    parser.add_argument("--output",    default=None)
    return parser.parse_args()

def main():
    args = parse_args()
    run_id = generate_run_id()
    print(f"\n  cxl fault injector")
    print(f"  run id   : {run_id}")
    print(f"  strategy : {args.strategy}")
    print(f"  device   : {args.device}")
    print()
    print(f"  {CYAN}{BOLD}environment checks{RESET}")
    checks = all_checks()
    if checks is None:
        print(f"\n{RED}critical check failed, exiting.{RESET}")
        sys.exit(1)

    print(f"\n  {CYAN}{BOLD}device discovery{RESET}")
    topo = discovery()
    if topo["total_devices"] == 0:
        print(f"\n{RED}no cxl devices found, exiting.{RESET}")
        sys.exit(1)


    print(f"\n  {CYAN}{BOLD}strategy engine{RESET}")
    targets = strategy(
        topo, strategy=args.strategy, device_name=args.device, limit=args.limit
    )

    print(f"\n  {CYAN}{BOLD}injection and detection{RESET}")
    all_inj = []
    all_det = []
    for i, t in enumerate(targets, 1):
        print(f"\n  [{i}/{len(targets)}] {t['device']} @ {t['dpa']}")
        device = next(d for d in topo["devices"] if d["name"] == t["device"])
        inj = injection(device, t["dpa"])
        det = detection(device["name"], t["dpa"])
        print_live_result(inj, det)
        all_inj.append(inj)
        all_det.append(det)

    print(f"\n  {CYAN}{BOLD}report{RESET}")
    report = build_report(run_id, checks, topo, args.strategy, all_inj, all_det)
    print_summary(report)
    save_report(report, output_path=args.output)
    sys.exit(0 if report["summary"]["failed"] == 0 else 1)

if __name__ == "__main__":
    main()
PYEOF


ok "All Python modules written"
echo ""

echo "  Running CXL Fault Injector"

echo ""

cd "$INSTALL_DIR"
exec python3 main.py "$@"
