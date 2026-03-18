# Brendan Lynskey 2025
SIM = icarus
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(PWD)/../../../rtl/iommu_pkg.sv \
                  $(PWD)/../../../rtl/io_ptw.sv
TOPLEVEL = io_ptw
MODULE = test_io_ptw
COMPILE_ARGS = -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
