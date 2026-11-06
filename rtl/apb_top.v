//==============================================================================
// apb_top.v
// Top level: apb_requester <==APB==> apb_completer
//
//   user request/response  -->  [apb_requester] ==APB bus== [apb_completer]
//                                                              |       ^
//                                                          ctrl_o   status_i
//==============================================================================
module apb_top #(
  parameter ADDR_WIDTH  = 8,
  parameter DATA_WIDTH  = 32,
  parameter WAIT_STATES = 0
)(
  input  wire                    PCLK,
  input  wire                    PRESETn,

  // User-side request interface (into the Requester)
  input  wire                    req_valid,
  output wire                    req_ready,
  input  wire                    req_write,
  input  wire [ADDR_WIDTH-1:0]   req_addr,
  input  wire [DATA_WIDTH-1:0]   req_wdata,
  input  wire [DATA_WIDTH/8-1:0] req_strb,
  input  wire [2:0]              req_prot,

  // User-side response interface (from the Requester)
  output wire                    rsp_valid,
  output wire [DATA_WIDTH-1:0]   rsp_rdata,
  output wire                    rsp_err,

  // Peripheral hardware side (Completer registers)
  input  wire [DATA_WIDTH-1:0]   status_i,
  output wire [DATA_WIDTH-1:0]   ctrl_o
);

  //----------------------------------------------------------------------------
  // APB bus between Requester and Completer
  //----------------------------------------------------------------------------
  wire [ADDR_WIDTH-1:0]   PADDR;
  wire [2:0]              PPROT;
  wire                    PSEL;
  wire                    PENABLE;
  wire                    PWRITE;
  wire [DATA_WIDTH-1:0]   PWDATA;
  wire [DATA_WIDTH/8-1:0] PSTRB;
  wire                    PREADY;
  wire [DATA_WIDTH-1:0]   PRDATA;
  wire                    PSLVERR;

  //----------------------------------------------------------------------------
  // Requester
  //----------------------------------------------------------------------------
  apb_requester #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_requester (
    .PCLK       (PCLK),
    .PRESETn    (PRESETn),

    .req_valid  (req_valid),
    .req_ready  (req_ready),
    .req_write  (req_write),
    .req_addr   (req_addr),
    .req_wdata  (req_wdata),
    .req_strb   (req_strb),
    .req_prot   (req_prot),

    .rsp_valid  (rsp_valid),
    .rsp_rdata  (rsp_rdata),
    .rsp_err    (rsp_err),

    .PADDR      (PADDR),
    .PPROT      (PPROT),
    .PSEL       (PSEL),
    .PENABLE    (PENABLE),
    .PWRITE     (PWRITE),
    .PWDATA     (PWDATA),
    .PSTRB      (PSTRB),
    .PREADY     (PREADY),
    .PRDATA     (PRDATA),
    .PSLVERR    (PSLVERR)
  );

  //----------------------------------------------------------------------------
  // Completer
  //----------------------------------------------------------------------------
  apb_completer #(
    .ADDR_WIDTH  (ADDR_WIDTH),
    .DATA_WIDTH  (DATA_WIDTH),
    .WAIT_STATES (WAIT_STATES)
  ) u_completer (
    .PCLK       (PCLK),
    .PRESETn    (PRESETn),

    .PADDR      (PADDR),
    .PPROT      (PPROT),
    .PSEL       (PSEL),
    .PENABLE    (PENABLE),
    .PWRITE     (PWRITE),
    .PWDATA     (PWDATA),
    .PSTRB      (PSTRB),
    .PREADY     (PREADY),
    .PRDATA     (PRDATA),
    .PSLVERR    (PSLVERR),

    .status_i   (status_i),
    .ctrl_o     (ctrl_o)
  );

endmodule
