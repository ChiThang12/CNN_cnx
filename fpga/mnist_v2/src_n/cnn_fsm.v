`timescale 1ns/10ps
`define DATA_BITS 32
module cnn_fsm(
  input clk,
  input rst,
  input start,
  input ready,
  input [`DATA_BITS-1:0] BRAM_IF2_ADDR_temp,
  input [`DATA_BITS-1:0] L2_BRAM_IF1_ADDR_temp,
  input [6:0] psum_temp_indx,
  
  output reg [5:0] state,
  output reg [5:0] n_state,
  output reg [2:0] layer,
  output reg [5:0] counter,
  output reg [3:0] channel_cnt,
  output reg [2:0] cnt_rd_new,
  output done
);

  // FSM:
  //==================== Layer 1 =======================================================
  parameter IDLE           = 0,
            L1_RD_BRTCH1   = 1,    // read bram to cache (12 cycle)
            L1_RD_BRTCH2   = 2,    // read bram to cache (37 cycle) total 50 cycle (weight)
            L1_RD_BRTCH3   = 3,    // read 6 * 8
            L1_READ24      = 4,
            L1_READ_TILE1  = 5,
            L1_READ_TILE2  = 6,
            L1_READ_TILE3  = 7,
            L1_READ_TILE4  = 8,
            L1_READ_TILE5  = 9,
            L1_READ_TILE6  = 10,
            L1_READ_TILE7  = 11,
            L1_READ_TILE8  = 12,
            L1_EXE1        = 13,
            L1_EXE2        = 14,
            L1_MX_PL1      = 15,
            L1_MX_PL2      = 16,
            L1_WRITE_TEMP  = 17;
            
  //==================== Layer 2 =======================================================
  parameter L2_RST        = 18,
            L2_RD_BRTCH1  = 19,
            L2_RD_BRTCH2  = 20,
            L2_RD_BRTCH3  = 21,
            L2_READ12     = 22,        
            L2_READ_TILE1 = 23,
            L2_READ_TILE2 = 24,
            L2_READ_TILE5 = 25,
            L2_READ_TILE6 = 26,
            L2_EXE        = 27,
            L2_MX_PL      = 28,
            L2_WRITE_TEMP = 29;

  //==================== Layer 3 =======================================================     
  parameter L3_RST        = 30,
            L3_RD_BRTCH1  = 31,
            L3_RD_BRTCH2  = 32,
            L3_RD_BRTCH3  = 33,
            L3_EXE        = 34,
            L3_DONE       = 35;

  //==================== Layer 4 =======================================================     
  parameter L4_RST        = 36,
            L4_RD_BRTCH1  = 37,
            L4_EXE        = 38,
            L4_SUM        = 39,
            L4_OUT        = 40;
  
  //==================== Layer 5 =======================================================     
  parameter L5_RST        = 41,
            L5_RD_BRTCH1  = 42,
            L5_RD_BRTCH2  = 43,
            L5_EXE        = 44,
            L5_SUM        = 45,
            L5_OUT        = 46,
            DONE          = 47;

  // next state logic
  always @(*) begin
    case (state)
    //======================= Layer 1 ===========================================================================================================
      IDLE:          n_state = (start) ? L1_RD_BRTCH1 : IDLE;
      L1_RD_BRTCH1:  n_state = (counter == 12) ? L1_RD_BRTCH2 : L1_RD_BRTCH1; // 0 ~ 12clk
      L1_RD_BRTCH2:  n_state = (counter == 37) ? L1_READ_TILE1 : L1_RD_BRTCH2; // 0 ~ 50clk
      L1_RD_BRTCH3:  n_state = (counter == 12) ? L1_READ_TILE1 : L1_RD_BRTCH3;

      L1_READ24:     n_state = (counter == 6)  ? L1_READ_TILE1 : L1_READ24;  // repeat 6 times -> L1_RD_BRTCH1

      // 1-2-5-6
      L1_READ_TILE1: n_state = L1_READ_TILE2;
      L1_READ_TILE2: n_state = L1_READ_TILE5;
      L1_READ_TILE3: n_state = L1_READ_TILE4;
      L1_READ_TILE4: n_state = L1_READ_TILE7;
      L1_READ_TILE5: n_state = L1_READ_TILE6;
      L1_READ_TILE6: n_state = L1_EXE1;
      L1_READ_TILE7: n_state = L1_READ_TILE8; 
      L1_READ_TILE8: n_state = L1_EXE2;
      L1_EXE1:       n_state = (counter == 3) ? L1_MX_PL1 : L1_EXE1;
      L1_EXE2:       n_state = (counter == 3) ? L1_MX_PL2 : L1_EXE2;
      L1_MX_PL1:     n_state = (counter == 5) ? L1_READ_TILE3 : L1_MX_PL1;  // repeat 6 times -> L1_RD_BRTCH1
      L1_MX_PL2:     n_state = (counter == 5) ? L1_WRITE_TEMP : L1_MX_PL2;
      L1_WRITE_TEMP: n_state = (BRAM_IF2_ADDR_temp == 293) ? L2_RST : ((counter == 2) ? ((cnt_rd_new == 6) ? L1_RD_BRTCH3 : L1_READ24) : L1_WRITE_TEMP); // 6 * 2 = 4 * 3
     
    //======================= Layer 2 ===========================================================================================================
      L2_RST:        n_state = L2_RD_BRTCH1;//(start) ? L2_RD_BRTCH1 : L2_RST;
      L2_RD_BRTCH1:  n_state = (counter == 36) ? L2_RD_BRTCH2  : L2_RD_BRTCH1; // 0 ~ 36 ifmp & weight
      L2_RD_BRTCH2:  n_state = (counter == 13) ? L2_READ_TILE1 : L2_RD_BRTCH2; // 0 ~ 50 weight
      L2_RD_BRTCH3:  n_state = (counter == 36) ? L2_READ_TILE1 : L2_RD_BRTCH3; // ifmp
      L2_READ12:     n_state = (counter == 12) ? L2_READ_TILE1 : L2_READ12;
      L2_READ_TILE1: n_state = L2_READ_TILE2;
      L2_READ_TILE2: n_state = L2_READ_TILE5;
      L2_READ_TILE5: n_state = L2_READ_TILE6;
      L2_READ_TILE6: n_state = L2_EXE;
      L2_EXE:        n_state = (counter == 3) ? ((channel_cnt == 5) ? L2_MX_PL : ((psum_temp_indx == 99) ? L2_RD_BRTCH1 : ((cnt_rd_new == 4) ? L2_RD_BRTCH3 : L2_READ12))) : L2_EXE; // rd12 repeats 4 times
      L2_MX_PL:      n_state = (counter == 7) ? L2_WRITE_TEMP : L2_MX_PL;
      L2_WRITE_TEMP: n_state = (L2_BRAM_IF1_ADDR_temp == 99) ? L3_RST : ((counter == 1) ? ((psum_temp_indx == 0) ? L2_RD_BRTCH1 : ((cnt_rd_new == 4) ? L2_RD_BRTCH3 : L2_READ12)) : L2_WRITE_TEMP); // 8 = 4 * 2 // change condition

      //======================= Layer 3 ===========================================================================================================
      L3_RST:        n_state = L3_RD_BRTCH1;
      L3_RD_BRTCH1:  n_state = (counter == 25) ? L3_RD_BRTCH2  : L3_RD_BRTCH1; // weight + input
      L3_RD_BRTCH2:  n_state = (counter == 24) ? L3_EXE : L3_RD_BRTCH2; // weight 
      L3_RD_BRTCH3:  n_state = (counter == 50) ? L3_EXE : L3_RD_BRTCH3; // weight 
      L3_EXE:        n_state = (counter == 2)  ? ((psum_temp_indx == 14) ? ((channel_cnt == 15) ? L3_DONE : L3_RD_BRTCH1) : L3_RD_BRTCH3) : L3_EXE;
      L3_DONE:       n_state = L4_RST;

      //======================= Layer 4 ===========================================================================================================
      L4_RST:        n_state = L4_RD_BRTCH1;
      L4_RD_BRTCH1:  n_state = (counter == 30) ? L4_EXE : L4_RD_BRTCH1;
      L4_EXE:        n_state = (counter == 2) ? L4_SUM : L4_EXE;
      L4_SUM:        n_state = L4_OUT;
      L4_OUT:        n_state = (psum_temp_indx == 99) ? L5_RST : L4_RD_BRTCH1;
              
      //======================= Layer 5 ===========================================================================================================
      L5_RST:        n_state = L5_RD_BRTCH1;
      L5_RD_BRTCH1:  n_state = (counter == 21) ? L5_RD_BRTCH2 : L5_RD_BRTCH1;
      L5_RD_BRTCH2:  n_state = (counter == 21) ? L5_EXE : L5_RD_BRTCH2;
      L5_EXE:        n_state = (counter == 2)  ? L5_SUM : L5_EXE;
      L5_SUM:        n_state = L5_OUT;
      L5_OUT:        n_state = (psum_temp_indx == 46) ? DONE : L5_RD_BRTCH1; // mode = 1: number, mode = 0: letter
      DONE:          n_state = (ready) ? IDLE : DONE;

      default:       n_state = IDLE;
    endcase
  end

  always @(posedge clk or posedge rst) begin
    if(rst) state <= IDLE;
    else state <= n_state;
  end

  // layer 
  always @(*) begin
    case (state)
      L1_RD_BRTCH1, L1_RD_BRTCH2, L1_RD_BRTCH3, L1_READ24, L1_READ_TILE1, L1_READ_TILE2, L1_READ_TILE3, 
      L1_READ_TILE4, L1_READ_TILE5, L1_READ_TILE6, L1_READ_TILE7, L1_READ_TILE8, L1_EXE1, L1_EXE2, L1_MX_PL1, 
      L1_MX_PL2, L1_WRITE_TEMP: layer = 1;

      L2_RST, L2_RD_BRTCH1, L2_RD_BRTCH2, L2_RD_BRTCH3, L2_READ12, L2_READ_TILE1, L2_READ_TILE2, L2_READ_TILE5, 
      L2_READ_TILE6, L2_EXE, L2_MX_PL, L2_WRITE_TEMP: layer = 2;

      L3_RST, L3_RD_BRTCH1, L3_RD_BRTCH2, L3_RD_BRTCH3, L3_EXE, L3_DONE: layer = 3;

      L4_RST, L4_RD_BRTCH1, L4_EXE, L4_SUM, L4_OUT: layer = 4;

      L5_RST, L5_RD_BRTCH1, L5_RD_BRTCH2, L5_EXE, L5_SUM, L5_OUT: layer = 5;
      
      default: layer = 0;
    endcase
  end

  assign done = (state == DONE);

  // Counters
  always @(posedge clk or posedge rst) begin
    if(rst) cnt_rd_new <= 0; // for conv1: RD24, for conv2: RD12
    else begin
      if((state == L1_READ24 && counter == 1) || (state == L2_READ12 && counter == 1)) cnt_rd_new <= cnt_rd_new + 1;
      else if(state == L1_RD_BRTCH3 || state == L2_RD_BRTCH1 || state == L2_RD_BRTCH3 || state == IDLE) cnt_rd_new <= 0;
    end
  end

  wire L1_counter_flag = (state == L1_RD_BRTCH1 && counter <= 11) || (state == L1_RD_BRTCH2 && counter <= 36) || (state == L1_RD_BRTCH3 && counter <= 11) ||
                         (state == L1_READ24 && counter <= 5) || ((state == L1_MX_PL1 || state == L1_MX_PL2) && counter <= 4) ||
                         (state == L1_WRITE_TEMP && counter <= 1) || ((state == L1_EXE1 || state == L1_EXE2) && counter <= 2);
                         
  wire L2_counter_flag = (state == L2_RD_BRTCH1 && counter <= 35) || (state == L2_RD_BRTCH2 && counter <= 12) || (state == L2_RD_BRTCH3 && counter <= 35) ||
                         (state == L2_READ12 && counter <= 11) || (state == L2_MX_PL && counter <= 6) ||
                         (state == L2_EXE && counter <= 2) || (state == L2_WRITE_TEMP && counter <= 0);
  
  wire L3_counter_flag = (state == L3_RD_BRTCH1 && counter <= 24) || (state == L3_RD_BRTCH2 && counter <= 23) || (state == L3_RD_BRTCH3 && counter <= 49) || 
                         (state == L3_EXE && counter <= 1);
                         
  wire L4_counter_flag = (state == L4_RD_BRTCH1 && counter <= 29) || (state == L4_EXE && counter <= 1);
  
  wire L5_counter_flag = (state == L5_RD_BRTCH1 && counter <= 20) || (state == L5_RD_BRTCH2 && counter <= 20) || (state == L5_EXE && counter <= 1);

  always @(posedge clk or posedge rst) begin
    if(rst) counter <= 0;
    else begin
      if(L1_counter_flag || L2_counter_flag || L3_counter_flag || L4_counter_flag || L5_counter_flag) counter <= counter + 1;
      else counter <= 0; 
    end
  end

  always @(posedge clk or posedge rst) begin
    if(rst) channel_cnt <= 0;
    else begin
      if((state == L2_EXE && n_state == L2_RD_BRTCH1) || (state == L3_EXE && n_state == L3_RD_BRTCH1)) channel_cnt <= channel_cnt + 1;
      else if((state == L2_WRITE_TEMP && n_state == L2_RD_BRTCH1) || state == L3_RST || state == IDLE) channel_cnt <= 0;
    end
  end

endmodule
