//==============================================================================
// apb_checker.sv : APB protocol assertions (checked every clock cycle)
//
// Connect it to the APB bus between the Requester and the Completer.
// Rules 1-7 come from the AMBA APB spec. Rule 8 is specific to our Completer.
//==============================================================================
`define APB_CLK_RST @(posedge PCLK) disable iff (!PRESETn)

module apb_checker #(
  parameter ADDR_WIDTH  = 8,
  parameter DATA_WIDTH  = 32,
  parameter WAIT_STATES = 0       // only used by rule 8
)(
  input logic                    PCLK,
  input logic                    PRESETn,
  input logic [ADDR_WIDTH-1:0]   PADDR,
  input logic [2:0]              PPROT,
  input logic                    PSEL,
  input logic                    PENABLE,
  input logic                    PWRITE,
  input logic [DATA_WIDTH-1:0]   PWDATA,
  input logic [DATA_WIDTH/8-1:0] PSTRB,
  input logic                    PREADY,
  input logic [DATA_WIDTH-1:0]   PRDATA,
  input logic                    PSLVERR
);

  // A transfer finishes in the cycle where all three are HIGH
  wire xfer_done = PSEL & PENABLE & PREADY;

  // Counts ACCESS cycles in which PREADY was LOW (used by rule 8)
  integer wait_cnt;
  always @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn)                  wait_cnt <= 0;
    else if (xfer_done)            wait_cnt <= 0;
    else if (PSEL && PENABLE)      wait_cnt <= wait_cnt + 1;
    else                           wait_cnt <= 0;
  end

  // 1. PENABLE is only allowed while PSEL is HIGH
  a_penable_needs_psel: assert property (`APB_CLK_RST
    PENABLE |-> PSEL)
    else $error("APB: PENABLE HIGH while PSEL LOW");

  // 2. SETUP lasts exactly one cycle and is always followed by ACCESS
  a_setup_then_access: assert property (`APB_CLK_RST
    (PSEL && !PENABLE) |=> (PSEL && PENABLE))
    else $error("APB: SETUP not followed by ACCESS");

  // 3. While PREADY is LOW in ACCESS, everything from the Requester must hold
  a_stable_in_wait: assert property (`APB_CLK_RST
    (PSEL && PENABLE && !PREADY) |=>
      (PSEL && PENABLE && $stable(PADDR) && $stable(PWRITE) &&
       $stable(PWDATA) && $stable(PSTRB) && $stable(PPROT)))
    else $error("APB: signal changed during wait state");

  // 4. After a completed transfer PENABLE must drop (go to IDLE or SETUP)
  a_penable_drops: assert property (`APB_CLK_RST
    xfer_done |=> !PENABLE)
    else $error("APB: PENABLE still HIGH after transfer completed");

  // 5. PSTRB must be all LOW on reads
  a_pstrb_zero_on_read: assert property (`APB_CLK_RST
    (PSEL && !PWRITE) |-> (PSTRB == '0))
    else $error("APB: PSTRB not zero on a read");

  // 6. PSLVERR only in the last cycle of a transfer (recommended by the spec)
  a_pslverr_only_at_end: assert property (`APB_CLK_RST
    PSLVERR |-> xfer_done)
    else $error("APB: PSLVERR outside completion cycle");

  // 7. No X/Z on control signals, and on payload when it must be valid
  a_no_x_control: assert property (`APB_CLK_RST
    !$isunknown({PSEL, PENABLE, PREADY}))
    else $error("APB: X/Z on PSEL/PENABLE/PREADY");

  a_no_x_request: assert property (`APB_CLK_RST
    PSEL |-> !$isunknown({PADDR, PWRITE, PPROT, PSTRB}))
    else $error("APB: X/Z on request signals while PSEL HIGH");

  a_no_x_wdata: assert property (`APB_CLK_RST
    (PSEL && PWRITE) |-> !$isunknown(PWDATA))
    else $error("APB: X/Z on PWDATA during a write");

  a_no_x_response: assert property (`APB_CLK_RST
    xfer_done |-> !$isunknown(PSLVERR))
    else $error("APB: X/Z on PSLVERR at completion");

  a_no_x_rdata: assert property (`APB_CLK_RST
    (xfer_done && !PWRITE) |-> !$isunknown(PRDATA))
    else $error("APB: X/Z on PRDATA at read completion");

  // 8. Our Completer inserts exactly WAIT_STATES wait cycles per transfer
  a_exact_wait_states: assert property (`APB_CLK_RST
    xfer_done |-> (wait_cnt == WAIT_STATES))
    else $error("APB: wrong number of wait states");

endmodule
