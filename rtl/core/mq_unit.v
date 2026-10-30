// ============================================================================
// mq_unit.v — Xbrvdsp modular arithmetic: packed 2 x 16-bit mod q, for NTTs
// ============================================================================
// Two independent 16-bit lanes of arithmetic modulo an odd q held in state,
// with Montgomery multiplication (R = 2^16). Custom-0 opcode, funct3 110
// (doc/lattice_crypto.md):
//   funct7 0: mqmul2 rd, rs1, rs2   lane: mont(rs1 * rs2)
//   funct7 1: mqadd2 rd, rs1, rs2   lane: addq(rs1, rs2)
//   funct7 2: mqsub2 rd, rs1, rs2   lane: subq(rs1, rs2)
//   funct7 3: ctadd2 rd, rs1, rs2   lane: addq(rs1, mont(zeta * rs2))
//   funct7 4: ctsub2 rd, rs1, rs2   lane: subq(rs1, mont(zeta * rs2))
//   funct7 9: gsmul2 rd, rs1, rs2   lane: mont(zeta * subq(rs2, rs1))
//   funct7 5: mq.cfg  rs1           q = rs1[15:0], qp = rs1[31:16]; zeta = 0  (rd 0, rs2 0)
//   funct7 6: mq.zeta rs1           zeta = rs1[15:0]                          (rd 0, rs2 0)
//   funct7 7: mq.rd   rd            rd = {qp, q}                              (rs1 0, rs2 0)
//   funct7 8: mq.rdz  rd            rd = zeta, zero-extended                  (rs1 0, rs2 0)
// with, all unsigned:
//   mont(p)   t = (p + ((p * qp) mod 2^16) * q) >> 16; t >= q ? t - q : t
//   addq(a,b) s = a + b;  s >= q ? s - q : s
//   subq(a,b) a >= b ? a - b : a - b + q
// each lane's result being bits [15:0]. qp must be -q^-1 mod 2^16, so that
// the sum is a multiple of 2^16 and mont(p) = p * 2^-16 mod q: with lanes
// below q it is exact and the result is below q (every lane's arithmetic is
// defined for any value, so the Spike model can match it bit for bit).
// q, qp reset to ML-KEM's 3329 and 3327; zeta resets to 0.
//
// ctadd2 and ctsub2 are the two halves of a Cooley-Tukey butterfly
// (a + zeta*b, a - zeta*b), gsmul2 the multiply of a Gentleman-Sande one
// (zeta*(b - a); a + b is mqadd2), on two coefficient pairs at once: the
// same zeta in both lanes, set once per block of butterflies by mq.zeta. A
// multiply by zeta alone is ctadd2 with rs1 = x0.
//
// The unit spans EX and MEM, like the RV32M multiply (brv32p_core.v), with
// at most one multiplier in series in each stage. mq.zeta also keeps
// zqp = zeta * qp mod 2^16, so that for the zeta instructions EX forms both
// the products zeta * b and the Montgomery quotients m = zqp * b mod 2^16
// (gsmul2 first takes b - a mod q), registered here at the end of EX; MEM
// adds m * q, shifts, reduces and adds or subtracts. (mq.cfg clears zeta,
// and so zqp, which would otherwise be stale for the new qp.) mqmul2's
// quotient depends on the product, so it takes two cycles in MEM: the first
// forms m from the registered product and stalls the pipeline (`stall`, as
// a D-cache wait does), the second finishes. The hazard unit holds an
// instruction that uses a result for one cycle, as after a multiply. State
// changes only when `update` is high (the EX-to-MEM condition, as for acc
// and poly), so a flushed mq.cfg or mq.zeta never takes effect; an older
// instruction in MEM still sees the old q, and a younger one in EX already
// sees the new zeta.
// ============================================================================

