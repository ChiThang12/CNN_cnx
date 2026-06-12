`timescale 1ns/10ps
`define DATA_BITS 32

// =============================================================================
// Module: addr_gen
// Description: BRAM address generator for MNIST CNN inference engine.
//              Generates read/write addresses for input feature map BRAMs
//              (IF1, IF2) and weight BRAMs (W1..W4) based on FSM state,
//              counters, and layer control signals.
//              All addresses are byte-based; bram.v shifts right by 2 internally.
// =============================================================================

module addr_gen(
  input  clk, rst,

  // FSM state signals
  input  [5:0] state, n_state,

  // Layer indicator (1=Conv1, 2=Conv2, 3=Dense1, 4=Dense2)
  input  [2:0] layer,

  // General-purpose counter (used across states)
  input  [6:0] counter,

  // Conv1/Conv2 control
  input  [2:0] row_group,   // which group of 3 rows (Conv1 input)
  input  [2:0] ch_batch,    // output channel batch index
  input  [3:0] in_ch,       // input channel index (Conv2)
  input  [4:0] col_pos,     // column position (unused here, kept for interface)

  // Dense layer counter
  input  [5:0] dense_cnt,

  // MaxPool row index
  input  [1:0] mxpl_row,

  // -------------------------------------------------------------------
  // BRAM addresses (byte-based)
  // -------------------------------------------------------------------
  output reg [31:0] BRAM_IF1_ADDR,
  output reg [31:0] BRAM_IF2_ADDR,
  output     [31:0] BRAM_W1_ADDR,
  output     [31:0] BRAM_W2_ADDR,
  output     [31:0] BRAM_W3_ADDR,
  output     [31:0] BRAM_W4_ADDR,

  // -------------------------------------------------------------------
  // Write enables (4-bit byte enable)
  // -------------------------------------------------------------------
  output [3:0] BRAM_IF1_WE, BRAM_IF2_WE,
  output [3:0] BRAM_W1_WE,  BRAM_W2_WE,  BRAM_W3_WE,  BRAM_W4_WE,

  // -------------------------------------------------------------------
  // BRAM enables (always active)
  // -------------------------------------------------------------------
  output BRAM_IF1_EN, BRAM_IF2_EN,
  output BRAM_W1_EN,  BRAM_W2_EN,  BRAM_W3_EN,  BRAM_W4_EN,

  // -------------------------------------------------------------------
  // Byte-select output for cache_ctrl (bit position within 32-bit word)
  // -------------------------------------------------------------------
  output reg [4:0] bits_select
);

  // =========================================================================
  // FSM State Parameters
  // =========================================================================
  parameter IDLE      = 6'd0;
  parameter L1_RST    = 6'd1;
  parameter L1_RD_IFMP= 6'd2;
  parameter L1_RD_W   = 6'd3;
  parameter L1_SET_COL= 6'd4;
  parameter L1_EXE    = 6'd5;
  parameter L1_MXPL   = 6'd6;
  parameter L1_WRITE  = 6'd7;

  parameter L2_RST    = 6'd8;
  parameter L2_RD_IFMP= 6'd9;
  parameter L2_RD_W   = 6'd10;
  parameter L2_SET    = 6'd11;
  parameter L2_EXE    = 6'd12;
  parameter L2_ACC    = 6'd13;
  parameter L2_WRITE  = 6'd14;

  parameter L3_RST    = 6'd15;
  parameter L3_RD     = 6'd16;
  parameter L3_EXE    = 6'd17;
  parameter L3_ACC    = 6'd18;
  parameter L3_OUT    = 6'd19;

  parameter L4_RST    = 6'd20;
  parameter L4_RD     = 6'd21;
  parameter L4_EXE    = 6'd22;
  parameter L4_ACC    = 6'd23;
  parameter L4_OUT    = 6'd24;
  parameter DONE      = 6'd25;

  // =========================================================================
  // Weight BRAM address registers (word-index, shifted <<2 for byte address)
  // =========================================================================

  reg [31:0] bram_w1_addr_r;
  reg [31:0] bram_w2_addr_r;
  reg [31:0] bram_w3_addr_r;
  reg [31:0] bram_w4_addr_r;

  // -------------------------------------------------------------------------
  // W1: Conv1 weight BRAM
  //   Layout: 2 batches x 19 words (18 kernel weights + 1 bias = 19 words)
  //   Batch 0: words  0..17 (address 0..17)
  //   Batch 1: words 18..35 (address 18..35)
  //   Increments each cycle in L1_RD_W.
  //   When transitioning back to L1_RD_W for batch 1: set to word 18.
  // -------------------------------------------------------------------------
  always @(posedge clk or posedge rst) begin
    if (rst)
      bram_w1_addr_r <= 0;
    else begin
      if (state == IDLE || state == L1_RST)
        bram_w1_addr_r <= 0;                        // Reset at layer start
      else if (state == L1_RD_W)
        bram_w1_addr_r <= bram_w1_addr_r + 1;       // Increment each read cycle
      // When MaxPool done (batch 0 complete), preload batch-1 start address
      else if (n_state == L1_RD_W && state == L1_MXPL && ch_batch == 0)
        bram_w1_addr_r <= 18;                        // Batch 1 starts at word 18
    end
  end
  assign BRAM_W1_ADDR = bram_w1_addr_r << 2;        // Convert word addr to byte addr

  // -------------------------------------------------------------------------
  // W2: Conv2 weight BRAM
  //   Layout: ch_batch * (16 in_ch * 18 words) + in_ch * 18 + counter
  //   Start of (ch_batch, in_ch) group = ch_batch*288 + in_ch*18
  //   Increments each cycle in L2_RD_W.
  //   Reset to correct group start when re-entering L2_RD_W from L2_ACC.
  // -------------------------------------------------------------------------
  always @(posedge clk or posedge rst) begin
    if (rst)
      bram_w2_addr_r <= 0;
    else begin
      if (state == IDLE || state == L2_RST)
        bram_w2_addr_r <= 0;                                        // Layer reset
      else if (state == L2_RD_W)
        bram_w2_addr_r <= bram_w2_addr_r + 1;                      // Sequential read
      // Pre-load next (ch_batch, in_ch) start address before L2_RD_W
      else if (n_state == L2_RD_W && state == L2_ACC)
        bram_w2_addr_r <= ch_batch * 288 + {28'b0, in_ch} * 18;   // Group base
      else if (n_state == L2_RD_W && state == L2_RST)
        bram_w2_addr_r <= 0;                                        // First group
    end
  end
  assign BRAM_W2_ADDR = bram_w2_addr_r << 2;

  // -------------------------------------------------------------------------
  // W3: Dense1 weight BRAM
  //   Layout: ch_batch*(416 inputs * 2 words/input) + dense_cnt*2 + counter
  //   Each ch_batch block = 832 words (416*2).
  //   On L3_OUT: advance to next ch_batch block (wraps to 0 after batch 5).
  // -------------------------------------------------------------------------
  always @(posedge clk or posedge rst) begin
    if (rst)
      bram_w3_addr_r <= 0;
    else begin
      if (state == IDLE || state == L3_RST)
        bram_w3_addr_r <= 0;                                          // Layer reset
      else if (state == L3_RD)
        bram_w3_addr_r <= bram_w3_addr_r + 1;                        // Sequential read
      // Advance to next ch_batch block after output stage
      else if (state == L3_OUT)
        bram_w3_addr_r <= (ch_batch + 1 < 6) ? (ch_batch + 1) * 832 : 0;
    end
  end
  assign BRAM_W3_ADDR = bram_w3_addr_r << 2;

  // -------------------------------------------------------------------------
  // W4: Dense2 weight BRAM
  //   Layout: dense_cnt*4 + counter (4 words per output group)
  //   Simple sequential increment in L4_RD; resets at layer start.
  // -------------------------------------------------------------------------
  always @(posedge clk or posedge rst) begin
    if (rst)
      bram_w4_addr_r <= 0;
    else begin
      if (state == IDLE || state == L4_RST)
        bram_w4_addr_r <= 0;                      // Layer reset
      else if (state == L4_RD)
        bram_w4_addr_r <= bram_w4_addr_r + 1;    // Sequential read
    end
  end
  assign BRAM_W4_ADDR = bram_w4_addr_r << 2;

  // =========================================================================
  // IF1 Address: Input feature map BRAM 1
  //   - L1: Holds raw input image (28x28, 8-bit pixels, 4 per word)
  //         Read 3 rows per group: row_group * 8 words/row = row_group * 32 bytes
  //   - L2_WRITE: Conv2 result written here sequentially (104 words)
  //   - L3_RD: Dense1 reads from here (address 0..103 sequential)
  // =========================================================================
  always @(posedge clk or posedge rst) begin
    if (rst)
      BRAM_IF1_ADDR <= 0;
    else begin
      // Reset to row_group base at L1 start or after finishing a row group
      if (state == L1_RST ||
          (n_state == L1_RD_IFMP && state == L1_WRITE && counter == 59))
        BRAM_IF1_ADDR <= {25'b0, row_group} * 32; // row_group * 8 words * 4 bytes
      // Increment by 4 bytes (one word) for each pixel group read
      else if (state == L1_RD_IFMP)
        BRAM_IF1_ADDR <= BRAM_IF1_ADDR + 4;
      // Sequential write address for Conv2 output (L2_WRITE)
      else if (state == L2_RST || state == L3_RST)
        BRAM_IF1_ADDR <= 0;
      else if (state == L2_WRITE)
        BRAM_IF1_ADDR <= {25'b0, counter} * 4;   // counter 0..103, byte address
    end
  end

  // =========================================================================
  // IF2 Address: Input feature map BRAM 2
  //   - L1_WRITE: MaxPool output written here
  //               Address = (mxpl_row * 60 + counter) * 4
  //               (15 columns x 4 channels = 60 words per mxpl row)
  //   - L2_RD_IFMP: Conv2 reads pooled feature map from here
  //                 Address = (counter * 4 + in_ch[3:2]) * 4
  //                 (4 channels packed per word, select via in_ch[1:0])
  // =========================================================================
  reg [31:0] bram_if2_addr_r;

  always @(posedge clk or posedge rst) begin
    if (rst)
      bram_if2_addr_r <= 0;
    else begin
      if (state == L2_RST)
        bram_if2_addr_r <= 0;                                          // Layer reset
      // L1_WRITE: compute write address for MaxPool output pixel
      else if (state == L1_WRITE)
        bram_if2_addr_r <= ({30'b0, mxpl_row} * 60 + {25'b0, counter}) * 4;
      // L2_RD_IFMP: compute read address for packed channel data
      else if (n_state == L2_RD_IFMP && state == L2_RST)
        bram_if2_addr_r <= 0;                                          // First read
      else if (state == L2_RD_IFMP)
        bram_if2_addr_r <= ({25'b0, counter} * 4 + {28'b0, in_ch[3:2]}) * 4;
    end
  end

  // BRAM_IF2_ADDR mux: expose IF2 during layer 2 or L1_WRITE
  always @(*) begin
    if (layer == 3'd2)
      BRAM_IF2_ADDR = bram_if2_addr_r;
    else if (state == L1_WRITE)
      BRAM_IF2_ADDR = bram_if2_addr_r;
    else
      BRAM_IF2_ADDR = 32'b0;
  end

  // =========================================================================
  // bits_select: selects which byte within a 32-bit BRAM word to extract
  //   for L2_RD_IFMP (4 channels packed per word, selected by in_ch[1:0])
  //   Registered to align with BRAM read latency.
  // =========================================================================
  reg [1:0] bits_sel_temp;

  always @(posedge clk or posedge rst) begin
    if (rst)
      bits_sel_temp <= 2'b00;
    else if (state == L2_RD_IFMP)
      bits_sel_temp <= in_ch[1:0];   // Capture channel byte-lane select
  end

  always @(*) begin
    case (bits_sel_temp)
      2'b00: bits_select = 5'd31;   // Bits [31:24] — highest byte
      2'b01: bits_select = 5'd23;   // Bits [23:16]
      2'b10: bits_select = 5'd15;   // Bits [15:8]
      2'b11: bits_select = 5'd7;    // Bits [7:0]  — lowest byte
      default: bits_select = 5'd31;
    endcase
  end

  // =========================================================================
  // BRAM Enable Signals (always enabled)
  // =========================================================================
  assign BRAM_W1_EN  = 1'b1;
  assign BRAM_W2_EN  = 1'b1;
  assign BRAM_W3_EN  = 1'b1;
  assign BRAM_W4_EN  = 1'b1;
  assign BRAM_IF1_EN = 1'b1;
  assign BRAM_IF2_EN = 1'b1;

  // =========================================================================
  // BRAM Write Enable Signals
  //   Weight BRAMs: read-only (WE = 0000)
  //   IF1: write during L2_WRITE (Conv2 output → IF1)
  //   IF2: write during L1_WRITE (MaxPool output → IF2)
  // =========================================================================
  assign BRAM_W1_WE  = 4'b0000;
  assign BRAM_W2_WE  = 4'b0000;
  assign BRAM_W3_WE  = 4'b0000;
  assign BRAM_W4_WE  = 4'b0000;
  assign BRAM_IF1_WE = (state == L2_WRITE) ? 4'b1111 : 4'b0000;
  assign BRAM_IF2_WE = (state == L1_WRITE) ? 4'b1111 : 4'b0000;

endmodule
