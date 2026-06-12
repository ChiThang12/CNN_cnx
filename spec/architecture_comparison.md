# KIẾN TRÚC HIỆN TẠI vs ĐỀ XUẤT

## HIỆN TẠI: Linear FSM Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      cnn_top (Top-Level)                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐         ┌─────────────────┐                   │
│  │  cnn_fsm     │────────→│ Control Signals │                   │
│  │ (26 states)  │         │ (state, layer,  │                   │
│  │              │         │ counter, ch_... │                   │
│  └──────────────┘         └─────────────────┘                   │
│       │                            │                             │
│       └────────────┬───────────────┘                             │
│                    ▼                                              │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                   Control Flow                          │   │
│  │  L1_RST→L1_RD_IFMP→L1_RD_W→L1_SET_COL→L1_EXE→...       │   │
│  │  (explicit state per layer)                            │   │
│  └──────────────────────────────────────────────────────────┘   │
│       │              │              │            │               │
│       ▼              ▼              ▼            ▼               │
│  ┌─────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐     │
│  │addr_gen │  │cache_ctrl│  │ pe_array │  │maxpool_ctrl  │     │
│  │(600 LOC)│  │(200 LOC) │  │(200 LOC) │  │ (250 LOC)   │     │
│  └────┬────┘  └────┬─────┘  └────┬─────┘  └──────┬───────┘     │
│       │           │             │               │               │
│  Read │ Addr      │ i_cache,    │ psum_in_flat  │ pe_out        │
│  Write│ commands  │ w_cache     │ (256 bits)    │ (256 bits)    │
│       │           │             │               │               │
│       ▼           ▼             ▼               ▼               │
│  ┌─────────────────┐    ┌──────────────────────────────────┐   │
│  │  BRAM Storage   │    │     psum_fc_ctrl (CRITICAL!)     │   │
│  │  ─────────────  │    │  ──────────────────────────────  │   │
│  │  IF1: 1×36Kb    │    │  Stores partial sums AS FF:      │   │
│  │  IF2: 1×36Kb    │    │                                  │   │
│  │  W1-W4: 4×36Kb  │    │  conv2_psum[4][13][8]  ─→ 13Kb  │   │
│  │                 │    │  dense1_psum[6][8]    ─→ 1.5Kb  │   │
│  │                 │    │  conv2_out[416]       ─→ 3.3Kb  │   │
│  └─────────────────┘    │  ────────────────────────         │   │
│                          │  TOTAL: ~18 Kb of FF!            │   │
│                          │  = ~4,500 LUTs wasted            │   │
│                          └──────────────────────────────────┘   │
│                                   │                              │
│                                   ▼                              │
│                         Result (8 bits)                          │
└─────────────────────────────────────────────────────────────────┘

ISSUES:
  ❌ 26 states hardcoded (can't add layers without rewrite)
  ❌ Very wide port buses (13K+ bits for conv2_psum_flat)
  ❌ 1-cycle BRAM latency → 25-30% wasted cycles
  ❌ Partial sums stored in FF (should be BRAM)
  ❌ Non-parameterizable (NUM_PE=8 fixed, kernel size fixed)
```

---

## ĐỀ XUẤT: Generalized Streaming Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│              cnn_top_v2 (Generalized)                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │          Generalized FSM (Only 4-State Loop!)              │ │
│  │  ┌─────────────────────────────────────────┐               │ │
│  │  │ IDLE                                    │               │ │
│  │  │   ↓                                     │               │ │
│  │  │ FETCH_IFMP (Đọc input features)        │               │ │
│  │  │   ↓                                     │               │ │
│  │  │ FETCH_WEIGHT (Đọc trọng số)             │               │ │
│  │  │   ↓                                     │               │ │
│  │  │ EXECUTE (Tính toán)                    │               │ │
│  │  │   ↓                                     │               │ │
│  │  │ WRITE_BACK (Ghi kết quả)                │               │ │
│  │  │   ↓ [Có còn lớp?]                      │               │ │
│  │  │ FETCH_IFMP (loop) / DONE                │               │ │
│  │  └─────────────────────────────────────────┘               │ │
│  │                                                              │ │
│  │  + CSR (Control Status Registers)                           │ │
│  │    - KERNEL_SIZE, STRIDE, INPUT_CHANNELS, OUTPUT_CHANNELS  │ │
│  │    - IFMP_WIDTH, IFMP_HEIGHT                               │ │
│  │    - PADDING, ACTIVATION_MODE, etc.                        │ │
│  │                                                              │ │
│  │  Kích thước: ~150 LUTs (vs 500 trước)                      │ │
│  └────────────────────────────────────────────────────────────┘ │
│       │ Control signals (state, layer_cfg, ...)                 │
│       └──────────┬────────────────────────────────────────────────┤
│                  ▼                                                 │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │            Streaming Data Path (AXI4-Stream)                │ │
│  │                                                              │ │
│  │  Master                                    Slave             │ │
│  │  (cache_ctrl)                              (pe_array)        │ │
│  │  ─────────────                             ──────────       │ │
│  │                                                              │ │
│  │  tvalid ───────────────┐                                    │ │
│  │                         ├────→ AXI4-Stream                  │ │
│  │  tready ←──────────────┤      Interconnect                  │ │
│  │                         │      (32-64 bits wide)            │ │
│  │  tdata[31:0] ──────────┘                                    │ │
│  │  tlast (optional)                                           │ │
│  │                                                              │ │
│  │  Advantages:                                                │ │
│  │  • Data width: 32/64 bits (not 13K!)                       │ │
│  │  • Easy backpressure when tready=0                         │ │
│  │  • Standard interface (reusable in larger SoC)             │ │
│  └──────────────────────────────────────────────────────────────┘ │
│       │ Input streaming data                                     │
│       ▼                                                           │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │         Ping-Pong Buffer (Double-Buffering)               │  │
│  │  ┌──────────────────┐      ┌──────────────────┐            │  │
│  │  │  Buffer_A        │      │  Buffer_B        │            │  │
│  │  │  (active read)   │◄────→│  (being filled)  │            │  │
│  │  │  ├─ i_cache_A    │      │  ├─ i_cache_B    │            │  │
│  │  │  │ (96 bytes)     │      │  │ (96 bytes)     │            │  │
│  │  │  ├─ w_cache_A    │      │  ├─ w_cache_B    │            │  │
│  │  │  │ (72 bytes)     │      │  │ (72 bytes)     │            │  │
│  │  │  └─ rptr_A       │      │  └─ wptr_B       │            │  │
│  │  └──────────────────┘      └──────────────────┘            │  │
│  │                                                              │  │
│  │  While PE_ARRAY reads from Buffer_A:                       │  │
│  │     cache_ctrl pre-fetches next layer data into Buffer_B   │  │
│  │  (1-cycle BRAM latency is now HIDDEN!)                     │  │
│  │                                                              │  │
│  │  Efficiency gain: 30% → 95%+ cycle efficiency             │  │
│  └────────────────────────────────────────────────────────────┘  │
│       │ i_cache, w_cache (pre-loaded, no stall)                 │
│       ▼                                                           │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │         PE Array (Parameterized)                           │  │
│  │                                                              │  │
│  │  parameter NUM_PE = 8;  (можна 4, 8, 16, 32)              │  │
│  │  parameter KERNEL_SIZE = 3;                                │  │
│  │                                                              │  │
│  │  Generate:                                                 │  │
│  │    for (p=0; p<NUM_PE; p=p+1) begin                        │  │
│  │      PE_NxN #(.SIZE(KERNEL_SIZE)) pe[p] (...)             │  │
│  │    end                                                     │  │
│  │                                                              │  │
│  │  Input:  i_cache (same patch for all PEs)                 │  │
│  │          w_cache (each PE has its weight row)             │  │
│  │          psum_in (from accumulator)                       │  │
│  │                                                              │  │
│  │  Output: pe_out[NUM_PE] (32-bit each)                     │  │
│  │                                                              │  │
│  │  No more pe_out_flat[255:0] explosion!                    │  │
│  └────────────────────────────────────────────────────────────┘  │
│       │ pe_out[0..NUM_PE-1]                                     │
│       ▼                                                           │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │   Accumulator with BRAM-based Storage (RMW Pattern)        │  │
│  │                                                              │  │
│  │  Old psum_fc_ctrl (FF nightmare):                          │  │
│  │    reg [31:0] conv2_psum[4][13][8]  = 13 KB FF            │  │
│  │                                                              │  │
│  │  New design (BRAM-based):                                  │  │
│  │    ┌─ Accumulator BRAM (36 Kb, dual-port)                 │  │
│  │    ├─ Read address: read_addr ← calculate(layer_cfg)      │  │
│  │    ├─ Read data: old_psum ← BRAM[read_addr] (1 cycle)    │  │
│  │    ├─ Compute: new_psum ← old_psum + pe_out             │  │
│  │    ├─ Write address: same as read                         │  │
│  │    └─ Write data: BRAM[write_addr] ← new_psum            │  │
│  │                                                              │  │
│  │    RMW Controller:                                         │  │
│  │      - Handles read-modify-write pipeline                 │  │
│  │      - Avoids hazards (RAW, WAW)                          │  │
│  │      - Output: result (8 bits for FC, or to IF2 BRAM)   │  │
│  │                                                              │  │
│  │  Savings:                                                  │  │
│  │    - conv2_psum: 13 KB FF → 0 FF (100% savings)          │  │
│  │    - dense1_psum: 1.5 KB FF → 0 FF (100% savings)        │  │
│  │    - conv2_out: keep small FF (read-heavy)                │  │
│  │    - Net: Save ~4,500 LUTs!                               │  │
│  └────────────────────────────────────────────────────────────┘  │
│       │ result (8 bits)                                         │
│       ▼                                                           │
│    Final classification                                          │
└─────────────────────────────────────────────────────────────────┘


IMPROVEMENTS:
  ✅ 4-state loop (fixed, not 26!)
  ✅ CSR-based parameterization (layer-independent)
  ✅ AXI4-Stream ports (32-64 bits, not 13K!)
  ✅ Ping-pong buffer (BRAM latency hidden, +35% speedup)
  ✅ BRAM-based accumulator (saves 4.5K LUTs)
  ✅ Parameterized PE array (scale NUM_PE easily)
  ✅ Only ~150 LUT (vs 500 for FSM), -30% total
  ✅ Support arbitrary number of layers (N-layer CNN)
```

---

## DATA FLOW COMPARISON

### Hiện Tại: Monolithic PE-Output Broadcast

```
               psum_fc_ctrl (RW cache)
                    │
                    ├─ conv2_psum_flat[13311:0] ──┐
                    │                             │ 13K bits!
                    ├─ dense1_psum_flat[1535:0]  │
                    │                             │ routing issue
                    └─ conv2_out_flat[3327:0] ───┘
                           │
                    ┌──────▼───────┐
                    │ cnn_top      │
                    │ wiring       │ (long nets)
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │ pe_array    │
                    │ unpacks all │
                    │ 3 arrays    │
                    └─────────────┘

Timing: Long combinational path → timing closure difficult
Power:  High toggle on wide buses → ~50% power in routing
Area:   Many wires and mux→ area overhead
```

### Đề Xuất: Streaming with Handshake

```
       cache_ctrl (source)          pe_array (sink)
            │                              │
            ├─ tvalid ────────────────────→│
            │     (1 bit: "data ready")    │
            │                              │
            ├─ tdata[31:0] ────────────────→│
            │     (only 32 bits!)          │
            │                              │
            └─ tready ←────────────────────┤
                  (1 bit: "PE ready")      │

When tready=0 (PE busy):
  - cache_ctrl automatically stalls
  - No explicit handshaking logic needed
  - Self-throttling mechanism

Timing: Short combinational depth (mux + registers) → easy closure
Power:  Low toggle on narrow buses → ~20% power in routing
Area:   Simple handshake logic → minimal overhead
```

---

## STATE MACHINE COMPARISON

### Hiện Tại: Explicit State Tree (26 States)

```
IDLE
  │
  └─ start=1
     │
     └─ L1_RST
        │
        └─ L1_RD_IFMP (counter==0..24)
           │
           └─ L1_RD_W (counter==0..18)
              │
              ├─ ch_batch==0 → L1_RD_W (preload batch 1)
              │
              └─ ch_batch==1 → L1_SET_COL
                 │
                 ├─ col_pos < 5'd29 → L1_SET_COL (loop columns)
                 │
                 └─ col_pos == 5'd29 → L1_MXPL
                    │
                    ├─ row_group[0]==0 → L1_RD_IFMP (next row)
                    │
                    └─ row_group[0]==1 → L1_WRITE (60 cycles)
                       │
                       ├─ mxpl_row < 2'd2 → L1_RD_IFMP
                       │
                       └─ mxpl_row==2'd2 → L2_RST
                          │
                          └─ L2_RD_IFMP (46 cycles)
                             │
                             └─ L2_RD_W (19 cycles)
                                │
                                ├─ col_pos==12 && ch_batch==3
                                │  ├─ in_ch==15 → L2_WRITE
                                │  └─ in_ch<15 → L2_RD_IFMP
                                │
                                └─ else → L2_SET
                                   │
                                   └─ L2_EXE → L2_ACC
                                      │
                                      └─ ... (decisions)
                                         │
                                         └─ L3_RST ... (more tree)
                                            │
                                            └─ L4_RST ... (more tree)
                                               │
                                               └─ DONE

Total: 26 explicit states + 20+ case branches
Problem: Any topology change → entire tree rebuild
```

### Đề Xuất: Generic Loop (4 States + CSR)

```
                    ┌─────────────────┐
                    │   LAYER LOOP    │
                    │  (for each CSR) │
                    └────────┬────────┘
                             │
         ┌───────────────────┼───────────────────┐
         │                   │                   │
         ▼                   ▼                   ▼
    FETCH_IFMP          FETCH_WEIGHT       EXECUTE
    ├─ Read addr        ├─ Read addr        ├─ Load PE input
    │  from CSR         │  from CSR          │
    ├─ Loop i_cache     ├─ Loop w_cache     ├─ 3-stage pipeline
    │  with handshake   │  with handshake    ├─ ReLU (if needed)
    └─ Done?            └─ Done?             ├─ Quantize
       Yes: FETCH_WEIGHT  Yes: EXECUTE        │  (if needed)
       No: (loop)          No: (loop)          └─ Output psum
                                                  │
                                                  ▼
                                            WRITE_BACK
                                            ├─ Select BRAM
                                            │ (IF1 vs IF2)
                                            ├─ RMW pattern
                                            │ (read old,
                                            │  compute sum,
                                            │  write new)
                                            └─ Done layer?
                                               Yes: FETCH_IFMP
                                                    (next layer)
                                               No: (loop)

Cycle cost per state: SAME
Total cycles: SAME
But architecture is GENERIC for any layer configuration!

CSR Configuration Example:
  Layer 1 CSR: {KERNEL=3, STRIDE=1, IN_CH=1, OUT_CH=16, ...}
  Layer 2 CSR: {KERNEL=3, STRIDE=1, IN_CH=16, OUT_CH=32, ...}
  Layer 3 CSR: {KERNEL=1, STRIDE=1, IN_CH=416, OUT_CH=48, ...}
  Layer 4 CSR: {KERNEL=1, STRIDE=1, IN_CH=48, OUT_CH=2, ...}
  
  To add Layer 5:
    - Just load new CSR config
    - FSM automatically applies it
    - No Verilog changes!
```

---

## SUMMARY

| Aspect | Current | Proposed |
|--------|---------|----------|
| **Architecture** | Linear, explicit states | Generic loop + CSR |
| **FSM States** | 26 | 4 (+config registers) |
| **Scalability** | Fixed 4 layers | N arbitrary layers |
| **Data Path** | Flat 13K-bit buses | AXI4-Stream 32-64 bits |
| **Buffering** | Single cache | Ping-pong buffer |
| **Storage** | FF-based psum | BRAM-based accumulator |
| **Latency Hiding** | ~70% efficient | ~95%+ efficient |
| **LUT Count** | ~13.8K | ~9.6K |
| **FF Count** | ~3.8K | ~3.2K |
| **BRAM Count** | 6 | 8 |
| **Development Time** | Days/weeks per layer | Hours for new layer (CSR only) |
| **Timing Closure** | Difficult (long nets) | Easy (short, standard IFs) |

