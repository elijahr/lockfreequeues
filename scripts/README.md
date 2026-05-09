# scripts

Operational helper scripts for working on lockfreequeues.

## run_with_hang_sample.py

Runs a command under a hard wall-clock timeout and, when the command
hangs past the timeout, captures a debug bundle (per-thread stacks via
`sample` on macOS or `gdb -batch` / `gstack` on Linux, plus `ps` and
`vmmap` snapshots on platforms where those exist) before SIGKILL'ing
the process group. Stdout/stderr are redirected to a bundle log file,
and the bundle directory path is surfaced on stderr along with a tail
of each artifact so the dispatching agent gets actionable signal
without reading multi-MB files.

This is the standard wrapper for invoking any threaded test that has
historically livelocked or deadlocked (in particular,
`tests/t_unbounded_sipmuc_threaded.nim` and
`tests/t_unbounded_sipmuc_threaded_stress.nim`). Use it for
intermittent-bug triage rather than letting a hung test consume CI
minutes silently.

### Usage

```
python3 scripts/run_with_hang_sample.py <timeout_s> <bundle_dir> <label> -- <cmd...>
```

- `timeout_s`: seconds to wait before declaring the command hung.
- `bundle_dir`: parent directory under which a per-run subdirectory is
  created (`<label>_<unix_ts>/`).
- `label`: short tag included in the subdirectory name and in the hang
  banner on stderr.
- `--`: separator; everything after is the command to run.

Exit code is the child process's return code on success, or `124` on a
timeout-driven kill.
