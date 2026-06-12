`timescale 1ns/10ps
// ============================================================
// Module: PE_3x3
// Description: 3x3 convolution Processing Element
//   - 3-stage pipeline: multiply -> partial sum -> final sum
//   - Optional ReLU activation
//   - Optional 8-bit quantization (output clipped to [0,255])
// ============================================================
module PE_3x3(
  input rst, clk,
  input relu_en, quan_en,
  output [31:0] pe_out,
  input  [31:0] psum,
  input  [7:0] in_IF1, in_IF2, in_IF3,
  input  [7:0] in_IF4, in_IF5, in_IF6,
  input  [7:0] in_IF7, in_IF8, in_IF9,
  input  signed [7:0] in_W1, in_W2, in_W3,
  input  signed [7:0] in_W4, in_W5, in_W6,
  input  signed [7:0] in_W7, in_W8, in_W9
);
  integer i;
  wire [31:0] relu_out;
  reg signed [31:0] sum1, sum2, sum;
  reg signed [31:0] mul [0:8];

  // Stage 1: Multiply (unsigned input * signed weight)
  always @(posedge clk or posedge rst) begin
    if(rst) for(i=0;i<9;i=i+1) mul[i] <= 0;
    else begin
      mul[0] <= $signed({1'b0,in_IF1}) * in_W1;
      mul[1] <= $signed({1'b0,in_IF2}) * in_W2;
      mul[2] <= $signed({1'b0,in_IF3}) * in_W3;
      mul[3] <= $signed({1'b0,in_IF4}) * in_W4;
      mul[4] <= $signed({1'b0,in_IF5}) * in_W5;
      mul[5] <= $signed({1'b0,in_IF6}) * in_W6;
      mul[6] <= $signed({1'b0,in_IF7}) * in_W7;
      mul[7] <= $signed({1'b0,in_IF8}) * in_W8;
      mul[8] <= $signed({1'b0,in_IF9}) * in_W9;
    end
  end

  // Stage 2: Partial sum (split into two groups) + accumulate psum
  always @(posedge clk or posedge rst) begin
    if(rst) begin sum1<=0; sum2<=0; end
    else begin
      sum1 <= mul[0]+mul[1]+mul[2]+mul[3]+mul[4];
      sum2 <= mul[5]+mul[6]+mul[7]+mul[8]+psum;
    end
  end

  // Stage 3: Final sum
  always @(posedge clk or posedge rst) begin
    if(rst) sum <= 0;
    else sum <= sum1 + sum2;
  end

  // ReLU: clamp negative values to 0
  assign relu_out = relu_en ? ((sum < 0) ? 0 : sum) : sum;

  // Quantization: scale bits[14:7] -> 8-bit output [0,255]
  //   If any upper bit [31:15] is set -> saturate to 255
  //   Else take bits [14:7] and round up if bit[6]=1
  assign pe_out = quan_en ?
                 (|(relu_out[31:15]) ? 32'd255 :
                 ((&relu_out[14:7])  ? {24'b0, relu_out[14:7]} :
                 ({24'b0, relu_out[14:7]} + relu_out[6]))) :
                 relu_out;
endmodule
