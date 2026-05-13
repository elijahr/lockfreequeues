#!/usr/bin/env python3
"""Run a command with a hard wall-clock timeout. On hang, capture a
debug bundle (per-thread stacks, ps snapshot, vmmap summary on macOS,
partial stdout/stderr), kill the process group, and surface a tail of
each artifact to stderr so the dispatching agent has signal without
reading multi-MB files.

Cross-platform notes:
- macOS: uses ``sample`` (Apple's per-thread stack sampler) plus ``ps``
  and ``vmmap``. All three ship with the OS.
- Linux: falls back to ``gdb -batch`` (preferred — gives the same
  per-thread backtraces as ``sample``) or ``gstack`` if gdb is missing.
  ``ps -L`` substitutes for ``ps -M``. ``vmmap`` is skipped (no
  equivalent on Linux that ships by default; ``/proc/<pid>/maps`` is
  too verbose to be useful as a hang summary).
- Other platforms: best-effort — only stdout/stderr capture is
  guaranteed.

Usage:
    run_with_hang_sample.py <timeout_s> <bundle_dir> <label> -- <cmd...>

Exits with the child's return code on success, 124 on hang.
"""
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time

timeout_s = float(sys.argv[1])
sample_dir = pathlib.Path(sys.argv[2])
sample_dir.mkdir(parents=True, exist_ok=True)
label = sys.argv[3]
assert sys.argv[4] == "--"
cmd = sys.argv[5:]

ts = int(time.time())
bundle = sample_dir / f"{label}_{ts}"
bundle.mkdir(parents=True, exist_ok=True)
log_path = bundle / "stdout.log"


def _which(name: str) -> str:
    """Return absolute path of executable or empty string."""
    return shutil.which(name) or ""


def _capture_macos_hang(pid: int, bundle: pathlib.Path) -> None:
    # 1. sample (2 sec of all-thread stacks)
    if _which("sample"):
        subprocess.run(
            ["sample", str(pid), "2", "-file", str(bundle / "sample.txt")],
            timeout=15,
            capture_output=True,
        )
    # 2. ps snapshot - state, threads, %cpu, rss
    with open(bundle / "ps.txt", "wb") as f:
        subprocess.run(["ps", "-M", "-p", str(pid)], stdout=f, timeout=5)
    # 3. vmmap summary (small, useful for "is it ballooning")
    if _which("vmmap"):
        with open(bundle / "vmmap.txt", "wb") as f:
            subprocess.run(["vmmap", "-summary", str(pid)], stdout=f, timeout=10)


def _capture_linux_hang(pid: int, bundle: pathlib.Path) -> None:
    # 1. per-thread stacks via gdb (preferred) or gstack fallback.
    if _which("gdb"):
        with open(bundle / "sample.txt", "wb") as f:
            subprocess.run(
                [
                    "gdb",
                    "-batch",
                    "-p",
                    str(pid),
                    "-ex",
                    "thread apply all bt",
                    "-ex",
                    "detach",
                    "-ex",
                    "quit",
                ],
                stdout=f,
                stderr=subprocess.STDOUT,
                timeout=30,
            )
    elif _which("gstack"):
        with open(bundle / "sample.txt", "wb") as f:
            subprocess.run(["gstack", str(pid)], stdout=f, timeout=15)
    # 2. ps snapshot - threads, state, %cpu, rss. ``-L`` substitutes for
    # ``-M`` on Linux.
    with open(bundle / "ps.txt", "wb") as f:
        subprocess.run(
            ["ps", "-L", "-o", "pid,tid,stat,pcpu,rss,comm", "-p", str(pid)],
            stdout=f,
            timeout=5,
        )
    # 3. vmmap has no Linux equivalent that ships by default. Skip.


def _capture_generic_hang(pid: int, bundle: pathlib.Path) -> None:
    # Best-effort: just write a marker file noting that no per-thread
    # stack capture tool is available on this platform.
    with open(bundle / "sample.txt", "w") as f:
        f.write(
            f"no per-thread stack tool available on platform {sys.platform}\n"
        )


# Use a real file (not PIPE) so the child's prints land on disk
# immediately and survive a SIGKILL.
log_f = open(log_path, "wb", buffering=0)
env = dict(os.environ)
env["PYTHONUNBUFFERED"] = "1"
env["NIMOUT_FLUSH"] = "1"
p = subprocess.Popen(
    cmd,
    stdout=log_f,
    stderr=subprocess.STDOUT,
    env=env,
    start_new_session=True,
)
rc = None
try:
    rc = p.wait(timeout=timeout_s)
except subprocess.TimeoutExpired:
    if sys.platform == "darwin":
        _capture_macos_hang(p.pid, bundle)
    elif sys.platform.startswith("linux"):
        _capture_linux_hang(p.pid, bundle)
    else:
        _capture_generic_hang(p.pid, bundle)
    # Kill the whole process group.
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except Exception:
        pass
    try:
        p.wait(timeout=5)
    except Exception:
        pass
    log_f.close()
    sys.stderr.write(
        f"\n=== HANG label={label} pid={p.pid} timeout={timeout_s}s "
        f"bundle={bundle} ===\n"
    )
    for name in ("stdout.log", "sample.txt", "ps.txt", "vmmap.txt"):
        f = bundle / name
        if not f.exists():
            continue
        data = f.read_bytes()
        sys.stderr.write(f"\n--- {name} (size={len(data)}) tail ---\n")
        sys.stderr.write(data[-2000:].decode("utf-8", errors="replace"))
    sys.exit(124)
log_f.close()
if rc != 0:
    data = log_path.read_bytes()
    sys.stderr.write(
        f"\n=== FAIL label={label} rc={rc} log={log_path} ===\n"
    )
    sys.stderr.write(data[-2000:].decode("utf-8", errors="replace"))
sys.exit(rc)
