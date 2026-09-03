#!/bin/sh
# One generation, then exit. No loop, no daemon, no background process.
#
# Every path in cell4.lua is relative to the working directory, so the `cd` is
# not optional: without it the program would start a second, empty installation
# wherever the scheduler happens to begin. cell4.lua refuses to run in that case
# rather than silently resetting, and this script is the fix.
#
# Namecheap cPanel cron (every 6 minutes). The redirect is not optional: cPanel
# emails the output of every run that produces any, which at this interval is 240
# emails a day. Set CELL4_TIMEOUT below the interval.
#   */6 * * * * /home/USER/cell4/run-once.sh >> /home/USER/cell4/cron.log 2>&1
#
# Throttle for a constrained or shared host. Uncomment and tune; see NAMECHEAP.md.
# These change how much work ONE invocation does. They do not touch the
# acceptance rule -- alpha, bootstrap_reps and the held-out split size are
# deliberately not settable from the environment.
# export CELL4_CANDIDATES=1        # candidates per generation (default 4)
# export CELL4_SECONDS=1           # per-task solver wall clock (default 3)
# export CELL4_NODES=800           # per-task solver node budget (default 3000)
# export CELL4_EXTERNAL_CAP=20     # ARC tasks per generation (default 60)

# Which interpreter. cron runs with a minimal PATH, so if luajit lives somewhere
# like ~/bin you must say so here (or set CELL4_LUA in the cron command).
CELL4_LUA=${CELL4_LUA:-luajit}

# Optional wall-clock ceiling, in seconds. 0 (the default) means no ceiling: the
# lock already stops two runs from overlapping, so a long generation simply makes
# the next scheduled run exit immediately instead of piling up.
#
# Set it on a host that kills long processes. It must be LOWER than your cron
# interval, and the recovery below is why: `timeout` kills the interpreter part
# way through, which leaves the lock directory behind, and without clearing it
# every run for the next hour would refuse. Exit code 124 means and only means
# "timeout stopped it", so at that point nothing is holding the lock and forcing
# it open is correct rather than a guess.
CELL4_TIMEOUT=${CELL4_TIMEOUT:-0}

cd "$(dirname "$0")" || exit 1

if [ "${CELL4_TIMEOUT:-0}" -gt 0 ] 2>/dev/null && command -v timeout >/dev/null 2>&1; then
  nice -n 19 timeout "$CELL4_TIMEOUT" "$CELL4_LUA" cell4.lua step
  rc=$?
  if [ "$rc" -eq 124 ]; then
    echo "cell4: generation exceeded ${CELL4_TIMEOUT}s and was stopped; clearing its lock" >&2
    "$CELL4_LUA" cell4.lua unlock force >/dev/null 2>&1
  fi
  exit "$rc"
fi

# `exec` replaces this shell with the interpreter: one process, not two.
exec "$CELL4_LUA" cell4.lua step
