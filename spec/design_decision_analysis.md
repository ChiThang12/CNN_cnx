# 🎯 CNN ACCELERATOR v3 - PHÂN TÍCH QUY ĐỊNH THIẾT KẾ

**Ngày**: 12 Tháng 6, 2026  
**Trạng thái**: ✅ Tất cả 13 câu hỏi đã được trả lời  
**Người quyết định**: Design Team  
**Tài liệu liên quan**: qa_checklist_spec_v3.md, architecture_improvement_analysis.md  

---

## 📊 TÓM TẮT QUY ĐỊNH

| Nhóm | Câu | Lựa Chọn | Xác Nhận |
|------|-----|---------|---------|
| **FSM** | Q1.1 | **C** - Hybrid (Dense dùng ConvPE special mode) | ✅ |
| | Q1.2 | **7 MUST-HAVE CSR** + Optional features | ✅ |
| | Q1.3 | **B** - Dynamic 4-16 layers | ✅ |
| **Streaming** | Q2.1 | **D** - Dual 32-bit AXI4-Stream ports | ✅ |
| | Q2.2 | **A** - Minimal AXI4-Stream (TDATA, TVALID, TREADY, TLAST) | ✅ |
| | Q2.3 | **B** - FIFO mode backpressure handling | ✅ |
| **Buffer** | Q3.1 | **B** - Separate BRAMs (BRAM_IF1 read, BRAM_IF1_W write) | ✅ |
| | Q3.2 | **D** - Fully datapath decoupling (RAM-adjacent addr_gen) | ✅ |
| **Accumulator** | Q4.1 | **A** - BRAM-based psum storage | ✅ |
| | Q4.2 | **B** - 1-2 cycle RMW latency tolerance | ✅ |
| | Q4.3 | **D** - Hybrid layout (separate conv2 & dense1 BRAMs) | ✅ |
| **Generics** | Q5.1 | **D** - Support 8 or 16 PEs only | ✅ |
| | Q5.2 | **B** - Support 1×1 and 3×3 kernels | ✅ |
| | Q5.3 | **B** - Activation enum (NONE, RELU, TANH, SIGMOID) | ✅ |

---

## 🔍 PHÂN TÍCH CHI TIẾT MỖI QUYẾT ĐỊNH

### NHÓM 1: FSM KHÁI QUÁT HÓA

#### Q1.1: Hybrid Approach (Dense = ConvPE + Special Mode) ✅
```
Quyết định: C - Hybrid approach
Lý do:
  • Dense layer = Conv 1×1 (toán học tương đương)
  • Nhưng không spatial (N×1 instead of 3×3)
  • → Dùng PE_NxN with KERNEL_SIZE = 1 mode
  
Tác động thiết kế:
  ✓ FSM có thể dùng 4-state loop chung cho mọi layer
  ✓ PE_NxN sẽ có conditional logic:
      if (KERNEL_SIZE == 1)
          // Dense computation (no spatial loop)
      else if (KERNEL_SIZE == 3)
          // Conv 3×3 computation
  
  ✓ Logic complexity: +80-100 LUTs (manageable)
  ✓ Reusability: 100% (mọi layer dùng chung code path)
  
Xác nhận:
  → Phù hợp với mục tiêu generalization
  → Tối ưu hóa code reuse
  → Giảm FSM states (26 → 4)
```

#### Q1.2: CSR MUST-HAVE Set ✅
```
Quyết định:
  MUST-HAVE (7):
    1. KERNEL_SIZE       (8-bit: 1, 3, 5, 7, ...)
    2. STRIDE            (8-bit: 1, 2, 3, 4, ...)
    3. INPUT_CHANNELS    (16-bit: 1-8192)
    4. OUTPUT_CHANNELS   (16-bit: 1-8192)
    5. INPUT_WIDTH       (16-bit: image width in pixels)
    6. INPUT_HEIGHT      (16-bit: image height in pixels)
    7. PADDING           (8-bit: 0, 1, 2, ...)
  
  OPTIONAL (Selected):
    ✓ ACTIVATION_MODE    (2-bit: 00=NONE, 01=RELU, 10=TANH, 11=SIGMOID)
    ✓ QUANTIZATION_MODE  (2-bit: 00=NONE, 01=INT8, 10=FIXED_POINT)
    ✓ USE_BIAS           (1-bit)
  
Thiết kế CSR Register File:
  ┌─────────────────────────────────────────────────────┐
  │ CSR Offset | Name           | Width | Purpose       │
  ├─────────────────────────────────────────────────────┤
  │ 0x00       | KERNEL_SIZE    | 8     | Kernel size   │
  │ 0x01       | STRIDE         | 8     | Stride        │
  │ 0x02       | PADDING        | 8     | Padding       │
  │ 0x03       | IN_CHANNELS    | 16    | Input ch      │
  │ 0x04       | OUT_CHANNELS   | 16    | Output ch     │
  │ 0x05       | IN_WIDTH       | 16    | Input width   │
  │ 0x06       | IN_HEIGHT      | 16    | Input height  │
  │ 0x07       | ACTIVATION     | 2     | Activation fn │
  │ 0x08       | QUANT          | 2     | Quantization  │
  │ 0x09       | LAYER_CTRL     | 8     | Layer control │
  ├─────────────────────────────────────────────────────┤
  │ TOTAL SIZE: 40 bits × 10 registers = 50 bytes      │
  └─────────────────────────────────────────────────────┘

Tác động:
  • CSR total: 50 bytes = 400 bits (manageable)
  • Control bus width: 32-bit AXI → 2-3 writes per layer config
  • Register file overhead: +150 LUTs (small)
  • Firmware interface: Simple (write CSR 0x00-0x09, then assert START)

Xác nhận:
  → Đủ để config mọi layer type
  → Không quá phức tạp
  → Cân bằng flexibility + simplicity
```

