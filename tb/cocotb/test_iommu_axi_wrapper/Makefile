# Brendan Lynskey 2025
SIM = icarus
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(PWD)/../../../rtl/iommu_pkg.sv \
                  $(PWD)/../../../rtl/lru_tracker.sv \
                  $(PWD)/../../../rtl/iotlb.sv \
                  $(PWD)/../../../rtl/device_context_cache.sv \
                  $(PWD)/../../../rtl/io_ptw.sv \
                  $(PWD)/../../../rtl/io_permission_checker.sv \
                  $(PWD)/../../../rtl/fault_handler.sv \
                  $(PWD)/../../../rtl/iommu_reg_file.sv \
                  $(PWD)/../../../rtl/iommu_core.sv \
                  $(PWD)/../../../rtl/iommu_axi_wrapper.sv
TOPLEVEL = iommu_axi_wrapper
MODULE = test_iommu_axi_wrapper
COMPILE_ARGS = -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
