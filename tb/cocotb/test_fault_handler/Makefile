# Brendan Lynskey 2025
SIM = icarus
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(PWD)/../../../rtl/iommu_pkg.sv \
                  $(PWD)/../../../rtl/fault_handler.sv
TOPLEVEL = fault_handler
MODULE = test_fault_handler
COMPILE_ARGS = -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
