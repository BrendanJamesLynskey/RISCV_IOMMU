# Brendan Lynskey 2025
SIM = icarus
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(PWD)/../../../rtl/iommu_pkg.sv \
                  $(PWD)/../../../rtl/iommu_reg_file.sv
TOPLEVEL = iommu_reg_file
MODULE = test_iommu_reg_file
COMPILE_ARGS = -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
