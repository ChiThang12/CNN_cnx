# CHECKLIST HOÀN THIỆN SPEC - CNN ACCELERATOR v3

## 📋 HƯỚNG DẪN SỬ DỤNG

Dưới đây là danh sách **13 câu hỏi cốt lõi** cần phải trả lời để hoàn thiện spec v3.
Mỗi câu hỏi có:
- **Mô tả**: Giải thích tại sao câu hỏi quan trọng
- **Tuỳ chọn**: Các lựa chọn khả thi
- **Đánh dấu**: Checkbox để bạn tick
- **Ảnh hưởng**: Tác động lên thiết kế

---

# NHÓM 1: FSM KHÁI QUÁT HÓA

## Q1.1: Cơ sở tính toán chung cho tất cả lớp CNN

**Mô tả:**
Hiện tại, Conv1/Conv2 và Dense1/Dense2 được xử lý như những thực thể hoàn toàn khác nhau.
Để generalize FSM thành 4-state loop, cần biết:
- Có thể coi Dense layer như Conv với kernel 1×1 không?
- Hay phải có 2 loại PE khác nhau (ConvPE vs DensePE)?

**Tuỳ chọn:**

```
[ ] A. Dense = Conv 1×1 model
    └─ Ưu điểm: Dùng chung PE_3x3 (hoặc PE_1x1)
    └─ Nhược điểm: Dense tính toán khác (fully-connected, không spatial)
    └─ Hệ quả: Cần 1 PE class chung, logic shared

[ ] B. Dense ≠ Conv model (maintain separate)
    └─ Ưu điểm: Logic riêng biệt, dễ tối ưu cho từng loại
    └─ Nhược điểm: FSM sẽ có 2 branch lớn (Conv & Dense)
    └─ Hệ quả: Cần 2 PE classes (ConvPE, DensePE)

[ ] C. Hybrid approach (Dense dùng ConvPE với special mode)
    └─ Ưu điểm: Tối ưu giữa A và B
    └─ Nhược điểm: PE logic phức tạp hơn
    └─ Hệ quả: 1 parameterized PE class + mode selector
```

**Câu trả lời được chọn:** _______________

**Ảnh hưởng trên thiết kế:**
- Nếu A hoặc C: FSM có thể dùng 4-state loop chung
- Nếu B: FSM cần 6-8 state (Conv branch + Dense branch)

---

## Q1.2: Bộ thanh ghi cấu hình (CSR) cần chứa gì?

**Mô tả:**
CSR là "cấu hình thời chạy" cho mỗi lớp. Khi chuyển lớp, chỉ cần nạp CSR mới thay vì viết lại FSM.
Danh sách đề xuất:

```
Yêu cầu (MUST-HAVE):
  [✓] KERNEL_SIZE       (1, 3, 5, 7, ...)
  [✓] STRIDE            (1, 2, 3, ...)
  [✓] INPUT_CHANNELS    (1, 8, 16, 32, ...)
  [✓] OUTPUT_CHANNELS   (16, 32, 48, 2, ...)
  [✓] INPUT_WIDTH       (8, 15, ...)
  [✓] INPUT_HEIGHT      (8, 15, ...)
  [✓] PADDING           (0, 1, 2, ...)

Tùy chọn (NICE-TO-HAVE):
  [ ] ACTIVATION_MODE       (NONE, RELU, TANH, SIGMOID, ...)
  [ ] QUANTIZATION_MODE     (NONE, INT8, FIXED_POINT, ...)
  [ ] QUANTIZATION_SCALE    (bit shift, scaling factor)
  [ ] USE_BIAS              (0=no, 1=add bias)
  [ ] BATCH_NORM_MODE       (pre-activation, post-activation)
  [ ] WEIGHT_LAYOUT         (row-major, col-major, interleaved)
  [ ] OUTPUT_DESTINATION    (IF1 BRAM, IF2 BRAM, accumulator)

Tùy chọn (NICE-TO-HAVE, quản lý):
  [ ] LAYER_ID              (0..255, debug purposes)
  [ ] INTERRUPT_ENABLE      (interrupt sau layer)
  [ ] PROFILING_ENABLE      (measure cycle count, power)
```

