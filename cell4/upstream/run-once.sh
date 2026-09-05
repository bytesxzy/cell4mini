#!/bin/sh
export CELL4_CANDIDATES=1
export CELL4_SECONDS=1
export CELL4_NODES=800
export CELL4_EXTERNAL_CAP=20
cd "$(dirname "$0")" || exit 1
nice -n 19 timeout 240 /home/cellgdty/.local/bin/luajit cell4.lua step
rc=$?
[ "$rc" -eq 124 ] && /home/cellgdty/.local/bin/luajit cell4.lua unlock force >/dev/null 2>&1
exit $rc
