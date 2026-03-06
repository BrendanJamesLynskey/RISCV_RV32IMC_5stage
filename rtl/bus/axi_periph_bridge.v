// ============================================================================
// axi_periph_bridge.v — AXI4-Lite to Simple Bus Peripheral Bridge
// ============================================================================
module axi_periph_bridge (
  input  wire        clk,
  input  wire        rst_n,
  // AXI read
  input  wire [31:0] araddr,  input  wire arvalid, output wire arready,
  output wire [31:0] rdata,   output wire rvalid,  input  wire rready,
  // AXI write
  input  wire [31:0] awaddr,  input  wire awvalid, output wire awready,
  input  wire [31:0] wdata,   input  wire [3:0] wstrb,
  input  wire        wvalid,  output wire wready,
  output wire        bvalid,  input  wire bready,
  // GPIO
  output reg  [7:0]  gpio_addr, output reg gpio_rd, output reg gpio_wr,
  output reg  [31:0] gpio_wdata, input wire [31:0] gpio_rdata,
  // UART
  output reg  [7:0]  uart_addr, output reg uart_rd, output reg uart_wr,
  output reg  [31:0] uart_wdata, input wire [31:0] uart_rdata,
  // Timer
  output reg  [7:0]  timer_addr, output reg timer_rd, output reg timer_wr,
  output reg  [31:0] timer_wdata, input wire [31:0] timer_rdata
);

  function [1:0] psel;
    input [31:0] a;
    begin
      case (a[11:8])
        4'h0: psel = 2'd0;
        4'h1: psel = 2'd1;
        4'h2: psel = 2'd2;
        default: psel = 2'd0;
      endcase
    end
  endfunction

  // Read FSM
  localparam [1:0] RI = 2'd0, RA = 2'd1, RR = 2'd2;
  reg [1:0] rfsm;
  reg [31:0] rdr, rar;
  assign arready = (rfsm == RI);
  assign rdata = rdr;
  assign rvalid = (rfsm == RR);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rfsm <= RI; rdr <= 0; rar <= 0; end
    else case (rfsm)
      RI: if (arvalid) begin rar <= araddr; rfsm <= RA; end
      RA: begin
        case (psel(rar)) 2'd0: rdr<=gpio_rdata; 2'd1: rdr<=uart_rdata; 2'd2: rdr<=timer_rdata; default: rdr<=0; endcase
        rfsm <= RR;
      end
      RR: if (rready) rfsm <= RI;
      default: rfsm <= RI;
    endcase
  end

  // Write FSM
  localparam [1:0] WI = 2'd0, WA = 2'd1, WRR = 2'd2;
  reg [1:0] wfsm;
  reg [31:0] war, wdr;
  assign awready = (wfsm==WI) && awvalid && wvalid;
  assign wready  = (wfsm==WI) && awvalid && wvalid;
  assign bvalid  = (wfsm==WRR);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin wfsm<=WI; war<=0; wdr<=0; end
    else case (wfsm)
      WI: if (awvalid&&wvalid) begin war<=awaddr; wdr<=wdata; wfsm<=WA; end
      WA: wfsm <= WRR;
      WRR: if (bready) wfsm <= WI;
      default: wfsm <= WI;
    endcase
  end

  // Unified read/write address and control
  always @(*) begin
    gpio_rd=0; uart_rd=0; timer_rd=0;
    gpio_wr=0; uart_wr=0; timer_wr=0;
    gpio_wdata=wdr; uart_wdata=wdr; timer_wdata=wdr;

    gpio_addr=rar[7:0]; uart_addr=rar[7:0]; timer_addr=rar[7:0];

    if (rfsm==RA) case(psel(rar)) 2'd0:gpio_rd=1; 2'd1:uart_rd=1; 2'd2:timer_rd=1; default:; endcase

    if (wfsm==WA) begin
      gpio_addr=war[7:0]; uart_addr=war[7:0]; timer_addr=war[7:0];
      case(psel(war)) 2'd0:gpio_wr=1; 2'd1:uart_wr=1; 2'd2:timer_wr=1; default:; endcase
    end
  end

endmodule