**Hãy đánh dấu CSR nào là MUST-HAVE:**
```
MUST-HAVE CSRs (tối thiểu để hoạt động):
  KERNEL_SIZE, STRIDE, INPUT_CHANNELS, OUTPUT_CHANNELS,
  INPUT_WIDTH, INPUT_HEIGHT, PADDING, ...
  (thêm vào)

NICE-TO-HAVE CSRs (tùy tuỳ):
  ...
```

**Ảnh hưởng trên thiết kế:**
- Mỗi CSR thêm: +1-2 multiplexer, +overhead storage
- CSR số lượng: ảnh hưởng kích thước control bus từ CPU/DMA
- Số lượng bit: ảnh hưởng độ phức tạp arithmetic (offset calculation)

---

## Q1.3: Mục tiêu hỗ trợ bao nhiêu lớp tối đa?

**Mô tả:**
Quyết định này ảnh hưởng tới cách load CSR config.

**Tuỳ chọn:**

```
[ ] A. Fixed 4 layers (MNIST = 2 Conv + 2 Dense)
    └─ Ưu điểm: Simple, CSRs pre-loaded at compile-time
    └─ Nhược điểm: Chỉ cho MNIST, không reusable cho CNN khác
    └─ Hệ quả: CSR là static arrays, không cần config register

[ ] B. Dynamic 4-16 layers (VGG16, ResNet-like)
    └─ Ưu điểm: Reusable cho nhiều CNN architecture
    └─ Nhược điểm: Cần layer config table (firmware/memory)
    └─ Hệ quả: CSR loader hardware (read layer_idx, load CSR)

[ ] C. Unlimited layers (theoretical limit)
    └─ Ưu điểm: Maximum flexibility
    └─ Nhược điểm: Cần sophisticated config management (OS-like)
    └─ Hệ quả: Complete control plane redesign, may need CPU integration
```

**Câu trả lời được chọn:** _______________

**Ảnh hưởng trên thiết kế:**
- A: Simple, FSM tạo layer_idx là enum (hardcoded)
- B: CSR register file (memory) + layer iterator
- C: Full control plane (beyond scope của hardware-only design)

---

# NHÓM 2: GIAO TIẾP STREAMING

## Q2.1: Băng thông dữ liệu yêu cầu (data width)?

**Mô tả:**
Data width của AXI4-Stream port quyết định:
- Cycle delay (khi chuyển từ BRAM sang cache)
- Điểm cân bằng giữa throughput & routing complexity

**Phân tích hiện tại:**
```
Layer 1 (Conv1):
  i_cache load = 96 bytes / 4 cycles = 24 bytes/cycle
  Equivalence: 192 bits/cycle (if AXI width = 192)
  
Layer 2 (Conv2):
  i_cache load = 45 bytes / 45 cycles = 1 byte/cycle
  Equivalence: 8 bits/cycle (bottleneck!)
  → Nếu AXI width > 8 bits: có thể prefetch multiple pixels
  
Typical options:
  - 32-bit: 1 word = 4 pixels/cycle (good for Layer1, overkill for Layer2)
  - 64-bit: 2 words = 8 pixels/cycle
  - 128-bit: 4 words = 16 pixels/cycle
  - 256-bit: 8 words = 32 pixels/cycle (bandwidth overkill)
```

**Tuỳ chọn:**

```
[ ] A. 32-bit AXI4-Stream
    └─ Ưu điểm: Standard, easy to implement, Xilinx/Altera tools support
    └─ Nhược điểm: Layer2 bottleneck (need 45 cycles to load 45 bytes)
    └─ Hệ quả: BRAM latency hiding bị giảm
    └─ LUT cost: ~300 LUTs (simple handshake)

[ ] B. 64-bit AXI4-Stream
    └─ Ưu điểm: Better for Layer2 (can prefetch 2 pixels in parallel)
    └─ Nhược điểm: Routing more complex
    └─ Hệ quả: Layer2 load < 45 cycles
    └─ LUT cost: ~350 LUTs (still simple)

[ ] C. 128-bit AXI4-Stream
    └─ Ưu điểm: Excellent for Layer1 (load i_cache in <2 cycles)
    └─ Nhược điểm: Significant routing, higher power
    └─ Hệ quả: Potential bandwidth underutilization for small layers
    └─ LUT cost: ~400 LUTs

[ ] D. Dual 32-bit ports (parallel data paths)
    └─ Ưu điểm: Flexible, can load from 2 BRAMs in parallel
    └─ Nhược điểm: More complex control, 2× handshake logic
    └─ Hệ quả: Good for large convolutions
    └─ LUT cost: ~500 LUTs (2× controller)
```

