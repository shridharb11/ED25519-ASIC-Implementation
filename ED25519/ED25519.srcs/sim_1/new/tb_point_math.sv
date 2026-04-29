`timescale 1ns / 1ps

module tb_point_math;

    // --- Clocks and Resets ---
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk; // 100MHz (10ns period)

    // --- DUT Signals ---
    logic       start_seq;
    logic [2:0] seq_id;
    logic       seq_done;
    logic       math_error;
    
    // Tie external data logic low for isolated math testing
    logic [1:0]   data_sel   = 2'b00; 
    logic [255:0] ext_data_1 = '0;
    logic [255:0] ext_data_2 = '0;
    logic [255:0] otp_data   = '0;

    // --- Instantiate the Top Module ---
    barrett_core dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start_seq  (start_seq),
        .seq_id     (seq_id),
        .data_sel   (data_sel),   // Driven by TB for now
        .ext_data_1 (ext_data_1), 
        .ext_data_2 (ext_data_2), 
        .otp_data   (otp_data),   
        .seq_done   (seq_done),
        .math_error (math_error)
    );

    initial begin
        int wait_cycles; 
        
        $display("========================================");
        $display(" Starting Point Math Hardware Test");
        $display("========================================");

        start_seq   = 0;
        seq_id      = 3'b000; 
        
        // 1. Reset
        #20 rst_n = 1;
        @(posedge clk);
        #1;

        // =========================================================
        // TEST 1: POINT DOUBLING (G -> 2G)
        // =========================================================
        $display("\n[TEST 1] Loading Base Point G into Accumulator (REG[0:3])...");
        
        // Paste the Python test vector generated for G here:
        dut.u_regs.mem[0] = 256'h216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51a; // Gx
        dut.u_regs.mem[1] = 256'h6666666666666666666666666666666666666666666666666666666666666658; // Gy
        dut.u_regs.mem[2] = 256'h0000000000000000000000000000000000000000000000000000000000000001; // Gz
        // (Ensure you paste the Python Gt value here)
        dut.u_regs.mem[3] = 256'h67875f0fd78b766566ea4e8e64abe37d20f09f80775152f56dde8ab3a5b7dda3; // Gt 

        seq_id = 3'b010; // POINT DOUBLE
        start_seq = 1;
        @(posedge clk); #1; start_seq = 0;

        wait_cycles = 0;
        while (!seq_done) begin
            @(posedge clk);
            wait_cycles++;
            if (wait_cycles > 500) begin
                $display("[FATAL] Point Double Timeout! Sequences took too long.");
                $finish;
            end
        end
        @(posedge clk); #1;

        $display("[SUCCESS] Point Double finished in %0d cycles.", wait_cycles);
        $display("Projective 2G X: %h", dut.u_regs.mem[0]);
        $display("Projective 2G Y: %h", dut.u_regs.mem[1]);
        $display("Projective 2G Z: %h", dut.u_regs.mem[2]);

        // =========================================================
        // TEST 2: POINT ADDITION (G + G -> 2G)
        // =========================================================
        $display("\n[TEST 2] Hard resetting Accumulator and Operand to G...");
        
        // 1. HARD RESET Accumulator (REG[0:3]) to Base Point G
        dut.u_regs.mem[0] = 256'h216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51a; 
        dut.u_regs.mem[1] = 256'h6666666666666666666666666666666666666666666666666666666666666658; 
        dut.u_regs.mem[2] = 256'h0000000000000000000000000000000000000000000000000000000000000001; 
        dut.u_regs.mem[3] = 256'h67875f0fd78b766566ea4e8e64abe37d20f09f80775152f56dde8ab3a5b7dda3; 
        
        // 2. HARD RESET Operand (REG[4:7]) to Base Point G
        dut.u_regs.mem[4] = 256'h216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51a; 
        dut.u_regs.mem[5] = 256'h6666666666666666666666666666666666666666666666666666666666666658; 
        dut.u_regs.mem[6] = 256'h0000000000000000000000000000000000000000000000000000000000000001; 
        dut.u_regs.mem[7] = 256'h67875f0fd78b766566ea4e8e64abe37d20f09f80775152f56dde8ab3a5b7dda3; 
        
        // 3. Load 2d constant into REG[15]
        dut.u_regs.mem[15] = 256'h2406d9dc56dffce7198e80f2eef3d13000e0149a8283b156ebd69b9426b2f159;
        seq_id = 3'b011; // POINT ADD
        start_seq = 1;
        @(posedge clk); #1; start_seq = 0;

        wait_cycles = 0;
        while (!seq_done) begin
            @(posedge clk);
            
            // --- REVIEWER DIAGNOSTIC TRACE ---
            if (dut.u_seq.reg_we) begin
                $display(" Step %0d done | R10(C)=%h R11(D)=%h R12(E)=%h R13(F)=%h", 
                    dut.u_seq.step_counter,
                    dut.u_regs.mem[10], // Printing lower 64 bits for readability
                    dut.u_regs.mem[11],
                    dut.u_regs.mem[12],
                    dut.u_regs.mem[13]);
            end
            // ---------------------------------

            wait_cycles++;
            if (wait_cycles > 500) begin
                $display("[FATAL] Point Add Timeout!");
                $finish;
            end
        end
        @(posedge clk); #1;

        $display("[SUCCESS] Point Add finished in %0d cycles.", wait_cycles);
        $display("Projective Add X: %h", dut.u_regs.mem[0]);
        $display("Projective Add Y: %h", dut.u_regs.mem[1]);
        $display("Projective Add Z: %h", dut.u_regs.mem[2]);
        $display("Projective Add T: %h", dut.u_regs.mem[3]); // T is now printed!
        $display("========================================");

        $finish;
    end
endmodule