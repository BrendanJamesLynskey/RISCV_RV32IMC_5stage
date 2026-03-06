// ============================================================================
// brv32p_core.v — 5-Stage Pipelined RV32IMC CPU Core
// ============================================================================

module brv32p_core (
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
  input  wire        timer_irq
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

  // PC Register
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      pc_if <= RESET_VECTOR;
    else if (!stall_if && !mem_stall)
      pc_if <= pc_next;
  end

  assign imem_addr = pc_if;
  assign imem_rd   = 1'b1;
  assign instr_raw_if = imem_rdata;

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

  always @(*) begin
    if (trap_enter)
      pc_next = mtvec_out;
    else if (mret_ex)
      pc_next = mepc_out;
    else if (branch_mispredict_ex)
      pc_next = branch_target_ex;
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
  reg        illegal_c_id;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush_id) begin
      pc_id         <= 32'b0;
      instr_id      <= 32'h0000_0013; // NOP
      pc_inc_id     <= 32'd4;
      pred_taken_id <= 1'b0;
      illegal_c_id  <= 1'b0;
    end else if (!stall_id && !mem_stall) begin
      pc_id         <= pc_if;
      instr_id      <= instr_expanded_if;
      pc_inc_id     <= pc_inc;
      pred_taken_id <= bp_pred_taken && bp_pred_valid;
      illegal_c_id  <= illegal_c_if;
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

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush_ex) begin
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
    end else if (!stall_ex && !mem_stall) begin
      ctrl_ex       <= ctrl_id;
      pc_ex         <= pc_id;
      rs1_data_ex   <= rs1_data_raw;
      rs2_data_ex   <= rs2_data_raw;
      imm_ex        <= imm_id;
      pc_inc_ex     <= pc_inc_id;
      rs1_addr_ex   <= rs1_addr_id;
      rs2_addr_ex   <= rs2_addr_id;
      rd_addr_ex    <= rd_addr_id;
      pred_taken_ex <= pred_taken_id;
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

  // MulDiv
  wire [31:0] muldiv_result;
  wire        muldiv_busy, muldiv_valid;

  muldiv u_muldiv (
    .clk    (clk),
    .rst_n  (rst_n),
    .start  (ctrl_ex[`CTRL_MULDIV_EN]),
    .op     (ctrl_ex[`CTRL_MULDIV_OP]),
    .a      (rs1_fwd),
    .b      (rs2_fwd),
    .result (muldiv_result),
    .busy   (muldiv_busy),
    .valid  (muldiv_valid)
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

  assign branch_target_computed = ctrl_ex[`CTRL_JALR] ?
    {alu_result_ex[31:1], 1'b0} : (pc_ex + imm_ex);

  // Mispredict detection
  wire is_branch_or_jump;
  assign is_branch_or_jump = (ctrl_ex[`CTRL_BR_TYPE] != BR_NONE) ||
                              ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR];

  wire actual_taken;
  assign actual_taken = branch_taken_ex || ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR];

  assign branch_mispredict_ex = is_branch_or_jump &&
    ((actual_taken != pred_taken_ex) ||
     (actual_taken && (branch_target_computed != pc_ex + pc_inc_ex)));

  assign branch_target_ex = actual_taken ? branch_target_computed :
                            (pc_ex + pc_inc_ex);

  // Branch predictor update
  assign bp_update_en     = (ctrl_ex[`CTRL_BR_TYPE] != BR_NONE);
  assign bp_update_pc     = pc_ex;
  assign bp_update_taken  = branch_taken_ex;
  assign bp_update_target = branch_target_computed;

  // MRET
  assign mret_ex = ctrl_ex[`CTRL_MRET];

  // EX result select
  reg [31:0] ex_result;
  always @(*) begin
    case (ctrl_ex[`CTRL_WB_SEL])
      WB_ALU:    ex_result = alu_result_ex;
      WB_PC4:    ex_result = pc_ex + pc_inc_ex;
      WB_MULDIV: ex_result = muldiv_result;
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

  assign alu_result_mem = ex_result_mem;  // Forwarding tap

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush_mem) begin
      ctrl_mem       <= {`CTRL_W{1'b0}};
      pc_mem         <= 32'b0;
      ex_result_mem  <= 32'b0;
      rs2_data_mem   <= 32'b0;
      rd_addr_mem    <= 5'b0;
    end else if (!mem_stall) begin
      ctrl_mem       <= ctrl_ex;
      pc_mem         <= pc_ex;
      ex_result_mem  <= ex_result;
      rs2_data_mem   <= rs2_fwd;
      rd_addr_mem    <= rd_addr_ex;
    end
  end

  // ════════════════════════════════════════════════════════════════════
  // MEM — Memory Access
  // ════════════════════════════════════════════════════════════════════
  assign dmem_addr     = ex_result_mem;
  assign dmem_rd       = ctrl_mem[`CTRL_MEM_RD];
  assign dmem_wr       = ctrl_mem[`CTRL_MEM_WR];
  assign dmem_width    = ctrl_mem[`CTRL_MEM_WIDTH];
  assign dmem_sign_ext = ctrl_mem[`CTRL_MEM_SIGN];
  assign dmem_wdata    = rs2_data_mem;

  // MEM result
  wire [31:0] mem_result;
  assign mem_result = ctrl_mem[`CTRL_MEM_RD] ? dmem_rdata : ex_result_mem;

  // Trap logic
  wire        irq_pending;
  wire [31:0] csr_rdata;

  assign trap_enter = ctrl_mem[`CTRL_ECALL] || ctrl_mem[`CTRL_EBREAK] ||
                      ctrl_mem[`CTRL_ILLEGAL] || irq_pending;

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
    end else if (irq_pending) begin
      trap_cause = {1'b1, 31'd11};
    end
  end

  // ════════════════════════════════════════════════════════════════════
  // MEM/WB Pipeline Register
  // ════════════════════════════════════════════════════════════════════
  reg [31:0]         mem_result_wb;
  reg [31:0]         csr_rdata_wb;
  reg [4:0]          rd_addr_wb;
  reg [`CTRL_W-1:0]  ctrl_wb;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl_wb      <= {`CTRL_W{1'b0}};
      mem_result_wb <= 32'b0;
      csr_rdata_wb <= 32'b0;
      rd_addr_wb   <= 5'b0;
    end else if (!mem_stall) begin
      ctrl_wb      <= ctrl_mem;
      mem_result_wb <= mem_result;
      csr_rdata_wb <= csr_rdata;
      rd_addr_wb   <= rd_addr_mem;
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

  assign wb_wr_en   = ctrl_wb[`CTRL_REG_WR];
  assign wb_rd_addr = rd_addr_wb;
  assign wb_data_fwd = wb_rd_data;  // Forwarding tap

  // ════════════════════════════════════════════════════════════════════
  // CSR Unit
  // ════════════════════════════════════════════════════════════════════
  wire [31:0] csr_wdata;
  // ctrl_mem[CTRL_CSR_OP] is bits [19:17]; bit 2 of that = bit 19
  assign csr_wdata = ctrl_mem[19] ?
    {27'b0, rd_addr_mem} : ex_result_mem;

  csr u_csr (
    .clk           (clk),
    .rst_n         (rst_n),
    .csr_en        (ctrl_mem[`CTRL_CSR_EN] && !trap_enter),
    .csr_addr      (ctrl_mem[`CTRL_CSR_ADDR]),
    .csr_op        (ctrl_mem[`CTRL_CSR_OP]),
    .csr_wdata     (csr_wdata),
    .csr_rdata     (csr_rdata),
    .trap_enter    (trap_enter),
    .trap_cause    (trap_cause),
    .trap_val      (trap_val),
    .trap_pc       (pc_mem),
    .mtvec_out     (mtvec_out),
    .mepc_out      (mepc_out),
    .mret          (mret_ex),
    .ext_irq       (ext_irq),
    .timer_irq     (timer_irq),
    .instr_retired (ctrl_wb[`CTRL_REG_WR] || ctrl_wb[`CTRL_MEM_WR] || ctrl_wb[`CTRL_ECALL]),
    .irq_pending   (irq_pending)
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
    .ex_wb_sel        (ctrl_ex[`CTRL_WB_SEL]),
    .mem_rd           (rd_addr_mem),
    .mem_reg_wr       (ctrl_mem[`CTRL_REG_WR]),
    .wb_rd            (rd_addr_wb),
    .wb_reg_wr        (ctrl_wb[`CTRL_REG_WR]),
    .branch_mispredict(branch_mispredict_ex || trap_enter || mret_ex),
    .jump_ex          (ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR]),
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
