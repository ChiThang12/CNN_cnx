# Phân Tích Kiến Trúc CNN Accelerator - Thiếu Sót & Câu Hỏi Cấu Trúc

## 📊 XÁC NHẬN THIẾU SÓT (100% CHÍNH XÁC)

### 1️⃣ FSM Không Tái Sử Dụng (CONFIRMED)
- **Con số**: 26 trạng thái cố định (IDLE→L1_RST→L1_RD_IFMP→...→L4_OUT→DONE)
- **Vấn đề**:
  - Mỗi thay đổi cấu trúc CNN (thêm lớp/thay kernel) → phải viết lại FSM từ đầu
  - Mã nguồn lớn, khó bảo trì, tăng độ phức tạp logic trên FPGA/ASIC
  - Không có cơ chế parameterization để tùy biến số lớp

---

### 2️⃣ Port Bus Cực Rộng (CONFIRMED)
```
Conv2 Partial Sums:  4×13×8×32 = 13,312 bits  ← KHỦNG KHIẾP
Dense1 Partial Sums: 6×8×32   = 1,536 bits
Conv2 Output:        416×8    = 3,328 bits
                     ─────────────────────────
                     TỔNG:     ~18KB dữ liệu
```
- **Vấn đề**:
  - Routing congestion trên chip
  - High power consumption (toggle activity)
  - Khó scale-up với các FPGA nhỏ hơn

---

### 3️⃣ BRAM Latency Kinh Điển (CONFIRMED)
- **Hiện tượng**: `counter == 0` là dummy cycle (wasteful)
- **Mục đích**: Chờ BRAM phản hồi (1 cycle latency)
- **Hiệu năng**: ~7% chu kỳ bị lãng phí × 4 lớp = **28% tổng chu kỳ thực**

---

### 4️⃣ Thanh Ghi Lưu Trữ Quá Lớn (CONFIRMED)
```verilog
// Từ psum_fc_ctrl.v:
reg signed [31:0] conv2_psum [0:3][0:12][0:7];     // 13,312 flip-flops
reg signed [31:0] dense1_psum [0:5][0:7];          // 1,536 flip-flops
reg [7:0] conv2_out [0:415];                       // 3,328 flip-flops
─────────────────────────────────────────────────────────
TOTAL: ~18K flip-flops (tiêu tốn tài nguyên không cần thiết)
```

---

## 🎯 NHỮNG CÂU HỎI CẦN LÀMRÕ ĐỂ HOÀN THIỆN SPEC

### **NHÓM 1: FSM KHÁI QUÁT HÓA**

#### Q1.1: Mô hình tính toán chung cho tất cả lớp?
```
Hiện tại: Conv1(3x3,16ch) → Conv2(3x3,32ch) → Dense1 → Dense2
Câu hỏi:
  • Có thể coi Dense layer như Conv với kernel 1×1 không?
  • Hay cần tách biệt logic xử lý Conv vs Dense?
  • Cần support bao nhiêu kiểu layer: [Conv, Dense, Activation, Pooling] ?
```

#### Q1.2: Control Status Registers (CSRs) nên chứa gì?
```
Đề xuất CSR set cho mỗi lớp:
  ✓ KERNEL_SIZE      (1x1, 3x3, 5x5, ...)
  ✓ STRIDE           (1, 2, ...)
  ✓ PADDING          (0, 1, ...)
  ✓ INPUT_CHANNELS   (8, 16, 32, ...)
  ✓ OUTPUT_CHANNELS  (16, 32, 48, ...)
  ✓ INPUT_WIDTH/HEIGHT
  ✓ ???

Câu hỏi:
  • Còn thiếu CSR nào quan trọng?
  • Có cần CSR cho activation function (ReLU/Tanh/None)?
  • Có cần CSR cho quantization (bit-width, scale factor)?
```

#### Q1.3: Số lượng lớp tối đa hỗ trợ?
```
Câu hỏi:
  • Mục tiêu: [2, 4, 8, 16, unlimited] lớp?
  • Có cấu trúc thư viện lớp tương tự PyTorch/Keras không?
  • Hay là máy trạng thái chỉ là "engine" - config hoàn toàn từ software?
```

---

### **NHÓM 2: GIAO TIẾP STREAMING (AXI4-Stream)**