**Câu trả lời được chọn:** _______________

**Ảnh hưởng trên thiết kế:**
- Data width → determines tdata[N:0] bus in AXI4-Stream
- Affects prefetch strategy (how many cycles to load full cache)
- Determines load balancing between layers

---

## Q2.2: Loại giao tiếp nên dùng?

**Mô tả:**
AXI4 Standard có 2 flavor: AXI4-Full (most features) vs AXI4-Stream (simplified).

**Tuỳ chọn:**

```
AXI4-Stream (recommended):
┌────────────────┬────────────────────────────┐
│ Signal         │ Purpose                    │
├────────────────┼────────────────────────────┤
│ ACLK           │ Clock (shared)             │
│ ARESETN        │ Reset (active-low)         │
│ TDATA[N:0]     │ Data payload               │
│ TVALID         │ Data valid (source)        │
│ TREADY         │ Ready to accept (sink)     │
│ TLAST          │ Last beat in burst         │
│ TKEEP[N/8:0]   │ Byte valid strobes         │
│ TUSER[M:0]     │ Custom metadata (optional) │
└────────────────┴────────────────────────────┘

[ ] A. AXI4-Stream (minimal set)
    └─ Use: TDATA, TVALID, TREADY, TLAST only
    └─ Cost: ~300 LUTs handshake logic
    └─ Benefit: Simple, standard, reusable

[ ] B. AXI4-Stream (with TKEEP)
    └─ Use: TDATA, TVALID, TREADY, TLAST, TKEEP
    └─ Cost: +50 LUTs for byte strobing logic
    └─ Benefit: Support variable-length transfers (e.g., unaligned pixels)

[ ] C. AXI4-Stream (with TUSER)
    └─ Use: TDATA, TVALID, TREADY, TLAST, TKEEP, TUSER
    └─ Cost: +100 LUTs for metadata handling
    └─ Benefit: Can carry layer_id, batch_id, etc. (useful for debug)

[ ] D. AXI4-Full (write/read path, like AXI3)
    └─ Use: Full write (AWADDR, WDATA, WRESP) + read (ARADDR, RDATA)
    └─ Cost: +800 LUTs (full protocol)
    └─ Benefit: Supports out-of-order transactions, more flexible addressing
    └─ Downside: Overkill for simple streaming

[ ] E. Custom handshake (not standard)
    └─ Use: Simple valid/ready + data
    └─ Cost: ~150 LUTs (minimal)
    └─ Benefit: Minimal overhead
    └─ Downside: Proprietary, hard to integrate into larger SoC
```

**Câu trả lời được chọn:** _______________

**Ảnh hưởng trên thiết kế:**
- A (minimal): Fast development, standard compliance
- B (TKEEP): Support for unaligned or variable-width data
- C (TUSER): Good for debug & multi-layer tracking
- D (Full): Overkill unless you need fancy features
- E (custom): Fast development, but limits reusability

---

## Q2.3: Cơ chế backpressure (tready=0)?

**Mô tả:**
Khi PE bận (chưa sẵn nhận dữ liệu), cache_ctrl phải làm gì?

**Tuỳ chọn:**

```
[ ] A. Blocking mode (cache_ctrl waits)
    └─ FSM stays in FETCH_IFMP state until tready=1
    └─ Cost: Simple, no extra state
    └─ Benefit: Automatic flow control
    └─ Risk: FSM can deadlock if tready never goes high

[ ] B. FIFO mode (cache_ctrl buffers)
    └─ Cache_ctrl has small FIFO (2-4 entries)
    └─ If FIFO full, FSM stalls; otherwise continues
    └─ Cost: +200-300 LUTs for FIFO
    └─ Benefit: Decouples cache and PE, handles burst traffic
    └─ Risk: Requires FIFO management (empty/full detection)

[ ] C. Non-blocking mode (data loss on backpressure)
    └─ If tready=0, cache_ctrl ignores & moves on
    └─ Cost: 0 LUTs
    └─ Benefit: Never stalls
    └─ Risk: MASSIVE bug if happens (data corruption guaranteed)
    └─ Not recommended unless you're SURE tready is always 1
```

**Câu trả lời được chọn:** _______________

