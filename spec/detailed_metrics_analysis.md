# PHÂN TÍCH CHI TIẾT: TÀI NGUYÊN & HIỆU NĂNG HIỆN TẠI

## 1. FSM ANALYSIS

### Số lượng trạng thái theo lớp
```
Layer 1 (Conv1 + MaxPool):
  IDLE (1) → L1_RST (1) → L1_RD_IFMP (1) → L1_RD_W (1) → L1_SET_COL (1) 
  → L1_EXE (1) → L1_MXPL (1) → L1_WRITE (1)
  = 8 trạng thái + logic rẽ nhánh phức tạp

Layer 2 (Conv2):
  L2_RST (1) → L2_RD_IFMP (1) → L2_RD_W (1) → L2_SET (1) → L2_EXE (1)
  → L2_ACC (1) → L2_WRITE (1)
  = 7 trạng thái + logic accumulation

Layer 3 (Dense1):
  L3_RST (1) → L3_RD (1) → L3_EXE (1) → L3_ACC (1) → L3_OUT (1)
  = 5 trạng thái

Layer 4 (Dense2):
  L4_RST (1) → L4_RD (1) → L4_EXE (1) → L4_ACC (1) → L4_OUT (1)
  = 5 trạng thái

TOTAL: 8+7+5+5+1 (DONE) = 26 trạng thái
```

### Độ phức tạp logic
```verilog
// Từ cnn_fsm.v - next_state logic
always @(*) begin
    case (state)
        IDLE       : n_state = start ? L1_RST : IDLE;                    // 1 mux
        L1_RST     : n_state = L1_RD_IFMP;                              // 1 assign
        L1_RD_IFMP : n_state = (counter == 7'd24) ? L1_RD_W : ...;      // 1 mux
        L1_RD_W    : n_state = (counter == 7'd18) ? L1_SET_COL : ...;   // 1 mux
        L1_SET_COL : n_state = L1_EXE;                                  // 1 assign
        L1_EXE     : n_state = (counter == 7'd2) ? L1_MXPL : ...;       // 1 mux
        L1_MXPL    : begin                                              // 4-way mux
            if (col_pos < 5'd29)
                n_state = L1_SET_COL;
            else if (ch_batch == 3'd0)
                n_state = L1_RD_W;
            else if (row_group[0] == 1'b0)
                n_state = L1_RD_IFMP;
            else
                n_state = L1_WRITE;
        end
        ... [repeated 19 more states]
    endcase
end

// TỔNG CỘNG: ~26 case items + nested if-else = O(n) logic depth
// Khi synthesize → long combinational path → slow Fmax
```

### Vấn đề khi extend sang 5+ lớp
```
Nếu thêm 1 lớp mới (L5):
  - Thêm 5-8 trạng thái → 31-34 trạng thái
  - Thêm logic branch trong L4_OUT → L5_RST
  - Tất cả counter, layer, ch_batch, dense_cnt... cần update
  - Case statement trong next_state tăng từ 26→34 items
  - Khả năng introduce bug cao (missed state, circular dependency)
```

---

## 2. DATA PATH & PORT ANALYSIS

### I_CACHE (Input Feature Map Cache)

#### Layer 1 (Conv1): 3×32 = 96 pixels
```
Layout trong i_cache:
  Row 0: [32 pixels]  ← i_cache[0:31]
  Row 1: [32 pixels]  ← i_cache[32:63]
  Row 2: [32 pixels]  ← i_cache[64:95]
  
Fetch từ BRAM_IF1:
  L1_RD_IFMP state: 25 cycles (counter 0..24)
  - Counter=0 (dummy): BRAM_ADDR=0x00, ignore DOUT
  - Counter=1: BRAM_DOUT=mem[0] → i_cache[0:3]   (4 bytes)
  - Counter=2: BRAM_DOUT=mem[1] → i_cache[4:7]   (4 bytes)
  ...
  - Counter=24: BRAM_DOUT=mem[23] → i_cache[92:95] (4 bytes)
  
  96 bytes / 24 cycles = 4 bytes/cycle
  Throughput: 32 bits/cycle (khi tính BRAM word = 32 bits)
```

