//`timescale 1ns/10ps
//`define DATA_BITS 32
//module maxpool_ctrl(
//  input clk,
//  input rst,
//  input [5:0] state,
//  input [2:0] layer,
//  input [3:0] channel_cnt,
  
//  input [255:0] pe_out_flat,

//  output [`DATA_BITS-1:0] BRAM_IF1_DIN,
//  output [`DATA_BITS-1:0] BRAM_IF2_DIN
//);

//  parameter L1_EXE1        = 13,
//            L1_EXE2        = 14,
//            L1_MX_PL1      = 15,
//            L1_MX_PL2      = 16,
//            L1_WRITE_TEMP  = 17,
//            L2_EXE         = 27,
//            L2_MX_PL       = 28,
//            L2_WRITE_TEMP  = 29;

//  wire [31:0] pe_out [0:7];
//  genvar k;
//  generate
//    for (k=0; k<8; k=k+1) begin : unflat_pe_out
//      assign pe_out[k] = pe_out_flat[k*32+31 : k*32];
//    end
//  endgenerate

//  wire shift_sram_en;
//  wire sft_mx_pl_reg_en;

//  assign shift_sram_en = (state == L1_EXE1 || state == L1_EXE2 || (channel_cnt == 5 && state == L2_EXE)); 
//  assign sft_mx_pl_reg_en = (state == L1_MX_PL1 || state == L1_MX_PL2 || state == L2_MX_PL); 

//  reg  [31:0] pe_sram [0:31]; // 32 * 32 = 1024
//  reg  [2:0]  pe_sram_indx_j;
  
//  reg [7:0] temp1;
//  reg [7:0] temp2;
//  reg [7:0] mx_pl_out;
//  reg [7:0] mx_pl_reg [0:11];
//  reg [3:0] mx_pl_reg_indx;

//  integer i, j;

//  // ======================================= maxpooling =====================================================================================
//  // pe_sram: the output of the PE 
//  always @(posedge clk or posedge rst) begin
//    if(rst) begin
//      for(i = 0; i < 32; i=i+1) begin
//        pe_sram[i] <= 0;
//      end
//    end
//    else begin // shift register
//      if(shift_sram_en) begin
//        for(j = 0; j < 8; j=j+1) pe_sram[j*4+3] <= pe_out[j];
//        for(j = 0; j < 8; j=j+1) begin
//          for(i = 3; i > 0; i=i-1) begin
//            pe_sram[j*4+i-1] <= pe_sram[j*4+i];
//          end
//        end
//      end 
//    end
//  end
  
//  always @(posedge clk or posedge rst) begin
//    if(rst) pe_sram_indx_j <= 0;
//    else begin
//      if(state == L1_MX_PL1 || state == L1_MX_PL2 || state == L2_MX_PL) pe_sram_indx_j <= pe_sram_indx_j + 1;
//      else pe_sram_indx_j <= 0; 
//    end
//  end
  
//  // maxpool: compare the number stored in pe_sram
//  always @(*) begin // 1 cycle
//    temp1     = (pe_sram[pe_sram_indx_j*4+0] > pe_sram[pe_sram_indx_j*4+1]) ? pe_sram[pe_sram_indx_j*4+0] : pe_sram[pe_sram_indx_j*4+1];
//    temp2     = (pe_sram[pe_sram_indx_j*4+2] > temp1) ? pe_sram[pe_sram_indx_j*4+2] : temp1;
//    mx_pl_out = (pe_sram[pe_sram_indx_j*4+3] > temp2) ? pe_sram[pe_sram_indx_j*4+3] : temp2;
//  end
  
//  // max pool output
//  always @(posedge clk or posedge rst) begin
//    if(rst) for(i = 0; i < 8; i=i+1) mx_pl_reg[i] <= 0;
//    else begin
//      if(sft_mx_pl_reg_en) begin
//        if(layer == 1) begin     // index used: 0 ~ 11 
//          mx_pl_reg[11] <= mx_pl_out;
//          for(i = 11; i >= 1; i=i-1) mx_pl_reg[i-1] <= mx_pl_reg[i]; 
//        end
//        else if(layer == 2) begin // index used: 0 ~ 7 
//          mx_pl_reg[7] <= mx_pl_out;
//          for(i = 7; i >= 1; i=i-1) mx_pl_reg[i-1] <= mx_pl_reg[i];           
//        end
//      end
//    end
//  end
  
//  always @(posedge clk or posedge rst) begin
//    if(rst) mx_pl_reg_indx <= 0;
//    else begin
//      if(state == L1_WRITE_TEMP || state == L2_WRITE_TEMP) mx_pl_reg_indx <= mx_pl_reg_indx + 4;
//      else mx_pl_reg_indx <= 0;
//    end
//  end
//  // ======================================================================================================================================================

//  // ========================================== Bram Din ======================================================================================== 
//  // BRAM_IF2_DIN: for conv1/conv3/fc2 output
//  assign BRAM_IF2_DIN = {mx_pl_reg[mx_pl_reg_indx], mx_pl_reg[mx_pl_reg_indx+1], mx_pl_reg[mx_pl_reg_indx+2], mx_pl_reg[mx_pl_reg_indx+3]};
  
//  // BRAM_IF1_DIN: for conv2/fc1 output
//  assign BRAM_IF1_DIN = {mx_pl_reg[mx_pl_reg_indx], mx_pl_reg[mx_pl_reg_indx+1], mx_pl_reg[mx_pl_reg_indx+2], mx_pl_reg[mx_pl_reg_indx+3]};
//  // ==============================================================================================================================================

//endmodule
`timescale 1ns/10ps
`define DATA_BITS 32