**Ảnh hưởng trên thiết kế:**
- A: Simple flow control (recommended for most cases)
- B: Decoupled producer-consumer (good for pipelined designs)
- C: Error-prone, only use if 100% confident backpressure won't happen

---

# NHÓM 3: PING-PONG BUFFER & ADDRESS GENERATION

## Q3.1: BRAM dual-access capability?

**Mô tả:**
Ping-pong buffer strategy depends on whether you can read from BRAM_IF1 while writing to another location in same cycle.

**Tuỳ chọn:**

```
[ ] A. Dual-port BRAM (read port A + write port B)
    └─ Configuration: 1 BRAM_IF1 with 2 ports
    │  ├─ Port A (read):  addr_read, dout_A (current layer)
    │  └─ Port B (write): addr_write, din_B (layer output)
    └─ Cost: BRAM stays 1, control logic +100 LUTs
    └─ Benefit: Single BRAM, can overlap read & write
    └─ Constraint: Must manage address conflict (same BRAM, different port)

[ ] B. Separate BRAMs (BRAM_IF1 for read, BRAM_IF1_W for write)
    └─ Configuration: 2 separate BRAMs
    │  ├─ BRAM_IF1 (read):  input features for current layer
    │  └─ BRAM_IF1_W (write): output/intermediate results
    └─ Cost: +1 BRAM (total 7 instead of 6)
    └─ Benefit: No address conflict, parallel access
    └─ Drawback: More BRAM usage, more area

[ ] C. Single-port BRAM (sequential access)
    └─ Configuration: 1 BRAM_IF1, priority mux (read vs write)
    │  ├─ Read: addr_read → priority check
    │  ├─ Write: addr_write → priority check
    │  └─ In same cycle: one succeeds, other waits
    └─ Cost: +50 LUTs for priority mux
    └─ Benefit: Minimal BRAM, standard design
    └─ Constraint: Must be careful with pipeline hazards (RAW, WAW)
```

**Câu trả lời được chọn:** _______________

**Ảnh hưởng trên thiết kế:**
- A (dual-port): More flexible, but requires dual-port BRAM (Xilinx RAMB18E1 supports this)
- B (separate): Guaranteed no conflict, but uses more area
- C (single-port): Minimal area, but needs careful hazard management in FSM

---

## Q3.2: Decoupled address generation (value)?

**Mô tả:**
Current design has 1 monolithic addr_gen.v (600 LOC). Proposal: tách thành 4 instances
(addr_gen_w1, addr_gen_w2, addr_gen_w3, addr_gen_w4).

**Tuỳ chọn:**

```
[ ] A. Keep monolithic (status quo)
    └─ Pro: Single module, all logic in one place
    └─ Con: Hard to understand (600 LOC), difficult to debug
    └─ Scalability: Adding layers → harder to extend

[ ] B. Tách thành 4 instances (one per weight BRAM)
    └─ Pro: Modular, each gen handles one weight type
    │       ├─ addr_gen_w1: only W1 (Conv1 weights)
    │       ├─ addr_gen_w2: only W2 (Conv2 weights)
    │       ├─ addr_gen_w3: only W3 (Dense1 weights)
    │       └─ addr_gen_w4: only W4 (Dense2 weights)
    └─ Con: Need port mux / dispatcher (small overhead)
    └─ Benefit: Easy to verify (each module ~150 LOC), easy to reuse
    └─ Cost: +100 LUTs for mux logic

[ ] C. Tách + make parametric (addr_gen #(.BRAM_ID(0)))
    └─ Pro: Single parametrized module, generate 4 copies
    │       Easier to maintain (1 source, 4 instances)
    │       Easy to add 5th/6th weight BRAM if needed
    └─ Con: More complex parameter logic
    └─ Benefit: Best scalability (N BRAMs = N instances)
    └─ Cost: +150 LUTs (slightly more than B)

[ ] D. Fully datapath decoupling (RAM-adjacent address gen)
    └─ Pro: Place each addr_gen_i next to BRAM_i physically
    │       Lower routing congestion (shorts nets)
    │       Easier timing closure
    └─ Con: Requires placement constraints (Vivado .xdc)
    └─ Benefit: Physical efficiency, lower power
    └─ Cost: No additional LUTs, but requires place&route tuning
```

**Câu trả lời được chọn:** _______________

**Ảnh hưởng trên thiết kế:**
- A: Simplicity, but maintainability issues
- B: Good modularity, small overhead
- C: Best for generalization (future-proof)
- D: Physical optimization (Advance level)

