// ============================================================================
// dsp_unit.v — Xbrvdsp step 1: the multiply-accumulate unit
// ============================================================================
// A 40-bit accumulator (8 guard bits over a 32-bit sum of products) and the
// instructions that use it (custom-0 opcode; doc/dsp_extension.md):
//   funct3 000: mac (funct7 0), dmac (1), msu (2), acc.set (4),
//               acc.seth (5, acc[39:32] = rs1[7:0]): update acc
//   funct3 001: acc.rd  rd, sh   rd = sat32((acc + round) >> sh)
//   funct3 010: acc.rdh rd, sh   rd = sat16((acc + round) >> sh)
//   funct3 011: acc.rdl rd (funct7 0) = acc[31:0]; acc.rdx rd (1) =
//               sext(acc[39:32]). With acc.set and acc.seth they give exact
//               readback and save/restore of all 40 bits.
//   funct3 100: sadd rd, rs1, rs2 (funct7 0) = sat32(rs1 + rs2);
//               ssub (funct7 1) = sat32(rs1 - rs2);
//               radd16 (funct7 2) = per 16-bit half, (rs1 + rs2) >> 1;
//               rsub16 (funct7 3) = per half, (rs1 - rs2) >> 1 (signed,
//               rounding down: exact, never overflows);
//               pk16 (funct7 4) = {rs1[15:0], rs2[15:0]}. They do not use acc.
// round is 2^(sh-1), or 0 when sh is 0. a and b are the forwarded rs1 and
// rs2; sh is the rs2 field.
//
// acc changes only when `update` is high: the core raises it for a valid
// accumulator instruction as it moves from EX to MEM, and not if it is being
// flushed, so a MAC squashed by an interrupt or an older exception never
// touches acc. acc.rd reads acc in EX, after every older MAC has updated it,
// so back-to-back use needs no forwarding.
// ============================================================================

module dsp_unit (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        update,      // apply this accumulator instruction now
  input  wire [6:0]  funct7,
  input  wire [2:0]  funct3,
  input  wire [31:0] a,
  input  wire [31:0] b,
  input  wire [4:0]  sh,
  output reg  [31:0] result       // acc.rd / acc.rdh
);

  reg  signed [39:0] acc;

  wire signed [31:0] p_lo = $signed(a[15:0])  * $signed(b[15:0]);
  wire signed [31:0] p_hi = $signed(a[31:16]) * $signed(b[31:16]);
  wire signed [39:0] p_lo_x = {{8{p_lo[31]}}, p_lo};
  wire signed [39:0] p_hi_x = {{8{p_hi[31]}}, p_hi};

  reg  signed [39:0] acc_next;
  always @(*) begin
    case (funct7)
      7'b0000001: acc_next = acc + p_lo_x + p_hi_x;            // dmac
      7'b0000010: acc_next = acc - p_lo_x;                     // msu
      7'b0000100: acc_next = {{8{a[31]}}, a};                  // acc.set
      7'b0000101: acc_next = {a[7:0], acc[31:0]};              // acc.seth
      default:    acc_next = acc + p_lo_x;                     // mac
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      acc <= 40'sd0;
    else if (update && funct3 == 3'b000)
      acc <= acc_next;
  end

  // Read: round, shift right arithmetically, saturate
  wire signed [40:0] rnd     = (sh == 5'd0) ? 41'sd0 : (41'sd1 <<< (sh - 5'd1));
  wire signed [40:0] summed  = {acc[39], acc} + rnd;
  wire signed [40:0] shifted = summed >>> sh;
  wire               over32  = shifted >  41'sd2147483647;
  wire               under32 = shifted < -41'sd2147483648;
  wire               over16  = shifted >  41'sd32767;
  wire               under16 = shifted < -41'sd32768;

  // Saturating add and subtract: 33-bit result, clamped to 32 bits
  wire signed [32:0] s_sum = funct7[0] ? ($signed({a[31], a}) - $signed({b[31], b}))
                                       : ($signed({a[31], a}) + $signed({b[31], b}));
  wire [31:0] s_sat = (s_sum[32] != s_sum[31]) ? (s_sum[32] ? 32'h8000_0000 : 32'h7FFF_FFFF)
                                               : s_sum[31:0];

  // Packed halves: 17-bit sum or difference of each signed half, halved
  wire signed [16:0] h_lo = funct7[0] ? ($signed({a[15], a[15:0]})  - $signed({b[15], b[15:0]}))
                                      : ($signed({a[15], a[15:0]})  + $signed({b[15], b[15:0]}));
  wire signed [16:0] h_hi = funct7[0] ? ($signed({a[31], a[31:16]}) - $signed({b[31], b[31:16]}))
                                      : ($signed({a[31], a[31:16]}) + $signed({b[31], b[31:16]}));

  always @(*) begin
    if (funct3 == 3'b100)
      result = funct7[2] ? {a[15:0], b[15:0]} :            // pk16
               funct7[1] ? {h_hi[16:1], h_lo[16:1]} :     // radd16, rsub16
                           s_sat;                          // sadd, ssub
    else if (funct3 == 3'b011)
      result = funct7[0] ? {{24{acc[39]}}, acc[39:32]} : acc[31:0];
    else if (funct3 == 3'b010)
      result = over16 ? 32'h0000_7FFF : under16 ? 32'hFFFF_8000 : {{16{shifted[15]}}, shifted[15:0]};
    else
      result = over32 ? 32'h7FFF_FFFF : under32 ? 32'h8000_0000 : shifted[31:0];
  end

endmodule