#### Q1.3: Dynamic 4-16 Layers ✅
```
Quyết định: B - Dynamic 4-16 layers
Lý do:
  • VGG16 = 13 Conv + 3 Dense = 16 layers
  • ResNet = tới 152 layers (nhưng chúng ta target 16 max)
  • MNIST = 4 layers (2 Conv + 2 Dense)
  • → 4-16 is practical sweet spot
  
Cơ chế CSR Loading:
  ┌──────────────────────────────────┐
  │ Software (firmware/driver):      │
  │ ├─ layer_config[0] = {K=3,S=1..}│
  │ ├─ layer_config[1] = {K=3,S=1..}│
  │ ├─ ...                            │
  │ └─ layer_config[15] = {...}      │
  └──────────────────────────────────┘
          ↓ (load via CSR bus)
  ┌──────────────────────────────────┐
  │ Hardware CSR Register File:      │
  │ ├─ CSR[0x00-0x09] = layer_0 cfg │
  │ └─ ...                            │
  └──────────────────────────────────┘
          ↓ (FSM reads CSR when next_layer)
  ┌──────────────────────────────────┐
  │ FSM State Machine (4-state loop):│
  │ FETCH_IFMP → FETCH_WEIGHT →      │
  │   EXECUTE → WRITE_BACK → ...     │
  │   (then CSR_LOAD next layer)     │
  └──────────────────────────────────┘

  Implementation Detail:
  • FSM has counter: layer_idx ∈ [0..15]
  • After WRITE_BACK, if (layer_idx < max_layers-1):
      - Read next CSR config from register file
      - FSM loop restart with new KERNEL_SIZE, STRIDE, etc.
      - else: FSM → DONE

Tác động:
  • Memory requirement: 16 × 50 bytes = 800 bytes CSR memory
  • Can store in:
    ✓ On-chip BRAM (small, ~1 BRAM)
    ✓ CPU memory (AXI-accessible)
  • No impact on PE array logic
  • FSM adds 1 extra state (CSR_LOAD) or embedded in FSM loop
  
Xác nhận:
  → Practical range (4-16 layers)
  → Covers MNIST to VGG16
  → Firmware-friendly (simple CSR table)
  → Future-proof (if need >16, add more CSR memory)
```

---

### NHÓM 2: GIAO TIẾP STREAMING

#### Q2.1: Dual 32-bit AXI4-Stream Ports ✅
```
Quyết định: D - Dual 32-bit ports
Lý do:
  Analyze bandwidth needs:
  
  Layer 1 (Conv1): 96 bytes / 4 cycles = 24 bytes/cycle
                   = 192 bits/cycle needed
                   → Single 32-bit port: 192/32 = 6 cycles/byte (OK)
  
  Layer 2 (Conv2): 45 bytes / 45 cycles = 1 byte/cycle
                   = 8 bits/cycle (bottleneck)
                   → Single 32-bit port: overkill but fine
  
  Dual 32-bit: 2 × 32 = 64 bits/cycle = 8 bytes/cycle
  → Layer 1: load 96 bytes in ~12 cycles (vs 4 cycles → 3× speedup)
  → Layer 2: load 45 bytes in ~6 cycles (vs 45 cycles → 7.5× speedup!)
  
Architecture:
  ┌─────────────────────────────────────────┐
  │ BRAM_IF1 (Input Feature Maps)           │
  │ ├─ Port A (Data):  tdata0[31:0]        │
  │ └─ Port B (Data):  tdata1[31:0]        │
  └─────────────────────────────────────────┘
          ↓                    ↓
  ┌──────────────────────────────────────────┐
  │ AXI4-Stream Master (Dual ports)          │
  │ Port 0:                  Port 1:         │
  │  ├─ tvalid0              ├─ tvalid1     │
  │  ├─ tready0              ├─ tready1     │
  │  ├─ tdata0[31:0]         ├─ tdata1[31:0]│
  │  └─ tlast0               └─ tlast1       │
  └──────────────────────────────────────────┘
          ↓                    ↓
  ┌──────────────────────────────────────────┐
  │ PE Array (Consumer)                      │
  │ ├─ tready0 = (state==FETCH && !cache_A_full)
  │ ├─ tready1 = (state==FETCH && !cache_B_full)
  │ └─ When both valid: load cache in parallel
  └──────────────────────────────────────────┘

Advantage:
  ✓ Dual data streams → 2× bandwidth when both available
  ✓ Supports ping-pong (fill cache_A while reading cache_B)
  ✓ Standard AXI4-Stream with 32-bit width (easy on FPGA)
  ✓ Power balanced (lower freq than single 64-bit port)

Cost:
  • 2× handshake logic: +150 LUTs
  • 2× data buffers (in pe_array): +50 LUTs
  • Total streaming overhead: ~200 LUTs

Xác nhận:
  → Optimal bandwidth/cost tradeoff
  → Supports dual-BRAM read
  → Scales well with ping-pong architecture
```

#### Q2.2: Minimal AXI4-Stream ✅
```
Quyết định: A - Minimal (TDATA, TVALID, TREADY, TLAST only)
Lý do:
  • MNIST v3 không cần byte strobing (TKEEP) - luôn full words
  • Không cần metadata (TUSER) trong v3
  • TLAST đủ để đánh dấu end-of-burst
  • Simplicity > Features
  
Interface Definition:
  
  AXI4-Stream Master (cache_ctrl → pe_array):
  ┌─────────────────────────────────────────┐
  │ Signal       | Width | Direction | Desc │
  ├─────────────────────────────────────────┤
  │ ACLK         | 1     | input     | Clk  │
  │ ARESETN      | 1     | input     | Rst  │
  │ TVALID       | 1     | output    | Data valid │
  │ TREADY       | 1     | input     | Ready  │
  │ TDATA[31:0]  | 32    | output    | Data payload │
  │ TLAST        | 1     | output    | Last beat in burst │
  └─────────────────────────────────────────┘
  
  Handshake Protocol (3-state):
  
  Cycle N:    TVALID=1, TDATA=data[N], TREADY=?
              ├─ If TREADY=1: data accepted
              │   - pe_array captures TDATA
              │   - cache_ctrl can advance to next
              └─ If TREADY=0: backpressure
                  - pe_array not ready
                  - cache_ctrl holds state & retries
  
  Cycle N+1:  TVALID=1, TDATA=data[N+1], TLAST=0
              (continue sending data)
  
  Cycle M:    TVALID=1, TDATA=data[M], TLAST=1
              (last data beat, end of transaction)
              
  Cycle M+1:  TVALID=0 (no more data until next layer)

RTL Implementation:
  
  cache_ctrl.v:
  ```verilog
  always @(posedge ACLK) begin
      if (state == FETCH_IFMP) begin
          TVALID <= (counter < num_words);
          TDATA <= BRAM_DOUT;
          TLAST <= (counter == num_words - 1);
          if (TVALID && TREADY) begin
              counter <= counter + 1;
              if (TLAST) state <= FETCH_WEIGHT;
          end
      end
  end
  ```
  
  pe_array.v:
  ```verilog
  always @(posedge ACLK) begin
      if (TVALID && TREADY) begin
          i_cache[cache_idx] <= TDATA;
          cache_idx <= cache_idx + 1;
      end
  end
  
  assign TREADY = (state == FETCH && !cache_full);
  ```

Cost:
  • Handshake logic: ~100 LUTs
  • Data pipeline: ~50 LUTs
  • Total: ~150 LUTs

Xác nhận:
  → Đơn giản nhưng đủ
  → Dễ verify (simple state machine)
  → Future-proof (can add TKEEP/TUSER later)
  → Standard AXI4-Stream (reusable)
```

