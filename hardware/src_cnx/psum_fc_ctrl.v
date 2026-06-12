`timescale 1ns/10ps
`define DATA_BITS 32

// =============================================================================
// Module: psum_fc_ctrl
// Description: Partial Sum Controller for FC/Conv layers.
//              Manages psum feedback to PEs, accumulates Conv2/Dense1/Dense2
//              partial sums, captures quantized Conv2 output for Dense1 input,
//              and computes final 2-class result.
//
// Ports:
//   clk, rst        - clock and active-high reset
//   state [5:0]     - current FSM state from cnn_top
//   layer [2:0]     - current layer index
//   counter [6:0]   - general-purpose counter from FSM
//   ch_batch [2:0]  - channel batch index (0..3 for Conv2, 0..5 for Dense1)
//   in_ch [3:0]     - input channel index within a group (0..15)
//   col_pos [4:0]   - column position (0..12 for Conv2)
//   dense_cnt [5:0] - dense group counter (0..51 for Dense1, 0..6 for Dense2)
//   pe_out_flat     - 8 PE outputs packed into 256 bits
//
//   psum_in_flat    - psum feedback to PE array (256 bits)
//   conv2_psum_flat - Conv2 accumulated partial sums (4*13*8*32 bits)
//   dense1_psum_flat- Dense1 PE activations / Dense2 input (6*8*32 bits)
//   conv2_out_flat  - quantized Conv2 output for Dense1 input (416*8 bits)
//   result          - final inference result (class 0 or 1)
// =============================================================================

module psum_fc_ctrl(
  input  wire        clk,
  input  wire        rst,
  input  wire [5:0]  state,
  input  wire [2:0]  layer,
  input  wire [6:0]  counter,
  input  wire [2:0]  ch_batch,
  input  wire [3:0]  in_ch,
  input  wire [4:0]  col_pos,
  input  wire [5:0]  dense_cnt,
  input  wire [255:0] pe_out_flat,    // 8 PE outputs packed: [PE7..PE0]

  output wire [255:0]   psum_in_flat,       // psum feedback to PE (8 x 32b)
  output wire [13311:0] conv2_psum_flat,    // Conv2 partial sums: 4*13*8*32 bits
  output wire [1535:0]  dense1_psum_flat,   // Dense1 output (6*8*32 bits)
  output wire [3327:0]  conv2_out_flat,     // quantized Conv2 output: 416*8 bits
  output wire [7:0]     result
);

// ---------------------------------------------------------------------------
// FSM State Parameters
// ---------------------------------------------------------------------------
parameter
  IDLE    = 6'd0,
  L2_RST  = 6'd8,
  L2_SET  = 6'd11,
  L2_EXE  = 6'd12,
  L2_ACC  = 6'd13,
  L2_WRITE= 6'd14,
  L3_RST  = 6'd15,
  L3_RD   = 6'd16,
  L3_EXE  = 6'd17,
  L3_ACC  = 6'd18,
  L3_OUT  = 6'd19,
  L4_RST  = 6'd20,
  L4_RD   = 6'd21,
  L4_EXE  = 6'd22,
  L4_ACC  = 6'd23,
  L4_OUT  = 6'd24;

// ---------------------------------------------------------------------------
// Internal wire/reg declarations
// ---------------------------------------------------------------------------

// Unpacked PE output wires (from pe_out_flat)
wire [31:0] pe_out [0:7];

// Partial sum feedback register array (fed back to PE array each cycle)
reg  [31:0] psum_in [0:7];

// Conv2 accumulated partial sums: [ch_batch 0..3][col_pos 0..12][PE 0..7]
reg  signed [31:0] conv2_psum [0:3][0:12][0:7];

// Dense1 accumulated output: [batch 0..5][PE 0..7]
// Each entry = final accumulated psum after all 52 dense_cnt groups
reg  signed [31:0] dense1_psum [0:5][0:7];

// Dense2 two-neuron partial sums (accumulates over groups)
reg  signed [31:0] dense2_psum [0:1];

