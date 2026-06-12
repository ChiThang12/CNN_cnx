`timescale 1ns/10ps
`define DATA_BITS 32
module addr_gen(
  input clk,
  input rst,
  input [5:0] state,
  input [5:0] n_state,
  input [2:0] layer,
  input [5:0] counter,
  input [2:0] cnt_rd_new,
  input [3:0] channel_cnt,
  input [6:0] psum_temp_indx,

  output reg [`DATA_BITS-1:0] BRAM_IF1_ADDR,
  output reg [`DATA_BITS-1:0] BRAM_IF2_ADDR,
  output [`DATA_BITS-1:0] BRAM_W1_ADDR,
  output [`DATA_BITS-1:0] BRAM_W2_ADDR,
  output [`DATA_BITS-1:0] BRAM_W3_ADDR,
  output [`DATA_BITS-1:0] BRAM_W4_ADDR,
  output [`DATA_BITS-1:0] BRAM_W5_ADDR,

  output [3:0] BRAM_IF1_WE,
  output [3:0] BRAM_IF2_WE,
  output [3:0] BRAM_W1_WE,
  output [3:0] BRAM_W2_WE,
  output [3:0] BRAM_W3_WE,
  output [3:0] BRAM_W4_WE,
  output [3:0] BRAM_W5_WE,

  output BRAM_IF1_EN,
  output BRAM_IF2_EN,
  output BRAM_W1_EN,
  output BRAM_W2_EN,
  output BRAM_W3_EN,
  output BRAM_W4_EN,
  output BRAM_W5_EN,

  output reg [`DATA_BITS-1:0] BRAM_IF2_ADDR_temp,
  output reg [`DATA_BITS-1:0] L2_BRAM_IF1_ADDR_temp,
  output reg [4:0] bits_select
);

  // States copied for reference (used directly via integer values or just let compiler handle if we `include, but better to define them if used in this file directly, wait, we use state == ... so we need the parameters)
  // We can copy parameters from cnn_fsm here, or since we only use specific states, we need the parameters.
  // Actually, we need to redefine state parameters or define them in a common header.
  // To keep it simple and standalone, let's redefine the state parameters used in addr_gen.
  parameter IDLE           = 0,
            L1_RD_BRTCH1   = 1,    // read bram to cache (12 cycle)
            L1_RD_BRTCH2   = 2,
            L1_RD_BRTCH3   = 3,
            L1_READ24      = 4,
            L1_READ_TILE1  = 5,
            L1_WRITE_TEMP  = 17,
            L2_RST         = 18,
            L2_RD_BRTCH1   = 19,
            L2_RD_BRTCH2   = 20,
            L2_RD_BRTCH3   = 21,
            L2_READ12      = 22,
            L2_READ_TILE1  = 23,
            L2_WRITE_TEMP  = 29,
            L3_RD_BRTCH1   = 31,
            L3_RD_BRTCH2   = 32,
            L3_RD_BRTCH3   = 33,
            L4_RD_BRTCH1   = 37,
            L5_RD_BRTCH1   = 42,
            L5_RD_BRTCH2   = 43;

  reg  [`DATA_BITS-1:0] BRAM_W1_ADDR_temp;
  reg  [`DATA_BITS-1:0] BRAM_W2_ADDR_temp, BRAM_W3_ADDR_temp, BRAM_W4_ADDR_temp, BRAM_W5_ADDR_temp;

  wire [`DATA_BITS-1:0] L1_BRAM_IF1_ADDR_temp, L3_BRAM_IF1_ADDR_temp;
  wire [`DATA_BITS-1:0] L2_bram_IF2_addr;

  reg [2:0] x, y; // 8 * 8
  reg [3:0] base_addr_r; 
  reg [7:0] base_addr_c;

  wire [7:0] L2_ifmp_indx; 
  wire [4:0] L3_ifmp_indx; 

  reg [1:0] bits_select_temp;

  // =========================== address calculate begin =============================================================================
  always @(*) begin // for conv1/conv3 input & conv2 output
    if(layer == 1) BRAM_IF1_ADDR = L1_BRAM_IF1_ADDR_temp << 2;      // input addr
    else if(layer == 2) BRAM_IF1_ADDR = L2_BRAM_IF1_ADDR_temp << 2; // output addr
    else if(layer == 3) BRAM_IF1_ADDR = {(L3_BRAM_IF1_ADDR_temp >> 2), 2'b0}; // input addr
    else BRAM_IF1_ADDR = 0;
  end

  assign BRAM_W1_ADDR = BRAM_W1_ADDR_temp << 2;
  assign BRAM_W2_ADDR = BRAM_W2_ADDR_temp << 2;
  assign BRAM_W3_ADDR = BRAM_W3_ADDR_temp << 2;
  assign BRAM_W4_ADDR = BRAM_W4_ADDR_temp << 2;
  assign BRAM_W5_ADDR = BRAM_W5_ADDR_temp << 2;

  always @(*) begin
    if(layer == 1) BRAM_IF2_ADDR = BRAM_IF2_ADDR_temp << 2;
    else if(layer == 2) BRAM_IF2_ADDR = {(L2_bram_IF2_addr >> 2), 2'b0}; // * 4 / 4
    else BRAM_IF2_ADDR = 0;
  end

  assign L1_BRAM_IF1_ADDR_temp = base_addr_r + base_addr_c + {y, x}; // IF1: for conv1/conv3/fc2 input
  assign L3_BRAM_IF1_ADDR_temp = (L3_ifmp_indx << 4) + channel_cnt;  // # of pixel in this channel - 1 : L3_ifmp_indx;
  assign L3_ifmp_indx = counter;
  assign L2_ifmp_indx = (base_addr_r + base_addr_c) + ((y << 3) + (y << 2)) + ((y << 1) + x); // 14y + x
  assign L2_bram_IF2_addr = (L2_ifmp_indx << 2) + (L2_ifmp_indx << 1) + channel_cnt; // # of pixel in this channel - 1 : L2_ifmp_indx;

  // BRAM_IF2_ADDR (Get data READY in mxpl state) // IF2: for conv2/fc1 input
  always @(posedge clk or posedge rst) begin
    if(rst) BRAM_IF2_ADDR_temp <= 0;
    else begin
      if(state == IDLE) BRAM_IF2_ADDR_temp <= 0;
      else if(state == L1_WRITE_TEMP) BRAM_IF2_ADDR_temp <= BRAM_IF2_ADDR_temp + 1;
    end
  end

  // BRAM_IF1_ADDR
  // x
  always @(posedge clk or posedge rst) begin
    if(rst) x <= 0;
    else begin
      if(state == L1_RD_BRTCH1 || state == L1_RD_BRTCH3 || state == L2_READ12) begin
        if(x == 1) x <= 0;
        else x <= x + 1;
      end
      else if(state == L1_READ_TILE1 || state == L2_READ_TILE1 || state == IDLE) x <= 0;
      else if(state == L2_RD_BRTCH1 || state == L2_RD_BRTCH3) begin
        if(x == 5) x <= 0;
        else x <= x + 1;
      end
    end
  end

  //y
  always @(posedge clk or posedge rst) begin
    if(rst) y <= 0;
    else begin
      if(((state == L1_RD_BRTCH1 || state == L1_RD_BRTCH3) && x == 1) || state == L1_READ24 || (state == L2_READ12 && x == 1) || ((state == L2_RD_BRTCH1 || state == L2_RD_BRTCH3) && x == 5)) 
        y <= y + 1;
      else if(state == L1_READ_TILE1 || state == L2_READ_TILE1 || state == IDLE) y <= 0;
    end
  end

  always @(posedge clk or posedge rst) begin
    if(rst) base_addr_r <= 0;
    else begin
      if(state == L1_READ_TILE1) base_addr_r <= base_addr_r + 1;
      else if(n_state == L1_READ24 && cnt_rd_new == 0) base_addr_r <= 2; // L1_READ24 first time
      else if(state == L1_RD_BRTCH1 || state == L1_RD_BRTCH3 || state == L2_RST || base_addr_r == 14 || state == IDLE) base_addr_r <= 0; 
      else if(state == L2_READ_TILE1) base_addr_r <= base_addr_r + 2;
      else if(n_state == L2_READ12 && cnt_rd_new == 0) base_addr_r <= 6;
    end
  end

  always @(posedge clk or posedge rst) begin
    if(rst) base_addr_c <= 0;
    else begin
      if(state == L1_READ24 && cnt_rd_new == 6 && counter == 5) base_addr_c <= base_addr_c + 16;
      else if(state == L2_RST || base_addr_c == 140 || state == IDLE) base_addr_c <= 0; 
      else if(state == L2_READ12 && cnt_rd_new == 4 && counter == 11) base_addr_c <= base_addr_c + 28;
    end
  end

  // BRAM_W1_ADDR
  always @(posedge clk or posedge rst) begin
    if(rst) BRAM_W1_ADDR_temp <= 0;
    else begin
      if(state == IDLE) BRAM_W1_ADDR_temp <= 0;
      else if(state == L1_RD_BRTCH1 || state == L1_RD_BRTCH2) BRAM_W1_ADDR_temp <= BRAM_W1_ADDR_temp + 1;
    end
  end
  
  // BRAM_W2_ADDR 
  always @(posedge clk or posedge rst) begin
    if(rst) BRAM_W2_ADDR_temp <= 0;
    else begin
      if(state == IDLE) BRAM_W2_ADDR_temp <= 0;
      else if(state == L2_RD_BRTCH2 && counter == 13) BRAM_W2_ADDR_temp <= BRAM_W2_ADDR_temp + 50; 
      else if(state == L2_RD_BRTCH1 || state == L2_RD_BRTCH2) BRAM_W2_ADDR_temp <= BRAM_W2_ADDR_temp + 1;
      else if(state == L2_WRITE_TEMP && n_state == L2_RD_BRTCH1) BRAM_W2_ADDR_temp <= 50;
    end
  end

  always @(posedge clk or posedge rst) begin
    if(rst) BRAM_W3_ADDR_temp <= 0;
    else begin
      if(state == IDLE) BRAM_W3_ADDR_temp <= 0;
      else if(state == L3_RD_BRTCH1 || (state == L3_RD_BRTCH2 && counter <= 23) || (state == L3_RD_BRTCH3 && counter <= 49)) BRAM_W3_ADDR_temp <= BRAM_W3_ADDR_temp + 1;
    end
  end

  always @(posedge clk or posedge rst) begin
    if(rst) BRAM_W4_ADDR_temp <= 0;
    else begin
      if(state == IDLE) BRAM_W4_ADDR_temp <= 0;
      else if(state == L4_RD_BRTCH1 && counter <= 29) BRAM_W4_ADDR_temp <= BRAM_W4_ADDR_temp + 1;
    end
  end

  always @(posedge clk or posedge rst) begin
    if(rst) BRAM_W5_ADDR_temp <= 0;
    else begin
      if(state == IDLE) BRAM_W5_ADDR_temp <= 0;
      else if((state == L5_RD_BRTCH1 || state == L5_RD_BRTCH2) && counter <= 20) BRAM_W5_ADDR_temp <= BRAM_W5_ADDR_temp + 1;
    end
  end  

  always @(posedge clk or posedge rst) begin
    if(rst) L2_BRAM_IF1_ADDR_temp <= 0;
    else begin
      if(state == IDLE) L2_BRAM_IF1_ADDR_temp <= 0;
      else if(state == L2_WRITE_TEMP) begin
        if(counter == 0) L2_BRAM_IF1_ADDR_temp <= L2_BRAM_IF1_ADDR_temp + 1;
        else begin
          if(psum_temp_indx == 0) L2_BRAM_IF1_ADDR_temp <= 2;
          else L2_BRAM_IF1_ADDR_temp <= L2_BRAM_IF1_ADDR_temp + 3;
        end 
      end
    end
  end

  // Layer1 & Layer2 input bits selection
  always @(posedge clk or posedge rst) begin
    if(rst) bits_select_temp <= 0;
    else begin
      if(layer == 2) bits_select_temp <= L2_bram_IF2_addr[1:0];
      else if(layer == 3) bits_select_temp <= L3_BRAM_IF1_ADDR_temp[1:0];
    end 
  end

  always @(*) begin // bits_select: choosing the 8 bits data we want from bram dout (32 bits)
    case (bits_select_temp[1:0])
      2'b00: bits_select = 31;
      2'b01: bits_select = 23;
      2'b10: bits_select = 15;
      2'b11: bits_select = 7;
      default: bits_select = 0;
    endcase
  end

  assign BRAM_W1_EN  = 1;
  assign BRAM_W2_EN  = 1;
  assign BRAM_W3_EN  = 1;
  assign BRAM_W4_EN  = 1;
  assign BRAM_W5_EN  = 1;
  assign BRAM_IF1_EN = 1;
  assign BRAM_IF2_EN = 1;

  assign BRAM_W1_WE  = 4'b0000;
  assign BRAM_W2_WE  = 4'b0000;
  assign BRAM_W3_WE  = 4'b0000;
  assign BRAM_W4_WE  = 4'b0000;
  assign BRAM_W5_WE  = 4'b0000;
  assign BRAM_IF1_WE = (state == L2_WRITE_TEMP) ? 4'b1111 : 4'b0000;
  assign BRAM_IF2_WE = (state == L1_WRITE_TEMP) ? 4'b1111 : 4'b0000;

endmodule
