// ============================================================================
// axi_sram.v — AXI4-Lite SRAM Slave (Unified backing memory)
// ============================================================================

module axi_sram #(
  parameter DEPTH     = 8192,
  parameter INIT_FILE = "firmware.hex"
)(
  input  wire        clk,
  input  wire        rst_n,

  // AXI4-Lite slave: Read
  input  wire [31:0] araddr,
  input  wire        arvalid,
  output wire        arready,
  output wire [31:0] rdata,
  output wire        rvalid,
  input  wire        rready,

  // AXI4-Lite slave: Write
  input  wire [31:0] awaddr,
  input  wire        awvalid,
  output wire        awready,
  input  wire [31:0] wdata,
  input  wire [3:0]  wstrb,
  input  wire        wvalid,
  output wire        wready,
  output wire        bvalid,
  input  wire        bready
);

  localparam AW = $clog2(DEPTH);

  reg [31:0] mem [0:DEPTH-1];

  // Initialise
  integer init_i;
  initial begin
    for (init_i = 0; init_i < DEPTH; init_i = init_i + 1)
      mem[init_i] = 32'h0000_0013; // NOP
    if (INIT_FILE != "")
      $readmemh(INIT_FILE, mem);
  end

  // ── Read channel ─────────────────────────────────────────────────────
  localparam [1:0] RD_IDLE = 2'd0, RD_RESP = 2'd1;
  reg [1:0] rd_state;
  reg [31:0] rd_data_reg;

  assign arready = (rd_state == RD_IDLE);
  assign rdata   = rd_data_reg;
  assign rvalid  = (rd_state == RD_RESP);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_state    <= RD_IDLE;
      rd_data_reg <= 32'b0;
    end else begin
      case (rd_state)
        RD_IDLE: begin
          if (arvalid) begin
            rd_data_reg <= mem[araddr[AW+1:2]];
            rd_state    <= RD_RESP;
          end
        end
        RD_RESP: begin
          if (rready)
            rd_state <= RD_IDLE;
        end
        default: rd_state <= RD_IDLE;
      endcase
    end
  end

  // ── Write channel ────────────────────────────────────────────────────
  localparam [1:0] WR_IDLE = 2'd0, WR_RESP = 2'd1;
  reg [1:0] wr_state;

  assign awready = (wr_state == WR_IDLE) && awvalid && wvalid;
  assign wready  = (wr_state == WR_IDLE) && awvalid && wvalid;
  assign bvalid  = (wr_state == WR_RESP);

  integer wr_i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_state <= WR_IDLE;
    end else begin
      case (wr_state)
        WR_IDLE: begin
          if (awvalid && wvalid) begin
            for (wr_i = 0; wr_i < 4; wr_i = wr_i + 1)
              if (wstrb[wr_i])
                mem[awaddr[AW+1:2]][wr_i*8 +: 8] <= wdata[wr_i*8 +: 8];
            wr_state <= WR_RESP;
          end
        end
        WR_RESP: begin
          if (bready)
            wr_state <= WR_IDLE;
        end
        default: wr_state <= WR_IDLE;
      endcase
    end
  end

endmodule
