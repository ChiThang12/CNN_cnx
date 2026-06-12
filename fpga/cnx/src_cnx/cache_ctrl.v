`timescale 1ns/10ps
`define DATA_BITS 32

// =============================================================================
// Module: cache_ctrl
// Description: Cache controller for MNIST CNN inference engine.
//              Manages loading of:
//                - i_cache: 96-byte input feature map cache
//                  (3 rows x 32 cols for Conv1, or 45 pixels for Conv2)
//                - w_cache: 72-byte weight cache
//                  (8 PEs x 9 weights for Conv; Dense weight groups)
//              Data is sourced from BRAM read data ports (1-cycle latency),
//              indexed via counter and bits_select signals.
// =============================================================================

module cache_ctrl(
  input  clk, rst,

  // FSM state
  input  [5:0] state,

  // General-purpose counter (used to time BRAM read captures)
  input  [6:0] counter,

  // Byte-select for L2_RD_IFMP (bit position within 32-bit word)
  input  [4:0] bits_select,

  // BRAM read data ports
  input  [`DATA_BITS-1:0] BRAM_IF1_DOUT,
  input  [`DATA_BITS-1:0] BRAM_IF2_DOUT,
  input  [`DATA_BITS-1:0] BRAM_W1_DOUT,
  input  [`DATA_BITS-1:0] BRAM_W2_DOUT,
  input  [`DATA_BITS-1:0] BRAM_W3_DOUT,
  input  [`DATA_BITS-1:0] BRAM_W4_DOUT,

  // Flattened cache outputs (byte arrays packed into flat bus)
  output [767:0] i_cache_flat,   // 96 bytes: i_cache[0..95]
  output [575:0] w_cache_flat    // 72 bytes: w_cache[0..71]
);

  // =========================================================================
  // FSM State Parameters (local redeclaration for this module)
  // =========================================================================
  parameter L1_RD_IFMP = 6'd2;
  parameter L1_RD_W    = 6'd3;
  parameter L2_RD_IFMP = 6'd9;
  parameter L2_RD_W    = 6'd10;
  parameter L3_RD      = 6'd16;
  parameter L4_RD      = 6'd21;

  // =========================================================================
  // Cache Storage
  //   i_cache[0..95] : input feature map cache (3 rows × 32 pixels, 8-bit)
  //   w_cache[0..71] : weight cache (8 PE × 9 weights, 8-bit)
  // =========================================================================
  reg [7:0] i_cache [0:95];
  reg [7:0] w_cache [0:71];

  // Write index registers
  reg [6:0] icache_indx;   // byte index into i_cache (0..95)
  reg [6:0] wcache_indx;   // byte index into w_cache (0..71)

  integer i;

  // =========================================================================
  // Flatten cache arrays to output buses
  //   i_cache_flat[k*8+7 : k*8] = i_cache[k]  for k in 0..95
  //   w_cache_flat[k*8+7 : k*8] = w_cache[k]  for k in 0..71
  // =========================================================================
  genvar k;
  generate
    for (k = 0; k < 96; k = k + 1) begin : gen_icache_flat
      assign i_cache_flat[k*8+7 : k*8] = i_cache[k];
    end
    for (k = 0; k < 72; k = k + 1) begin : gen_wcache_flat
      assign w_cache_flat[k*8+7 : k*8] = w_cache[k];
    end
  endgenerate

  // =========================================================================
  // i_cache Loading
  //   L1_RD_IFMP: Load 4 pixels per BRAM read (32-bit word → 4 bytes)
  //              counter 0 is prefetch/dummy; capture starts at counter==1
  //              Total: 24 reads × 4 bytes = 96 bytes (3 rows × 32 pixels)
  //
  //   L2_RD_IFMP: Load 1 pixel per BRAM read (byte extracted via bits_select)
  //              counter 0 is dummy; capture starts at counter==1
  //              Total: 45 reads × 1 byte = 45 bytes (5×9 window)
  // =========================================================================
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      for (i = 0; i < 96; i = i + 1)
        i_cache[i] <= 8'h00;
    end
    else begin
      // --- Conv1: pack 4 pixels per BRAM word ---
      if (state == L1_RD_IFMP && counter != 7'd0)
        {i_cache[icache_indx],     i_cache[icache_indx + 7'd1],
         i_cache[icache_indx + 7'd2], i_cache[icache_indx + 7'd3]}
          <= BRAM_IF1_DOUT;  // MSB → lowest index (big-endian byte order)

      // --- Conv2: extract 1 byte from packed 4-channel word ---
      else if (state == L2_RD_IFMP && counter != 7'd0)
        i_cache[icache_indx] <= BRAM_IF2_DOUT[bits_select -: 8];
    end
  end

  // -------------------------------------------------------------------------
  // icache_indx: write pointer for i_cache
  //   - Reset to 0 at start of read state (counter==0)
  //   - Advance by 4 per cycle in L1_RD_IFMP (4 bytes per word)
  //   - Advance by 1 per cycle in L2_RD_IFMP (1 byte per read)
  // -------------------------------------------------------------------------
  always @(posedge clk or posedge rst) begin
    if (rst)
      icache_indx <= 7'd0;
    else begin
      if (state == L1_RD_IFMP) begin
        if (counter == 7'd0)
          icache_indx <= 7'd0;         // Reset at state entry (first cycle)
        else
          icache_indx <= icache_indx + 7'd4;  // 4 pixels loaded per word
      end
      else if (state == L2_RD_IFMP) begin
        if (counter == 7'd0)
          icache_indx <= 7'd0;         // Reset at state entry
        else
          icache_indx <= icache_indx + 7'd1;  // 1 pixel loaded per read
      end
      // Explicit reset for states L1_RD_IFMP (2) and L2_RD_IFMP (9) on entry
      else if (state == 6'd2 || state == 6'd9)
        icache_indx <= 7'd0;
    end
  end

  // =========================================================================
  // w_cache Loading
  //   All weight read states (L1_RD_W, L2_RD_W, L3_RD, L4_RD):
  //     Load 4 bytes per BRAM read (32-bit word)
  //     counter 0 is prefetch/dummy; capture starts at counter==1
  //     Source BRAM selected by current state.
  // =========================================================================
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      for (i = 0; i < 72; i = i + 1)
        w_cache[i] <= 8'h00;
    end
    else begin
      if ((state == L1_RD_W  || state == L2_RD_W ||
           state == L3_RD    || state == L4_RD)
          && counter != 7'd0) begin
        // Pack 4 bytes from selected weight BRAM into w_cache
        {w_cache[wcache_indx],       w_cache[wcache_indx + 7'd1],
         w_cache[wcache_indx + 7'd2], w_cache[wcache_indx + 7'd3]}
          <= (state == L1_RD_W) ? BRAM_W1_DOUT :
             (state == L2_RD_W) ? BRAM_W2_DOUT :
             (state == L3_RD)   ? BRAM_W3_DOUT :
                                  BRAM_W4_DOUT;
      end
    end
  end

  // -------------------------------------------------------------------------
  // wcache_indx: write pointer for w_cache
  //   - Advance by 4 each cycle while loading weights
  //   - Reset to 0 otherwise (ensures fresh load at next read state)
  // -------------------------------------------------------------------------
  always @(posedge clk or posedge rst) begin
    if (rst)
      wcache_indx <= 7'd0;
    else begin
      if ((state == L1_RD_W  || state == L2_RD_W ||
           state == L3_RD    || state == L4_RD)
          && counter != 7'd0)
        wcache_indx <= wcache_indx + 7'd4;   // 4 bytes per BRAM word
      else
        wcache_indx <= 7'd0;                 // Reset between bursts
    end
  end

endmodule