module maxpool_ctrl(
  input clk,
  input rst,
  input [5:0] state,
  input [2:0] layer,
  input [3:0] channel_cnt,
  input [255:0] pe_out_flat,
  output [`DATA_BITS-1:0] BRAM_IF1_DIN,
  output [`DATA_BITS-1:0] BRAM_IF2_DIN
);

  parameter L1_EXE1        = 13,
            L1_EXE2        = 14,
            L1_MX_PL1      = 15,
            L1_MX_PL2      = 16,
            L1_WRITE_TEMP  = 17,
            L2_EXE         = 27,
            L2_MX_PL       = 28,
            L2_WRITE_TEMP  = 29;

  // ---------- unpack pe_out_flat ----------
  wire [31:0] pe_out [0:7];
  genvar k;
  generate
    for (k = 0; k < 8; k = k + 1) begin : unflat_pe_out
      assign pe_out[k] = pe_out_flat[k*32 +: 32];
    end
  endgenerate

  wire shift_sram_en;
  wire sft_mx_pl_reg_en;

  assign shift_sram_en   = (state == L1_EXE1 || state == L1_EXE2 || (channel_cnt == 5 && state == L2_EXE)); 
  assign sft_mx_pl_reg_en = (state == L1_MX_PL1 || state == L1_MX_PL2 || state == L2_MX_PL); 

  // --------------------------------------------------------------
  // 1. pe_sram: 32 entries, m?i entry 32-bit (gi? nguyên kích th??c)
  //    S?a l?i shift register (dùng m?ng t?m ?? tránh race condition)
  // --------------------------------------------------------------
  reg [31:0] pe_sram [0:31];
  reg [2:0]  pe_sram_indx_j;

  integer i, j;
    reg [31:0] old_vals [0:31];
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      for (i = 0; i < 32; i = i + 1) pe_sram[i] <= 0;
    end else if (shift_sram_en) begin
      // L?u giá tr? c? tr??c khi ghi ?è
     
      for (j = 0; j < 32; j = j + 1) old_vals[j] = pe_sram[j];
      // Shift t?ng nhóm 4 s? (j*4+3 là m?i nh?t)
      for (j = 0; j < 8; j = j + 1) begin
        pe_sram[j*4 + 3] <= pe_out[j];                 // nh?n ??u vào m?i
        pe_sram[j*4 + 2] <= old_vals[j*4 + 3];
        pe_sram[j*4 + 1] <= old_vals[j*4 + 2];
        pe_sram[j*4 + 0] <= old_vals[j*4 + 1];
      end
    end
  end

  // --------------------------------------------------------------
  // 2. B? ??m ch? s? nhóm (gi? nguyên)
  // --------------------------------------------------------------
  always @(posedge clk or posedge rst) begin
    if (rst) pe_sram_indx_j <= 0;
    else begin
      if (state == L1_MX_PL1 || state == L1_MX_PL2 || state == L2_MX_PL)
        pe_sram_indx_j <= pe_sram_indx_j + 1;
      else
        pe_sram_indx_j <= 0;
    end
  end

  // --------------------------------------------------------------
  // 3. M?ng so sánh d?ng cây (2 t?ng thay vì 3) ? gi?m ?? tr? t? h?p
  // --------------------------------------------------------------
  wire [7:0] a, b, c, d;
  wire [7:0] max_ab, max_cd;
  wire [7:0] mx_pl_out;

  assign a = pe_sram[pe_sram_indx_j*4 + 0];
  assign b = pe_sram[pe_sram_indx_j*4 + 1];
  assign c = pe_sram[pe_sram_indx_j*4 + 2];
  assign d = pe_sram[pe_sram_indx_j*4 + 3];

  assign max_ab = (a > b) ? a : b;
  assign max_cd = (c > d) ? c : d;
  assign mx_pl_out = (max_ab > max_cd) ? max_ab : max_cd;

  // --------------------------------------------------------------
  // 4. Thanh ghi shift cho k?t qu? max (gi? nguyên c?u trúc)
  // --------------------------------------------------------------
  reg [7:0] mx_pl_reg [0:11];
  reg [3:0] mx_pl_reg_indx;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      for (i = 0; i < 12; i = i + 1) mx_pl_reg[i] <= 0;
    end else if (sft_mx_pl_reg_en) begin
      if (layer == 1) begin          // c?n 12 ph?n t?
        mx_pl_reg[11] <= mx_pl_out;
        for (i = 11; i >= 1; i = i - 1)
          mx_pl_reg[i-1] <= mx_pl_reg[i];
      end else if (layer == 2) begin // c?n 8 ph?n t?
        mx_pl_reg[7] <= mx_pl_out;
        for (i = 7; i >= 1; i = i - 1)
          mx_pl_reg[i-1] <= mx_pl_reg[i];
      end
    end
  end

  always @(posedge clk or posedge rst) begin
    if (rst) mx_pl_reg_indx <= 0;
    else begin
      if (state == L1_WRITE_TEMP || state == L2_WRITE_TEMP)
        mx_pl_reg_indx <= mx_pl_reg_indx + 4;
      else
        mx_pl_reg_indx <= 0;
    end
  end

  // --------------------------------------------------------------
  // 5. Gán ??u ra BRAM (gi? nguyên)
  // --------------------------------------------------------------
  assign BRAM_IF2_DIN = { mx_pl_reg[mx_pl_reg_indx],
                          mx_pl_reg[mx_pl_reg_indx+1],
                          mx_pl_reg[mx_pl_reg_indx+2],
                          mx_pl_reg[mx_pl_reg_indx+3] };
  assign BRAM_IF1_DIN = BRAM_IF2_DIN;   // gi?ng h?t g?c

endmodule