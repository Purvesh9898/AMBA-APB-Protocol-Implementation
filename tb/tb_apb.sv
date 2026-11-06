//==============================================================================
// tb_apb.sv : testbench for apb_top
//
//   T1  Reset                          T7  PPROT accepted and ignored
//   T2  Write / read back              T8  Back-to-back requests
//   T3  STATUS (read-only) register    T9  Random idle gaps
//   T4  Write to read-only -> error    T10 Reset in the middle of a transfer
//   T5  PSTRB byte lanes               T11 Constrained random vs. reference model
//   T6  Bad addresses -> error
//
// Wait states: change the WAIT_STATES parameter (0, 1, 3 ...) and re-run.
// Assertions : apb_checker.sv checks the APB protocol every clock cycle.
//              Compile with -DNO_SVA to run without it (e.g. Icarus Verilog).
//==============================================================================
`timescale 1ns/1ps

module tb_apb #(
  parameter WAIT_STATES = 0
)();

  //----------------------------------------------------------------------------
  // DUT, clock, assertion checker
  //----------------------------------------------------------------------------
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

`ifndef NO_SVA
  apb_checker #(.ADDR_WIDTH(8), .DATA_WIDTH(32), .WAIT_STATES(WAIT_STATES)) chk (
    .PCLK(PCLK), .PRESETn(PRESETn),
    .PADDR(dut.PADDR), .PPROT(dut.PPROT), .PSEL(dut.PSEL), .PENABLE(dut.PENABLE),
    .PWRITE(dut.PWRITE), .PWDATA(dut.PWDATA), .PSTRB(dut.PSTRB),
    .PREADY(dut.PREADY), .PRDATA(dut.PRDATA), .PSLVERR(dut.PSLVERR)
  );