#### Layer 2 (Conv2): 5×9 = 45 pixels
```
Layout trong i_cache:
  Row 0: [15 pixels] ← i_cache[0:14]
  Row 1: [15 pixels] ← i_cache[15:29]
  Row 2: [15 pixels] ← i_cache[30:44]
  
Fetch từ BRAM_IF2:
  L2_RD_IFMP state: 46 cycles (counter 0..45)
  - Counter=0 (dummy): BRAM_ADDR=..., ignore
  - Counter=1: BRAM_DOUT[bits_select-:8] → i_cache[0]   (1 byte)
  - Counter=2: BRAM_DOUT[bits_select-:8] → i_cache[1]   (1 byte)
  ...
  - Counter=45: BRAM_DOUT[...] → i_cache[44]            (1 byte)
  
  45 bytes / 45 cycles = 1 byte/cycle
  Throughput: 8 bits/cycle
  
  ⚠️ VẤN ĐỀ: bits_select phải delay 1 cycle để align với BRAM latency
              → phức tạp hóa cache_ctrl.v
```

### W_CACHE (Weight Cache)

#### Layer 1: 8 PE × 9 weights = 72 bytes
```
L1_RD_W state: 19 cycles (counter 0..18)
  - Counter=0 (dummy)
  - Counter=1..18: 18 words (4 bytes each) = 72 bytes
  
  Throughput: 72 bytes / 18 cycles = 4 bytes/cycle (optimal)
```

#### Layer 2: 8 PE × 9 weights = 72 bytes
```
L2_RD_W state: 19 cycles (counter 0..18)
  - Same as Layer 1
  - Lặp lại 16 lần (per in_ch) × 4 (ch_batch) = 64 lần
```

#### Layer 3 & 4: Dense weights
```
L3_RD  state: 3 cycles  → 2 words = 8 bytes (repeated 52 times per batch, 6 batches)
L4_RD  state: 5 cycles  → 4 words = 16 bytes (repeated 6 times)
```

### PSUM FLAT ARRAYS - KHUNG HOẢNG TÀI NGUYÊN

#### Conv2 Partial Sums (cnn_top.v line 72)
```verilog
wire [13311:0] conv2_psum_flat;  // Unpack từ psum_fc_ctrl

// Trong psum_fc_ctrl.v:
reg signed [31:0] conv2_psum [0:3][0:12][0:7];

// Kích thước:
//   4 ch_batch × 13 columns × 8 PEs × 32 bits = 13,312 bits
//   = 1,664 bytes
//   = 1,664 flip-flops trên FPGA
//   = ~2 LUTs per FF (SRL16 + FF) = 3,328 LUTs (!!!)

// Tối ưu hóa với BRAM (1 block BRAM thường 36Kb):
//   Xilinx: 36 Kb = 4,608 bytes (32-bit word)
//   → Đủ chứa 1,664 bytes + overhead
//   → Tiết kiệm 3,328 LUTs
```

#### Dense1 Partial Sums (cnn_top.v line 73)
```verilog
wire [1535:0] dense1_psum_flat;

// Trong psum_fc_ctrl.v:
reg signed [31:0] dense1_psum [0:5][0:7];

// Kích thước:
//   6 batches × 8 neurons × 32 bits = 1,536 bits
//   = 192 bytes
//   = 192 flip-flops
//   = ~384 LUTs

// Có thể giữ FF vì nhỏ
```

#### Conv2 Output (cnn_top.v line 74)
```verilog
wire [3327:0] conv2_out_flat;

// Trong psum_fc_ctrl.v:
reg [7:0] conv2_out [0:415];

// Kích thước:
//   416 entries × 8 bits = 3,328 bits
//   = 416 bytes
//   = 416 flip-flops
//   = ~832 LUTs

// Nên keep ở FF (cần fast read cho Dense1 input)
```

### PORT FANOUT - ROUTING CONGESTION ANALYSIS

```
pe_array.v nhận từ psum_fc_ctrl.v:

  Input:  conv2_psum_flat[13311:0]    ← 13,312 wires
          dense1_psum_flat[1535:0]    ← 1,536 wires
  
  Output: pe_out_flat[255:0]          ← 256 wires (8 PE × 32-bit)
  
  psum_in_flat[255:0]                 ← 256 wires feedback

  TOTAL INPUT:  ~15K wires → cnn_top.v
  TOTAL OUTPUT: ~500 wires → cnn_top.v
  
  ⚠️ PROBLEM:
     - FPGA routing resources bị cạn kiệt khi:
       • Chip nhỏ (<50K LUTs)
       • Chế độ high utilization (>80% LUT usage)
     - Timing closure khó khăn (long nets → high delay)
     - Power consumption từ toggle activity trên những bus to này
```

