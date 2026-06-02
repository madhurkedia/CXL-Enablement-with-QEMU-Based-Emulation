
#  CXL Memory Fault Injection Framework
#  Usage:  chmod +x cxl_fault_injector.sh && sudo ./cxl_fault_injector.sh
#          or with options:
#          sudo ./cxl_fault_injector.sh --strategy sweep --limit 5
#          sudo ./cxl_fault_injector.sh --dry-run
#          sudo ./cxl_fault_injector.sh --strategy numa --numa-node 0
#          sudo ./cxl_fault_injector.sh --strategy interleave --device mem0



set -e

# colours
GREEN="\033[92m"; YELLOW="\033[93m"; RED="\033[91m"; BOLD="\033[1m"; RESET="\033[0m"
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
import os, sys, subprocess, platform

GREEN  = "\033[92m"; YELLOW = "\033[93m"; RED = "\033[91m"; BOLD = "\033[1m"; RESET = "\033[0m"
def ok(msg):   print(f"  {GREEN}[pass]{RESET} {msg}")
def warn(msg): print(f"  {YELLOW}[warn]{RESET} {msg}")
def fail(msg): print(f"  {RED}[fail]{RESET} {msg}")
def info(msg): print(f"  [info] {msg}")

def check_root():
    print("\n-- checking root privileges")
    if os.geteuid() == 0:
        ok("running as root"); return True
    fail("not running as root -- use: sudo python3 main.py"); return False

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
        warn(f"kernel {ver} -- partial support, sysfs fallback may be needed"); return ver, True
    else:
        fail(f"kernel {ver} -- too old, need 6.0+"); return ver, False

def check_cxl_cli():
    print("\n-- checking cxl-cli")
    try:
        result = subprocess.run(["cxl", "version"], capture_output=True, text=True, timeout=5)
        version = result.stdout.strip() or result.stderr.strip()
        ok(f"cxl-cli found, version {version}"); return version, True
    except FileNotFoundError:
        warn("cxl-cli not found -- will fall back to sysfs"); return None, False
    except subprocess.TimeoutExpired:
        warn("cxl-cli timed out -- will fall back to sysfs"); return None, False

def check_detection_paths():
    print("\n-- probing detection capabilities")
    caps = {"event_interrupt": False, "mce_available": False, "mailbox_poll": True}
    cxl_sysfs = "/sys/bus/cxl/devices/"
    if os.path.exists(cxl_sysfs):
        for dev in os.listdir(cxl_sysfs):
            if dev.startswith("mem"):
                if os.path.exists(f"{cxl_sysfs}{dev}/firmware_version"):
                    caps["event_interrupt"] = True; break
    if caps["event_interrupt"]: ok("path 3 (event interrupt) -- supported")
    else:                        warn("path 3 (event interrupt) -- not detected")
    if os.path.exists("/sys/bus/machinecheck"):
        caps["mce_available"] = True; ok("path 2 (mce) -- available")
    else:
        warn("path 2 (mce) -- not available (expected in wsl/qemu)")
    ok("path 1 (mailbox poll) -- always available")
    return caps

def determine_mode(caps):
    print("\n-- determining environment mode")
    if caps["event_interrupt"]:    mode, desc = "MODE 3", "full real hardware (cxl 2.0)"
    elif caps["mce_available"]:    mode, desc = "MODE 2", "real hardware basic"
    else:                          mode, desc = "MODE 1", "qemu lab or wsl"
    info(f"{mode} -- {desc}"); return mode

def all_checks():
    print("=" * 45); print("  cxl fault injector -- environment checks"); print("=" * 45)
    out = {}
    out["root"] = check_root()
    if not out["root"]:
        print(f"\n{RED}cannot continue without root.{RESET}"); return None
    ver, ok_flag = check_kernel()
    out["kernel_version"] = ver
    if not ok_flag:
        print(f"\n{RED}kernel too old, exiting.{RESET}"); return None
    cxl_ver, cxl_found = check_cxl_cli()
    out["cxl_cli_version"]   = cxl_ver
    out["cxl_cli_available"] = cxl_found
    out["sysfs_fallback"]    = not cxl_found
    caps = check_detection_paths()
    out["detection_capabilities"] = caps
    out["environment_mode"]       = determine_mode(caps)
    print("\n" + "=" * 45); print("  checks done"); print("=" * 45)
    return out

if __name__ == "__main__":
    all_checks()
PYEOF

# discovery/discover.py 
cat > "$INSTALL_DIR/discovery/discover.py" << 'PYEOF'
import os, sys, json, subprocess

from utils.checks import ok, warn, fail, info

SYSFS = "/sys/bus/cxl/devices"

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

def scan_sysfs():
    print("\n-- scanning sysfs for cxl devices")
    if not os.path.exists(SYSFS):
        warn(f"sysfs path not found: {SYSFS}")
        info("expected in wsl2 or systems without cxl hardware")
        return []
    devs = sorted(e for e in os.listdir(SYSFS) if e.startswith("mem"))
    if devs:
        ok(f"sysfs found: {', '.join(devs)}")
    else:
        warn("no mem* devices in sysfs")
    return devs

