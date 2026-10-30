// ============================================================================
// zk_unit.v — ratified scalar cryptography for RV32: Zbkb, Zbkc, Zbkx, Zknh, Zkne, Zknd
// ============================================================================
// Zbkb (bit manipulation for cryptography):
//   ror, rol, rori; andn, orn, xnor; pack, packh; brev8, rev8; zip, unzip
// Zknh (SHA-2):
//   sha256sig0, sha256sig1, sha256sum0, sha256sum1 (one source);
//   sha512sig0l/h, sha512sig1l/h, sha512sum0r, sha512sum1r (two sources:
//   SHA-512's 64-bit words as two 32-bit halves, RV32's form)
// Zkne and Zknd (AES, RV32): aes32esi, aes32esmi, aes32dsi, aes32dsmi
// Zbkc (carry-less multiply): clmul (low word), clmulh (high word)
// Zbkx (crossbar permutation): xperm4, xperm8 (rs2 indexes rs1's nibbles or
//   bytes; an index past the end gives 0)
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

  function [7:0] sbox_fwd(input [7:0] v);
    case (v)
      8'h00: sbox_fwd = 8'h63;
      8'h01: sbox_fwd = 8'h7c;
      8'h02: sbox_fwd = 8'h77;
      8'h03: sbox_fwd = 8'h7b;
      8'h04: sbox_fwd = 8'hf2;
      8'h05: sbox_fwd = 8'h6b;
      8'h06: sbox_fwd = 8'h6f;
      8'h07: sbox_fwd = 8'hc5;
      8'h08: sbox_fwd = 8'h30;
      8'h09: sbox_fwd = 8'h01;
      8'h0a: sbox_fwd = 8'h67;
      8'h0b: sbox_fwd = 8'h2b;
      8'h0c: sbox_fwd = 8'hfe;
      8'h0d: sbox_fwd = 8'hd7;
      8'h0e: sbox_fwd = 8'hab;
      8'h0f: sbox_fwd = 8'h76;
      8'h10: sbox_fwd = 8'hca;
      8'h11: sbox_fwd = 8'h82;
      8'h12: sbox_fwd = 8'hc9;
      8'h13: sbox_fwd = 8'h7d;
      8'h14: sbox_fwd = 8'hfa;
      8'h15: sbox_fwd = 8'h59;
      8'h16: sbox_fwd = 8'h47;
      8'h17: sbox_fwd = 8'hf0;
      8'h18: sbox_fwd = 8'had;
      8'h19: sbox_fwd = 8'hd4;
      8'h1a: sbox_fwd = 8'ha2;
      8'h1b: sbox_fwd = 8'haf;
      8'h1c: sbox_fwd = 8'h9c;
      8'h1d: sbox_fwd = 8'ha4;
      8'h1e: sbox_fwd = 8'h72;
      8'h1f: sbox_fwd = 8'hc0;
      8'h20: sbox_fwd = 8'hb7;
      8'h21: sbox_fwd = 8'hfd;
      8'h22: sbox_fwd = 8'h93;
      8'h23: sbox_fwd = 8'h26;
      8'h24: sbox_fwd = 8'h36;
      8'h25: sbox_fwd = 8'h3f;
      8'h26: sbox_fwd = 8'hf7;
      8'h27: sbox_fwd = 8'hcc;
      8'h28: sbox_fwd = 8'h34;
      8'h29: sbox_fwd = 8'ha5;
      8'h2a: sbox_fwd = 8'he5;
      8'h2b: sbox_fwd = 8'hf1;
      8'h2c: sbox_fwd = 8'h71;
      8'h2d: sbox_fwd = 8'hd8;
      8'h2e: sbox_fwd = 8'h31;
      8'h2f: sbox_fwd = 8'h15;
      8'h30: sbox_fwd = 8'h04;
      8'h31: sbox_fwd = 8'hc7;
      8'h32: sbox_fwd = 8'h23;
      8'h33: sbox_fwd = 8'hc3;
      8'h34: sbox_fwd = 8'h18;
      8'h35: sbox_fwd = 8'h96;
      8'h36: sbox_fwd = 8'h05;
      8'h37: sbox_fwd = 8'h9a;
      8'h38: sbox_fwd = 8'h07;
      8'h39: sbox_fwd = 8'h12;
      8'h3a: sbox_fwd = 8'h80;
      8'h3b: sbox_fwd = 8'he2;
      8'h3c: sbox_fwd = 8'heb;
      8'h3d: sbox_fwd = 8'h27;
      8'h3e: sbox_fwd = 8'hb2;
      8'h3f: sbox_fwd = 8'h75;
      8'h40: sbox_fwd = 8'h09;
      8'h41: sbox_fwd = 8'h83;
      8'h42: sbox_fwd = 8'h2c;
      8'h43: sbox_fwd = 8'h1a;
      8'h44: sbox_fwd = 8'h1b;
      8'h45: sbox_fwd = 8'h6e;
      8'h46: sbox_fwd = 8'h5a;
      8'h47: sbox_fwd = 8'ha0;
      8'h48: sbox_fwd = 8'h52;
      8'h49: sbox_fwd = 8'h3b;
      8'h4a: sbox_fwd = 8'hd6;
      8'h4b: sbox_fwd = 8'hb3;
      8'h4c: sbox_fwd = 8'h29;
      8'h4d: sbox_fwd = 8'he3;
      8'h4e: sbox_fwd = 8'h2f;
      8'h4f: sbox_fwd = 8'h84;
      8'h50: sbox_fwd = 8'h53;
      8'h51: sbox_fwd = 8'hd1;
      8'h52: sbox_fwd = 8'h00;
      8'h53: sbox_fwd = 8'hed;
      8'h54: sbox_fwd = 8'h20;
      8'h55: sbox_fwd = 8'hfc;
      8'h56: sbox_fwd = 8'hb1;
      8'h57: sbox_fwd = 8'h5b;
      8'h58: sbox_fwd = 8'h6a;
      8'h59: sbox_fwd = 8'hcb;
      8'h5a: sbox_fwd = 8'hbe;
      8'h5b: sbox_fwd = 8'h39;
      8'h5c: sbox_fwd = 8'h4a;
      8'h5d: sbox_fwd = 8'h4c;
      8'h5e: sbox_fwd = 8'h58;
      8'h5f: sbox_fwd = 8'hcf;
      8'h60: sbox_fwd = 8'hd0;
      8'h61: sbox_fwd = 8'hef;
      8'h62: sbox_fwd = 8'haa;
      8'h63: sbox_fwd = 8'hfb;
      8'h64: sbox_fwd = 8'h43;
      8'h65: sbox_fwd = 8'h4d;
      8'h66: sbox_fwd = 8'h33;
      8'h67: sbox_fwd = 8'h85;
      8'h68: sbox_fwd = 8'h45;
      8'h69: sbox_fwd = 8'hf9;
      8'h6a: sbox_fwd = 8'h02;
      8'h6b: sbox_fwd = 8'h7f;
      8'h6c: sbox_fwd = 8'h50;
      8'h6d: sbox_fwd = 8'h3c;
      8'h6e: sbox_fwd = 8'h9f;
      8'h6f: sbox_fwd = 8'ha8;
      8'h70: sbox_fwd = 8'h51;
      8'h71: sbox_fwd = 8'ha3;
      8'h72: sbox_fwd = 8'h40;
      8'h73: sbox_fwd = 8'h8f;
      8'h74: sbox_fwd = 8'h92;
      8'h75: sbox_fwd = 8'h9d;
      8'h76: sbox_fwd = 8'h38;
      8'h77: sbox_fwd = 8'hf5;
      8'h78: sbox_fwd = 8'hbc;
      8'h79: sbox_fwd = 8'hb6;
      8'h7a: sbox_fwd = 8'hda;
      8'h7b: sbox_fwd = 8'h21;
      8'h7c: sbox_fwd = 8'h10;
      8'h7d: sbox_fwd = 8'hff;
      8'h7e: sbox_fwd = 8'hf3;
      8'h7f: sbox_fwd = 8'hd2;
      8'h80: sbox_fwd = 8'hcd;
      8'h81: sbox_fwd = 8'h0c;
      8'h82: sbox_fwd = 8'h13;
      8'h83: sbox_fwd = 8'hec;
      8'h84: sbox_fwd = 8'h5f;
      8'h85: sbox_fwd = 8'h97;
      8'h86: sbox_fwd = 8'h44;
      8'h87: sbox_fwd = 8'h17;
      8'h88: sbox_fwd = 8'hc4;
      8'h89: sbox_fwd = 8'ha7;
      8'h8a: sbox_fwd = 8'h7e;
      8'h8b: sbox_fwd = 8'h3d;
      8'h8c: sbox_fwd = 8'h64;
      8'h8d: sbox_fwd = 8'h5d;
      8'h8e: sbox_fwd = 8'h19;
      8'h8f: sbox_fwd = 8'h73;
      8'h90: sbox_fwd = 8'h60;
      8'h91: sbox_fwd = 8'h81;
      8'h92: sbox_fwd = 8'h4f;
      8'h93: sbox_fwd = 8'hdc;
      8'h94: sbox_fwd = 8'h22;
      8'h95: sbox_fwd = 8'h2a;
      8'h96: sbox_fwd = 8'h90;
      8'h97: sbox_fwd = 8'h88;
      8'h98: sbox_fwd = 8'h46;
      8'h99: sbox_fwd = 8'hee;
      8'h9a: sbox_fwd = 8'hb8;
      8'h9b: sbox_fwd = 8'h14;
      8'h9c: sbox_fwd = 8'hde;
      8'h9d: sbox_fwd = 8'h5e;
      8'h9e: sbox_fwd = 8'h0b;
      8'h9f: sbox_fwd = 8'hdb;
      8'ha0: sbox_fwd = 8'he0;
      8'ha1: sbox_fwd = 8'h32;
      8'ha2: sbox_fwd = 8'h3a;
      8'ha3: sbox_fwd = 8'h0a;
      8'ha4: sbox_fwd = 8'h49;
      8'ha5: sbox_fwd = 8'h06;
      8'ha6: sbox_fwd = 8'h24;
      8'ha7: sbox_fwd = 8'h5c;
      8'ha8: sbox_fwd = 8'hc2;
      8'ha9: sbox_fwd = 8'hd3;
      8'haa: sbox_fwd = 8'hac;
      8'hab: sbox_fwd = 8'h62;
      8'hac: sbox_fwd = 8'h91;
      8'had: sbox_fwd = 8'h95;
      8'hae: sbox_fwd = 8'he4;
      8'haf: sbox_fwd = 8'h79;
      8'hb0: sbox_fwd = 8'he7;
      8'hb1: sbox_fwd = 8'hc8;
      8'hb2: sbox_fwd = 8'h37;
      8'hb3: sbox_fwd = 8'h6d;
      8'hb4: sbox_fwd = 8'h8d;
      8'hb5: sbox_fwd = 8'hd5;
      8'hb6: sbox_fwd = 8'h4e;
      8'hb7: sbox_fwd = 8'ha9;
      8'hb8: sbox_fwd = 8'h6c;
      8'hb9: sbox_fwd = 8'h56;
      8'hba: sbox_fwd = 8'hf4;
      8'hbb: sbox_fwd = 8'hea;
      8'hbc: sbox_fwd = 8'h65;
      8'hbd: sbox_fwd = 8'h7a;
      8'hbe: sbox_fwd = 8'hae;
      8'hbf: sbox_fwd = 8'h08;
      8'hc0: sbox_fwd = 8'hba;
      8'hc1: sbox_fwd = 8'h78;
      8'hc2: sbox_fwd = 8'h25;
      8'hc3: sbox_fwd = 8'h2e;
      8'hc4: sbox_fwd = 8'h1c;
      8'hc5: sbox_fwd = 8'ha6;
      8'hc6: sbox_fwd = 8'hb4;
      8'hc7: sbox_fwd = 8'hc6;
      8'hc8: sbox_fwd = 8'he8;
      8'hc9: sbox_fwd = 8'hdd;
      8'hca: sbox_fwd = 8'h74;
      8'hcb: sbox_fwd = 8'h1f;
      8'hcc: sbox_fwd = 8'h4b;
      8'hcd: sbox_fwd = 8'hbd;
      8'hce: sbox_fwd = 8'h8b;
      8'hcf: sbox_fwd = 8'h8a;
      8'hd0: sbox_fwd = 8'h70;
      8'hd1: sbox_fwd = 8'h3e;
      8'hd2: sbox_fwd = 8'hb5;
      8'hd3: sbox_fwd = 8'h66;
      8'hd4: sbox_fwd = 8'h48;
      8'hd5: sbox_fwd = 8'h03;
      8'hd6: sbox_fwd = 8'hf6;
      8'hd7: sbox_fwd = 8'h0e;
      8'hd8: sbox_fwd = 8'h61;
      8'hd9: sbox_fwd = 8'h35;
      8'hda: sbox_fwd = 8'h57;
      8'hdb: sbox_fwd = 8'hb9;
      8'hdc: sbox_fwd = 8'h86;
      8'hdd: sbox_fwd = 8'hc1;
      8'hde: sbox_fwd = 8'h1d;
      8'hdf: sbox_fwd = 8'h9e;
      8'he0: sbox_fwd = 8'he1;
      8'he1: sbox_fwd = 8'hf8;
      8'he2: sbox_fwd = 8'h98;
      8'he3: sbox_fwd = 8'h11;
      8'he4: sbox_fwd = 8'h69;
      8'he5: sbox_fwd = 8'hd9;
      8'he6: sbox_fwd = 8'h8e;
      8'he7: sbox_fwd = 8'h94;
      8'he8: sbox_fwd = 8'h9b;
      8'he9: sbox_fwd = 8'h1e;
      8'hea: sbox_fwd = 8'h87;
      8'heb: sbox_fwd = 8'he9;
      8'hec: sbox_fwd = 8'hce;
      8'hed: sbox_fwd = 8'h55;
      8'hee: sbox_fwd = 8'h28;
      8'hef: sbox_fwd = 8'hdf;
      8'hf0: sbox_fwd = 8'h8c;
      8'hf1: sbox_fwd = 8'ha1;
      8'hf2: sbox_fwd = 8'h89;
      8'hf3: sbox_fwd = 8'h0d;
      8'hf4: sbox_fwd = 8'hbf;
      8'hf5: sbox_fwd = 8'he6;
      8'hf6: sbox_fwd = 8'h42;
      8'hf7: sbox_fwd = 8'h68;
      8'hf8: sbox_fwd = 8'h41;
      8'hf9: sbox_fwd = 8'h99;
      8'hfa: sbox_fwd = 8'h2d;
      8'hfb: sbox_fwd = 8'h0f;
      8'hfc: sbox_fwd = 8'hb0;
      8'hfd: sbox_fwd = 8'h54;
      8'hfe: sbox_fwd = 8'hbb;
      8'hff: sbox_fwd = 8'h16;
    endcase
  endfunction

  function [7:0] sbox_inv(input [7:0] v);
    case (v)
      8'h00: sbox_inv = 8'h52;
      8'h01: sbox_inv = 8'h09;
      8'h02: sbox_inv = 8'h6a;
      8'h03: sbox_inv = 8'hd5;
      8'h04: sbox_inv = 8'h30;
      8'h05: sbox_inv = 8'h36;
      8'h06: sbox_inv = 8'ha5;
      8'h07: sbox_inv = 8'h38;
      8'h08: sbox_inv = 8'hbf;
      8'h09: sbox_inv = 8'h40;
      8'h0a: sbox_inv = 8'ha3;
      8'h0b: sbox_inv = 8'h9e;
      8'h0c: sbox_inv = 8'h81;
      8'h0d: sbox_inv = 8'hf3;
      8'h0e: sbox_inv = 8'hd7;
      8'h0f: sbox_inv = 8'hfb;
      8'h10: sbox_inv = 8'h7c;
      8'h11: sbox_inv = 8'he3;
      8'h12: sbox_inv = 8'h39;
      8'h13: sbox_inv = 8'h82;
      8'h14: sbox_inv = 8'h9b;
      8'h15: sbox_inv = 8'h2f;
      8'h16: sbox_inv = 8'hff;
      8'h17: sbox_inv = 8'h87;
      8'h18: sbox_inv = 8'h34;
      8'h19: sbox_inv = 8'h8e;
      8'h1a: sbox_inv = 8'h43;
      8'h1b: sbox_inv = 8'h44;
      8'h1c: sbox_inv = 8'hc4;
      8'h1d: sbox_inv = 8'hde;
      8'h1e: sbox_inv = 8'he9;
      8'h1f: sbox_inv = 8'hcb;
      8'h20: sbox_inv = 8'h54;
      8'h21: sbox_inv = 8'h7b;
      8'h22: sbox_inv = 8'h94;
      8'h23: sbox_inv = 8'h32;
      8'h24: sbox_inv = 8'ha6;
      8'h25: sbox_inv = 8'hc2;
      8'h26: sbox_inv = 8'h23;
      8'h27: sbox_inv = 8'h3d;
      8'h28: sbox_inv = 8'hee;
      8'h29: sbox_inv = 8'h4c;
      8'h2a: sbox_inv = 8'h95;
      8'h2b: sbox_inv = 8'h0b;
      8'h2c: sbox_inv = 8'h42;
      8'h2d: sbox_inv = 8'hfa;
      8'h2e: sbox_inv = 8'hc3;
      8'h2f: sbox_inv = 8'h4e;
      8'h30: sbox_inv = 8'h08;
      8'h31: sbox_inv = 8'h2e;
      8'h32: sbox_inv = 8'ha1;
      8'h33: sbox_inv = 8'h66;
      8'h34: sbox_inv = 8'h28;
      8'h35: sbox_inv = 8'hd9;
      8'h36: sbox_inv = 8'h24;
      8'h37: sbox_inv = 8'hb2;
      8'h38: sbox_inv = 8'h76;
      8'h39: sbox_inv = 8'h5b;
      8'h3a: sbox_inv = 8'ha2;
      8'h3b: sbox_inv = 8'h49;
      8'h3c: sbox_inv = 8'h6d;
      8'h3d: sbox_inv = 8'h8b;
      8'h3e: sbox_inv = 8'hd1;
      8'h3f: sbox_inv = 8'h25;
      8'h40: sbox_inv = 8'h72;
      8'h41: sbox_inv = 8'hf8;
      8'h42: sbox_inv = 8'hf6;
      8'h43: sbox_inv = 8'h64;
      8'h44: sbox_inv = 8'h86;
      8'h45: sbox_inv = 8'h68;
      8'h46: sbox_inv = 8'h98;
      8'h47: sbox_inv = 8'h16;
      8'h48: sbox_inv = 8'hd4;
      8'h49: sbox_inv = 8'ha4;
      8'h4a: sbox_inv = 8'h5c;
      8'h4b: sbox_inv = 8'hcc;
      8'h4c: sbox_inv = 8'h5d;
      8'h4d: sbox_inv = 8'h65;
      8'h4e: sbox_inv = 8'hb6;
      8'h4f: sbox_inv = 8'h92;
      8'h50: sbox_inv = 8'h6c;
      8'h51: sbox_inv = 8'h70;
      8'h52: sbox_inv = 8'h48;
      8'h53: sbox_inv = 8'h50;
      8'h54: sbox_inv = 8'hfd;
      8'h55: sbox_inv = 8'hed;
      8'h56: sbox_inv = 8'hb9;
      8'h57: sbox_inv = 8'hda;
      8'h58: sbox_inv = 8'h5e;
      8'h59: sbox_inv = 8'h15;
      8'h5a: sbox_inv = 8'h46;
      8'h5b: sbox_inv = 8'h57;
      8'h5c: sbox_inv = 8'ha7;
      8'h5d: sbox_inv = 8'h8d;
      8'h5e: sbox_inv = 8'h9d;
      8'h5f: sbox_inv = 8'h84;
      8'h60: sbox_inv = 8'h90;
      8'h61: sbox_inv = 8'hd8;
      8'h62: sbox_inv = 8'hab;
      8'h63: sbox_inv = 8'h00;
      8'h64: sbox_inv = 8'h8c;
      8'h65: sbox_inv = 8'hbc;
      8'h66: sbox_inv = 8'hd3;
      8'h67: sbox_inv = 8'h0a;
      8'h68: sbox_inv = 8'hf7;
      8'h69: sbox_inv = 8'he4;
      8'h6a: sbox_inv = 8'h58;
      8'h6b: sbox_inv = 8'h05;
      8'h6c: sbox_inv = 8'hb8;
      8'h6d: sbox_inv = 8'hb3;
      8'h6e: sbox_inv = 8'h45;
      8'h6f: sbox_inv = 8'h06;
      8'h70: sbox_inv = 8'hd0;
      8'h71: sbox_inv = 8'h2c;
      8'h72: sbox_inv = 8'h1e;
      8'h73: sbox_inv = 8'h8f;
      8'h74: sbox_inv = 8'hca;
      8'h75: sbox_inv = 8'h3f;
      8'h76: sbox_inv = 8'h0f;
      8'h77: sbox_inv = 8'h02;
      8'h78: sbox_inv = 8'hc1;
      8'h79: sbox_inv = 8'haf;
      8'h7a: sbox_inv = 8'hbd;
      8'h7b: sbox_inv = 8'h03;
      8'h7c: sbox_inv = 8'h01;
      8'h7d: sbox_inv = 8'h13;
      8'h7e: sbox_inv = 8'h8a;
      8'h7f: sbox_inv = 8'h6b;
      8'h80: sbox_inv = 8'h3a;
      8'h81: sbox_inv = 8'h91;
      8'h82: sbox_inv = 8'h11;
      8'h83: sbox_inv = 8'h41;
      8'h84: sbox_inv = 8'h4f;
      8'h85: sbox_inv = 8'h67;
      8'h86: sbox_inv = 8'hdc;
      8'h87: sbox_inv = 8'hea;
      8'h88: sbox_inv = 8'h97;
      8'h89: sbox_inv = 8'hf2;
      8'h8a: sbox_inv = 8'hcf;
      8'h8b: sbox_inv = 8'hce;
      8'h8c: sbox_inv = 8'hf0;
      8'h8d: sbox_inv = 8'hb4;
      8'h8e: sbox_inv = 8'he6;
      8'h8f: sbox_inv = 8'h73;
      8'h90: sbox_inv = 8'h96;
      8'h91: sbox_inv = 8'hac;
      8'h92: sbox_inv = 8'h74;
      8'h93: sbox_inv = 8'h22;
      8'h94: sbox_inv = 8'he7;
      8'h95: sbox_inv = 8'had;
      8'h96: sbox_inv = 8'h35;
      8'h97: sbox_inv = 8'h85;
      8'h98: sbox_inv = 8'he2;
      8'h99: sbox_inv = 8'hf9;
      8'h9a: sbox_inv = 8'h37;
      8'h9b: sbox_inv = 8'he8;
      8'h9c: sbox_inv = 8'h1c;
      8'h9d: sbox_inv = 8'h75;
      8'h9e: sbox_inv = 8'hdf;
      8'h9f: sbox_inv = 8'h6e;
      8'ha0: sbox_inv = 8'h47;
      8'ha1: sbox_inv = 8'hf1;
      8'ha2: sbox_inv = 8'h1a;
      8'ha3: sbox_inv = 8'h71;
      8'ha4: sbox_inv = 8'h1d;
      8'ha5: sbox_inv = 8'h29;
      8'ha6: sbox_inv = 8'hc5;
      8'ha7: sbox_inv = 8'h89;
      8'ha8: sbox_inv = 8'h6f;
      8'ha9: sbox_inv = 8'hb7;
      8'haa: sbox_inv = 8'h62;
      8'hab: sbox_inv = 8'h0e;
      8'hac: sbox_inv = 8'haa;
      8'had: sbox_inv = 8'h18;
      8'hae: sbox_inv = 8'hbe;
      8'haf: sbox_inv = 8'h1b;
      8'hb0: sbox_inv = 8'hfc;
      8'hb1: sbox_inv = 8'h56;
      8'hb2: sbox_inv = 8'h3e;
      8'hb3: sbox_inv = 8'h4b;
      8'hb4: sbox_inv = 8'hc6;
      8'hb5: sbox_inv = 8'hd2;
      8'hb6: sbox_inv = 8'h79;
      8'hb7: sbox_inv = 8'h20;
      8'hb8: sbox_inv = 8'h9a;
      8'hb9: sbox_inv = 8'hdb;
      8'hba: sbox_inv = 8'hc0;
      8'hbb: sbox_inv = 8'hfe;
      8'hbc: sbox_inv = 8'h78;
      8'hbd: sbox_inv = 8'hcd;
      8'hbe: sbox_inv = 8'h5a;
      8'hbf: sbox_inv = 8'hf4;
      8'hc0: sbox_inv = 8'h1f;
      8'hc1: sbox_inv = 8'hdd;
      8'hc2: sbox_inv = 8'ha8;
      8'hc3: sbox_inv = 8'h33;
      8'hc4: sbox_inv = 8'h88;
      8'hc5: sbox_inv = 8'h07;
      8'hc6: sbox_inv = 8'hc7;
      8'hc7: sbox_inv = 8'h31;
      8'hc8: sbox_inv = 8'hb1;
      8'hc9: sbox_inv = 8'h12;
      8'hca: sbox_inv = 8'h10;
      8'hcb: sbox_inv = 8'h59;
      8'hcc: sbox_inv = 8'h27;
      8'hcd: sbox_inv = 8'h80;
      8'hce: sbox_inv = 8'hec;
      8'hcf: sbox_inv = 8'h5f;
      8'hd0: sbox_inv = 8'h60;
      8'hd1: sbox_inv = 8'h51;
      8'hd2: sbox_inv = 8'h7f;
      8'hd3: sbox_inv = 8'ha9;
      8'hd4: sbox_inv = 8'h19;
      8'hd5: sbox_inv = 8'hb5;
      8'hd6: sbox_inv = 8'h4a;
      8'hd7: sbox_inv = 8'h0d;
      8'hd8: sbox_inv = 8'h2d;
      8'hd9: sbox_inv = 8'he5;
      8'hda: sbox_inv = 8'h7a;
      8'hdb: sbox_inv = 8'h9f;
      8'hdc: sbox_inv = 8'h93;
      8'hdd: sbox_inv = 8'hc9;
      8'hde: sbox_inv = 8'h9c;
      8'hdf: sbox_inv = 8'hef;
      8'he0: sbox_inv = 8'ha0;
      8'he1: sbox_inv = 8'he0;
      8'he2: sbox_inv = 8'h3b;
      8'he3: sbox_inv = 8'h4d;
      8'he4: sbox_inv = 8'hae;
      8'he5: sbox_inv = 8'h2a;
      8'he6: sbox_inv = 8'hf5;
      8'he7: sbox_inv = 8'hb0;
      8'he8: sbox_inv = 8'hc8;
      8'he9: sbox_inv = 8'heb;
      8'hea: sbox_inv = 8'hbb;
      8'heb: sbox_inv = 8'h3c;
      8'hec: sbox_inv = 8'h83;
      8'hed: sbox_inv = 8'h53;
      8'hee: sbox_inv = 8'h99;
      8'hef: sbox_inv = 8'h61;
      8'hf0: sbox_inv = 8'h17;
      8'hf1: sbox_inv = 8'h2b;
      8'hf2: sbox_inv = 8'h04;
      8'hf3: sbox_inv = 8'h7e;
      8'hf4: sbox_inv = 8'hba;
      8'hf5: sbox_inv = 8'h77;
      8'hf6: sbox_inv = 8'hd6;
      8'hf7: sbox_inv = 8'h26;
      8'hf8: sbox_inv = 8'he1;
      8'hf9: sbox_inv = 8'h69;
      8'hfa: sbox_inv = 8'h14;
      8'hfb: sbox_inv = 8'h63;
      8'hfc: sbox_inv = 8'h55;
      8'hfd: sbox_inv = 8'h21;
      8'hfe: sbox_inv = 8'h0c;
      8'hff: sbox_inv = 8'h7d;
    endcase
  endfunction

  function [7:0] xt(input [7:0] v);              // multiply by x (2) in GF(2^8), AES's polynomial
    xt = {v[6:0], 1'b0} ^ (v[7] ? 8'h1b : 8'h00);
  endfunction

  // AES (Zkne, Zknd): one S-box per instruction, on byte bs of rs2. The
  // middle-round forms add that byte's column of MixColumns (2, 1, 1, 3) or
  // InvMixColumns (14, 9, 13, 11). The result is rotated into place by bs
  // and XORed into rs1.
  wire [1:0]  bs      = insn[31:30];
  wire [4:0]  aes_op  = insn[29:25];             // 10001 esi, 10011 esmi, 10101 dsi, 10111 dsmi
  wire [31:0] aes_sh  = b >> {bs, 3'b000};
  wire [7:0]  aes_in  = aes_sh[7:0];
  wire [7:0]  s_e     = sbox_fwd(aes_in);
  wire [7:0]  s_d     = sbox_inv(aes_in);
  wire [7:0]  s2 = xt(s_e), s3 = xt(s_e) ^ s_e;
  wire [7:0]  d2 = xt(s_d), d4 = xt(d2), d8 = xt(d4);
  wire [7:0]  d9 = d8 ^ s_d, d11 = d8 ^ d2 ^ s_d, d13 = d8 ^ d4 ^ s_d, d14 = d8 ^ d4 ^ d2;
  wire [31:0] aes_col = (aes_op == 5'b10001) ? {24'd0, s_e} :
                        (aes_op == 5'b10011) ? {s3, s_e, s_e, s2} :
                        (aes_op == 5'b10101) ? {24'd0, s_d} :
                                               {d11, d13, d9, d14};
  wire [31:0] aes_rot = (aes_col << {bs, 3'b000}) | (aes_col >> (6'd32 - {1'b0, bs, 3'b000}));
  wire        is_aes  = !is_imm && funct3 == 3'b000 && aes_op[4] && aes_op[0];

  // Carry-less multiply: the 63-bit product of a and b over GF(2)
  reg [63:0] clp;
  integer ci;
  always @(*) begin
    clp = 64'd0;
    for (ci = 0; ci < 32; ci = ci + 1)
      if (b[ci]) clp = clp ^ ({32'd0, a} << ci);
  end

  // Crossbar permutations: each nibble (xperm4) or byte (xperm8) of b picks
  // one of a's
  reg [31:0] xp4, xp8;
  integer xi;
  always @(*) begin
    for (xi = 0; xi < 8; xi = xi + 1)
      xp4[4*xi +: 4] = b[4*xi + 3] ? 4'd0 : a[4*b[4*xi +: 3] +: 4];
    for (xi = 0; xi < 4; xi = xi + 1)
      xp8[8*xi +: 8] = (b[8*xi + 2 +: 6] != 6'd0) ? 8'd0 : a[8*b[8*xi +: 2] +: 8];
  end

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
    end else if (is_aes) begin
      result = a ^ aes_rot;                                                        // aes32*
    end else if (funct3 == 3'b000) begin                                           // SHA-512, RV32
      case (funct7)
        7'h28: result = (a << 25) ^ (a << 30) ^ (a >> 28) ^ (b >> 7) ^ (b >> 2) ^ (b << 4);    // sum0r
        7'h29: result = (a << 23) ^ (a >> 14) ^ (a >> 18) ^ (b >> 9) ^ (b << 18) ^ (b << 14);  // sum1r
        7'h2a: result = (a >> 1) ^ (a >> 7) ^ (a >> 8) ^ (b << 31) ^ (b << 25) ^ (b << 24);    // sig0l
        7'h2e: result = (a >> 1) ^ (a >> 7) ^ (a >> 8) ^ (b << 31) ^ (b << 24);                // sig0h
        7'h2b: result = (a << 3) ^ (a >> 6) ^ (a >> 19) ^ (b >> 29) ^ (b << 26) ^ (b << 13);   // sig1l
        default: result = (a << 3) ^ (a >> 6) ^ (a >> 19) ^ (b >> 29) ^ (b << 13);            // sig1h (0x2f)
      endcase
    end else if (funct7 == 7'b0000101) begin
      result = (funct3 == 3'b001) ? clp[31:0] : clp[63:32];                       // clmul, clmulh
    end else if (funct7 == 7'b0010100) begin
      result = (funct3 == 3'b010) ? xp4 : xp8;                                     // xperm4, xperm8
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
