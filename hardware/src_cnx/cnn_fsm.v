// =============================================================================
// File     : cnn_fsm.v
// Project  : MNIST CNN Accelerator v2
// Author   : Auto-generated
// Date     : 2026-06-11
// -----------------------------------------------------------------------------
// Description:
//   Finite State Machine (FSM) điều khiển toàn bộ pipeline CNN gồm 4 layer:
//     Layer 1 : Conv1 (3x3, 16ch) + MaxPool 2x2  -- Input 8x32x1
//     Layer 2 : Conv2 (3x3, 32ch, 16 in_ch)
//     Layer 3 : Dense1 (416->48, ReLU + quantize)
//     Layer 4 : Dense2 (48->2, argmax)
//
//   Tổng số state: 26 (IDLE..DONE)
// =============================================================================

`timescale 1ns/10ps
`define DATA_BITS 32

module cnn_fsm (
    // -------------------------------------------------------------------------
    // Clock / Reset / Control
    // -------------------------------------------------------------------------
    input  wire        clk,        // System clock
    input  wire        rst,        // Active-high synchronous-ish reset
    input  wire        start,      // Pulse to begin inference
    input  wire        ready,      // External "result consumed" handshake

    // -------------------------------------------------------------------------
    // FSM state outputs
    // -------------------------------------------------------------------------
    output reg  [5:0]  state,      // Current state
    output reg  [5:0]  n_state,    // Next state (combinational)

    // -------------------------------------------------------------------------
    // Layer indicator
    // -------------------------------------------------------------------------
    output reg  [2:0]  layer,      // Which layer is active (1-4, 0=idle)

    // -------------------------------------------------------------------------
    // Counters / indices
    // -------------------------------------------------------------------------
    output reg  [6:0]  counter,    // General cycle counter (max 104 in L2_WRITE)
    output reg  [2:0]  row_group,  // Row group index for Layer1 (0..5)
    output reg  [2:0]  ch_batch,   // Channel batch index (L1:0..1, L2:0..3, L3:0..5)
    output reg  [3:0]  in_ch,      // Input channel index for Layer2 (0..15)
    output reg  [4:0]  col_pos,    // Column position (L1:0..29, L2:0..12)
    output reg  [5:0]  dense_cnt,  // Dense group counter (L3:0..51, L4:0..5)
    output reg  [1:0]  mxpl_row,   // MaxPool output row index (0..2)

    // -------------------------------------------------------------------------
    // Done flag
    // -------------------------------------------------------------------------
    output wire        done        // Asserted when inference is complete
);

// =============================================================================
// State encoding (6-bit one-hot friendly binary)
// =============================================================================
localparam [5:0]
    IDLE        = 6'd0,
    L1_RST      = 6'd1,
    L1_RD_IFMP  = 6'd2,
    L1_RD_W     = 6'd3,
    L1_SET_COL  = 6'd4,
    L1_EXE      = 6'd5,
    L1_MXPL     = 6'd6,
    L1_WRITE    = 6'd7,
    L2_RST      = 6'd8,
    L2_RD_IFMP  = 6'd9,
    L2_RD_W     = 6'd10,
    L2_SET      = 6'd11,
    L2_EXE      = 6'd12,
    L2_ACC      = 6'd13,
    L2_WRITE    = 6'd14,
    L3_RST      = 6'd15,
    L3_RD       = 6'd16,
    L3_EXE      = 6'd17,
    L3_ACC      = 6'd18,
    L3_OUT      = 6'd19,
    L4_RST      = 6'd20,
    L4_RD       = 6'd21,
    L4_EXE      = 6'd22,
    L4_ACC      = 6'd23,
    L4_OUT      = 6'd24,
    DONE        = 6'd25;