// Quantized Conv2 output stored after L2_ACC (for Dense1 activation input)
// 416 values: 13 cols * 32 channels = 13*32 = 416
reg  [7:0] conv2_out [0:415];

// Final classification result register
reg  [7:0] result_r;

// Loop variables
integer i, j;
genvar  k, a, q;

// ---------------------------------------------------------------------------
// Generate: unpack pe_out_flat -> pe_out[0..7]
// Generate: pack psum_in[0..7] -> psum_in_flat
// Generate: pack conv2_psum -> conv2_psum_flat [batch][col][PE]
// Generate: pack dense1_psum -> dense1_psum_flat [batch][PE]
// Generate: pack conv2_out -> conv2_out_flat
// ---------------------------------------------------------------------------
generate
  for (k = 0; k < 8; k = k + 1) begin : gen_pe
    assign pe_out[k]                    = pe_out_flat[k*32 +: 32];
    assign psum_in_flat[k*32 +: 32]    = psum_in[k];
  end

  // conv2_psum_flat layout: [batch][col][PE] -> index = (a*13*8 + k*8 + j)*32
  for (a = 0; a < 4; a = a + 1) begin : gen_c2b
    for (k = 0; k < 13; k = k + 1) begin : gen_c2c
      for (j = 0; j < 8; j = j + 1) begin : gen_c2p
        assign conv2_psum_flat[(a*13*8 + k*8 + j)*32 +: 32] = conv2_psum[a][k][j];
      end
    end
  end

  // dense1_psum_flat layout: [batch][PE] -> index = (a*8 + k)*32
  for (a = 0; a < 6; a = a + 1) begin : gen_d1b
    for (k = 0; k < 8; k = k + 1) begin : gen_d1p
      assign dense1_psum_flat[(a*8 + k)*32 +: 32] = dense1_psum[a][k];
    end
  end

  // conv2_out_flat: 416 bytes packed
  for (q = 0; q < 416; q = q + 1) begin : gen_c2out
    assign conv2_out_flat[q*8 +: 8] = conv2_out[q];
  end
endgenerate

// Tie result output to register
assign result = result_r;

