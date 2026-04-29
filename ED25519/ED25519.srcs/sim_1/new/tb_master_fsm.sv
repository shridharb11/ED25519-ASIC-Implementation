`timescale 1ns / 1ps

module tb_master_fsm;

    // --- Clocks and Resets ---
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk; // 100MHz (10ns period)

    // --- Top-Level Host Interface ---
    logic start_verify = 0;
    logic verify_done;
    logic signature_valid;

    // --- Internal Bus Wiring (FSM <-> Datapath) ---
    logic         w_start_seq;
    logic [2:0]   w_seq_id;
    logic         w_seq_done;
    logic         w_math_error;
    logic [1:0]   w_data_sel;
    logic [255:0] w_datapath_read_data;
    
    // External dummy wires (for future signature input)
    logic [255:0] ext_data_1 = '0;
    logic [255:0] ext_data_2 = '0;
    logic [255:0] otp_data   = '0;

    // --- Instantiate the Master FSM ---
    master_fsm u_fsm (
        .clk                (clk),
        .rst_n              (rst_n),
        .start_verify       (start_verify),
        .verify_done        (verify_done),
        .signature_valid    (signature_valid),
        .start_seq          (w_start_seq),
        .seq_id             (w_seq_id),
        .seq_done           (w_seq_done),
        .math_error         (w_math_error),
        .datapath_read_data (w_datapath_read_data),
        .data_sel           (w_data_sel)
    );

    // --- Instantiate the Datapath Engine ---
    barrett_core u_datapath (
        .clk        (clk),
        .rst_n      (rst_n),
        .start_seq  (w_start_seq),
        .seq_id     (w_seq_id),
        .data_sel   (w_data_sel), 
        .ext_data_1 (ext_data_1), 
        .ext_data_2 (ext_data_2), 
        .otp_data   (otp_data),   
        .seq_done   (w_seq_done),
        .math_error (w_math_error)
    );

    // THE CRITICAL FIX: Direct memory tap for the FSM scalar latch
    assign w_datapath_read_data = u_datapath.u_regs.mem[25];

    // --- Main Test Sequence ---
    initial begin
        int timeout_cycles = 0;
        
        // =========================================================
        // 🎛️ USER CONFIGURATION ZONE
        // =========================================================
        // Change this scalar to test different multiples of G!
        // (e.g., 256'd3, 256'd4, or a full 256-bit hex string)
        logic [255:0] test_scalar = 256'h4fe94d9006f020a5a3c080d96827fffd3c010ac0f12e7a42cb33284f86837c30;
        
        $display("=================================================");
        $display(" ED25519 Hardware Accelerator - Integration Test");
        $display("=================================================");
        $display("[HOST] Target Scalar (s) = %h", test_scalar);

        // =========================================================
        // 1. HARDWARE RESET
        // =========================================================
        rst_n = 0;
        #20 rst_n = 1;
        @(posedge clk); #1;

        // =========================================================
        // 2. LOAD CRYPTOGRAPHIC CONSTANTS
        // =========================================================
        // Base Point G
        u_datapath.u_regs.mem[4]  = 256'h216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51a; // Gx
        u_datapath.u_regs.mem[5]  = 256'h6666666666666666666666666666666666666666666666666666666666666658; // Gy
        u_datapath.u_regs.mem[6]  = 256'h0000000000000000000000000000000000000000000000000000000000000001; // Gz
        u_datapath.u_regs.mem[7]  = 256'h67875f0fd78b766566ea4e8e64abe37d20f09f80775152f56dde8ab3a5b7dda3; // Gt
        
        // Curve Constant 2d
        u_datapath.u_regs.mem[15] = 256'h2406d9dc56dffce7198e80f2eef3d13000e0149a8283b156ebd69b9426b2f159; 
        
        // Neutral Point (0, 1, 1, 0)
        u_datapath.u_regs.mem[26] = 256'd0; // Neut X
        u_datapath.u_regs.mem[27] = 256'd1; // Neut Y
        u_datapath.u_regs.mem[28] = 256'd1; // Neut Z
        u_datapath.u_regs.mem[29] = 256'd0; // Neut T

        // Load the User Scalar
        u_datapath.u_regs.mem[25] = test_scalar; 

        @(posedge clk); #1;

        // =========================================================
        // 3. START POINT MULTIPLICATION
        // =========================================================
        $display("[HOST] Constants loaded. Asserting start_verify...");
        start_verify = 1;
        @(posedge clk); #1;
        start_verify = 0;

        $display("[TEST] Computing P1 = s * G. Please wait...");

        // =========================================================
        // 4. WAIT FOR COMPLETION
        // =========================================================
        while (!verify_done) begin
            @(posedge clk);
            timeout_cycles++;
            
            // Timeout set to 150k to allow for massive scalars (worst-case ~130k cycles)
            if (timeout_cycles > 150000) begin 
                $display("\n[FATAL] Simulation Timeout at %0d cycles!", timeout_cycles);
                $display("  FSM State = %0d", u_fsm.state);
                $display("  Seq ID    = %0b", w_seq_id);
                $finish;
            end
        end

        // =========================================================
        // 5. REPORT RESULTS
        // =========================================================
        $display("\n=================================================");
        $display("[SUCCESS] Computation Finished in %0d cycles!", timeout_cycles);
        $display("=================================================");
        
        $display("Final Projective Coordinates (P1):");
        $display("  P1_X (REG[17]) = %h", u_datapath.u_regs.mem[17]);
        $display("  P1_Y (REG[18]) = %h", u_datapath.u_regs.mem[18]);
        $display("  P1_Z (REG[19]) = %h", u_datapath.u_regs.mem[19]);
        $display("  P1_T (REG[20]) = %h", u_datapath.u_regs.mem[20]);
        
        $display("\n[HOST] To verify against Python Reference:");
        $display("  run: to_affine(P1_X, P1_Y, P1_Z)");
        $display("=================================================\n");

        $finish;
    end

endmodule