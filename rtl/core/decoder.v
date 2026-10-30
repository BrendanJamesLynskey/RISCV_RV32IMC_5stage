// ============================================================================
// decoder.v — RV32IMC Instruction Decoder for BRV32P
// ============================================================================
// Decodes a 32-bit instruction (already expanded from C) into the control
// bundle plus register addresses and immediate value.
// ============================================================================

module decoder (
  input  wire [31:0]          instr,
  output wire [4:0]           rs1_addr,
  output wire [4:0]           rs2_addr,
  output wire [4:0]           rd_addr,
  output reg  [31:0]          imm,
  output reg  [43:0]          ctrl   // CTRL_W = 44
);

  `include "brv32p_defs.vh"

  wire [6:0] opcode;
  wire [2:0] funct3;
  wire [6:0] funct7;

  assign opcode   = instr[6:0];
  assign funct3   = instr[14:12];
  assign funct7   = instr[31:25];
  assign rs1_addr = instr[19:15];
  assign rs2_addr = instr[24:20];
  assign rd_addr  = instr[11:7];

  // ── Immediate generation ─────────────────────────────────────────────
  always @(*) begin
    case (opcode)
      OP_LOAD, OP_JALR, OP_IMM:
        imm = {{20{instr[31]}}, instr[31:20]};
      OP_STORE:
        imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
      OP_BRANCH:
        imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
      OP_LUI, OP_AUIPC:
        imm = {instr[31:12], 12'b0};
      OP_JAL:
        imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
      OP_SYSTEM:   // CSR write data: zimm (the rs1 field) for CSRR*I, else 0 (rs1 + 0)
        imm = instr[14] ? {27'b0, instr[19:15]} : 32'b0;
      default:
        imm = 32'b0;
    endcase
  end

  // ── Control signal generation ────────────────────────────────────────
  always @(*) begin
    // Defaults — everything off
    ctrl = {`CTRL_W{1'b0}};

    case (opcode)
      OP_LUI: begin
        ctrl[`CTRL_REG_WR]  = 1'b1;
        ctrl[`CTRL_ALU_OP]  = ALU_PASS_B;
        ctrl[`CTRL_ALU_SRC] = 1'b1;
        ctrl[`CTRL_WB_SEL]  = WB_ALU;
      end

      OP_AUIPC: begin
        ctrl[`CTRL_REG_WR]  = 1'b1;
        ctrl[`CTRL_WB_SEL]  = WB_AUIPC;  // pc + imm, computed in EX
      end

      OP_JAL: begin
        ctrl[`CTRL_JAL]     = 1'b1;
        ctrl[`CTRL_REG_WR]  = 1'b1;
        ctrl[`CTRL_WB_SEL]  = WB_PC4;
      end

      OP_JALR: begin
        ctrl[`CTRL_JALR]    = 1'b1;
        ctrl[`CTRL_REG_WR]  = 1'b1;
        ctrl[`CTRL_ALU_SRC] = 1'b1;
        ctrl[`CTRL_ALU_OP]  = ALU_ADD;
        ctrl[`CTRL_WB_SEL]  = WB_PC4;
      end

      OP_BRANCH: begin
        case (funct3)
          3'b000: ctrl[`CTRL_BR_TYPE] = BR_EQ;
          3'b001: ctrl[`CTRL_BR_TYPE] = BR_NE;
          3'b100: ctrl[`CTRL_BR_TYPE] = BR_LT;
          3'b101: ctrl[`CTRL_BR_TYPE] = BR_GE;
          3'b110: ctrl[`CTRL_BR_TYPE] = BR_LTU;
          3'b111: ctrl[`CTRL_BR_TYPE] = BR_GEU;
          default: ctrl[`CTRL_ILLEGAL] = 1'b1;
        endcase
      end

      OP_LOAD: begin
        ctrl[`CTRL_MEM_RD]    = 1'b1;
        ctrl[`CTRL_REG_WR]    = 1'b1;
        ctrl[`CTRL_ALU_SRC]   = 1'b1;
        ctrl[`CTRL_ALU_OP]    = ALU_ADD;
        ctrl[`CTRL_WB_SEL]    = WB_MEM;
        ctrl[`CTRL_MEM_WIDTH] = funct3[1:0];
        ctrl[`CTRL_MEM_SIGN]  = ~funct3[2];
      end

      OP_STORE: begin
        ctrl[`CTRL_MEM_WR]    = 1'b1;
        ctrl[`CTRL_ALU_SRC]   = 1'b1;
        ctrl[`CTRL_ALU_OP]    = ALU_ADD;
        ctrl[`CTRL_MEM_WIDTH] = funct3[1:0];
      end

      OP_IMM: begin
        ctrl[`CTRL_REG_WR]  = 1'b1;
        ctrl[`CTRL_ALU_SRC] = 1'b1;
        ctrl[`CTRL_WB_SEL]  = WB_ALU;
        case (funct3)
          3'b000: ctrl[`CTRL_ALU_OP] = ALU_ADD;
          3'b001: ctrl[`CTRL_ALU_OP] = ALU_SLL;
          3'b010: ctrl[`CTRL_ALU_OP] = ALU_SLT;
          3'b011: ctrl[`CTRL_ALU_OP] = ALU_SLTU;
          3'b100: ctrl[`CTRL_ALU_OP] = ALU_XOR;
          3'b101: ctrl[`CTRL_ALU_OP] = funct7[5] ? ALU_SRA : ALU_SRL;
          3'b110: ctrl[`CTRL_ALU_OP] = ALU_OR;
          3'b111: ctrl[`CTRL_ALU_OP] = ALU_AND;
        endcase
      end

      OP_REG: begin
        ctrl[`CTRL_REG_WR] = 1'b1;
        ctrl[`CTRL_WB_SEL] = WB_ALU;
        if (funct7 == 7'b0000001) begin
          // M extension
          ctrl[`CTRL_MULDIV_EN] = 1'b1;
          ctrl[`CTRL_MULDIV_OP] = funct3;
          ctrl[`CTRL_WB_SEL]    = WB_MULDIV;
        end else begin
          case (funct3)
            3'b000: ctrl[`CTRL_ALU_OP] = funct7[5] ? ALU_SUB : ALU_ADD;
            3'b001: ctrl[`CTRL_ALU_OP] = ALU_SLL;
            3'b010: ctrl[`CTRL_ALU_OP] = ALU_SLT;
            3'b011: ctrl[`CTRL_ALU_OP] = ALU_SLTU;
            3'b100: ctrl[`CTRL_ALU_OP] = ALU_XOR;
            3'b101: ctrl[`CTRL_ALU_OP] = funct7[5] ? ALU_SRA : ALU_SRL;
            3'b110: ctrl[`CTRL_ALU_OP] = ALU_OR;
            3'b111: ctrl[`CTRL_ALU_OP] = ALU_AND;
          endcase
        end
      end

      OP_SYSTEM: begin
        if (funct3 == 3'b000) begin
          case (instr[31:20])
            12'h000: ctrl[`CTRL_ECALL]   = 1'b1;
            12'h001: ctrl[`CTRL_EBREAK]  = 1'b1;
            12'h302: ctrl[`CTRL_MRET]    = 1'b1;
            default: ctrl[`CTRL_ILLEGAL] = 1'b1;
          endcase
        end else begin
          ctrl[`CTRL_CSR_EN]   = 1'b1;
          ctrl[`CTRL_CSR_OP]   = funct3;
          ctrl[`CTRL_ALU_SRC]  = 1'b1;   // CSR write data = rs1 + 0, or zimm for CSRR*I
          ctrl[`CTRL_ALU_OP]   = funct3[2] ? ALU_PASS_B : ALU_ADD;
          ctrl[`CTRL_CSR_ADDR] = instr[31:20];
          ctrl[`CTRL_REG_WR]   = 1'b1;
          ctrl[`CTRL_WB_SEL]   = WB_CSR;
        end
      end

      OP_FENCE: begin
        ctrl[`CTRL_FENCE] = 1'b1;
      end

      // Xbrvdsp accumulator instructions (dsp_unit.v). Updates of acc
      // write no register; acc.rd and acc.rdh write rd from acc.
      OP_CUSTOM0: begin
        if (funct3 == 3'b000 && rd_addr == 5'd0 &&
            (funct7[5:0] == 6'b000000 || funct7[5:0] == 6'b000001 || funct7[5:0] == 6'b000010 ||
             ((funct7 == 7'b0000100 || funct7 == 7'b0000101) && rs2_addr == 5'd0)))
          ;                                           // mac, dmac, msu (+ .lp: funct7 bit 6), acc.set, acc.seth
        else if (((funct3 == 3'b001 || funct3 == 3'b010) && funct7 == 7'b0000000 && rs1_addr == 5'd0) ||
                 (funct3 == 3'b011 && (funct7 == 7'b0000000 || funct7 == 7'b0000001) &&
                  rs1_addr == 5'd0 && rs2_addr == 5'd0)) begin
          ctrl[`CTRL_REG_WR] = 1'b1;                  // acc.rd, acc.rdh, acc.rdl, acc.rdx
          ctrl[`CTRL_WB_SEL] = WB_DSP;
        end else
          ctrl[`CTRL_ILLEGAL] = 1'b1;
      end

      OP_CUSTOM1: begin
        if (funct3 == 3'b000 && (funct7 == 7'b0000000 || funct7 == 7'b0000001) &&
            rs2_addr == 5'd0 && rd_addr[4:2] == 3'b000)
          ;                                           // ar.set, ar.cfg
        else if (funct3 == 3'b000 && funct7 == 7'b0000010 && rs2_addr == 5'd0 && rd_addr[4:1] == 4'b0000)
          ;                                           // lp.set, lp.sets
        else if (funct3 == 3'b110 && rd_addr == 5'd0 && instr[31:20] == 12'd0)
          ;                                           // lp.setup
        else if (funct3 == 3'b111 && instr[31:15] == 17'd0 && rd_addr == 5'd0)
          ;                                           // lp.end
        else if ((funct3 == 3'b001 || funct3 == 3'b010 || funct3 == 3'b101) &&
                 rs1_addr == 5'd0 && instr[31:22] == 10'd0) begin
          ctrl[`CTRL_MEM_RD]    = 1'b1;               // lh.a, lw.a, lhu.a
          ctrl[`CTRL_REG_WR]    = 1'b1;
          ctrl[`CTRL_WB_SEL]    = WB_MEM;
          ctrl[`CTRL_MEM_WIDTH] = funct3[1:0];
          ctrl[`CTRL_MEM_SIGN]  = ~funct3[2];
        end else if (funct3 == 3'b011 && rs1_addr == 5'd0 &&
                     (instr[31:23] == 9'd0 || instr[31:20] == 12'd8 || instr[31:20] == 12'd9)) begin
          ctrl[`CTRL_REG_WR]    = 1'b1;               // ar.rd, ar.rds, lp.rd
          ctrl[`CTRL_WB_SEL]    = WB_AGU;
        end else
          ctrl[`CTRL_ILLEGAL] = 1'b1;
      end

      default: begin
        ctrl[`CTRL_ILLEGAL] = 1'b1;
      end
    endcase
  end

endmodule
