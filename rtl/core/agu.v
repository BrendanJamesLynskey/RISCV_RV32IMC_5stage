// ============================================================================
// agu.v — Xbrvdsp step 2: address generators
// ============================================================================
// Four address registers, ar0-ar3, each an address and a signed 16-bit stride
// in bytes. Instructions (custom-1 opcode; doc/dsp_extension.md):
//   funct3 000, R-type, N in the rd field (rd[4:2] = 0), rs2 = 0:
//     ar.set arN, rs1   (funct7 0)  addr = rs1
//     ar.cfg arN, rs1   (funct7 1)  stride = rs1[15:0]
//   funct3 001 / 010 / 101, I-type, rs1 = 0, imm = N:
//     lh.a / lw.a / lhu.a rd, arN   rd = mem[addr]; addr += stride
//   funct3 011, I-type, rs1 = 0, imm = N (+4 for the stride):
//     ar.rd rd, arN     rd = addr;   ar.rds rd, arN   rd = sext(stride)
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

  wire [2:0] funct3 = insn[14:12];
  wire       is_set = (funct3 == 3'b000);
  wire [1:0] n      = is_set ? insn[8:7] : insn[21:20];   // rd field, or imm

  assign addr   = ar_addr[n];
  assign result = insn[22] ? {{16{ar_stride[n][15]}}, ar_stride[n]} : ar_addr[n];

  integer i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < 4; i = i + 1) begin
        ar_addr[i]   <= 32'd0;
        ar_stride[i] <= 16'd0;
      end
    end else if (update) begin
      if (is_set) begin
        if (insn[25])
          ar_stride[n] <= a[15:0];                               // ar.cfg
        else
          ar_addr[n]   <= a;                                     // ar.set
      end else if (funct3 != 3'b011) begin
        ar_addr[n] <= ar_addr[n] + {{16{ar_stride[n][15]}}, ar_stride[n]};   // load: step
      end
    end
  end

endmodule
