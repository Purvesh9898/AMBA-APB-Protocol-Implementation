//==============================================================================
// apb_completer.v  (Verilog-2001 / 2005)
// Simple APB4 Completer (peripheral side) with a small register file.
//
// Register map (DATA_WIDTH = 32 -> byte offsets):
//   0x00  CTRL     RW   reset = 0
//   0x04  DATA     RW   reset = 0
//   0x08  STATUS   RO   value comes from status_i
//   0x0C  SCRATCH  RW   reset = 0
//
// Policies:
//   * Unaligned PADDR         -> PSLVERR, no update, read returns 0
//   * Address outside the map -> PSLVERR, no update, read returns 0
//   * Write to RO register    -> PSLVERR, no update
//   * Errored write           -> register NOT updated
//   * PSTRB                   -> byte-lane writes supported
//   * PPROT                   -> accepted but ignored
//   * Reset                   -> asynchronous assert, active-LOW (PRESETn)
//   * Wait states             -> fixed number, set by WAIT_STATES
//==============================================================================
module apb_completer #(
  parameter ADDR_WIDTH  = 8,    // up to 32
  parameter DATA_WIDTH  = 32,   // 8, 16 or 32
  parameter WAIT_STATES = 0     // extra ACCESS cycles before PREADY = 1
)(
  // APB interface
  input  wire                    PCLK,
  input  wire                    PRESETn,
  input  wire [ADDR_WIDTH-1:0]   PADDR,
  input  wire [2:0]              PPROT,     // unused
  input  wire                    PSEL,      // this Completer's PSELx
  input  wire                    PENABLE,
  input  wire                    PWRITE,
  input  wire [DATA_WIDTH-1:0]   PWDATA,
  input  wire [DATA_WIDTH/8-1:0] PSTRB,
  output wire                    PREADY,
  output wire [DATA_WIDTH-1:0]   PRDATA,
  output wire                    PSLVERR,

  // Hardware side of the registers
  input  wire [DATA_WIDTH-1:0]   status_i,  // read by STATUS register
  output wire [DATA_WIDTH-1:0]   ctrl_o     // driven by CTRL register
);

  //----------------------------------------------------------------------------
  // Local parameters
  //----------------------------------------------------------------------------
  localparam BYTE_LANES = DATA_WIDTH / 8;
  localparam LSB        = $clog2(BYTE_LANES);   // low address bits = byte offset
  localparam NUM_REGS   = 4;
  localparam CNT_W      = (WAIT_STATES > 0) ? $clog2(WAIT_STATES + 1) : 1;

  localparam [ADDR_WIDTH-1:0] ALIGN_MASK = BYTE_LANES - 1;

  localparam IDX_CTRL    = 0;
  localparam IDX_DATA    = 1;
  localparam IDX_STATUS  = 2;   // read-only
  localparam IDX_SCRATCH = 3;

  //----------------------------------------------------------------------------
  // Registers
  //----------------------------------------------------------------------------
  reg [DATA_WIDTH-1:0] reg_ctrl, reg_data, reg_scratch;

  assign ctrl_o = reg_ctrl;

  //----------------------------------------------------------------------------
  // Phase decode (SETUP = PSEL & !PENABLE, ACCESS = PSEL & PENABLE)
  //----------------------------------------------------------------------------
  wire access_phase = PSEL & PENABLE;

  //----------------------------------------------------------------------------
  // Wait-state generator -> PREADY
  // PREADY may take any value while PENABLE is LOW, so it is simply
  // derived from the counter.
  //----------------------------------------------------------------------------
  reg [CNT_W-1:0] wait_cnt;

  assign PREADY = (wait_cnt == WAIT_STATES);

  always @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn)
      wait_cnt <= {CNT_W{1'b0}};
    else if (access_phase && !PREADY)
      wait_cnt <= wait_cnt + 1'b1;
    else
      wait_cnt <= {CNT_W{1'b0}};   // transfer finished, or not in ACCESS
  end

  //----------------------------------------------------------------------------
  // Transfer-complete condition: PSEL & PENABLE & PREADY
  //----------------------------------------------------------------------------
  wire xfer_done = access_phase & PREADY;

  //----------------------------------------------------------------------------
  // Address decode and error checking
  //----------------------------------------------------------------------------
  wire [ADDR_WIDTH-1:0] word_idx     = PADDR >> LSB;
  wire                  unaligned    = |(PADDR & ALIGN_MASK);
  wire                  out_of_range = (word_idx >= NUM_REGS);
  wire                  write_to_ro  = PWRITE && (word_idx == IDX_STATUS);
  wire                  xfer_err     = unaligned | out_of_range | write_to_ro;

  // PSLVERR is only meaningful in the last cycle of a transfer.
  assign PSLVERR = xfer_done & xfer_err;

  //----------------------------------------------------------------------------
  // Write path: commit on the completion edge, only if no error, per PSTRB
  //----------------------------------------------------------------------------
  wire wr_en = xfer_done & PWRITE & ~xfer_err;

  integer i;

  always @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn) begin
      reg_ctrl    <= {DATA_WIDTH{1'b0}};
      reg_data    <= {DATA_WIDTH{1'b0}};
      reg_scratch <= {DATA_WIDTH{1'b0}};
    end else if (wr_en) begin
      for (i = 0; i < BYTE_LANES; i = i + 1) begin
        if (PSTRB[i]) begin
          case (word_idx)
            IDX_CTRL:    reg_ctrl[8*i +: 8]    <= PWDATA[8*i +: 8];
            IDX_DATA:    reg_data[8*i +: 8]    <= PWDATA[8*i +: 8];
            IDX_SCRATCH: reg_scratch[8*i +: 8] <= PWDATA[8*i +: 8];
            default: ;
          endcase
        end
      end
    end
  end

  //----------------------------------------------------------------------------
  // Read path: PRDATA is valid in the completion cycle of a read,
  // and driven to zero otherwise.
  //----------------------------------------------------------------------------
  reg [DATA_WIDTH-1:0] rdata_mux;

  always @* begin
    case (word_idx)
      IDX_CTRL:    rdata_mux = reg_ctrl;
      IDX_DATA:    rdata_mux = reg_data;
      IDX_STATUS:  rdata_mux = status_i;
      IDX_SCRATCH: rdata_mux = reg_scratch;
      default:     rdata_mux = {DATA_WIDTH{1'b0}};
    endcase
  end

  assign PRDATA = (access_phase & ~PWRITE & ~unaligned) ? rdata_mux
                                                         : {DATA_WIDTH{1'b0}};

endmodule