---

# NHÓM 4: MEMORY-BASED ACCUMULATION

## Q4.1: BRAM vs SRAM vs FF for psum storage?

**Mô tả:**
Hiện tại: conv2_psum[4][13][8] = 13K flip-flops. 
Need to reduce này từ FF → memory-based.

**Tuỳ chọn:**

```
Storage Option     | Density | Latency | Power | Cost (LUT) | Tech Support
───────────────────┼─────────┼─────────┼───────┼────────────┼──────────────
FF (status quo)    | LOW     | 0 cy    | HIGH  | 4,544      | Universal
BRAM (Block RAM)   | VERY ↑  | 1-2 cy  | LOW   | 0 (use 1B) | FPGA standard
SRAM (Scratchpad)  | HIGH    | 0 cy    | MED   | 0 (use 1B) | ASIC only
Distributed RAM    | MED     | 0 cy    | MED   | 500-1000   | Xilinx only
LUT RAM            | LOW     | 0 cy    | LOW   | 2000-3000  | Xilinx SRL16
───────────────────┴─────────┴─────────┴───────┴────────────┴──────────────

[ ] A. BRAM (Xilinx RAMB18E1 or similar)
    └─ Size: 18 Kb or 36 Kb per BRAM
    │  ├─ Current psum total: ~15 Kb (conv2 13K + dense1 1.5K)
    │  └─ Fits in: 1× 18Kb BRAM (or 1× 36Kb dual-port)
    └─ Latency: 1 cycle (read) + 1 cycle (write) = 2 cycles RMW
    └─ Cost: Use 1 existing BRAM (no additional FF waste)
    └─ Benefit: Industry standard, free (BRAM already on FPGA)
    └─ Trade-off: 1-2 cycle latency hidden by ping-pong buffer
    └─ RECOMMENDATION: ★★★★★ (Best for FPGA)

[ ] B. Distributed RAM (Xilinx SRL16 shift register + LUT)
    └─ Size: 16×32-bit = 512 bytes per SRL
    │  ├─ Current psum total: ~15 Kb = 15 × 1024 / 8 = 1,920 bytes
    │  └─ Need: ~4 SRLs
    └─ Latency: 0 cycles (combinational)
    └─ Cost: ~1,500 LUTs (vs 4,544 for FF)
    └─ Benefit: Faster (no latency), same density as BRAM
    └─ Trade-off: Still uses LUTs (not free)
    └─ RECOMMENDATION: ★★★ (Good if BRAM constrained)

[ ] C. SRAM (ASIC only, not available on FPGA)
    └─ Size: 15 Kb SRAM macro
    └─ Latency: 0 cycles (combinational or 1-cycle depending on design)
    └─ Cost: FREE (part of process, area cost only)
    └─ Benefit: Highest density, lowest power (ASIC advantage)
    └─ Trade-off: Only available if porting to ASIC
    └─ RECOMMENDATION: ★★★★★ (Best for ASIC, n/a for FPGA)

[ ] D. Hybrid (BRAM for conv2, keep FF for dense1)
    └─ Rationale: conv2_psum is large (13K), dense1 is small (1.5K)
    │  ├─ Store conv2_psum in BRAM
    │  └─ Keep dense1_psum as FF (small, fast)
    └─ Cost: 1 BRAM + 384 LUTs (FF for dense1)
    └─ Benefit: Best of both worlds
    └─ Trade-off: Slightly more complex control
    └─ RECOMMENDATION: ★★★★ (Good compromise)
```

**Câu trả lời được chọn:** _______________

**Ảnh hưởng trên thiết kế:**
- A (BRAM): Standard, proven, +1-2 cycle latency hidden by ping-pong
- B (Distributed RAM): Good alternative if BRAM limited
- C (SRAM): Best for ASIC, not applicable to FPGA
- D (Hybrid): Practical middle-ground

---

## Q4.2: RMW (Read-Modify-Write) latency tolerance?

**Mô tả:**
Nếu accumulator dùng BRAM, RMW pattern sẽ có latency:

```
Cycle 0: Issue READ_ADDR ← addr_calc()
Cycle 1: BRAM returns old_psum ← MEM[addr]
Cycle 2: Compute new_psum ← old_psum + pe_out[i]
Cycle 3: Issue WRITE_ADDR/WRITE_DATA ← same addr / new_psum
Cycle 4: BRAM stores (internal, no acknowledgment)

Total: 4 cycles per accumulation

Can you tolerate this latency in the pipeline?
```

