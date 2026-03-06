// ============================================================================
// gpio.v — General-Purpose I/O Peripheral (32-bit, memory-mapped)
// ============================================================================

module gpio #(
  parameter WIDTH = 32
)(
  input  wire        clk,
  input  wire        rst_n,

  // Bus interface
  input  wire [7:0]  addr,
  input  wire        wr_en,
  input  wire        rd_en,
  input  wire [31:0] wdata,
  output reg  [31:0] rdata,

  // Physical pins
  input  wire [WIDTH-1:0] gpio_in,
  output wire [WIDTH-1:0] gpio_out,
  output wire             irq
);

  reg [WIDTH-1:0] data_out;
  reg [WIDTH-1:0] dir;
  reg [WIDTH-1:0] irq_en;
  reg [WIDTH-1:0] irq_stat;
  reg [WIDTH-1:0] gpio_in_sync, gpio_in_prev;

  // ── Double-synchroniser for async inputs ───────────────────────────
  reg [WIDTH-1:0] gpio_in_meta;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      gpio_in_meta <= 0;
      gpio_in_sync <= 0;
    end else begin
      gpio_in_meta <= gpio_in;
      gpio_in_sync <= gpio_in_meta;
    end
  end

  // ── Rising-edge detector for interrupt ─────────────────────────────
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      gpio_in_prev <= 0;
    else
      gpio_in_prev <= gpio_in_sync;
  end

  wire [WIDTH-1:0] rising_edge;
  assign rising_edge = gpio_in_sync & ~gpio_in_prev;

  // ── Register write ────────────────────────────────────────────────
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_out <= 0;
      dir      <= 0;
      irq_en   <= 0;
      irq_stat <= 0;
    end else begin
      irq_stat <= irq_stat | (rising_edge & irq_en);

      if (wr_en) begin
        case (addr[4:2])
          3'd0: data_out <= wdata[WIDTH-1:0];
          3'd2: dir      <= wdata[WIDTH-1:0];
          3'd3: irq_en   <= wdata[WIDTH-1:0];
          3'd4: irq_stat <= irq_stat & ~wdata[WIDTH-1:0]; // W1C
          default: ;
        endcase
      end
    end
  end

  // ── Register read ─────────────────────────────────────────────────
  always @(*) begin
    rdata = 32'b0;
    if (rd_en) begin
      case (addr[4:2])
        3'd0: rdata = {{(32-WIDTH){1'b0}}, data_out};
        3'd1: rdata = {{(32-WIDTH){1'b0}}, gpio_in_sync};
        3'd2: rdata = {{(32-WIDTH){1'b0}}, dir};
        3'd3: rdata = {{(32-WIDTH){1'b0}}, irq_en};
        3'd4: rdata = {{(32-WIDTH){1'b0}}, irq_stat};
        default: rdata = 32'b0;
      endcase
    end
  end

  // ── Output drive ──────────────────────────────────────────────────
  assign gpio_out = data_out & dir;
  assign irq      = |(irq_stat & irq_en);

endmodule