---

## 3. PERFORMANCE & EFFICIENCY ANALYSIS

### Cycle Breakdown (MNIST đơn lẻ)

```
Layer 1 (Conv1 + MaxPool):
  ├─ L1_RST:      1 cycle
  ├─ L1_RD_IFMP:  25 cycles (dummy + 24 useful)
  ├─ L1_RD_W:     19 cycles × 2 batches = 38 cycles
  ├─ L1_SET_COL:  1 cycle × 30 columns = 30 cycles
  ├─ L1_EXE:      3 cycles × 30 columns = 90 cycles
  ├─ L1_MXPL:     30 cycles (column iteration)
  └─ L1_WRITE:    60 cycles × 3 rows = 180 cycles (max-pool output write)
  
  SUBTOTAL: 1+25+38+30+90+30+180 = 394 cycles
  Useful: 394 - 25 - 19×2 = 331 cycles
  Efficiency: 331/394 = 84%

Layer 2 (Conv2):
  ├─ L2_RST:      1 cycle
  ├─ L2_RD_IFMP:  46 cycles × 16 in_ch = 736 cycles
  ├─ L2_RD_W:     19 cycles × 4 ch_batch × 16 in_ch = 1,216 cycles
  ├─ L2_SET:      1 cycle × 13 col × 4 batch × 16 in_ch = 832 cycles
  ├─ L2_EXE:      3 cycles × 13 col × 4 batch × 16 in_ch = 2,496 cycles
  ├─ L2_ACC:      13 col × 4 batch × 16 in_ch = 832 cycles (decision)
  └─ L2_WRITE:    104 cycles
  
  SUBTOTAL: ~6,100+ cycles
  Dummy cycles: 46×16 + 19×64 = ~1,720 cycles
  Efficiency: (6100-1720)/6100 = 71% ✗ WORSE

Layer 3 (Dense1):
  ├─ L3_RD:       3 cycles × 52 groups × 6 batches = 936 cycles
  ├─ L3_EXE:      3 cycles × 52 × 6 = 936 cycles
  ├─ L3_ACC:      52 × 6 = 312 cycles (decision)
  └─ L3_OUT:      6 cycles (batch iteration)
  
  SUBTOTAL: ~2,200 cycles
  Dummy: 3×52×6 = 936 cycles
  Efficiency: (2200-936)/2200 = 57% ✗✗ VERY BAD

Layer 4 (Dense2):
  ├─ L4_RD:       5 cycles × 6 groups = 30 cycles
  ├─ L4_EXE:      3 cycles × 6 = 18 cycles
  ├─ L4_ACC:      6 cycles (decision)
  └─ L4_OUT:      1 cycle
  
  SUBTOTAL: ~60 cycles
  Dummy: 5×6 = 30 cycles
  Efficiency: (60-30)/60 = 50% ✗✗ TERRIBLE

─────────────────────────────────────────────────────────────
GRAND TOTAL: ~8,700+ cycles

Dummy cycles: ~2,600 cycles (WASTED waiting for BRAM)
Overall efficiency: (8700-2600)/8700 = 70%

⚠️ CONCLUSION: ~30% cycle budget lost to BRAM latency hiding!
```

### Throughput at Different Clock Speeds

```
Assume clk period = 15.4 ns (65 MHz - Xilinx max)

Layer 1:  394 cycles × 15.4 ns = 6.07 µs
Layer 2: 6100 cycles × 15.4 ns = 93.9 µs
Layer 3: 2200 cycles × 15.4 ns = 33.9 µs
Layer 4:   60 cycles × 15.4 ns = 0.92 µs

TOTAL: ~135 µs per inference
Throughput: 1 image / 135 µs = 7,407 images/sec (MNIST only!)

Speedup if eliminate BRAM latency (ping-pong buffer):
  New total: 8700 - 2600 = 6100 cycles = 93.9 µs
  Speedup: 135/93.9 = 1.43× faster
```

---

## 4. RESOURCE UTILIZATION ESTIMATE

