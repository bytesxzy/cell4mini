#!/usr/bin/env sh
# Runs every cell4 test suite. From the repo root: sh tests/run_all.sh
#
# The Lua suite covers the runtime; the Python suite covers the trainer-side
# exporter. They meet at tests/fixtures/golden_policy.cell4, which both sides
# check independently - that fixture is what stops the two implementations
# drifting into being self-consistently wrong about the format.
set -e
cd "$(dirname "$0")/.."

LUA=${LUA:-lua5.3}
PYTHON=${PYTHON:-python3}

echo "== runtime (Lua) =="
"$LUA" tests/cell4_smoke_test.lua

echo "== exporter (Python) =="
if command -v "$PYTHON" >/dev/null 2>&1; then
	"$PYTHON" tests/test_export_policy.py
else
	echo "SKIPPED: $PYTHON not found (the Lua suite still checks the golden fixture)"
fi

echo "== all suites passed =="
