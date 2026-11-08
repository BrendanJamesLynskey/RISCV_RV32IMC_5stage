// ============================================================================
// branch_predictor.v — Branch direction predictor and Branch Target Buffer
// ============================================================================
// BP_KIND picks the direction predictor (H&P 6th ed. §3.3):
//   0  static not-taken
//   1  one bit per entry: repeat the last outcome
//   2  two-bit saturating counters (the design's predictor; the default)
//   3  gshare: two-bit counters indexed by PC xor global history
//   4  tournament: a chooser of two-bit counters picks, per branch, between
//      kind 2 and kind 3
// Kind 2 is the original circuit, unchanged.
//
// 256-entry BHT indexed by PC[8:1]. Predicts taken/not-taken.
// BTB (Branch Target Buffer) stores the last known target for taken branches.
// Indexes and tags use halfword addresses (PC[31:1]): with RV32C, two
// instructions can share a word, and must not share an entry.
// ============================================================================

`include "brv32p_bp.vh"

module branch_predictor #(
  parameter BP_KIND     = `BP_KIND_DEFAULT,
  parameter BHT_ENTRIES = `BP_BHT_DEFAULT,
  parameter BTB_ENTRIES = 64,
  parameter GH_BITS     = `BP_GH_DEFAULT    // gshare/tournament: history length (0 .. log2(BHT_ENTRIES))
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

  wire [BHT_IDX_W-1:0] pred_idx;
  wire [BHT_IDX_W-1:0] upd_idx;
  assign pred_idx = pc[BHT_IDX_W:1];
  assign upd_idx  = update_pc[BHT_IDX_W:1];

  genvar g;

  wire dir_taken;                       // the direction predictor's answer

  // ── BHT: 2-bit saturating counters (kind 2 and the local half of 4) ──
  reg [1:0] bht [0:BHT_ENTRIES-1];
  wire      bht_taken = bht[pred_idx][1];  // MSB = prediction

  generate
    if (BP_KIND == 2 || BP_KIND == 4) begin : g_bht2
      // One always block per entry (generate), so each resets on its own; a
      // reset loop of non-blocking array writes is not supported when this is
      // linted or simulated with Verilator.
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
    end
  endgenerate

  // ── Global history and gshare (kinds 3 and 4) ──────────────────────────
  // The history holds the outcomes of the last GH_BITS branches that have
  // resolved in EX (not speculatively: fetch runs a few cycles ahead of it).
  // A branch is trained in the counter it was predicted from, not the one
  // today's history would pick: predictions are remembered by fetch address
  // in a small table (hs_*), standing in for the history a full design
  // would carry down the pipeline with the branch.
  localparam GHW = (GH_BITS < 1) ? 1 : (GH_BITS > BHT_IDX_W ? BHT_IDX_W : GH_BITS);

  reg  [GHW-1:0] ghr;
  wire [BHT_IDX_W-1:0] gh_ext = (GH_BITS == 0) ? {BHT_IDX_W{1'b0}} : ghr;
  wire [BHT_IDX_W-1:0] g_pred_idx = pred_idx ^ gh_ext;

  reg [1:0] gcnt [0:BHT_ENTRIES-1];
  wire      g_taken = gcnt[g_pred_idx][1];

  reg [1:0] cho [0:BHT_ENTRIES-1];          // chooser: MSB set = trust gshare
  wire      cho_global = cho[pred_idx][1];

  // what was predicted at each fetch address (indexed like the BTB)
  reg [GHW-1:0] hs_hist [0:BTB_ENTRIES-1];
  reg           hs_loc  [0:BTB_ENTRIES-1];
  reg           hs_glb  [0:BTB_ENTRIES-1];
  wire [BTB_IDX_W-1:0] hs_pred_idx = pc[BTB_IDX_W:1];
  wire [BTB_IDX_W-1:0] hs_upd_idx  = update_pc[BTB_IDX_W:1];
  wire [GHW-1:0]       hs_hist_upd = hs_hist[hs_upd_idx];
  wire [BHT_IDX_W-1:0] hh_ext      = (GH_BITS == 0) ? {BHT_IDX_W{1'b0}} : hs_hist_upd;
  wire [BHT_IDX_W-1:0] g_upd_idx   = upd_idx ^ hh_ext;
  wire                 upd_loc     = hs_loc[hs_upd_idx];
  wire                 upd_glb     = hs_glb[hs_upd_idx];

  generate
    if (BP_KIND >= 3) begin : g_gshare
      always @(posedge clk) begin
        hs_hist[hs_pred_idx] <= gh_ext[GHW-1:0];
        hs_loc[hs_pred_idx]  <= bht_taken;
        hs_glb[hs_pred_idx]  <= g_taken;
      end
      always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
          ghr <= {GHW{1'b0}};
        else if (update_en)
          ghr <= {ghr, update_taken};
      end
      for (g = 0; g < BHT_ENTRIES; g = g + 1) begin : g_gcnt
        always @(posedge clk or negedge rst_n) begin
          if (!rst_n)
            gcnt[g] <= 2'b01;
          else if (update_en && g_upd_idx == g) begin
            if (update_taken && gcnt[g] != 2'b11)
              gcnt[g] <= gcnt[g] + 1'b1;
            else if (!update_taken && gcnt[g] != 2'b00)
              gcnt[g] <= gcnt[g] - 1'b1;
          end
        end
      end
    end
    if (BP_KIND == 4) begin : g_tourn
      // The chooser moves toward whichever half was right, when they differed
      for (g = 0; g < BHT_ENTRIES; g = g + 1) begin : g_cho
        always @(posedge clk or negedge rst_n) begin
          if (!rst_n)
            cho[g] <= 2'b01;                         // weakly local
          else if (update_en && upd_idx == g && upd_loc != upd_glb) begin
            if (upd_glb == update_taken && cho[g] != 2'b11)
              cho[g] <= cho[g] + 1'b1;
            else if (upd_glb != update_taken && cho[g] != 2'b00)
              cho[g] <= cho[g] - 1'b1;
          end
        end
      end
    end
  endgenerate

  // ── One bit per entry (kind 1) ───────────────────────────────────────
  reg [BHT_ENTRIES-1:0] bht1;
  wire bht1_taken = bht1[pred_idx];
  generate
    if (BP_KIND == 1) begin : g_bht1
      always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
          bht1 <= {BHT_ENTRIES{1'b0}};
        else if (update_en)
          bht1[upd_idx] <= update_taken;
      end
    end
  endgenerate

  assign dir_taken = (BP_KIND == 0) ? 1'b0 :
                     (BP_KIND == 1) ? bht1_taken :
                     (BP_KIND == 3) ? g_taken :
                     (BP_KIND == 4) ? (cho_global ? g_taken : bht_taken) :
                                      bht_taken;
  assign pred_taken = dir_taken;

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
  generate
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
