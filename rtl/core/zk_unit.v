// ============================================================================
// zk_unit.v — ratified scalar cryptography for RV32: Zbkb and Zknh
// ============================================================================
// Zbkb (bit manipulation for cryptography):
//   ror, rol, rori; andn, orn, xnor; pack, packh; brev8, rev8; zip, unzip
// Zknh (SHA-2):
//   sha256sig0, sha256sig1, sha256sum0, sha256sum1 (one source);
//   sha512sig0l/h, sha512sig1l/h, sha512sum0r, sha512sum1r (two sources:
//   SHA-512's 64-bit words as two 32-bit halves, RV32's form)
// The encodings are the standard ones (OP and OP-IMM); the decoder sends
// them here, and EX takes the result through the extension write-back
// select. One cycle, no state. a and b are the forwarded rs1 and rs2.
// ============================================================================

module zk_unit (
  input  wire [31:0] insn,        // the instruction in EX
  input  wire [31:0] a,           // rs1
  input  wire [31:0] b,           // rs2
  output reg  [31:0] result
);

  wire [6:0]  opcode = insn[6:0];
  wire [2:0]  funct3 = insn[14:12];
  wire [6:0]  funct7 = insn[31:25];
  wire [11:0] imm    = insn[31:20];
  wire        is_imm = (opcode == 7'b0010011);
  wire [4:0]  sh     = is_imm ? insn[24:20] : b[4:0];
  // One barrel rotator for ror, rori and rol: rotating left by n is rotating
  // right by (32 - n) mod 32
  wire        is_rol = !is_imm && funct3 == 3'b001;
  wire [31:0] rot    = rotr(a, is_rol ? (5'd0 - sh) : sh);

  function [31:0] rotr(input [31:0] v, input [4:0] n);
    rotr = (v >> n) | (v << (6'd32 - {1'b0, n}));
  endfunction

  function [31:0] brev8(input [31:0] v);
    integer k;
    for (k = 0; k < 32; k = k + 1)
      brev8[k] = v[(k & ~7) + 7 - (k & 7)];
  endfunction

  function [31:0] zip32(input [31:0] v);         // bit 2i = v[i], bit 2i+1 = v[i+16]
    integer k;
    for (k = 0; k < 16; k = k + 1) begin
      zip32[2*k]     = v[k];
      zip32[2*k + 1] = v[k + 16];
    end
  endfunction

  function [31:0] unzip32(input [31:0] v);       // the inverse
    integer k;
    for (k = 0; k < 16; k = k + 1) begin
      unzip32[k]      = v[2*k];
      unzip32[k + 16] = v[2*k + 1];
    end
  endfunction

  always @(*) begin
    result = 32'd0;
    if (is_imm) begin
      if (funct3 == 3'b101) begin
        if (funct7 == 7'b0110000)   result = rot;                                  // rori
        else if (imm == 12'h687)    result = brev8(a);
        else if (imm == 12'h698)    result = {a[7:0], a[15:8], a[23:16], a[31:24]};  // rev8
        else                        result = unzip32(a);                           // unzip (0x08f)
      end else begin
        case (imm)
          12'h08f: result = zip32(a);
          12'h100: result = rotr(a, 5'd2) ^ rotr(a, 5'd13) ^ rotr(a, 5'd22);       // sha256sum0
          12'h101: result = rotr(a, 5'd6) ^ rotr(a, 5'd11) ^ rotr(a, 5'd25);       // sha256sum1
          12'h102: result = rotr(a, 5'd7) ^ rotr(a, 5'd18) ^ (a >> 3);             // sha256sig0
          default: result = rotr(a, 5'd17) ^ rotr(a, 5'd19) ^ (a >> 10);          // sha256sig1 (0x103)
        endcase
      end
    end else if (funct3 == 3'b000) begin                                           // SHA-512, RV32
      case (funct7)
        7'h28: result = (a << 25) ^ (a << 30) ^ (a >> 28) ^ (b >> 7) ^ (b >> 2) ^ (b << 4);    // sum0r
        7'h29: result = (a << 23) ^ (a >> 14) ^ (a >> 18) ^ (b >> 9) ^ (b << 18) ^ (b << 14);  // sum1r
        7'h2a: result = (a >> 1) ^ (a >> 7) ^ (a >> 8) ^ (b << 31) ^ (b << 25) ^ (b << 24);    // sig0l
        7'h2e: result = (a >> 1) ^ (a >> 7) ^ (a >> 8) ^ (b << 31) ^ (b << 24);                // sig0h
        7'h2b: result = (a << 3) ^ (a >> 6) ^ (a >> 19) ^ (b >> 29) ^ (b << 26) ^ (b << 13);   // sig1l
        default: result = (a << 3) ^ (a >> 6) ^ (a >> 19) ^ (b >> 29) ^ (b << 13);            // sig1h (0x2f)
      endcase
    end else if (funct7 == 7'b0110000) begin
      result = rot;                                                                // rol, ror
    end else if (funct7 == 7'b0100000) begin
      case (funct3)
        3'b111:  result = a & ~b;                                                  // andn
        3'b110:  result = a | ~b;                                                  // orn
        default: result = ~(a ^ b);                                                // xnor
      endcase
    end else begin
      result = (funct3 == 3'b100) ? {b[15:0], a[15:0]} : {16'd0, b[7:0], a[7:0]};  // pack, packh
    end
  end

endmodule
