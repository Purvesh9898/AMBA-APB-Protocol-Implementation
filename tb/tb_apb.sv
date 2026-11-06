//==============================================================================
// tb_apb_simple.sv : beginner testbench for apb_top, with key assertions
//
// Test cases:
//   T1 Reset            T4 Write to read-only STATUS -> error
//   T2 Write / read     T5 PSTRB byte lanes
//   T3 STATUS register  T6 Bad address (out of range, unaligned) -> error
//
// Assertions (checked every clock cycle, see the section after the clock):
//   A1 PENABLE only with PSEL           A4 PSTRB is zero on reads
//   A2 SETUP is followed by ACCESS      A5 PSLVERR only in the completion cycle
//   A3 Signals stable during wait states
//==============================================================================
`timescale 1ns/1ps

module tb_apb #(
  parameter WAIT_STATES = 0       // try 2: A3 only gets exercised when > 0
)();

  logic        PCLK, PRESETn;
  logic        req_valid, req_ready, req_write;
  logic [7:0]  req_addr;
  logic [31:0] req_wdata;
  logic [3:0]  req_strb;
  logic [2:0]  req_prot;
  logic        rsp_valid, rsp_err;
  logic [31:0] rsp_rdata;
  logic [31:0] status_i, ctrl_o;

  apb_top #(.ADDR_WIDTH(8), .DATA_WIDTH(32), .WAIT_STATES(WAIT_STATES)) dut (
    .PCLK(PCLK), .PRESETn(PRESETn),
    .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
    .req_addr(req_addr), .req_wdata(req_wdata), .req_strb(req_strb), .req_prot(req_prot),
    .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .rsp_err(rsp_err),
    .status_i(status_i), .ctrl_o(ctrl_o)
  );

  initial PCLK = 0;
  always #5 PCLK = ~PCLK;

  //----------------------------------------------------------------------------
  // Assertions: the most important APB protocol rules.
  // They watch the APB bus inside the DUT and are switched off during reset.
  // (Not supported by Icarus Verilog: compile with -DNO_SVA to skip them.)
  //----------------------------------------------------------------------------
`ifndef NO_SVA
  wire        psel    = dut.PSEL;
  wire        penable = dut.PENABLE;
  wire        pready  = dut.PREADY;
  wire        pwrite  = dut.PWRITE;
  wire        pslverr = dut.PSLVERR;
  wire [7:0]  paddr   = dut.PADDR;
  wire [31:0] pwdata  = dut.PWDATA;
  wire [3:0]  pstrb   = dut.PSTRB;
  wire [2:0]  pprot   = dut.PPROT;
  wire        xfer_done = psel & penable & pready;     // transfer finishes here

  // A1: PENABLE may only be HIGH while PSEL is HIGH
  A1_penable_needs_psel: assert property (
    @(posedge PCLK) disable iff (!PRESETn)
    penable |-> psel)
    else $error("A1: PENABLE HIGH while PSEL LOW");

  // A2: SETUP lasts one cycle and is always followed by ACCESS
  A2_setup_then_access: assert property (
    @(posedge PCLK) disable iff (!PRESETn)
    (psel && !penable) |=> (psel && penable))
    else $error("A2: SETUP not followed by ACCESS");

  // A3: while PREADY is LOW in ACCESS, the request must not change
  A3_stable_in_wait: assert property (
    @(posedge PCLK) disable iff (!PRESETn)
    (psel && penable && !pready) |=>
      (psel && penable && $stable(paddr) && $stable(pwrite) &&
       $stable(pwdata) && $stable(pstrb) && $stable(pprot)))
    else $error("A3: request changed during a wait state");

  // A4: PSTRB must be all zero on reads
  A4_pstrb_zero_on_read: assert property (
    @(posedge PCLK) disable iff (!PRESETn)
    (psel && !pwrite) |-> (pstrb == 4'b0000))
    else $error("A4: PSTRB not zero on a read");

  // A5: PSLVERR may only be HIGH in the last cycle of a transfer
  A5_pslverr_only_at_end: assert property (
    @(posedge PCLK) disable iff (!PRESETn)
    pslverr |-> xfer_done)
    else $error("A5: PSLVERR outside the completion cycle");
`endif

  //----------------------------------------------------------------------------
  // Helpers
  //----------------------------------------------------------------------------
  integer errors = 0;
  logic [31:0] got_data;     // result of the last transfer
  logic        got_err;

  task check(input string name, input logic [31:0] got, input logic [31:0] expected);
    if (got === expected)
      $display("  PASS: %0s = 0x%0h", name, got);
    else begin
      $display("  FAIL: %0s = 0x%0h, expected 0x%0h", name, got, expected);
      errors = errors + 1;
    end
  endtask

  task xfer(input logic wr, input logic [7:0] addr, input logic [31:0] data, input logic [3:0] strb);
    begin
      @(negedge PCLK);
      req_valid = 1;
      req_write = wr;
      req_addr = addr;
      req_wdata = data;
      req_strb = wr ? strb : 4'b0;
      req_prot = 3'b000;
      @(posedge PCLK);                 // accepted here (requester is idle)
      @(negedge PCLK);
      req_valid = 0;
      wait (rsp_valid == 1);           // response pulse
      @(negedge PCLK);
      got_data = rsp_rdata;
      got_err  = rsp_err;
    end
  endtask

  task write_reg(input logic [7:0] addr, input logic [31:0] data, input logic [3:0] strb);
    xfer(1, addr, data, strb);
  endtask

  task read_reg(input logic [7:0] addr);
    xfer(0, addr, 32'h0, 4'h0);
  endtask

  task do_reset;
    begin
      @(negedge PCLK);  PRESETn = 0;
      repeat (3) @(posedge PCLK);
      @(negedge PCLK);  PRESETn = 1;
      repeat (2) @(posedge PCLK);
      #1;
    end
  endtask

  //----------------------------------------------------------------------------
  // Tests
  //----------------------------------------------------------------------------
  initial begin
    req_valid = 0; req_write = 0; req_addr = 0; req_wdata = 0;
    req_strb  = 0; req_prot  = 0; status_i = 32'hCAFE0001;
    PRESETn   = 0;
    repeat (3) @(posedge PCLK);

    // ---- T1: reset ----
    $display("T1: reset");
    #1;
    check("ctrl_o during reset", ctrl_o,    0);
    check("req_ready          ", req_ready, 1);
    do_reset;
    check("ctrl_o after reset ", ctrl_o,    0);
    write_reg(8'h00, 32'hA5A5A5A5, 4'hF);
    check("ctrl_o after write ", ctrl_o,    32'hA5A5A5A5);
    @(negedge PCLK);  PRESETn = 0;  #1;           // reset is asynchronous
    check("ctrl_o after reset ", ctrl_o,    0);
    do_reset;
    read_reg(8'h00);
    check("CTRL read-back     ", got_data,  0);

    // ---- T2: write / read back ----
    $display("T2: write / read back");
    write_reg(8'h04, 32'hDEADBEEF, 4'hF);
    check("write err ", got_err,  0);
    read_reg(8'h04);
    check("DATA      ", got_data, 32'hDEADBEEF);
    write_reg(8'h0C, 32'h12345678, 4'hF);
    read_reg(8'h0C);
    check("SCRATCH   ", got_data, 32'h12345678);
    read_reg(8'h04);
    check("DATA kept ", got_data, 32'hDEADBEEF);   // other register not disturbed

    // ---- T3: STATUS follows the status_i input ----
    $display("T3: STATUS register");
    read_reg(8'h08);
    check("STATUS #1 ", got_data, 32'hCAFE0001);
    status_i = 32'h0000FFFF;
    read_reg(8'h08);
    check("STATUS #2 ", got_data, 32'h0000FFFF);

    // ---- T4: write to read-only register ----
    $display("T4: write to read-only STATUS");
    write_reg(8'h08, 32'h11111111, 4'hF);
    check("write err ", got_err,  1);
    read_reg(8'h08);
    check("STATUS kept", got_data, 32'h0000FFFF);
    check("read err   ", got_err,  0);

    // ---- T5: PSTRB byte lanes ----
    $display("T5: PSTRB byte lanes");
    write_reg(8'h04, 32'hFFFFFFFF, 4'b1111);
    write_reg(8'h04, 32'h12345678, 4'b0001);       // only byte 0
    read_reg(8'h04);
    check("strb 0001 ", got_data, 32'hFFFFFF78);
    write_reg(8'h04, 32'hAABBCCDD, 4'b0110);       // bytes 1 and 2
    read_reg(8'h04);
    check("strb 0110 ", got_data, 32'hFFBBCC78);
    write_reg(8'h04, 32'h00000000, 4'b0000);       // no bytes
    read_reg(8'h04);
    check("strb 0000 ", got_data, 32'hFFBBCC78);

    // ---- T6: bad addresses ----
    $display("T6: bad addresses");
    write_reg(8'h0C, 32'h55555555, 4'hF);
    write_reg(8'h10, 32'hFFFFFFFF, 4'hF);          // out of range
    check("range wr err", got_err, 1);
    read_reg(8'h10);
    check("range rd err", got_err, 1);
    check("range rd dat", got_data, 0);
    write_reg(8'h0D, 32'hFFFFFFFF, 4'hF);          // unaligned
    check("align wr err", got_err, 1);
    read_reg(8'h0D);
    check("align rd err", got_err, 1);
    read_reg(8'h0C);
    check("SCRATCH kept", got_data, 32'h55555555); // bad writes changed nothing

    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("TESTS FAILED (%0d errors)", errors);
    $finish;
  end

  initial begin
    #40000;
    $display("TIMEOUT: test did not finish");
    $finish;
  end

endmodule