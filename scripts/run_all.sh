#!/bin/bash
# Brendan Lynskey 2025
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "=== Running SystemVerilog Tests ==="
bash "$SCRIPT_DIR/run_all_sv.sh"
SV_RESULT=$?
echo ""
echo "=== Running CocoTB Tests ==="
bash "$SCRIPT_DIR/run_all_cocotb.sh"
COCOTB_RESULT=$?
echo ""
if [ $SV_RESULT -eq 0 ] && [ $COCOTB_RESULT -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED"
    exit 1
fi
