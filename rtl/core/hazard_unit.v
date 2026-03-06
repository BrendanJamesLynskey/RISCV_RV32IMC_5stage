// ============================================================================
// hazard_unit.v — Pipeline Hazard Detection & Data Forwarding
// ============================================================================

module hazard_unit (
  // ID stage register addresses (for load-use hazard detection)
  input  wire [4:0]  id_rs1,
  input  wire [4:0]  id_rs2,

  // EX stage register addresses (for forwarding MUX control)
  input  wire [4:0]  ex_rs1,
  input  wire [4:0]  ex_rs2,

  // EX stage info
  input  wire [4:0]  ex_rd,
  input  wire        ex_reg_wr,
  input  wire        ex_mem_rd,     // Load in EX -> stall
  input  wire [2:0]  ex_wb_sel,

  // MEM stage info
  input  wire [4:0]  mem_rd,
  input  wire        mem_reg_wr,

  // WB stage info
  input  wire [4:0]  wb_rd,
  input  wire        wb_reg_wr,

  // Control hazards
  input  wire        branch_mispredict,
  input  wire        jump_ex,        // JAL/JALR resolved in EX

  // MulDiv stall
  input  wire        muldiv_busy,

  // Forwarding outputs
  output reg  [1:0]  fwd_rs1,
  output reg  [1:0]  fwd_rs2,

  // Pipeline control
  output reg         stall_if,
  output reg         stall_id,
  output reg         stall_ex,
  output reg         flush_id,
  output reg         flush_ex,
  output reg         flush_mem
);

  `include "brv32p_defs.vh"

  // ── Load-use hazard detection ────────────────────────────────────────
  wire load_use_hazard;
  assign load_use_hazard = ex_mem_rd && (ex_rd != 5'd0) &&
                           ((ex_rd == id_rs1) || (ex_rd == id_rs2));

  // ── Data forwarding (based on EX stage addresses) ──────────────────
  always @(*) begin
    // RS1 forwarding
    if (mem_reg_wr && (mem_rd != 5'd0) && (mem_rd == ex_rs1))
      fwd_rs1 = FWD_EX_MEM;
    else if (wb_reg_wr && (wb_rd != 5'd0) && (wb_rd == ex_rs1))
      fwd_rs1 = FWD_MEM_WB;
    else
      fwd_rs1 = FWD_NONE;

    // RS2 forwarding
    if (mem_reg_wr && (mem_rd != 5'd0) && (mem_rd == ex_rs2))
      fwd_rs2 = FWD_EX_MEM;
    else if (wb_reg_wr && (wb_rd != 5'd0) && (wb_rd == ex_rs2))
      fwd_rs2 = FWD_MEM_WB;
    else
      fwd_rs2 = FWD_NONE;
  end

  // ── Stall / Flush logic ──────────────────────────────────────────────
  always @(*) begin
    stall_if  = 1'b0;
    stall_id  = 1'b0;
    stall_ex  = 1'b0;
    flush_id  = 1'b0;
    flush_ex  = 1'b0;
    flush_mem = 1'b0;

    // MulDiv stall: freeze IF/ID/EX until done
    if (muldiv_busy) begin
      stall_if = 1'b1;
      stall_id = 1'b1;
      stall_ex = 1'b1;
    end
    // Load-use: stall IF and ID, insert bubble in EX
    else if (load_use_hazard) begin
      stall_if = 1'b1;
      stall_id = 1'b1;
      flush_ex = 1'b1;   // Bubble
    end

    // Branch mispredict: flush IF, ID, EX (instructions fetched after branch)
    if (branch_mispredict) begin
      flush_id  = 1'b1;
      flush_ex  = 1'b1;
      // Override stalls — flush takes priority
      stall_if  = 1'b0;
      stall_id  = 1'b0;
    end
  end

endmodule
