// ============================================================================
// branch_predictor.v — 2-bit Saturating Counter Branch History Table
// ============================================================================
// 256-entry BHT indexed by PC[8:1]. Predicts taken/not-taken.
// BTB (Branch Target Buffer) stores the last known target for taken branches.
// Indexes and tags use halfword addresses (PC[31:1]): with RV32C, two
// instructions can share a word, and must not share an entry.
// ============================================================================

module branch_predictor #(
  parameter BHT_ENTRIES = 256,
  parameter BTB_ENTRIES = 64
)(
  input  wire        clk,
  input  wire        rst_n,

  // Prediction request (IF stage)
  input  wire [31:0] pc,
  output wire        pred_taken,
  output wire [31:0] pred_target,
  output wire        pred_valid,    // BTB hit

  // Update from EX stage
  input  wire        update_en,
  input  wire [31:0] update_pc,
  input  wire        update_taken,
  input  wire [31:0] update_target
);

  localparam BHT_IDX_W = $clog2(BHT_ENTRIES);
  localparam BTB_IDX_W = $clog2(BTB_ENTRIES);

  // ── BHT: 2-bit saturating counters ───────────────────────────────────
  reg [1:0] bht [0:BHT_ENTRIES-1];

  wire [BHT_IDX_W-1:0] pred_idx;
  wire [BHT_IDX_W-1:0] upd_idx;

  assign pred_idx = pc[BHT_IDX_W:1];
  assign upd_idx  = update_pc[BHT_IDX_W:1];

  assign pred_taken = bht[pred_idx][1];  // MSB = prediction

  // ── BTB: direct-mapped target cache ──────────────────────────────────
  reg [31:0]              btb_target [0:BTB_ENTRIES-1];
  reg [31-BTB_IDX_W-1:0]  btb_tag   [0:BTB_ENTRIES-1];
  reg                      btb_valid [0:BTB_ENTRIES-1];

  wire [BTB_IDX_W-1:0]     btb_pred_idx;
  wire [BTB_IDX_W-1:0]     btb_upd_idx;
  wire [31-BTB_IDX_W-1:0]  btb_pred_tag;
  wire [31-BTB_IDX_W-1:0]  btb_upd_tag;

  assign btb_pred_idx = pc[BTB_IDX_W:1];
  assign btb_upd_idx  = update_pc[BTB_IDX_W:1];
  assign btb_pred_tag = pc[31:BTB_IDX_W+1];
  assign btb_upd_tag  = update_pc[31:BTB_IDX_W+1];

  assign pred_valid  = btb_valid[btb_pred_idx] &&
                       (btb_tag[btb_pred_idx] == btb_pred_tag);
  assign pred_target = btb_target[btb_pred_idx];

  // ── Update logic ─────────────────────────────────────────────────────
  // One always block per entry (generate), so each resets on its own; a
  // reset loop of non-blocking array writes is not supported when this is
  // linted or simulated with Verilator.
  genvar g;
  generate
    for (g = 0; g < BHT_ENTRIES; g = g + 1) begin : g_bht
      always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
          bht[g] <= 2'b01;                       // weakly not-taken
        else if (update_en && upd_idx == g) begin
          if (update_taken && bht[g] != 2'b11)
            bht[g] <= bht[g] + 1'b1;             // saturating counter
          else if (!update_taken && bht[g] != 2'b00)
            bht[g] <= bht[g] - 1'b1;
        end
      end
    end

    // BTB: store the target of taken branches
    for (g = 0; g < BTB_ENTRIES; g = g + 1) begin : g_btb
      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          btb_valid[g]  <= 1'b0;
          btb_target[g] <= 32'b0;
          btb_tag[g]    <= 0;
        end else if (update_en && update_taken && btb_upd_idx == g) begin
          btb_valid[g]  <= 1'b1;
          btb_target[g] <= update_target;
          btb_tag[g]    <= btb_upd_tag;
        end
      end
    end
  endgenerate

endmodule
