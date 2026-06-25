---
name: big-job
description: Run long-running shell commands (builds, tests, data pipelines, scraping, training runs, etc.) as detached background jobs via systemd transient units, with journal-based output capture and lifecycle management. Use this skill whenever the user asks you to run something that will take more than a few seconds — large test suites, long builds, batch processing, data migrations, ML training, or any command the user explicitly wants running "in the background". Also use it when you need to run multiple heavy commands in parallel without blocking. Trigger on phrases like "run in background", "long running", "don't wait for it", "kick off a build", "run tests and come back", "start a training run", "batch process", or any task where blocking the conversation would be annoying.
---

# Big Jobs

Run heavy or long-running shell commands as detached systemd transient services. Each job gets its own user unit with journal-based output, exit code tracking, and OOM protection. All units use the `bigjob-` prefix for easy filtering.

## Naming convention

Every job unit is named `bigjob-YYYYMMDD-HHMMSS-jobname` where:
- The timestamp is the current datetime (evaluate it yourself, do NOT use shell `$(date ...)`)
- `jobname` is a short kebab-case label describing the task (e.g. `train`, `build-frontend`, `run-tests`)

Example: `bigjob-20260305-143021-train`

Use `JOBNAME` as shorthand for the full unit name in commands below.

## Commands

### Start a job

By default, protect the machine with a hard cgroup memory cap: reserve 24 GiB for the OS, desktop, Docker, databases, and agent processes, then let the job use the rest. If the job exceeds the cap, systemd/kernel OOM-kills the job's unit instead of letting the whole machine thrash.

```bash
MEMORY_RESERVE_GB=24
TOTAL_MEMORY_GB=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)
MEMORY_MAX_GB=$((TOTAL_MEMORY_GB - MEMORY_RESERVE_GB))
[ "$MEMORY_MAX_GB" -lt 4 ] && MEMORY_MAX_GB=4

systemd-run --user \
  --unit=JOBNAME \
  --slice=bigjobs.slice \
  --remain-after-exit \
  -p MemoryAccounting=yes \
  -p MemoryMax="${MEMORY_MAX_GB}G" \
  -p MemorySwapMax=0 \
  -p OOMPolicy=kill \
  -p OOMScoreAdjust=500 \
  -p StandardOutput=journal \
  -p StandardError=journal \
  --working-directory=/absolute/path/to/project \
  -E PYTHONUNBUFFERED=1 \
  -- command arg1 arg2
```

- `MemoryMax` is a hard cgroup limit set to installed RAM minus `MEMORY_RESERVE_GB`; on a 122 GiB machine the default cap is about 98 GiB
- `MemorySwapMax=0` prevents the job cgroup from using swap if swap exists; with swap disabled globally, this is still harmless and explicit
- `OOMPolicy=kill` makes memory failure kill the unit rather than leave children behind
- `OOMScoreAdjust=500` biases kernel OOM selection toward big jobs over interactive/system processes
- `--slice=bigjobs.slice` groups heavy jobs together for easier inspection and future policy
- `--remain-after-exit` keeps the unit visible after the command finishes so we can check status and read output
- Output goes to the systemd journal, queryable with `journalctl`
- The unit is fully detached — survives agent restarts

After starting, tell the user the unit name, then **immediately** start waiting for the job (see below). Never just start a job and stop — always follow up with the wait command in the same turn.

### Wait for job (always do this after starting)

```bash
while [ "$(systemctl --user show -p SubState --value JOBNAME)" = "running" ]; do sleep 2; done; \
SUB=$(systemctl --user show -p SubState --value JOBNAME); \
RESULT=$(systemctl --user show -p Result --value JOBNAME); \
CODE=$(systemctl --user show -p ExecMainStatus --value JOBNAME); \
TAIL=$(journalctl --user -u JOBNAME -o cat --no-pager | tail -80); \
printf 'SubState=%s Result=%s ExecMainStatus=%s\n%s\n' "$SUB" "$RESULT" "$CODE" "$TAIL"
```

This polls until the command finishes, reports the final state/result/exit code, then dumps the last 80 lines of output. **This must always be run as a background Bash call immediately after starting a job.** The agent will be notified when the job finishes. If the job exceeds its memory cap, expect a nonzero status and often `Result=oom-kill` or an exit status such as 137.

### Check status

```bash
systemctl --user show -p SubState -p Result -p ExecMainStatus -p MemoryCurrent -p MemoryPeak JOBNAME
```

Prints named properties:
- `SubState`: `running` | `exited` | `failed`
- `Result`: `success` | `exit-code` | `oom-kill` | other systemd result
- `ExecMainStatus`: the exit code (0 = success)
- `MemoryCurrent`: current cgroup memory usage when available
- `MemoryPeak`: peak cgroup memory usage when available

### Read output

```bash
# Last 50 lines
journalctl --user -u JOBNAME -o cat --no-pager | tail -50

# All output
journalctl --user -u JOBNAME -o cat --no-pager

# Follow (live stream)
journalctl --user -u JOBNAME -o cat -f
```

### Kill a job

```bash
# Graceful (SIGTERM)
systemctl --user kill JOBNAME

# Force (SIGKILL)
systemctl --user kill -s KILL JOBNAME

# Stop entirely (also removes the transient unit)
systemctl --user stop JOBNAME
```

### List jobs

```bash
systemctl --user list-units 'bigjob-*' --all --no-pager
```

Shows all bigjob units with their state (running/exited/failed).

### Clean up finished jobs

```bash
# Stop a specific finished unit (removes it since it's transient)
systemctl --user stop JOBNAME

# Stop all finished (exited) bigjob units
systemctl --user list-units 'bigjob-*' --all --no-pager --plain \
  | awk '$4=="exited" {print $1}' \
  | xargs -r systemctl --user stop

# Reset any failed units
systemctl --user reset-failed 'bigjob-*'
```

## Guidelines

- **Always tell the user** the unit name after starting
- **Always wait immediately** — after starting a job, always run the wait loop as a background Bash call in the same turn. Never start a job without also starting to wait for it
- **Default to background** for anything > 30 seconds
- **Check exit codes** — don't assume success; read output on failure
- **Use `tail` for output** — output can be huge; don't dump everything unless needed
- **Memory safety** — keep the default all-but-24G cap unless the user explicitly asks for a different reserve; increase `MEMORY_RESERVE_GB` when the desktop, databases, Docker, or vLLM services must stay responsive
- **Working directory** — always pass `--working-directory` with an absolute path
- **Reconnection** — use `systemctl --user list-units 'bigjob-*'` to find jobs after restart
