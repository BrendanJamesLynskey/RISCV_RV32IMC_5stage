`timescale 1ns / 1ps

module tb_brv32p_soc;

  reg         clk;
  reg         rst_n;
  reg  [31:0] gpio_in;
  wire [31:0] gpio_out;
  reg         uart_rx;
  wire        uart_tx;

  initial clk = 0;
  always #5 clk = ~clk;

  brv32p_soc #(
    .MEM_DEPTH (8192),
    .INIT_FILE ("firmware.hex")
  ) dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .gpio_in  (gpio_in),
    .gpio_out (gpio_out),
    .uart_rx  (uart_rx),
    .uart_tx  (uart_tx)
  );

  `define CORE    dut.u_core
  `define RF      dut.u_core.u_regfile
  `define CSR     dut.u_core.u_csr
  `define BP      dut.u_core.u_bp
  `define ICACHE  dut.u_icache
  `define DCACHE  dut.u_dcache
  `define GPIO    dut.u_gpio
  `define UART    dut.u_uart
  `define TIMER   dut.u_timer

  function [31:0] get_reg;
    input integer idx;
    begin
      if (idx == 0) get_reg = 32'd0;
      else get_reg = `RF.regs[idx];
    end
  endfunction

  integer pass_cnt, fail_cnt, test_num;
  initial begin pass_cnt = 0; fail_cnt = 0; test_num = 0; end

  task check;
    input [511:0] name;
    input [31:0] actual;
    input [31:0] expected;
    begin
      test_num = test_num + 1;
      if (actual === expected) begin
        $display("[PASS] #%0d %0s = 0x%08h", test_num, name, actual);
        pass_cnt = pass_cnt + 1;
      end else begin
        $display("[FAIL] #%0d %0s: got 0x%08h, expected 0x%08h", test_num, name, actual, expected);
        fail_cnt = fail_cnt + 1;
      end
    end
  endtask

  task check_nonzero;
    input [511:0] name;
    input [31:0] actual;
    begin
      test_num = test_num + 1;
      if (actual !== 32'd0) begin
        $display("[PASS] #%0d %0s = 0x%08h (nonzero)", test_num, name, actual);
        pass_cnt = pass_cnt + 1;
      end else begin
        $display("[FAIL] #%0d %0s: expected nonzero", test_num, name);
        fail_cnt = fail_cnt + 1;
      end
    end
  endtask

  task run;
    input integer n;
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) @(posedge clk);
    end
  endtask

  // Wait for a register to reach a specific value; a timeout is a failure
  task wait_reg;
    input integer reg_idx;
    input [31:0] val;
    input integer timeout;
    integer cnt;
    begin
      cnt = 0;
      while (get_reg(reg_idx) !== val && cnt < timeout) begin
        @(posedge clk);
        cnt = cnt + 1;
      end
      if (cnt >= timeout) begin
        test_num = test_num + 1;
        fail_cnt = fail_cnt + 1;
        $display("[FAIL] #%0d Timeout waiting for x%0d = 0x%08h (current: 0x%08h)", test_num, reg_idx, val, get_reg(reg_idx));
      end
    end
  endtask

  // UART monitor: decodes each 8N1 byte the DUT transmits.
  // Bit period is clk_div + 1 cycles (see uart.v TX state machine).
  reg  [7:0] uart_byte;
  integer    uart_count, uart_period, ub;
  initial begin uart_count = 0; uart_byte = 8'h00; end

  always @(negedge uart_tx) if (rst_n) begin
    uart_period = `UART.clk_div + 1;
    run(uart_period / 2);
    if (uart_tx === 1'b0) begin
      for (ub = 0; ub < 8; ub = ub + 1) begin
        run(uart_period);
        uart_byte[ub] = uart_tx;
      end
      run(uart_period);
      if (uart_tx === 1'b1) uart_count = uart_count + 1;
      else $display("[WARN] UART framing error (no stop bit)");
    end
  end

  // ── Main Test ─────────────────────────────────────────────────────────
  integer valid_count, trained, s_idx, w_idx, bp_idx;

  initial begin
    $display("=============================================================");
    $display("  BRV32P - 5-Stage Pipelined RV32IMC SoC Testbench");
    $display("=============================================================");

    rst_n   = 0;
    gpio_in = 32'b0;
    uart_rx = 1'b1;

    run(10);
    rst_n = 1;

    // ── Wait for ALU results to propagate through pipeline ──────────
    $display("\n--- Test: ALU Instructions (pipeline) ---");

    wait_reg(1, 32'd42, 50000);
    wait_reg(19, 32'd1, 100000);

    check("ADDI x1=42",    get_reg(1),  32'd42);
    check("ADDI x2=10",    get_reg(2),  32'd10);
    check("ADD  x3=52",    get_reg(3),  32'd52);
    check("SUB  x4=32",    get_reg(4),  32'd32);
    check("ANDI x5=52",    get_reg(5),  32'd52);
    check("ORI  x6=0x55",  get_reg(6),  32'h55);
    check("XORI x7=0xAA",  get_reg(7),  32'hAA);
    check("SLLI x8=160",   get_reg(8),  32'd160);
    check("SRLI x9=40",    get_reg(9),  32'd40);
    check("SLTI x18=1",    get_reg(18), 32'd1);
    check("SLT  x19=1",    get_reg(19), 32'd1);

    // ── Forwarding test ─────────────────────────────────────────────
    $display("\n--- Test: Data Forwarding ---");
    check("Forwarding: ADD x3 uses x1,x2 via forward", get_reg(3), 32'd52);

    // ── Load/Store through D-cache ──────────────────────────────────
    $display("\n--- Test: Load/Store (D-Cache) ---");
    wait_reg(11, 32'd52, 50000);
    check("SW+LW via D-cache: x11=52", get_reg(11), 32'd52);
    wait_reg(12, 32'h55, 50000);
    check("SB+LBU via D-cache: x12=0x55", get_reg(12), 32'h55);

    // ── Branch prediction ───────────────────────────────────────────
    $display("\n--- Test: Branches + Prediction ---");
    wait_reg(15, 32'd2, 50000);
    check("BEQ+BNE through pipeline: x15=2", get_reg(15), 32'd2);

    // ── JAL ─────────────────────────────────────────────────────────
    $display("\n--- Test: JAL ---");
    wait_reg(17, 32'd3, 50000);
    check("JAL target: x17=3", get_reg(17), 32'd3);
    check("JAL link: x16=0x6C", get_reg(16), 32'h6C);

    // ── Program completion ──────────────────────────────────────────
    // AUIPC at 0xA4 runs only after the countdown loop has finished, so
    // x20 = 0xA4 proves the whole program executed in order.
    $display("\n--- Test: Loop (BNE countdown, BP training) and completion ---");
    wait_reg(20, 32'h0000_00A4, 100000);
    check("AUIPC x20=0xA4 (program reached its end)", get_reg(20), 32'h0000_00A4);
    // x23 resets to 0, so the loop result only counts once the end is reached
    check("Loop finished: x23=0 at program end",
          (get_reg(20) === 32'h0000_00A4) ? get_reg(23) : 32'hFFFF_FFFF, 32'd0);
    check_nonzero("CSRRS read mcycle into x21", get_reg(21));
    run(50);
    check("ECALL trapped: mcause=11", `CSR.mcause, 32'd11);

    // ── GPIO ────────────────────────────────────────────────────────
    $display("\n--- Test: GPIO Output ---");
    check("GPIO output = 52 (DIR=0xFF, OUT=52)", gpio_out, 32'd52);

    // ── UART ────────────────────────────────────────────────────────
    $display("\n--- Test: UART TX ---");
    run(2000);
    check_nonzero("UART bytes received", uart_count);
    check("UART byte = 'H'", {24'b0, uart_byte}, 32'h48);

    // ── GPIO Input ──────────────────────────────────────────────────
    $display("\n--- Test: GPIO Input ---");
    gpio_in = 32'hDEAD_BEEF;
    run(5);
    check("GPIO input sync", `GPIO.gpio_in_sync, 32'hDEAD_BEEF);

    // ── CSR ─────────────────────────────────────────────────────────
    $display("\n--- Test: CSR mcycle ---");
    check_nonzero("mcycle counter running", `CSR.mcycle[31:0]);

    // ── I-Cache statistics ──────────────────────────────────────────
    $display("\n--- Test: I-Cache ---");
    begin
      valid_count = 0;
      for (s_idx = 0; s_idx < 64; s_idx = s_idx + 1)
        for (w_idx = 0; w_idx < 2; w_idx = w_idx + 1)
          if (`ICACHE.valid_mem[s_idx][w_idx]) valid_count = valid_count + 1;
      if (valid_count > 0) begin
        $display("[PASS] #%0d I-Cache: %0d valid lines", test_num+1, valid_count);
        pass_cnt = pass_cnt + 1;
      end else begin
        $display("[FAIL] #%0d I-Cache: no valid lines", test_num+1);
        fail_cnt = fail_cnt + 1;
      end
      test_num = test_num + 1;
    end

    // ── Branch Predictor state ──────────────────────────────────────
    $display("\n--- Test: Branch Predictor ---");
    begin
      trained = 0;
      for (bp_idx = 0; bp_idx < 256; bp_idx = bp_idx + 1)
        if (`BP.bht[bp_idx] != 2'b01) trained = trained + 1;
      if (trained > 0) begin
        $display("[PASS] #%0d BHT: %0d entries trained", test_num+1, trained);
        pass_cnt = pass_cnt + 1;
      end else begin
        $display("[FAIL] #%0d BHT: no entries trained", test_num+1);
        fail_cnt = fail_cnt + 1;
      end
      test_num = test_num + 1;
    end

    // ── Summary ─────────────────────────────────────────────────────
    $display("\n=============================================================");
    $display("  Results: %0d PASSED, %0d FAILED out of %0d", pass_cnt, fail_cnt, test_num);
    if (fail_cnt == 0) $display("  *** ALL TESTS PASSED ***");
    else               $display("  *** SOME TESTS FAILED ***");
    $display("=============================================================");
    $finish;
  end

  // Timeout
  initial begin
    #20_000_000;
    $display("[ERROR] Global timeout!");
    $finish;
  end

  // VCD
  initial begin
    if ($test$plusargs("VCD")) begin
      $dumpfile("brv32p_soc.vcd");
      $dumpvars(0, tb_brv32p_soc);
    end
  end

endmodule