#### Q2.3: FIFO Mode Backpressure ✅
```
Quyết định: B - FIFO mode
Lý do:
  • Decouples cache_ctrl and pe_array
  • Handles burst traffic intelligently
  • More robust than blocking
  
Architecture:
  
  ┌─────────────────────────────────────────┐
  │ cache_ctrl                              │
  │  (AXI4-Stream Master)                   │
  └─────────────────────────────────────────┘
            ↓ TVALID, TDATA
  ┌─────────────────────────────────────────┐
  │ Input FIFO (2-4 entries)                │
  │  ├─ write_ptr (cache_ctrl side)        │
  │  ├─ read_ptr (pe_array side)           │
  │  └─ [entry0][entry1][entry2][entry3]  │
  └─────────────────────────────────────────┘
            ↓ tready signal (if FIFO has space)
  ┌─────────────────────────────────────────┐
  │ pe_array                                │
  │  (AXI4-Stream Slave)                    │
  └─────────────────────────────────────────┘

FIFO Logic:
  
  cache_ctrl side:
  ```verilog
  wire fifo_full = (next_write_ptr == read_ptr);
  assign TREADY_FROM_FIFO = !fifo_full;
  
  if (TVALID && TREADY_FROM_FIFO) begin
      fifo[write_ptr] <= TDATA;
      write_ptr <= write_ptr + 1;
  end
  ```
  
  pe_array side:
  ```verilog
  wire fifo_empty = (read_ptr == write_ptr);
  wire fifo_valid = !fifo_empty;
  
  if (fifo_valid && consumer_ready) begin
      output_data <= fifo[read_ptr];
      read_ptr <= read_ptr + 1;
  end
  ```

Behavior:
  • If pe_array busy (TREADY=0):
    → FIFO buffers 2-4 words from BRAM
    → cache_ctrl continues until FIFO full
    → No FSM stall (better utilization)
  
  • If pe_array catches up:
    → FIFO drains
    → TREADY goes high again
    → Cache_ctrl resumes data push

Benefits:
  ✓ Smooth pipeline without artificial stalls
  ✓ Handles bursty traffic
  ✓ Decoupled clock domains possible (future)
  
Cost:
  • FIFO 4-entry × 32-bit: 128 bits FF = ~256 LUTs
  • Or: use BRAM (1 BRAM slice, much cheaper)
  • Control logic: ~50 LUTs
  • Total: ~150 LUTs (if BRAM FIFO) or ~300 LUTs (if FF FIFO)

Recommendation:
  → Use BRAM-based FIFO (save LUTs)
  → 4-entry depth sufficient for MNIST
  → Can scale to 8-16 entries for larger CNNs

Xác nhận:
  → Robust backpressure handling
  → Decoupled producer/consumer
  → Scales well to pipelined designs
```

---

### NHÓM 3: PING-PONG BUFFER & ADDRESS GEN

#### Q3.1: Separate BRAMs (BRAM_IF1 Read, BRAM_IF1_W Write) ✅
```
Quyết định: B - Separate BRAMs
Lý do:
  • Avoid port conflict (critical path issue)
  • Simpler design (no mux arbitration)
  • Parallel read+write (ping-pong friendly)
  
Memory Architecture:
  
  ┌──────────────────────────────────────┐
  │ Input Feature Map Storage            │
  ├──────────────────────────────────────┤
  │ BRAM_IF1 (Read-only during layer):   │
  │  • 36 Kb capacity                    │
  │  • Holds current layer input features│
  │  • Address: row_id[4:0], col[9:0]   │
  │  • Output: dout_IF1[31:0]            │
  │  • Read latency: 1 cycle             │
  │                                      │
  │ BRAM_IF1_W (Write-only):             │
  │  • 36 Kb capacity                    │
  │  • Holds previous layer output       │
  │  • (to become next layer input)      │
  │  • Address: row[4:0], col[9:0]      │
  │  • Write latency: 0 (buffered)       │
  │  • Write port: din_IF1_W[31:0]      │
  └──────────────────────────────────────┘

Timing & Data Flow:
  
  Layer N execution:
  ┌──────────────────────────────────┐
  │ Cycle T:  Read from BRAM_IF1     │
  │           BRAM_IF1[addr] → dout  │
  │           (latency = 1 cycle)    │
  │ Cycle T+1: dout arrives at PE    │
  │           PE processes dout      │
  │           (MACs, accumulation)   │
  │ Cycle T+2: PE output ready       │
  │           PE[i] → BRAM_IF1_W[addr]
  │           (write new value)      │
  └──────────────────────────────────┘
  
  When Layer N+1 starts:
  │ BRAM_IF1_W (now contains layer N output)
  │ becomes the new input for layer N+1
  │ (swap role: previous write port = new read port)
  └──────────────────────────────────────────

Ping-Pong Pattern (Pseudo):
  
  Layer 0:
    Read from BRAM_IF1 (layer input)
    Write to BRAM_IF1_W (layer output)
  
  Layer 1:
    Read from BRAM_IF1_W (previous output)
    Write to BRAM_IF1 (new output)
  
  Layer 2:
    Read from BRAM_IF1 (previous output)
    Write to BRAM_IF1_W (new output)
  
  ... (continue alternating)

Cost:
  • Extra BRAM: +1 (total 6→7 BRAMs)
  • Control logic: ~100 LUTs (addr mux, role swap)
  • Address generator: no change (still works)
  
Advantage:
  ✓ Zero port conflict (no arbitration needed)
  ✓ No RAW/WAW hazards (separate ports)
  ✓ Clean data flow (previous output = next input)
  ✓ Easy to debug (clear separation)

Xác nhận:
  → Robust, simple design
  → Fits Xilinx FPGA capability (plenty BRAM)
  → Scales well to larger networks
```

