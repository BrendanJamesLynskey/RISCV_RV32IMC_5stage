`timescale 1ns / 1ps
// ============================================================================
// tb_netlist.v — runs a program on the SoC's placed-and-routed funcsim netlist
// ============================================================================
// A netlist has only the SoC's ports, so unlike tb_isa.v this cannot see the
// core's retire trace or load the SRAM: the program is the SRAM's initial image
// (the netlist was built with it), and it reports on the GPIO pins (1 pass,
// 2 fail; saif_polymul.c built with -DNETLIST). Plusarg +timeout=<cycles>.
// Prints: RESULT PASS|FAIL|TIMEOUT <cycles> cycles
// ============================================================================
module tb_netlist;

  reg         clk;
  reg         rst_n;
  wire [31:0] gpio_out;
  wire        uart_tx;
  integer     cycles, timeout;

  initial clk = 0;
  always #5 clk = ~clk;

  brv32p_soc dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .gpio_in  (32'b0),
    .gpio_out (gpio_out),
    .uart_rx  (1'b1),
    .uart_tx  (uart_tx)
  );

  initial begin
    if (!$value$plusargs("timeout=%d", timeout)) timeout = 2000000;
    rst_n  = 0;
    cycles = 0;
    repeat (10) @(posedge clk);
    rst_n = 1;
  end

  always @(posedge clk) if (rst_n) begin
    cycles = cycles + 1;
    if (gpio_out != 0) begin
      $display("RESULT %0s %0d cycles", gpio_out == 32'd1 ? "PASS" : "FAIL", cycles);
      $finish;
    end
    if (cycles >= timeout) begin
      $display("RESULT TIMEOUT %0d cycles", cycles);
      $finish;
    end
  end

endmodule
