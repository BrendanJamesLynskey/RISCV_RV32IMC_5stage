// ============================================================================
// csr.v — Control and Status Register Unit for BRV32P
// ============================================================================

module csr (
  input  wire        clk,
  input  wire        rst_n,

  // CSR access
  input  wire        csr_en,
  input  wire [11:0] csr_addr,
  input  wire [2:0]  csr_op,
  input  wire [31:0] csr_wdata,
  output reg  [31:0] csr_rdata,

  // Trap interface
  input  wire        trap_enter,
  input  wire [31:0] trap_cause,
  input  wire [31:0] trap_val,
  input  wire [31:0] trap_pc,
  output wire [31:0] mtvec_out,
  output wire [31:0] mepc_out,

  // MRET
  input  wire        mret,

  // Interrupts
  input  wire        ext_irq,
  input  wire        timer_irq,
  input  wire        instr_retired,
  output wire        irq_pending
);

  `include "brv32p_defs.vh"

  reg [31:0] mstatus, mie, mtvec, mscratch, mepc, mcause, mtval;
  reg [31:0] mip;
  reg [63:0] mcycle, minstret;

  assign mtvec_out = mtvec;
  assign mepc_out  = mepc;

  // Interrupt pending
  always @(*) begin
    mip = 32'b0;
    mip[11] = ext_irq;
    mip[7]  = timer_irq;
  end
  assign irq_pending = mstatus[3] & |(mip & mie);

  // CSR Read
  always @(*) begin
    csr_rdata = 32'b0;
    case (csr_addr)
      CSR_MSTATUS:  csr_rdata = mstatus;
      CSR_MIE:      csr_rdata = mie;
      CSR_MTVEC:    csr_rdata = mtvec;
      CSR_MSCRATCH: csr_rdata = mscratch;
      CSR_MEPC:     csr_rdata = mepc;
      CSR_MCAUSE:   csr_rdata = mcause;
      CSR_MTVAL:    csr_rdata = mtval;
      CSR_MIP:      csr_rdata = mip;
      CSR_MCYCLE:   csr_rdata = mcycle[31:0];
      CSR_MINSTRET: csr_rdata = minstret[31:0];
      CSR_MHARTID:  csr_rdata = 32'd0;
      default:      csr_rdata = 32'b0;
    endcase
  end

  // Hoisted local variable
  reg [31:0] nv;

  // CSR Write / Trap
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mstatus  <= 32'b0;
      mie      <= 32'b0;
      mtvec    <= 32'b0;
      mscratch <= 32'b0;
      mepc     <= 32'b0;
      mcause   <= 32'b0;
      mtval    <= 32'b0;
      mcycle   <= 64'b0;
      minstret <= 64'b0;
    end else begin
      mcycle <= mcycle + 1'b1;
      if (instr_retired)
        minstret <= minstret + 1'b1;

      if (trap_enter) begin
        mepc       <= trap_pc;
        mcause     <= trap_cause;
        mtval      <= trap_val;
        mstatus[7] <= mstatus[3];
        mstatus[3] <= 1'b0;
      end else if (mret) begin
        mstatus[3] <= mstatus[7];
        mstatus[7] <= 1'b1;
      end else if (csr_en) begin
        case (csr_op[1:0])
          2'b01: nv = csr_wdata;
          2'b10: nv = csr_rdata | csr_wdata;
          2'b11: nv = csr_rdata & ~csr_wdata;
          default: nv = csr_rdata;
        endcase
        case (csr_addr)
          CSR_MSTATUS:  mstatus  <= nv & 32'h88;
          CSR_MIE:      mie      <= nv;
          CSR_MTVEC:    mtvec    <= {nv[31:2], 2'b00};
          CSR_MSCRATCH: mscratch <= nv;
          CSR_MEPC:     mepc     <= {nv[31:2], 2'b00};
          CSR_MCAUSE:   mcause   <= nv;
          CSR_MTVAL:    mtval    <= nv;
          default: ;
        endcase
      end
    end
  end

endmodule