#### Q3.2: Fully Datapath Decoupling (RAM-Adjacent Addr Gen) ✅
```
Quyết định: D - Fully datapath decoupling
Lý do:
  • Place each addr_gen instance next to its BRAM
  • Minimize routing delay (critical timing path)
  • Better physical design
  
Physical Layout (Vivado):
  
  ┌─────────────────────────────────────────┐
  │ FPGA Floor Plan (schematic):            │
  │                                          │
  │  [BRAM_W1]  ←→ [addr_gen_w1]          │
  │  [BRAM_W2]  ←→ [addr_gen_w2]          │
  │  [BRAM_IF1] ←→ [addr_gen_if1]         │
  │  [BRAM_IF2] ←→ [addr_gen_if2]         │
  │                                          │
  │  All others on opposite side (clock   │
  │  distribution, FSM, PE array)         │
  └─────────────────────────────────────────┘

Placement Constraints (.xdc):
  
  ```tcl
  # Assign BRAM_W1 to specific FPGA site
  set_property BRAM_ADDR_LOCS {BLOCKRAM_X10Y20} [get_cells bram_w1]
  
  # Assign addr_gen_w1 nearby (same column or adjacent)
  set_property LOC SLICE_X20Y20 [get_cells addr_gen_w1]
  
  # Set timing constraint for critical path
  set_false_path -from [get_cells addr_gen_w1] \
                  -to [get_cells bram_w1] \
                  -through [get_nets *addr*] -max 2ns
  ```

Benefit:
  ✓ Short routing distance → low delay
  ✓ Lower routing congestion (distributed)
  ✓ Better power (shorter nets = less toggle)
  ✓ Easier timing closure (Fmax++).
  
Cost:
  • No LUT increase (same logic)
  • Requires Vivado constraint file (.xdc)
  • Requires place & route iteration

Implementation Notes:
  
  addr_gen_w1.v (example):
  ```verilog
  module addr_gen_w1 #(
      parameter WIDTH = 16,
      parameter DEPTH = 2048
  ) (
      input clk, rst,
      input [7:0] layer_id,
      input [7:0] in_ch,
      input [7:0] out_ch,
      
      output reg [WIDTH-1:0] addr,
      output reg valid
  );
      // Layer-specific address generation
      // Only for W1 (Conv1 weights)
      
      always @(posedge clk) begin
          case (layer_id)
              8'd0: begin // Conv1 layer
                  addr <= in_ch * 9 + out_ch;
                  valid <= 1;
              end
              default: valid <= 0;
          endcase
      end
  endmodule
  ```

Scalability:
  • Current: 4 address generators (W1, W2, IF1, IF2)
  • Future: If add W5, addr_gen_w5 placed adjacent to BRAM_W5
  • No global impact (modular design)

Xác nhận:
  → Advanced placement optimization
  → Necessary for timing closure on large designs
  → Scales well to next-gen (larger PE array, more layers)
```

---

### NHÓM 4: BRAM-BASED ACCUMULATOR

#### Q4.1: BRAM for Psum Storage ✅
```
Quyết định: A - BRAM-based psum
Lý do:
  • Current FF storage: 13,312 bits (conv2_psum) = ~4,500 LUTs
  • BRAM alternative: 1 × 36Kb BRAM (costs 0 LUTs)
  • Savings: 4,500 LUTs freed for other logic
  
Memory Calculation:
  
  conv2_psum[4][13][8]: 4 batches × 13 cols × 8 PEs × 32-bit
                        = 4,160 entries × 32-bit
                        = 132 Kb data
                        Requires: 4 × 36Kb BRAMs = 144 Kb (adequate)
  
  Alternative layout:
  dense1_psum[6][8]: 6 batches × 8 neurons × 32-bit
                     = 48 entries × 32-bit
                     = 1.5 Kb data
                     (fits in 1 BRAM easily)

BRAM Storage Mapping:
  
  Option 1 - Single BRAM (interleaved):
  Address space: 12 bits (0-4095)
  
    ADDR[11:0] = batch[1:0] × 416 + col[3:0] × 32 + pe[2:0]
    
    Example:
      conv2_psum[1][3][5] → ADDR = 1×416 + 3×32 + 5
                                   = 416 + 96 + 5
                                   = 517
      
    Advantage: Single BRAM, simple addressing
    Disadvantage: Sequential access only (1 read+1 write per cycle)
  
  Option 2 - Dual BRAM (banked):
  
    BRAM0: conv2_psum[0,2][*][*] (even batches)
    BRAM1: conv2_psum[1,3][*][*] (odd batches)
    
    Advantage: Can read different batches in parallel
    Disadvantage: Requires 2 addresses, more complex routing

Recommendation: Option 1 (single BRAM)
  • MNIST conv2 has sequential access pattern
  • 1 read + 1 write per cycle sufficient
  • Simpler implementation

RMW Operation (Read-Modify-Write):
  
  Traditional (FF-based):
    psum_in = ff[addr];  // Combinatorial
    
  BRAM-based:
    Cycle N:   ADDR_READ = addr;        // Request read
    Cycle N+1: psum_in = BRAM[ADDR_READ]; // Data arrives (1-cycle latency)
    Cycle N+2: new_psum = psum_in + pe_out[i];
    Cycle N+3: ADDR_WRITE = addr;       // Request write
    Cycle N+4: BRAM[ADDR_WRITE] = new_psum;
    
    Total RMW latency: 4 cycles (manageable with ping-pong)

Cost:
  • BRAM: +1 (total 6→7 BRAMs)
  • RMW controller: +150 LUTs
  • Net savings: 4,500 - 150 = 4,350 LUTs freed! 🎉

Xác nhận:
  → Massive resource savings
  → Enables scaling to larger PE arrays
  → Standard FPGA design pattern
  → Timing-friendly (less combinatorial logic)
```

