// ============================================================================
// loop_unit.v — Xbrvdsp step 4: the hardware loop
// ============================================================================
// State: lc, the loop count, and lp_start, where the body begins. The body's
// last instruction is marked: mac.lp / dmac.lp / msu.lp (custom-0, funct7
// bit 6 set) or lp.end (custom-1, funct3 111). After it, if lc > 1, lc is
// decremented and execution goes to lp_start; otherwise lc becomes 0 and
// execution falls through. So lp.setup with a count of n runs the body n
// times (once for n = 0 or 1).
//   lp.setup rs1      custom-1, funct3 110, rd 0, imm 0: lc = rs1, lp_start = pc + 4
//   lp.set   rs1      custom-1, funct3 000, funct7 0000010, rd 0: lc = rs1
//   lp.sets  rs1      ... rd 1: lp_start = rs1        (with lp.rd: save/restore)
//   lp.rd    rd       custom-1, funct3 011, imm 8: rd = lc; imm 9: rd = lp_start
//
// The loop-back works as a branch: the core resolves a marked instruction in
// EX like a branch (taken = lc > 1, target lp_start), so the branch
// predictor learns it and predicts it taken, and the last iteration is an
// ordinary mispredict. The state changes only when `update` is high, under
// the same rule as acc and the address registers (as the instruction leaves
// EX, not if it is flushed), so a marked instruction squashed by an
// interrupt does not count.
// ============================================================================

module loop_unit (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        update,      // apply this instruction now
  input  wire        valid,       // the instruction in EX is real and legal
  input  wire [31:0] insn,        // the instruction in EX
  input  wire [31:0] pc,          // its pc
  input  wire [31:0] a,           // forwarded rs1
  output wire        loop_end,    // it ends a loop body
  output wire        loop_back,   // ... and the loop goes round again
  output wire [31:0] start,       // lp_start
  output wire [31:0] result       // lp.rd
);

  reg [31:0] lc;
  reg [31:0] lp_start;

  wire [6:0] opcode = insn[6:0];
  wire [2:0] funct3 = insn[14:12];
  wire       custom0 = (opcode == 7'b0001011);
  wire       custom1 = (opcode == 7'b0101011);

  wire is_setup = custom1 && funct3 == 3'b110;
  wire is_set   = custom1 && funct3 == 3'b000 && insn[31:25] == 7'b0000010;

  assign loop_end  = valid && ((custom0 && funct3 == 3'b000 && insn[31]) ||
                               (custom1 && funct3 == 3'b111));
  assign loop_back = loop_end && (lc > 32'd1);
  assign start     = lp_start;
  assign result    = insn[20] ? lp_start : lc;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lc       <= 32'd0;
      lp_start <= 32'd0;
    end else if (update) begin
      if (is_setup) begin
        lc       <= a;
        lp_start <= pc + 32'd4;
      end else if (is_set) begin
        if (insn[7]) lp_start <= a;
        else         lc       <= a;
      end else if (loop_end) begin
        lc <= loop_back ? lc - 32'd1 : 32'd0;
      end
    end
  end

endmodule
