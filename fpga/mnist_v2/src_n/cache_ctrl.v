`timescale 1ns/10ps
`define DATA_BITS 32
module cache_ctrl(
  input clk,
  input rst,
  input [5:0] state,
  input [5:0] n_state,
  input [5:0] counter,
  input [4:0] bits_select,

  input [`DATA_BITS-1:0] BRAM_IF1_DOUT,
  input [`DATA_BITS-1:0] BRAM_IF2_DOUT,
  input [`DATA_BITS-1:0] BRAM_W1_DOUT,
  input [`DATA_BITS-1:0] BRAM_W2_DOUT,
  input [`DATA_BITS-1:0] BRAM_W3_DOUT,
  input [`DATA_BITS-1:0] BRAM_W4_DOUT,
  input [`DATA_BITS-1:0] BRAM_W5_DOUT,

  output [383:0] i_cache_flat,  // 48 * 8
  output [1599:0] w_cache_flat  // 200 * 8
);

  parameter IDLE           = 0,
            L1_RD_BRTCH1   = 1,
            L1_RD_BRTCH2   = 2,
            L1_RD_BRTCH3   = 3,
            L1_READ24      = 4,
            L1_WRITE_TEMP  = 17,
            L2_RST         = 18,
            L2_RD_BRTCH1   = 19,
            L2_RD_BRTCH2   = 20,
            L2_RD_BRTCH3   = 21,
            L2_READ12      = 22,
            L2_EXE         = 27,
            L2_WRITE_TEMP  = 29,
            L3_RD_BRTCH1   = 31,
            L3_RD_BRTCH2   = 32,
            L3_RD_BRTCH3   = 33,
            L4_RST         = 36,
            L4_RD_BRTCH1   = 37,
            L5_RST         = 41,
            L5_RD_BRTCH1   = 42,
            L5_RD_BRTCH2   = 43;

  reg [7:0] i_cache [0:47]; // 8 x 6 => 48 * 8 = 512, actually 48*8 = 384
  reg [7:0] w_cache [0:199];// 8 * 200 = 1600 
  reg [5:0] icache_indx;        // range: 0 ~ 63
  reg [7:0] wcache_indx;        // 0 ~ 255
  
  integer i;

  genvar k;
  generate
    for (k=0; k<48; k=k+1) begin : gen_icache
      assign i_cache_flat[k*8+7 : k*8] = i_cache[k];
    end
    for (k=0; k<200; k=k+1) begin : gen_wcache
      assign w_cache_flat[k*8+7 : k*8] = w_cache[k];
    end
  endgenerate

  // ========================== i_cache ================================================================================================
  always @(posedge clk or posedge rst) begin
    if(rst) for(i = 0; i < 48; i=i+1) i_cache[i] <= 0;
    else begin
      if(state == L1_READ24) begin
        if(counter == 0) begin
          for(i = 0; i < 41; i=i+8) i_cache[i] <= i_cache[i+4];
          for(i = 1; i < 42; i=i+8) i_cache[i] <= i_cache[i+4];
          for(i = 2; i < 43; i=i+8) i_cache[i] <= i_cache[i+4];
          for(i = 3; i < 44; i=i+8) i_cache[i] <= i_cache[i+4];
        end
        else if(counter == 1) {i_cache[4],  i_cache[5],  i_cache[6],  i_cache[7]}  <= BRAM_IF1_DOUT;
        else if(counter == 2) {i_cache[12], i_cache[13], i_cache[14], i_cache[15]} <= BRAM_IF1_DOUT;
        else if(counter == 3) {i_cache[20], i_cache[21], i_cache[22], i_cache[23]} <= BRAM_IF1_DOUT;
        else if(counter == 4) {i_cache[28], i_cache[29], i_cache[30], i_cache[31]} <= BRAM_IF1_DOUT;
        else if(counter == 5) {i_cache[36], i_cache[37], i_cache[38], i_cache[39]} <= BRAM_IF1_DOUT;
        else if(counter == 6) {i_cache[44], i_cache[45], i_cache[46], i_cache[47]} <= BRAM_IF1_DOUT;                             
      end 
      else if((state == L1_RD_BRTCH1 || state == L1_RD_BRTCH3) && counter != 0) 
        {i_cache[icache_indx], i_cache[icache_indx+1], i_cache[icache_indx+2], i_cache[icache_indx+3]} <= BRAM_IF1_DOUT; // 12 cycle 
      else if(state == L2_READ12) begin // 0 ~ 12
        if(counter == 0) begin
          for(i = 0; i < 41; i=i+8) i_cache[i] <= i_cache[i+2];
          for(i = 1; i < 42; i=i+8) i_cache[i] <= i_cache[i+2];
          for(i = 2; i < 43; i=i+8) i_cache[i] <= i_cache[i+2];
          for(i = 3; i < 44; i=i+8) i_cache[i] <= i_cache[i+2];
        end
        else i_cache[icache_indx] <= BRAM_IF2_DOUT[bits_select-:8];
      end
      else if((state == L2_RD_BRTCH1 || state == L2_RD_BRTCH3) && counter != 0)
        i_cache[icache_indx] <= BRAM_IF2_DOUT[bits_select-:8];
    end
  end

  // icache_indx
  always @(posedge clk or posedge rst) begin
    if(rst) icache_indx <= 0;
    else begin
      if((state == L1_RD_BRTCH1 || state == L1_RD_BRTCH3) && counter != 0) icache_indx <= icache_indx + 4;
      else if(state == L1_READ24) begin
        if(counter == 0) icache_indx <= 4;
        else icache_indx <= icache_indx + 8;
      end
      else if((state == L2_RD_BRTCH1 || state == L2_RD_BRTCH3) && counter != 0) begin
        if(icache_indx[2:0] == 3'b101) icache_indx <= icache_indx + 3;
        else icache_indx <= icache_indx + 1;
      end
      else if(state == L2_READ12) begin
        if(counter == 0) icache_indx <= 4;
        else if(counter == 1 || counter == 3 || counter == 5 || counter == 7 || counter == 9  || counter == 11) icache_indx <= icache_indx + 1;
        else if(counter == 2 || counter == 4 || counter == 6 || counter == 8 || counter == 10 || counter == 12) icache_indx <= icache_indx + 7;
      end
      else if(state == IDLE || state == L1_WRITE_TEMP || state == L2_RST || ((n_state == L2_RD_BRTCH1 || n_state == L2_RD_BRTCH3) && (state == L2_EXE || state == L2_WRITE_TEMP))) icache_indx <= 0;
    end
  end

  // ========================== w_cache ================================================================================================
  always @(posedge clk or posedge rst) begin
    if(rst) for(i = 0; i < 200; i=i+1) w_cache[i] <= 0; 
    else begin
      if((state == L1_RD_BRTCH1 && counter != 0) || state == L1_RD_BRTCH2) 
        {w_cache[wcache_indx], w_cache[wcache_indx+1], w_cache[wcache_indx+2], w_cache[wcache_indx+3]} <= BRAM_W1_DOUT; // 4 data in 1 row => 50 cycle
      else if((state == L2_RD_BRTCH1 && counter != 0) || state == L2_RD_BRTCH2) 
        {w_cache[wcache_indx], w_cache[wcache_indx+1], w_cache[wcache_indx+2], w_cache[wcache_indx+3]} <= BRAM_W2_DOUT; 
      else if((state == L3_RD_BRTCH1 && counter != 0) || state == L3_RD_BRTCH2 || (state == L3_RD_BRTCH3 && counter != 0)) 
        {w_cache[wcache_indx], w_cache[wcache_indx+1], w_cache[wcache_indx+2], w_cache[wcache_indx+3]} <= BRAM_W3_DOUT;
      else if(state == IDLE || state == L4_RST || state == L5_RST) for(i = 0; i < 200; i=i+1) w_cache[i] <= 0;
      else if(state == L4_RD_BRTCH1 && counter != 0) {w_cache[wcache_indx], w_cache[wcache_indx+1], w_cache[wcache_indx+2], w_cache[wcache_indx+3]} <= BRAM_W4_DOUT; 
      else if((state == L5_RD_BRTCH1 || state == L5_RD_BRTCH2) && counter != 0) {w_cache[wcache_indx], w_cache[wcache_indx+1], w_cache[wcache_indx+2], w_cache[wcache_indx+3]} <= BRAM_W5_DOUT; 
    end
  end

  // wcache_indx
  always @(posedge clk or posedge rst) begin
    if(rst) wcache_indx <= 0;
    else begin
      if(state == L5_RD_BRTCH2 && counter == 0) wcache_indx <= 100;
      else if(((state == L1_RD_BRTCH1 || state == L2_RD_BRTCH1 || state == L3_RD_BRTCH1 || state == L3_RD_BRTCH3 || state == L4_RD_BRTCH1 || state == L5_RD_BRTCH1 || state == L5_RD_BRTCH2) && counter != 0) || 
                state == L1_RD_BRTCH2 || state == L2_RD_BRTCH2 || state == L3_RD_BRTCH2) wcache_indx <= wcache_indx + 4;
      else wcache_indx <= 0;
    end
  end

endmodule
