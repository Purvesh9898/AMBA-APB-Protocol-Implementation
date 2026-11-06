//==============================================================================
// apb_requester.v  (Verilog-2001 / 2005, synthesizable)
// APB4 Requester: turns a simple request/response interface into APB transfers.
//
// FSM (spec Chapter 4):
//   IDLE   : PSEL=0
//   SETUP  : PSEL=1, PENABLE=0   (exactly one cycle)
//   ACCESS : PSEL=1, PENABLE=1   (stays while PREADY=0)
//
// User-side interface:
//   Request  : req_valid / req_ready handshake, a request is accepted in the
//              cycle where req_valid & req_ready are both HIGH.
//   Response : rsp_valid is a one-cycle pulse after the APB transfer completes,
//              carrying rsp_rdata (reads only) and rsp_err (from PSLVERR).
//
// Notes:
//   * req_ready is HIGH in IDLE, and also in the last ACCESS cycle (PREADY=1),
//     so back-to-back requests go ACCESS -> SETUP directly (PSEL stays HIGH).
//   * PSTRB is forced to all-zero for reads (spec requirement).
//   * All APB outputs come from registers or the state register, so they are
//     stable throughout ACCESS, as required while PREADY is LOW.
//   * Single Completer: one PSEL output. Address decoding to several PSELx
//     is a later extension.
//   * No timeout: if a Completer never raises PREADY, this Requester waits.
//==============================================================================
module apb_requester #(
  parameter ADDR_WIDTH = 8,
  parameter DATA_WIDTH = 32
)(
  input  wire                    PCLK,
  input  wire                    PRESETn,

  // User-side request interface
  input  wire                    req_valid,
  output wire                    req_ready,
  input  wire                    req_write,   // 1 = write, 0 = read
  input  wire [ADDR_WIDTH-1:0]   req_addr,
  input  wire [DATA_WIDTH-1:0]   req_wdata,
  input  wire [DATA_WIDTH/8-1:0] req_strb,    // ignored for reads
  input  wire [2:0]              req_prot,

  // User-side response interface
  output reg                     rsp_valid,   // one-cycle pulse
  output reg  [DATA_WIDTH-1:0]   rsp_rdata,
  output reg                     rsp_err,

  // APB interface
  output wire [ADDR_WIDTH-1:0]   PADDR,
  output wire [2:0]              PPROT,
  output wire                    PSEL,
  output wire                    PENABLE,
  output wire                    PWRITE,
  output wire [DATA_WIDTH-1:0]   PWDATA,
  output wire [DATA_WIDTH/8-1:0] PSTRB,
  input  wire                    PREADY,
  input  wire [DATA_WIDTH-1:0]   PRDATA,
  input  wire                    PSLVERR
);

  //----------------------------------------------------------------------------
  // State encoding
  //----------------------------------------------------------------------------
  localparam [1:0] S_IDLE   = 2'd0,
                   S_SETUP  = 2'd1,
                   S_ACCESS = 2'd2;

  reg [1:0] state, next_state;

  //----------------------------------------------------------------------------
  // Latched request (held stable for the whole transfer)
  //----------------------------------------------------------------------------
  reg [ADDR_WIDTH-1:0]   addr_r;
  reg [2:0]              prot_r;
  reg                    write_r;
  reg [DATA_WIDTH-1:0]   wdata_r;
  reg [DATA_WIDTH/8-1:0] strb_r;

  //----------------------------------------------------------------------------
  // Handshake and transfer-complete conditions
  //----------------------------------------------------------------------------
  wire access_done = (state == S_ACCESS) & PREADY;   // PSEL & PENABLE & PREADY

  assign req_ready = (state == S_IDLE) | access_done;

  wire accept = req_valid & req_ready;

  //----------------------------------------------------------------------------
  // Next-state logic
  //----------------------------------------------------------------------------
  always @* begin
    next_state = state;
    case (state)
      S_IDLE:   if (req_valid) next_state = S_SETUP;

      S_SETUP:  next_state = S_ACCESS;            // always one cycle

      S_ACCESS: if (PREADY) begin
                  if (req_valid) next_state = S_SETUP;  // back-to-back
                  else           next_state = S_IDLE;
                end

      default:  next_state = S_IDLE;
    endcase
  end

  //----------------------------------------------------------------------------
  // Sequential logic: state, request latch, response capture
  //----------------------------------------------------------------------------
  always @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn) begin
      state     <= S_IDLE;
      addr_r    <= {ADDR_WIDTH{1'b0}};
      prot_r    <= 3'b000;
      write_r   <= 1'b0;
      wdata_r   <= {DATA_WIDTH{1'b0}};
      strb_r    <= {(DATA_WIDTH/8){1'b0}};
      rsp_valid <= 1'b0;
      rsp_rdata <= {DATA_WIDTH{1'b0}};
      rsp_err   <= 1'b0;
    end else begin
      state     <= next_state;
      rsp_valid <= 1'b0;                          // default: pulse

      // Capture response on the completion edge
      if (access_done) begin
        rsp_valid <= 1'b1;
        rsp_err   <= PSLVERR;
        rsp_rdata <= write_r ? {DATA_WIDTH{1'b0}} : PRDATA;
      end

      // Latch a new request when accepted
      if (accept) begin
        addr_r  <= req_addr;
        prot_r  <= req_prot;
        write_r <= req_write;
        wdata_r <= req_wdata;
        strb_r  <= req_write ? req_strb : {(DATA_WIDTH/8){1'b0}};
      end
    end
  end

  //----------------------------------------------------------------------------
  // APB outputs
  //----------------------------------------------------------------------------
  assign PSEL    = (state != S_IDLE);
  assign PENABLE = (state == S_ACCESS);
  assign PADDR   = addr_r;
  assign PPROT   = prot_r;
  assign PWRITE  = write_r;
  assign PWDATA  = wdata_r;
  assign PSTRB   = strb_r;

endmodule
