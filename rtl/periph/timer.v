// ============================================================================
// timer.v — 32-bit Timer/Counter Peripheral
// ============================================================================

module timer (
  input  wire        clk,
  input  wire        rst_n,

  // Bus interface
  input  wire [7:0]  addr,
  input  wire        wr_en,
  input  wire        rd_en,
  input  wire [31:0] wdata,
  output reg  [31:0] rdata,

  output wire        irq
);

  reg        enable;
  reg        auto_reload;
  reg [31:0] prescaler;
  reg [31:0] compare;
  reg [31:0] count;
  reg [31:0] pre_cnt;
  reg        match_flag;

  // ── Tick generation ───────────────────────────────────────────────
  wire tick;
  assign tick = enable && (pre_cnt == prescaler);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      enable      <= 1'b0;
      auto_reload <= 1'b0;
      prescaler   <= 32'b0;
      compare     <= 32'hFFFF_FFFF;
      count       <= 32'b0;
      pre_cnt     <= 32'b0;
      match_flag  <= 1'b0;
    end else begin
      if (enable) begin
        if (pre_cnt >= prescaler)
          pre_cnt <= 32'b0;
        else
          pre_cnt <= pre_cnt + 1'b1;
      end

      if (tick) begin
        if (count >= compare) begin
          match_flag <= 1'b1;
          count <= auto_reload ? 32'b0 : count;
        end else begin
          count <= count + 1'b1;
        end
      end

      if (wr_en) begin
        case (addr[4:2])
          3'd0: {auto_reload, enable} <= wdata[1:0];
          3'd1: prescaler <= wdata;
          3'd2: compare   <= wdata;
          3'd3: count     <= wdata;
          3'd4: match_flag <= match_flag & ~wdata[0];
          default: ;
        endcase
      end
    end
  end

  // ── Register Read ─────────────────────────────────────────────────
  always @(*) begin
    rdata = 32'b0;
    if (rd_en) begin
      case (addr[4:2])
        3'd0: rdata = {30'b0, auto_reload, enable};
        3'd1: rdata = prescaler;
        3'd2: rdata = compare;
        3'd3: rdata = count;
        3'd4: rdata = {31'b0, match_flag};
        default: rdata = 32'b0;
      endcase
    end
  end

  assign irq = match_flag;

endmodule
