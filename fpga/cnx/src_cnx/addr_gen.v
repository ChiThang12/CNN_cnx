`timescale 1ns/10ps
`define DATA_BITS 32

// =============================================================================
// Module : addr_gen
// Project: MNIST CNN Accelerator v2
// Date   : 2026-06-11
// -----------------------------------------------------------------------------
// Description:
//   BRAM address generator cho MNIST CNN inference engine.
//   Sinh ??a ch? ??c/ghi cho IF1, IF2 (feature-map) và W1..W4 (weight BRAMs).
//   T?t c? ??a ch? là byte-based; bram.v t? shift-right 2 n?i b? (addr >> 2).
//
// Timing model (BRAM latency = 1 cycle):
//   - Addr set t?i posedge clk N  ?  BRAM_DOUT h?p l? t?i posedge clk N+1
//   - M?i read-state có 1 "dummy cycle" (counter == 0) ?? pipeline ??a ch?
//   - cache_ctrl b? qua counter == 0, b?t ??u ghi vào cache t? counter == 1
//
// ??a ch? W1..W4 ???c tính nh? sau:
//   W1 : word-index t?ng tu?n t? trong L1_RD_W (reset v? 0 ? L1_RST,
//        preload v? 18 khi chuy?n sang batch-1 t?i L1_MXPL)
//   W2 : preload v? (ch_batch*288 + in_ch*18) tr??c m?i L2_RD_W
//   W3 : t?ng tu?n t? qua t?t c? dense_cnt groups trong m?t ch_batch;
//        preload v? (ch_batch+1)*832 ? L3_OUT ?? chu?n b? batch ti?p
//   W4 : t?ng tu?n t? qua t?t c? dense_cnt groups; reset ? L4_RST
//
// *** NOTE V? L?I X TRONG SIMULATION ***
//   L?i "in_W9 = X" KHÔNG xu?t phát t? addr_gen.
//   Nguyên nhân th?c: bram.v không kh?i t?o mem[] ? X khi simulation b?t ??u.
//   Fix: thêm initial block trong bram.v:
//     initial begin : mem_init
//       integer idx;
//       for (idx = 0; idx < 50001; idx = idx + 1)
//         mem[idx] = 32'h0000_0000;
//     end
// =============================================================================

