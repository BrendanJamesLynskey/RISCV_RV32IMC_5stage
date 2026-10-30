// ============================================================================
// brv32p_core.v — 5-Stage Pipelined RV32IMC CPU Core
// ============================================================================

module brv32p_core #(
  parameter [31:0] RESET_PC = 32'h0000_0000
) (
  input  wire        clk,
  input  wire        rst_n,

  // Instruction memory interface
  output wire [31:0] imem_addr,
  output wire        imem_rd,
  input  wire [31:0] imem_rdata,
  input  wire        imem_ready,

  // Data memory interface
  output wire [31:0] dmem_addr,
  output wire        dmem_rd,
  output wire        dmem_wr,
  output wire [1:0]  dmem_width,
  output wire        dmem_sign_ext,
  output wire [31:0] dmem_wdata,
  input  wire [31:0] dmem_rdata,
  input  wire        dmem_ready,

  // Interrupts
  input  wire        ext_irq,
  input  wire        timer_irq,

  // FENCE.I: invalidate the instruction cache
  output wire        icache_invalidate,

  // Retire trace: one pulse per retired instruction, in program order.
  // Not used by the SoC; testbenches compare it against a reference model.
  output wire        retire_valid,
  output wire [31:0] retire_pc,
  output wire [31:0] retire_insn,      // raw encoding; [31:16] = 0 for RVC
  output wire        retire_rd_we,
  output wire [4:0]  retire_rd_addr,
  output wire [31:0] retire_rd_wdata,
  output wire        retire_mem_we,
  output wire [31:0] retire_mem_addr,
  output wire [31:0] retire_mem_wdata,
  output wire [1:0]  retire_mem_width
);

  `include "brv32p_defs.vh"

  // ════════════════════════════════════════════════════════════════════
  // Pipeline control signals
  // ════════════════════════════════════════════════════════════════════
  wire stall_if, stall_id, stall_ex;
  wire flush_id, flush_ex, flush_mem;
  wire [1:0] fwd_rs1, fwd_rs2;
  wire mem_stall;
  wire dmem_stall;
  wire imem_stall;

  assign dmem_stall = (dmem_rd | dmem_wr) & ~dmem_ready;
  assign imem_stall = imem_rd & ~imem_ready;
  assign mem_stall  = dmem_stall | imem_stall;

  // ════════════════════════════════════════════════════════════════════
  // IF — Instruction Fetch
  // ════════════════════════════════════════════════════════════════════
  reg  [31:0] pc_if;
  reg  [31:0] pc_next;
  wire [31:0] instr_raw_if;
  wire        bp_pred_taken;
  wire [31:0] bp_pred_target;
  wire        bp_pred_valid;
  wire        is_compressed_if;

  // Instruction alignment (RV32C). Memory returns aligned 32-bit words, but
  // instructions are 16 or 32 bits on any 16-bit boundary:
  //   pc[1] = 0: the instruction starts in the low half of the word;
  //   pc[1] = 1: it starts in the high half. If that half is a compressed
  //              instruction, use it; otherwise the instruction straddles
  //              two words. Keep the half in half_buf, fetch the next word
  //              (sending a bubble to ID meanwhile), then join the halves.
  // The bubble is avoided when fetch already holds that half: the next
  // instruction in sequence starts in the upper half of the word just read
  // (after a compressed instruction in its lower half, or after a straddling
  // instruction that ended in it). Then the half is kept now (early_straddle)
  // and fetch goes straight on to the following word.
  reg         straddle;          // half_buf holds the low half of the instruction at pc_if
  reg  [15:0] half_buf;
  wire        fetch_valid;       // instr_raw_if is a complete instruction this cycle
  wire [15:0] half_at_pc = pc_if[1] ? imem_rdata[31:16] : imem_rdata[15:0];
  wire        straddle_start = !straddle && pc_if[1] && (half_at_pc[1:0] == 2'b11);
  wire        seq_upper_half;    // the next instruction in sequence starts in the upper half of this word
  wire        early_straddle = seq_upper_half && (imem_rdata[17:16] == 2'b11);
  wire        if_advance = !stall_if && !mem_stall;
  wire        redirect;          // mispredict, trap, MRET or FENCE.I this cycle
  wire        fencei_take;       // FENCE.I in EX acts this cycle (defined in EX)

  assign fetch_valid  = !straddle_start;
  assign instr_raw_if = straddle                   ? {imem_rdata[15:0], half_buf} :
                        (half_at_pc[1:0] != 2'b11) ? {16'b0, half_at_pc}         :
                                                     imem_rdata;
  assign imem_addr    = {pc_if[31:2] + {29'b0, straddle}, 2'b00};
  assign imem_rd      = 1'b1;

  // PC Register
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_if    <= RESET_PC;
      straddle <= 1'b0;
      half_buf <= 16'b0;
    end else if (redirect && !mem_stall) begin
      pc_if    <= pc_next;
      straddle <= 1'b0;
    end else if (if_advance) begin
      pc_if    <= pc_next;           // holds pc_if while a straddle is pending
      straddle <= straddle_start || early_straddle;
      if (straddle_start) half_buf <= half_at_pc;
      else if (early_straddle) half_buf <= imem_rdata[31:16];
    end
  end

  // Compressed decoder
  wire [31:0] instr_expanded_if;
  wire        illegal_c_if;

  compressed_decoder u_cdec (
    .instr_in      (instr_raw_if),
    .instr_out     (instr_expanded_if),
    .is_compressed (is_compressed_if),
    .illegal_c     (illegal_c_if)
  );

  // Branch predictor
  wire        bp_update_en;
  wire [31:0] bp_update_pc, bp_update_target;
  wire        bp_update_taken;

  branch_predictor u_bp (
    .clk         (clk),
    .rst_n       (rst_n),
    .pc          (pc_if),
    .pred_taken  (bp_pred_taken),
    .pred_target (bp_pred_target),
    .pred_valid  (bp_pred_valid),
    .update_en   (bp_update_en),
    .update_pc   (bp_update_pc),
    .update_taken(bp_update_taken),
    .update_target(bp_update_target)
  );

  // Next PC MUX
  wire        branch_mispredict_ex;
  wire [31:0] branch_target_ex;
  wire        trap_enter;
  wire [31:0] mtvec_out, mepc_out;
  wire        mret_ex;

  wire [31:0] pc_inc;
  assign pc_inc = is_compressed_if ? 32'd2 : 32'd4;

  // Sequential next pc lands in the upper half of the word just read: a
  // compressed instruction in a lower half (pc[1] = 0), or a straddling
  // instruction (pc[1] = 1, 4 bytes, ending in the word just read). Not when
  // fetch follows a predicted-taken branch instead (pc_next mux below; a
  // redirect resets straddle in any case).
  assign seq_upper_half = fetch_valid && !(bp_pred_taken && bp_pred_valid) &&
                          (pc_if[1] ? (straddle && !is_compressed_if) : is_compressed_if);

  assign redirect = trap_enter || mret_ex || branch_mispredict_ex || fencei_take;

  always @(*) begin
    if (trap_enter)
      pc_next = mtvec_out;
    else if (mret_ex)
      pc_next = mepc_out;
    else if (branch_mispredict_ex)
      pc_next = branch_target_ex;
    else if (fencei_take)
      pc_next = pc_ex + pc_inc_ex;
    else if (!fetch_valid)
      pc_next = pc_if;               // first half of a straddling instruction
    else if (bp_pred_taken && bp_pred_valid)
      pc_next = bp_pred_target;
    else
      pc_next = pc_if + pc_inc;
  end

  // ════════════════════════════════════════════════════════════════════
  // IF/ID Pipeline Register
  // ════════════════════════════════════════════════════════════════════
  reg [31:0] pc_id, instr_id;
  reg [31:0] pc_inc_id;
  reg        pred_taken_id;
  reg [31:0] pred_target_id;    // where fetch went next if pred_taken_id
  reg        illegal_c_id;
  reg        valid_id;                  // stage holds a real instruction, not a bubble
  reg [31:0] raw_id;                    // original encoding, for the retire trace

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush_id) begin
      pc_id         <= 32'b0;
      instr_id      <= 32'h0000_0013; // NOP
      pc_inc_id     <= 32'd4;
      pred_taken_id <= 1'b0;
      pred_target_id <= 32'b0;
      illegal_c_id  <= 1'b0;
      valid_id      <= 1'b0;
      raw_id        <= 32'b0;
    end else if (!stall_id && !mem_stall) begin
      pc_id         <= pc_if;
      instr_id      <= fetch_valid ? instr_expanded_if : 32'h0000_0013;  // NOP while a straddle completes
      pc_inc_id     <= pc_inc;
      pred_taken_id <= bp_pred_taken && bp_pred_valid && fetch_valid;
      pred_target_id <= bp_pred_target;
      illegal_c_id  <= illegal_c_if && fetch_valid;
      valid_id      <= fetch_valid;
      raw_id        <= instr_raw_if;
    end
  end

  // ════════════════════════════════════════════════════════════════════
  // ID — Instruction Decode
  // ════════════════════════════════════════════════════════════════════
  wire [4:0]          rs1_addr_id, rs2_addr_id, rd_addr_id;
  wire [31:0]         imm_id;
  wire [`CTRL_W-1:0]  ctrl_id;
  wire [31:0]         rs1_data_raw, rs2_data_raw;

  decoder u_decoder (
    .instr    (instr_id),
    .rs1_addr (rs1_addr_id),
    .rs2_addr (rs2_addr_id),
    .rd_addr  (rd_addr_id),
    .imm      (imm_id),
    .ctrl     (ctrl_id)
  );

  // Register file
  wire        wb_wr_en;
  wire [4:0]  wb_rd_addr;
  reg  [31:0] wb_rd_data;

  regfile u_regfile (
    .clk      (clk),
    .rst_n    (rst_n),
    .rs1_addr (rs1_addr_id),
    .rs1_data (rs1_data_raw),
    .rs2_addr (rs2_addr_id),
    .rs2_data (rs2_data_raw),
    .wr_en    (wb_wr_en),
    .rd_addr  (wb_rd_addr),
    .rd_data  (wb_rd_data)
  );

  // ════════════════════════════════════════════════════════════════════
  // ID/EX Pipeline Register
  // ════════════════════════════════════════════════════════════════════
  reg [31:0]         pc_ex, rs1_data_ex, rs2_data_ex, imm_ex;
  reg [31:0]         pc_inc_ex;
  reg [4:0]          rs1_addr_ex, rs2_addr_ex, rd_addr_ex;
  reg [`CTRL_W-1:0]  ctrl_ex;
  reg                pred_taken_ex;
  reg [31:0]         pred_target_ex;
  reg                valid_ex;
  reg [31:0]         raw_ex;

  // An illegal compressed instruction traps; clear its other control bits so
  // the expansion it produced cannot write anything
  reg [`CTRL_W-1:0] ctrl_id_eff;
  always @(*) begin
    ctrl_id_eff = ctrl_id;
    if (illegal_c_id) begin
      ctrl_id_eff = {`CTRL_W{1'b0}};
      ctrl_id_eff[`CTRL_ILLEGAL] = 1'b1;
    end
  end

  // flush_ex from a load-use hazard inserts a bubble as the load moves on to
  // MEM; during a memory stall the load is held in EX, so it must not fire
  // (mispredict and trap flushes are already gated by mem_stall).
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || (flush_ex && !mem_stall)) begin
      valid_ex      <= 1'b0;
      raw_ex        <= 32'b0;
      ctrl_ex       <= {`CTRL_W{1'b0}};
      pc_ex         <= 32'b0;
      rs1_data_ex   <= 32'b0;
      rs2_data_ex   <= 32'b0;
      imm_ex        <= 32'b0;
      pc_inc_ex     <= 32'd4;
      rs1_addr_ex   <= 5'b0;
      rs2_addr_ex   <= 5'b0;
      rd_addr_ex    <= 5'b0;
      pred_taken_ex <= 1'b0;
      pred_target_ex <= 32'b0;
    end else if (!stall_ex && !mem_stall) begin
      ctrl_ex       <= ctrl_id_eff;
      pc_ex         <= pc_id;
      rs1_data_ex   <= rs1_data_raw;
      rs2_data_ex   <= rs2_data_raw;
      imm_ex        <= imm_id;
      pc_inc_ex     <= pc_inc_id;
      rs1_addr_ex   <= rs1_addr_id;
      rs2_addr_ex   <= rs2_addr_id;
      rd_addr_ex    <= rd_addr_id;
      pred_taken_ex <= pred_taken_id;
      pred_target_ex <= pred_target_id;
      valid_ex      <= valid_id;
      raw_ex        <= raw_id;
    end
  end

  // ════════════════════════════════════════════════════════════════════
  // EX — Execute
  // ════════════════════════════════════════════════════════════════════

  // Forwarding MUXes
  reg  [31:0] rs1_fwd, rs2_fwd;
  wire [31:0] alu_result_mem;  // From EX/MEM register
  wire [31:0] wb_data_fwd;     // From MEM/WB

  always @(*) begin
    case (fwd_rs1)
      FWD_EX_MEM:  rs1_fwd = alu_result_mem;
      FWD_MEM_WB:  rs1_fwd = wb_data_fwd;
      default:     rs1_fwd = rs1_data_ex;
    endcase
    case (fwd_rs2)
      FWD_EX_MEM:  rs2_fwd = alu_result_mem;
      FWD_MEM_WB:  rs2_fwd = wb_data_fwd;
      default:     rs2_fwd = rs2_data_ex;
    endcase
  end

  // ALU
  wire [31:0] alu_b, alu_result_ex;
  wire        alu_zero;

  assign alu_b = ctrl_ex[`CTRL_ALU_SRC] ? imm_ex : rs2_fwd;

  alu u_alu (
    .a      (rs1_fwd),
    .b      (alu_b),
    .op     (ctrl_ex[`CTRL_ALU_OP]),
    .result (alu_result_ex),
    .zero   (alu_zero)
  );

  // AUIPC result
  wire [31:0] auipc_result;
  assign auipc_result = pc_ex + imm_ex;

  // MulDiv: the divider runs in EX; a multiply only passes through EX and
  // computes in MEM
  wire [2:0]  md_op_ex = ctrl_ex[`CTRL_MULDIV_OP];
  wire        mul_ex   = ctrl_ex[`CTRL_MULDIV_EN] && !md_op_ex[2];
  wire [31:0] muldiv_result;
  wire        muldiv_busy, muldiv_valid;

  muldiv u_muldiv (
    .clk    (clk),
    .rst_n  (rst_n),
    .start  (ctrl_ex[`CTRL_MULDIV_EN]),
    .hold   (mem_stall),
    .kill   (flush_ex && !mem_stall),
    .op     (ctrl_ex[`CTRL_MULDIV_OP]),
    .a      (rs1_fwd),
    .b      (rs2_fwd),
    .result (muldiv_result),
    .busy   (muldiv_busy),
    .valid  (muldiv_valid)
  );

  // Xbrvdsp: multiply-accumulate. An accumulator instruction updates acc as
  // it moves from EX to MEM (not while held, and not if a trap flushes it)
  wire dsp_ex = valid_ex && (raw_ex[6:0] == OP_CUSTOM0) && !ctrl_ex[`CTRL_ILLEGAL];
  wire [31:0] dsp_result;

  dsp_unit u_dsp (
    .clk    (clk),
    .rst_n  (rst_n),
    .update (dsp_ex && !mem_stall && !stall_ex && !flush_mem),
    .funct7 ({1'b0, raw_ex[30:25]}),   // bit 6 marks a loop end (loop_unit.v)
    .funct3 (raw_ex[14:12]),
    .a      (rs1_fwd),
    .b      (rs2_fwd),
    .sh     (raw_ex[24:20]),
    .result (dsp_result)
  );

  // Xbrvdsp: address generators. An AGU instruction updates its address
  // register as it moves from EX to MEM, with the same gating as acc, and not
  // if the load is misaligned (it traps and runs again after the handler).
  wire agu_ex      = valid_ex && (raw_ex[6:0] == OP_CUSTOM1) && !ctrl_ex[`CTRL_ILLEGAL];
  wire agu_load_ex = agu_ex && ctrl_ex[`CTRL_MEM_RD];
  wire [31:0] agu_addr, agu_result;
  wire        misaligned_ex;

  agu u_agu (
    .clk    (clk),
    .rst_n  (rst_n),
    .update (agu_ex && !mem_stall && !stall_ex && !flush_mem && !misaligned_ex),
    .insn   (raw_ex),
    .a      (rs1_fwd),
    .addr   (agu_addr),
    .result (agu_result)
  );

  // Xbrvdsp: the hardware loop. A loop-end instruction resolves in EX like a
  // branch (below): taken while lc > 1, to lp_start.
  wire        loop_end_ex, loop_back_ex;
  wire [31:0] loop_start, loop_result;

  loop_unit u_loop (
    .clk       (clk),
    .rst_n     (rst_n),
    .update    (valid_ex && !ctrl_ex[`CTRL_ILLEGAL] && !mem_stall && !stall_ex && !flush_mem),
    .valid     (valid_ex && !ctrl_ex[`CTRL_ILLEGAL]),
    .insn      (raw_ex),
    .pc        (pc_ex),
    .a         (rs1_fwd),
    .loop_end  (loop_end_ex),
    .loop_back (loop_back_ex),
    .start     (loop_start),
    .result    (loop_result)
  );

  // Branch resolution
  reg  branch_taken_ex;
  wire [31:0] branch_target_computed;

  always @(*) begin
    branch_taken_ex = 1'b0;
    case (ctrl_ex[`CTRL_BR_TYPE])
      BR_EQ:  branch_taken_ex = (rs1_fwd == rs2_fwd);
      BR_NE:  branch_taken_ex = (rs1_fwd != rs2_fwd);
      BR_LT:  branch_taken_ex = ($signed(rs1_fwd) < $signed(rs2_fwd));
      BR_GE:  branch_taken_ex = ($signed(rs1_fwd) >= $signed(rs2_fwd));
      BR_LTU: branch_taken_ex = (rs1_fwd < rs2_fwd);
      BR_GEU: branch_taken_ex = (rs1_fwd >= rs2_fwd);
      default: branch_taken_ex = 1'b0;
    endcase
  end

  assign branch_target_computed = loop_end_ex        ? loop_start :
                                  ctrl_ex[`CTRL_JALR] ? {alu_result_ex[31:1], 1'b0} : (pc_ex + imm_ex);

  // Mispredict detection
  wire is_branch_or_jump;
  assign is_branch_or_jump = (ctrl_ex[`CTRL_BR_TYPE] != BR_NONE) ||
                              ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR] || loop_end_ex;

  wire actual_taken;
  assign actual_taken = branch_taken_ex || ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR] || loop_back_ex;

  // Redirects (mispredict here, MRET below, traps in MEM) act only on a cycle
  // when the pipeline advances. During a memory stall the EX and MEM
  // instructions are held, so acting early would flush the branch or jump
  // itself while its redirect is lost (the PC does not load while stalled).
  // A mispredict is a wrong direction, or taken to the wrong place (the
  // target fetch followed, pred_target_ex, differs from the real one). A taken
  // prediction for an instruction that is not a branch or jump (a BTB alias,
  // or a stale entry) is also a mispredict: fall through to pc+len.
  assign branch_mispredict_ex = !mem_stall && valid_ex &&
    ((is_branch_or_jump &&
      ((actual_taken != pred_taken_ex) ||
       (actual_taken && (branch_target_computed != pred_target_ex)))) ||
     (!is_branch_or_jump && pred_taken_ex));

  assign branch_target_ex = actual_taken ? branch_target_computed :
                            (pc_ex + pc_inc_ex);

  // Misaligned load or store: the address is known here, the exception is
  // taken when the instruction reaches MEM (the access itself is suppressed)
  wire mem_access_ex = ctrl_ex[`CTRL_MEM_RD] || ctrl_ex[`CTRL_MEM_WR];
  // The data address: rs1 + imm from the ALU, or an address register's value
  wire [31:0] mem_addr_ex = (raw_ex[6:0] == OP_CUSTOM1) ? agu_addr : alu_result_ex;
  assign misaligned_ex = mem_access_ex &&
    ((ctrl_ex[`CTRL_MEM_WIDTH] == 2'd1 && mem_addr_ex[0]) ||
     (ctrl_ex[`CTRL_MEM_WIDTH] == 2'd2 && mem_addr_ex[1:0] != 2'b00));

  // FENCE.I (MISC-MEM, funct3 = 001): invalidate the I-cache and refetch the
  // next instruction, so nothing fetched before the fence runs. The D-cache
  // is write-through, so older stores are already in memory.
  wire fencei_ex = valid_ex && (raw_ex[6:0] == 7'b0001111) && (raw_ex[14:12] == 3'b001);
  assign fencei_take = !mem_stall && fencei_ex;
  assign icache_invalidate = fencei_take;

  // Branch predictor update
  assign bp_update_en     = !mem_stall && ((ctrl_ex[`CTRL_BR_TYPE] != BR_NONE) || loop_end_ex);  // once per branch
  assign bp_update_pc     = pc_ex;
  assign bp_update_taken  = branch_taken_ex || loop_back_ex;
  assign bp_update_target = branch_target_computed;

  // MRET
  assign mret_ex = !mem_stall && ctrl_ex[`CTRL_MRET];  // mstatus update once

  // EX result select
  reg [31:0] ex_result;
  always @(*) begin
    case (ctrl_ex[`CTRL_WB_SEL])
      WB_ALU:    ex_result = alu_result_ex;
      WB_PC4:    ex_result = pc_ex + pc_inc_ex;
      WB_MULDIV: ex_result = muldiv_result;
      WB_AUIPC:  ex_result = auipc_result;
      WB_DSP:    ex_result = dsp_result;
      WB_AGU:    ex_result = raw_ex[23] ? loop_result : agu_result;   // lp.rd : ar.rd
      WB_MEM:    ex_result = mem_addr_ex;
      default:   ex_result = alu_result_ex;
    endcase
  end

  // ════════════════════════════════════════════════════════════════════
  // EX/MEM Pipeline Register
  // ════════════════════════════════════════════════════════════════════
  reg [31:0]         pc_mem;
  reg [31:0]         ex_result_mem, rs2_data_mem;
  reg [4:0]          rd_addr_mem;
  reg [`CTRL_W-1:0]  ctrl_mem;


  reg                valid_mem;
  reg [31:0]         raw_mem;
  reg                misaligned_mem;
  reg  [31:0]        rs1_data_mem;      // a multiply's first operand

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush_mem) begin
      ctrl_mem       <= {`CTRL_W{1'b0}};
      pc_mem         <= 32'b0;
      ex_result_mem  <= 32'b0;
      rs2_data_mem   <= 32'b0;
      rs1_data_mem   <= 32'b0;
      rd_addr_mem    <= 5'b0;
      misaligned_mem <= 1'b0;
      valid_mem      <= 1'b0;
      raw_mem        <= 32'b0;
    end else if (!mem_stall) begin
      ctrl_mem       <= ctrl_ex;
      pc_mem         <= pc_ex;
      ex_result_mem  <= ex_result;
      rs2_data_mem   <= rs2_fwd;
      rs1_data_mem   <= rs1_fwd;
      rd_addr_mem    <= rd_addr_ex;
      misaligned_mem <= misaligned_ex;
      // While EX is stalled (multi-cycle MUL/DIV) this register keeps copying
      // the waiting instruction; only the final copy is a real instruction.
      valid_mem      <= valid_ex && !stall_ex;
      raw_mem        <= raw_ex;
    end
  end

  // ════════════════════════════════════════════════════════════════════
  // MEM — Memory Access
  // ════════════════════════════════════════════════════════════════════
  assign dmem_addr     = ex_result_mem;
  assign dmem_rd       = ctrl_mem[`CTRL_MEM_RD] && !misaligned_mem;
  assign dmem_wr       = ctrl_mem[`CTRL_MEM_WR] && !misaligned_mem;
  assign dmem_width    = ctrl_mem[`CTRL_MEM_WIDTH];
  assign dmem_sign_ext = ctrl_mem[`CTRL_MEM_SIGN];
  assign dmem_wdata    = rs2_data_mem;

  // Multiply, from operands registered at the end of EX. Being in MEM keeps
  // the multiplier off the forwarding path into EX (the critical path when it
  // sat in EX); the hazard unit holds a dependent instruction for one cycle,
  // as after a load.
  wire [2:0]  md_op_mem = ctrl_mem[`CTRL_MULDIV_OP];
  wire        mul_mem   = ctrl_mem[`CTRL_MULDIV_EN] && !md_op_mem[2];
  wire signed [32:0] mul_a = {md_op_mem != MD_MULHU && rs1_data_mem[31], rs1_data_mem};
  wire signed [32:0] mul_b = {md_op_mem == MD_MULH && rs2_data_mem[31], rs2_data_mem};
  wire signed [65:0] mul_p = mul_a * mul_b;
  wire [31:0] mul_result = (md_op_mem == MD_MUL) ? mul_p[31:0] : mul_p[63:32];

  // MEM result
  wire [31:0] mem_result;
  assign mem_result = ctrl_mem[`CTRL_MEM_RD] ? dmem_rdata :
                      mul_mem                ? mul_result : ex_result_mem;

  // Trap logic
  wire        irq_pending;
  wire [4:0]  irq_code;
  wire [31:0] csr_rdata;

  // Forwarding tap from MEM. A CSR instruction's result is the CSR value read
  // here in MEM, not its EX result (rs1, the write data)
  assign alu_result_mem = (ctrl_mem[`CTRL_WB_SEL] == WB_CSR) ? csr_rdata : ex_result_mem;

  // Exceptions belong to the instruction in MEM, which does not retire.
  // Interrupts are taken at the instruction in EX (mepc = pc_ex): it and all
  // younger instructions are flushed, and the instruction in MEM completes
  // normally, so nothing runs twice after MRET. An interrupt waits while EX
  // is a bubble, a MUL/DIV is busy, or MEM holds a CSR instruction (whose
  // write the trap would otherwise override).
  wire exc_mem  = valid_mem && (ctrl_mem[`CTRL_ECALL] || ctrl_mem[`CTRL_EBREAK] ||
                                ctrl_mem[`CTRL_ILLEGAL] || misaligned_mem);
  wire irq_take = irq_pending && valid_ex && !stall_ex && !ctrl_mem[`CTRL_CSR_EN] && !exc_mem;

  assign trap_enter = !mem_stall && (exc_mem || irq_take);

  reg [31:0] trap_cause, trap_val;
  always @(*) begin
    trap_cause = 32'b0;
    trap_val   = 32'b0;
    if (ctrl_mem[`CTRL_ILLEGAL]) begin
      trap_cause = 32'd2;
    end else if (ctrl_mem[`CTRL_ECALL]) begin
      trap_cause = 32'd11;
    end else if (ctrl_mem[`CTRL_EBREAK]) begin
      trap_cause = 32'd3;
    end else if (misaligned_mem) begin
      trap_cause = ctrl_mem[`CTRL_MEM_WR] ? 32'd6 : 32'd4;   // store / load address misaligned
      trap_val   = ex_result_mem;
    end else if (irq_take) begin
      trap_cause = {1'b1, 26'b0, irq_code};
    end
  end

  // ════════════════════════════════════════════════════════════════════
  // MEM/WB Pipeline Register
  // ════════════════════════════════════════════════════════════════════
  reg [31:0]         mem_result_wb;
  reg [31:0]         csr_rdata_wb;
  reg [4:0]          rd_addr_wb;
  reg [`CTRL_W-1:0]  ctrl_wb;
  reg                valid_wb;          // high for exactly one cycle per retired instruction
  reg [31:0]         pc_wb, raw_wb, mem_addr_wb, mem_wdata_wb;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl_wb      <= {`CTRL_W{1'b0}};
      mem_result_wb <= 32'b0;
      csr_rdata_wb <= 32'b0;
      rd_addr_wb   <= 5'b0;
      valid_wb     <= 1'b0;
      pc_wb        <= 32'b0;
      raw_wb       <= 32'b0;
      mem_addr_wb  <= 32'b0;
      mem_wdata_wb <= 32'b0;
    end else if (!mem_stall) begin
      ctrl_wb      <= ctrl_mem;
      mem_result_wb <= mem_result;
      csr_rdata_wb <= csr_rdata;
      rd_addr_wb   <= rd_addr_mem;
      valid_wb     <= valid_mem && !exc_mem;   // a trapping instruction does not retire
      pc_wb        <= pc_mem;
      raw_wb       <= raw_mem;
      mem_addr_wb  <= ex_result_mem;
      mem_wdata_wb <= rs2_data_mem;
    end else begin
      valid_wb     <= 1'b0;                    // held by a stall: already retired
    end
  end

  // ════════════════════════════════════════════════════════════════════
  // WB — Writeback
  // ════════════════════════════════════════════════════════════════════
  always @(*) begin
    case (ctrl_wb[`CTRL_WB_SEL])
      WB_MEM:    wb_rd_data = mem_result_wb;
      WB_CSR:    wb_rd_data = csr_rdata_wb;
      default:   wb_rd_data = mem_result_wb;
    endcase
  end

  assign wb_wr_en   = ctrl_wb[`CTRL_REG_WR] && valid_wb;
  assign wb_rd_addr = rd_addr_wb;
  assign wb_data_fwd = wb_rd_data;  // Forwarding tap

  // Retire trace
  assign retire_valid     = valid_wb;
  assign retire_pc        = pc_wb;
  assign retire_insn      = raw_wb;
  assign retire_rd_we     = wb_wr_en && (rd_addr_wb != 5'd0);
  assign retire_rd_addr   = rd_addr_wb;
  assign retire_rd_wdata  = wb_rd_data;
  assign retire_mem_we    = valid_wb && ctrl_wb[`CTRL_MEM_WR];
  assign retire_mem_addr  = mem_addr_wb;
  assign retire_mem_wdata = mem_wdata_wb;
  assign retire_mem_width = ctrl_wb[`CTRL_MEM_WIDTH];

  // ════════════════════════════════════════════════════════════════════
  // CSR Unit
  // ════════════════════════════════════════════════════════════════════
  wire [31:0] csr_wdata;
  // CSR write data comes from EX: rs1 for CSRRW/S/C, zimm for CSRRWI/SI/CI
  assign csr_wdata = ex_result_mem;

  csr u_csr (
    .clk           (clk),
    .rst_n         (rst_n),
    .csr_en        (valid_mem && ctrl_mem[`CTRL_CSR_EN] && !trap_enter && !mem_stall),  // write once; read value is the old one
    .csr_addr      (ctrl_mem[`CTRL_CSR_ADDR]),
    .csr_op        (ctrl_mem[`CTRL_CSR_OP]),
    .csr_wdata     (csr_wdata),
    .csr_rdata     (csr_rdata),
    .trap_enter    (trap_enter),
    .trap_cause    (trap_cause),
    .trap_val      (trap_val),
    .trap_pc       (exc_mem ? pc_mem : pc_ex),
    .mtvec_out     (mtvec_out),
    .mepc_out      (mepc_out),
    .mret          (mret_ex),
    .ext_irq       (ext_irq),
    .timer_irq     (timer_irq),
    .instr_retired (valid_wb),
    .irq_pending   (irq_pending),
    .irq_code      (irq_code)
  );

  // ════════════════════════════════════════════════════════════════════
  // Hazard Unit
  // ════════════════════════════════════════════════════════════════════
  hazard_unit u_hazard (
    .id_rs1           (rs1_addr_id),
    .id_rs2           (rs2_addr_id),
    .ex_rs1           (rs1_addr_ex),
    .ex_rs2           (rs2_addr_ex),
    .ex_rd            (rd_addr_ex),
    .ex_reg_wr        (ctrl_ex[`CTRL_REG_WR]),
    .ex_mem_rd        (ctrl_ex[`CTRL_MEM_RD]),
    .ex_mul           (mul_ex),
    .ex_wb_sel        (ctrl_ex[`CTRL_WB_SEL]),
    .mem_rd           (rd_addr_mem),
    .mem_reg_wr       (ctrl_mem[`CTRL_REG_WR]),
    .wb_rd            (rd_addr_wb),
    .wb_reg_wr        (ctrl_wb[`CTRL_REG_WR]),
    .branch_mispredict(branch_mispredict_ex || trap_enter || mret_ex || fencei_take),
    .jump_ex          (ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR]),
    .trap             (trap_enter),
    .muldiv_busy      (muldiv_busy),
    .fwd_rs1          (fwd_rs1),
    .fwd_rs2          (fwd_rs2),
    .stall_if         (stall_if),
    .stall_id         (stall_id),
    .stall_ex         (stall_ex),
    .flush_id         (flush_id),
    .flush_ex         (flush_ex),
    .flush_mem        (flush_mem)
  );

endmodule