**Tuỳ chọn:**

```
[ ] A. 0-cycle RMW preferred (impossible with BRAM, but achievable with FF/SRAM)
    └─ Means: Can't use BRAM for RMW
    └─ Must use: FF or Distributed RAM
    └─ Cost: +4,500 LUTs (back to current design)
    └─ Benefit: No latency overhead
    └─ Verdict: Defeats the purpose of migration

[ ] B. 1-2 cycle RMW acceptable (partially hidden by pipelining)
    └─ Mechanism: While waiting for BRAM read, PE can compute next layer
    │  ├─ Cycle 0-1: Read from BRAM
    │  ├─ Cycle 1-2: PE computes (overlapped with read latency)
    │  └─ Cycle 2-3: Write to BRAM
    └─ Cost: BRAM + small latch buffer
    └─ Benefit: Mostly masked, minimal cycle overhead
    └─ Verdict: Recommended

[ ] C. 3-4 cycle RMW (acceptable if overall throughput improves)
    └─ Mechanism: FSM must stall PE when BRAM not ready
    │  ├─ If pe_out arrives but BRAM still busy → stall PE
    │  └─ Stall counter in FSM tracks this
    └─ Cost: +100 LUTs for stall logic, minimal cycle loss
    └─ Benefit: Still much better than current FF approach (0 latency but huge area)
    └─ Verdict: Acceptable trade-off

[ ] D. >4 cycle RMW (not acceptable)
    └─ Means: BRAM is too slow for this design
    └─ Verdict: Should not use BRAM (use FF or Distributed RAM instead)
```

**Câu trả lời được chọn:** _______________

**Ảnh hưởng trên thiết kế:**
- A: Must stick with FF/Distributed RAM (no migration benefit)
- B: Perfect, BRAM is viable, latency masked
- C: Acceptable, small FSM changes needed
- D: BRAM not suitable, reconsider SRAM or FF

---

## Q4.3: BRAM layout & organization?

**Mô tả:**
If you choose BRAM for psum, how should data be organized inside?

```
Scenario: conv2_psum[4][13][8] = 4×13×8 = 416 entries, 32-bit each

BRAM layout options:
```

**Tuỳ chọn:**

```
[ ] A. Single BRAM, sequential layout
    Address map:
      ADDR[0..415]:   conv2_psum[0][0][0..7]   (batch 0, col 0, PE 0-7)
      ADDR[8..15]:    conv2_psum[0][1][0..7]   (batch 0, col 1, PE 0-7)
      ...
      ADDR[416..431]: conv2_psum[3][12][0..7]  (batch 3, col 12, PE 0-7)
      
    Calculation: addr = batch*104 + col*8 + pe_id (104 = 13×8 per batch)
    
    Cost: 1× 36Kb BRAM
    Benefit: Simple addressing
    Risk: Single BRAM bottleneck (only 1 read + 1 write per cycle)
    Verdict: ★★★ (OK for sequential access)

[ ] B. Dual BRAM, bank by batch
    Address map:
      BRAM0: conv2_psum[0][*][*] + conv2_psum[2][*][*]  (even batches)
      BRAM1: conv2_psum[1][*][*] + conv2_psum[3][*][*]  (odd batches)
      
    Benefit: Can read/write different batches in parallel
    Risk: More complex address routing
    Cost: 2× 18Kb BRAMs (total ~1 BRAM)
    Verdict: ★★★★ (Good for parallelism)

[ ] C. Interleaved BRAM, bank by PE
    Address map:
      BRAM0: conv2_psum[*][*][0,1] (PE 0,1)
      BRAM1: conv2_psum[*][*][2,3] (PE 2,3)
      BRAM2: conv2_psum[*][*][4,5] (PE 4,5)
      BRAM3: conv2_psum[*][*][6,7] (PE 6,7)
      
    Benefit: All 8 PEs can read/write concurrently (if each BRAM has 2 ports)
    Risk: Very complex address generation (need 8 addresses in parallel)
    Cost: 4× 18Kb BRAMs (might be overkill)
    Verdict: ★★ (Complex, only if max parallelism needed)

[ ] D. Hybrid layout (separate conv2 & dense1)
    Address map:
      BRAM0 (36Kb): conv2_psum[4][13][8] + padding
      BRAM1 (36Kb): dense1_psum[6][8] + conv2_out[416] + padding
      
    Benefit: Clear separation, easy to manage
    Cost: 2× 36Kb BRAMs
    Drawback: Over-allocation of space
    Verdict: ★★★★ (Clear organization, slight waste)
```

