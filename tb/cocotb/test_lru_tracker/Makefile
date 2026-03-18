# Brendan Lynskey 2025
SIM = icarus
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(PWD)/../../../rtl/iommu_pkg.sv \
                  $(PWD)/../../../rtl/lru_tracker.sv
TOPLEVEL = lru_tracker
MODULE = test_lru_tracker
COMPILE_ARGS = -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
