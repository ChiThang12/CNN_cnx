`timescale 1ns/10ps
// =============================================================================
// Module: bram
// Fix: Thêm initial block ?? kh?i t?o toàn b? mem[] v? 0.
//      Không có initial block ? mem[i] = X khi simulation b?t ??u.
//      $readmemh ch? ghi ?è các ??a ch? có trong file hex;
//      nh?ng ??a ch? còn l?i gi? nguyên X ? gây l?i X-propagation.
// =============================================================================
module bram(clk, rst, dout, addr, en, din, wen);
  input clk;
  input rst;
  output reg [31:0] dout;
  input  [3:0]  wen;
  input  [31:0] addr;
  input  en;
  input  [31:0] din;
  wire [31:0] addrW;
  (* ram_style = "block" *)
  reg [31:0] mem [0:50000];

  // ---------------------------------------------------------------------------
  // FIX: Kh?i t?o toàn b? mem v? 0 tr??c khi $readmemh ch?y.
  //   - Trong Vivado simulation (xsim), initial block ???c h? tr?.
  //   - $readmemh s? ghi ?è các entry có trong file hex lên n?n 0 này.
  //   - Các ??a ch? không có trong hex file ? gi? giá tr? 0 (thay vì X).
  // ---------------------------------------------------------------------------
  integer idx;
  initial begin : mem_zero_init
    for (idx = 0; idx <= 50000; idx = idx + 1)
      mem[idx] = 32'h0000_0000;
  end

  // Write port
  always @(posedge clk) begin
    if (wen == 4'b1111 && en)
      mem[addrW] <= din;
  end

  // Read port (registered, latency = 1 cycle)
  always @(posedge clk) begin
    if (en)
      dout <= mem[addrW];
  end

  assign addrW = addr >> 2;
endmodule