#### Q4.2: 1-2 Cycle RMW Latency Tolerance ✅
```
Quyết định: B - 1-2 cycle RMW latency tolerance
Lý do:
  • BRAM has inherent 1-cycle latency
  • Dual-port BRAM can read & write same cycle
  • Ping-pong buffer hides most latency
  
Latency Analysis:
  
  Scenario 1: Sequential access (no dependency)
    Cycle N:   Read BRAM[addr0] → dout_A
               (latency window)
    Cycle N+1: dout_A arrives, PE computes
               Write BRAM[addr1] ← result
               (independent from read, overlapped)
    
    Effective latency: 0 (hidden by next layer's computation)
  
  Scenario 2: Read-after-write (dependency)
    Cycle N:   Write BRAM[addr] ← value1
    Cycle N+1: Read BRAM[addr] → need value1
               But BRAM[addr] = value1 already
               (1-cycle latency absorbed by ping-pong)
    
    Effect: 1 stall cycle (acceptable)

FSM Hazard Management:
  
  To avoid RAW/WAW hazards:
  
  ```verilog
  // Prevent reading addr before write completes
  always @(*) begin
      if (write_pending && (read_addr == write_addr))
          pe_stall = 1'b1; // Stall PE, retry next cycle
      else
          pe_stall = 1'b0;
  end
  ```

Ping-Pong Mitigation:
  
  Layer N:
    Read buffer_A → Process → Write to buffer_B
    (4-cycle pipeline, BRAM latency hidden within)
  
  Transition N→N+1:
    • buffer_B now contains layer N output
    • Read buffer_B for layer N+1
    • Write to buffer_A
    • No stall (buffers ready when needed)

Timing Estimate:
  
  Without BRAM optimization:
    Max combinational path: BRAM_READ → PE → accumulator
                          ≥ 2 ns
    Fmax: ~500 MHz (with pipelining)
  
  With BRAM + pipeline:
    Max path: PE_COMPUTE
            ≤ 1.5 ns
    Fmax: 650+ MHz! (better timing)

Xác nhận:
  → 1-2 cycle tolerance is acceptable
  → Ping-pong fully hides most latency
  → FSM hazard logic manageable
  → Results in faster Fmax
```

#### Q4.3: Hybrid Layout (Separate conv2 & dense1) ✅
```
Quyết định: D - Hybrid layout
Lý do:
  • conv2_psum[4][13][8] = 132 Kb (dense access)
  • dense1_psum[6][8] = 1.5 Kb (sparse access)
  • Keep separate for better address generation & timing

Memory Allocation:
  
  BRAM0 (36 Kb): conv2_psum (416 entries)
                 • Address: 9 bits (0-415)
                 • Width: 32 bits
                 • Usage: 13 Kb / 36 Kb = 36% (efficient)
                 • Future: can scale to 768 entries (larger conv)
  
  BRAM1 (36 Kb): dense1_psum (48 entries) +
                 psum_misc (spare)
                 • Address: 6 bits (0-47) for dense1
                 • Width: 32 bits
                 • Usage: 1.5 Kb / 36 Kb = 4% (very slack)
                 • Future: can add dense2, conv3 psum here

Address Generation:
  
  conv2_psum_ctrl.v:
  ```verilog
  always @(*) begin
      conv2_addr = {batch[1:0], col[3:0], pe[2:0]};
      // 2-bit + 4-bit + 3-bit = 9-bit address
  end
  ```
  
  dense1_psum_ctrl.v:
  ```verilog
  always @(*) begin
      dense1_addr = {batch[2:0], neuron[2:0]};
      // 3-bit + 3-bit = 6-bit address
  end
  ```

Scalability:
  
  If future CNN needs:
  • conv3_psum[8][7][16]: 896 entries → needs separate BRAM
  • dense2_psum[1024]: too large for shared BRAM
  
  Then add:
  BRAM2: conv3_psum (896 entries)
  BRAM3: dense2_psum (1024 entries)
  
  Total: 6 + 4 = 10 BRAMs (still within Artix-7 capacity of 135)

Cost:
  • 2 BRAMs: +2 (total 6→8)
  • Separate controllers: +50 LUTs each = +100 LUTs
  • Total overhead: ~100 LUTs (small)

Advantage:
  ✓ Clear organization (easy to debug)
  ✓ Optimized addressing (no conflict)
  ✓ Scales naturally to larger networks
  ✓ Power-efficient (address decoder split)

Xác nhận:
  → Clean, modular design
  → Future-proof allocation
  → Good balance of flexibility & simplicity
```

---

### NHÓM 5: PARAMETERIZATION

