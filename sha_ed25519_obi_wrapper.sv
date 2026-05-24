// =============================================================================
// sha_ed25519_obi_wrapper.sv
//
// OBI slave CSR wrapper for the SHA+ED25519 accelerator (top_ed25519).
//
// Base address: 0x0005_0000  (4KB window, addr[11:0] used)
//
// Register map:
//   0x000 — CRYPTO_CTRL  (RW)
//             [0] start   : write 1 to assert start_verify for one cycle
//                           self-clearing. Read always returns 0.
//   0x004 — CRYPTO_STATUS (RO)
//             [0] verify_done    : high when ED25519 verification complete
//             [1] signature_valid: high when signature verified OK
//
// OBI handshake:
//   - gnt combinational (always-ready, no backpressure)
//   - rvalid registered, one cycle after granted read
//   - err permanently 0
//
// Assumption: start_verify on top_ed25519 is level-sensitive for one cycle.
//             The wrapper pulses it for exactly one clock cycle on a write-1
//             to CRYPTO_CTRL[0], then self-clears.
// =============================================================================

module sha_ed25519_obi_wrapper (
  input  logic clk_i,
  input  logic rst_ni,

  // OBI subordinate interface (flat)
  input  logic        req_i,
  input  logic        we_i,
  input  logic [ 3:0] be_i,
  input  logic [31:0] addr_i,
  input  logic [31:0] wdata_i,
  output logic        gnt_o,
  output logic        rvalid_o,
  output logic [31:0] rdata_o,
  output logic        err_o,

  // top_ed25519 control/status ports
  output logic        start_verify_o,   // pulses for one cycle
  input  logic        verify_done_i,
  input  logic        signature_valid_i
);

  // --------------------------------------------------------------------------
  // Register address offsets
  // --------------------------------------------------------------------------
  localparam logic [11:0] CRYPTO_CTRL_OFF   = 12'h000;
  localparam logic [11:0] CRYPTO_STATUS_OFF = 12'h004;

  // --------------------------------------------------------------------------
  // OBI handshake — always-ready, single cycle
  // --------------------------------------------------------------------------
  assign gnt_o = req_i;
  assign err_o = 1'b0;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) rvalid_o <= 1'b0;
    else         rvalid_o <= req_i & gnt_o;
  end

  // --------------------------------------------------------------------------
  // start_verify — pulse for one cycle on write-1 to CRYPTO_CTRL[0]
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      start_verify_o <= 1'b0;
    end else begin
      // Self-clear every cycle by default
      start_verify_o <= 1'b0;
      // Set for one cycle on a granted write to CRYPTO_CTRL with bit 0 high
      if (req_i && gnt_o && we_i &&
          addr_i[11:0] == CRYPTO_CTRL_OFF &&
          be_i[0] && wdata_i[0]) begin
        start_verify_o <= 1'b1;
      end
    end
  end

  // --------------------------------------------------------------------------
  // Read data — registered, returned with rvalid one cycle after request
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rdata_o <= 32'h0;
    end else begin
      if (req_i && gnt_o && !we_i) begin
        case (addr_i[11:0])
          CRYPTO_CTRL_OFF: begin
            // start bit always reads 0 (self-clearing)
            rdata_o <= 32'h0;
          end
          CRYPTO_STATUS_OFF: begin
            rdata_o <= {30'h0, signature_valid_i, verify_done_i};
          end
          default: begin
            rdata_o <= 32'hDEAD_BEEF;
          end
        endcase
      end
    end
  end

endmodule
