`timescale 1ns/10ps
`define DATA_BITS 32

// =============================================================================
// Module: psum_fc_ctrl
// Description: Partial Sum Controller for FC/Conv layers.
//              Manages psum feedback to PEs, accumulates Conv2/Dense1/Dense2
//              partial sums, captures quantized Conv2 output for Dense1 input,
//              and computes final 2-class result.
//
// Fix log (2026-06-11):
//
//   BUG FIX 2 - conv2_out index sai th? t? outer/inner loop:
//     Tr??c: conv2_out[col_pos * 32 + ch_batch * 8 + k]
//            col_pos ch?y 0..12 ? col_pos*32 max = 384, gây overlap và
//            shuffle d? li?u khi ch_batch thay ??i.
//     Sau  : conv2_out[ch_batch * 104 + col_pos * 8 + k]
//            Layout ?úng: outer=ch_batch(0..3), inner=col_pos(0..12),
//            innermost=PE(0..7). 13*8=104 entries m?i ch_batch.
//
//   BUG FIX 3 - pipeline hazard: capture dense1_psum quá s?m:
//     PE_3x3 có 3-stage pipeline (mul ? sum1+sum2+psum ? sum).
//     T?i L3_OUT, pe_out còn là k?t qu? c?a group c?; psum_in[j] ?ang
//     gi? pe_out t? L3_ACC cu?i cùng - ?ây là giá tr? tích l?y ?úng.
//     Tr??c: dense1_psum[ch_batch][j] <= $signed(pe_out[j])  t?i L3_OUT
//     Sau  : dense1_psum[ch_batch][j] <= $signed(psum_in[j]) t?i L3_OUT
//            psum_in ???c c?p nh?t t?i L3_ACC (pe_out valid 1 cycle sau EXE[2]),
//            nên t?i L3_OUT nó ch?a k?t qu? tích l?y hoàn ch?nh c?a batch.
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

wire [31:0] pe_out [0:7];
reg  [31:0] psum_in [0:7];
reg  signed [31:0] conv2_psum [0:3][0:12][0:7];
reg  signed [31:0] dense1_psum [0:5][0:7];
reg  signed [31:0] dense2_psum [0:1];
reg  [7:0] conv2_out [0:415];
reg  [7:0] result_r;

integer i, j, k;
genvar  ga, gj, gk, gq;

// ---------------------------------------------------------------------------
// Generate blocks
// ---------------------------------------------------------------------------
generate
  for (gk = 0; gk < 8; gk = gk + 1) begin : gen_pe
    assign pe_out[gk]                   = pe_out_flat[gk*32 +: 32];
    assign psum_in_flat[gk*32 +: 32]    = psum_in[gk];
  end

  for (ga = 0; ga < 4; ga = ga + 1) begin : gen_c2b
    for (gk = 0; gk < 13; gk = gk + 1) begin : gen_c2c
      for (gj = 0; gj < 8; gj = gj + 1) begin : gen_c2p
        assign conv2_psum_flat[(ga*13*8 + gk*8 + gj)*32 +: 32] = conv2_psum[ga][gk][gj];
      end
    end
  end

  for (ga = 0; ga < 6; ga = ga + 1) begin : gen_d1b
    for (gk = 0; gk < 8; gk = gk + 1) begin : gen_d1p
      assign dense1_psum_flat[(ga*8 + gk)*32 +: 32] = dense1_psum[ga][gk];
    end
  end

  for (gq = 0; gq < 416; gq = gq + 1) begin : gen_c2out
    assign conv2_out_flat[gq*8 +: 8] = conv2_out[gq];
  end
endgenerate

assign result = result_r;