#### Q5.1: Support 8 or 16 PEs Only ✅
```
Quyết định: D - Support 8 or 16 PEs only
Lý do:
  • 8 PEs: good for small FPGA (Artix-7-50T)
  • 16 PEs: good for medium FPGA (Artix-7-100T, Kintex)
  • Most CNNs benefit from 8-16 PEs
  • Overkill beyond 16 (parallelism diminishes)

Design Implementation:
  
  pe_array.v (top-level):
  ```verilog
  module pe_array #(
      parameter NUM_PE = 8  // 8 or 16
  ) (
      ...
  );
      
      if (NUM_PE == 8) begin
          // 8 PEs configuration
          genvar i;
          for (i=0; i<8; i=i+1) begin
              PE pe_inst (
                  .id(i),
                  .kernel_size(KERNEL_SIZE),
                  ...
              );
          end
      end
      else if (NUM_PE == 16) begin
          // 16 PEs configuration
          genvar i;
          for (i=0; i<16; i=i+1) begin
              PE pe_inst (
                  .id(i),
                  .kernel_size(KERNEL_SIZE),
                  ...
              );
          end
      end
  endmodule
  ```

Resource Impact (16 PEs vs 8 PEs):
  
  | Component | 8 PE | 16 PE | Δ |
  |-----------|------|-------|---|
  | PE logic (MAC+ACC) | 8K LUT | 16K LUT | +8K |
  | Psum storage (FF) | 4.5K LUT | 9K LUT | +4.5K |
  | Control logic | 2K LUT | 2.5K LUT | +0.5K |
  | Total | 14.5K LUT | 27.5K LUT | +13K |
  | Util (Artix-100T) | 23% | 43% | +20% |
  
  Bandwidth requirement:
  • Instruction/config: 1 CSR set (same for both)
  • Data bandwidth: i_cache width stays 32-bit (bottleneck)
  • → 16 PEs may underutilize in memory-bound layers
  
  Recommendation:
  • Start with 8 PEs (conservative, proven)
  • Scale to 16 PEs if:
    - Bandwidth increased (larger BRAM width or dual ports)
    - Power budget allows
    - Timing closure OK

Scaling Path (Multi-PE):
  
  Parameter NUM_PE only affects:
  1. Generate block (PE instantiation)
  2. Output bus width: pe_out_flat[NUM_PE×32-1:0]
  3. Input mux: i_cache read ×NUM_PE
  4. Accumulator width: psum_in[NUM_PE×32-1:0]
  
  No FSM changes (loop-based, data-parallel)
  No BRAM address changes (same depth)
  
Cost:
  • 8↔16 toggle: Recompile, 5-minute synthesis
  • No design rework
  • No IP licensing issues

Xác nhận:
  → Practical 2-option approach
  → Covers small-to-medium FPGA targets
  → Minimizes design complexity
```

#### Q5.2: Support 1×1 and 3×3 Kernels ✅
```
Quyết định: B - Support 1×1 and 3×3 only
Lý do:
  • 1×1: bottleneck in ResNet, efficient (no spatial)
  • 3×3: standard convolution (MNIST Conv1/2)
  • 5×5+: Inception (future version, not v3)
  • Simplicity: logic stays manageable
  
PE_NxN Module Design:
  
  PE_NxN.v:
  ```verilog
  module PE_NxN #(
      parameter KERNEL_SIZE = 3,  // 1 or 3
      parameter DATA_WIDTH = 8,
      parameter WEIGHT_WIDTH = 8,
      parameter ACCUM_WIDTH = 32
  ) (
      input clk, rst,
      
      // Data inputs (depends on KERNEL_SIZE)
      input [KERNEL_SIZE*KERNEL_SIZE*DATA_WIDTH-1:0] pixel_in,
      input [KERNEL_SIZE*KERNEL_SIZE*WEIGHT_WIDTH-1:0] weight,
      
      // Control
      input [ACCUM_WIDTH-1:0] psum_in,
      input compute_en,
      
      // Output
      output reg [ACCUM_WIDTH-1:0] psum_out
  );
      
      // Multiplier tree (conditional)
      if (KERNEL_SIZE == 1) begin
          // 1×1 kernel: 1 multiplier (simple)
          wire [2*DATA_WIDTH-1:0] product = pixel_in × weight;
          always @(posedge clk) begin
              if (compute_en)
                  psum_out <= psum_in + product;
          end
      end
      else if (KERNEL_SIZE == 3) begin
          // 3×3 kernel: 9 multipliers + tree adder
          wire [8*2*DATA_WIDTH-1:0] products;
          genvar i;
          for (i=0; i<9; i=i+1) begin
              assign products[(i+1)*16-1:i*16] = 
                  pixel_in[(i+1)*8-1:i*8] × weight[(i+1)*8-1:i*8];
          end
          
          wire [ACCUM_WIDTH-1:0] sum_9 = 
              products[15:0] + products[31:16] + products[47:32] +
              products[63:48] + products[79:64] + products[95:80] +
              products[111:96] + products[127:112] + products[143:128];
          
          always @(posedge clk) begin
              if (compute_en)
                  psum_out <= psum_in + sum_9;
          end
      end
  endmodule
  ```

Logic Overhead:
  
  | Item | 1×1 | 3×3 | Delta |
  |------|-----|-----|-------|
  | Multipliers | 1 | 9 | +8 |
  | Adder tree | 1-stage | 4-stage | +3 stages |
  | Pipeline depth | 3 | 5 | +2 |
  | LUT per PE | 50 | 130 | +80 |
  | 8 PE array | 400 | 1040 | +640 |
  
  Justification:
  • 1×1 often needs higher KERNEL_SIZE for pooling/normalization
  • 3×3 most common in traditional CNNs
  • Future: add 5×5 in v4 if needed

CSR for Kernel Size:
  
  CSR[0x00] KERNEL_SIZE:
    00 = invalid
    01 = 1×1
    10 = 3×3
    11 = reserved (future 5×5)

FSM Impact:
  
  No change to FSM state machine!
  • Loop-based execution (data-parallel)
  • Kernel size handled in PE compute (different # of cycles)
  • FSM just waits for (compute_en && psum_ready)

Example: Conv Layer with Mixed Kernels
  
  Layer 0: KERNEL_SIZE=3, INPUT_CHANNELS=1, OUTPUT_CHANNELS=16
           → Uses PE_3x3 (9×MAC per cycle)
  
  Layer 1: KERNEL_SIZE=1, INPUT_CHANNELS=16, OUTPUT_CHANNELS=32
           → Uses PE_1x1 (1×MAC per cycle) with KERNEL_SIZE override
           → FSM counts differently (16 cycles instead of 1)

Performance:
  
  1×1 latency: 1 cycle (simpler)
  3×3 latency: 2-3 cycles (more complex)
  
  Throughput stays same per layer (FSM amortizes)

Xác nhận:
  → Practical kernel support
  → Covers ResNet + VGG architectures
  → Manageable logic overhead (+640 LUTs)
  → Future-extensible (5×5 in v4)
```