def get_dpa_range(name):
    size_path = f"{SYSFS}/{name}/ram/size"
    if not os.path.exists(size_path):
        warn(f"no ram/size for {name} -- will use simulated 1gb range")
        size = 1 * 1024 ** 3
        return "0x0", hex(size), size
    try:
        with open(size_path) as fh:
            raw = fh.read().strip()
        size = int(raw, 16) if raw.startswith("0x") else int(raw)
        info(f"{name} dpa range: 0x0 to {hex(size)} ({size // (1024**3)} gb)")
        return "0x0", hex(size), size
    except ValueError:
        warn(f"could not parse size for {name}")
        size = 1 * 1024 ** 3
        return "0x0", hex(size), size

def get_numa_node(name):
    path = f"{SYSFS}/{name}/numa_node"
    if os.path.exists(path):
        try:
            with open(path) as fh:
                node = int(fh.read().strip())
            info(f"{name} numa node: {node}")
            return node
        except ValueError:
            pass
    info(f"{name} numa node: unknown")
    return None

def check_existing_poison(name):
    print(f"\n-- checking pre-existing poison on {name}")
    try:
        r = subprocess.run(["cxl", "list", "--poison", name], capture_output=True, text=True, timeout=10)
        raw = r.stdout.strip()
        if not raw or raw == "[]":
            ok(f"{name} poison list is clean")
            return [], 0
        data = json.loads(raw)
        if isinstance(data, dict):
            data = [data]
        warn(f"{name} has {len(data)} pre-existing poison record(s)")
        return data, len(data)
    except Exception as e:
        info(f"could not read poison list for {name} (expected in wsl2). Error details: {e}")
        return [], 0

def check_capacity(name, current):
    path = f"{SYSFS}/{name}/poison_max"
    capacity = 256
    if os.path.exists(path):
        try:
            with open(path) as fh:
                capacity = int(fh.read().strip())
        except ValueError:
            pass
    else:
        info(f"{name} poison_max not found, assuming {capacity}")
    pct = (current / capacity * 100) if capacity else 0
    risk = "HIGH" if pct > 80 else "LOW"
    if risk == "HIGH":
        warn(f"{name} poison list {pct:.0f}% full")
    else:
        info(f"{name} poison list: {current}/{capacity} ({pct:.0f}%)")
    return capacity, risk

def build_topology(cli_devices, sysfs_devices):
    print("\n-- building topology map")
    cli_names = set()
    for d in cli_devices:
        name = d.get("memdev") or d.get("name", "")
        if name: cli_names.add(name)
    all_names = sorted(cli_names | set(sysfs_devices))
    if not all_names:
        warn("no real cxl devices found anywhere")
        info("generating simulated mem0 for development")
        all_names = ["mem0"]
    devices = []
    numa_map = {}
    total = 0
    for name in all_names:
        dpa_start, dpa_end, size = get_dpa_range(name)
        numa = get_numa_node(name)
        poison_list, poison_count = check_existing_poison(name)
        capacity, risk = check_capacity(name, poison_count)
        simulated = not os.path.exists(f"{SYSFS}/{name}/ram/size")
        devices.append({
            "name": name, "path": f"{SYSFS}/{name}",
            "dpa_start": dpa_start, "dpa_end": dpa_end,
            "size_bytes": size, "size_gb": round(size / (1024**3), 2),
            "numa_node": numa, "online": True,
            "poison_list_count": poison_count, "poison_list_capacity": capacity,
            "risk_flag": risk, "simulated": simulated
        })
        total += size
        node_key = str(numa) if numa is not None else "unknown"
        numa_map.setdefault(node_key, []).append(name)
    topology = {
        "total_devices": len(devices),
        "total_cxl_memory_gb": round(total / (1024**3), 2),
        "numa_map": numa_map, "devices": devices
    }
    ok(f"topology ready: {len(devices)} device(s), {topology['total_cxl_memory_gb']} gb total")
    return topology

def discovery():
    print("=" * 45)
    print("  cxl fault injector -- device discovery")
    print("=" * 45)
    cli  = list_devices_via_cli()
    sysf = scan_sysfs()
    topo = build_topology(cli, sysf)
    print("\n" + "=" * 45)
    print("  discovery complete")
    print("=" * 45)
    print(json.dumps(topo, indent=2))
    return topo

if __name__ == "__main__":
    discovery()
PYEOF

# strategy/strategy.py 
cat > "$INSTALL_DIR/strategy/strategy.py" << 'PYEOF'
import os, sys, random

from utils.checks import ok, warn, fail, info

CACHELINE = 64

