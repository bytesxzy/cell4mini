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
# `exec` replaces this shell with the interpreter: one process, not two.
cd "$(dirname "$0")" || exit 1
exec luajit cell4.lua step
