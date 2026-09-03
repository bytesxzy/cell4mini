#!/bin/sh
# One generation, then exit. No loop, no daemon, no background process.
#
# Every path in cell4.lua is relative to the working directory, so the `cd` is
# not optional: without it the program would start a second, empty installation
# wherever the scheduler happens to begin. cell4.lua refuses to run in that case
# rather than silently resetting, and this script is the fix.
#
# Namecheap cPanel cron (every 30 minutes):
#   */30 * * * * /home/USER/cell4/run-once.sh >> /home/USER/cell4/cron.log 2>&1
#
# Throttle for a constrained or shared host. Uncomment and tune; see NAMECHEAP.md.
# These change how much work ONE invocation does. They do not touch the
# acceptance rule -- alpha, bootstrap_reps and the held-out split size are
# deliberately not settable from the environment.
# export CELL4_CANDIDATES=1        # candidates per generation (default 4)
# export CELL4_SECONDS=1           # per-task solver wall clock (default 3)
# export CELL4_NODES=800           # per-task solver node budget (default 3000)
# export CELL4_EXTERNAL_CAP=20     # ARC tasks per generation (default 60)

# `exec` replaces this shell with the interpreter: one process, not two.
# On shared hosting, prefer:  exec nice -n 19 timeout 300 luajit cell4.lua step
# so this job yields the core and can never be the long-running process that
# trips a limit. A killed run leaves a lock; `cell4.lua unlock` clears it.
cd "$(dirname "$0")" || exit 1
exec luajit cell4.lua step
