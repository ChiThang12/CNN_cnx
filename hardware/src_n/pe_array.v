
`timescale 1ns/10ps
`define DATA_BITS 32
module pe_array(
  input clk,
  input rst,
  input [5:0] state,
  input [2:0] layer,
  input [5:0] counter,
  input [3:0] channel_cnt,
  
  input [383:0] i_cache_flat, // 48 * 8
  input [1599:0] w_cache_flat, // 200 * 8
  
  input [`DATA_BITS-1:0] BRAM_IF1_DOUT,
  input [4:0] bits_select,
  
  input [25599:0] psum_temp_flat, // 8 * 100 * 32
  input [255:0] psum_in_flat,     // 8 * 32

  input relu_en,
  input quan_en,

  output [255:0] pe_out_flat      // 8 * 32
);

  parameter L1_READ_TILE1  = 5,
            L1_READ_TILE2  = 6,
            L1_READ_TILE3  = 7,
            L1_READ_TILE4  = 8,
            L1_READ_TILE5  = 9,
            L1_READ_TILE6  = 10,
            L1_READ_TILE7  = 11,
            L1_READ_TILE8  = 12,
            L2_READ_TILE1  = 23,
            L2_READ_TILE2  = 24,
            L2_READ_TILE5  = 25,
            L2_READ_TILE6  = 26,
            L3_RD_BRTCH1   = 31,
            L4_RST         = 36,
            L5_RST         = 41;

  reg  [7:0]  pe_pre_in [0:24];
  reg  [7:0]  pe_in     [0:199]; // 200 * 8 = 1600
  wire [31:0] pe_out    [0:7];
  
  wire [7:0] i_cache [0:47];
  wire [7:0] w_cache [0:199];
  wire [31:0] psum_in [0:7];

  integer i, j;
  genvar k, a;
  
  generate
    for (k=0; k<48; k=k+1) begin : unflat_icache
      assign i_cache[k] = i_cache_flat[k*8+7 : k*8];
    end
    for (k=0; k<200; k=k+1) begin : unflat_wcache
      assign w_cache[k] = w_cache_flat[k*8+7 : k*8];
    end
    for (a=0; a<8; a=a+1) begin : unflat_psum
      assign psum_in[a] = psum_in_flat[a*32+31 : a*32];
      assign pe_out_flat[a*32+31 : a*32] = pe_out[a];
    end
  endgenerate

  // pe_pre_in: choose the 5 * 5 data from i_cache, whose size is 6 * 8 
  always @(posedge clk or posedge rst) begin
    if(rst) for(i = 0; i < 25; i=i+1) pe_pre_in[i] <= 0;
    else begin
      case(state)
        L1_READ_TILE1, L2_READ_TILE1: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              pe_pre_in[i+5*j] <= i_cache[i+8*j];
            end
          end
        end
        L1_READ_TILE2, L2_READ_TILE2: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              pe_pre_in[i+5*j] <= i_cache[i+8*j+1];
            end
          end
        end
        L1_READ_TILE3: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              pe_pre_in[i+5*j] <= i_cache[i+8*j+2];
            end
          end        
        end
        L1_READ_TILE4: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              pe_pre_in[i+5*j] <= i_cache[i+8*j+3];
            end
          end
        end
        L1_READ_TILE5, L2_READ_TILE5: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              pe_pre_in[i+5*j] <= i_cache[i+8*j+8];
            end
          end
        end
        L1_READ_TILE6, L2_READ_TILE6: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              pe_pre_in[i+5*j] <= i_cache[i+8*j+9];
            end
          end
        end
        L1_READ_TILE7: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              pe_pre_in[i+5*j] <= i_cache[i+8*j+10];
            end
          end
        end
        L1_READ_TILE8: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              pe_pre_in[i+5*j] <= i_cache[i+8*j+11];
            end
          end
        end
        L3_RD_BRTCH1: pe_pre_in[counter-1] <= BRAM_IF1_DOUT[bits_select-:8];
      endcase
    end
  end

  // make the PE's input data ready
  always @(*) begin
    if(layer == 1 || layer == 2 || layer == 3) begin
      for(j = 0; j < 176; j=j+25) begin
        for(i = 0; i < 25; i=i+1) begin
          pe_in[i+j] = pe_pre_in[i]; 
        end
      end
    end
    else if(layer == 4 && ~(state == L4_RST))begin
      for(j = 0; j < 15; j=j+1) begin
        for(i = 0; i < 8; i=i+1) begin
          pe_in[i+8*j] = psum_temp_flat[(i*100+j)*32 +: 8]; 
        end
      end 
      for(i = 120; i < 200; i=i+1) pe_in[i] = 0;
    end
    else if(layer == 5 && ~(state == L5_RST)) begin
      for(i = 16; i < 100; i=i+1) begin
        pe_in[i-16] = psum_temp_flat[(0*100+i)*32 +: 8];
        pe_in[i+84] = psum_temp_flat[(0*100+i)*32 +: 8];
      end
      for(i = 84; i < 100; i=i+1)  pe_in[i] = 0;
      for(i = 184; i < 200; i=i+1) pe_in[i] = 0;
    end
    else for(i = 0; i < 200; i=i+1) pe_in[i] = 0;
  end

  // ========================================= PE =====================================================================
	generate 
    for (a = 0; a < 8; a = a + 1) begin: pe_arrays 										
      PE PE_Array(.in_IF1 (pe_in[a*25+0] ), 
                  .in_IF2 (pe_in[a*25+1] ), 
                  .in_IF3 (pe_in[a*25+2] ), 
                  .in_IF4 (pe_in[a*25+3] ), 
                  .in_IF5 (pe_in[a*25+4] ), 
                  .in_IF6 (pe_in[a*25+5] ), 
                  .in_IF7 (pe_in[a*25+6] ), 
                  .in_IF8 (pe_in[a*25+7] ), 
                  .in_IF9 (pe_in[a*25+8] ), 
                  .in_IF10(pe_in[a*25+9] ), 
                  .in_IF11(pe_in[a*25+10]), 
                  .in_IF12(pe_in[a*25+11]), 
                  .in_IF13(pe_in[a*25+12]), 
                  .in_IF14(pe_in[a*25+13]), 
                  .in_IF15(pe_in[a*25+14]), 
                  .in_IF16(pe_in[a*25+15]), 
                  .in_IF17(pe_in[a*25+16]), 
                  .in_IF18(pe_in[a*25+17]), 
                  .in_IF19(pe_in[a*25+18]), 
                  .in_IF20(pe_in[a*25+19]), 
                  .in_IF21(pe_in[a*25+20]), 
                  .in_IF22(pe_in[a*25+21]), 
                  .in_IF23(pe_in[a*25+22]), 
                  .in_IF24(pe_in[a*25+23]), 
                  .in_IF25(pe_in[a*25+24]), 

                  .in_W1 (w_cache[a*25+0 ]), 
                  .in_W2 (w_cache[a*25+1 ]), 
                  .in_W3 (w_cache[a*25+2 ]), 
                  .in_W4 (w_cache[a*25+3 ]), 
                  .in_W5 (w_cache[a*25+4 ]), 
                  .in_W6 (w_cache[a*25+5 ]), 
                  .in_W7 (w_cache[a*25+6 ]), 
                  .in_W8 (w_cache[a*25+7 ]), 
                  .in_W9 (w_cache[a*25+8 ]), 
                  .in_W10(w_cache[a*25+9 ]), 
                  .in_W11(w_cache[a*25+10]), 
                  .in_W12(w_cache[a*25+11]), 
                  .in_W13(w_cache[a*25+12]), 
                  .in_W14(w_cache[a*25+13]), 
                  .in_W15(w_cache[a*25+14]), 
                  .in_W16(w_cache[a*25+15]), 
                  .in_W17(w_cache[a*25+16]), 
                  .in_W18(w_cache[a*25+17]), 
                  .in_W19(w_cache[a*25+18]), 
                  .in_W20(w_cache[a*25+19]), 
                  .in_W21(w_cache[a*25+20]), 
                  .in_W22(w_cache[a*25+21]), 
                  .in_W23(w_cache[a*25+22]), 
                  .in_W24(w_cache[a*25+23]), 
                  .in_W25(w_cache[a*25+24]),
                  .rst(rst), 
                  .clk(clk),
                  .psum(psum_in[a]),
                  .relu_en(relu_en),
                  .quan_en(quan_en),
                  .pe_out(pe_out[a])
                );	
    end
	endgenerate
  // ============================================================================================
endmodule
