// ============================================================================
// branch_predictor.v — 2-bit Saturating Counter Branch History Table
// ============================================================================
// 256-entry BHT indexed by PC[9:2]. Predicts taken/not-taken.
// BTB (Branch Target Buffer) stores the last known target for taken branches.
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

  assign pred_idx = pc[BHT_IDX_W+1:2];
  assign upd_idx  = update_pc[BHT_IDX_W+1:2];

  assign pred_taken = bht[pred_idx][1];  // MSB = prediction

  // ── BTB: direct-mapped target cache ──────────────────────────────────
  reg [31:0]              btb_target [0:BTB_ENTRIES-1];
  reg [31-BTB_IDX_W-2:0]  btb_tag   [0:BTB_ENTRIES-1];
  reg                      btb_valid [0:BTB_ENTRIES-1];

  wire [BTB_IDX_W-1:0]     btb_pred_idx;
  wire [BTB_IDX_W-1:0]     btb_upd_idx;
  wire [31-BTB_IDX_W-2:0]  btb_pred_tag;
  wire [31-BTB_IDX_W-2:0]  btb_upd_tag;

  assign btb_pred_idx = pc[BTB_IDX_W+1:2];
  assign btb_upd_idx  = update_pc[BTB_IDX_W+1:2];
  assign btb_pred_tag = pc[31:BTB_IDX_W+2];
  assign btb_upd_tag  = update_pc[31:BTB_IDX_W+2];

  assign pred_valid  = btb_valid[btb_pred_idx] &&
                       (btb_tag[btb_pred_idx] == btb_pred_tag);
  assign pred_target = btb_target[btb_pred_idx];

  // ── Update logic ─────────────────────────────────────────────────────
  integer i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < BHT_ENTRIES; i = i + 1)
        bht[i] <= 2'b01;  // Weakly not-taken
      for (i = 0; i < BTB_ENTRIES; i = i + 1) begin
        btb_valid[i]  <= 1'b0;
        btb_target[i] <= 32'b0;
        btb_tag[i]    <= 0;
      end
    end else if (update_en) begin
      // BHT update: saturating counter
      if (update_taken) begin
        if (bht[upd_idx] != 2'b11)
          bht[upd_idx] <= bht[upd_idx] + 1'b1;
      end else begin
        if (bht[upd_idx] != 2'b00)
          bht[upd_idx] <= bht[upd_idx] - 1'b1;
      end

      // BTB update: store target on taken branches
      if (update_taken) begin
        btb_valid[btb_upd_idx]  <= 1'b1;
        btb_target[btb_upd_idx] <= update_target;
        btb_tag[btb_upd_idx]    <= btb_upd_tag;
      end
    end
  end

endmodule
