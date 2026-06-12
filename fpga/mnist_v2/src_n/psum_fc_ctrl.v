`timescale 1ns/10ps
`define DATA_BITS 32
module psum_fc_ctrl(
  input clk,
  input rst,
  input [5:0] state,
  input [2:0] layer,
  input [5:0] counter,
  input [3:0] channel_cnt,

  input [255:0] pe_out_flat,

  output [255:0] psum_in_flat,
  output [25599:0] psum_temp_flat,
  output reg [6:0] psum_temp_indx,
  output [7:0] result
);

  parameter IDLE           = 0,
            L2_READ_TILE2  = 24,
            L2_READ_TILE5  = 25,
            L2_READ_TILE6  = 26,
            L2_EXE         = 27,
            L3_RST         = 30,
            L3_RD_BRTCH1   = 31,
            L3_RD_BRTCH3   = 33,
            L3_EXE         = 34,
            L3_DONE        = 35,
            L4_RST         = 36,
            L4_SUM         = 39,
            L4_OUT         = 40,
            L5_RST         = 41,
            L5_SUM         = 45,
            L5_OUT         = 46;

  wire [31:0] pe_out [0:7];
  reg [31:0] psum_temp [0:799]; // 10 * 10 * 8
  reg [31:0] psum_in [0:7];
  reg [7:0] psum_in_indx;
  reg signed [31:0] pe_out_sum_a;
  reg signed [31:0] pe_out_sum_b;
  wire [31:0] pe_out_sum_a_relu;
  wire [31:0] pe_out_sum_b_relu;
  wire [31:0] pe_out_sum_a_quan;

  reg [7:0] soft_max_indx;
  reg [31:0] soft_max_temp;

  integer i, j;
  genvar k, a;

  generate
    for (k=0; k<8; k=k+1) begin : unflat_pe_out
      assign pe_out[k] = pe_out_flat[k*32+31 : k*32];
    end
    for (a=0; a<8; a=a+1) begin : flat_psum
      assign psum_in_flat[a*32+31 : a*32] = psum_in[a];
      for (k=0; k<100; k=k+1) begin : flat_psum_temp
        assign psum_temp_flat[(a*100+k)*32+31 : (a*100+k)*32] = psum_temp[a*100+k];
      end
    end
  endgenerate

  assign result = soft_max_indx;

  // ============================================== psum control =========================================================================================
  // ============================= pipeline X
  always @(posedge clk or posedge rst) begin
    if(rst) for(i = 0; i < 8; i=i+1) psum_in[i] <= 0;
    else begin 
      if(state == IDLE || layer == 1 || layer == 4 || layer == 5 || state == L3_RST) for(i = 0; i < 8; i=i+1) psum_in[i] <= 0;
      else if(state == L2_READ_TILE2 || state == L2_READ_TILE5 || state == L2_READ_TILE6 || (state == L2_EXE && counter == 0)) for(i = 0; i < 8; i=i+1) psum_in[i] <= psum_temp[i*100+psum_in_indx];
      else if(state == L3_EXE && counter == 0 && channel_cnt != 0) for(i = 0; i < 8; i=i+1) psum_in[i] <= psum_temp[i*100+psum_in_indx];
    end
  end
