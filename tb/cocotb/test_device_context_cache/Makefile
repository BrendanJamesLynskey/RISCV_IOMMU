# Brendan Lynskey 2025
SIM = icarus
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(PWD)/../../../rtl/iommu_pkg.sv \
                  $(PWD)/../../../rtl/lru_tracker.sv \
                  $(PWD)/../../../rtl/device_context_cache.sv
TOPLEVEL = device_context_cache
MODULE = test_device_context_cache
COMPILE_ARGS = -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
