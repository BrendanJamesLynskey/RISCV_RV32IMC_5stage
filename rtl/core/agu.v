// ============================================================================
// agu.v — Xbrvdsp step 2: address generators
// ============================================================================
// Four address registers, ar0-ar3, each an address and a signed 16-bit stride
// in bytes. Instructions (custom-1 opcode; doc/dsp_extension.md):
//   funct3 000, R-type, N in the rd field (rd[4:2] = 0), rs2 = 0:
//     ar.set arN, rs1   (funct7 0)  addr = rs1
//     ar.cfg arN, rs1   (funct7 1)  stride = rs1[15:0]
//     ar.mode arN, rs1  (funct7 3)  bit-reversed mode = rs1[0]
//   funct3 001 / 010 / 101, I-type, rs1 = 0, imm = N:
//     lh.a / lw.a / lhu.a rd, arN   rd = mem[addr]; addr += stride
//   funct3 011, I-type, rs1 = 0, imm = N (+4 for the stride, +12 the mode):
//     ar.rd rd, arN     rd = addr;   ar.rds rd, arN   rd = sext(stride)
//     ar.rdm rd, arN    rd = the bit-reversed mode bit (0 or 1)
//
// Bit-reversed mode (step 5b), set by ar.mode. A load then steps
// the low 16 bits of addr by reverse-carry addition,
//   addr[15:0] = rev16(rev16(addr[15:0]) + rev16(stride)),
// which carries from high bits to low; the carry stops at the element size
// (the bits below it, bit 0 for lh.a and bits 1:0 for lw.a, keep their
// value), which is where the sequence wraps round. With stride = N/2
// elements (in bytes) and the buffer aligned to its size, the loads visit
// the elements in bit-reversed order, as an FFT's input permutation needs.
//
// Like the accumulator, the registers change only when `update` is high: the
// core raises it for a valid AGU instruction as it moves from EX to MEM, not
// if it is being flushed, and not if the load is misaligned (it traps, and
// runs again after the handler). Loads read addr in EX, after every older
// update, so back-to-back loads on one register need no forwarding.
// ============================================================================

module agu (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        update,      // apply this AGU instruction now
  input  wire [31:0] insn,        // the instruction in EX
  input  wire [31:0] a,           // forwarded rs1 (ar.set, ar.cfg)
  output wire [31:0] addr,        // the load address: addr of arN
  output wire [31:0] result       // ar.rd / ar.rds
);

  reg  [31:0] ar_addr   [0:3];
  reg  [15:0] ar_stride [0:3];
  reg         ar_br     [0:3];      // bit-reversed mode

  wire [2:0] funct3 = insn[14:12];
  wire [6:0] funct7  = insn[31:25];
  wire       is_set  = (funct3 == 3'b000) &&                       // not lp.set (funct7 2: loop_unit.v)
                       (funct7 == 7'd0 || funct7 == 7'd1 || funct7 == 7'd3);
  wire       is_load = (funct3 == 3'b001) || (funct3 == 3'b010) || (funct3 == 3'b101);
  wire [1:0] n      = is_set ? insn[8:7] : insn[21:20];   // rd field, or imm

  assign addr   = ar_addr[n];
  assign result = (insn[23:22] == 2'b11) ? {31'd0, ar_br[n]} :
                  insn[22]               ? {{16{ar_stride[n][15]}}, ar_stride[n]} : ar_addr[n];

  function [15:0] rev16(input [15:0] v);
    integer k;
    for (k = 0; k < 16; k = k + 1)
      rev16[k] = v[15 - k];
  endfunction

  wire [15:0] br_sum  = rev16(rev16(ar_addr[n][15:0]) + rev16(ar_stride[n]));
  wire [1:0]  br_keep = (funct3[1:0] == 2'b10) ? 2'b11 : 2'b01;   // below the element: word, half
  wire [15:0] br_next = {br_sum[15:2],
                         br_keep[1] ? ar_addr[n][1] : br_sum[1],
                         ar_addr[n][0]};

  integer i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < 4; i = i + 1) begin
        ar_addr[i]   <= 32'd0;
        ar_stride[i] <= 16'd0;
        ar_br[i]     <= 1'b0;
      end
    end else if (update) begin
      if (is_set) begin
        if (funct7 == 7'd3)
          ar_br[n]     <= a[0];                                  // ar.mode
        else if (funct7 == 7'd1)
          ar_stride[n] <= a[15:0];                               // ar.cfg
        else
          ar_addr[n]   <= a;                                     // ar.set
      end else if (is_load) begin
        if (ar_br[n])
          ar_addr[n][15:0] <= br_next;                           // load: bit-reversed step
        else
          ar_addr[n] <= ar_addr[n] + {{16{ar_stride[n][15]}}, ar_stride[n]};   // load: step
      end
    end
  end

endmodule
