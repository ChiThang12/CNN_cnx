`timescale 1ns/10ps
`define DATA_BITS 32
module cnn_top(
  input clk, 
  input rst, 
  input start, 
  output done,  
  input ready, 
  output [7:0] result, 

  output [`DATA_BITS-1:0] BRAM_IF1_ADDR,  
  output [`DATA_BITS-1:0] BRAM_IF2_ADDR,  

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

  input  [`DATA_BITS-1:0] BRAM_IF1_DOUT, 
  input  [`DATA_BITS-1:0] BRAM_IF2_DOUT, 
  input  [`DATA_BITS-1:0] BRAM_W1_DOUT,
  input  [`DATA_BITS-1:0] BRAM_W2_DOUT, 
  input  [`DATA_BITS-1:0] BRAM_W3_DOUT, 
  input  [`DATA_BITS-1:0] BRAM_W4_DOUT, 
  input  [`DATA_BITS-1:0] BRAM_W5_DOUT, 

  output [`DATA_BITS-1:0] BRAM_IF1_DIN, 
  output [`DATA_BITS-1:0] BRAM_IF2_DIN,
  output [`DATA_BITS-1:0] BRAM_W1_DIN, 
  output [`DATA_BITS-1:0] BRAM_W2_DIN,
  output [`DATA_BITS-1:0] BRAM_W3_DIN,
  output [`DATA_BITS-1:0] BRAM_W4_DIN,
  output [`DATA_BITS-1:0] BRAM_W5_DIN
);

  // W_DIN logic: none of the weight brams are written to in hardware
  // We can assign them to 0 or leave them disconnected (vivado tool will optimize).
  assign BRAM_W1_DIN = 0;
  assign BRAM_W2_DIN = 0;
  assign BRAM_W3_DIN = 0;
  assign BRAM_W4_DIN = 0;
  assign BRAM_W5_DIN = 0;

  // Internal signals
  wire [5:0] state, n_state, counter;
  wire [2:0] layer, cnt_rd_new;
  wire [3:0] channel_cnt;
  wire [`DATA_BITS-1:0] BRAM_IF2_ADDR_temp;
  wire [`DATA_BITS-1:0] L2_BRAM_IF1_ADDR_temp;
  wire [6:0] psum_temp_indx;
  wire [4:0] bits_select;

  wire [383:0] i_cache_flat;
  wire [1599:0] w_cache_flat;
  wire [255:0] pe_out_flat;
  wire [255:0] psum_in_flat;
  wire [25599:0] psum_temp_flat;

  wire relu_en, quan_en;

  // Parameters matching L3_RD_BRTCH1
  parameter L3_RD_BRTCH1 = 31;

  assign relu_en = (layer == 1 || (layer == 2 && channel_cnt == 5) || (layer == 3 && channel_cnt == 15 && !(counter == 0 && state == L3_RD_BRTCH1))) ? 1 : 0;
  assign quan_en = (layer == 1 || (layer == 2 && channel_cnt == 5) || (layer == 3 && channel_cnt == 15 && !(counter == 0 && state == L3_RD_BRTCH1))) ? 1 : 0;

  // 1. FSM and Control
  cnn_fsm u_fsm (
    .clk(clk),
    .rst(rst),
    .start(start),
    .ready(ready),
    .BRAM_IF2_ADDR_temp(BRAM_IF2_ADDR_temp),
    .L2_BRAM_IF1_ADDR_temp(L2_BRAM_IF1_ADDR_temp),
    .psum_temp_indx(psum_temp_indx),
    .state(state),
    .n_state(n_state),
    .layer(layer),
    .counter(counter),
    .channel_cnt(channel_cnt),
    .cnt_rd_new(cnt_rd_new),
    .done(done)
  );

  // 2. Address Generation
  addr_gen u_addr_gen (
    .clk(clk),
    .rst(rst),
    .state(state),
    .n_state(n_state),
    .layer(layer),
    .counter(counter),
    .cnt_rd_new(cnt_rd_new),
    .channel_cnt(channel_cnt),
    .psum_temp_indx(psum_temp_indx),
    .BRAM_IF1_ADDR(BRAM_IF1_ADDR),
    .BRAM_IF2_ADDR(BRAM_IF2_ADDR),
    .BRAM_W1_ADDR(BRAM_W1_ADDR),
    .BRAM_W2_ADDR(BRAM_W2_ADDR),
    .BRAM_W3_ADDR(BRAM_W3_ADDR),
    .BRAM_W4_ADDR(BRAM_W4_ADDR),
    .BRAM_W5_ADDR(BRAM_W5_ADDR),
    .BRAM_IF1_WE(BRAM_IF1_WE),
    .BRAM_IF2_WE(BRAM_IF2_WE),
    .BRAM_W1_WE(BRAM_W1_WE),
    .BRAM_W2_WE(BRAM_W2_WE),
    .BRAM_W3_WE(BRAM_W3_WE),
    .BRAM_W4_WE(BRAM_W4_WE),
    .BRAM_W5_WE(BRAM_W5_WE),
    .BRAM_IF1_EN(BRAM_IF1_EN),
    .BRAM_IF2_EN(BRAM_IF2_EN),
    .BRAM_W1_EN(BRAM_W1_EN),
    .BRAM_W2_EN(BRAM_W2_EN),
    .BRAM_W3_EN(BRAM_W3_EN),
    .BRAM_W4_EN(BRAM_W4_EN),
    .BRAM_W5_EN(BRAM_W5_EN),
    .BRAM_IF2_ADDR_temp(BRAM_IF2_ADDR_temp),
    .L2_BRAM_IF1_ADDR_temp(L2_BRAM_IF1_ADDR_temp),
    .bits_select(bits_select)
  );

  // 3. Cache Controller
  cache_ctrl u_cache_ctrl (
    .clk(clk),
    .rst(rst),
    .state(state),
    .n_state(n_state),
    .counter(counter),
    .bits_select(bits_select),
    .BRAM_IF1_DOUT(BRAM_IF1_DOUT),
    .BRAM_IF2_DOUT(BRAM_IF2_DOUT),
    .BRAM_W1_DOUT(BRAM_W1_DOUT),
    .BRAM_W2_DOUT(BRAM_W2_DOUT),
    .BRAM_W3_DOUT(BRAM_W3_DOUT),
    .BRAM_W4_DOUT(BRAM_W4_DOUT),
    .BRAM_W5_DOUT(BRAM_W5_DOUT),
    .i_cache_flat(i_cache_flat),
    .w_cache_flat(w_cache_flat)
  );

  // 4. PE Array
  pe_array u_pe_array (
    .clk(clk),
    .rst(rst),
    .state(state),
    .layer(layer),
    .counter(counter),
    .channel_cnt(channel_cnt),
    .i_cache_flat(i_cache_flat),
    .w_cache_flat(w_cache_flat),
    .BRAM_IF1_DOUT(BRAM_IF1_DOUT),
    .bits_select(bits_select),
    .psum_temp_flat(psum_temp_flat),
    .psum_in_flat(psum_in_flat),
    .relu_en(relu_en),
    .quan_en(quan_en),
    .pe_out_flat(pe_out_flat)
  );

  // 5. Maxpool Controller
  maxpool_ctrl u_maxpool_ctrl (
    .clk(clk),
    .rst(rst),
    .state(state),
    .layer(layer),
    .channel_cnt(channel_cnt),
    .pe_out_flat(pe_out_flat),
    .BRAM_IF1_DIN(BRAM_IF1_DIN),
    .BRAM_IF2_DIN(BRAM_IF2_DIN)
  );

  // 6. Partial Sum & FC Controller
  psum_fc_ctrl u_psum_fc_ctrl (
    .clk(clk),
    .rst(rst),
    .state(state),
    .layer(layer),
    .counter(counter),
    .channel_cnt(channel_cnt),
    .pe_out_flat(pe_out_flat),
    .psum_in_flat(psum_in_flat),
    .psum_temp_flat(psum_temp_flat),
    .psum_temp_indx(psum_temp_indx),
    .result(result)
  );

endmodule
