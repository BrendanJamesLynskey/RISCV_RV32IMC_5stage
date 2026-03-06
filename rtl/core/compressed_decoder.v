// ============================================================================
// compressed_decoder.v — RV32C Compressed Instruction Expander
// ============================================================================
// Expands 16-bit compressed instructions into their 32-bit equivalents.
// If the instruction is already 32-bit (bits [1:0] == 2'b11), it passes
// through unchanged. Returns 'is_compressed' to adjust PC increment.
// ============================================================================

module compressed_decoder (
  input  wire [31:0] instr_in,     // Raw fetched data (may be 16 or 32 bit)
  output reg  [31:0] instr_out,    // Expanded 32-bit instruction
  output wire        is_compressed, // 1 if input was 16-bit
  output reg         illegal_c     // Illegal compressed encoding
);

  wire [15:0] ci;  // Compressed instruction
  assign ci = instr_in[15:0];
  assign is_compressed = (ci[1:0] != 2'b11);

  // Compressed register mapping: cr' = cr + 8 (registers x8-x15)
  function [4:0] cr;
    input [2:0] r;
    begin
      cr = {2'b01, r};
    end
  endfunction

  // Hoisted intermediate variables
  reg [9:0]  c_nzuimm;
  reg [6:0]  c_off7;
  reg [5:0]  c_imm6;
  reg [20:0] c_jimm;
  reg [9:0]  c_nzimm_sp;
  reg [8:0]  c_boff;
  reg [7:0]  c_off8;

  always @(*) begin
    instr_out = instr_in;  // Default: pass through 32-bit
    illegal_c = 1'b0;
    c_nzuimm   = 10'b0;
    c_off7     = 7'b0;
    c_imm6     = 6'b0;
    c_jimm     = 21'b0;
    c_nzimm_sp = 10'b0;
    c_boff     = 9'b0;
    c_off8     = 8'b0;

    if (is_compressed) begin
      instr_out = 32'h0000_0013;  // NOP default
      illegal_c = 1'b0;

      case (ci[1:0])
        // ── Quadrant 0 ──────────────────────────────────────────────
        2'b00: begin
          case (ci[15:13])
            3'b000: begin // C.ADDI4SPN -> addi rd', x2, nzuimm
              if (ci[12:5] == 8'b0) begin
                illegal_c = 1'b1;
              end else begin
                c_nzuimm = {ci[10:7], ci[12:11], ci[5], ci[6], 2'b00};
                instr_out = {2'b0, c_nzuimm, 5'd2, 3'b000, cr(ci[4:2]), 7'b0010011};
              end
            end
            3'b010: begin // C.LW -> lw rd', offset(rs1')
              c_off7 = {ci[5], ci[12:10], ci[6], 2'b00};
              instr_out = {5'b0, c_off7, cr(ci[9:7]), 3'b010, cr(ci[4:2]), 7'b0000011};
            end
            3'b110: begin // C.SW -> sw rs2', offset(rs1')
              c_off7 = {ci[5], ci[12:10], ci[6], 2'b00};
              instr_out = {5'b0, c_off7[6:5], cr(ci[4:2]), cr(ci[9:7]), 3'b010, c_off7[4:0], 7'b0100011};
            end
            default: illegal_c = 1'b1;
          endcase
        end

        // ── Quadrant 1 ──────────────────────────────────────────────
        2'b01: begin
          case (ci[15:13])
            3'b000: begin // C.ADDI / C.NOP -> addi rd, rd, nzimm
              c_imm6 = {ci[12], ci[6:2]};
              instr_out = {{6{c_imm6[5]}}, c_imm6, ci[11:7], 3'b000, ci[11:7], 7'b0010011};
            end
            3'b001: begin // C.JAL -> jal x1, offset (RV32 only)
              c_jimm = {{10{ci[12]}}, ci[8], ci[10:9], ci[6], ci[7], ci[2], ci[11], ci[5:3], 1'b0};
              instr_out = {c_jimm[20], c_jimm[10:1], c_jimm[11], c_jimm[19:12], 5'd1, 7'b1101111};
            end
            3'b010: begin // C.LI -> addi rd, x0, imm
              c_imm6 = {ci[12], ci[6:2]};
              instr_out = {{6{c_imm6[5]}}, c_imm6, 5'd0, 3'b000, ci[11:7], 7'b0010011};
            end
            3'b011: begin
              if (ci[11:7] == 5'd2) begin // C.ADDI16SP -> addi x2, x2, nzimm
                c_nzimm_sp = {ci[12], ci[4:3], ci[5], ci[2], ci[6], 4'b0000};
                instr_out = {{2{c_nzimm_sp[9]}}, c_nzimm_sp, 5'd2, 3'b000, 5'd2, 7'b0010011};
              end else begin // C.LUI -> lui rd, nzuimm
                instr_out = {{14{ci[12]}}, ci[12], ci[6:2], ci[11:7], 7'b0110111};
              end
            end
            3'b100: begin // ALU operations on compressed registers
              case (ci[11:10])
                2'b00: begin // C.SRLI -> srli rd', rd', shamt
                  instr_out = {7'b0000000, ci[6:2], cr(ci[9:7]), 3'b101, cr(ci[9:7]), 7'b0010011};
                end
                2'b01: begin // C.SRAI -> srai rd', rd', shamt
                  instr_out = {7'b0100000, ci[6:2], cr(ci[9:7]), 3'b101, cr(ci[9:7]), 7'b0010011};
                end
                2'b10: begin // C.ANDI -> andi rd', rd', imm
                  c_imm6 = {ci[12], ci[6:2]};
                  instr_out = {{6{c_imm6[5]}}, c_imm6, cr(ci[9:7]), 3'b111, cr(ci[9:7]), 7'b0010011};
                end
                2'b11: begin
                  case ({ci[12], ci[6:5]})
                    3'b000: instr_out = {7'b0100000, cr(ci[4:2]), cr(ci[9:7]), 3'b000, cr(ci[9:7]), 7'b0110011}; // C.SUB
                    3'b001: instr_out = {7'b0000000, cr(ci[4:2]), cr(ci[9:7]), 3'b100, cr(ci[9:7]), 7'b0110011}; // C.XOR
                    3'b010: instr_out = {7'b0000000, cr(ci[4:2]), cr(ci[9:7]), 3'b110, cr(ci[9:7]), 7'b0110011}; // C.OR
                    3'b011: instr_out = {7'b0000000, cr(ci[4:2]), cr(ci[9:7]), 3'b111, cr(ci[9:7]), 7'b0110011}; // C.AND
                    default: illegal_c = 1'b1;
                  endcase
                end
              endcase
            end
            3'b101: begin // C.J -> jal x0, offset
              c_jimm = {{10{ci[12]}}, ci[8], ci[10:9], ci[6], ci[7], ci[2], ci[11], ci[5:3], 1'b0};
              instr_out = {c_jimm[20], c_jimm[10:1], c_jimm[11], c_jimm[19:12], 5'd0, 7'b1101111};
            end
            3'b110: begin // C.BEQZ -> beq rs1', x0, offset
              c_boff = {ci[12], ci[6:5], ci[2], ci[11:10], ci[4:3], 1'b0};
              instr_out = {c_boff[8], {3{c_boff[8]}}, c_boff[7:5], 5'd0, cr(ci[9:7]), 3'b000, c_boff[4:1], c_boff[8], 7'b1100011};
            end
            3'b111: begin // C.BNEZ -> bne rs1', x0, offset
              c_boff = {ci[12], ci[6:5], ci[2], ci[11:10], ci[4:3], 1'b0};
              instr_out = {c_boff[8], {3{c_boff[8]}}, c_boff[7:5], 5'd0, cr(ci[9:7]), 3'b001, c_boff[4:1], c_boff[8], 7'b1100011};
            end
            default: illegal_c = 1'b1;
          endcase
        end

        // ── Quadrant 2 ──────────────────────────────────────────────
        2'b10: begin
          case (ci[15:13])
            3'b000: begin // C.SLLI -> slli rd, rd, shamt
              instr_out = {7'b0000000, ci[6:2], ci[11:7], 3'b001, ci[11:7], 7'b0010011};
            end
            3'b010: begin // C.LWSP -> lw rd, offset(x2)
              c_off8 = {ci[3:2], ci[12], ci[6:4], 2'b00};
              instr_out = {4'b0, c_off8, 5'd2, 3'b010, ci[11:7], 7'b0000011};
            end
            3'b100: begin
              if (ci[12] == 1'b0) begin
                if (ci[6:2] == 5'b0) begin // C.JR -> jalr x0, rs1, 0
                  instr_out = {12'b0, ci[11:7], 3'b000, 5'd0, 7'b1100111};
                end else begin // C.MV -> add rd, x0, rs2
                  instr_out = {7'b0, ci[6:2], 5'd0, 3'b000, ci[11:7], 7'b0110011};
                end
              end else begin
                if (ci[6:2] == 5'b0) begin
                  if (ci[11:7] == 5'b0) begin // C.EBREAK -> ebreak
                    instr_out = 32'h0010_0073;
                  end else begin // C.JALR -> jalr x1, rs1, 0
                    instr_out = {12'b0, ci[11:7], 3'b000, 5'd1, 7'b1100111};
                  end
                end else begin // C.ADD -> add rd, rd, rs2
                  instr_out = {7'b0, ci[6:2], ci[11:7], 3'b000, ci[11:7], 7'b0110011};
                end
              end
            end
            3'b110: begin // C.SWSP -> sw rs2, offset(x2)
              c_off8 = {ci[8:7], ci[12:9], 2'b00};
              instr_out = {4'b0, c_off8[7:5], ci[6:2], 5'd2, 3'b010, c_off8[4:0], 7'b0100011};
            end
            default: illegal_c = 1'b1;
          endcase
        end

        default: begin
          // bits [1:0] == 2'b11 -> 32-bit, handled by default assignment
        end
      endcase
    end
  end

endmodule