/*
 1 2  =>  1 2 5 6
 5 6 
*/
  always @(posedge clk or posedge rst) begin
    if(rst) psum_in_indx <= 0;
    else begin
      if(state == IDLE) psum_in_indx <= 0;
      else if(state == L2_READ_TILE2 || state == L2_READ_TILE5 || state == L2_READ_TILE6 || (state == L2_EXE && counter == 0)) begin // delay 1 cycle
        if(psum_in_indx == 99) psum_in_indx <= 0;
        else psum_in_indx <= psum_in_indx + 1;
      end
      else if(state == L3_EXE && counter == 0 && channel_cnt != 0) begin
        if(psum_in_indx == 14) psum_in_indx <= 0;
        else psum_in_indx <= psum_in_indx + 1;
      end
    end
  end
  // ============================= pipeline X
  // psum_temp
  // ============================= pipeline O
  always @(posedge clk or posedge rst) begin
    if(rst) psum_temp_indx <= 0;
    else begin
      if(state == L2_EXE) begin
        if(psum_temp_indx == 99) psum_temp_indx <= 0;
        else psum_temp_indx <= psum_temp_indx + 1;
      end
      else if(state == IDLE || state == L3_RST || state == L5_RST) psum_temp_indx <= 0;
      else if(counter == 0 && ((state == L3_RD_BRTCH1 && channel_cnt != 0) || state == L3_RD_BRTCH3)) begin
        if(psum_temp_indx == 14) psum_temp_indx <= 0;
        else psum_temp_indx <= psum_temp_indx + 1;
      end
      else if(state == L4_RST) psum_temp_indx <= 16;
      else if(state == L4_OUT) psum_temp_indx <= psum_temp_indx + 1;
      else if(state == L5_OUT) psum_temp_indx <= psum_temp_indx + 2;
    end
  end

  always @(posedge clk or posedge rst) begin
    if(rst) begin
      for(i = 0; i < 8; i=i+1) begin
        for(j = 0; j < 100; j=j+1)
          psum_temp[i*100+j] <= 0;
      end
    end
    else begin
      if(state == L3_RST || state == IDLE) begin
        for(i = 0; i < 8; i=i+1) begin
          for(j = 0; j < 100; j=j+1)
            psum_temp[i*100+j] <= 0;
        end
      end
      else if(state == L2_EXE || (counter == 0 && ((state == L3_RD_BRTCH1 && channel_cnt != 0) || state == L3_RD_BRTCH3)) || state == L3_DONE) 
        for(i = 0; i < 8; i=i+1) psum_temp[i*100+psum_temp_indx] <= pe_out[i];
      else if(state == L4_OUT) psum_temp[psum_temp_indx] <= pe_out_sum_a_quan;
      else if(state == L5_OUT) begin
        psum_temp[100+psum_temp_indx] <= pe_out_sum_a_relu;
        psum_temp[100+psum_temp_indx+1] <= pe_out_sum_b_relu;
      end
    end
  end
  // ============================= pipeline O
  // =====================================================================================================================================================

  // ============================= fc1/fc2 sum, relu and quantize ======================================================================
  always @(posedge clk or posedge rst) begin
    if(rst) pe_out_sum_a <= 0;
    else begin
      if(state == L4_SUM) pe_out_sum_a <= (pe_out[0] + pe_out[1]) + (pe_out[2] + pe_out[3] + pe_out[4]);
      else if(state == L5_SUM) pe_out_sum_a <= (pe_out[0] + pe_out[1]) + (pe_out[2] + pe_out[3]);
    end
  end

  always @(posedge clk or posedge rst) begin
    if(rst) pe_out_sum_b <= 0;
    else begin
      if(state == L5_SUM) pe_out_sum_b <= (pe_out[4] + pe_out[5]) + (pe_out[6] + pe_out[7]);
    end
  end
  assign pe_out_sum_a_relu = (pe_out_sum_a < 0) ? 0 : pe_out_sum_a;
  assign pe_out_sum_b_relu = (pe_out_sum_b < 0) ? 0 : pe_out_sum_b;

  assign pe_out_sum_a_quan = ((|pe_out_sum_a_relu[31:15]) ? 255 : ((&pe_out_sum_a_relu[14:7]) ? pe_out_sum_a_relu[14:7] : (pe_out_sum_a_relu[14:7] + pe_out_sum_a_relu[6])));                     
  // ===================================================================================================================================================================
  
  // ===================================================== softmax ====================================================================================
  always @(posedge clk or posedge rst) begin
    if(rst) soft_max_indx <= 0;
    else begin
      if(state == L5_OUT) begin
        if(psum_temp_indx == 46) soft_max_indx <= (soft_max_temp > pe_out_sum_a_relu) ? soft_max_indx : psum_temp_indx;
        else soft_max_indx <= (soft_max_temp > pe_out_sum_a_relu) ? ((soft_max_temp > pe_out_sum_b_relu) ? soft_max_indx : psum_temp_indx + 1)
                                                                  : ((pe_out_sum_a_relu > pe_out_sum_b_relu) ? psum_temp_indx : psum_temp_indx + 1);
      end
    end
  end

  always @(posedge clk or posedge rst) begin
    if(rst) soft_max_temp <= 0;
    else begin
      if(state == IDLE) soft_max_temp <= 0;
      else if(state == L5_OUT) begin
        if(psum_temp_indx == 46) soft_max_temp <= (soft_max_temp > pe_out_sum_a_relu) ? soft_max_temp : pe_out_sum_a_relu;
        else soft_max_temp <= (soft_max_temp > pe_out_sum_a_relu) ? ((soft_max_temp > pe_out_sum_b_relu) ? soft_max_temp : pe_out_sum_b_relu)
                                                                  : ((pe_out_sum_a_relu > pe_out_sum_b_relu) ? pe_out_sum_a_relu : pe_out_sum_b_relu);
      end
    end
  end
  // ==========================================================================================================================================================

endmodule