// ---------------------------------------------------------------------------
// psum_in: partial sum feedback to PE array
//   - Reset to 0 at IDLE / L2_RST / L3_RST / L4_RST
//   - Conv2 (L2_SET): load saved psum for (ch_batch, col_pos) if in_ch != 0
//                     else clear to 0 for fresh start
//   - Dense1 (L3_OUT): clear to 0 before new batch starts
//            (L3_ACC): capture PE output as new psum for next group
//   - Dense2 (L4_ACC): save first 2 PE outputs as running psum
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
  if (rst) begin
    for (i = 0; i < 8; i = i + 1)
      psum_in[i] <= 32'd0;
  end
  else begin
    if (state == IDLE || state == L2_RST || state == L3_RST || state == L4_RST) begin
      // Clear psum at start of each layer phase
      for (i = 0; i < 8; i = i + 1)
        psum_in[i] <= 32'd0;
    end

    // ---- Conv2 ----
    else if (state == L2_SET && in_ch != 4'd0) begin
      // Load previously saved psum for this (ch_batch, col_pos) position
      // so PE can continue accumulating from where it left off
      for (i = 0; i < 8; i = i + 1)
        psum_in[i] <= conv2_psum[ch_batch][col_pos][i];
    end
    else if (state == L2_SET && in_ch == 4'd0) begin
      // Fresh start: first in_ch group for this (ch_batch, col_pos)
      for (i = 0; i < 8; i = i + 1)
        psum_in[i] <= 32'd0;
    end

    // ---- Dense1 ----
    else if (state == L3_OUT) begin
      // After capturing batch output, reset psum for next batch
      for (i = 0; i < 8; i = i + 1)
        psum_in[i] <= 32'd0;
    end
    else if (state == L3_ACC) begin
      // Save current PE output as psum for next dense group
      for (i = 0; i < 8; i = i + 1)
        psum_in[i] <= pe_out[i];
    end

    // ---- Dense2 ----
    else if (state == L4_ACC) begin
      // Save first 2 PE outputs as running partial sums for 2-neuron layer
      for (i = 0; i < 2; i = i + 1)
        psum_in[i] <= pe_out[i];
    end
  end
end

// ---------------------------------------------------------------------------
// Conv2 psum accumulation storage: conv2_psum[ch_batch][col_pos][PE]
//   - Reset at hard rst or L2_RST
//   - Save PE output at L2_ACC (after each in_ch group execution)
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
  if (rst) begin
    for (i = 0; i < 4; i = i + 1)
      for (j = 0; j < 13; j = j + 1)
        for (k = 0; k < 8; k = k + 1)
          conv2_psum[i][j][k] <= 32'sd0;
  end
  else if (state == L2_RST) begin
    // Clear all Conv2 partial sums at start of L2 phase
    for (i = 0; i < 4; i = i + 1)
      for (j = 0; j < 13; j = j + 1)
        for (k = 0; k < 8; k = k + 1)
          conv2_psum[i][j][k] <= 32'sd0;
  end
  else if (state == L2_ACC) begin
    // Store PE output into conv2_psum at current (ch_batch, col_pos)
    for (k = 0; k < 8; k = k + 1)
      conv2_psum[ch_batch][col_pos][k] <= $signed(pe_out[k]);
  end
end

// ---------------------------------------------------------------------------
// Conv2 quantized output capture: conv2_out[col_pos*32 + ch_batch*8 + PE]
//   Layout: 13 columns x (4 batches x 8 PEs) = 13 x 32 = 416 values
//   Captured at L2_ACC when in_ch==15 (final accumulation for this group done)
//   Lower 8 bits of pe_out = quantized activation
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
  if (rst) begin
    for (i = 0; i < 416; i = i + 1)
      conv2_out[i] <= 8'd0;
  end
  else if (state == L2_ACC && in_ch == 4'd15) begin
    // Address: col_pos * 32 + ch_batch * 8 + PE_index
    for (k = 0; k < 8; k = k + 1)
      conv2_out[col_pos * 32 + ch_batch * 8 + k] <= pe_out[k][7:0];
  end
end

// ---------------------------------------------------------------------------
// Dense1 output accumulation: dense1_psum[batch][PE]
//   - Reset all at rst or L3_RST
//   - Capture final accumulated PE output at L3_OUT for current ch_batch
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
  if (rst) begin
    for (i = 0; i < 6; i = i + 1)
      for (j = 0; j < 8; j = j + 1)
        dense1_psum[i][j] <= 32'sd0;
  end
  else if (state == L3_RST) begin
    // Clear Dense1 output array at start of L3 phase
    for (i = 0; i < 6; i = i + 1)
      for (j = 0; j < 8; j = j + 1)
        dense1_psum[i][j] <= 32'sd0;
  end
  else if (state == L3_OUT) begin
    // Capture fully-accumulated Dense1 result for this batch (ch_batch index)
    for (j = 0; j < 8; j = j + 1)
      dense1_psum[ch_batch][j] <= $signed(pe_out[j]);
  end
end

// ---------------------------------------------------------------------------
// Dense2 partial sums: dense2_psum[0..1]
//   - Reset at rst or L4_RST
//   - Accumulate at L4_ACC (2-neuron running sum saved across groups)
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
  if (rst) begin
    dense2_psum[0] <= 32'sd0;
    dense2_psum[1] <= 32'sd0;
  end
  else if (state == L4_RST) begin
    dense2_psum[0] <= 32'sd0;
    dense2_psum[1] <= 32'sd0;
  end
  else if (state == L4_ACC) begin
    dense2_psum[0] <= $signed(pe_out[0]);
    dense2_psum[1] <= $signed(pe_out[1]);
  end
end

// ---------------------------------------------------------------------------
// Final result: compare Dense2 neurons to determine class
//   Class 0: neuron0 >= neuron1
//   Class 1: neuron1 > neuron0
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
  if (rst) begin
    result_r <= 8'd0;
  end
  else if (state == L4_OUT) begin
    result_r <= ($signed(dense2_psum[0]) >= $signed(dense2_psum[1])) ? 8'd0 : 8'd1;
  end
end

endmodule
