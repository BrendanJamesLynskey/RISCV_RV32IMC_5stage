// ============================================================================
// axi_interconnect.v — Simple AXI4-Lite Bus Fabric
// ============================================================================

module axi_interconnect (
  input  wire        clk,
  input  wire        rst_n,

  // Master 0: I-Cache (read only)
  input  wire [31:0] m0_araddr,
  input  wire        m0_arvalid,
  output reg         m0_arready,
  output reg  [31:0] m0_rdata,
  output reg         m0_rvalid,
  input  wire        m0_rready,

  // Master 1: D-Cache (reads)
  input  wire [31:0] m1_araddr,
  input  wire        m1_arvalid,
  output reg         m1_arready,
  output reg  [31:0] m1_rdata,
  output reg         m1_rvalid,
  input  wire        m1_rready,

  // Master 1: D-Cache (writes)
  input  wire [31:0] m1_awaddr,
  input  wire        m1_awvalid,
  output reg         m1_awready,
  input  wire [31:0] m1_wdata,
  input  wire [3:0]  m1_wstrb,
  input  wire        m1_wvalid,
  output reg         m1_wready,
  output reg         m1_bvalid,
  input  wire        m1_bready,

  // Write completion signal to dcache
  output wire        m1_wr_done,

  // Slave 0: Main Memory
  output reg  [31:0] s0_araddr,
  output reg         s0_arvalid,
  input  wire        s0_arready,
  input  wire [31:0] s0_rdata,
  input  wire        s0_rvalid,
  output reg         s0_rready,
  output reg  [31:0] s0_awaddr,
  output reg         s0_awvalid,
  input  wire        s0_awready,
  output reg  [31:0] s0_wdata,
  output reg  [3:0]  s0_wstrb,
  output reg         s0_wvalid,
  input  wire        s0_wready,
  input  wire        s0_bvalid,
  output reg         s0_bready,

  // Slave 1: Peripherals
  output reg  [31:0] s1_araddr,
  output reg         s1_arvalid,
  input  wire        s1_arready,
  input  wire [31:0] s1_rdata,
  input  wire        s1_rvalid,
  output reg         s1_rready,
  output reg  [31:0] s1_awaddr,
  output reg         s1_awvalid,
  input  wire        s1_awready,
  output reg  [31:0] s1_wdata,
  output reg  [3:0]  s1_wstrb,
  output reg         s1_wvalid,
  input  wire        s1_wready,
  input  wire        s1_bvalid,
  output reg         s1_bready
);

  // ── Arbiter state ────────────────────────────────────────────────────
  localparam [2:0] ARB_IDLE = 3'd0, ARB_M0_RD = 3'd1, ARB_M1_RD = 3'd2, ARB_M1_WR = 3'd3;
  reg [2:0] arb_state;

  // Address decode
  function addr_is_periph;
    input [31:0] a;
    begin
      addr_is_periph = (a[31:28] == 4'h2);
    end
  endfunction

  // ── Registered write request ─────────────────────────────────────────
  reg [31:0] wr_addr_reg, wr_data_reg;
  reg [3:0]  wr_strb_reg;
  reg        wr_target_periph;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      arb_state        <= ARB_IDLE;
      wr_addr_reg      <= 32'b0;
      wr_data_reg      <= 32'b0;
      wr_strb_reg      <= 4'b0;
      wr_target_periph <= 1'b0;
    end else begin
      case (arb_state)
        ARB_IDLE: begin
          if (m1_awvalid && m1_wvalid) begin
            arb_state        <= ARB_M1_WR;
            wr_addr_reg      <= m1_awaddr;
            wr_data_reg      <= m1_wdata;
            wr_strb_reg      <= m1_wstrb;
            wr_target_periph <= addr_is_periph(m1_awaddr);
          end else if (m1_arvalid) begin
            arb_state <= ARB_M1_RD;
          end else if (m0_arvalid) begin
            arb_state <= ARB_M0_RD;
          end
        end

        ARB_M0_RD: begin
          if (addr_is_periph(m0_araddr) ? (s1_rvalid && m0_rready) : (s0_rvalid && m0_rready))
            arb_state <= ARB_IDLE;
        end

        ARB_M1_RD: begin
          if (addr_is_periph(m1_araddr) ? (s1_rvalid && m1_rready) : (s0_rvalid && m1_rready))
            arb_state <= ARB_IDLE;
        end

        ARB_M1_WR: begin
          if (wr_target_periph ? (s1_bvalid) : (s0_bvalid))
            arb_state <= ARB_IDLE;
        end

        default: arb_state <= ARB_IDLE;
      endcase
    end
  end

  // ── Write completion pulse ───────────────────────────────────────────
  assign m1_wr_done = (arb_state == ARB_M1_WR) &&
                      (wr_target_periph ? s1_bvalid : s0_bvalid);

  // ── Routing ──────────────────────────────────────────────────────────
  always @(*) begin
    // Default: deassert everything
    m0_arready = 1'b0; m0_rdata = 32'b0; m0_rvalid = 1'b0;
    m1_arready = 1'b0; m1_rdata = 32'b0; m1_rvalid = 1'b0;
    m1_awready = 1'b0; m1_wready = 1'b0; m1_bvalid = 1'b0;

    s0_araddr = 32'b0; s0_arvalid = 1'b0; s0_rready = 1'b0;
    s0_awaddr = 32'b0; s0_awvalid = 1'b0; s0_wdata  = 32'b0;
    s0_wstrb  = 4'b0;  s0_wvalid  = 1'b0; s0_bready = 1'b0;

    s1_araddr = 32'b0; s1_arvalid = 1'b0; s1_rready = 1'b0;
    s1_awaddr = 32'b0; s1_awvalid = 1'b0; s1_wdata  = 32'b0;
    s1_wstrb  = 4'b0;  s1_wvalid  = 1'b0; s1_bready = 1'b0;

    case (arb_state)
      ARB_M0_RD: begin
        if (addr_is_periph(m0_araddr)) begin
          s1_araddr  = m0_araddr;  s1_arvalid = m0_arvalid;
          m0_arready = s1_arready; m0_rdata   = s1_rdata;
          m0_rvalid  = s1_rvalid;  s1_rready  = m0_rready;
        end else begin
          s0_araddr  = m0_araddr;  s0_arvalid = m0_arvalid;
          m0_arready = s0_arready; m0_rdata   = s0_rdata;
          m0_rvalid  = s0_rvalid;  s0_rready  = m0_rready;
        end
      end

      ARB_M1_RD: begin
        if (addr_is_periph(m1_araddr)) begin
          s1_araddr  = m1_araddr;  s1_arvalid = m1_arvalid;
          m1_arready = s1_arready; m1_rdata   = s1_rdata;
          m1_rvalid  = s1_rvalid;  s1_rready  = m1_rready;
        end else begin
          s0_araddr  = m1_araddr;  s0_arvalid = m1_arvalid;
          m1_arready = s0_arready; m1_rdata   = s0_rdata;
          m1_rvalid  = s0_rvalid;  s0_rready  = m1_rready;
        end
      end

      ARB_M1_WR: begin
        if (wr_target_periph) begin
          s1_awaddr  = wr_addr_reg;  s1_awvalid = 1'b1;
          s1_wdata   = wr_data_reg;  s1_wstrb   = wr_strb_reg;
          s1_wvalid  = 1'b1;
          m1_awready = s1_awready;   m1_wready  = s1_wready;
          m1_bvalid  = s1_bvalid;    s1_bready  = m1_bready;
        end else begin
          s0_awaddr  = wr_addr_reg;  s0_awvalid = 1'b1;
          s0_wdata   = wr_data_reg;  s0_wstrb   = wr_strb_reg;
          s0_wvalid  = 1'b1;
          m1_awready = s0_awready;   m1_wready  = s0_wready;
          m1_bvalid  = s0_bvalid;    s0_bready  = m1_bready;
        end
      end

      default: ;
    endcase
  end

endmodule
