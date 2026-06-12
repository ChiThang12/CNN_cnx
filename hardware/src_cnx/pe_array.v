// =============================================================================
// File      : pe_array.v
// Project   : MNIST CNN Accelerator
// Author    : FPGA Engineer
// Created   : 2026-06-11
// Description:
//   PE Array wrapper. Instantiates 8 PE_3x3 processing elements.
//   Handles input routing for:
//     - L1 (Conv1): 3x3 sliding window from i_cache (3x32 layout)
//     - L2 (Conv2): 3x3 patch from i_cache (3x15 layout)
//     - L3 (Dense1): 8 activations from conv2_psum_flat
//     - L4 (Dense2): 8 activations from dense1_psum_flat
//   All 8 PEs receive the same 9-input patch; weight differentiation
//   is achieved by assigning distinct weight rows from w_cache.
// =============================================================================

`timescale 1ns/10ps
`define DATA_BITS 32

module pe_array(
  input clk, rst,

  // FSM state & layer info
  input [5:0] state,
  input [2:0] layer,
  input [6:0] counter,
  input [4:0] col_pos,      // sliding-window column offset (L1 / L2)
  input [2:0] ch_batch,     // channel batch index
  input [5:0] dense_cnt,    // dense layer neuron group index

  // Flat input/weight caches
  input [767:0]   i_cache_flat,       // 96 x 8-bit  input feature map cache
  input [575:0]   w_cache_flat,       // 72 x 8-bit  weight cache (8 PEs x 9 weights)

  // Activation / quantisation controls
  input relu_en, quan_en,

  // Partial-sum inputs (8 x 32-bit)
  input [255:0]    psum_in_flat,

  // Conv2 partial sums: 4*13*8*32 = 13312 bits
  input [13311:0]  conv2_psum_flat,

  // Dense1 partial sums: 6*8*32 = 1536 bits
  input [1535:0]   dense1_psum_flat,

  // PE outputs (8 x 32-bit)
  output [255:0]  pe_out_flat
);

  // ---------------------------------------------------------------------------
  // State parameter definitions (shared across project)
  // ---------------------------------------------------------------------------
  parameter IDLE      = 6'd0;
  parameter L1_RST    = 6'd1;
  parameter L1_RD_IFMP= 6'd2;
  parameter L1_RD_W   = 6'd3;
  parameter L1_SET_COL= 6'd4;
  parameter L1_EXE    = 6'd5;
  parameter L1_MXPL   = 6'd6;
  parameter L1_WRITE  = 6'd7;

  parameter L2_RST    = 6'd8;
  parameter L2_RD_IFMP= 6'd9;
  parameter L2_RD_W   = 6'd10;
  parameter L2_SET    = 6'd11;
  parameter L2_EXE    = 6'd12;
  parameter L2_ACC    = 6'd13;
  parameter L2_WRITE  = 6'd14;

  parameter L3_RST    = 6'd15;
  parameter L3_RD     = 6'd16;
  parameter L3_EXE    = 6'd17;
  parameter L3_ACC    = 6'd18;
  parameter L3_OUT    = 6'd19;

  parameter L4_RST    = 6'd20;
  parameter L4_RD     = 6'd21;
  parameter L4_EXE    = 6'd22;
  parameter L4_ACC    = 6'd23;
  parameter L4_OUT    = 6'd24;
  parameter DONE      = 6'd25;

  // ---------------------------------------------------------------------------
  // Unpack flat inputs into arrays
  // ---------------------------------------------------------------------------
  wire [7:0] i_cache [0:95];
  wire [7:0] w_cache [0:71];
  wire [31:0] psum_in [0:7];
  wire [31:0] pe_out  [0:7];

  genvar k, a;
  generate
    for(k = 0; k < 96; k = k + 1)
      assign i_cache[k] = i_cache_flat[k*8 +: 8];

    for(k = 0; k < 72; k = k + 1)
      assign w_cache[k] = w_cache_flat[k*8 +: 8];

    for(a = 0; a < 8; a = a + 1) begin : psum_unpack
      assign psum_in[a]               = psum_in_flat[a*32 +: 32];
      assign pe_out_flat[a*32 +: 32]  = pe_out[a];
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // pe_pre_in: 9-element input patch registered each cycle
  // ---------------------------------------------------------------------------
  reg [7:0] pe_pre_in [0:8];
  integer i, j;

  always @(posedge clk or posedge rst) begin
    if(rst) begin
      for(i = 0; i < 9; i = i + 1)
        pe_pre_in[i] <= 8'd0;
    end
    else begin
      // ------------------------------------------------------------------
      // L1 (Conv1): 3x32 layout in i_cache.
      //   pe_pre_in[r*3+c] = i_cache[r*32 + col_pos + c], r=0..2, c=0..2
      // ------------------------------------------------------------------
      if(state == L1_SET_COL) begin
        pe_pre_in[0] <= i_cache[col_pos + 5'd0];
        pe_pre_in[1] <= i_cache[col_pos + 5'd1];
        pe_pre_in[2] <= i_cache[col_pos + 5'd2];
        pe_pre_in[3] <= i_cache[7'd32 + col_pos + 5'd0];
        pe_pre_in[4] <= i_cache[7'd32 + col_pos + 5'd1];
        pe_pre_in[5] <= i_cache[7'd32 + col_pos + 5'd2];
        pe_pre_in[6] <= i_cache[7'd64 + col_pos + 5'd0];
        pe_pre_in[7] <= i_cache[7'd64 + col_pos + 5'd1];
        pe_pre_in[8] <= i_cache[7'd64 + col_pos + 5'd2];
      end

      // ------------------------------------------------------------------
      // L2 (Conv2): 3x15 layout in i_cache.
      //   3x3 patch at col_pos: row offsets 0, 15, 30
      // ------------------------------------------------------------------
      else if(state == L2_SET) begin
        pe_pre_in[0] <= i_cache[col_pos + 5'd0];
        pe_pre_in[1] <= i_cache[col_pos + 5'd1];
        pe_pre_in[2] <= i_cache[col_pos + 5'd2];
        pe_pre_in[3] <= i_cache[7'd15 + col_pos + 5'd0];
        pe_pre_in[4] <= i_cache[7'd15 + col_pos + 5'd1];
        pe_pre_in[5] <= i_cache[7'd15 + col_pos + 5'd2];
        pe_pre_in[6] <= i_cache[7'd30 + col_pos + 5'd0];
        pe_pre_in[7] <= i_cache[7'd30 + col_pos + 5'd1];
        pe_pre_in[8] <= i_cache[7'd30 + col_pos + 5'd2];
      end

      // ------------------------------------------------------------------
      // L3 (Dense1): Read 8 activations from conv2_psum_flat.
      //   conv2_psum_flat: 4*13*8*32 = 13312 bits
      //   Group index: dense_cnt (0..51, 52 groups of 8 activations)
      //   Each 32-bit entry holds one Conv2 output; lower 8 bits used.
      //   Offset per group = dense_cnt * 8 entries * 32 bits = dense_cnt*256
      // ------------------------------------------------------------------
      else if(state == L3_RD && counter == 7'd1) begin
        for(j = 0; j < 8; j = j + 1)
          pe_pre_in[j] <= conv2_psum_flat[dense_cnt*256 + j*32 +: 8];
        pe_pre_in[8] <= 8'd0;
      end

      // ------------------------------------------------------------------
      // L4 (Dense2): Read 8 activations from dense1_psum_flat.
      //   dense1_psum_flat: 6*8*32 = 1536 bits
      //   Group index: dense_cnt (0..5, 6 groups of 8 activations)
      //   Lower 8 bits of each 32-bit entry used as activation.
      // ------------------------------------------------------------------
      else if(state == L4_RD && counter == 7'd3) begin
        for(j = 0; j < 8; j = j + 1)
          pe_pre_in[j] <= dense1_psum_flat[dense_cnt*256 + j*32 +: 8];
        pe_pre_in[8] <= 8'd0;
      end

    end // else rst
  end // always

  // ---------------------------------------------------------------------------
  // pe_in replication: broadcast pe_pre_in to all 8 PEs
  // Each PE slot occupies 9 consecutive entries in pe_in[].
  // ---------------------------------------------------------------------------
  reg [7:0] pe_in [0:71]; // 8 PEs x 9 inputs

  always @(*) begin
    for(j = 0; j < 8; j = j + 1)
      for(i = 0; i < 9; i = i + 1)
        pe_in[j*9 + i] = pe_pre_in[i];
  end

  // ---------------------------------------------------------------------------
  // PE instantiation: 8 x PE_3x3
  // Each PE receives the same input patch but its own row of weights.
  // ---------------------------------------------------------------------------
  generate
    for(a = 0; a < 8; a = a + 1) begin : pe_arrays
      PE_3x3 PE (
        .clk     (clk),
        .rst     (rst),
        .relu_en (relu_en),
        .quan_en (quan_en),
        .psum    (psum_in[a]),
        .pe_out  (pe_out[a]),
        // Input feature map patch (same for all PEs)
        .in_IF1  (pe_in[a*9 + 0]),
        .in_IF2  (pe_in[a*9 + 1]),
        .in_IF3  (pe_in[a*9 + 2]),
        .in_IF4  (pe_in[a*9 + 3]),
        .in_IF5  (pe_in[a*9 + 4]),
        .in_IF6  (pe_in[a*9 + 5]),
        .in_IF7  (pe_in[a*9 + 6]),
        .in_IF8  (pe_in[a*9 + 7]),
        .in_IF9  (pe_in[a*9 + 8]),
        // Weights: each PE has its own 9-weight row from w_cache
        .in_W1   (w_cache[a*9 + 0]),
        .in_W2   (w_cache[a*9 + 1]),
        .in_W3   (w_cache[a*9 + 2]),
        .in_W4   (w_cache[a*9 + 3]),
        .in_W5   (w_cache[a*9 + 4]),
        .in_W6   (w_cache[a*9 + 5]),
        .in_W7   (w_cache[a*9 + 6]),
        .in_W8   (w_cache[a*9 + 7]),
        .in_W9   (w_cache[a*9 + 8])
      );
    end
  endgenerate

endmodule
