// ============================================================================
// dcache.v — 2-Way Set-Associative Data Cache (Write-Through)
// ============================================================================

module dcache #(
  parameter SETS       = 64,
  parameter WAYS       = 2,
  parameter LINE_BYTES = 16
)(
  input  wire        clk,
  input  wire        rst_n,

  // CPU interface
  input  wire [31:0] addr,
  input  wire        rd_en,
  input  wire        wr_en,
  input  wire [1:0]  width,
  input  wire        sign_ext,
  input  wire [31:0] wdata,
  output reg  [31:0] rdata,
  output reg         ready,

  // Memory interface
  output reg  [31:0] mem_addr,
  output reg         mem_rd,
  output reg         mem_wr,
  output reg  [31:0] mem_wdata,
  output reg  [3:0]  mem_wstrb,
  input  wire [31:0] mem_rdata,
  input  wire        mem_valid,
  input  wire        mem_wr_done
);

  `include "brv32p_defs.vh"

  localparam OFFSET_W = $clog2(LINE_BYTES);
  localparam SET_W    = $clog2(SETS);
  localparam TAG_W    = 32 - SET_W - OFFSET_W;
  localparam WORDS    = LINE_BYTES / 4;

  // ── Storage ──────────────────────────────────────────────────────────
  reg [TAG_W-1:0] tag_mem  [0:SETS-1][0:WAYS-1];
  reg             valid_mem[0:SETS-1][0:WAYS-1];
  reg [31:0]      data_mem [0:SETS-1][0:WAYS-1][0:WORDS-1];
  reg             lru      [0:SETS-1];

  // ── Address decomposition ────────────────────────────────────────────
  wire [TAG_W-1:0]    tag;
  wire [SET_W-1:0]    set_idx;
  wire [OFFSET_W-3:0] word_sel;
  wire [1:0]          byte_off;

  assign tag      = addr[31:SET_W+OFFSET_W];
  assign set_idx  = addr[SET_W+OFFSET_W-1:OFFSET_W];
  assign word_sel = addr[OFFSET_W-1:2];
  assign byte_off = addr[1:0];

  // ── Hit detection ────────────────────────────────────────────────────
  wire hit0, hit1, hit;
  wire hit_way;
  assign hit0    = valid_mem[set_idx][0] && (tag_mem[set_idx][0] == tag);
  assign hit1    = valid_mem[set_idx][1] && (tag_mem[set_idx][1] == tag);
  assign hit     = hit0 || hit1;
  assign hit_way = hit1;

  // ── Sub-word read logic ──────────────────────────────────────────────
  wire [31:0] raw_word;
  assign raw_word = hit0 ? data_mem[set_idx][0][word_sel] :
                           data_mem[set_idx][1][word_sel];

  // Hoisted local variables for sub-word read
  reg [7:0]  byte_val;
  reg [15:0] half_val;

  always @(*) begin
    rdata = 32'b0;
    byte_val = 8'b0;
    half_val = 16'b0;
    case (width)
      MEM_BYTE: begin
        case (byte_off)
          2'd0: byte_val = raw_word[7:0];
          2'd1: byte_val = raw_word[15:8];
          2'd2: byte_val = raw_word[23:16];
          2'd3: byte_val = raw_word[31:24];
        endcase
        rdata = sign_ext ? {{24{byte_val[7]}}, byte_val} : {24'b0, byte_val};
      end
      MEM_HALF: begin
        half_val = byte_off[1] ? raw_word[31:16] : raw_word[15:0];
        rdata = sign_ext ? {{16{half_val[15]}}, half_val} : {16'b0, half_val};
      end
      MEM_WORD: rdata = raw_word;
      default:  rdata = raw_word;
    endcase
  end

  // ── Write strobe generation ──────────────────────────────────────────
  reg [3:0] wstrb;
  always @(*) begin
    case (width)
      MEM_BYTE: wstrb = 4'b0001 << byte_off;
      MEM_HALF: wstrb = byte_off[1] ? 4'b1100 : 4'b0011;
      MEM_WORD: wstrb = 4'b1111;
      default:  wstrb = 4'b1111;
    endcase
  end

  reg [31:0] wdata_aligned;
  always @(*) begin
    case (width)
      MEM_BYTE: wdata_aligned = {4{wdata[7:0]}};
      MEM_HALF: wdata_aligned = {2{wdata[15:0]}};
      MEM_WORD: wdata_aligned = wdata;
      default:  wdata_aligned = wdata;
    endcase
  end

  // ── Write buffer ─────────────────────────────────────────────────────
  reg        wbuf_valid;
  reg [31:0] wbuf_addr;
  reg [31:0] wbuf_data;
  reg [3:0]  wbuf_strb;

  // ── FSM ──────────────────────────────────────────────────────────────
  localparam [2:0] DC_IDLE = 3'd0, DC_FILL = 3'd1, DC_FILL_DONE = 3'd2, DC_WRITE_THROUGH = 3'd3;
  reg [2:0] state;
  reg [1:0] fill_cnt;
  reg       fill_way;
  reg [31:0] pending_addr;
  reg [31:0] pending_wdata;
  reg [3:0]  pending_wstrb;
  reg        pending_is_write;

  integer s, w2, ii;

  always @(*) begin
    ready     = 1'b0;
    mem_rd    = 1'b0;
    mem_wr    = wbuf_valid;
    mem_addr  = wbuf_valid ? wbuf_addr : 32'b0;
    mem_wdata = wbuf_data;
    mem_wstrb = wbuf_valid ? wbuf_strb : 4'b0;

    case (state)
      DC_IDLE: begin
        if ((rd_en || wr_en) && hit) begin
          if (wr_en && wbuf_valid)
            ready = 1'b0;
          else
            ready = 1'b1;
        end else if ((rd_en || wr_en) && !hit) begin
          ready = 1'b0;
        end else begin
          ready = 1'b1;
        end
      end
      DC_FILL: begin
        if (!wbuf_valid) begin
          mem_rd   = 1'b1;
          mem_addr = {pending_addr[31:OFFSET_W], fill_cnt, 2'b00};
        end
      end
      DC_FILL_DONE: begin
        ready = 1'b1;
      end
      DC_WRITE_THROUGH: begin
        ready = 1'b0;
      end
      default: ;
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state            <= DC_IDLE;
      fill_cnt         <= 2'b0;
      fill_way         <= 1'b0;
      pending_is_write <= 1'b0;
      wbuf_valid       <= 1'b0;
      wbuf_addr        <= 32'b0;
      wbuf_data        <= 32'b0;
      wbuf_strb        <= 4'b0;
      for (s = 0; s < SETS; s = s + 1) begin
        for (w2 = 0; w2 < WAYS; w2 = w2 + 1)
          valid_mem[s][w2] <= 1'b0;
        lru[s] <= 1'b0;
      end
    end else begin
      // Write buffer drain: clear when AXI acknowledges
      if (wbuf_valid && mem_wr_done)
        wbuf_valid <= 1'b0;

      case (state)
        DC_IDLE: begin
          if ((rd_en || wr_en) && hit) begin
            if (wr_en && !wbuf_valid) begin
              lru[set_idx] <= hit_way ? 1'b0 : 1'b1;
              for (ii = 0; ii < 4; ii = ii + 1)
                if (wstrb[ii])
                  data_mem[set_idx][hit_way][word_sel][ii*8 +: 8] <= wdata_aligned[ii*8 +: 8];
              wbuf_valid <= 1'b1;
              wbuf_addr  <= addr;
              wbuf_data  <= wdata_aligned;
              wbuf_strb  <= wstrb;
            end else if (!wr_en) begin
              lru[set_idx] <= hit_way ? 1'b0 : 1'b1;
            end
          end else if ((rd_en || wr_en) && !hit && !wbuf_valid) begin
            fill_way         <= lru[set_idx] ? 1'b1 : 1'b0;
            fill_cnt         <= 2'b0;
            pending_addr     <= addr;
            pending_wdata    <= wdata_aligned;
            pending_wstrb    <= wstrb;
            pending_is_write <= wr_en;
            state            <= DC_FILL;
          end
        end

        DC_FILL: begin
          if (!wbuf_valid && mem_valid) begin
            data_mem[set_idx][fill_way][fill_cnt] <= mem_rdata;
            if (fill_cnt == 2'd3) begin
              tag_mem[set_idx][fill_way]   <= tag;
              valid_mem[set_idx][fill_way] <= 1'b1;
              lru[set_idx]                 <= fill_way ? 1'b0 : 1'b1;
              state                        <= DC_FILL_DONE;
            end else begin
              fill_cnt <= fill_cnt + 1'b1;
            end
          end
        end

        DC_FILL_DONE: begin
          if (pending_is_write) begin
            for (ii = 0; ii < 4; ii = ii + 1)
              if (pending_wstrb[ii])
                data_mem[set_idx][fill_way][word_sel][ii*8 +: 8] <= pending_wdata[ii*8 +: 8];
            wbuf_valid <= 1'b1;
            wbuf_addr  <= pending_addr;
            wbuf_data  <= pending_wdata;
            wbuf_strb  <= pending_wstrb;
          end
          state <= DC_IDLE;
        end

        DC_WRITE_THROUGH: begin
          if (!wbuf_valid)
            state <= DC_IDLE;
        end

        default: state <= DC_IDLE;
      endcase
    end
  end

endmodule
