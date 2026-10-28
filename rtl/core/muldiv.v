// ============================================================================
// muldiv.v — Multiply / Divide Unit (RV32M Extension)
// ============================================================================
// Single-cycle multiply, iterative restoring divide (32 steps, plus a done
// cycle). Stalls the pipeline via 'busy' during the division. The done state
// holds its result while 'hold' (a pipeline stall) keeps the instruction in EX.
// Operands are captured when a division starts, because forwarded operand
// values are not stable while EX waits.
// ============================================================================

module muldiv (
  input  wire        clk,
  input  wire        rst_n,

  input  wire        start,
  input  wire        hold,       // pipeline stalled: keep a finished result
  input  wire        kill,       // instruction in EX flushed: abandon a division
  input  wire [2:0]  op,
  input  wire [31:0] a,          // rs1
  input  wire [31:0] b,          // rs2
  output reg  [31:0] result,
  output reg         busy,
  output reg         valid       // Result ready this cycle
);

  `include "brv32p_defs.vh"

  // ── Multiply (single-cycle) ───────────────────────────────────────────
  wire signed [63:0] mul_ss;
  wire signed [63:0] mul_su;
  wire        [63:0] mul_uu;

  assign mul_ss = $signed(a) * $signed(b);
  assign mul_su = $signed(a) * $signed({1'b0, b});
  assign mul_uu = $unsigned(a) * $unsigned(b);

  // ── Divide (iterative, 33 cycles) ────────────────────────────────────
  reg        div_active;
  reg [5:0]  div_count;
  reg        div_signed_r;
  reg        div_rem;
  reg        negate_result;
  reg        negate_remainder;
  reg [31:0] dividend;
  reg [31:0] divisor_reg;
  reg [63:0] div_acc;    // {remainder, quotient} shift register

  reg [31:0] div_result;
  wire       div_done;

  assign div_done = div_active && (div_count == 6'd32);

  // Hoisted local variables
  reg [31:0] abs_a, abs_b;
  reg [32:0] rem_sh, trial;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_active       <= 1'b0;
      div_count        <= 6'd0;
      div_acc          <= 64'd0;
      divisor_reg      <= 32'd0;
      div_signed_r     <= 1'b0;
      div_rem          <= 1'b0;
      negate_result    <= 1'b0;
      negate_remainder <= 1'b0;
    end else if (kill) begin
      div_active       <= 1'b0;
    end else if (start && !div_active &&
                 (op == MD_DIV || op == MD_DIVU || op == MD_REM || op == MD_REMU)) begin
      div_active <= 1'b1;
      div_count  <= 6'd0;
      dividend   <= a;      // for the remainder of a division by zero

      div_signed_r <= (op == MD_DIV) || (op == MD_REM);
      div_rem      <= (op == MD_REM) || (op == MD_REMU);

      // Handle signs for signed division
      if ((op == MD_DIV) || (op == MD_REM)) begin
        abs_a = a[31] ? (~a + 1) : a;
        abs_b = b[31] ? (~b + 1) : b;
        div_acc     <= {32'd0, abs_a};
        divisor_reg <= abs_b;
        negate_result    <= a[31] ^ b[31];
        negate_remainder <= a[31];
      end else begin
        div_acc     <= {32'd0, a};
        divisor_reg <= b;
        negate_result    <= 1'b0;
        negate_remainder <= 1'b0;
      end
    end else if (div_active) begin
      if (div_count < 6'd32) begin
        // Restoring division step. div_acc = {remainder, dividend/quotient}:
        // shift the next dividend bit into the remainder, then try to
        // subtract the divisor (33 bits, so a remainder >= 2^31 is safe)
        rem_sh = {div_acc[63:32], div_acc[31]};
        trial  = rem_sh - {1'b0, divisor_reg};
        if (!trial[32])
          div_acc <= {trial[31:0], div_acc[30:0], 1'b1};
        else
          div_acc <= {rem_sh[31:0], div_acc[30:0], 1'b0};
        div_count <= div_count + 1'b1;
      end else if (!hold) begin
        div_active <= 1'b0;       // result taken by the pipeline
      end
    end
  end

  // Division result select
  always @(*) begin
    if (div_rem) begin
      div_result = negate_remainder ? (~div_acc[63:32] + 1) : div_acc[63:32];
    end else begin
      div_result = negate_result ? (~div_acc[31:0] + 1) : div_acc[31:0];
    end
    // Division by zero
    if (divisor_reg == 32'd0) begin
      if (div_rem)
        div_result = dividend;
      else
        div_result = 32'hFFFF_FFFF;
    end
  end

  // ── Output MUX ────────────────────────────────────────────────────────
  wire is_mul;
  assign is_mul = (op == MD_MUL || op == MD_MULH || op == MD_MULHSU || op == MD_MULHU);

  wire is_div = (op == MD_DIV || op == MD_DIVU || op == MD_REM || op == MD_REMU);

  always @(*) begin
    valid  = 1'b0;
    // Busy from the cycle a division starts, so the instruction stays in EX
    busy   = (start && is_div && !div_active) || (div_active && !div_done);
    result = 32'b0;

    if (start && !div_active && is_mul) begin
      valid = 1'b1;
      case (op)
        MD_MUL:    result = mul_ss[31:0];
        MD_MULH:   result = mul_ss[63:32];
        MD_MULHSU: result = mul_su[63:32];
        MD_MULHU:  result = mul_uu[63:32];
        default:   result = 32'b0;
      endcase
    end else if (div_done) begin
      valid  = 1'b1;
      result = div_result;
    end
  end

endmodule
