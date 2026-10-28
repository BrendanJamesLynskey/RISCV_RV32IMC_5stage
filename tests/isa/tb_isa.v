`timescale 1ns / 1ps
// ============================================================================
// tb_isa.v — runs one riscv-tests ISA test on the BRV32P SoC
// ============================================================================
// Plusargs:
//   +hex=<file>        program image (one 32-bit word per line), loaded at 0
//   +tohost=<hex>      address of the test's tohost word
//   +trace=<file>      optional: write the retire trace as a commit log
//   +timeout=<cycles>  optional: default 200000
// The test stores 1 to tohost on success, or (testnum << 1) | 1 on failure;
// the store is seen on the core's retire trace. Prints one line:
//   RESULT PASS|FAIL|TIMEOUT <cycles> cycles <n> retired [failing test case]
// ============================================================================
module tb_isa;

  reg         clk;
  reg         rst_n;
  wire [31:0] gpio_out;
  wire        uart_tx;

  initial clk = 0;
  always #5 clk = ~clk;

  brv32p_soc #(
    .MEM_DEPTH (8192),
    .INIT_FILE (""),
    .RESET_PC  (32'h8000_0000)      // tests are linked at 0x8000_0000, like Spike's RAM
  ) dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .gpio_in  (32'b0),
    .gpio_out (gpio_out),
    .uart_rx  (1'b1),
    .uart_tx  (uart_tx)
  );

  `define CORE dut.u_core

  reg [8*512-1:0] hex_file, trace_file;   // paths up to 512 characters
  reg [31:0]   tohost;
  integer      timeout, cycles, retired, trace_fd, hex_fd;

  initial begin
    if (!$value$plusargs("hex=%s", hex_file)) begin
      $display("RESULT FAIL 0 cycles 0 retired (no +hex given)");
      $finish;
    end
    if (!$value$plusargs("tohost=%h", tohost)) begin
      $display("RESULT FAIL 0 cycles 0 retired (no +tohost given)");
      $finish;
    end
    if (!$value$plusargs("timeout=%d", timeout)) timeout = 200000;
    trace_fd = 0;
    if ($value$plusargs("trace=%s", trace_file)) trace_fd = $fopen(trace_file, "w");

    // $readmemh only warns if the file is missing, which would leave the
    // memory full of NOPs; fail loudly instead
    hex_fd = $fopen(hex_file, "r");
    if (hex_fd == 0) begin
      $display("RESULT FAIL 0 cycles 0 retired (cannot open %0s)", hex_file);
      $finish;
    end
    $fclose(hex_fd);

    // Load after the SRAM's own initial block has filled memory with NOPs
    #1 $readmemh(hex_file, dut.u_sram.mem);
  end

  // Commit log: one line per retired instruction, in Spike's --log-commits
  // style: core 0, privilege 3 (M), pc, encoding, then the register write
  // and/or the store. Called from the checking block below, so the final
  // tohost store is logged before the run ends.
  task log_retire;
  begin
    if (`CORE.retire_insn[31:16] == 16'b0 && `CORE.retire_insn[1:0] != 2'b11)
      $fwrite(trace_fd, "core   0: 3 0x%08h (0x%04h)", `CORE.retire_pc, `CORE.retire_insn[15:0]);
    else
      $fwrite(trace_fd, "core   0: 3 0x%08h (0x%08h)", `CORE.retire_pc, `CORE.retire_insn);
    if (`CORE.retire_rd_we)
      $fwrite(trace_fd, " x%0d%s0x%08h", `CORE.retire_rd_addr,
              (`CORE.retire_rd_addr < 10) ? "  " : " ", `CORE.retire_rd_wdata);
    if (`CORE.retire_mem_we)
      case (`CORE.retire_mem_width)
        2'd0:    $fwrite(trace_fd, " mem 0x%08h 0x%02h", `CORE.retire_mem_addr, `CORE.retire_mem_wdata[7:0]);
        2'd1:    $fwrite(trace_fd, " mem 0x%08h 0x%04h", `CORE.retire_mem_addr, `CORE.retire_mem_wdata[15:0]);
        default: $fwrite(trace_fd, " mem 0x%08h 0x%08h", `CORE.retire_mem_addr, `CORE.retire_mem_wdata);
      endcase
    $fwrite(trace_fd, "\n");
  end
  endtask

  initial begin
    rst_n   = 0;
    cycles  = 0;
    retired = 0;
    repeat (10) @(posedge clk);
    rst_n = 1;
  end

  always @(posedge clk) if (rst_n) begin
    cycles = cycles + 1;
    if (`CORE.retire_valid) begin
      retired = retired + 1;
      if (trace_fd != 0) log_retire;
      if (`CORE.retire_mem_we && `CORE.retire_mem_addr == tohost) begin
        if (`CORE.retire_mem_wdata == 32'd1)
          $display("RESULT PASS %0d cycles %0d retired", cycles, retired);
        else if (`CORE.retire_mem_wdata == ((1337 << 1) | 1))
          $display("RESULT FAIL %0d cycles %0d retired unexpected trap, mcause=%0d mepc=0x%08h",
                   cycles, retired, `CORE.u_csr.mcause, `CORE.u_csr.mepc);
        else
          $display("RESULT FAIL %0d cycles %0d retired test case %0d",
                   cycles, retired, `CORE.retire_mem_wdata >> 1);
        if (trace_fd != 0) $fclose(trace_fd);
        $finish;
      end
    end
    if (cycles >= timeout) begin
      $display("RESULT TIMEOUT %0d cycles %0d retired (last pc 0x%08h)", cycles, retired, `CORE.retire_pc);
      if (trace_fd != 0) $fclose(trace_fd);
      $finish;
    end
  end

endmodule
