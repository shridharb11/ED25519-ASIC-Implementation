`timescale 1ns / 1ps

module tb_master_fsm;

    // --- Clocks and Resets ---
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk; // 100MHz

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
    
    // External dummy wires
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

    // Tap the register file's A port so the FSM can read 's' during the LOAD_S state
    assign w_datapath_read_data = u_datapath.u_regs.A_out;

    initial begin
        int timeout_cycles = 0;

        $display("========================================");
        $display(" Starting Master FSM Phase 2 Test");
        $display("========================================");

        // 1. Apply Reset
        #20 rst_n = 1;
        @(posedge clk); #1;

        // =========================================================
        // PRE-LOAD THE CONSTANTS (Acting as the RISC-V Host)
        // =========================================================
        $display("[HOST] Loading Cryptographic Constants...");
        
        // 1. Base Point G into REG[4:7]
        u_datapath.u_regs.mem[4] = 256'h216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51a;
        u_datapath.u_regs.mem[5] = 256'h6666666666666666666666666666666666666666666666666666666666666658;
        u_datapath.u_regs.mem[6] = 256'h0000000000000000000000000000000000000000000000000000000000000001;
        u_datapath.u_regs.mem[7] = 256'h67875f0fd78b766566ea4e8e64abe37d20f09f80775152f56dde8ab3a5b7dda3;
        
        // 2. The 2d Curve Constant into REG[15]
        u_datapath.u_regs.mem[15] = 256'h2406d9dc56dffce7198e80f2eef3d13000e0149a8283b156ebd69b9426b2f159;

        // 3. The Neutral Point (0, 1, 1, 0) into REG[26:29]
        u_datapath.u_regs.mem[26] = 256'h0000000000000000000000000000000000000000000000000000000000000000;
        u_datapath.u_regs.mem[27] = 256'h0000000000000000000000000000000000000000000000000000000000000001;
        u_datapath.u_regs.mem[28] = 256'h0000000000000000000000000000000000000000000000000000000000000001;
        u_datapath.u_regs.mem[29] = 256'h0000000000000000000000000000000000000000000000000000000000000000;

        // 4. Load the target scalar 's' into REG[25]
        // Setting to 2. This means P1 = 2 * G
        u_datapath.u_regs.mem[25] = 256'h0000000000000000000000000000000000000000000000000000000000000002;

        // =========================================================
        // START THE FSM
        // =========================================================
        $display("[HOST] Asserting start_verify...");
        start_verify = 1;
        @(posedge clk); #1; 
        start_verify = 0;

        $display("[TEST] Master FSM is calculating P1 = s * G. Please wait... (Expected ~40,000 cycles)");

        // Wait for the Master FSM to finish all 256 iterations
        while (!verify_done) begin
            @(posedge clk);
            timeout_cycles++;
            
            // 256 doublings * ~120 cycles + 1 addition * ~200 cycles = roughly 31,000 cycles.
            // Safety timeout set to 50,000.
            if (timeout_cycles > 75000) begin
                $display("[FATAL] Master FSM Timeout! Something got stuck.");
                $finish;
            end
        end

        // After verify_done, before $finish — add these diagnostic prints:
        $display("\n=== DIAGNOSTIC DUMP ===");

        // 1. Did INIT_NEUTRAL actually write the neutral point?
        $display("REG[0] (should be 0): %h", u_datapath.u_regs.mem[0]);
        $display("REG[1] (should be 1): %h", u_datapath.u_regs.mem[1]);
        $display("REG[2] (should be 1): %h", u_datapath.u_regs.mem[2]);
        $display("REG[3] (should be 0): %h", u_datapath.u_regs.mem[3]);

        // 2. Did the scalar latch correctly in the FSM?
        $display("FSM scalar_reg (should be 2): %h", u_fsm.scalar_reg);

        // 3. Check scratch registers — did any multiply ever produce a valid result?
        $display("REG[8]  (scratch A): %h", u_datapath.u_regs.mem[8]);
        $display("REG[9]  (scratch B): %h", u_datapath.u_regs.mem[9]);

        // 4. Are the neutral point source registers intact?
        $display("REG[26] (neutral X=0): %h", u_datapath.u_regs.mem[26]);
        $display("REG[27] (neutral Y=1): %h", u_datapath.u_regs.mem[27]);

        // 5. Is G still in REG[4:7]?
        $display("REG[4]  (Gx): %h", u_datapath.u_regs.mem[4]);
        $display("REG[5]  (Gy): %h", u_datapath.u_regs.mem[5]);

        // 6. Is s still in REG[25]?
        $display("REG[25] (s=2): %h", u_datapath.u_regs.mem[25]);

        // 7. Final accumulator state
        $display("REG[0:3] final accumulator:");
        $display("  X: %h", u_datapath.u_regs.mem[0]);
        $display("  Y: %h", u_datapath.u_regs.mem[1]);
        $display("  Z: %h", u_datapath.u_regs.mem[2]);
        $display("  T: %h", u_datapath.u_regs.mem[3]);

        @(posedge clk); #1;

        $display("========================================");
        $display("[SUCCESS] Phase 2 Finished in %0d clock cycles!", timeout_cycles);
        $display("========================================");
        
        $display("Final P1 Coordinates (Stored in REG[17:20]):");
        $display("P1_X = %h", u_datapath.u_regs.mem[17]);
        $display("P1_Y = %h", u_datapath.u_regs.mem[18]);
        $display("P1_Z = %h", u_datapath.u_regs.mem[19]);
        $display("P1_T = %h", u_datapath.u_regs.mem[20]);

        $finish;
    end

endmodule