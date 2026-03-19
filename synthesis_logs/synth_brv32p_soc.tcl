set_param general.maxThreads 4
set_param synth.elaboration.rodinMoreOptions {rt::set_parameter dissolveMemorySizeLimit 524288}
create_project -in_memory -part xc7a35tcpg236-1

set_property include_dirs {/home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/pkg} [current_fileset]
set_property generic {MEM_DEPTH=1024} [current_fileset]

read_verilog [list \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/core/alu.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/core/branch_predictor.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/core/brv32p_core.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/core/compressed_decoder.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/core/csr.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/core/decoder.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/core/hazard_unit.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/core/muldiv.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/core/regfile.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/cache/dcache.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/cache/icache.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/bus/axi_interconnect.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/bus/axi_periph_bridge.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/bus/axi_sram.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/periph/gpio.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/periph/timer.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/periph/uart.v \
    /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/rtl/brv32p_soc.v \
]

set xdc_file "/home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/synthesis_logs/clock.xdc"
set fp [open $xdc_file w]
puts $fp "create_clock -period 10.000 -name clk \[get_ports clk\]"
close $fp
read_xdc $xdc_file

synth_design -top brv32p_soc -part xc7a35tcpg236-1

report_utilization -file /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/synthesis_logs/utilization_brv32p_soc.rpt
report_timing_summary -file /home/brendan/synthesis_workspace/RISCV_RV32IMC_5stage/synthesis_logs/timing_brv32p_soc.rpt
