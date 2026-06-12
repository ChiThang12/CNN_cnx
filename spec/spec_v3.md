# 📋 MNIST CNN ACCELERATOR v3 - DETAILED SPECIFICATION

**Date**: June 12, 2026  
**Version**: v3.0  
**Status**: ✅ APPROVED  
**Target Platform**: Xilinx Artix-7-100T  
**Language**: Verilog-2001  

---

## Table of Contents

1. [Overview](#overview)
2. [System Architecture](#system-architecture)
3. [Module Parameters](#module-parameters)
4. [Port Definitions](#port-definitions)
5. [CSR Register Map](#csr-register-map)
6. [FSM State Machine](#fsm-state-machine)
7. [Data Format Specification](#data-format-specification)
8. [BRAM Address Generation](#bram-address-generation)
9. [AXI4-Stream Interface](#axi4-stream-interface)
10. [Constraints & Timing](#constraints--timing)

---

## Overview

### Design Goals
- **Generalization**: Support Conv1×1, Conv3×3 kernels (via PE_NxN parameterization)
- **Dynamic Layer Config**: 4-16 layers via CSR register loading
- **High Throughput**: Dual 32-bit AXI4-Stream ports for parallel data ingress
- **Area Efficiency**: BRAM-based psum storage (FF reduction: 69%)
- **Flexibility**: Multiple activation functions (NONE, ReLU, Tanh, Sigmoid)

### Key Metrics

| Metric | v2 | v3 | Δ |
|--------|----|----|---|
| **LUT** | 9,200 | 8,840 | -4% |
| **FF** | 6,544 | 2,000 | -69% |
| **BRAM** | 6 | 9 | +50% |
| **FSM States** | 26 | 4 (+ CSR) | -85% |
| **Max Layers** | Fixed 4 | Dynamic 4-16 | Flexible |

### v3 Architecture Highlights

```
┌─────────────────────────────────────────────────────────────┐
│                    CNN_TOP_V3                               │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────────┐   │
│  │ AXI4-Stream Interface (Dual 32-bit)                  │   │
│  │  tdata0[31:0], tvalid0, tready0, tlast0             │   │
│  │  tdata1[31:0], tvalid1, tready1, tlast1             │   │
│  └──────────────────────────────────────────────────────┘   │
│           ↓                                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ CSR Controller (Register File)                       │   │
│  │  - KERNEL_SIZE, STRIDE, PADDING, IN/OUT_CH, etc.    │   │
│  │  - Support: 16 × 50-byte layer configs              │   │
│  └──────────────────────────────────────────────────────┘   │
│           ↓                                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ FSM (4-State Generic Loop)                           │   │
│  │  1. FETCH_IFMP  2. FETCH_WEIGHT  3. EXECUTE  4. ...  │   │
│  │  (+ CSR_LOAD on layer transition)                    │   │
│  └──────────────────────────────────────────────────────┘   │
│           ↓                                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Data Path                                            │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐           │   │
│  │  │Cache_Ctrl│→ │PE_Array  │→ │Psum_Ctrl │           │   │
│  │  └──────────┘  └──────────┘  └──────────┘           │   │
│  │                     ↓                                 │   │
│  │  ┌──────────────────────────────────┐                │   │
│  │  │ BRAM Memory Subsystem            │                │   │
│  │  │ ├─ BRAM_IF1 (input/conv2 out)   │                │   │
│  │  │ ├─ BRAM_IF1_W (ping-pong write) │                │   │
│  │  │ ├─ BRAM_W1/W2/W3/W4 (weights)   │                │   │
│  │  │ ├─ BRAM_psum_conv2 (psum acc)   │                │   │
│  │  │ └─ BRAM_psum_dense1 (psum acc)  │                │   │
│  │  └──────────────────────────────────┘                │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## System Architecture

### Module Hierarchy

```
cnn_top_v3.v (TOP)
├── cnn_fsm_v3.v          (4-state FSM + CSR loader)
├── csr_controller.v      (Register file + write decoder)
├── addr_gen_v3.v         (Address generator for BRAMs)
├── cache_ctrl_v3.v       (Load BRAM data to PE cache)
├── pe_array_v3.v         (8× PE_NxN + activation)
│   └── PE_NxN.v          (Parameterized 1×1 / 3×3 PE)
│       └── activation_unit.v (ReLU / Tanh / Sigmoid)
├── maxpool_ctrl_v3.v     (2×2 MaxPool for Conv1)
├── ping_pong_ctrl.v      (Dual BRAM buffer management)
├── bram_psum_ctrl.v      (BRAM Read-Modify-Write)
└── axi4_stream_adapter.v (AXI4-Stream handshake logic)
```

### Data Flow

```
External AXI4-Stream
  ↓
┌─────────────────────────┐
│ AXI4-Stream Adapter     │
│ (handshake, buffering)  │
└─────────────────────────┘
  ↓
┌─────────────────────────┐
│ Ping-Pong Controller    │
│ (BRAM_IF1, BRAM_IF1_W)  │
└─────────────────────────┘
  ↓
┌─────────────────────────┐
│ Cache Controller        │
│ (Load BRAM → PE cache)  │
└─────────────────────────┘
  ↓
┌─────────────────────────┐
│ PE Array (8× PE_NxN)    │
│ (compute 3×3 or 1×1)    │
└─────────────────────────┘
  ↓
┌─────────────────────────┐
│ Psum/Activation Unit    │
│ (accumulate + ReLU/...)  │
└─────────────────────────┘
  ↓
┌─────────────────────────┐
│ BRAM Accumulator        │
│ (store psum for next)   │
└─────────────────────────┘
  ↓
External Output
```

---

## Module Parameters

### Global Parameters (All Modules)

```verilog
// Timescale
`timescale 1ns/10ps

// Data width
parameter DATA_BITS = 32;        // BRAM/AXI4-Stream word width
parameter PE_OUT_BITS = 32;      // PE output accumulator width
parameter ACCUM_WIDTH = 32;      // Partial sum accumulator
parameter QUANT_OUT_BITS = 8;    // Quantized output (after ReLU)

// PE Array Configuration
parameter NUM_PE = 8;            // Number of parallel PEs (8 or 16)
parameter KERNEL_SIZE = 3;       // Kernel size: 1 (dense) or 3 (conv)
parameter PE_LANE_WIDTH = 8;     // Per-PE data width (input/weight)

// BRAM Configuration
parameter BRAM_DEPTH = 16384;    // 36 Kb BRAM: 16384 × 32-bit words
parameter BRAM_ADDR_WIDTH = 14;  // log2(16384)
parameter BRAM_IF1_SIZE = 2048;  // 64 Kb (28×28 image, 2 channels)
parameter BRAM_W1_SIZE = 512;    // Conv1 weights  (2 batches × 19 words)
parameter BRAM_W2_SIZE = 1024;   // Conv2 weights  (4 batches × 16 in_ch × 18 words)
parameter BRAM_W3_SIZE = 2048;   // Dense1 weights (6 batches × 416 inputs)
parameter BRAM_W4_SIZE = 256;    // Dense2 weights (6 groups × 4 words)
parameter BRAM_PSUM_CONV2_SIZE = 1664;  // 4*13*8 = 416 entries
parameter BRAM_PSUM_DENSE1_SIZE = 48;   // 6*8 = 48 entries

// FSM Configuration
parameter NUM_LAYERS = 4;        // Configurable: 4-16 layers
parameter NUM_STATES = 4;        // Generic FSM: FETCH_IFMP, FETCH_WEIGHT, EXECUTE, WRITE_BACK
parameter CSR_DEPTH = 16;        // Support 16 layer configs
parameter CSR_WIDTH = 50;        // 10 CSR registers × 5 bytes per layer

// Cache Configuration
parameter CACHE_DEPTH = 96;      // Input feature map cache (3×32 pixels)
parameter WCACHE_DEPTH = 72;     // Weight cache (8 PE × 9 weights)

// Activation Function Enum
parameter ACTIVATION_NONE = 2'b00;
parameter ACTIVATION_RELU = 2'b01;
parameter ACTIVATION_TANH = 2'b10;
parameter ACTIVATION_SIGMOID = 2'b11;
```

### Module-Specific Parameters

#### PE_NxN Parameters

```verilog
module PE_NxN #(
    parameter KERNEL_SIZE = 3,          // 1 or 3
    parameter ACTIVATION_MODE = 2'b01,  // NONE/RELU/TANH/SIGMOID
    parameter PE_IN_WIDTH = 8,          // Input feature width
    parameter PE_W_WIDTH = 8,           // Weight width (signed)
    parameter PE_ACCUM_WIDTH = 32       // Accumulator width
) (
    // ... ports
);
```

**Behavior**:
- `KERNEL_SIZE = 1`: Dense layer (input vector: 8 elements, no spatial)
- `KERNEL_SIZE = 3`: Convolution (3×3 window, 9 inputs)
- `ACTIVATION_MODE`: Applied post-accumulation

#### CSR Controller Parameters

```verilog
module csr_controller #(
    parameter NUM_LAYERS = 4,           // 4-16 layers max
    parameter CSR_ADDR_WIDTH = 8,       // 0x00-0xFF addressing
    parameter CSR_DATA_WIDTH = 32       // AXI4 write port width
) (
    // ... ports
);
```

---

## Port Definitions

### cnn_top_v3.v (Top-Level Module)

```verilog
module cnn_top_v3 #(
    parameter NUM_PE = 8,
    parameter NUM_LAYERS = 4,
    parameter KERNEL_SIZE = 3
) (
    // ===== Global Signals =====
    input wire clk,              // System clock
    input wire rst,              // Active-high synchronous reset
    input wire [15:0] layer_count, // Number of layers to execute (4-16)
    
    // ===== CSR/Configuration Bus (AXI4 Lite style) =====
    input wire [7:0] csr_addr,
    input wire [31:0] csr_wdata,
    input wire csr_we,
    output reg [31:0] csr_rdata,
    
    // ===== Control Signals =====
    input wire start,            // Pulse to begin inference
    output wire done,            // Asserted when inference complete
    input wire ready,            // Consumer ready for result
    
    // ===== AXI4-Stream Slave (Input Data) =====
    input wire [31:0] s_tdata0,  // Stream 0: 32-bit data
    input wire s_tvalid0,        // Stream 0: data valid
    output wire s_tready0,       // Stream 0: ready to accept
    input wire s_tlast0,         // Stream 0: end of burst
    
    input wire [31:0] s_tdata1,  // Stream 1: 32-bit data
    input wire s_tvalid1,        // Stream 1: data valid
    output wire s_tready1,       // Stream 1: ready to accept
    input wire s_tlast1,         // Stream 1: end of burst
    
    // ===== AXI4-Stream Master (Output Result) =====
    output wire [7:0] m_tdata,   // Result: 8-bit class
    output wire m_tvalid,        // Result valid
    input wire m_tready,         // Master ready
    output wire m_tlast,         // Last result
    
    // ===== Optional Debug Ports =====
    output wire [5:0] fsm_state,
    output wire [5:0] fsm_n_state,
    output wire [15:0] layer_index,
    output wire [31:0] perf_cycles
);
```

### cnn_fsm_v3.v (FSM Module)

```verilog
module cnn_fsm_v3 #(
    parameter NUM_LAYERS = 4
) (
    // ===== Clock / Reset =====
    input wire clk,
    input wire rst,
    
    // ===== Control Interface =====
    input wire start,
    output reg [5:0] state,
    output wire [5:0] n_state,
    output wire done,
    
    // ===== CSR Interface =====
    input wire [31:0] csr_kernel_size,
    input wire [31:0] csr_stride,
    input wire [31:0] csr_padding,
    input wire [31:0] csr_in_channels,
    input wire [31:0] csr_out_channels,
    input wire [31:0] csr_in_width,
    input wire [31:0] csr_in_height,
    input wire [1:0] csr_activation,
    input wire [1:0] csr_quant_mode,
    
    // ===== Output Control Signals =====
    output reg [2:0] layer,        // Current layer (0-3)
    output reg [6:0] counter,      // General purpose counter
    output reg [15:0] layer_index, // Which layer in sequence
    output wire [31:0] perf_cycles,
    
    // ===== Handshake with sub-modules =====
    output wire cache_ctrl_en,
    input wire cache_ctrl_valid,
    output wire pe_array_en,
    input wire pe_array_valid,
    output wire psum_wr_en,
    input wire psum_wr_valid
);
```

### PE_NxN.v (Processing Element)

```verilog
module PE_NxN #(
    parameter KERNEL_SIZE = 3,
    parameter ACTIVATION_MODE = 2'b01
) (
    // ===== Clock / Reset =====
    input wire clk,
    input wire rst,
    
    // ===== Control =====
    input wire compute_en,
    output wire compute_valid,
    
    // ===== Data Input (9 elements for 3×3, 1 for 1×1) =====
    input wire [7:0] in_IF [0:8],   // Input feature map
    input wire signed [7:0] in_W [0:8];  // Weights (signed)
    
    // ===== Partial Sum Feedback =====
    input wire [31:0] psum_in,
    
    // ===== Output =====
    output wire [31:0] pe_out      // Result (activated + quantized)
);
```

### cache_ctrl_v3.v

```verilog
module cache_ctrl_v3 (
    // ===== Clock / Reset =====
    input wire clk,
    input wire rst,
    
    // ===== FSM Signals =====
    input wire [5:0] state,
    input wire [6:0] counter,
    
    // ===== AXI4-Stream Input =====
    input wire [31:0] s_tdata0,
    input wire s_tvalid0,
    output wire s_tready0,
    
    input wire [31:0] s_tdata1,
    input wire s_tvalid1,
    output wire s_tready1,
    
    // ===== BRAM Read Ports =====
    input wire [31:0] BRAM_IF1_DOUT,
    input wire [31:0] BRAM_W1_DOUT,
    input wire [31:0] BRAM_W2_DOUT,
    input wire [31:0] BRAM_W3_DOUT,
    input wire [31:0] BRAM_W4_DOUT,
    
    // ===== Cache Output (flattened) =====
    output wire [767:0] i_cache_flat,   // 96 bytes
    output wire [575:0] w_cache_flat    // 72 bytes
);
```

---

## CSR Register Map

### CSR Address Space

```
┌──────────────────────────────────────────────────────────────┐
│             CSR Register File (Layer Configuration)           │
├──────────────────────────────────────────────────────────────┤
│ Offset | Register Name        | Width | Bits | Purpose       │
├─────────────────────────────────────────────────────────────┤
│ 0x00   | KERNEL_SIZE          | 8     | 7:0  | Kernel size   │
│ 0x01   | STRIDE               | 8     | 7:0  | Stride        │
│ 0x02   | PADDING              | 8     | 7:0  | Padding       │
│ 0x03   | IN_CHANNELS          | 16    | 15:0 | Input ch      │
│ 0x04   | OUT_CHANNELS         | 16    | 15:0 | Output ch     │
│ 0x05   | IN_WIDTH             | 16    | 15:0 | Input width   │
│ 0x06   | IN_HEIGHT            | 16    | 15:0 | Input height  │
│ 0x07   | ACTIVATION_MODE      | 2     | 1:0  | Activation fn │
│ 0x08   | QUANT_MODE           | 2     | 1:0  | Quantization  │
│ 0x09   | LAYER_CTRL           | 8     | 7:0  | Ctrl bits     │
├─────────────────────────────────────────────────────────────┤
│ Total per layer: 10 registers = 50 bits = 7 bytes (padded)  │
│ For 16 layers: 16 × 50 bits = 800 bits = 100 bytes          │
└──────────────────────────────────────────────────────────────┘
```

### CSR Register Details

#### 0x00: KERNEL_SIZE (RW)
```
Bit    Description         Values      Notes
7:0    Kernel dimension    1,3,5,7     For v3: 1 (dense) or 3 (conv)
```
**Example**: 
- `0x01` = 1×1 kernel (Dense layer)
- `0x03` = 3×3 kernel (Convolution layer)

#### 0x01: STRIDE (RW)
```
Bit    Description         Values      Notes
7:0    Stride value        1,2,3,4     Conv stride / Dense: always 1
```

#### 0x02: PADDING (RW)
```
Bit    Description         Values      Notes
7:0    Padding             0,1,2       Conv padding / Dense: always 0
```

#### 0x03-0x04: CHANNELS (RW)
```
Register 0x03 (IN_CHANNELS):
Bit    Description         Values      Notes
15:0   Input channels      1-8192      Feature map depth (input)

Register 0x04 (OUT_CHANNELS):
Bit    Description         Values      Notes
15:0   Output channels     1-8192      Feature map depth (output)
```

#### 0x05-0x06: DIMENSIONS (RW)
```
Register 0x05 (IN_WIDTH):
Bit    Description         Values      Notes
15:0   Input width         1-4096      Pixels per row

Register 0x06 (IN_HEIGHT):
Bit    Description         Values      Notes
15:0   Input height        1-4096      Rows per feature map
```

#### 0x07: ACTIVATION_MODE (RW)
```
Bit    Description         Value       Behavior
1:0    Activation type     2'b00       No activation (Linear)
                           2'b01       ReLU (max(0, x))
                           2'b10       Tanh (-1 to +1)
                           2'b11       Sigmoid (0 to +1)
```

#### 0x08: QUANT_MODE (RW)
```
Bit    Description         Value       Behavior
1:0    Quantization        2'b00       No quantization (full 32-bit)
                           2'b01       INT8 quantization (bits[14:7])
                           2'b10       Fixed-point 16-bit
```

#### 0x09: LAYER_CTRL (RW)
```
Bit    Description         Value       Behavior
7:4    Reserved            0000        
3:0    Layer index         0-15        Current layer being configured
```

### CSR Access Protocol

**Firmware Example (Pseudo-C)**:

```c
// Configure Layer 0 (Conv1: 3×3, stride=1, padding=1)
write_csr(0x00, 0x03);      // KERNEL_SIZE = 3
write_csr(0x01, 0x01);      // STRIDE = 1
write_csr(0x02, 0x01);      // PADDING = 1
write_csr(0x03, 0x0001);    // IN_CHANNELS = 1
write_csr(0x04, 0x0010);    // OUT_CHANNELS = 16
write_csr(0x05, 0x001C);    // IN_WIDTH = 28
write_csr(0x06, 0x001C);    // IN_HEIGHT = 28
write_csr(0x07, 0x01);      // ACTIVATION = ReLU
write_csr(0x08, 0x01);      // QUANT = INT8
write_csr(0x09, 0x00);      // LAYER = 0

// Then assert START signal to begin inference
```

---

## FSM State Machine

### 4-State Generic Loop

The v3 FSM uses a **generic 4-state loop** instead of 26 hardcoded states:

```
┌─────────────────────────────────────────────────────────────┐
│  FSM STATE MACHINE (4-State Loop + CSR Loader)              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  State 0: IDLE                                               │
│    ├─ Waits for START pulse                                 │
│    └─ On START: load layer_0 config from CSR               │
│           → next state: FETCH_IFMP                          │
│                                                              │
│  ╔═══════════════════════════════════════════════════════╗  │
│  ║ GENERIC LAYER LOOP (Repeats for each layer)          ║  │
│  ╠═══════════════════════════════════════════════════════╣  │
│  ║                                                        ║  │
│  ║ State 1: FETCH_IFMP (Input Feature Map)              ║  │
│  ║   Action:  Load input BRAM → PE cache                ║  │
│  ║   Duration: 24-45 cycles (varies by layer)           ║  │
│  ║   Condition: counter < max_cycles                    ║  │
│  ║   → next state: FETCH_WEIGHT                         ║  │
│  ║                                                        ║  │
│  ║ State 2: FETCH_WEIGHT (Load Kernels)                 ║  │
│  ║   Action:  Load weight BRAM → PE cache               ║  │
│  ║   Duration: 18-20 cycles                             ║  │
│  ║   Condition: counter < max_cycles                    ║  │
│  ║   → next state: EXECUTE                              ║  │
│  ║                                                        ║  │
│  ║ State 3: EXECUTE (Compute)                           ║  │
│  ║   Action:  Compute convolution (3×3 or Dense 1×1)   ║  │
│  ║   Duration: 3-5 cycles (pipelined)                   ║  │
│  ║   Condition: counter < max_cycles                    ║  │
│  ║   → next state: WRITE_BACK                           ║  │
│  ║                                                        ║  │
│  ║ State 4: WRITE_BACK (Store Results)                  ║  │
│  ║   Action:  Write output to BRAM / accumulator        ║  │
│  ║   Duration: 60-104 cycles                            ║  │
│  ║   Condition: counter < max_cycles                    ║  │
│  ║   If (layer_idx < max_layers - 1):                   ║  │
│  ║      Load next CSR config                            ║  │
│  ║      → next state: FETCH_IFMP (repeat loop)          ║  │
│  ║   Else:                                               ║  │
│  ║      → next state: DONE                              ║  │
│  ║                                                        ║  │
│  ╚═══════════════════════════════════════════════════════╝  │
│                                                              │
│  State 5: DONE                                               │
│    ├─ Inference complete                                     │
│    ├─ Result (argmax of Dense2 output) ready               │
│    └─ Wait for ready signal → transition to IDLE           │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### State Encoding (6-bit)

```verilog
parameter [5:0]
    IDLE         = 6'd0,
    FETCH_IFMP   = 6'd1,
    FETCH_WEIGHT = 6'd2,
    EXECUTE      = 6'd3,
    WRITE_BACK   = 6'd4,
    CSR_LOAD     = 6'd5,  // Optional (embedded in WRITE_BACK)
    DONE         = 6'd31;
```

### State Transition Logic (Pseudo-Code)

```verilog
always @(*) begin
    case (state)
        IDLE: begin
            if (start)
                n_state = CSR_LOAD;  // Load layer_0 config
            else
                n_state = IDLE;
        end
        
        CSR_LOAD: begin
            // Load CSR[0x00:0x09] → FSM config
            n_state = FETCH_IFMP;
        end
        
        FETCH_IFMP: begin
            if (counter == ifmp_max_cycles)
                n_state = FETCH_WEIGHT;
            else
                n_state = FETCH_IFMP;
        end
        
        FETCH_WEIGHT: begin
            if (counter == weight_max_cycles)
                n_state = EXECUTE;
            else
                n_state = FETCH_WEIGHT;
        end
        
        EXECUTE: begin
            if (counter == exe_max_cycles)
                n_state = WRITE_BACK;
            else
                n_state = EXECUTE;
        end
        
        WRITE_BACK: begin
            if (counter == writeback_max_cycles) begin
                if (layer_index < (layer_count - 1)) begin
                    // Load next layer config from CSR
                    layer_index <= layer_index + 1;
                    n_state = CSR_LOAD;
                end else
                    n_state = DONE;
            end else
                n_state = WRITE_BACK;
        end
        
        DONE: begin
            if (ready)
                n_state = IDLE;
            else
                n_state = DONE;
        end
        
        default: n_state = IDLE;
    endcase
end
```

### Counter Management

For each state, the `counter` register tracks progress:

```verilog
always @(posedge clk or posedge rst) begin
    if (rst)
        counter <= 7'd0;
    else if (state != n_state)
        counter <= 7'd0;              // Reset on state transition
    else if (counter_flag)
        counter <= counter + 7'd1;    // Increment while active
end

wire counter_flag =
    (state == FETCH_IFMP && counter <= ifmp_max) ||
    (state == FETCH_WEIGHT && counter <= weight_max) ||
    (state == EXECUTE && counter <= exe_max) ||
    (state == WRITE_BACK && counter <= writeback_max);
```

---

## Data Format Specification

### Input Data Format

**AXI4-Stream Format** (Dual ports):
- **Width**: 32 bits per port (2 ports = 64 bits/cycle max)
- **Byte Order**: Big-endian within word (MSB first)
- **Packing**: 4 pixels per word (8-bit each)

Example (Layer 1: 28×28 image):
```
BRAM_IF1[0] = [pixel[0], pixel[1], pixel[2], pixel[3]]    // bytes [31:24], [23:16], [15:8], [7:0]
BRAM_IF1[1] = [pixel[4], pixel[5], pixel[6], pixel[7]]
...
BRAM_IF1[195] = [pixel[784], ..., pixel[787]]  // 28×28 = 784 pixels
```

### Weight Data Format

**Signed 8-bit** weights stored in BRAM:
```
BRAM_W1[0]  = [weight[0], weight[1], weight[2], weight[3]]
           = [-128 to +127] per element
```

### Partial Sum (Accumulator) Format

**32-bit signed integer**:
```
psum[31:0]  = Accumulated MAC result
           = Range: -2^31 to +2^31-1
           
Example:
9 × (input[7:0] × weight[7:0]) → max ~(255 × 127 × 9) ≈ 290K
→ fits comfortably in 32-bit signed
```

### Output Data Format (After Quantization)

**8-bit unsigned** (ReLU + INT8 quantize):
```
Formula:
1. sum = sum1 + sum2 (32-bit signed)
2. if (relu_en): sum = max(0, sum)
3. if (quan_en):
   - Extract bits [14:7]
   - Saturate to [0, 255] if overflow
   - Output: 8-bit result

Example:
sum = 0x1234 = 0b 00010010 00110100
Bits [14:7] = 0x24 >> 7 = 0x12 (if using [14:7])
→ Quantized output: 0x12 (18 in decimal)
```

---

## BRAM Address Generation

### BRAM Memory Map

```
┌─────────────────────────────────────────────────────────────┐
│ BRAM Memory Allocation (Xilinx Artix-7, 36 Kb blocks)       │
├─────────────────────────────────────────────────────────────┤
│ BRAM_IF1 (16384 words × 32-bit)   @ 0x00000000            │
│   └─ Layer 1 input (28×28 = 784 px = 196 words)           │
│   └─ Layer 2-4 intermediate outputs                        │
│                                                              │
│ BRAM_IF1_W (16384 words × 32-bit) @ 0x00010000            │
│   └─ Ping-pong buffer for Layer 1 output / Layer 2 input  │
│                                                              │
│ BRAM_W1 (512 words × 32-bit)      @ 0x00020000            │
│   └─ Conv1 weights (2 batches × 18 kernel weights)        │
│   └─ Size: 2 × 19 words = 38 words                        │
│                                                              │
│ BRAM_W2 (1024 words × 32-bit)     @ 0x00030000            │
│   └─ Conv2 weights (32 out_ch × 16 in_ch × 18 words)     │
│   └─ Size: 4 batches × 16 in_ch × 19 words = 1216 words  │
│                                                              │
│ BRAM_W3 (2048 words × 32-bit)     @ 0x00040000            │
│   └─ Dense1 weights (416 inputs × 48 outputs × 2 words)  │
│   └─ Size: 6 batches × 416 × 2 = 4992 words (spill OK)   │
│                                                              │
│ BRAM_W4 (256 words × 32-bit)      @ 0x00050000            │
│   └─ Dense2 weights (48 inputs × 2 outputs × 4 words)    │
│   └─ Size: 6 groups × 4 words = 24 words                 │
│                                                              │
│ BRAM_psum_conv2 (1664 words × 32-bit) @ 0x00060000        │
│   └─ Conv2 partial sums (4 batches × 13 cols × 8 PE)     │
│   └─ Size: 4 × 13 × 8 = 416 entries                      │
│                                                              │
│ BRAM_psum_dense1 (48 words × 32-bit) @ 0x00070000         │
│   └─ Dense1 output (6 batches × 8 PE) = 48 entries       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### BRAM Address Calculation Formulas

#### Layer 1 (Conv1) Input BRAM

```
Address for row_group (0-5):
  BRAM_IF1_ADDR = row_group * 8 words * 4 bytes = row_group * 32
                = byte address
  
Example:
  row_group = 0 → ADDR = 0x00000000
  row_group = 1 → ADDR = 0x00000020 (32 bytes)
  row_group = 5 → ADDR = 0x000000A0
```

#### Layer 2 (Conv2) Input BRAM

```
Address for input channel + column:
  BRAM_IF2_ADDR = (counter * 4 + in_ch[3:2]) * 4
  
  counter: cycle number in L2_RD_IFMP state
  in_ch[3:2]: which 4-channel word within the row
  
Example:
  counter = 0, in_ch = 0 → ADDR = 0x00000000
  counter = 1, in_ch = 0 → ADDR = 0x00000004
  counter = 15, in_ch = 4 → ADDR = 0x00000064 (100 bytes)
```

#### Weight BRAM Addressing

##### BRAM_W1 (Conv1)
```
Batch-based organization:
  Batch 0: words  0-18  (offset 0)
  Batch 1: words 19-37  (offset 19)
  
Address = (batch * 19 + counter) * 4
        = byte address

FSM behavior:
  - Start L1_RD_W: bram_w1_addr_r = 0
  - Increment each cycle: bram_w1_addr_r += 1
  - At batch 1: jump to bram_w1_addr_r = 18
```

##### BRAM_W2 (Conv2)
```
Layout: 4 ch_batches × 16 in_ch × 19 words per (ch_batch, in_ch)
  
Address = (ch_batch * 16 * 19 + in_ch * 19 + counter) * 4
        = (ch_batch * 288 + in_ch * 19 + counter) * 4

Example:
  ch_batch=0, in_ch=0, counter=0  → ADDR = 0
  ch_batch=0, in_ch=1, counter=0  → ADDR = 19*4 = 0x4C
  ch_batch=1, in_ch=0, counter=0  → ADDR = 288*4 = 0x480
```

##### BRAM_W3 (Dense1)
```
Layout: 6 ch_batches × 416 inputs × 2 words (832 words per batch)

Address = (ch_batch * 832 + dense_cnt * 2 + counter) * 4

Dense_cnt ranges 0-51 (52 groups of 8 inputs each = 416 total)

Example:
  ch_batch=0, dense_cnt=0, counter=0  → ADDR = 0
  ch_batch=1, dense_cnt=0, counter=0  → ADDR = 832*4 = 0xD00
```

##### BRAM_W4 (Dense2)
```
Layout: 6 groups × 4 words per output

Address = (dense_cnt * 4 + counter) * 4

Example:
  dense_cnt=0, counter=0  → ADDR = 0
  dense_cnt=1, counter=0  → ADDR = 4*4 = 0x10
```

---

## AXI4-Stream Interface

### Protocol Specification

**Standard AXI4-Stream (minimal)**:

```
┌──────────────────────────────────┐
│ AXI4-Stream Channel Signals       │
├──────────────────────────────────┤
│ tdata[31:0]    ← Payload (32-bit) │
│ tvalid         ← Source valid     │
│ tready         ← Sink ready       │
│ tlast          ← End of burst     │
└──────────────────────────────────┘
```

### Handshake Protocol

```
Master                           Slave
   │                              │
   ├─ tvalid=1, tdata=word0 ─────→
   │                       tready=1
   ├─ tvalid=1, tdata=word1 ─────→
   │                       tready=1
   ├─ tvalid=1, tdata=lastword ──→
   │        tlast=1         tready=1
   │ (transfer complete)
   │
   ├─ tvalid=0 (no more data)
```

### Dual-Port Configuration

**cnn_top_v3** has **2 independent AXI4-Stream slave ports**:

```verilog
// Stream 0
input wire [31:0] s_tdata0,
input wire s_tvalid0,
output wire s_tready0,
input wire s_tlast0,

// Stream 1
input wire [31:0] s_tdata1,
input wire s_tvalid1,
output wire s_tready1,
input wire s_tlast1,
```

**Bandwidth**:
- Single port: 32 bits/cycle = 4 bytes/cycle
- Dual ports: 64 bits/cycle = 8 bytes/cycle (when both active)

### Ready/Valid Semantics

**s_tready** asserted when:
```verilog
s_tready = (state == FETCH_IFMP) && !cache_full;
```

**s_tvalid** expected from external master:
- `s_tvalid=1` when data present on tdata
- `s_tvalid=0` when no more data (backpressure)

**tlast** semantics:
- `tlast=1` when this is the final word of current layer's input
- FSM uses tlast to trigger transition to next state

### Error Handling

**No built-in error signals** in v3; assumes clean transfers:
- External master guarantees valid data sequences
- No tkeep, tdest, tuser in minimal interface
- All transfers assumed complete (no partial beats)

---

## Constraints & Timing

### Timing Specifications

#### Clock Constraints (.xdc format)

```tcl
# Main system clock (target: 100 MHz, 10 ns period)
create_clock -period 10.000 -name clk [get_ports clk]

# Timing path constraints
set_input_delay -clock clk 2.0 [get_ports {rst start ready}]
set_output_delay -clock clk 2.0 [get_ports {done}]

# Relax AXI4-Stream interface (external sync)
set_input_delay -clock clk 3.0 [get_ports {s_tvalid0 s_tdata0}]
set_output_delay -clock clk 3.0 [get_ports {s_tready0}]
```

#### Setup/Hold Margins

```
Fmax Target: 100 MHz (10 ns clock period)
Slack Target: 2 ns
Max combinational delay: 8 ns
Max FF-FF setup: 5 ns
```

### Reset Specification

**Synchronous Reset** (active-high):
```verilog
always @(posedge clk) begin
    if (rst) begin
        state <= IDLE;
        counter <= 7'd0;
        // ... reset all registers
    end else begin
        // normal operation
    end
end
```

**Reset Duration**: Minimum 10 ns (1 clock cycle)

### Power Specifications

#### Estimated Power Consumption

| Component | v2 Est. | v3 Est. | Notes |
|-----------|---------|---------|-------|
| **Logic** | 180 mW | 175 mW | -4% LUT |
| **Memory (BRAM)** | 90 mW | 140 mW | +50% BRAM |
| **Memory (FF)** | 120 mW | 35 mW | -69% FF |
| **I/O (AXI)** | 50 mW | 80 mW | +2 streams |
| **Total** | **440 mW** | **430 mW** | **-2%** |

**Assumptions**:
- 100 MHz clock
- Activity factor: 0.5 (average)
- 28 nm equivalent (Artix-7 @ ~40 nm)

---

## Implementation Guidelines

### Coding Standards

1. **Naming Conventions**:
   - Registers: snake_case (e.g., `fsm_state`, `cache_addr`)
   - Parameters: UPPER_CASE (e.g., `NUM_PE`, `KERNEL_SIZE`)
   - Wires: snake_case (e.g., `pe_output`, `bram_valid`)

2. **File Organization**:
   - One module per file
   - File name = Module name (e.g., `PE_NxN.v`)
   - Include header with date, author, brief description

3. **Parameterization**:
   - All configurable values as parameters
   - No hardcoded constants except state encodings
   - Parameter documentation in module header

### Verification Strategy

1. **Unit Testing**:
   - Test each module in isolation
   - Verify address calculations
   - Test counter rollover, state transitions

2. **Integration Testing**:
   - Full layer execution (Layer 1 only)
   - Multi-layer sequence (all 4 MNIST layers)
   - AXI4-Stream handshake correctness

3. **Golden Model Comparison**:
   - Compare RTL output vs. Python simulation
   - Verify bit-accuracy of quantization
   - Check ReLU activation correctness

### Synthesis Considerations

**Xilinx-Specific Optimizations**:
```verilog
// For distributed RAM (small caches)
(* ram_style = "distributed" *)
reg [7:0] i_cache [0:95];

// For block RAM (BRAM)
(* ram_style = "block" *)
reg [31:0] mem [0:16383];

// Mark critical paths for timing closure
(* keep = "true" *)
reg [5:0] state;
```

**Expected Results**:
- **LUT**: ~8,800 (13.9% utilization)
- **FF**: ~2,000 (1.6% utilization)
- **BRAM**: ~9 blocks (6.7% utilization)
- **Fmax**: 100+ MHz (easily achievable)
- **Synthesis Time**: 2-3 minutes

---

## Document Control

| Version | Date | Author | Status | Notes |
|---------|------|--------|--------|-------|
| v3.0 | 2026-06-12 | Design Team | ✅ APPROVED | Initial release for implementation |
| v2.1 | 2026-06-10 | Design Team | Archived | Previous MNIST v2 spec |
| v1.0 | 2026-05-15 | Design Team | Archived | First version (4-layer fixed) |

---

## References

- **design_decision_analysis.md**: Q&A decisions for v3 architecture
- **qa_checklist_spec_v3.md**: Validation checklist
- **architecture_improvement_analysis.md**: Detailed analysis of design choices

---

**Document Generated**: 2026-06-12  
**Next Phase**: Begin RTL implementation (Phase 2: FSM Refactor)  
**Status**: ✅ READY FOR IMPLEMENTATION