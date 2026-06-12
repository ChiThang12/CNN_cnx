// =============================================================================
// File      : maxpool_ctrl.v
// Project   : MNIST CNN Accelerator
// Author    : FPGA Engineer
// Created   : 2026-06-11
// Description:
//   MaxPool controller for Conv1 output (L1_MXPL / L1_WRITE states).
//   Implements 2x2 max-pooling over the 30-column Conv1 output:
//
//   Column pooling  : compares adjacent even/odd column PE outputs
//                     → col_max_buf  [ch_batch * 120 + mpool_col*8 + PE_idx]
//   Row pooling     : at the end of an even row_group, col_max_buf is
//                     snapshot into row_buf for later comparison with the
//                     following odd row_group.
//   Final max       : final_max[i] = max(col_max_buf[i], row_buf[i])
//
//   Output packing  : During L1_WRITE the 32-bit BRAM_IF2_DIN word is built
//                     by packing 4 bytes selected by {write_cw, write_col}:
//                       counter[1:0] → 4 channel-words per column slice
//                       counter[6:2] → column index (0..14)
//
//   BRAM_IF1_DIN    : Driven to 0 here; the psum_fc_ctrl module drives it
//                     for Conv2 output write-back.
//
//   Index arithmetic (col_max_buf / row_buf):
//     - 2 ch_batches, 15 pooled columns, 8 PEs = 2*15*8 = 240 entries
//     - address = ch_batch * 120 + mpool_col * 8 + PE_idx
//       (mpool_col = col_pos >> 1, range 0..14)
// =============================================================================

`timescale 1ns/10ps
`define DATA_BITS 32

