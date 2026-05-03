`timescale 1ns / 1ps

// =============================================================================
// Testbench: tb_golden_top
// DUT:       top_ed25519
// Vector:    TV3 — Custom Bootloader Sequence
//
// pubKey = 65aca07edafd4c58ad156f5ab8c47add5f1a6036339133e160edfa654087b234
// sig_R  = 2a06b3b03e37ffce5b5f688a4e42d562f7ea59f804e6f443b5a0821a14defa68
// sig_S  = e0c52a27f59fd2fd971c5d4ac97da751d2b28568f1169ec8cee73616f1e2ac0c
// hash   = 2b923230ddff5b8afc30db54fadc2ea54671cc40b76855f09eb620718f97a112
//          8b2283f771ce4fc7f28b755e103040dc20fe324f910c72ebdf5e52bba7901ae1
//
// Register pre-load strategy:
//   The reg_file has no dedicated init port. We use SystemVerilog hierarchical
//   references to directly initialise mem[] before reset is released.
//   All writes happen while rst_n=0, so the FSM never sees a partial state.
// =============================================================================

module tb_golden_top;

    // -------------------------------------------------------------------------
    // Clock & reset
    // -------------------------------------------------------------------------
    logic clk     = 0;
    logic rst_n   = 0;
    always #5 clk = ~clk;          // 100 MHz

    // -------------------------------------------------------------------------
    // DUT ports
    // -------------------------------------------------------------------------
    logic         start_verify = 0;
    logic [255:0] ext_data_1   = '0;
    logic [255:0] ext_data_2   = '0;
    logic [255:0] otp_data     = '0;
    logic [1:0]   data_sel     = 2'b00;
    logic         verify_done;
    logic         signature_valid;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    top_ed25519 dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .start_verify    (start_verify),
        .ext_data_1      (ext_data_1),
        .ext_data_2      (ext_data_2),
        .otp_data        (otp_data),
        .data_sel        (data_sel),
        .verify_done     (verify_done),
        .signature_valid (signature_valid)
    );

    // -------------------------------------------------------------------------
    // Hierarchical shorthand for the register file memory array
    // -------------------------------------------------------------------------
    // Adjust the path if your elaborator uses a different hierarchy separator.
    `define MEM dut.u_regs.mem

    // -------------------------------------------------------------------------
    // Constants (all values already in little-endian integer form as the
    // Python model uses int.from_bytes(..., 'little'))
    // -------------------------------------------------------------------------

    // --- Curve / hardware constants ---
    localparam logic [255:0] CONST_ZERO  = 256'd0;
    localparam logic [255:0] CONST_ONE   = 256'd1;

    localparam logic [255:0] CURVE_D =
        256'h52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3;

    localparam logic [255:0] CURVE_2D =
        256'h2406d9dc56dffce7198e80f2eef3d13000e0149a8283b156ebd69b9426b2f159;

    localparam logic [255:0] SQRT_M1 =
        256'h2b8324804fc1df0b2b4d00993dfbd7a72f431806ad2fe478c4ee1b274a0ea0b0;

    // --- Base point G (extended coordinates, Z=1) ---
    localparam logic [255:0] G_X =
        256'h216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51a;

    localparam logic [255:0] G_Y =
        256'h6666666666666666666666666666666666666666666666666666666666666658;

    localparam logic [255:0] G_Z = 256'd1;

    localparam logic [255:0] G_T =
        256'h67875f0fd78b766566ea4e8e64abe37d20f09f80775152f56dde8ab3a5b7dda3;

    // --- Barrett reduction constants (mod L) ---
    localparam logic [255:0] BARRETT_MU_HI = 
        256'h000000000000000000000000000000000000000000000000000000000000000f;

    localparam logic [255:0] CURVE_ORDER_L = 
        256'h1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed;

    localparam logic [255:0] BARRETT_MU_LO = 
        256'hffffffffffffffffffffffffffffffeb2106215d086329a7ed9ce5a30a2c131b;

    // --- Endian-Corrected SystemVerilog Constants ---
    localparam logic [255:0] TV3_PUB_KEY =
        256'h34b2874065faed60e133913336601a5fdd7ac4b85a6f15ad584cfdda7ea0ac65;

    localparam logic [255:0] TV3_SIG_R =
        256'h68fade141a82a0b543f4e604f859eaf762d5424e8a685f5bceff373eb0b3062a;

    localparam logic [255:0] TV3_SIG_S =
        256'h0cace2f11636e7cec89e16f16885b2d251a77dc94a5d1c97fdd29ff5272ac5e0;

    // HASH_LO is the reversed FIRST 32 bytes of the SHA-512 digest
    localparam logic [255:0] HASH_LO =
        256'h12a1978f7120b69ef05568b740cc7146a52edcfa54db30fc8a5bffdd3032922b;

    // HASH_HI is the reversed LAST 32 bytes of the SHA-512 digest
    localparam logic [255:0] HASH_HI =
        256'he11a90a7bb525edfeb720c914f32fe20dc4030105e758bf2c74fce71f783228b;

    // -------------------------------------------------------------------------
    // Timeout watchdog
    // -------------------------------------------------------------------------
    localparam integer TIMEOUT_CYCLES = 5_000_000;
    integer cycle_count = 0;

    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (cycle_count >= TIMEOUT_CYCLES) begin
            $display("[TIMEOUT] Simulation exceeded %0d cycles — aborting.", TIMEOUT_CYCLES);
            $finish;
        end
    end

    // -------------------------------------------------------------------------
    // Main stimulus
    // -------------------------------------------------------------------------
    initial begin
        // ------------------------------------------------------------------
        // 1. Hold reset, pre-load register file via hierarchical reference
        //    All writes are invisible to the FSM while rst_n=0.
        // ------------------------------------------------------------------
        rst_n = 0;
        @(posedge clk); #1;    // let elaboration settle

        // --- Hardware constants (persistent zone, REG 24-28) ---
        `MEM[24] = CONST_ZERO;       // zero
        `MEM[25] = CONST_ONE;        // one
        `MEM[26] = CURVE_D;          // Edwards d
        `MEM[27] = CURVE_2D;         // 2d
        `MEM[28] = SQRT_M1;          // sqrt(-1)

        // --- Base point G (REG 4-7) ---
        `MEM[4]  = G_X;
        `MEM[5]  = G_Y;
        `MEM[6]  = G_Z;
        `MEM[7]  = G_T;

        // --- Barrett constants for mod-L reduction (REG 8-12) ---
        // Seq 0 (Barrett reduction) reads:
        //   REG[8]  = hash_lo   (H lo-256)
        //   REG[9]  = hash_hi   (H hi-256)
        //   REG[10] = mu_hi
        //   REG[11] = L  (curve order)
        //   REG[12] = mu_lo
        `MEM[8]  = HASH_LO;
        `MEM[9]  = HASH_HI;
        `MEM[10] = BARRETT_MU_HI;
        `MEM[11] = CURVE_ORDER_L;
        `MEM[12] = BARRETT_MU_LO;

        // --- Test vector inputs ---
        `MEM[20] = TV3_SIG_R;        // compressed R
        `MEM[21] = TV3_PUB_KEY;      // compressed A (pubKey)
        `MEM[23] = TV3_SIG_S;        // scalar s

        $display("=============================================================");
        $display("  TB: Register file pre-loaded.");
        $display("  TV3 — Custom Bootloader Sequence");
        $display("  pubKey = %h", TV3_PUB_KEY);
        $display("  sig_R  = %h", TV3_SIG_R);
        $display("  sig_S  = %h", TV3_SIG_S);
        $display("  H_lo   = %h", HASH_LO);
        $display("  H_hi   = %h", HASH_HI);
        $display("=============================================================");

        // ------------------------------------------------------------------
        // 2. Release reset
        // ------------------------------------------------------------------
        repeat (4) @(posedge clk);
        rst_n = 1;
        $display("[%0t] Reset released.", $time);

        // ------------------------------------------------------------------
        // 3. Pulse start_verify for one cycle
        // ------------------------------------------------------------------
        @(posedge clk); #1;
        start_verify = 1;
        @(posedge clk); #1;
        start_verify = 0;
        $display("[%0t] start_verify pulsed — FSM running.", $time);

        // ------------------------------------------------------------------
        // 4. Wait for verify_done
        // ------------------------------------------------------------------
        @(posedge clk);
        wait (verify_done === 1'b1);
        @(posedge clk); // let signature_valid settle

        // ------------------------------------------------------------------
        // 5. Report result
        // ------------------------------------------------------------------
        $display("=============================================================");
        if (signature_valid === 1'b1)
            $display("  [PASS] VALID Ed25519 signature — signature_valid = 1");
        else
            $display("  [FAIL] INVALID signature — signature_valid = 0");
        $display("  Total cycles: %0d", cycle_count);
        $display("=============================================================");

        // ------------------------------------------------------------------
        // 6. Optional: dump a few internal registers for debug
        // ------------------------------------------------------------------
        $display("\n--- Key register dump (post-verification) ---");
        $display("  REG[16] h scalar = %h", `MEM[16]);
        $display("  REG[17] P1_X     = %h", `MEM[17]);
        $display("  REG[18] P1_Y     = %h", `MEM[18]);
        $display("  REG[19] P1_Z     = %h", `MEM[19]);
        $display("  REG[0]  P2_X     = %h", `MEM[0]);
        $display("  REG[1]  P2_Y     = %h", `MEM[1]);
        $display("  REG[2]  P2_Z     = %h", `MEM[2]);
        $display("  REG[20] R_X      = %h", `MEM[20]);
        $display("  REG[21] R_Y      = %h", `MEM[21]);

        $finish;
    end

    // -------------------------------------------------------------------------
    // Optional waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_golden_top.vcd");
        $dumpvars(0, tb_golden_top);
    end

endmodule