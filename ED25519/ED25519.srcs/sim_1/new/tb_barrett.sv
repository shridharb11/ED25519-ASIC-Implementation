`timescale 1ns / 1ps

module tb_barrett;

    // --- Clocks and Resets ---
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk; // 100MHz (10ns period)

    // --- DUT Signals ---
    logic       start_seq;
    logic [2:0] seq_id;
    logic       seq_done;
    logic       math_error;

    // --- Instantiate the Top Module ---
    barrett_core dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start_seq  (start_seq),
        .seq_id     (seq_id),
        .seq_done   (seq_done),
        .math_error (math_error)
    );

    // --- DATAPATH X-RAY TRACER ---
    always @(posedge clk) begin
        if (dut.u_seq.reg_we) begin
            $display("[TRACE] Step %0d | Wrote %h into REG[%0d]", 
                     dut.u_seq.step_counter, 
                     dut.u_alu.alu_result, 
                     dut.u_seq.dest_sel);
        end
    end

    initial begin
        // ---------------------------------------------------------
        // DECLARE VARIABLES AT THE TOP (Strict SystemVerilog Rule)
        // ---------------------------------------------------------
        int wait_cycles; 
        
        $display("========================================");
        $display(" Starting Full Barrett Sequence Test");
        $display("========================================");

        // Initialize inputs
        start_seq   = 0;
        seq_id      = 3'b001; // ID for Barrett sequence
        wait_cycles = 0; 
        
        // 1. Reset the system
        #20 rst_n = 1;
        @(posedge clk);
        #1;

        // 2. BACKDOOR MEMORY LOAD
        dut.u_regs.mem[8]  = 256'hff0e88ea09f81e6f1997b85154842b4d4f4cea72e493c4152a4bf5dc0a599c13; // H_lo
        dut.u_regs.mem[9]  = 256'hec2c4f79d24938d2000df7649d46ea9a0a1d9238fcf9abbb15149d1a95368ae6; // H_hi
        dut.u_regs.mem[10] = 256'h000000000000000000000000000000000000000000000000000000000000000f; // mu_hi
        dut.u_regs.mem[11] = 256'h1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed; // q
        dut.u_regs.mem[12] = 256'hffffffffffffffffffffffffffffffeb2106215d086329a7ed9ce5a30a2c131b; // mu_lo

        
        $display("[INFO] Registers loaded. Firing sequence...");

        // 3. Trigger the Micro-Sequencer
        start_seq = 1;
        @(posedge clk); 
        #1; // Hold for 1 clock cycle
        start_seq = 0;

        // 4. Wait for Sequence to Finish (Timeout fail-safe active)
        while (!seq_done) begin
            @(posedge clk);
            wait_cycles++;
            if (wait_cycles > 500) begin
                $display("[FATAL] Sequencer Timeout! Stuck in infinite loop.");
                $finish;
            end
        end
        
        // 5. Read the final result
        // According to your ROM Step 10, the final reduced scalar is 
        // written to Register 12 (dest_sel = 12)
        @(posedge clk); 
        #1;
        
        $display("========================================");
        if (math_error) begin
            $display("[FAIL] Sequence finished but raised MATH_ERROR (r >= q)!");
            $display("       Result = %h", dut.u_regs.mem[15]);
        end else begin
            // With S_FETCH removed, this should run noticeably faster!
            $display("[SUCCESS] Sequence Finished cleanly in %0d cycles!", wait_cycles);
            $display("Final Reduced Scalar = %h", dut.u_regs.mem[15]);
        end
        $display("========================================");
        
        $finish;
    end
endmodule