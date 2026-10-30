// ============================================================================
// gf_unit.v — Xbrvdsp finite-field step: packed GF(2^8) multiply
// ============================================================================
// Four independent byte lanes, each multiplied in GF(2^8) modulo
// P = x^8 + poly, where poly (P less its x^8 term) is held in an 8-bit
// register (custom-0 opcode, funct3 101; doc/finite_fields.md):
//   funct7 0: gfmul4 rd, rs1, rs2   rd.byte[i] = rs1.byte[i] * rs2.byte[i] mod P
//   funct7 1: gf.cfg rs1            poly = rs1[7:0]           (rd 0, rs2 0)
//   funct7 2: gf.rd  rd             rd = poly, zero-extended  (rs1 0, rs2 0)
// poly resets to 0x1D (P = 0x11D, the usual Reed-Solomon field); AES's is
// 0x1B. Any poly gives a well-defined product; it is a field only when P is
// irreducible.
//
// Each lane forms the 15-bit carry-less product, then folds its top seven
// bits back with x^(8+j) mod P (j = 0..6), which depend only on poly. The
// unit is combinational in EX, like zk_unit.v. poly changes only when
// `update` is high (the core's EX-to-MEM condition, as for acc), so a
// gf.cfg that is flushed never takes effect, and the gfmul4 right after a
// gf.cfg already sees the new poly.
// ============================================================================

module gf_unit (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        update,      // apply a gf.cfg now
  input  wire [6:0]  funct7,
  input  wire [31:0] a,
  input  wire [31:0] b,
  output reg  [31:0] result
);

  reg [7:0] poly;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      poly <= 8'h1D;
    else if (update && funct7 == 7'b0000001)
      poly <= a[7:0];
  end

  // red_j = x^(8+j) mod P: each is the one before times x
  function [7:0] xtime;
    input [7:0] v, pl;
    xtime = {v[6:0], 1'b0} ^ (v[7] ? pl : 8'h00);
  endfunction

  wire [7:0] red0 = poly;
  wire [7:0] red1 = xtime(red0, poly);
  wire [7:0] red2 = xtime(red1, poly);
  wire [7:0] red3 = xtime(red2, poly);
  wire [7:0] red4 = xtime(red3, poly);
  wire [7:0] red5 = xtime(red4, poly);
  wire [7:0] red6 = xtime(red5, poly);

  function [7:0] gfmul;
    input [7:0] x, y;
    input [55:0] r;              // red6..red0, packed
    reg   [14:0] p;
    integer k;
    begin
      p = 15'd0;
      for (k = 0; k < 8; k = k + 1)
        if (y[k]) p = p ^ ({7'd0, x} << k);
      gfmul = p[7:0];
      for (k = 0; k < 7; k = k + 1)
        if (p[8 + k]) gfmul = gfmul ^ r[8*k +: 8];
    end
  endfunction

  wire [55:0] red_p = {red6, red5, red4, red3, red2, red1, red0};

  always @(*) begin
    case (funct7)
      7'b0000010: result = {24'd0, poly};                            // gf.rd
      default:    result = {gfmul(a[31:24], b[31:24], red_p), gfmul(a[23:16], b[23:16], red_p),
                            gfmul(a[15:8],  b[15:8],  red_p), gfmul(a[7:0],   b[7:0],   red_p)};
    endcase
  end

endmodule