module addr_gen (
  input  wire        clk,
  input  wire        rst,

  // FSM state (current & next, combinational)
  input  wire [5:0]  state,
  input  wire [5:0]  n_state,

  // Layer indicator (1=Conv1, 2=Conv2, 3=Dense1, 4=Dense2)
  input  wire [2:0]  layer,

  // General-purpose counter
  input  wire [6:0]  counter,

  // Conv1 / Conv2 control
  input  wire [2:0]  row_group,   // Row group index (Conv1 input rows)
  input  wire [2:0]  ch_batch,    // Output channel batch
  input  wire [3:0]  in_ch,       // Input channel index (Conv2)
  input  wire [4:0]  col_pos,     // Column position (interface placeholder)

  // Dense layer group counter
  input  wire [5:0]  dense_cnt,

  // MaxPool output row index
  input  wire [1:0]  mxpl_row,

  // -------------------------------------------------------------------
  // BRAM addresses (byte-based)
  // -------------------------------------------------------------------
  output reg  [31:0] BRAM_IF1_ADDR,
  output reg  [31:0] BRAM_IF2_ADDR,
  output wire [31:0] BRAM_W1_ADDR,
  output wire [31:0] BRAM_W2_ADDR,
  output wire [31:0] BRAM_W3_ADDR,
  output wire [31:0] BRAM_W4_ADDR,

  // -------------------------------------------------------------------
  // Write enables (4-bit byte enable)
  // -------------------------------------------------------------------
  output wire [3:0]  BRAM_IF1_WE,
  output wire [3:0]  BRAM_IF2_WE,
  output wire [3:0]  BRAM_W1_WE,
  output wire [3:0]  BRAM_W2_WE,
  output wire [3:0]  BRAM_W3_WE,
  output wire [3:0]  BRAM_W4_WE,

  // -------------------------------------------------------------------
  // BRAM enables (always active)
  // -------------------------------------------------------------------
  output wire        BRAM_IF1_EN,
  output wire        BRAM_IF2_EN,
  output wire        BRAM_W1_EN,
  output wire        BRAM_W2_EN,
  output wire        BRAM_W3_EN,
  output wire        BRAM_W4_EN,

  // -------------------------------------------------------------------
  // Byte-select cho cache_ctrl (L2_RD_IFMP: byte lane trong 32-bit word)
  // -------------------------------------------------------------------
  output reg  [4:0]  bits_select
);

  // =========================================================================
  // FSM State Parameters
  // =========================================================================
  localparam [5:0]
    IDLE       = 6'd0,
    L1_RST     = 6'd1,
    L1_RD_IFMP = 6'd2,
    L1_RD_W    = 6'd3,
    L1_SET_COL = 6'd4,
    L1_EXE     = 6'd5,
    L1_MXPL    = 6'd6,
    L1_WRITE   = 6'd7,
    L2_RST     = 6'd8,
    L2_RD_IFMP = 6'd9,
    L2_RD_W    = 6'd10,
    L2_SET     = 6'd11,
    L2_EXE     = 6'd12,
    L2_ACC     = 6'd13,
    L2_WRITE   = 6'd14,
    L3_RST     = 6'd15,
    L3_RD      = 6'd16,
    L3_EXE     = 6'd17,
    L3_ACC     = 6'd18,
    L3_OUT     = 6'd19,
    L4_RST     = 6'd20,
    L4_RD      = 6'd21,
    L4_EXE     = 6'd22,
    L4_ACC     = 6'd23,
    L4_OUT     = 6'd24,
    DONE       = 6'd25;

  // =========================================================================
  // Weight BRAM word-index registers (byte addr = word_idx << 2)
  // =========================================================================
  reg [31:0] bram_w1_addr_r;
  reg [31:0] bram_w2_addr_r;
  reg [31:0] bram_w3_addr_r;
  reg [31:0] bram_w4_addr_r;

  // -------------------------------------------------------------------------
  // W1 : Conv1 weights
  //   Layout : 2 batches × 18 words/batch = 36 words total
  //            Batch 0 ? words  0..17  (addr_r 0..17)
  //            Batch 1 ? words 18..35  (addr_r 18..35)
  //
  //   Timing trace (BRAM latency = 1 cycle, cache skips counter == 0):
  //     L1_RST : addr_r = 0
  //     L1_RD_W counter=0 : BRAM_ADDR = 0*4, BRAM?mem[0] next cycle, addr_r?1
  //     L1_RD_W counter=1 : BRAM_DOUT = mem[0] ? w_cache[0..3]  ?
  //     ...
  //     L1_RD_W counter=18: BRAM_DOUT = mem[17] ? w_cache[68..71] ?
  //
  //   Batch 1 preload : t?i L1_MXPL (n_state==L1_RD_W, ch_batch==0)
  //     addr_r = 18 ? L1_RD_W cycle0 BRAM_ADDR = 18*4, mem[18] ra ? counter=1 ?
  // -------------------------------------------------------------------------
  always @(posedge clk or posedge rst) begin
    if (rst)
      bram_w1_addr_r <= 32'd0;
    else begin
      if (state == IDLE || state == L1_RST)
        // Reset v? word 0 m?i khi b?t ??u Layer 1
        bram_w1_addr_r <= 32'd0;
      else if (state == L1_RD_W)
        // T?ng tu?n t? m?i cycle trong tr?ng thái ??c weight
        bram_w1_addr_r <= bram_w1_addr_r + 32'd1;
      else if (state == L1_MXPL && n_state == L1_RD_W && ch_batch == 3'd0)
        // Preload ??a ch? ??u batch 1 tr??c khi vào L1_RD_W l?n 2
        // Cycle ti?p (L1_RD_W, counter=0): BRAM_ADDR = 18*4 ? mem[18] ra t?i counter=1
        bram_w1_addr_r <= 32'd18;
    end
  end
  assign BRAM_W1_ADDR = bram_w1_addr_r << 2;

  // -------------------------------------------------------------------------
  // W2 : Conv2 weights
  //   Layout : 4 ch_batches × 16 in_ch × 18 words = 1152 words
  //            Base c?a (ch_batch, in_ch) = ch_batch*288 + in_ch*18
  //
  //   Timing trace:
  //     Preload t?i L2_ACC (n_state==L2_RD_W) ho?c L2_RST (n_state==L2_RD_W):
  //       addr_r = ch_batch*288 + in_ch*18
  //     L2_RD_W counter=0: BRAM_ADDR = base*4 ? mem[base] ra ? counter=1 ?
  //     L2_RD_W counter=18: BRAM_DOUT = mem[base+17] ? w_cache[68..71] ?
  // -------------------------------------------------------------------------
  always @(posedge clk or posedge rst) begin
    if (rst)
      bram_w2_addr_r <= 32'd0;
    else begin
      if (state == IDLE || state == L2_RST)
        // Reset toàn b? Layer 2
        bram_w2_addr_r <= 32'd0;
      else if (state == L2_RD_W)
        // T?ng tu?n t? trong tr?ng thái ??c weight
        bram_w2_addr_r <= bram_w2_addr_r + 32'd1;
      else if (n_state == L2_RD_W && state == L2_ACC)
        // Preload base address cho (ch_batch, in_ch) ti?p theo
        // in_ch ?ã ???c update b?i FSM tr??c khi vào ?ây
        bram_w2_addr_r <= {28'd0, ch_batch} * 32'd288
                        + {28'd0, in_ch}    * 32'd18;
      else if (n_state == L2_RD_W && state == L2_RST)
        // Group ??u tiên: base = 0
        bram_w2_addr_r <= 32'd0;
    end
  end
  assign BRAM_W2_ADDR = bram_w2_addr_r << 2;

  // -------------------------------------------------------------------------
  // W3 : Dense1 weights
  //   Layout : 6 ch_batches × 832 words/batch = 4992 words
  //            M?i batch = 52 groups × 2 words/group × 8 bytes/word... xem note
  //
  //   Timing trace (L3_RD = 3 cycles, counter 0..2, cache ghi t?i 1 và 2):
  //     L3_RST : addr_r = 0
  //     L3_RD counter=0 : BRAM_ADDR = 0 ? mem[0] ra ? counter=1
  //     L3_RD counter=1 : BRAM_DOUT = mem[0] ? w_cache[0..3] ?
  //     L3_RD counter=2 : BRAM_DOUT = mem[1] ? w_cache[4..7] ?
  //     addr_r = 2 sau khi thoát L3_RD l?n 1
  //
  //   Gi?a các dense_cnt groups (L3_ACC ? L3_RD):
  //     addr_r gi? nguyên ? L3_RD l?n ti?p ??c mem[addr_r], mem[addr_r+1] ?
  //     (sequential, ?úng)
  //
  //   Chuy?n sang ch_batch m?i (L3_OUT):
  //     Preload: addr_r = (ch_batch+1)*832
  //     L3_RD l?n ??u c?a batch m?i ??c mem[(ch_batch+1)*832] ?
  // -------------------------------------------------------------------------
  always @(posedge clk or posedge rst) begin
    if (rst)
      bram_w3_addr_r <= 32'd0;
    else begin
      if (state == IDLE || state == L3_RST)
        // Reset v? ??u Layer 3
        bram_w3_addr_r <= 32'd0;
      else if (state == L3_RD && counter != 7'd16)  // FIX BUG C: skip LAST cycle to maintain stride=16
        // T?ng tu?n t?; gi? nguyên ? L3_EXE, L3_ACC, L3_OUT
        bram_w3_addr_r <= bram_w3_addr_r + 32'd1;
      else if (state == L3_OUT)
        // Preload base address cho ch_batch ti?p theo
        // ch_batch t?i ?ây là giá tr? TR??C KHI FSM t?ng, nên +1
        bram_w3_addr_r <= ({29'd0, ch_batch} + 32'd1 < 32'd6)
                        ? ({29'd0, ch_batch} + 32'd1) * 32'd832
                        : 32'd0;  // Sau batch 5 ? wrap v? 0 (không dùng, nh?ng phòng th?)
    end
  end
  assign BRAM_W3_ADDR = bram_w3_addr_r << 2;

  // -------------------------------------------------------------------------
  // W4 : Dense2 weights
  //   Layout : 6 dense groups × 4 words/group = 24 words
  //
  //   Timing trace (L4_RD = 5 cycles, counter 0..4, cache ghi t?i 1..4):
  //     L4_RST : addr_r = 0
  //     L4_RD counter=0: BRAM_ADDR = 0 ? mem[0] ra ? counter=1
  //     L4_RD counter=1: BRAM_DOUT = mem[0] ? w_cache[0..3]  ?
  //     L4_RD counter=2: BRAM_DOUT = mem[1] ? w_cache[4..7]  ?
  //     L4_RD counter=3: BRAM_DOUT = mem[2] ? w_cache[8..11] ?
  //     L4_RD counter=4: BRAM_DOUT = mem[3] ? w_cache[12..15]?
  //
  //   Gi?a các dense_cnt groups (L4_ACC ? L4_RD):
  //     addr_r gi? nguyên ? ??c sequential mem[4..7], mem[8..11], ... ?
  // -------------------------------------------------------------------------
  always @(posedge clk or posedge rst) begin
    if (rst)
      bram_w4_addr_r <= 32'd0;
    else begin
      if (state == IDLE || state == L4_RST)
        // Reset v? ??u Layer 4
        bram_w4_addr_r <= 32'd0;
      else if (state == L4_RD)
        // T?ng tu?n t?; gi? nguyên ? L4_EXE, L4_ACC
        bram_w4_addr_r <= bram_w4_addr_r + 32'd1;
    end
  end
  assign BRAM_W4_ADDR = bram_w4_addr_r << 2;

  // =========================================================================
  // IF1 Address : Input feature-map BRAM 1
  // =========================================================================
  // Layer 1 (L1_RD_IFMP):
  //   ??c 3 hàng pixel b?t ??u t? byte offset = row_group * 32
  //   (32 byte = 8 words = 1 hàng 32 pixel × 1 byte/pixel)
  //   Timing: addr set t?i L1_RST ? BRAM_ADDR = base
  //           L1_RD_IFMP: addr t?ng 4 bytes m?i cycle (k? c? cycle 0)
  //           Cycle 0: BRAM nh?n addr = base, tr? mem[base] ? cycle 1
  //           cache_ctrl b? counter=0, ghi t? counter=1 ? ?úng ?
  //
  // Layer 2 (L2_WRITE):
  //   Ghi Conv2 output tu?n t? (104 words), addr = counter * 4
  //
  // Layer 3 (L3_RD):
  //   ??c dense input (Conv2 quantized output ???c ghi vào IF1 ? L2_WRITE)
  //   addr = 0 khi vào L3_RST, t?ng tu?n t? (??a ch? do addr_gen không qu?n,
  //   IF1 ?ã ???c ghi ??y ?? trong L2_WRITE, L3_RD dùng BRAM_W3 không ph?i IF1)
  // =========================================================================
  always @(posedge clk or posedge rst) begin
    if (rst)
      BRAM_IF1_ADDR <= 32'd0;
    else begin
      if (state == L1_RST ||
          (n_state == L1_RD_IFMP && state == L1_WRITE && counter == 7'd59))
        // ??t base address cho row_group hi?n t?i
        // row_group * 8 words * 4 bytes = row_group * 32
        BRAM_IF1_ADDR <= {25'b0, row_group} * 32'd32;

      else if (state == L1_RD_IFMP)
        // T?ng 4 bytes m?i cycle ?? ??c t?ng word pixel (4 pixel/word)
        BRAM_IF1_ADDR <= BRAM_IF1_ADDR + 32'd4;

      else if (state == L2_RST || state == L3_RST)
        // Reset v? 0 tr??c Layer 2 write-back và Layer 3 read
        BRAM_IF1_ADDR <= 32'd0;

      else if (state == L2_WRITE)
        // Ghi tu?n t?: counter 0..103 ? byte addr 0..412
        BRAM_IF1_ADDR <= {25'b0, counter} * 32'd4;
    end
  end

  // =========================================================================
  // IF2 Address : Input feature-map BRAM 2
  // =========================================================================
  // L1_WRITE  : Ghi MaxPool output
  //             Addr = (mxpl_row * 60 + counter) * 4
  //             (15 col × 4 channel-words = 60 words/row)
  //
  // L2_RD_IFMP: ??c pooled feature map
  //             Addr = (counter * 4 + in_ch[3:2]) * 4
  //             (4 channels ?óng gói trong 1 word, ch?n byte b?ng in_ch[1:0])
  // =========================================================================
  reg [31:0] bram_if2_addr_r;

  always @(posedge clk or posedge rst) begin
    if (rst)
      bram_if2_addr_r <= 32'd0;
    else begin
      if (state == L2_RST)
        bram_if2_addr_r <= 32'd0;

      else if (state == L1_WRITE)
        // ??a ch? ghi MaxPool: 1 word m?i counter step
        bram_if2_addr_r <= ({30'b0, mxpl_row} * 32'd60
                          + {25'b0, counter}) * 32'd4;

      else if (n_state == L2_RD_IFMP && state == L2_RST)
        // Kh?i ??u L2_RD_IFMP: b?t ??u t? ??a ch? 0
        bram_if2_addr_r <= 32'd0;

      else if (state == L2_RD_IFMP)
        // ??a ch? ??c pooled map; ch?n word d?a trên counter và in_ch[3:2]
        bram_if2_addr_r <= ({25'b0, counter} * 32'd4
                          + {28'b0, in_ch[3:2]}) * 32'd4;
    end
  end

  // Mux IF2: expose address khi Layer 2 ?ang active ho?c L1_WRITE
  always @(*) begin
    if (layer == 3'd2 || state == L1_WRITE)
      BRAM_IF2_ADDR = bram_if2_addr_r;
    else
      BRAM_IF2_ADDR = 32'd0;
  end

  // =========================================================================
  // bits_select : byte lane select cho L2_RD_IFMP
  //   ??ng ký ?? align v?i BRAM latency 1 cycle.
  //   in_ch[1:0] t?i cycle N ? bits_sel_temp h?p l? ? cycle N+1 (?úng lúc dùng)
  // =========================================================================
  reg [1:0] bits_sel_temp;

  always @(posedge clk or posedge rst) begin
    if (rst)
      bits_sel_temp <= 2'b00;
    else if (state == L2_RD_IFMP)
      bits_sel_temp <= in_ch[1:0];
  end

  always @(*) begin
    case (bits_sel_temp)
      2'b00:   bits_select = 5'd31;  // Bits [31:24] - byte cao nh?t
      2'b01:   bits_select = 5'd23;  // Bits [23:16]
      2'b10:   bits_select = 5'd15;  // Bits [15:8]
      2'b11:   bits_select = 5'd7;   // Bits [7:0]  - byte th?p nh?t
      default: bits_select = 5'd31;
    endcase
  end

  // =========================================================================
  // BRAM Enable (luôn b?t)
  // =========================================================================
  assign BRAM_W1_EN  = 1'b1;
  assign BRAM_W2_EN  = 1'b1;
  assign BRAM_W3_EN  = 1'b1;
  assign BRAM_W4_EN  = 1'b1;
  assign BRAM_IF1_EN = 1'b1;
  assign BRAM_IF2_EN = 1'b1;

  // =========================================================================
  // BRAM Write Enable
  //   Weight BRAMs : read-only t? phía accelerator (WE = 0000)
  //   IF1          : write trong L2_WRITE (Conv2 output ? IF1)
  //   IF2          : write trong L1_WRITE (MaxPool output ? IF2)
  // =========================================================================
  assign BRAM_W1_WE  = 4'b0000;
  assign BRAM_W2_WE  = 4'b0000;
  assign BRAM_W3_WE  = 4'b0000;
  assign BRAM_W4_WE  = 4'b0000;
  assign BRAM_IF1_WE = (state == L2_WRITE) ? 4'b1111 : 4'b0000;
  assign BRAM_IF2_WE = (state == L1_WRITE) ? 4'b1111 : 4'b0000;

endmodule
// ========================== END OF FILE =====================================