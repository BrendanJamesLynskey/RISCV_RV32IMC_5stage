// ============================================================================
// regfile.v — 32x32 Register File for BRV32P
// ============================================================================
// Two read ports (combinational), one write port (synchronous).
// x0 hardwired to zero. No internal forwarding (handled by hazard unit).
// ============================================================================

module regfile (
  input  wire        clk,
  input  wire        rst_n,

  // Read ports (combinational)
  input  wire [4:0]  rs1_addr,
  output wire [31:0] rs1_data,
  input  wire [4:0]  rs2_addr,
  output wire [31:0] rs2_data,

  // Write port (synchronous, rising edge)
  input  wire        wr_en,
  input  wire [4:0]  rd_addr,
  input  wire [31:0] rd_data
);

  reg [31:0] regs [1:31];

  // Read port A
  assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];

  // Read port B
  assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

  // Write
  integer i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 1; i < 32; i = i + 1)
        regs[i] <= 32'd0;
    end else if (wr_en && rd_addr != 5'd0) begin
      regs[rd_addr] <= rd_data;
    end
  end

endmodule