#### Q5.3: Activation Enum Mode Select ✅
```
Quyết định: B - Activation enum (2-bit selector)
Lý do:
  • Current: relu_en, quan_en (boolean flags)
  • Problem: Can't mix ReLU + Tanh
  • Solution: Enum mode selector (NONE/RELU/TANH/SIGMOID)
  • Cost: +80 LUTs per PE (manageable)
  
Activation Function Options:
  
  CSR[0x07] ACTIVATION_MODE (2-bit):
    00 = NONE (linear, pass-through)
    01 = RELU (max(0, x))
    10 = TANH (hyperbolic tangent)
    11 = SIGMOID (1/(1+exp(-x)))

RTL Implementation:
  
  activation_unit.v:
  ```verilog
  module activation_unit #(
      parameter DATA_WIDTH = 32,
      parameter MODE = 2'b00  // 00=NONE, 01=RELU, 10=TANH, 11=SIGMOID
  ) (
      input [DATA_WIDTH-1:0] data_in,
      output reg [DATA_WIDTH-1:0] data_out
  );
      
      always @(*) begin
          case (MODE)
              2'b00: data_out = data_in;  // NONE
              
              2'b01: data_out = (data_in[DATA_WIDTH-1] == 1'b1) ? 
                                32'h0 : data_in;  // RELU
              
              2'b10: data_out = tanh_lut(data_in);  // TANH (LUT-based)
              
              2'b11: data_out = sigmoid_lut(data_in);  // SIGMOID (LUT-based)
              
              default: data_out = data_in;
          endcase
      end
      
      // LUT for TANH/SIGMOID
      function [DATA_WIDTH-1:0] tanh_lut(input [DATA_WIDTH-1:0] x);
          // Lookup table: 256 entries, 8-bit resolution
          // data_out = TANH_LUT[x[10:2]]  (quantized)
          case (x[10:2])
              9'd0: tanh_lut = 32'h00000000;
              9'd1: tanh_lut = 32'h0000_0011;
              // ... 254 more entries
              9'd255: tanh_lut = 32'h0000_7FFF;
          endcase
      endfunction
      
      function [DATA_WIDTH-1:0] sigmoid_lut(input [DATA_WIDTH-1:0] x);
          // Similar LUT-based approach
          // data_out = SIGMOID_LUT[x[10:2]]
      endfunction
  endmodule
  ```

Integration with PE:
  
  PE_NxN.v (modified):
  ```verilog
  module PE_NxN #(
      parameter KERNEL_SIZE = 3,
      parameter ACTIVATION_MODE = 2'b00  // enum selector
  ) (
      ...
      input compute_en,
      output reg [ACCUM_WIDTH-1:0] psum_out
  );
      
      wire [ACCUM_WIDTH-1:0] psum_raw;
      wire [ACCUM_WIDTH-1:0] psum_activated;
      
      // Accumulation (ReLU/Tanh/Sigmoid applied after)
      assign psum_raw = psum_in + product_sum;
      
      // Activation unit instantiation
      activation_unit #(.MODE(ACTIVATION_MODE))
      act_inst (
          .data_in(psum_raw),
          .data_out(psum_activated)
      );
      
      always @(posedge clk) begin
          if (compute_en)
              psum_out <= psum_activated;  // Store activated result
      end
  endmodule
  ```

LUT Overhead Calculation:
  
  Per PE:
  • NONE mux: 2 LUT (selector)
  • RELU logic: 4 LUT (comparator + mux)
  • TANH_LUT: 128 LUT (256×8 ROM in distributed RAM)
  • SIGMOID_LUT: 128 LUT
  • Selector mux: 16 LUT (32-bit input select)
  • Total: ~250 LUT per PE (for full TANH/SIGMOID support)
  
  Optimization: Share LUT across all PEs
  • Single TANH_LUT (128×8 BRAM) for all 8 PEs
  • Single SIGMOID_LUT (128×8 BRAM)
  • Each PE just has selector logic (+50 LUT each)
  • Total: 50×8 + 1×BRAM + 1×BRAM = 400 LUT + 2 BRAM
  
  But for v3 MNIST:
  • Only ReLU needed (no Tanh/Sigmoid)
  • Can simplify: only RELU (4 LUT per PE)
  • Total: 32 LUT for 8-PE array

CSR Register:
  
  CSR[0x07] ACTIVATION_MODE (per layer):
  ```
  Format: 2'b[MODE_SELECT]
    2'b00 = NONE
    2'b01 = RELU
    2'b10 = TANH
    2'b11 = SIGMOID
  ```
  
  Firmware (pseudo-C):
  ```c
  csr[7] = (ACTIVATION_MODE << 0);
  ```

Performance Impact:
  
  RELU: 0 extra delay (comparator + mux, pipelined)
  TANH/SIGMOID: 1 extra cycle (LUT lookup → mux)
  
  FSM automatically accounts (waits for activate_valid)

Future Extensions:
  
  Could add:
  • ELU (Exponential Linear Unit)
  • GELU (Gaussian Error Linear Unit)
  • Swish (x × sigmoid(x))
  • LeakyReLU (α×x if x<0)
  
  Just add more case statements in activation_unit.v

Xác nhận:
  → Flexible activation support
  → Manageable LUT cost (if shared TANH/SIGMOID LUT)
  → Future-extensible
  → Good for modern architectures (ResNet, VGG use ReLU)
```

---

## 📈 TỔNG HỢP TÀI NGUYÊN v3

### Ước Tính LUT/FF/BRAM (v3 vs v2)