#### Q2.1: Băng thông dữ liệu yêu cầu?
```
Hiện tại: Dữ liệu i_cache = 96 bytes/4 chu kỳ = 24 bytes/cycle
          Nếu dùng AXI4-Stream 32-bit:
          → 32-bit/cycle = 4 bytes/cycle ✗ KHÔNG ĐỦ
          
Câu hỏi:
  • Nên dùng data width bao nhiêu? [32, 64, 128, 256 bits]?
  • Có thể sử dụng multiple slave ports không (dual-channel cache fill)?
  • Latency tolerance: bao nhiêu cycle backpressure (tready=0) được chấp nhận?
```

#### Q2.2: Cơ chế handshake chi tiết?
```
AXI4-Stream chuẩn:  master_valid, master_ready, master_data[n:0]
                    + master_last, master_keep (optional)

Câu hỏi:
  • Có cần tkeep (byte strobing) hay luôn full transfer?
  • Có cần tlast signal để đánh dấu cuối burst không?
  • Có cần tuser field cho metadata (layer_id, batch_id) không?
  • AXI4-Stream có đủ hay nên dùng AXI4-Full (AWVALID/WREADY...)?
```

#### Q2.3: Cách maintain state giữa cycles?
```
Câu hỏi:
  • Nếu slave backpressure (master_ready=0), FSM tạm dừng hay tiếp tục?
  • Dữ liệu partial không gửi được lưu ở đâu (FIFO/Latch/...)?
  • Có cần CDC (Clock Domain Crossing) cho data path?
```

---

### **NHÓM 3: PING-PONG BUFFER & DECOUPLED ADDRESS GEN**

#### Q3.1: Cấu trúc Ping-Pong cụ thể?
```
Hiện tại: Single cache (i_cache[0:95], w_cache[0:71])
          + dummy cycle trách chờ BRAM

Đề xuất:  Buffer_A + Buffer_B với 2 pointer sets:
          - active_ptr   (PE đang đọc)
          - loading_ptr  (cache_ctrl đang fill)

Câu hỏi:
  • BRAM port có thể dual-access không (2 địa chỉ/cycle)?
  • Hay phải chia 2 BRAM riêng (BRAM_IF1_A, BRAM_IF1_B)?
  • Kích thước mỗi buffer (96 bytes mỗi cái) có ổn không?
  • Có cần 3 buffer (A,B,C) cho 3-stage pipeline không?
```

#### Q3.2: Address generator tách biệt?
```
Hiện tại: addr_gen.v monolithic (~600 dòng)
          xử lý W1, W2, W3, W4 cùng lúc

Đề xuất: Tách thành 4 instance nhỏ:
         - addr_gen_w1 (chuyên Conv1 weight)
         - addr_gen_w2 (chuyên Conv2 weight)
         - addr_gen_w3 (chuyên Dense1 weight)
         - addr_gen_w4 (chuyên Dense2 weight)

Câu hỏi:
  • Có lợi ích gì (modularity, reusability)?
  • Hay chỉ là tách logic để dễ đọc?
  • Cần có common "port mux" ở giữa không?
```

---

### **NHÓM 4: MEMORY-BASED ACCUMULATION (BRAM)**

#### Q4.1: Chọn lựa: FF vs BRAM vs SRAM?
```
Hiện tại: Toàn bộ psum lưu FF (13K+ flip-flops)

Tuỳ chọn:
  A) BRAM (Block RAM):      Dung lượng cao, trễ 1-2 cycle, power thấp ✓
  B) SRAM (Scratchpad):     Dung lượng cao, trễ 0 cycle, power trung bình
  C) LUT + Distributed RAM: Dung lượng thấp, trễ 0, power cao
  D) Hybrid (FF cache + BRAM backing):

Câu hỏi:
  • Mục tiêu chip: [Xilinx FPGA, Altera FPGA, TSMC ASIC]?
  • Có constraint tài nguyên BRAM không?
  • Latency tolerance: [0-cycle RMW preferred, 1-2 cycle acceptable, 3+ not OK]?
```

#### Q4.2: Read-Modify-Write (RMW) Pattern?
```
Hiện tại:
  psum_in[i] ← conv2_psum[ch_batch][col_pos][i]  // Direct read
  
Đề xuất (RMW trên BRAM):
  Cycle N:     MEM_READ_ADDR ← calculate()     // Initiate read
  Cycle N+1:   old_psum ← MEM_READ_DATA         // Get data
  Cycle N+1.5: pe_out[i] ← PE(old_psum)        // Compute
  Cycle N+2:   MEM_WRITE_ADDR ← same             // Write back
               MEM_WRITE_DATA ← pe_out[i]
  
Câu hỏi:
  • Có thể dual-port BRAM không (read & write parallel)?
  • Nếu single-port, phải stall PE khi conflict không?
  • Có thể dùng FIFO queue (enqueue old_psum, dequeue pe_out)?
```