module mq_unit (
  input  wire        clk,
  input  wire        rst_n,
  // EX
  input  wire        update,      // apply an mq.cfg / mq.zeta now
  input  wire        load,        // an mq instruction is moving to MEM
  input  wire [6:0]  funct7_ex,
  input  wire [31:0] a_ex,
  input  wire [31:0] b_ex,
  // MEM
  input  wire        in_mem,      // MEM holds an mq instruction that writes rd
  input  wire        hold,        // the pipeline is held this cycle (mem_stall)
  input  wire [6:0]  funct7_mem,
  input  wire [31:0] a_mem,
  input  wire [31:0] b_mem,
  output reg  [31:0] result_mem,
  output wire        stall        // mqmul2's first MEM cycle
);

  localparam [6:0] F_MUL = 7'd0, F_ADD = 7'd1, F_SUB = 7'd2, F_CTADD = 7'd3, F_CTSUB = 7'd4,
                   F_CFG = 7'd5, F_ZETA = 7'd6, F_RD = 7'd7, F_RDZ = 7'd8, F_GSMUL = 7'd9;

  reg [15:0] q, qp, zeta, zqp;

  function [15:0] addq;
    input [15:0] a, b, q_;
    reg   [16:0] s;
    begin
      s    = {1'b0, a} + {1'b0, b};
      addq = (s >= {1'b0, q_}) ? s[15:0] - q_ : s[15:0];
    end
  endfunction

  function [15:0] subq;
    input [15:0] a, b, q_;
    begin
      subq = (a >= b) ? a - b : a - b + q_;
    end
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q    <= 16'd3329;
      qp   <= 16'd3327;
      zeta <= 16'd0;
      zqp  <= 16'd0;
    end else if (update) begin
      if (funct7_ex == F_CFG) begin
        q    <= a_ex[15:0];
        qp   <= a_ex[31:16];
        zeta <= 16'd0;
        zqp  <= 16'd0;
      end else if (funct7_ex == F_ZETA) begin
        zeta <= a_ex[15:0];
        zqp  <= a_ex[15:0] * qp;
      end
    end
  end

  // ── EX: products and (for the zeta instructions) quotients ──────────
  wire        by_zeta = funct7_ex == F_CTADD || funct7_ex == F_CTSUB || funct7_ex == F_GSMUL;
  wire        gs      = funct7_ex == F_GSMUL;
  wire [15:0] d_lo = gs ? subq(b_ex[15:0],  a_ex[15:0],  q) : b_ex[15:0];
  wire [15:0] d_hi = gs ? subq(b_ex[31:16], a_ex[31:16], q) : b_ex[31:16];
  wire [15:0] x_lo = by_zeta ? zeta : a_ex[15:0];
  wire [15:0] x_hi = by_zeta ? zeta : a_ex[31:16];
  reg  [31:0] p_lo, p_hi;
  reg  [15:0] m_lo, m_hi;

  // ── MEM: mqmul2's first cycle forms its quotients ───────────────────
  reg  phase;                                  // mqmul2's second MEM cycle
  wire mul_mem = in_mem && funct7_mem == F_MUL;
  assign stall = mul_mem && !phase;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      phase <= 1'b0;
    else
      phase <= mul_mem && hold;                // still in MEM next cycle
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_lo <= 32'd0;
      p_hi <= 32'd0;
      m_lo <= 16'd0;
      m_hi <= 16'd0;
    end else if (load) begin
      p_lo <= x_lo * d_lo;
      p_hi <= x_hi * d_hi;
      m_lo <= by_zeta ? zqp * d_lo : 16'd0;
      m_hi <= by_zeta ? zqp * d_hi : 16'd0;
    end else if (stall) begin
      m_lo <= p_lo[15:0] * qp;
      m_hi <= p_hi[15:0] * qp;
    end
  end

  // ── MEM: reduce, then add or subtract ───────────────────────────────
  function [15:0] reduce;                      // (p + m q) >> 16, less q if not below it
    input [31:0] p;
    input [15:0] m, q_;
    reg   [32:0] s;
    begin
      s      = {1'b0, p} + m * q_;
      reduce = (s[32:16] >= {1'b0, q_}) ? s[31:16] - q_ : s[31:16];
    end
  endfunction

  wire [15:0] r_lo = reduce(p_lo, m_lo, q);
  wire [15:0] r_hi = reduce(p_hi, m_hi, q);

  always @(*) begin
    case (funct7_mem)
      F_ADD:   result_mem = {addq(a_mem[31:16], b_mem[31:16], q), addq(a_mem[15:0], b_mem[15:0], q)};
      F_SUB:   result_mem = {subq(a_mem[31:16], b_mem[31:16], q), subq(a_mem[15:0], b_mem[15:0], q)};
      F_CTADD: result_mem = {addq(a_mem[31:16], r_hi, q), addq(a_mem[15:0], r_lo, q)};
      F_CTSUB: result_mem = {subq(a_mem[31:16], r_hi, q), subq(a_mem[15:0], r_lo, q)};
      F_RD:    result_mem = {qp, q};
      F_RDZ:   result_mem = {16'd0, zeta};
      default: result_mem = {r_hi, r_lo};                       // mqmul2, gsmul2
    endcase
  end

endmodule