module maxpool_ctrl(
  input clk, rst,

  // FSM state & position info
  input [5:0] state,
  input [2:0] layer,
  input [2:0] row_group,
  input [2:0] ch_batch,
  input [4:0] col_pos,       // current column (0..29) in Conv1 sliding window
  input [6:0] counter,       // write counter
  input [1:0] mxpl_row,      // maxpool row index

  // PE outputs to be pooled
  input [255:0] pe_out_flat,            // 8 x 32-bit PE results

  // BRAM write-data outputs
  output [`DATA_BITS-1:0] BRAM_IF2_DIN, // Maxpool result → IF2 BRAM
  output [`DATA_BITS-1:0] BRAM_IF1_DIN  // Conv2 output   → IF1 BRAM (driven elsewhere)
);

  // ---------------------------------------------------------------------------
  // State parameter definitions (shared across project)
  // ---------------------------------------------------------------------------
  parameter IDLE       = 6'd0;
  parameter L1_RST     = 6'd1;
  parameter L1_RD_IFMP = 6'd2;
  parameter L1_RD_W    = 6'd3;
  parameter L1_SET_COL = 6'd4;
  parameter L1_EXE     = 6'd5;
  parameter L1_MXPL    = 6'd6;
  parameter L1_WRITE   = 6'd7;

  parameter L2_RST     = 6'd8;
  parameter L2_RD_IFMP = 6'd9;
  parameter L2_RD_W    = 6'd10;
  parameter L2_SET     = 6'd11;
  parameter L2_EXE     = 6'd12;
  parameter L2_ACC     = 6'd13;
  parameter L2_WRITE   = 6'd14;

  parameter L3_RST     = 6'd15;
  parameter L3_RD      = 6'd16;
  parameter L3_EXE     = 6'd17;
  parameter L3_ACC     = 6'd18;
  parameter L3_OUT     = 6'd19;

  parameter L4_RST     = 6'd20;
  parameter L4_RD      = 6'd21;
  parameter L4_EXE     = 6'd22;
  parameter L4_ACC     = 6'd23;
  parameter L4_OUT     = 6'd24;
  parameter DONE       = 6'd25;

  // ---------------------------------------------------------------------------
  // Unpack PE outputs to 8-element array
  // ---------------------------------------------------------------------------
  wire [31:0] pe_out [0:7];
  genvar a;
  generate
    for(a = 0; a < 8; a = a + 1)
      assign pe_out[a] = pe_out_flat[a*32 +: 32];
  endgenerate

  // Quantised (lower 8-bit) PE output – Conv1 output is already quantised
  wire [7:0] pe_out_q [0:7];
  generate
    for(a = 0; a < 8; a = a + 1)
      assign pe_out_q[a] = pe_out[a][7:0];
  endgenerate

  // ---------------------------------------------------------------------------
  // col_even_buf: snapshot PE outputs on even columns
  //   Compared with the next odd-column output to get column-wise max.
  // ---------------------------------------------------------------------------
  reg [7:0] col_even_buf [0:7];
  integer i;

  always @(posedge clk or posedge rst) begin
    if(rst) begin
      for(i = 0; i < 8; i = i + 1)
        col_even_buf[i] <= 8'd0;
    end
    else if(state == L1_MXPL && col_pos[0] == 1'b0) begin
      // Even column: capture current PE outputs
      for(i = 0; i < 8; i = i + 1)
        col_even_buf[i] <= pe_out_q[i];
    end
  end

  // ---------------------------------------------------------------------------
  // col_max_buf: column-pair max result
  //   Layout: [ch_batch * 120 + mpool_col * 8 + PE_idx]
  //   Populated on odd columns (compare with buffered even-column values).
  //   ch_batch is 3-bit; only bits [0] used for 2-batch addressing (range 0..1).
  // ---------------------------------------------------------------------------
  reg [7:0] col_max_buf [0:239]; // 2 * 15 * 8 = 240 entries

  always @(posedge clk or posedge rst) begin
    if(rst) begin
      for(i = 0; i < 240; i = i + 1)
        col_max_buf[i] <= 8'd0;
    end
    else if(state == L1_MXPL && col_pos[0] == 1'b1) begin
      // Odd column: compute max(even, current) for each PE
      for(i = 0; i < 8; i = i + 1) begin
        col_max_buf[ch_batch[0]*120 + (col_pos >> 1)*8 + i] <=
          (col_even_buf[i] > pe_out_q[i]) ? col_even_buf[i] : pe_out_q[i];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // row_buf: snapshot of col_max_buf at the end of every even row_group
  //   Condition: last column (col_pos==29), both ch_batches processed
  //   (ch_batch==1), and current row_group is even (row_group[0]==0).
  //   The following odd row_group will then compare its col_max_buf
  //   against this row_buf to get the 2x2 pool maximum.
  // ---------------------------------------------------------------------------
  reg [7:0] row_buf [0:239];

  always @(posedge clk or posedge rst) begin
    if(rst) begin
      for(i = 0; i < 240; i = i + 1)
        row_buf[i] <= 8'd0;
    end
    else if(state == L1_MXPL &&
            col_pos   == 5'd29 &&
            ch_batch  == 3'd1  &&
            row_group[0] == 1'b0) begin
      // End of even row_group: latch entire col_max_buf for row comparison
      for(i = 0; i < 240; i = i + 1)
        row_buf[i] <= col_max_buf[i];
    end
  end

  // ---------------------------------------------------------------------------
  // final_max: 2x2 pooling result = max(col_max_buf, row_buf)
  // ---------------------------------------------------------------------------
  wire [7:0] final_max [0:239];
  generate
    for(a = 0; a < 240; a = a + 1)
      assign final_max[a] =
        (col_max_buf[a] > row_buf[a]) ? col_max_buf[a] : row_buf[a];
  endgenerate

  // ---------------------------------------------------------------------------
  // Write-address decode (during L1_WRITE)
  //   counter[6:2] = write_col  (0..14, 15 pooled columns)
  //   counter[1:0] = write_cw   (0..3,  4 channel-words per column)
  //     write_cw[1] → ch_batch index (0 or 1)
  //     write_cw[0] → PE half  (0=PE0-3, 1=PE4-7)
  //   → Pack 4 bytes from final_max into one 32-bit BRAM word.
  // ---------------------------------------------------------------------------
  wire [4:0] write_col;
  wire [1:0] write_cw;
  wire       wr_batch;  // which ch_batch (0 or 1)
  wire       wr_half;   // which PE half  (0=lower 4, 1=upper 4)

  assign write_col = counter[6:2];
  assign write_cw  = counter[1:0];
  assign wr_batch  = write_cw[1];
  assign wr_half   = write_cw[0];

  // Base index into final_max for current write word:
  //   wr_batch*120 + write_col*8 + wr_half*4  → 4 consecutive bytes
  wire [7:0] base_idx;
  assign base_idx = wr_batch * 8'd120 + write_col * 8'd8 + wr_half * 8'd4;

  // Pack 4 bytes (big-endian byte order within word: byte3=MSB, byte0=LSB)
  assign BRAM_IF2_DIN = (state == L1_WRITE) ?
    { final_max[base_idx + 8'd3],
      final_max[base_idx + 8'd2],
      final_max[base_idx + 8'd1],
      final_max[base_idx + 8'd0] } : 32'd0;

  // ---------------------------------------------------------------------------
  // BRAM_IF1_DIN: driven by psum_fc_ctrl for Conv2 write-back; tie off here.
  // ---------------------------------------------------------------------------
  assign BRAM_IF1_DIN = 32'd0;

endmodule
