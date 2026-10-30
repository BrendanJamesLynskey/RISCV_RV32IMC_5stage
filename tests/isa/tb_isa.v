`timescale 1ns / 1ps
// ============================================================================
// tb_isa.v — runs one riscv-tests ISA test on the BRV32P SoC
// ============================================================================
// Plusargs:
//   +hex=<file>        program image (one 32-bit word per line), loaded at 0
//   +tohost=<hex>      address of the test's tohost word
//   +trace=<file>      optional: write the retire trace as a commit log
//   +timeout=<cycles>  optional: default 200000
//   +pipe=<file>       optional: write a per-cycle pipeline trace (what each
//                      stage holds and the hazard unit's decisions), read by
//                      scripts/pipeview.py
// The test stores 1 to tohost on success, or (testnum << 1) | 1 on failure;
// the store is seen on the core's retire trace. Prints one line:
//   RESULT PASS|FAIL|TIMEOUT <cycles> cycles <n> retired [failing test case]
// ============================================================================
module tb_isa;

  reg         clk;
  reg         rst_n;
  wire [31:0] gpio_out;
  wire        uart_tx;

`ifndef TB_MEM_DEPTH
`define TB_MEM_DEPTH 8192
`endif

  initial clk = 0;
  always #5 clk = ~clk;

  brv32p_soc #(
    .MEM_DEPTH (`TB_MEM_DEPTH),     // words; the benchmarks build with 16384 (64 KB)
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

  reg [8*512-1:0] hex_file, trace_file, pipe_file;   // paths up to 512 characters
  reg [31:0]   tohost;
  integer      timeout, cycles, retired, trace_fd, hex_fd, pipe_fd;

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
    pipe_fd = 0;
    if ($value$plusargs("pipe=%s", pipe_file)) begin
      pipe_fd = $fopen(pipe_file, "w");
      $fwrite(pipe_fd, "# brv32p pipe v1: cycle pc_if fetch_valid straddle imem_stall pred_taken");
      $fwrite(pipe_fd, " | valid_id pc_id raw_id | valid_ex pc_ex raw_ex rs1_ex rs2_ex fwd_rs1 fwd_rs2");
      $fwrite(pipe_fd, " | valid_mem pc_mem raw_mem rd_mem dmem_rd dmem_wr dmem_stall");
      $fwrite(pipe_fd, " | valid_wb pc_wb raw_wb rd_we rd_wb rd_data");
      $fwrite(pipe_fd, " | stall_if stall_id stall_ex flush_id flush_ex flush_mem mem_stall");
      $fwrite(pipe_fd, " load_use muldiv_busy mispredict trap_enter exc_mem irq_take mret fencei trap_cause mul_use csr_use\n");
    end

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

  // Pipeline trace: one line per cycle, sampled on the falling edge, when the
  // registers hold this cycle's contents and the combinational control
  // (stalls, flushes, forwarding) has settled. The next rising edge acts on it.
  integer pipe_cycle;
  initial pipe_cycle = 0;
  always @(negedge clk) if (rst_n && pipe_fd != 0) begin
    pipe_cycle = pipe_cycle + 1;
    $fwrite(pipe_fd, "%0d %08h %0d %0d %0d %0d",
            pipe_cycle, `CORE.pc_if, `CORE.fetch_valid, `CORE.straddle, `CORE.imem_stall,
            `CORE.bp_pred_taken && `CORE.bp_pred_valid);
    $fwrite(pipe_fd, " | %0d %08h %08h | %0d %08h %08h %0d %0d %0d %0d",
            `CORE.valid_id, `CORE.pc_id, `CORE.raw_id,
            `CORE.valid_ex, `CORE.pc_ex, `CORE.raw_ex, `CORE.rs1_addr_ex, `CORE.rs2_addr_ex,
            `CORE.fwd_rs1, `CORE.fwd_rs2);
    $fwrite(pipe_fd, " | %0d %08h %08h %0d %0d %0d %0d",
            `CORE.valid_mem, `CORE.pc_mem, `CORE.raw_mem, `CORE.rd_addr_mem,
            `CORE.dmem_rd, `CORE.dmem_wr, `CORE.dmem_stall);
    $fwrite(pipe_fd, " | %0d %08h %08h %0d %0d %08h",
            `CORE.valid_wb, `CORE.pc_wb, `CORE.raw_wb, `CORE.wb_wr_en, `CORE.rd_addr_wb, `CORE.wb_rd_data);
    $fwrite(pipe_fd, " | %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %08h %0d %0d\n",
            `CORE.stall_if, `CORE.stall_id, `CORE.stall_ex,
            `CORE.flush_id, `CORE.flush_ex, `CORE.flush_mem, `CORE.mem_stall,
            `CORE.u_hazard.load_use_hazard, `CORE.muldiv_busy, `CORE.branch_mispredict_ex,
            `CORE.trap_enter, `CORE.exc_mem, `CORE.irq_take, `CORE.mret_ex, `CORE.fencei_take,
            `CORE.trap_cause, `CORE.u_hazard.mul_use_hazard, `CORE.u_hazard.csr_use_hazard);
  end

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
        if (pipe_fd != 0) $fclose(pipe_fd);
        $finish;
      end
    end
    if (cycles >= timeout) begin
      $display("RESULT TIMEOUT %0d cycles %0d retired (last pc 0x%08h)", cycles, retired, `CORE.retire_pc);
      if (trace_fd != 0) $fclose(trace_fd);
      if (pipe_fd != 0) $fclose(pipe_fd);
      $finish;
    end
  end

endmodule
