`timescale 1ns/10ps
`define CYCLE 15.4

// =============================================================================
// Module: cnn_tb
// Description: Testbench for cnn_top (CNN inference accelerator).
//              - 4 weight BRAMs: W1..W4
//              - 2 feature-map BRAMs: IF1 (input), IF2 (intermediate)
//              - Loads weight hex files from src_cnx directory
//              - Loads input image from in_32.hex
//              - Clock period: 15.4 ns
//              - Waits for done, displays classification result (0 or 1)
// =============================================================================

module cnn_tb;

// ---------------------------------------------------------------------------
// Testbench control signals
// ---------------------------------------------------------------------------
reg clk;    // system clock
reg rst;    // active-high reset
reg start;  // start inference pulse
reg ready;  // external ready (not used internally, kept for interface compat)

// ---------------------------------------------------------------------------
// DUT output signals
// ---------------------------------------------------------------------------
wire        done;       // asserted when inference is complete
wire [7:0]  result;     // classification result: 0 or 1

// ---------------------------------------------------------------------------
// BRAM interface signals: address, write-enable, enable, data in/out
// All BRAMs have 32-bit wide data ports
// ---------------------------------------------------------------------------

// Feature-map BRAM 1 (input image / Conv1 output)
wire [31:0] BRAM_IF1_ADDR;
wire [3:0]  BRAM_IF1_WE;
wire        BRAM_IF1_EN;
wire [31:0] BRAM_IF1_DOUT;
wire [31:0] BRAM_IF1_DIN;

// Feature-map BRAM 2 (Conv2 / intermediate feature maps)
wire [31:0] BRAM_IF2_ADDR;
wire [3:0]  BRAM_IF2_WE;
wire        BRAM_IF2_EN;
wire [31:0] BRAM_IF2_DOUT;
wire [31:0] BRAM_IF2_DIN;

// Weight BRAM 1 (Conv1 weights)
wire [31:0] BRAM_W1_ADDR;
wire [3:0]  BRAM_W1_WE;
wire        BRAM_W1_EN;
wire [31:0] BRAM_W1_DOUT;
wire [31:0] BRAM_W1_DIN;

// Weight BRAM 2 (Conv2 weights)
wire [31:0] BRAM_W2_ADDR;
wire [3:0]  BRAM_W2_WE;
wire        BRAM_W2_EN;
wire [31:0] BRAM_W2_DOUT;
wire [31:0] BRAM_W2_DIN;

// Weight BRAM 3 (Dense1 weights)
wire [31:0] BRAM_W3_ADDR;
wire [3:0]  BRAM_W3_WE;
wire        BRAM_W3_EN;
wire [31:0] BRAM_W3_DOUT;
wire [31:0] BRAM_W3_DIN;

// Weight BRAM 4 (Dense2 weights)
wire [31:0] BRAM_W4_ADDR;
wire [3:0]  BRAM_W4_WE;
wire        BRAM_W4_EN;
wire [31:0] BRAM_W4_DOUT;
wire [31:0] BRAM_W4_DIN;

// ---------------------------------------------------------------------------
// DUT Instantiation: cnn_top
// ---------------------------------------------------------------------------
cnn_top cnn(
  .clk          (clk),
  .rst          (rst),
  .start        (start),
  .ready        (ready),
  .done         (done),
  .result       (result),

  // Feature-map BRAM 1
  .BRAM_IF1_ADDR(BRAM_IF1_ADDR),
  .BRAM_IF1_WE  (BRAM_IF1_WE),
  .BRAM_IF1_EN  (BRAM_IF1_EN),
  .BRAM_IF1_DOUT(BRAM_IF1_DOUT),
  .BRAM_IF1_DIN (BRAM_IF1_DIN),

  // Feature-map BRAM 2
  .BRAM_IF2_ADDR(BRAM_IF2_ADDR),
  .BRAM_IF2_WE  (BRAM_IF2_WE),
  .BRAM_IF2_EN  (BRAM_IF2_EN),
  .BRAM_IF2_DOUT(BRAM_IF2_DOUT),
  .BRAM_IF2_DIN (BRAM_IF2_DIN),

  // Weight BRAM 1
  .BRAM_W1_ADDR (BRAM_W1_ADDR),
  .BRAM_W1_WE   (BRAM_W1_WE),
  .BRAM_W1_EN   (BRAM_W1_EN),
  .BRAM_W1_DOUT (BRAM_W1_DOUT),
  .BRAM_W1_DIN  (BRAM_W1_DIN),

  // Weight BRAM 2
  .BRAM_W2_ADDR (BRAM_W2_ADDR),
  .BRAM_W2_WE   (BRAM_W2_WE),
  .BRAM_W2_EN   (BRAM_W2_EN),
  .BRAM_W2_DOUT (BRAM_W2_DOUT),
  .BRAM_W2_DIN  (BRAM_W2_DIN),

  // Weight BRAM 3
  .BRAM_W3_ADDR (BRAM_W3_ADDR),
  .BRAM_W3_WE   (BRAM_W3_WE),
  .BRAM_W3_EN   (BRAM_W3_EN),
  .BRAM_W3_DOUT (BRAM_W3_DOUT),
  .BRAM_W3_DIN  (BRAM_W3_DIN),

  // Weight BRAM 4
  .BRAM_W4_ADDR (BRAM_W4_ADDR),
  .BRAM_W4_WE   (BRAM_W4_WE),
  .BRAM_W4_EN   (BRAM_W4_EN),
  .BRAM_W4_DOUT (BRAM_W4_DOUT),
  .BRAM_W4_DIN  (BRAM_W4_DIN)
);

