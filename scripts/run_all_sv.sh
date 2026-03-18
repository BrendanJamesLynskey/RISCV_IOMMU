#!/bin/bash
# Brendan Lynskey 2025
set -e

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RTL_DIR="$PROJ_DIR/rtl"
TB_DIR="$PROJ_DIR/tb/sv"

PASS=0
FAIL=0

# Define compilation units (testbench : required RTL files)
declare -A TESTS
TESTS[tb_lru_tracker]="iommu_pkg.sv lru_tracker.sv"
TESTS[tb_iotlb]="iommu_pkg.sv lru_tracker.sv iotlb.sv"
TESTS[tb_device_context_cache]="iommu_pkg.sv lru_tracker.sv device_context_cache.sv"
TESTS[tb_io_ptw]="iommu_pkg.sv io_ptw.sv"
TESTS[tb_io_permission_checker]="iommu_pkg.sv io_permission_checker.sv"
TESTS[tb_fault_handler]="iommu_pkg.sv fault_handler.sv"
TESTS[tb_iommu_reg_file]="iommu_pkg.sv fault_handler.sv iommu_reg_file.sv"
TESTS[tb_iommu_core]="iommu_pkg.sv lru_tracker.sv iotlb.sv device_context_cache.sv io_ptw.sv io_permission_checker.sv fault_handler.sv iommu_core.sv"
TESTS[tb_iommu_axi_wrapper]="iommu_pkg.sv lru_tracker.sv iotlb.sv device_context_cache.sv io_ptw.sv io_permission_checker.sv fault_handler.sv iommu_reg_file.sv iommu_core.sv iommu_axi_wrapper.sv"

for TB_NAME in "${!TESTS[@]}"; do
    RTL_FILES=""
    for f in ${TESTS[$TB_NAME]}; do
        RTL_FILES="$RTL_FILES $RTL_DIR/$f"
    done

    echo "========================================"
    echo "Compiling $TB_NAME..."
    iverilog -g2012 -o "${TB_NAME}.vvp" $RTL_FILES "$TB_DIR/${TB_NAME}.sv"

    echo "Running $TB_NAME..."
    if vvp "${TB_NAME}.vvp" | tee "${TB_NAME}.log" | grep -q "ALL TESTS PASSED"; then
        echo ">>> $TB_NAME: PASSED"
        PASS=$((PASS + 1))
    else
        echo ">>> $TB_NAME: FAILED"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "========================================"
echo "SV Test Summary: $PASS passed, $FAIL failed out of $((PASS+FAIL))"
echo "========================================"

[ $FAIL -eq 0 ] && exit 0 || exit 1