**Câu trả lời được chọn:** _______________

**Ảnh hưởng trên thiết kế:**
- A: Simplest, but sequential bottleneck
- B: Good balance of complexity & parallelism
- C: Maximum parallelism, but very complex
- D: Clear organization, minor resource waste

---

# NHÓM 5: PARAMETERIZATION & GENERICS

## Q5.1: Scale NUM_PE to what range?

**Mô tả:**
Hiện tại: `parameter NUM_PE = 8;` (fixed).
Proposal: Make it parameterizable, but what's the target range?

**Tuỳ chọn:**

```
[ ] A. Fixed 8 PEs (status quo)
    └─ Simplicity: No parameterization overhead
    └─ Scalability: Can't scale
    └─ Cost: As-is design

[ ] B. Support 4, 8, 16 PEs
    └─ Rationale: 4 PEs (small FPGA), 8 PEs (standard), 16 PEs (large FPGA)
    └─ Change: Generate block for 8 PEs → change to NUM_PE
    └─ Cost: Minimal (just change parameter)
    └─ Bandwidth need: 2×/4× higher for 16 PEs
    └─ Verdict: ★★★★ (Practical range)

[ ] C. Support arbitrary NUM_PE (power of 2: 1, 2, 4, 8, 16, 32)
    └─ Rationale: Ultimate flexibility
    └─ Change: All hardcoded 8s → NUM_PE throughout pe_array.v
    └─ Cost: +20% logic (dynamic mux for NUM_PE)
    └─ Bandwidth: 32× PE = 4 GB/s bandwidth! (overkill)
    └─ Verdict: ★★★ (Good for research, overkill for practice)

[ ] D. Support 8 or 16 PEs only
    └─ Rationale: Most CNNs need either 8 or 16 PEs
    └─ Change: Simple conditional generate (if NUM_PE == 8 ... else ...)
    └─ Cost: Minimal
    └─ Verdict: ★★★★★ (Practical, most likely)
```

**Câu trả lời được chọn:** _______________

**Ảnh hưởng trên thiết kế:**
- A: Keep as-is
- B: Good for different FPGA sizes
- C: Maximum flexibility
- D: Most practical (8 or 16 only)

---

## Q5.2: Support multiple kernel sizes (1×1, 3×3, 5×5)?

**Mô tả:**
Hiện tại: PE_3x3 (hardcoded 3×3).
Proposal: Support 1×1, 3×3, 5×5 kernels (and possibly more).

**Tuỳ chọn:**

```
[ ] A. Fixed 3×3 (status quo)
    └─ MNIST Conv1 & Conv2: both 3×3
    └─ Simplicity: No parameterization
    └─ Cost: PE_3x3.v as-is

[ ] B. Support 1×1 and 3×3 only
    └─ Rationale: Most common kernels in modern CNN
    │  ├─ 1×1: bottleneck in ResNet, efficient
    │  └─ 3×3: standard convolution
    └─ Change: PE_NxN with parameter KERNEL_SIZE ∈ {1, 3}
    └─ Cost: +150 LUTs (conditional logic for 1×1 vs 3×3)
    └─ Benefit: Support ResNet-like architecture
    └─ Verdict: ★★★★★ (Most practical)

[ ] C. Support 1×1, 3×3, 5×5
    └─ Rationale: Inception modules use 5×5
    └─ Change: PE_NxN with parameter KERNEL_SIZE ∈ {1, 3, 5, 7}
    └─ Cost: +300 LUTs (more conditional logic)
    └─ Benefit: Support Inception, Xception architectures
    └─ Verdict: ★★★ (Good for flexibility)

[ ] D. Fully parametric kernel (any odd size)
    └─ Rationale: Ultimate flexibility
    └─ Change: PE_NxN with parameter KERNEL_SIZE (1, 3, 5, 7, 9, ...)
    └─ Cost: +500+ LUTs (complex multiplier tree, memory)
    └─ Benefit: Support any kernel size
    └─ Verdict: ★★ (Complex, slow, not practical for fixed architecture)
```