// ---------------------------------------------------------------------------
// BRAM Instances
// ---------------------------------------------------------------------------

// Weight BRAM 1: Conv1 weights
bram bram_w1(
  .clk  (clk),
  .rst  (rst),
  .wen  (BRAM_W1_WE),
  .addr (BRAM_W1_ADDR),
  .en   (BRAM_W1_EN),
  .dout (BRAM_W1_DOUT),
  .din  (BRAM_W1_DIN)
);

// Weight BRAM 2: Conv2 weights
bram bram_w2(
  .clk  (clk),
  .rst  (rst),
  .wen  (BRAM_W2_WE),
  .addr (BRAM_W2_ADDR),
  .en   (BRAM_W2_EN),
  .dout (BRAM_W2_DOUT),
  .din  (BRAM_W2_DIN)
);

// Weight BRAM 3: Dense1 weights
bram bram_w3(
  .clk  (clk),
  .rst  (rst),
  .wen  (BRAM_W3_WE),
  .addr (BRAM_W3_ADDR),
  .en   (BRAM_W3_EN),
  .dout (BRAM_W3_DOUT),
  .din  (BRAM_W3_DIN)
);

// Weight BRAM 4: Dense2 weights
bram bram_w4(
  .clk  (clk),
  .rst  (rst),
  .wen  (BRAM_W4_WE),
  .addr (BRAM_W4_ADDR),
  .en   (BRAM_W4_EN),
  .dout (BRAM_W4_DOUT),
  .din  (BRAM_W4_DIN)
);

// Feature-map BRAM 1: input image (loaded from in_32.hex)
bram bram_if1(
  .clk  (clk),
  .rst  (rst),
  .wen  (BRAM_IF1_WE),
  .addr (BRAM_IF1_ADDR),
  .en   (BRAM_IF1_EN),
  .dout (BRAM_IF1_DOUT),
  .din  (BRAM_IF1_DIN)
);

// Feature-map BRAM 2: intermediate feature maps
bram bram_if2(
  .clk  (clk),
  .rst  (rst),
  .wen  (BRAM_IF2_WE),
  .addr (BRAM_IF2_ADDR),
  .en   (BRAM_IF2_EN),
  .dout (BRAM_IF2_DOUT),
  .din  (BRAM_IF2_DIN)
);

// ---------------------------------------------------------------------------
// Clock Generation: period = CYCLE ns (15.4 ns)
// ---------------------------------------------------------------------------
always #(`CYCLE / 2) clk = ~clk;

// ---------------------------------------------------------------------------
// Simulation Stimulus
// ---------------------------------------------------------------------------
initial begin
  // Initialize signals
  clk   = 1'b0;
  rst   = 1'b1;
  start = 1'b0;
  ready = 1'b0;

  // Release reset after 1 ns
  #1 rst = 1'b0;

  // Wait a few ns then assert start for one cycle
  #20 start = 1'b1;
  #(`CYCLE) start = 1'b0;

  // Wait until inference is complete
  wait (done);

  // Report results
  $display("\n===== Inference Done =====");
  $timeformat(-9, 2, " ns", 10);
  $display("Simulation time = %t", $time);

  // Wait two more cycles before reading result (pipeline flush)
  #(`CYCLE * 2);
  $display("Result (class) = %0d", result);

  if (result == 8'd0)
    $display("=> Class 0");
  else
    $display("=> Class 1");

  $finish;
end

// ---------------------------------------------------------------------------
// Memory Initialization: load hex files into BRAM memories
// Files are located in src_cnx directory
// ---------------------------------------------------------------------------
initial begin
  $readmemh("D:/PROJECT_CNX/fpga/mnist_v2/src_cnx/bram_w1.hex", bram_w1.mem);
  $readmemh("D:/PROJECT_CNX/fpga/mnist_v2/src_cnx/bram_w2.hex", bram_w2.mem);
  $readmemh("D:/PROJECT_CNX/fpga/mnist_v2/src_cnx/bram_w3.hex", bram_w3.mem);
  $readmemh("D:/PROJECT_CNX/fpga/mnist_v2/src_cnx/bram_w4.hex", bram_w4.mem);
  $readmemh("D:/PROJECT_CNX/fpga/mnist_v2/src_cnx/in_32.hex",   bram_if1.mem);
end

// ---------------------------------------------------------------------------
// Waveform Dump
// ---------------------------------------------------------------------------
initial begin
  $dumpfile("cnn_cnx.vcd");
  $dumpvars;
end

endmodule