### Xilinx Artix-7 (XC7A100T - nhỏ, phổ biến)
```
Available:
  - LUTs: 63,400
  - FFs:  126,800
  - BRAM: 135 (each 36 Kb)

Current Design (Worst Case):
  ├─ cnn_fsm:           ~500 LUTs (26 states, complex combinational)
  ├─ addr_gen:          ~1,200 LUTs (arithmetic, mux trees)
  ├─ cache_ctrl:        ~400 LUTs (small latches)
  ├─ pe_array (8×PE):   ~4,000 LUTs (8 MACs, pipeline)
  ├─ maxpool_ctrl:      ~600 LUTs (comparators, mux)
  ├─ psum_fc_ctrl:      ~2,000 LUTs (logic)
  ├─ psum_ff storage:   3,328 LUTs (conv2_psum: 1,664 FF × 2 LUT/FF)
  │                   + 384 LUTs (dense1_psum: 192 FF × 2 LUT/FF)
  │                   + 832 LUTs (conv2_out: 416 FF × 2 LUT/FF)
  └─ top-level:         ~500 LUTs
  
  SUBTOTAL: ~13,800 LUTs (22% utilization) - ACCEPTABLE

FFs:
  ├─ Counters:          ~30 FFs
  ├─ State regs:        ~100 FFs
  ├─ Psum storage:      ~2,000 FFs (conv2 + dense1 + conv2_out)
  ├─ PE pipelines:      ~1,500 FFs (8 PEs × 3-stage pipeline × 9 signals)
  └─ Misc caches:       ~200 FFs
  
  SUBTOTAL: ~3,800 FFs (3% utilization) - VERY SLACK

BRAM:
  ├─ BRAM_IF1:          1 BRAM (36 Kb)
  ├─ BRAM_IF2:          1 BRAM
  ├─ BRAM_W1/W2/W3/W4:  4 BRAMs
  └─ (psum could move here): +1 BRAM if conv2_psum → BRAM
  
  SUBTOTAL: 6-7 BRAMs (5% utilization) - VERY SLACK

⚠️ VERDICT: Current design fits easily BUT wastes resources
           - Too many LUTs on logic (cnn_fsm)
           - Too many FFs on psum (should be BRAM)
           - Scaling to larger CNN will hit LUT wall faster
```

### Proposed Design (Estimate)

```
Generalized FSM:
  - 4-state loop instead of 26 states  → ~150 LUTs (70% reduction)
  - CSR block for config              → ~200 LUTs (added)
  - Subtotal FSM: ~350 LUTs

Streaming interface (AXI4-Stream):
  - Slave interface (pe_array side)    → ~300 LUTs
  - Master interface (cache_ctrl side) → ~300 LUTs
  - Subtotal: ~600 LUTs

Ping-pong buffer:
  - Dual i_cache + logic              → ~100 LUTs (same as single)
  - Subtotal: ~100 LUTs

BRAM-based psum:
  - RMW controller for BRAM           → ~400 LUTs
  - (save 3,328+384+832) = ~4,544 LUTs
  - Net: 400 - 4,544 = -4,144 LUTs saved!

NEW SUBTOTAL: 13,800 - 500 + 150 - 500 + 600 + 100 - 4,144 = 9,606 LUTs
Reduction: ~30% → much easier timing closure

FFs: 3,800 → 3,200 (save psum FFs)

BRAM: 6 → 8 (add 2 for BRAM-based psum + ping-pong)
```

---

## 5. KEY METRICS SUMMARY TABLE

| Metric | Current | Proposed | Improvement |
|--------|---------|----------|-------------|
| FSM States | 26 | 4+CSR | -85% states |
| LUTs (logic) | ~13,800 | ~9,600 | -30% |
| LUTs (FF-based psum) | ~4,544 | 0 | -100% |
| FFs | ~3,800 | ~3,200 | -16% |
| BRAMs | 6 | 8 | +2 (small) |
| Port width (max) | 13,312 bits | 32-64 bits (AXI) | -99% |
| Routing congestion | HIGH | LOW | Better timing |
| BRAM latency hiding | 70% efficiency | 95%+ efficiency | +35% faster |
| Scalability | Fixed 4 layers | N arbitrary layers | Unlimited |
| Code maintainability | LOW (26 states) | HIGH (generic loop) | Much better |