`endif

  //----------------------------------------------------------------------------
  // Reference model + scoreboard
  //   send() predicts the result of every request and stores it in a queue.
  //   The monitor compares each real response with the stored prediction.
  //----------------------------------------------------------------------------
  integer errors = 0, checks = 0;
  logic [31:0] m_reg [0:3];                 // model of CTRL, DATA, STATUS, SCRATCH

  localparam MAXQ = 2048;
  logic [31:0] exp_rdata [0:MAXQ-1];
  logic        exp_err   [0:MAXQ-1];
  logic        exp_wr    [0:MAXQ-1];
  logic [7:0]  exp_addr  [0:MAXQ-1];
  integer exp_cnt = 0, rsp_cnt = 0;

  logic [31:0] got_data;                    // last response
  logic        got_err;

  always @(posedge PCLK) begin
    if (PRESETn && rsp_valid) begin
      if (rsp_cnt >= exp_cnt) begin
        $display("  FAIL: unexpected response"); errors = errors + 1;
      end else begin
        if (rsp_err !== exp_err[rsp_cnt] || rsp_rdata !== exp_rdata[rsp_cnt]) begin
          $display("  FAIL: txn %0d (%0s addr=0x%02h): err=%b data=0x%08h, expected err=%b data=0x%08h",
                   rsp_cnt, exp_wr[rsp_cnt] ? "WR" : "RD", exp_addr[rsp_cnt],
                   rsp_err, rsp_rdata, exp_err[rsp_cnt], exp_rdata[rsp_cnt]);
          errors = errors + 1;
        end
      end
      got_data = rsp_rdata;
      got_err  = rsp_err;
      rsp_cnt  = rsp_cnt + 1;               // last: drain() waits on this
    end
  end

  // statistic: ACCESS -> SETUP back-to-back transitions
  integer n_b2b = 0;
  logic   p_done = 0;
  always @(posedge PCLK) begin
    if (!PRESETn) p_done = 0;
    else begin
      if (p_done && dut.PSEL && !dut.PENABLE) n_b2b = n_b2b + 1;
      p_done = dut.PSEL & dut.PENABLE & dut.PREADY;
    end
  end

  //----------------------------------------------------------------------------
  // Helper tasks
  //----------------------------------------------------------------------------
  logic [2:0] cur_prot = 3'b000;

  task check(input string name, input logic [31:0] got, input logic [31:0] expected);
    begin
      checks = checks + 1;
      if (got !== expected) begin
        $display("  FAIL: %0s = 0x%0h, expected 0x%0h", name, got, expected);
        errors = errors + 1;
      end
    end
  endtask

  task model_reset;
    integer i;
    for (i = 0; i < 4; i = i + 1) m_reg[i] = 32'h0;
  endtask

  // Predict, then drive one request. Returns 1 ns after the accepting clock edge.
  task automatic send(input logic wr, input logic [7:0] a, input logic [31:0] d,
                      input logic [3:0] s, input logic [2:0] p);
    integer idx, i;
    logic   err;
    logic [31:0] tmp;
    begin
      idx = a >> 2;
      err = (a[1:0] != 2'b00) || (idx >= 4) || (wr && idx == 2);

      exp_wr[exp_cnt] = wr;  exp_addr[exp_cnt] = a;  exp_err[exp_cnt] = err;
      if (wr) begin
        exp_rdata[exp_cnt] = 32'h0;
        if (!err) begin
          tmp = m_reg[idx];
          for (i = 0; i < 4; i = i + 1) if (s[i]) tmp[8*i +: 8] = d[8*i +: 8];
          m_reg[idx] = tmp;
        end
      end else begin
        exp_rdata[exp_cnt] = err ? 32'h0 : (idx == 2) ? status_i : m_reg[idx];
      end
      exp_cnt = exp_cnt + 1;

      // Drive 1 ns AFTER a clock edge (never exactly on it) to avoid races.
      #1;
      req_valid = 1;  req_write = wr;  req_addr = a;
      req_wdata = d;  req_strb  = wr ? s : 4'h0;  req_prot = p;
      do @(negedge PCLK); while (!req_ready);     // req_ready is stable until the next posedge
      @(posedge PCLK);  #1;                       // request is accepted at this edge
      req_valid = 0;
    end
  endtask

  // Wait until every request sent so far has been answered
  task drain;
    begin
      wait (rsp_cnt == exp_cnt);
      @(posedge PCLK);  #1;
    end
  endtask

  task write_reg(input logic [7:0] a, input logic [31:0] d, input logic [3:0] s);
    begin send(1, a, d, s, cur_prot); drain; end
  endtask

  task read_reg(input logic [7:0] a);
    begin send(0, a, 32'h0, 4'h0, cur_prot); drain; end
  endtask

  // Reset (also clears the model and forgets outstanding requests)
  task do_reset;
    begin
      @(negedge PCLK);  PRESETn = 0;
      repeat (3) @(posedge PCLK);
      @(negedge PCLK);  PRESETn = 1;
      @(posedge PCLK);  #1;
      exp_cnt = rsp_cnt;
      model_reset;
    end
  endtask

  // Send a write, then reset it after 'cycles' more clock cycles
  //   cycles = 0 -> reset during SETUP,  cycles = 1 -> reset during ACCESS
  task reset_mid_transfer(input integer cycles);
    begin
      send(1, 8'h00, 32'hFFFFFFFF, 4'hF, 3'b000);
      repeat (cycles) @(posedge PCLK);
      @(negedge PCLK);  PRESETn = 0;  #1;
      check("ctrl_o after mid-transfer reset", ctrl_o, 0);
      check("PSEL after mid-transfer reset  ", dut.PSEL, 0);
      check("req_ready after reset          ", req_ready, 1);
      do_reset;
      read_reg(8'h00);
      check("CTRL after aborted write       ", got_data, 0);
    end
  endtask

  //----------------------------------------------------------------------------
  // Tests
  //----------------------------------------------------------------------------
  integer k, b2b0, pick;
  logic [7:0]  a_rand;
  logic [31:0] d_rand;
  logic [7:0]  bad_addr [0:11];

  initial begin
    req_valid = 0; req_write = 0; req_addr = 0; req_wdata = 0;
    req_strb  = 0; req_prot  = 0; status_i = 32'hCAFE0001;
    PRESETn   = 0;
    model_reset;
    bad_addr[0]  = 8'h10; bad_addr[1]  = 8'h14; bad_addr[2]  = 8'h40; bad_addr[3]  = 8'hFC;
    bad_addr[4]  = 8'h01; bad_addr[5]  = 8'h02; bad_addr[6]  = 8'h03; bad_addr[7]  = 8'h05;
    bad_addr[8]  = 8'h0B; bad_addr[9]  = 8'h0D; bad_addr[10] = 8'h0F; bad_addr[11] = 8'hFF;
    repeat (3) @(posedge PCLK);

    // ---- T1: reset ----
    $display("T1: reset");
    #1;
    check("ctrl_o during reset", ctrl_o, 0);
    check("req_ready           ", req_ready, 1);
    check("PSEL                ", dut.PSEL, 0);
    do_reset;
    check("ctrl_o after reset  ", ctrl_o, 0);
    write_reg(8'h00, 32'hA5A5A5A5, 4'hF);
    check("ctrl_o after write  ", ctrl_o, 32'hA5A5A5A5);
    @(negedge PCLK);  PRESETn = 0;  #1;             // reset is asynchronous
    check("ctrl_o after reset  ", ctrl_o, 0);
    do_reset;
    read_reg(8'h00);
    check("CTRL read-back      ", got_data, 0);

    // ---- T2: write / read back ----
    $display("T2: write / read back");
    write_reg(8'h04, 32'hDEADBEEF, 4'hF);  check("write err", got_err, 0);
    read_reg (8'h04);                      check("DATA     ", got_data, 32'hDEADBEEF);
    write_reg(8'h0C, 32'h12345678, 4'hF);
    read_reg (8'h0C);                      check("SCRATCH  ", got_data, 32'h12345678);
    read_reg (8'h04);                      check("DATA kept", got_data, 32'hDEADBEEF);

    // ---- T3: STATUS follows status_i ----
    $display("T3: STATUS register");
    read_reg(8'h08);  check("STATUS #1", got_data, 32'hCAFE0001);
    status_i = 32'h0000FFFF;
    read_reg(8'h08);  check("STATUS #2", got_data, 32'h0000FFFF);

    // ---- T4: write to read-only ----
    $display("T4: write to read-only STATUS");
    write_reg(8'h08, 32'h11111111, 4'hF);  check("write err  ", got_err, 1);
    read_reg (8'h08);                      check("STATUS kept", got_data, 32'h0000FFFF);
                                           check("read err   ", got_err, 0);

    // ---- T5: PSTRB ----
    $display("T5: PSTRB byte lanes");
    write_reg(8'h04, 32'hFFFFFFFF, 4'b1111);
    write_reg(8'h04, 32'h12345678, 4'b0001);  read_reg(8'h04);  check("strb 0001", got_data, 32'hFFFFFF78);
    write_reg(8'h04, 32'hAABBCCDD, 4'b0110);  read_reg(8'h04);  check("strb 0110", got_data, 32'hFFBBCC78);
    write_reg(8'h04, 32'h00000000, 4'b0000);  read_reg(8'h04);  check("strb 0000", got_data, 32'hFFBBCC78);
    write_reg(8'h04, 32'h11223344, 4'b1000);  read_reg(8'h04);  check("strb 1000", got_data, 32'h11BBCC78);
    write_reg(8'h04, 32'h99999999, 4'b1010);  read_reg(8'h04);  check("strb 1010", got_data, 32'h99BB9978);

    // ---- T6: bad addresses ----
    $display("T6: bad addresses");
    write_reg(8'h0C, 32'h55555555, 4'hF);
    for (k = 0; k < 12; k = k + 1) begin
      write_reg(bad_addr[k], 32'hFFFFFFFF, 4'hF);  check("bad wr err ", got_err, 1);
      read_reg (bad_addr[k]);                      check("bad rd err ", got_err, 1);
                                                   check("bad rd data", got_data, 0);
    end
    read_reg(8'h0C);  check("SCRATCH kept", got_data, 32'h55555555);
    read_reg(8'h00);  check("CTRL kept   ", got_data, 0);

    // ---- T7: PPROT ----
    $display("T7: PPROT accepted and ignored");
    for (k = 0; k < 8; k = k + 1) begin
      cur_prot = k;
      write_reg(8'h0C, 32'h100 + k, 4'hF);  check("write err", got_err, 0);
      read_reg (8'h0C);                     check("read-back ", got_data, 32'h100 + k);
    end
    cur_prot = 3'b000;

    // ---- T8: back-to-back ----
    $display("T8: back-to-back requests");
    b2b0 = n_b2b;
    send(1, 8'h00, 32'hB2B00001, 4'hF, 0);
    send(1, 8'h04, 32'hB2B00002, 4'hF, 0);
    send(0, 8'h00, 32'h0,        4'h0, 0);
    send(0, 8'h04, 32'h0,        4'h0, 0);
    send(1, 8'h0C, 32'hB2B00003, 4'hF, 0);
    send(0, 8'h0C, 32'h0,        4'h0, 0);
    drain;
    check("last read           ", got_data, 32'hB2B00003);
    check("ctrl_o              ", ctrl_o,   32'hB2B00001);
    check("ACCESS->SETUP count>=5", (n_b2b - b2b0) >= 5, 1);

    // ---- T9: random idle gaps ----
    $display("T9: random idle gaps");
    for (k = 0; k < 20; k = k + 1) begin
      repeat ($urandom_range(0, 5)) @(posedge PCLK);
      d_rand = $urandom;
      if ($urandom_range(0, 1)) write_reg({$urandom_range(0, 3), 2'b00}, d_rand, 4'hF);
      else                      read_reg ({$urandom_range(0, 3), 2'b00});
    end

    // ---- T10: reset in the middle of a transfer ----
    $display("T10: reset during SETUP and during ACCESS");
    reset_mid_transfer(0);
    reset_mid_transfer(1);

    // ---- T11: constrained random ----
    $display("T11: constrained random (300 transactions)");
    for (k = 0; k < 300; k = k + 1) begin
      if ($urandom_range(0, 15) == 0) begin        // change status_i only when idle
        drain;
        status_i = $urandom;
      end
      if ($urandom_range(0, 9) < 7) a_rand = {$urandom_range(0, 3), 2'b00};   // valid
      else                          a_rand = $urandom_range(0, 255);          // any
      send($urandom_range(0, 1), a_rand, $urandom, $urandom_range(0, 15), $urandom_range(0, 7));
      case ($urandom_range(0, 3))
        0:       drain;                                         // wait for the response
        1:       repeat ($urandom_range(1, 4)) @(posedge PCLK); // small gap
        default: ;                                              // back-to-back
      endcase
    end
    drain;
    check("ctrl_o after random", ctrl_o, m_reg[0]);

    // ---- Result ----
    $display("--------------------------------------------------");
    $display("WAIT_STATES=%0d : %0d checks, %0d transfers, %0d back-to-back",
             WAIT_STATES, checks, rsp_cnt, n_b2b);
    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("TESTS FAILED (%0d errors)", errors);
    $display("--------------------------------------------------");
    $finish;
  end

  initial begin
    #500000;
    $display("TIMEOUT: test did not finish");
    $finish;
  end

endmodule