// =============================================================================
// counter_flag : wire báo state nào đang cần đếm
// counter tăng khi flag=1, reset về 0 khi chuyển state mới
// =============================================================================
wire counter_flag =
    (state == L1_RD_IFMP  && counter <= 7'd23)  ||  // 0..24 → 25 cycles
    (state == L1_RD_W     && counter <= 7'd17)  ||  // 0..18 → 19 cycles
    (state == L1_EXE      && counter <= 7'd1)   ||  // 0..2  → 3  cycles
    (state == L1_WRITE    && counter <= 7'd58)  ||  // 0..59 → 60 cycles
    (state == L2_RD_IFMP  && counter <= 7'd44)  ||  // 0..45 → 46 cycles
    (state == L2_RD_W     && counter <= 7'd17)  ||  // 0..18 → 19 cycles
    (state == L2_EXE      && counter <= 7'd1)   ||  // 0..2  → 3  cycles
    (state == L2_WRITE    && counter <= 7'd102) ||  // 0..103→ 104 cycles
    (state == L3_RD       && counter <= 7'd1)   ||  // 0..2  → 3  cycles
    (state == L3_EXE      && counter <= 7'd1)   ||  // 0..2  → 3  cycles
    (state == L4_RD       && counter <= 7'd3)   ||  // 0..4  → 5  cycles
    (state == L4_EXE      && counter <= 7'd1);      // 0..2  → 3  cycles

// =============================================================================
// Next-state logic (Combinational)
// =============================================================================
always @(*) begin
    case (state)
        // ------------------------------------------------------------------
        // IDLE → kick off on start pulse
        // ------------------------------------------------------------------
        IDLE       : n_state = start ? L1_RST : IDLE;

        // ==================================================================
        // LAYER 1 : Conv1 3x3x16 + MaxPool 2x2
        // ==================================================================
        L1_RST     : n_state = L1_RD_IFMP;

        // Read input feature map (25 cycles: 0..24)
        L1_RD_IFMP : n_state = (counter == 7'd24) ? L1_RD_W : L1_RD_IFMP;

        // Read weights (19 cycles: 0..18)
        L1_RD_W    : n_state = (counter == 7'd18) ? L1_SET_COL : L1_RD_W;

        // Set column position (1 cycle, immediately go to EXE)
        L1_SET_COL : n_state = L1_EXE;

        // Execute conv (3 cycles: 0..2)
        L1_EXE     : n_state = (counter == 7'd2) ? L1_MXPL : L1_EXE;

        // MaxPool decision logic
        L1_MXPL    : begin
            if (col_pos < 5'd29)
                // More columns to process in this row group
                n_state = L1_SET_COL;
            else if (ch_batch == 3'd0)
                // Finished batch 0 → reload weights for batch 1
                n_state = L1_RD_W;
            else if (row_group[0] == 1'b0)
                // Even row_group finished → read next (odd) row_group
                n_state = L1_RD_IFMP;
            else
                // Odd row_group finished → write maxpool result
                n_state = L1_WRITE;
        end

        // Write MaxPool output (60 cycles: 0..59)
        L1_WRITE   : begin
            if (counter == 7'd59)
                // After 3rd mxpl_row (index 2) → move to Layer2
                n_state = (mxpl_row == 2'd2) ? L2_RST : L1_RD_IFMP;
            else
                n_state = L1_WRITE;
        end

        // ==================================================================
        // LAYER 2 : Conv2 3x3 (32 out_ch, 16 in_ch)
        // ==================================================================
        L2_RST     : n_state = L2_RD_IFMP;

        // Read input feature map (46 cycles: 0..45)
        L2_RD_IFMP : n_state = (counter == 7'd45) ? L2_RD_W : L2_RD_IFMP;

        // Read weights (19 cycles: 0..18)
        L2_RD_W    : n_state = (counter == 7'd18) ? L2_SET : L2_RD_W;

        // Set parameters (1 cycle)
        L2_SET     : n_state = L2_EXE;

        // Execute conv (3 cycles: 0..2)
        L2_EXE     : n_state = (counter == 7'd2) ? L2_ACC : L2_EXE;

        // Accumulation decision logic
        L2_ACC     : begin
            if (col_pos < 5'd12)
                // More columns in this in_ch/ch_batch
                n_state = L2_SET;
            else if (ch_batch < 4'd3)
                // Next ch_batch (reset col_pos)
                n_state = L2_RD_W;
            else if (in_ch < 4'd15)
                // Next in_ch (reset ch_batch + col_pos)
                n_state = L2_RD_IFMP;
            else
                // All in_ch done → write output
                n_state = L2_WRITE;
        end

        // Write Layer2 output (104 cycles: 0..103)
        L2_WRITE   : n_state = (counter == 7'd103) ? L3_RST : L2_WRITE;

        // ==================================================================
        // LAYER 3 : Dense1 (416→48, ReLU + quantize)
        // ==================================================================
        L3_RST     : n_state = L3_RD;

        // Read weights (3 cycles: 0..2; load words at counter 1,2; pe_pre_in at counter 1)
        L3_RD      : n_state = (counter == 7'd2) ? L3_EXE : L3_RD;

        // Execute MAC (3 cycles: 0..2)
        L3_EXE     : n_state = (counter == 7'd2) ? L3_ACC : L3_EXE;

        // Accumulate and check if group done
        L3_ACC     : begin
            if (dense_cnt < 6'd51)
                n_state = L3_RD;   // More groups in this batch
            else
                n_state = L3_OUT;  // All groups done → output
        end

        // Output: check if all batches done
        L3_OUT     : begin
            if (ch_batch < 3'd5)
                n_state = L3_RD;   // Next batch
            else
                n_state = L4_RST;  // All 6 batches done → Layer4
        end

        // ==================================================================
        // LAYER 4 : Dense2 (48→2, argmax)
        // ==================================================================
        L4_RST     : n_state = L4_RD;

        // Read weights (5 cycles: 0..4; load words at counter 1,2,3,4; pe_pre_in at counter 3)
        L4_RD      : n_state = (counter == 7'd4) ? L4_EXE : L4_RD;

        // Execute MAC (3 cycles: 0..2)
        L4_EXE     : n_state = (counter == 7'd2) ? L4_ACC : L4_EXE;

        // Accumulate and check group done
        L4_ACC     : begin
            if (dense_cnt < 6'd5)
                n_state = L4_RD;   // More groups
            else
                n_state = L4_OUT;  // All groups done → output
        end

        // Output argmax (1 cycle)
        L4_OUT     : n_state = DONE;

        // Done: wait for consumer handshake
        DONE       : n_state = ready ? IDLE : DONE;

        // Default: stay
        default    : n_state = IDLE;
    endcase
end

// =============================================================================
// State register (Sequential)
// =============================================================================
always @(posedge clk or posedge rst) begin
    if (rst)
        state <= IDLE;
    else
        state <= n_state;
end

// =============================================================================
// Layer indicator (Combinational from state)
// =============================================================================
always @(*) begin
    case (state)
        L1_RST, L1_RD_IFMP, L1_RD_W,
        L1_SET_COL, L1_EXE, L1_MXPL, L1_WRITE : layer = 3'd1;

        L2_RST, L2_RD_IFMP, L2_RD_W,
        L2_SET, L2_EXE, L2_ACC, L2_WRITE       : layer = 3'd2;

        L3_RST, L3_RD, L3_EXE,
        L3_ACC, L3_OUT                          : layer = 3'd3;

        L4_RST, L4_RD, L4_EXE,
        L4_ACC, L4_OUT, DONE                   : layer = 3'd4;

        default                                 : layer = 3'd0;
    endcase
end

// =============================================================================
// Counter management (Sequential)
// counter tăng khi counter_flag=1, reset về 0 khi chuyển state mới
// =============================================================================
always @(posedge clk or posedge rst) begin
    if (rst)
        counter <= 7'd0;
    else if (counter_flag)
        counter <= counter + 7'd1;
    else
        counter <= 7'd0;
end

// =============================================================================
// row_group management (Layer1: 0..5)
// Tăng sau khi hoàn thành cặp (even+odd) → tại L1_MXPL khi col_pos==29, ch_batch==1
// =============================================================================
always @(posedge clk or posedge rst) begin
    if (rst)
        row_group <= 3'd0;
    else begin
        if (state == IDLE || state == L1_RST)
            row_group <= 3'd0;
        else if (state == L1_MXPL && col_pos == 5'd29 && ch_batch == 3'd1)
            row_group <= row_group + 3'd1;
    end
end

// =============================================================================
// ch_batch management
//   L1: toggle 0↔1
//   L2: 0..3
//   L3: 0..5
// =============================================================================
always @(posedge clk or posedge rst) begin
    if (rst)
        ch_batch <= 3'd0;
    else begin
        // Reset conditions
        if (state == IDLE  || state == L1_RST ||
            state == L2_RST || state == L3_RST || state == L4_RST)
            ch_batch <= 3'd0;

        // Layer1: toggle between 0 and 1 at end of each row sweep
        else if (state == L1_MXPL && col_pos == 5'd29) begin
            if (ch_batch == 3'd0)
                ch_batch <= 3'd1;
            else
                ch_batch <= 3'd0;
        end

        // Layer2: 0..3, reset to 0 when wrapping
        else if (state == L2_ACC && col_pos == 5'd12) begin
            if (ch_batch == 3'd3)
                ch_batch <= 3'd0;
            else
                ch_batch <= ch_batch + 3'd1;
        end

        // Layer3: 0..5, increment at L3_OUT
        else if (state == L3_OUT) begin
            if (ch_batch == 3'd5)
                ch_batch <= 3'd0;
            else
                ch_batch <= ch_batch + 3'd1;
        end
    end
end

// =============================================================================
// in_ch management (Layer2: 0..15)
// Increments when all ch_batch (0..3) complete for one in_ch
// =============================================================================
always @(posedge clk or posedge rst) begin
    if (rst)
        in_ch <= 4'd0;
    else begin
        if (state == IDLE || state == L2_RST)
            in_ch <= 4'd0;
        else if (state == L2_ACC && col_pos == 5'd12 && ch_batch == 3'd3) begin
            if (in_ch == 4'd15)
                in_ch <= 4'd0;
            else
                in_ch <= in_ch + 4'd1;
        end
    end
end

// =============================================================================
// col_pos management
//   Layer1: 0..29 (advance at L1_MXPL)
//   Layer2: 0..12 (advance at L2_ACC)
// =============================================================================
always @(posedge clk or posedge rst) begin
    if (rst)
        col_pos <= 5'd0;
    else begin
        if (state == IDLE || state == L1_RST || state == L2_RST)
            col_pos <= 5'd0;

        // Layer1: advance or wrap at end of row
        else if (state == L1_MXPL) begin
            if (col_pos == 5'd29)
                col_pos <= 5'd0;
            else
                col_pos <= col_pos + 5'd1;
        end

        // Layer2: advance or wrap at end of in_ch sweep
        else if (state == L2_ACC) begin
            if (col_pos == 5'd12)
                col_pos <= 5'd0;
            else
                col_pos <= col_pos + 5'd1;
        end
    end
end

// =============================================================================
// dense_cnt management
//   Layer3: 0..51 (advance at L3_ACC), reset at L3_RST / L3_OUT(wrap)
//   Layer4: 0..5  (advance at L4_ACC), reset at L4_RST
// =============================================================================
always @(posedge clk or posedge rst) begin
    if (rst)
        dense_cnt <= 6'd0;
    else begin
        if (state == IDLE || state == L3_RST || state == L4_RST)
            dense_cnt <= 6'd0;

        // Layer3: increment group counter (wraps at 51→0)
        else if (state == L3_ACC) begin
            if (dense_cnt == 6'd51)
                dense_cnt <= 6'd0;
            else
                dense_cnt <= dense_cnt + 6'd1;
        end

        // Layer4: increment group counter (wraps at 5→0)
        else if (state == L4_ACC) begin
            if (dense_cnt == 6'd5)
                dense_cnt <= 6'd0;
            else
                dense_cnt <= dense_cnt + 6'd1;
        end
    end
end

// =============================================================================
// mxpl_row management (0..2, tracks which MaxPool output row we are writing)
// Increments at the end of each L1_WRITE burst
// =============================================================================
always @(posedge clk or posedge rst) begin
    if (rst)
        mxpl_row <= 2'd0;
    else begin
        if (state == IDLE || state == L1_RST)
            mxpl_row <= 2'd0;
        else if (state == L1_WRITE && counter == 7'd59)
            mxpl_row <= mxpl_row + 2'd1;
    end
end

// =============================================================================
// Done output
// =============================================================================
assign done = (state == DONE);

endmodule
// ========================== END OF FILE =====================================