**Câu trả lời được chọn:** _______________

**Ảnh hưởng trên thiết kế:**
- A: Keep as-is (MNIST only)
- B: Best practical (1×1 & 3×3 most common)
- C: Good for modern architectures
- D: Too complex for typical use

---

## Q5.3: Activation function support?

**Mô tả:**
Hiện tại: relu_en, quan_en (boolean flags).
Proposal: Support multiple activation functions (ReLU, Tanh, Sigmoid, None).

**Tuỳ chọn:**

```
[ ] A. Boolean flags (status quo)
    └─ relu_en:  ReLU or passthrough
    └─ quan_en:  Quantize or passthrough
    └─ Cost: 0 LUTs (already in design)
    └─ Flexibility: Limited (can't mix ReLU + others)

[ ] B. Activation enum (mode select)
    └─ ACTIVATION_MODE ∈ {NONE, RELU, TANH, SIGMOID}
    └─ Implementation: 2-bit selector + mux tree
    └─ Cost: +80 LUTs per PE (8 PEs = 640 LUTs total)
    └─ Benefit: Easy to add new activations
    └─ Verdict: ★★★★ (Good balance)

[ ] C. Activation LUT-based (arbitrary function)
    └─ Idea: Store activation curve in small BRAM (32×8 LUT)
    │  ├─ Output = LUT[relu_out[12:7]]
    │  └─ Supports any monotonic curve
    └─ Cost: 1 BRAM + 50 LUTs
    └─ Benefit: Can implement custom activation (e.g., ELU, GELU)
    └─ Verdict: ★★★ (Advanced, but useful)

[ ] D. No activation (compute layer, apply outside PE)
    └─ Idea: PE always outputs raw sum, no activation in hardware
    └─ Cost: 0 LUTs (simplest)
    └─ Benefit: Simple, but must do activation in software (slow)
    └─ Verdict: ★ (Not recommended for inference)
```

**Câu trả lời được chọn:** _______________

**Ảnh hưởng trên thiết kế:**
- A: Keep as-is
- B: Recommended (good flexibility with modest cost)
- C: Advanced (overkill for most cases)
- D: Not practical

---

# 📋 TÓRTÓM TẤT CHECKLIST

Sau khi trả lời hết 13 câu hỏi, hãy điền vào bảng dưới:

| Nhóm | Câu | Tuỳ chọn | Trạng thái |
|------|-----|---------|-----------|
| FSM | Q1.1 | _____ | [ ] |
| FSM | Q1.2 | KERNEL, STRIDE, IN_CH, OUT_CH, WIDTH, HEIGHT, PADDING, + _____ | [ ] |
| FSM | Q1.3 | _____ | [ ] |
| Stream | Q2.1 | _____ bits | [ ] |
| Stream | Q2.2 | _____ | [ ] |
| Stream | Q2.3 | _____ | [ ] |
| Buffer | Q3.1 | _____ | [ ] |
| Buffer | Q3.2 | _____ | [ ] |
| Accum | Q4.1 | _____ | [ ] |
| Accum | Q4.2 | _____ | [ ] |
| Accum | Q4.3 | _____ | [ ] |
| Generic | Q5.1 | _____ | [ ] |
| Generic | Q5.2 | _____ | [ ] |
| Generic | Q5.3 | _____ | [ ] |

---

# 🎯 NEXT STEPS AFTER Q&A

Sau khi hoàn thành checklist:

1. **Tạo Specification Document (Verilog Comments)**
   - Update cnn_fsm.v, cnn_top.v với parameter declarations
   - Add CSR definitions (nếu lựa chọn CSR)

2. **Design RTL Generalized FSM**
   - Refactor 26-state → 4-state loop
   - Add CSR loader

3. **Implement AXI4-Stream Interface**
   - Design slave port (pe_array side)
   - Design master port (cache_ctrl side)

4. **Prototype Ping-Pong Buffer**
   - Dual buffer + pointer management

5. **Refactor psum Storage**
   - Move from FF → BRAM-based RMW

6. **Parameterize PE Array**
   - Make NUM_PE, KERNEL_SIZE configurable
   - Implement activation function enum

7. **Testbench & Verification**
   - Update cnn_tb.v for new architecture
   - Add regression tests for each layer config

---

**Document này sẽ được update khi có feedback từ design team.**
