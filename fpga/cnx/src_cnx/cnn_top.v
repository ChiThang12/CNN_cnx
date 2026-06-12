`timescale 1ns/10ps
// ============================================================
// Module: cnn_top
// Description: Top-level CNN accelerator for MNIST inference
//   - 2 input feature-map BRAMs (BRAM_IF1, BRAM_IF2)
//   - 4 weight BRAMs (BRAM_W1..W4)
//   - Instantiates: cnn_fsm, addr_gen, cache_ctrl, pe_array,
//                   maxpool_ctrl, psum_fc_ctrl
//
// Fix (2026-06-11):
//   Thêm k?t n?i .conv2_out_flat(conv2_out_flat) vào u_pe_array.
//   Wire conv2_out_flat[3327:0] ?ã t?n t?i và ???c drive b?i
//   u_psum_fc_ctrl, nh?ng ch?a ???c k?t n?i t?i pe_array khi?n
//   pe_array không nh?n ???c quantized Conv2 output cho Dense1.
// ============================================================
module cnn_top(
  // Global
  input  clk,
  input  rst,
  input  start,
  output done,
  input  ready,
  output [7:0] result,
  // ---- Input Feature-Map BRAM 1 ----
  output [31:0] BRAM_IF1_ADDR,
  output [3:0]  BRAM_IF1_WE,
  output        BRAM_IF1_EN,
  input  [31:0] BRAM_IF1_DOUT,
  output [31:0] BRAM_IF1_DIN,
  // ---- Input Feature-Map BRAM 2 ----
  output [31:0] BRAM_IF2_ADDR,
  output [3:0]  BRAM_IF2_WE,
  output        BRAM_IF2_EN,
  input  [31:0] BRAM_IF2_DOUT,
  output [31:0] BRAM_IF2_DIN,
  // ---- Weight BRAM 1 ----
  output [31:0] BRAM_W1_ADDR,
  output [3:0]  BRAM_W1_WE,
  output        BRAM_W1_EN,
  input  [31:0] BRAM_W1_DOUT,
  output [31:0] BRAM_W1_DIN,
  // ---- Weight BRAM 2 ----
  output [31:0] BRAM_W2_ADDR,
  output [3:0]  BRAM_W2_WE,
  output        BRAM_W2_EN,
  input  [31:0] BRAM_W2_DOUT,
  output [31:0] BRAM_W2_DIN,
  // ---- Weight BRAM 3 ----
  output [31:0] BRAM_W3_ADDR,
  output [3:0]  BRAM_W3_WE,
  output        BRAM_W3_EN,
  input  [31:0] BRAM_W3_DOUT,
  output [31:0] BRAM_W3_DIN,
  // ---- Weight BRAM 4 ----
  output [31:0] BRAM_W4_ADDR,
  output [3:0]  BRAM_W4_WE,
  output        BRAM_W4_EN,
  input  [31:0] BRAM_W4_DOUT,
  output [31:0] BRAM_W4_DIN
);
  // ===========================================================
  // Internal signals
  // ===========================================================
  wire [5:0]  state, n_state;
  wire [6:0]  counter;
  wire [2:0]  layer;
  wire [2:0]  row_group, ch_batch;
  wire [3:0]  in_ch;
  wire [4:0]  col_pos;
  wire [5:0]  dense_cnt;
  wire [1:0]  mxpl_row;
  wire        relu_en, quan_en;
  wire [767:0] i_cache_flat;   // 96 bytes = 96*8 bits input cache
  wire [767:0] w_cache_flat;   // 96 bytes = 96*8 bits weight/bias cache
  wire [255:0] pe_out_flat;    // 8 PEs * 32-bit outputs
  wire [255:0] psum_in_flat;   // 8 PEs * 32-bit partial sums
  wire [4:0]  bits_select;
  wire [13311:0] conv2_psum_flat;
  wire [1535:0]  dense1_psum_flat;
  wire [3327:0]  conv2_out_flat;   // quantized Conv2 output: driven by psum_fc_ctrl, read by pe_array
  // ===========================================================
  // Weight BRAM DIN tied to 0 (read-only from accelerator side)
  // ===========================================================
  assign BRAM_W1_DIN = 32'd0;
  assign BRAM_W2_DIN = 32'd0;
  assign BRAM_W3_DIN = 32'd0;
  assign BRAM_W4_DIN = 32'd0;
  // ===========================================================
  // ReLU and Quantization enable: active during conv layers 1-3
  // ===========================================================
  // relu_en: active for Conv1(L1), Conv2(L2), Dense1(L3) output-final only
  // quan_en: active ONLY for Conv1/Conv2 (to quantize feature maps to 8-bit)
  //          MUST be FALSE for Dense1/Dense2 (accumulate full 32-bit sum)
  assign relu_en = (layer == 3'd1) ||
                   (layer == 3'd2 && in_ch == 4'd15) ||
                   (layer == 3'd3 && dense_cnt == 6'd51);
  assign quan_en = relu_en;
  // ===========================================================
  // Sub-module instantiations
  // ===========================================================
  // --- FSM: controls overall state machine ---
  cnn_fsm u_fsm (
    .clk        (clk),
    .rst        (rst),
    .start      (start),
    .done       (done),
    .ready      (ready),
    .state      (state),
    .n_state    (n_state),
    .counter    (counter),
    .layer      (layer),
    .row_group  (row_group),
    .ch_batch   (ch_batch),
    .in_ch      (in_ch),
    .col_pos    (col_pos),
    .dense_cnt  (dense_cnt),
    .mxpl_row   (mxpl_row)
  );
  // --- Address Generator: generates BRAM addresses ---
  addr_gen u_addr_gen (
    .clk                  (clk),
    .rst                  (rst),
    .state                (state),
    .layer                (layer),
    .row_group            (row_group),
    .ch_batch             (ch_batch),
    .in_ch                (in_ch),
    .col_pos              (col_pos),
    .dense_cnt            (dense_cnt),
    .mxpl_row             (mxpl_row),
    .counter              (counter),
    // IF BRAM addresses
    .BRAM_IF1_ADDR        (BRAM_IF1_ADDR),
    .BRAM_IF1_EN          (BRAM_IF1_EN),
    .BRAM_IF1_WE          (BRAM_IF1_WE),
    .BRAM_IF2_ADDR        (BRAM_IF2_ADDR),
    .BRAM_IF2_EN          (BRAM_IF2_EN),
    .BRAM_IF2_WE          (BRAM_IF2_WE),
    // Weight BRAM addresses
    .BRAM_W1_ADDR         (BRAM_W1_ADDR),
    .BRAM_W1_EN           (BRAM_W1_EN),
    .BRAM_W1_WE           (BRAM_W1_WE),
    .BRAM_W2_ADDR         (BRAM_W2_ADDR),
    .BRAM_W2_EN           (BRAM_W2_EN),
    .BRAM_W2_WE           (BRAM_W2_WE),
    .BRAM_W3_ADDR         (BRAM_W3_ADDR),
    .BRAM_W3_EN           (BRAM_W3_EN),
    .BRAM_W3_WE           (BRAM_W3_WE),
    .BRAM_W4_ADDR         (BRAM_W4_ADDR),
    .BRAM_W4_EN           (BRAM_W4_EN),
    .BRAM_W4_WE           (BRAM_W4_WE),
    // Misc
    .bits_select          (bits_select)
  );
  // --- Cache Controller: loads input/weight data into local cache ---
  cache_ctrl u_cache_ctrl (
    .clk             (clk),
    .rst             (rst),
    .state           (state),
    .counter         (counter),
    .bits_select     (bits_select),
    .ch_batch        (ch_batch),
    .in_ch           (in_ch),
    // BRAM data inputs
    .BRAM_IF1_DOUT   (BRAM_IF1_DOUT),
    .BRAM_IF2_DOUT   (BRAM_IF2_DOUT),
    .BRAM_W1_DOUT    (BRAM_W1_DOUT),
    .BRAM_W2_DOUT    (BRAM_W2_DOUT),
    .BRAM_W3_DOUT    (BRAM_W3_DOUT),
    .BRAM_W4_DOUT    (BRAM_W4_DOUT),
    // Cache flat outputs
    .i_cache_flat    (i_cache_flat),
    .w_cache_flat    (w_cache_flat)
  );
  // --- PE Array: 8 parallel 3x3 convolution PEs ---
  pe_array u_pe_array (
    .clk              (clk),
    .rst              (rst),
    .state            (state),
    .layer            (layer),
    .counter          (counter),
    .col_pos          (col_pos),
    .ch_batch         (ch_batch),
    .dense_cnt        (dense_cnt),
    .i_cache_flat     (i_cache_flat),
    .w_cache_flat     (w_cache_flat),
    .relu_en          (relu_en),
    .quan_en          (quan_en),
    .psum_in_flat     (psum_in_flat),
    .conv2_psum_flat  (conv2_psum_flat),
    .dense1_psum_flat (dense1_psum_flat),
    .conv2_out_flat   (conv2_out_flat),   // FIX: k?t n?i m?i - quantized Conv2 output cho Dense1
    .pe_out_flat      (pe_out_flat)
  );
  // --- MaxPool Controller: 2x2 max pooling across output feature maps ---
  maxpool_ctrl u_maxpool_ctrl (
    .clk           (clk),
    .rst           (rst),
    .state         (state),
    .layer         (layer),
    .row_group     (row_group),
    .ch_batch      (ch_batch),
    .col_pos       (col_pos),
    .counter       (counter),
    .mxpl_row      (mxpl_row),
    .pe_out_flat   (pe_out_flat),
    // Write-back to IF2 BRAM
    .BRAM_IF2_DIN  (BRAM_IF2_DIN),
    .BRAM_IF1_DIN  (BRAM_IF1_DIN)
  );
  // --- Partial Sum / Fully-Connected Controller ---
  psum_fc_ctrl u_psum_fc_ctrl (
    .clk           (clk),
    .rst           (rst),
    .state         (state),
    .layer         (layer),
    .counter       (counter),
    .ch_batch      (ch_batch),
    .in_ch         (in_ch),
    .col_pos       (col_pos),
    .dense_cnt     (dense_cnt),
    .pe_out_flat   (pe_out_flat),
    .psum_in_flat  (psum_in_flat),
    .conv2_psum_flat(conv2_psum_flat),
    .dense1_psum_flat(dense1_psum_flat),
    .conv2_out_flat (conv2_out_flat),
    .result        (result)
  );
endmodule