| Thành Phần | v2 (Hiện Tại) | v3 (Đề Xuất) | Δ | Ghi Chú |
|------------|---------------|--------------|---|---------|
| **Logic** | | | | |
| cnn_fsm | 500 | 150 | -70% | 26→4 states |
| addr_gen | 1,200 | 1,200 | 0% | Decoupled but same logic |
| cache_ctrl | 400 | 600 | +50% | +FIFO logic |
| pe_array (8×PE) | 4,000 | 4,640 | +16% | +activation enum |
| maxpool_ctrl | 600 | 600 | 0% | No change |
| psum_fc_ctrl | 2,000 | 400 | -80% | Logic only (BRAM stores data) |
| csr_ctrl | 0 | 200 | +200 | New CSR register file |
| AXI4-Stream | 0 | 300 | +300 | New interface |
| ping_pong_ctrl | 0 | 150 | +150 | New buffer mgmt |
| top-level | 500 | 600 | +20% | +mux, +routing |
| **TOTAL LOGIC** | **9,200** | **8,840** | **-4%** | Net savings! |
| | | | | |
| **Memory (FF)** | | | | |
| Psum FF storage | 4,544 | 0 | -100% | Moved to BRAM |
| Pipeline regs | 1,500 | 1,500 | 0% | No change |
| Control regs | 300 | 300 | 0% | No change |
| Misc | 200 | 200 | 0% | No change |
| **TOTAL FF** | **6,544** | **2,000** | **-69%** | Major reduction! |
| | | | | |
| **BRAM (36Kb)** | | | | |
| BRAM_IF1 | 1 | 1 | 0% | Input feature (read) |
| BRAM_IF1_W | 0 | 1 | +1 | Ping-pong write |
| BRAM_W1/W2/W3/W4 | 4 | 4 | 0% | Weight storage |
| BRAM_psum (conv2) | 0 | 1 | +1 | BRAM accumulator |
| BRAM_psum (dense1) | 0 | 1 | +1 | BRAM accumulator |
| FIFO (optional) | 0 | 1* | +1* | Optional FIFO |
| **TOTAL BRAM** | **6** | **9** | **+50%** | Still plenty |

\*FIFO can be implemented with FF instead (trade LUT for BRAM)

### Xilinx Artix-7-100T (63.4K LUT, 126.8K FF, 135 BRAM)

```
v2 Utilization:
  LUT:   9,200 / 63,400 = 14.5% (plenty slack)
  FF:    6,544 / 126,800 = 5.2% (very slack)
  BRAM:  6 / 135 = 4.4% (very slack)
  → Easy timing closure, room to scale

v3 Utilization:
  LUT:   8,840 / 63,400 = 13.9% (slightly better)
  FF:    2,000 / 126,800 = 1.6% (huge slack!)
  BRAM:  9 / 135 = 6.7% (still slack)
  → Even easier timing closure, freed resources for future expansion
```

---

## 🚀 LỘ TRÌNH PHÁT TRIỂN v3

### Phase 1: Specification & Planning (1 tuần)
- [ ] Confirm all Q&A decisions (THIS DOCUMENT)
- [ ] Create SPEC_v3.md (detailed Verilog spec)
- [ ] Create parameter list & CSR register map
- [ ] Create block diagram (RTL hierarchy)
- **Deliverable**: SPEC_v3.md + diagrams

### Phase 2: FSM Refactor (2 tuần)
- [ ] Implement 4-state generic loop (FETCH_IFMP → FETCH_WEIGHT → EXECUTE → WRITE_BACK)
- [ ] Implement CSR loader (read CSR registers, set layer config)
- [ ] Create testbench for FSM state transitions
- [ ] Verify layer-to-layer transitions (config swap)
- **Deliverable**: cnn_fsm_v3.v + cnn_fsm_tb.v

### Phase 3: Data Path (2 tuần)
- [ ] Implement AXI4-Stream slave (pe_array side)
- [ ] Implement AXI4-Stream master (cache_ctrl side)
- [ ] Implement FIFO backpressure buffer
- [ ] Implement ping-pong buffer controller
- [ ] Integration test with FSM
- **Deliverable**: axi4_stream_*.v + ping_pong_ctrl.v

### Phase 4: Memory Subsystem (2 tuần)
- [ ] Design BRAM RMW controller (for psum accumulation)
- [ ] Implement hazard detection (RAW/WAW)
- [ ] Replace psum_fc_ctrl.v with BRAM-based version
- [ ] Test RMW correctness (verify bit-accurate results)
- **Deliverable**: bram_psum_ctrl.v + test vectors

### Phase 5: Parameterization (1-2 tuần)
- [ ] Make PE_NxN parameterizable (KERNEL_SIZE ∈ {1,3})
- [ ] Parameterize activation functions (enum selector)
- [ ] Support NUM_PE ∈ {8, 16}
- [ ] Generate register file for CSR
- [ ] Test with different configurations
- **Deliverable**: PE_NxN.v + activation_unit.v + csr_reg.v

### Phase 6: Integration & Verification (2-3 tuần)
- [ ] Integrate all modules into cnn_top_v3.v
- [ ] Create comprehensive testbench
- [ ] Test MNIST network (4-layer)
- [ ] Test multi-layer config changes
- [ ] Verify performance (cycle count, throughput)
- [ ] Synthesis on Xilinx Artix-7-100T
- [ ] Timing analysis (Fmax, slack)
- **Deliverable**: cnn_top_v3.v + testbench + synthesis report

### Phase 7: Optimization & Documentation (1-2 tuần)
- [ ] Place & route optimization
- [ ] Create datasheet (Fmax, power, area)
- [ ] Document CSR register map
- [ ] Create design review presentation
- [ ] Finalize GitHub repo structure
- **Deliverable**: Design docs + P&R report

**Total Timeline: 11-15 tuần (~3 tháng)**

---

## ✅ VALIDATION CHECKLIST

Trước khi bắt đầu RTL:

- [ ] Tất cả 13 Q&A đã được trả lời & approved
- [ ] SPEC_v3.md được create & reviewed
- [ ] CSR register map defined
- [ ] Data path diagram drawn (AXI4-Stream, ping-pong)
- [ ] FSM state machine defined (4 states)
- [ ] Memory layout agreed (BRAM allocation)
- [ ] Team confident với technical direction
- [ ] Schedule approved by management
- [ ] Resources allocated (engineers, FPGAs, tools)

---

## 📚 NEXT DELIVERABLE

**Document tiếp theo cần create**: SPEC_v3.md
- Verilog parameter list (all #parameters)
- Port definitions (all module interfaces)
- CSR register map (offset, width, format)
- State machine details (4 states, transitions)
- BRAM address generation formulas
- Data format specifications
- Constraint file template (.xdc)

---

**Báo cáo hoàn tất**: 2026-06-12  
**Status**: ✅ READY FOR IMPLEMENTATION  
**Approval**: Design Team Lead Signature: ___________