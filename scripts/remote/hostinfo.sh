#!/usr/bin/env bash
# Print one JSON object describing this VM: CPU model, vCPUs, memory, kernel, OS, the Azure physical host name
# (Hyper-V KVP pool, its prefix names the datacenter), the data mount and its block devices.
set -euo pipefail
exec python3 - <<'PY'
import json, os, platform, subprocess

def out(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception as err:
        return f"error: {err}"

def kvp(key):
    path = "/var/lib/hyperv/.kvp_pool_3"
    try:
        data = open(path, "rb").read()
    except OSError:
        return None
    for off in range(0, len(data) - 2559, 2560):
        k = data[off:off + 512].split(b"\0", 1)[0].decode(errors="replace")
        if k == key:
            return data[off + 512:off + 2560].split(b"\0", 1)[0].decode(errors="replace")
    return None

data = os.environ.get("BENCH_DATA", "/mnt/data")
print(json.dumps({
    "hostname": platform.node(),
    "cpu_model": out("lscpu | sed -n 's/^Model name: *//p' | head -1"),
    "vcpus": os.cpu_count(),
    "memory_kb": int(out("awk '/MemTotal/ {print $2}' /proc/meminfo") or 0),
    "kernel": platform.release(),
    "os": out(". /etc/os-release && echo \"$PRETTY_NAME\""),
    "physical_host": kvp("PhysicalHostName"),
    "vm_size": out("curl -s -m 3 -H Metadata:true 'http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text'") or None,
    "data_mount": out(f"findmnt -n -o SOURCE,FSTYPE,OPTIONS {data}") or None,
    "data_size": out(f"df -h --output=size {data} 2>/dev/null | tail -1") or None,
    "block_devices": out("lsblk -dno NAME,MODEL,SIZE,TRAN | grep -v '^loop'").splitlines(),
    "schedulers": {d: out(f"cat /sys/block/{d}/queue/scheduler") for d in sorted(os.listdir("/sys/block")) if d.startswith(("nvme", "md"))},
}, indent=1))
PY
