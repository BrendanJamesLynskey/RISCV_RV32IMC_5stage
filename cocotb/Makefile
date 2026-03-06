TOPLEVEL_LANG = verilog
VERILOG_SOURCES = \
    $(PWD)/../rtl/core/alu.v \
    $(PWD)/../rtl/core/regfile.v \
    $(PWD)/../rtl/core/compressed_decoder.v \
    $(PWD)/../rtl/core/decoder.v \
    $(PWD)/../rtl/core/branch_predictor.v \
    $(PWD)/../rtl/core/hazard_unit.v \
    $(PWD)/../rtl/core/muldiv.v \
    $(PWD)/../rtl/core/csr.v \
    $(PWD)/../rtl/core/brv32p_core.v \
    $(PWD)/../rtl/cache/icache.v \
    $(PWD)/../rtl/cache/dcache.v \
    $(PWD)/../rtl/bus/axi_interconnect.v \
    $(PWD)/../rtl/bus/axi_sram.v \
    $(PWD)/../rtl/bus/axi_periph_bridge.v \
    $(PWD)/../rtl/periph/gpio.v \
    $(PWD)/../rtl/periph/uart.v \
    $(PWD)/../rtl/periph/timer.v \
    $(PWD)/../rtl/brv32p_soc.v

TOPLEVEL = brv32p_soc
COCOTB_TEST_MODULES = test_brv32p_soc
SIM ?= icarus

ifeq ($(SIM),icarus)
  COMPILE_ARGS += -g2005
  COMPILE_ARGS += -I$(PWD)/../rtl/pkg
  COMPILE_ARGS += -I$(PWD)/../rtl/core
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
