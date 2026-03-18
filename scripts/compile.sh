#!/bin/bash
# Brendan Lynskey 2025
PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RTL_DIR="$PROJ_DIR/rtl"

echo "Compiling all RTL..."
iverilog -g2012 -o /dev/null \
    "$RTL_DIR/iommu_pkg.sv" \
    "$RTL_DIR/lru_tracker.sv" \
    "$RTL_DIR/iotlb.sv" \
    "$RTL_DIR/device_context_cache.sv" \
    "$RTL_DIR/io_ptw.sv" \
    "$RTL_DIR/io_permission_checker.sv" \
    "$RTL_DIR/fault_handler.sv" \
    "$RTL_DIR/iommu_reg_file.sv" \
    "$RTL_DIR/iommu_core.sv" \
    "$RTL_DIR/iommu_axi_wrapper.sv"

echo "Compilation successful — no syntax errors."
