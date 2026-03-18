#!/bin/bash
# Brendan Lynskey 2025
set -e

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COCOTB_DIR="$PROJ_DIR/tb/cocotb"

PASS=0
FAIL=0

for TEST_DIR in "$COCOTB_DIR"/test_*/; do
    TEST_NAME=$(basename "$TEST_DIR")
    echo "========================================"
    echo "Running CocoTB: $TEST_NAME..."
    cd "$TEST_DIR"
    if make SIM=icarus 2>&1 | tee "$TEST_NAME.log" | grep -q "passed"; then
        echo ">>> $TEST_NAME: PASSED"
        PASS=$((PASS + 1))
    else
        echo ">>> $TEST_NAME: FAILED"
        FAIL=$((FAIL + 1))
    fi
    cd "$PROJ_DIR"
done

echo ""
echo "========================================"
echo "CocoTB Test Summary: $PASS passed, $FAIL failed out of $((PASS+FAIL))"
echo "========================================"

[ $FAIL -eq 0 ] && exit 0 || exit 1
