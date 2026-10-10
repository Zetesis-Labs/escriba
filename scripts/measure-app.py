#!/usr/bin/env python3
import argparse
import datetime
import json
import pathlib
import re
import subprocess
import tempfile
import time


def running_processes():
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,rss=,comm="], text=True
    )
    processes = {}
    for line in output.splitlines():
        pid, parent, rss, executable = line.strip().split(maxsplit=3)
        processes[int(pid)] = {
            "parent": int(parent),
            "rss_bytes": int(rss) * 1024,
            "executable": executable,
        }
    return processes


def app_processes(bundle):
    processes = running_processes()
    executable = str(bundle / "Contents/MacOS/escriba-tauri")
    matches = [pid for pid, info in processes.items() if info["executable"] == executable]
    if len(matches) != 1:
        raise RuntimeError("Debe estar abierta exactamente una instancia del bundle elegido")
    main = matches[0]
    listing = subprocess.check_output(["lsappinfo", "list"], text=True)
    blocks = re.split(r"(?m)^\s*\d+\) ", listing)
    app = next((block for block in blocks if re.search(rf"pid = {main}\b", block)), "")
    coalition = re.search(r"coalition: \d+\s*\{([^}]+)\}", app)
    if coalition is None:
        raise RuntimeError("No se pudo identificar la coalición de Escriba y su WebKit")
    associated = {int(pid) for pid in coalition.group(1).split()}
    selected = {
        pid: info for pid, info in processes.items()
        if pid == main or info["parent"] == main
        or (pid in associated and "com.apple.WebKit." in info["executable"])
    }
    return main, selected


def sample(bundle):
    main, processes = app_processes(bundle)
    with tempfile.TemporaryDirectory(prefix="escriba-footprint-") as directory:
        output = pathlib.Path(directory) / "footprint.json"
        command = ["footprint", "--noCategories", "--swapped", "-j", str(output)]
        for pid in processes:
            command.extend(["-p", str(pid)])
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
        memory = json.loads(output.read_text())
    if memory.get("errors") or memory.get("warnings"):
        raise RuntimeError(f"Medición incompleta: {memory.get('errors')} {memory.get('warnings')}")
    measured = memory["processes"]
    if {item["pid"] for item in measured} != set(processes):
        raise RuntimeError("Cambió el conjunto de procesos durante la medición")
    return {
        "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "main_pid": main,
        "footprint_bytes": sum(item["footprint"] for item in measured),
        "rss_bytes": sum(info["rss_bytes"] for info in processes.values()),
        "processes": measured,
    }


def main():
    parser = argparse.ArgumentParser(description="Mide Escriba y sus auxiliares sin leer la biblioteca")
    parser.add_argument("--bundle", type=pathlib.Path, default=pathlib.Path("/Applications/Escriba.app"))
    parser.add_argument("--duration", type=float, default=300)
    parser.add_argument("--interval", type=float, default=30)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.duration < 0 or args.interval <= 0:
        parser.error("La duración debe ser no negativa y el intervalo positivo")
    bundle = args.bundle.resolve(strict=True)
    files = [path for path in bundle.rglob("*") if path.is_file() and not path.is_symlink()]
    report = {
        "bundle": str(bundle),
        "bundle_bytes": sum(path.stat().st_size for path in files),
        "executables": {
            path.name: path.stat().st_size for path in (bundle / "Contents/MacOS").iterdir()
            if path.is_file()
        },
        "samples": [],
    }
    start = time.monotonic()
    while True:
        measurement = sample(bundle)
        measurement["elapsed_seconds"] = round(time.monotonic() - start, 2)
        if report["samples"] and measurement["main_pid"] != report["samples"][0]["main_pid"]:
            raise RuntimeError("Escriba se reinició durante la medición")
        report["samples"].append(measurement)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(f"{measurement['elapsed_seconds']:.0f}s: {measurement['footprint_bytes'] / 1048576:.2f} MiB de footprint, "
              f"{measurement['rss_bytes'] / 1048576:.2f} MiB de RSS", flush=True)
        remaining = args.duration - (time.monotonic() - start)
        if remaining <= 0:
            break
        time.sleep(min(args.interval, remaining))


if __name__ == "__main__":
    main()