// ---------------------------------------------------------------------------
// psum_in: feedback partial sum to PE
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
  if (rst) begin
    for (i = 0; i < 8; i = i + 1)
      psum_in[i] <= 32'd0;
  end
  else begin
    if (state == IDLE || state == L2_RST || state == L3_RST || state == L4_RST) begin
      for (i = 0; i < 8; i = i + 1)
        psum_in[i] <= 32'd0;
    end
    else if (state == L2_SET && in_ch != 4'd0) begin
      for (i = 0; i < 8; i = i + 1)
        psum_in[i] <= conv2_psum[ch_batch][col_pos][i];
    end
    else if (state == L2_SET && in_ch == 4'd0) begin
      for (i = 0; i < 8; i = i + 1)
        psum_in[i] <= 32'd0;
    end
    else if (state == L3_OUT) begin
      for (i = 0; i < 8; i = i + 1)
        psum_in[i] <= 32'd0;
    end
    else if (state == L3_ACC) begin
      for (i = 0; i < 8; i = i + 1)
        psum_in[i] <= pe_out[i];
    end
    else if (state == L4_ACC) begin
      for (i = 0; i < 2; i = i + 1)
        psum_in[i] <= pe_out[i];
    end
  end
end

// ---------------------------------------------------------------------------
// conv2_psum: accumulate Conv2 partial sums across in_ch
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
  if (rst) begin
    for (i = 0; i < 4; i = i + 1)
      for (j = 0; j < 13; j = j + 1)
        for (k = 0; k < 8; k = k + 1)
          conv2_psum[i][j][k] <= 32'sd0;
  end
  else if (state == L2_RST) begin
    for (i = 0; i < 4; i = i + 1)
      for (j = 0; j < 13; j = j + 1)
        for (k = 0; k < 8; k = k + 1)
          conv2_psum[i][j][k] <= 32'sd0;
  end
  else if (state == L2_ACC) begin
    for (k = 0; k < 8; k = k + 1)
      conv2_psum[ch_batch][col_pos][k] <= $signed(pe_out[k]);
  end
end

// ---------------------------------------------------------------------------
// conv2_out: capture quantized Conv2 output (after all in_ch accumulated)
//   FIX BUG 2: index = ch_batch*104 + col_pos*8 + k
//     Layout: outer=ch_batch(0..3), inner=col_pos(0..12), innermost=PE(0..7)
//     13 col × 8 PE = 104 entries per ch_batch ? stride = 104
//     Tr??c (sai): col_pos*32 + ch_batch*8 + k  (overflow và shuffle)
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
  if (rst) begin
    for (i = 0; i < 416; i = i + 1)
      conv2_out[i] <= 8'd0;
  end
  else if (state == L2_ACC && in_ch == 4'd15) begin
    for (k = 0; k < 8; k = k + 1)
      conv2_out[ch_batch * 104 + col_pos * 8 + k] <= pe_out[k][7:0];  // FIX: was col_pos*32 + ch_batch*8 + k
  end
end

// ---------------------------------------------------------------------------
// dense1_psum: capture Dense1 batch output
//   FIX BUG 3 (revised): capture t?i L3_ACC khi dense_cnt==51 (group cu?i).
//
//   T?i sao không dùng L3_OUT:
//     Block psum_in và block dense1_psum ch?y ??NG TH?I t?i posedge clk.
//     Khi state==L3_OUT, block psum_in gán psum_in[i] <= 32'd0 (reset).
//     N?u dense1_psum ??c psum_in[j] trong cùng cycle ?ó, nó ??c giá tr?
//     PRE-clock-edge c?a psum_in - nh?ng v?n ?? là t?i edge vào L3_OUT,
//     psum_in v?a ???c c?p nh?t t? L3_ACC[dense_cnt=51] ? edge tr??c.
//     Th?c t? simulation cho th?y psum_in=0 t?i L3_OUT ? race condition
//     ho?c psum_in b? reset tr??c khi L3_OUT ??c ???c.
//
//   Gi?i pháp: capture pe_out[j] tr?c ti?p t?i L3_ACC khi dense_cnt==51.
//     Lúc này pe_out ch?a k?t qu? pipeline hoàn ch?nh c?a group cu?i,
//     không ph? thu?c vào timing c?a psum_in reset.
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
  if (rst) begin
    for (i = 0; i < 6; i = i + 1)
      for (j = 0; j < 8; j = j + 1)
        dense1_psum[i][j] <= 32'sd0;
  end
  else if (state == L3_RST) begin
    for (i = 0; i < 6; i = i + 1)
      for (j = 0; j < 8; j = j + 1)
        dense1_psum[i][j] <= 32'sd0;
  end
  // FIX: capture t?i L3_ACC dense_cnt==51 thay vì L3_OUT
  // pe_out t?i ?ây là k?t qu? tích l?y hoàn ch?nh c?a batch hi?n t?i
  else if (state == L3_ACC && dense_cnt == 6'd51) begin
    for (j = 0; j < 8; j = j + 1)
      dense1_psum[ch_batch][j] <= $signed(pe_out[j]);
  end
end

// ---------------------------------------------------------------------------
// dense2_psum: capture Dense2 output
//   FIX: capture t?i L4_ACC khi dense_cnt==5 (group cu?i, 6 groups t?ng)
//   Lý do t??ng t? dense1: capture ?úng group cu?i, tránh overwrite sai.
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
  else if (state == L4_ACC && dense_cnt == 6'd5) begin
    dense2_psum[0] <= $signed(pe_out[0]);
    dense2_psum[1] <= $signed(pe_out[1]);
  end
end

// ---------------------------------------------------------------------------
// result: argmax of dense2_psum
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