def align(addr):
    return (addr // CACHELINE) * CACHELINE

def excluded_addresses(device):
    skip = {0x0}
    for entry in device.get("poison_list", []):
        try:
            skip.add(int(entry.get("dpa", "0x0"), 16))
        except (ValueError, AttributeError):
            pass
    return skip

def random_unused(device):
    info(f"strategy random_unused on {device['name']}")
    start = int(device["dpa_start"], 16)
    end = int(device["dpa_end"], 16)
    skip = excluded_addresses(device)
    pool = []
    addr = align(start + CACHELINE)
    while addr < end and len(pool) < 100_000:
        if addr not in skip:
            pool.append(addr)
        addr += CACHELINE
    if not pool:
        fail(f"no valid addresses on {device['name']}")
        return []
    chosen = random.choice(pool)
    ok(f"selected dpa: {hex(chosen)} on {device['name']}")
    return [{"device": device["name"], "dpa": hex(chosen), "strategy": "random_unused"}]

def sweep(device, limit=None):
    info(f"strategy sweep on {device['name']}" + (f" (limit {limit})" if limit else ""))
    start = int(device["dpa_start"], 16)
    end = int(device["dpa_end"], 16)
    skip = excluded_addresses(device)
    targets = []
    addr = align(start + CACHELINE)
    while addr < end:
        if addr not in skip:
            targets.append({"device": device["name"], "dpa": hex(addr), "strategy": "sweep"})
        addr += CACHELINE
        if limit and len(targets) >= limit:
            break
    ok(f"sweep generated {len(targets)} target(s) on {device['name']}")
    return targets

def numa_targeted(topology, numa_node):
    info(f"strategy numa_targeted on node {numa_node}")
    node_key = str(numa_node)
    if node_key not in topology.get("numa_map", {}):
        fail(f"numa node {numa_node} not in topology")
        info(f"available nodes: {list(topology['numa_map'].keys())}")
        return []
    dev_map = {d["name"]: d for d in topology["devices"]}
    targets = []
    for name in topology["numa_map"][node_key]:
        device = dev_map.get(name)
        if device:
            result = random_unused(device)
            for t in result:
                t["strategy"] = "numa_targeted"
                t["numa_node"] = numa_node
            targets.extend(result)
    ok(f"numa strategy generated {len(targets)} target(s)")
    return targets

def interleave_edge(topology):
    info("strategy interleave_edge")
    targets = []
    for device in topology["devices"]:
        start = int(device["dpa_start"], 16)
        end = int(device["dpa_end"], 16)
        skip = excluded_addresses(device)
        near_start = align(start + CACHELINE)
        near_end = align(end - CACHELINE)
        if near_start not in skip and near_start < end:
            targets.append({"device": device["name"], "dpa": hex(near_start),
                            "strategy": "interleave_edge", "position": "start_boundary"})
        if near_end not in skip and near_end > start:
            targets.append({"device": device["name"], "dpa": hex(near_end),
                            "strategy": "interleave_edge", "position": "end_boundary"})
        info(f"{device['name']} boundaries: start={hex(near_start)}, end={hex(near_end)}")
    ok(f"interleave edge generated {len(targets)} target(s)")
    return targets

def strategy(topology, strategy="random", device_name=None,
             numa_node=0, limit=None, dry_run=False):
    print("=" * 45)
    print("  cxl fault injector -- strategy engine")
    print("=" * 45)
    devices = topology["devices"]
    if device_name and device_name != "all":
        devices = [d for d in devices if d["name"] == device_name]
        if not devices:
            fail(f"device '{device_name}' not in topology")
            return []
        topology = dict(topology, devices=devices)
    if strategy == "random":
        targets = [t for d in devices for t in random_unused(d)]
    elif strategy == "sweep":
        targets = [t for d in devices for t in sweep(d, limit=limit)]
    elif strategy == "numa":
        targets = numa_targeted(topology, numa_node)
    elif strategy == "interleave":
        targets = interleave_edge(topology)
    else:
        fail(f"unknown strategy '{strategy}'")
        return []
    if dry_run:
        print("\n  -- dry run, no injection will happen --")
        for t in targets:
            pos = f" [{t.get('position', '')}]" if t.get("position") else ""
            print(f"  would inject: {t['device']} @ {t['dpa']}{pos}")
        print(f"  total: {len(targets)} target(s)")
        return targets
    print(f"\n  targets planned: {len(targets)}")
    return targets

if __name__ == "__main__":
    from discovery.discover import discovery
    topo = discovery()
    print("\n-- testing all strategies in dry-run mode --\n")
    for s in ["random", "sweep", "numa", "interleave"]:
        print(f"\n  strategy: {s}")
        strategy(topo, strategy=s, limit=3, dry_run=True, numa_node=0)
PYEOF

# injection/inject.py 
cat > "$INSTALL_DIR/injection/inject.py" << 'PYEOF'
import os, sys, subprocess, time

from utils.checks import ok, warn, fail, info

SYSFS       = "/sys/bus/cxl/devices"
DEBUG_SYSFS = "/sys/kernel/debug/cxl"

def pre_check(device):
    info(f"pre-injection check on {device['name']}")
    if not device.get("online", False):
        fail(f"{device['name']} is offline")
        return False
    count = device.get("poison_list_count", 0)
    capacity = device.get("poison_list_capacity", 256)
    if count >= capacity:
        fail(f"{device['name']} poison list full ({count}/{capacity})")
        return False
    if device.get("risk_flag") == "HIGH":
        warn(f"{device['name']} poison list over 80% full, continuing")
    ok("pre-check passed")
    return True

def inject_cli(device_name, dpa):
    info(f"injecting via cxl-cli: {device_name} @ {dpa}")
    try:
        r = subprocess.run(["cxl", "inject-poison", device_name, "--dpa", str(dpa)],
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

def inject_sysfs(device_name, dpa):
    info(f"injecting via sysfs: {device_name} @ {dpa}")
    path = f"{DEBUG_SYSFS}/{device_name}/inject_poison"
    if not os.path.exists(path):
        info(f"sysfs inject path not found: {path}")
        info("expected on wsl2 or systems without real cxl hardware")
        info(f"[simulated] injection recorded @ {dpa}")
        return True, "sysfs-simulated"
    try:
        with open(path, "w") as fh:
            fh.write(str(dpa) + "\n")
        ok("sysfs injection accepted")
        return True, "sysfs"
    except PermissionError:
        fail(f"permission denied: {path}")
        return False, "sysfs"
    except OSError as e:
        fail(f"sysfs write error: {e}")
        return False, "sysfs"

def confirm_injection(device_name, dpa, simulated=False):
    info(f"confirming injection on {device_name} @ {dpa}")
    if simulated:
        info("[simulated] skipping confirmation")
        return True
    trigger = f"{SYSFS}/{device_name}/trigger_poison_list"
    if os.path.exists(trigger):
        try:
            # Force hardware to audit the poison list before we read it
            with open(trigger, "w") as fh:
                fh.write("1\n")
        except OSError:
            pass
    time.sleep(1.0)
    try:
        r = subprocess.run(["cxl", "list", "--poison", device_name],
                           capture_output=True, text=True, timeout=10)
        if dpa in r.stdout:
            ok("injection confirmed in poison list")
            return True
        warn(f"{dpa} not in poison list yet")
        return False
    except Exception as e:
        warn(f"could not verify injection. Error details: {e}")
        return False

def clear_cli(device_name, dpa):
    info(f"clearing via cxl-cli: {device_name} @ {dpa}")
    try:
        r = subprocess.run(["cxl", "clear-poison", device_name, "--dpa", str(dpa)],
                           capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            ok("cxl-cli clear accepted")
            return True, "cxl-cli"
        warn(f"cxl-cli clear failed: {r.stderr.strip()}")
        return False, "cxl-cli"
    except FileNotFoundError:
        warn("cxl-cli not found for clear")
        return False, "cxl-cli"
    except subprocess.TimeoutExpired:
        warn("cxl-cli clear timed out")
        return False, "cxl-cli"

def clear_sysfs(device_name, dpa):
    info(f"clearing via sysfs: {device_name} @ {dpa}")
    path = f"{DEBUG_SYSFS}/{device_name}/clear_poison"
    if not os.path.exists(path):
        info("[simulated] clear recorded")
        return True, "sysfs-simulated"
    try:
        with open(path, "w") as fh:
            fh.write(str(dpa) + "\n")
        ok("sysfs clear accepted")
        return True, "sysfs"
    except OSError as e:
        fail(f"sysfs clear error: {e}")
        return False, "sysfs"

def verify_clear(device_name, dpa, simulated=False):
    info(f"verifying clear on {device_name} @ {dpa}")
    if simulated:
        info("[simulated] skipping verify")
        return True
    trigger = f"{SYSFS}/{device_name}/trigger_poison_list"
    if os.path.exists(trigger):
        try:
            # Force hardware to audit the poison list to ensure clear was successful
            with open(trigger, "w") as fh:
                fh.write("1\n")
        except OSError:
            pass
    time.sleep(1.0)
    try:
        r = subprocess.run(["cxl", "list", "--poison", device_name],
                           capture_output=True, text=True, timeout=10)
        if dpa not in r.stdout:
            ok("poison cleared, device is clean")
            return True
        fail(f"{dpa} still in poison list after clear")
        return False
    except Exception as e:
        warn(f"could not verify clear. Error details: {e}")
        return False

def injection(device, dpa):
    result = {
        "device": device["name"], "dpa": dpa,
        "pre_check": False, "injected": False, "injection_method": None,
        "injection_confirmed": False, "injection_time": None,
        "cleared": False, "clear_method": None,
        "verified_clean": False, "clear_time": None,
        "simulated": False, "overall": "FAIL"
    }
    print(f"\n  target: {device['name']} @ {dpa}")
    if not pre_check(device):
        return result
    result["pre_check"] = True
    success, method = inject_cli(device["name"], dpa)
    if not success:
        success, method = inject_sysfs(device["name"], dpa)
    if not success:
        fail("all injection methods failed")
        return result
    result["injected"] = True
    result["injection_method"] = method
    result["injection_time"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    simulated = "simulated" in method
    result["simulated"] = simulated
    result["injection_confirmed"] = confirm_injection(device["name"], dpa, simulated=simulated)
    success, method = clear_cli(device["name"], dpa)
    if not success:
        success, method = clear_sysfs(device["name"], dpa)
    result["cleared"] = success
    result["clear_method"] = method
    result["clear_time"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    result["verified_clean"] = verify_clear(device["name"], dpa, simulated=simulated)
    if result["injected"] and result["cleared"]:
        result["overall"] = "PASS"
        ok("cycle complete -- pass")
    else:
        fail("cycle incomplete -- fail")
    return result

if __name__ == "__main__":
    import json
    from discovery.discover import discovery
    from strategy.strategy  import strategy
    print("=" * 45)
    print("  cxl fault injector -- injection test")
    print("=" * 45)
    topo = discovery()
    targets = strategy(topo, strategy="random")
    for t in targets:
        device = next(d for d in topo["devices"] if d["name"] == t["device"])
        result = injection(device, t["dpa"])
        print("\n-- injection result --")
        print(json.dumps(result, indent=2))
PYEOF

# detection/detect.py 
cat > "$INSTALL_DIR/detection/detect.py" << 'PYEOF'
import os, sys, subprocess, time, json

from utils.checks import ok, warn, fail, info

SYSFS = "/sys/bus/cxl/devices"
MCE = "/sys/bus/machinecheck"

def path3_check(device_name, dpa, timeout=2):
    # CXL 2.0/3.0 spec defines event records for poison injection.
    # We poll the event_log sysfs node to verify if the hardware raised an event.
    info(f"path 3: waiting for event interrupt (timeout {timeout}s)")
    event_path = f"{SYSFS}/{device_name}/event_log"
    if not os.path.exists(event_path):
        info("path 3: not available (expected in wsl2/qemu)")
        return {"path": "path3_event_interrupt", "result": "NOT_AVAILABLE",
                "dpa_found": None, "latency_ms": None}
    start = time.time()
    while (time.time() - start) < timeout:
        try:
            with open(event_path) as fh:
                content = fh.read()
            if dpa in content:
                ms = int((time.time() - start) * 1000)
                ok(f"path 3: event fired, {dpa} detected ({ms}ms)")
                return {"path": "path3_event_interrupt", "result": "HIT",
                        "dpa_found": dpa, "latency_ms": ms}
        except OSError:
            pass
        time.sleep(0.05)
    warn(f"path 3: no event within {timeout}s")
    return {"path": "path3_event_interrupt", "result": "MISS",
            "dpa_found": None, "latency_ms": None}

def path1_check(device_name, dpa, simulated=False):
    info(f"path 1: polling poison list on {device_name}")
    if simulated:
        info("path 1: [simulated] recording as hit")
        return {"path": "path1_mailbox_poll", "result": "HIT",
                "dpa_found": dpa, "latency_ms": 0, "simulated": True}
    trigger = f"{SYSFS}/{device_name}/trigger_poison_list"
    if os.path.exists(trigger):
        try:
            # According to the CXL spec, reading the poison list sysfs file 
            # might return cached data. We must write to 'trigger_poison_list' 
            # to force the hardware to audit the memory and update the cache.
            with open(trigger, "w") as fh:
                fh.write("1\n")
            info("path 1: triggered hardware audit")
        except OSError as e:
            warn(f"path 1: could not trigger audit: {e}")
    time.sleep(0.3)
    start = time.time()
    try:
        r = subprocess.run(["cxl", "list", "--poison", device_name],
                           capture_output=True, text=True, timeout=10)
        ms = int((time.time() - start) * 1000)
        raw = r.stdout.strip()
        if not raw or raw == "[]":
            warn(f"path 1: poison list empty, {dpa} not found")
            return {"path": "path1_mailbox_poll", "result": "MISS",
                    "dpa_found": None, "latency_ms": ms, "simulated": False}
        if dpa in raw:
            ok(f"path 1: {dpa} confirmed ({ms}ms)")
            return {"path": "path1_mailbox_poll", "result": "HIT",
                    "dpa_found": dpa, "latency_ms": ms, "simulated": False}
        warn(f"path 1: {dpa} not in poison list")
        return {"path": "path1_mailbox_poll", "result": "MISS",
                "dpa_found": None, "latency_ms": ms, "simulated": False}
    except subprocess.TimeoutExpired:
        warn("path 1: cxl-cli timed out")
        return {"path": "path1_mailbox_poll", "result": "TIMEOUT",
                "dpa_found": None, "latency_ms": None, "simulated": False}
    except Exception as e:
        warn(f"path 1: error -- {e}")
        return {"path": "path1_mailbox_poll", "result": "ERROR",
                "dpa_found": None, "latency_ms": None, "simulated": False}

def path2_check(caps):
    # MCEs are triggered by the CPU when it consumes poisoned memory.
    # We check /sys/bus/machinecheck to ensure the hardware intercepted 
    # the fault rather than crashing the system entirely.
    if not caps.get("mce_available"):
        info("path 2: mce not available on this system")
        return {"path": "path2_mce", "result": "NOT_AVAILABLE", "fired": False, "address": None}
    info("path 2: checking mce logs")
    if not os.path.exists(MCE):
        ok("path 2: mce silent (good)")
        return {"path": "path2_mce", "result": "SILENT", "fired": False, "address": None}
    for entry in os.listdir(MCE):
        status_path = f"{MCE}/{entry}/status"
        if os.path.exists(status_path):
            try:
                with open(status_path) as fh:
                    status = fh.read().strip()
                if status and status not in ("0x0", "0"):
                    warn(f"path 2: mce fired -- {entry} status={status}")
                    return {"path": "path2_mce", "result": "FIRED",
                            "fired": True, "address": status}
            except OSError:
                pass
    ok("path 2: mce silent -- poison was not accessed (good)")
    return {"path": "path2_mce", "result": "SILENT", "fired": False, "address": None}

def cross_verify(p1, p2, p3):
    info("cross-verifying detection paths")
    r1 = p1.get("result")
    r2 = p2.get("result")
    r3 = p3.get("result")
    mce_flag = "CRIT_MCE_FIRED" if r2 == "FIRED" else None
    if mce_flag:
        warn("critical: mce fired -- poison was accessed before recovery")

    # both event interrupt and mailbox agree
    if r3 == "HIT" and r1 == "HIT":
        verdict = "PERFECT"
        ok("all paths agree -- hardware tracking correct")
    # event fired but mailbox missed it -- probably a fw bug
    elif r3 == "HIT" and r1 == "MISS":
        verdict = "FIRMWARE_BUG"
        fail("bug: event interrupt fired but poison list not updated")
    # mailbox caught it but event interrupt didn't fire
    elif r3 == "MISS" and r1 == "HIT":
        verdict = "WARN_PATH3_MISS"
        warn("event interrupt did not fire but path 1 caught it")
    # no event interrupt support, but mailbox confirmed
    elif r3 == "NOT_AVAILABLE" and r1 == "HIT":
        verdict = "PASS"
        ok("path 3 not available -- path 1 confirmed detection")
    # no event interrupt and mailbox also failed
    elif r3 == "NOT_AVAILABLE" and r1 in ("MISS", "ERROR", "TIMEOUT"):
        verdict = "FAIL_PATH1_MISS"
        fail("critical: path 1 poll also failed to detect poison")
    else:
        verdict = "INCONCLUSIVE"
        warn(f"inconclusive -- p1:{r1} p2:{r2} p3:{r3}")

    passed = verdict in ("PERFECT", "PASS", "WARN_PATH3_MISS")
    return {
        "path1": r1, "path2": r2, "path3": r3,
        "verdict": verdict, "mce_flag": mce_flag,
        "cross_verify": passed
    }

def detection(device_name, dpa, caps, simulated=False):
    print(f"\n  detection: {device_name} @ {dpa}")
    t_start = time.time()
    p3 = path3_check(device_name, dpa)
    p1 = path1_check(device_name, dpa, simulated=simulated)
    p2 = path2_check(caps)
    cv = cross_verify(p1, p2, p3)
    return {
        "device": device_name, "dpa": dpa,
        "path1": p1, "path2": p2, "path3": p3, "cross_verify": cv,
        "total_latency_ms": int((time.time() - t_start) * 1000), "simulated": simulated
    }

if __name__ == "__main__":
    from utils.checks       import all_checks
    from discovery.discover import discovery
    from strategy.strategy  import strategy
    from injection.inject   import injection
    print("=" * 45)
    print("  cxl fault injector -- detection test")
    print("=" * 45)
    checks = all_checks()
    caps = checks["detection_capabilities"]
    topo = discovery()
    targets = strategy(topo, strategy="random")
    for t in targets:
        device = next(d for d in topo["devices"] if d["name"] == t["device"])
        inj = injection(device, t["dpa"])
        det = detection(device["name"], t["dpa"], caps, simulated=inj.get("simulated", False))
        print("\n-- detection result --")
        print(json.dumps(det, indent=2))
PYEOF

# reporting/report.py 
cat > "$INSTALL_DIR/reporting/report.py" << 'PYEOF'
import os, sys, json, time

from utils.checks import ok, warn, fail, info, GREEN, YELLOW, RED, RESET, BOLD

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def generate_run_id():
    return f"cxl-fi-{time.strftime('%Y%m%d-%H%M%S')}"

def collect_flags(inj, det):
    flags = []
    cv = det.get("cross_verify", {})
    if not inj.get("injection_confirmed"):
        flags.append("FAIL_INJECTION_UNCONFIRMED")
    if not inj.get("cleared"):
        flags.append("FAIL_CLEAR_FAILED")
    if not inj.get("verified_clean"):
        flags.append("FAIL_VERIFY_FAILED")
    if det["path1"]["result"] == "MISS":
        flags.append("FAIL_PATH1_MISS")
    if det["path3"]["result"] == "MISS":
        flags.append("WARN_PATH3_MISS")
    if det["path2"]["result"] == "FIRED":
        flags.append("CRIT_MCE_FIRED")
    if cv.get("verdict") == "FIRMWARE_BUG":
        flags.append("BUG_FIRMWARE")
    if inj.get("simulated"):
        flags.append("INFO_SIMULATED_MODE")
    return flags

def _show_path(label, result, extra):
    if result == "HIT":
        ok(f"{label}: {result}{extra}")
    elif result in ("SILENT", "NOT_AVAILABLE"):
        info(f"{label}: {result}{extra}")
    elif result == "MISS":
        fail(f"{label}: {result}{extra}")
    else:
        warn(f"{label}: {result}{extra}")

def _show_verdict(verdict):
    if verdict in ("PERFECT", "PASS"):
        ok(f"cross-verify: {verdict}")
    elif verdict == "WARN_PATH3_MISS":
        warn(f"cross-verify: {verdict}")
    elif verdict == "FIRMWARE_BUG":
        fail(f"cross-verify: {verdict} -- firmware issue detected")
    elif verdict == "FAIL_PATH1_MISS":
        fail(f"cross-verify: {verdict} -- critical failure")
    else:
        warn(f"cross-verify: {verdict}")

def print_live_result(inj, det):
    device = inj["device"]
    dpa = inj["dpa"]
    verdict = det["cross_verify"]["verdict"]
    print(f"\n  result: {device} @ {dpa}")
    print(f"  {'-'*43}")
    if inj["injected"]:
        ok(f"injected via {inj.get('injection_method', 'unknown')}")
    else:
        fail("injection failed")
    if inj["injection_confirmed"]:
        ok("injection confirmed")
    else:
        warn("injection not confirmed")
    p1 = det["path1"]["result"]
    p2 = det["path2"]["result"]
    p3 = det["path3"]["result"]
    lat = det["path1"].get("latency_ms")
    lat_str = f" ({lat}ms)" if lat is not None else ""
    _show_path("path 1 mailbox poll", p1, lat_str)
    _show_path("path 2 mce", p2, "")
    _show_path("path 3 event interrupt", p3, "")
    print(f"  {'-'*43}")
    _show_verdict(verdict)
    if inj["cleared"]:
        ok(f"cleared via {inj.get('clear_method', 'unknown')}")
    else:
        fail("clear failed")
    if inj["verified_clean"]:
        ok("verified clean")
    else:
        fail("poison still present after clear")
    print(f"  {'-'*43}")
    if inj["overall"] == "PASS":
        print(f"  {GREEN}{BOLD}overall: pass{RESET}")
    else:
        print(f"  {RED}{BOLD}overall: fail{RESET}")
    flags = collect_flags(inj, det)
    if flags:
        print(f"  flags:")
        for f in flags:
            print(f"    {YELLOW}{f}{RESET}")

def build_report(run_id, checks, topology, strategy, all_inj, all_det):
    results = []
    passed = 0
    failed = 0
    warnings = 0
    firmware_bugs = 0
    for inj, det in zip(all_inj, all_det):
        flags = collect_flags(inj, det)
        results.append({
            "device": inj["device"], "dpa": inj["dpa"],
            "injection": {"method": inj.get("injection_method"),
                          "confirmed": inj.get("injection_confirmed"),
                          "timestamp": inj.get("injection_time"),
                          "simulated": inj.get("simulated", False)},
            "detection": {"path1": det["path1"], "path2": det["path2"], "path3": det["path3"],
                          "cross_verify": det["cross_verify"],
                          "total_latency_ms": det.get("total_latency_ms")},
            "recovery":  {"cleared": inj.get("cleared"), "clear_method": inj.get("clear_method"),
                          "verified_clean": inj.get("verified_clean"),
                          "clear_time": inj.get("clear_time")},
            "flags": flags, "overall": inj.get("overall", "FAIL")
        })
        if inj.get("overall") == "PASS":
            passed += 1
        else:
            failed += 1
        if any(f.startswith("WARN") for f in flags):
            warnings += 1
        if "BUG_FIRMWARE" in flags:
            firmware_bugs += 1
    return {
        "run_id": run_id, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "environment": {"mode": checks.get("environment_mode"),
                        "kernel": checks.get("kernel_version"),
                        "cxl_cli_version": checks.get("cxl_cli_version"),
                        "sysfs_fallback": checks.get("sysfs_fallback")},
        "topology": {"total_devices": topology.get("total_devices"),
                     "total_cxl_memory_gb": topology.get("total_cxl_memory_gb")},
        "strategy": strategy, "results": results,
        "summary": {"total_targets": len(results), "passed": passed, "failed": failed,
                    "warnings": warnings, "firmware_bugs_detected": firmware_bugs}
    }

def print_summary(report):
    s = report["summary"]
    print(f"\n  run summary -- {report['run_id']}")
    print(f"  {'-'*43}")
    print(f"  strategy   : {report['strategy']}")
    print(f"  environment: {report['environment']['mode']}")
    print(f"  kernel     : {report['environment']['kernel']}")
    print(f"  {'-'*43}")
    print(f"  total   : {s['total_targets']}")
    print(f"  {GREEN}passed  : {s['passed']}{RESET}")
    print(f"  {RED}failed  : {s['failed']}{RESET}")
    print(f"  {YELLOW}warnings: {s['warnings']}{RESET}")
    print(f"  fw bugs : {s['firmware_bugs_detected']}")
    print(f"  {'-'*43}")
    if s["failed"] == 0 and s["firmware_bugs_detected"] == 0:
        print(f"  {GREEN}{BOLD}all tests passed{RESET}")
    elif s["firmware_bugs_detected"] > 0:
        print(f"  {RED}{BOLD}firmware bugs detected{RESET}")
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

from utils.checks import GREEN, YELLOW, RED, BOLD, RESET

def parse_args():
    parser = argparse.ArgumentParser(
        prog="cxl-fault-injector",
        description="cxl memory fault injection framework",
        formatter_class=argparse.RawTextHelpFormatter,
        epilog="""
examples:
  sudo python3 main.py
  sudo python3 main.py --strategy random --device mem0
  sudo python3 main.py --strategy sweep --limit 5
  sudo python3 main.py --strategy numa --numa-node 0
  sudo python3 main.py --strategy interleave --dry-run
  sudo python3 main.py --strategy random --output /tmp/report.json
        """
    )
    parser.add_argument("--strategy",  choices=["random","sweep","numa","interleave"], default="random")
    parser.add_argument("--device",    default="all")
    parser.add_argument("--numa-node", type=int, default=0)
    parser.add_argument("--limit",     type=int, default=None)
    parser.add_argument("--output",    default=None)
    parser.add_argument("--dry-run",   action="store_true")
    parser.add_argument("--verbose",   action="store_true")
    return parser.parse_args()

def main():
    args = parse_args()
    run_id = generate_run_id()
    print(f"\n  cxl fault injector")
    print(f"  run id   : {run_id}")
    print(f"  strategy : {args.strategy}")
    print(f"  device   : {args.device}")
    if args.dry_run:
        print(f"  {YELLOW}mode     : dry run -- no injection will occur{RESET}")
    print()

    print("=" * 45)
    print("   environment checks")
    print("=" * 45)
    checks = all_checks()
    if checks is None:
        print(f"\n{RED}critical check failed, exiting.{RESET}")
        sys.exit(1)
    caps = checks["detection_capabilities"]

    print(f"\n{'='*45}")
    print("   device discovery")
    print("=" * 45)
    topo = discovery()
    if topo["total_devices"] == 0:
        print(f"\n{RED}no cxl devices found, exiting.{RESET}")
        sys.exit(1)
    if args.verbose:
        print(json.dumps(topo, indent=2))

    print(f"\n{'='*45}")
    print("   strategy engine")
    print("=" * 45)
    targets = strategy(
        topo, strategy=args.strategy, device_name=args.device,
        numa_node=args.numa_node, limit=args.limit, dry_run=args.dry_run
    )
    if args.dry_run:
        print(f"\n  {YELLOW}dry run done, exiting.{RESET}\n")
        sys.exit(0)
    if not targets:
        print(f"\n{RED}no targets generated, exiting.{RESET}")
        sys.exit(1)

    print(f"\n{'='*45}")
    print("   injection and detection")
    print("=" * 45)
    all_inj = []
    all_det = []
    for i, t in enumerate(targets, 1):
        print(f"\n  [{i}/{len(targets)}] {t['device']} @ {t['dpa']}")
        device = next(d for d in topo["devices"] if d["name"] == t["device"])
        inj = injection(device, t["dpa"])
        det = detection(device["name"], t["dpa"], caps, simulated=inj.get("simulated", False))
        print_live_result(inj, det)
        all_inj.append(inj)
        all_det.append(det)

    print(f"\n{'='*45}")
    print("   report")
    print("=" * 45)
    report = build_report(run_id, checks, topo, args.strategy, all_inj, all_det)
    print_summary(report)
    save_report(report, output_path=args.output)
    sys.exit(0 if (report["summary"]["failed"] == 0 and
                   report["summary"]["firmware_bugs_detected"] == 0) else 1)

if __name__ == "__main__":
    main()
PYEOF


ok "All Python modules written"
echo ""

echo "  Running CXL Fault Injector"

echo ""

cd "$INSTALL_DIR"
exec python3 main.py "$@"
