# Brendan Lynskey 2025
SIM = icarus
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(PWD)/../../../rtl/iommu_pkg.sv \
                  $(PWD)/../../../rtl/io_permission_checker.sv
TOPLEVEL = io_permission_checker
MODULE = test_io_permission_checker
COMPILE_ARGS = -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