#### Q4.3: Cấu trúc lưu trữ trên BRAM?
```
Hiện tại layout (tính toán):
  conv2_psum[4][13][8]:      ← 4×13×8 = 416 entries, 32-bit each
  dense1_psum[6][8]:         ← 6×8 = 48 entries, 32-bit each
  
BRAM allocation choices:
  A) Separate BRAM cho mỗi mảng     (3 BRAMs)
  B) Interleave trong 1 BRAM        (conflict risk)
  C) Banked BRAM (conv2→bank0, dense1→bank1)
  
Câu hỏi:
  • Nên allocate bao nhiêu BRAM?
  • Có cần ECC hoặc error detection không?
  • BRAM width: 32-bit, 36-bit (parity), hay 64-bit wide?
```

---

### **NHÓM 5: PARAMETERIZATION VÀ GENERICS**

#### Q5.1: Parameterize PE Array?
```
Hiện tại: 
  parameter NUM_PE = 8;  // Fixed in generate block
  
Câu hỏi:
  • Mục tiêu hỗ trợ [2, 4, 8, 16, 32] PE?
  • Hay chỉ cần [8, 16] PE?
  • Có impact gì tới FSM logic nếu NUM_PE thay đổi?
  • Bandwidth yêu cầu từ i_cache/w_cache tăng như nào?
```

#### Q5.2: Generic Convolution vs Fixed Conv3x3?
```
Hiện tại:
  PE_3x3: hardcoded 3×3 kernel
  
Câu hỏi:
  • Spec tiếp theo có cần hỗ trợ 1×1, 3×3, 5×5 không?
  • Nếu có, PE_NxN sẽ có tham số KERNEL_SIZE?
  • Logic multiply/accumulate có linh hoạt được không?
```

#### Q5.3: Activation Function parameterized?
```
Hiện tại:
  relu_en, quan_en: boolean signals
  
Câu hỏi:
  • Nên dùng enum (RELU, TANH, SIGMOID, NONE)?
  • Hay boolean flags (relu_en, tanh_en, sigmoid_en)?
  • Có cần LUT-based activation không (general function)?
```

---

## 📋 BẢNG TÓM TẮT CÂU HỎI

| Nhóm | Vấn đề | Mức ưu tiên | Câu hỏi chính |
|------|--------|-----------|--------------|
| **FSM** | 26 states cố định | 🔴 CAO | Q1.1: Dense ≠ Conv hay tương đương? |
| | | | Q1.2: CSR set nào đủ? |
| | | | Q1.3: Target: 4 hay unlimited layers? |
| **Stream** | Port quá rộng | 🔴 CAO | Q2.1: Data width tối ưu? |
| | | | Q2.2: AXI4-Stream hay AXI4-Full? |
| | **Latency** | 🟡 TB | Q2.3: Backpressure handling? |
| **Buffer** | Dummy cycle | 🟡 TB | Q3.1: Dual-port BRAM có không? |
| | | | Q3.2: Decoupled addr_gen có ích gì? |
| **Accumulator** | FF lãng phí | 🔴 CAO | Q4.1: BRAM/SRAM nên chọn cái? |
| | | | Q4.2: RMW latency tolerance? |
| | | | Q4.3: Interleave hay separate BRAM? |
| **Generics** | Hardcoded | 🟡 TB | Q5.1: Scale NUM_PE tới bao nhiêu? |
| | | | Q5.2: Support Conv1×1, Conv5×5? |
| | | | Q5.3: Activation function enum nào? |

---

## 💡 KHUYẾN NGHỊ TIẾP CẬN

### Giai đoạn 1: Định rõ Spec (1-2 tuần)
- [ ] Trả lời hết 13 câu hỏi trên
- [ ] Vẽ architectural diagram mới
- [ ] Liệt kê các port/interface chuẩn hóa

### Giai đoạn 2: RTL Prototype (3-4 tuần)
- [ ] Viết generalized FSM (4-state loop + CSR)
- [ ] Implement AXI4-Stream slave (nếu chọn)
- [ ] Prototype ping-pong buffer + decoupled addr_gen

### Giai đoạn 3: Refactor (2-3 tuần)
- [ ] Replace psum FF với BRAM-based accumulator
- [ ] Parameterize PE array, pe_array.v
- [ ] Integration test trên FPGA

---

**Tài liệu này sẽ được cập nhật liên tục khi có câu trả lời từ design team.**
