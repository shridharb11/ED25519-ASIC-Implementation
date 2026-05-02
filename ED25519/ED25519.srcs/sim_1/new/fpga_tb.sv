`timescale 1ns / 1ps

module tb_fpga_demo_top();

    // --------------------------------------------------------
    // Testbench Signals
    // --------------------------------------------------------
    logic clk;
    logic rst_n;
    logic start_demo;
    logic demo_done;
    logic signature_valid;

    // --------------------------------------------------------
    // Clock Generation (100 MHz for Nexys 4)
    // --------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk; // 10 ns period
    end

    // --------------------------------------------------------
    // Device Under Test (DUT)
    // --------------------------------------------------------
    fpga_demo_top dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start_demo     (start_demo),
        .demo_done      (demo_done),
        .signature_valid(signature_valid)
    );

    // --------------------------------------------------------
    // Test Sequence
    // --------------------------------------------------------
    initial begin
        // 1. Initialize Inputs
        rst_n      = 1'b0;
        start_demo = 1'b0;

        $display("==================================================");
        $display("[%0t] ED25519 FPGA Integration Test Started", $time);
        $display("==================================================");

        // 2. Apply Reset
        #50;
        rst_n = 1'b1;
        #50;

        // 3. Trigger the Master FSM
        $display("[%0t] Pushing 'start_demo' button...", $time);
        @(posedge clk);
        start_demo = 1'b1;
        @(posedge clk);
        start_demo = 1'b0; // Pulse for 1 clock cycle

        // 4. Wait for Completion with a Timeout Fork
        fork
            begin
                // Thread A: Wait for the demo to finish naturally
                wait(demo_done == 1'b1);
                
                $display("==================================================");
                $display("[%0t] TEST COMPLETE: 'demo_done' asserted!", $time);
                
                // Check the validity of the signature
                if (signature_valid) begin
                    $display(">> VERDICT: [ PASS ] Signature is VALID.");
                end else begin
                    $display(">> VERDICT: [ FAIL ] Signature is INVALID.");
                end
                $display("==================================================");
            end
            
            begin
                // Thread B: Watchdog Timer (Timeout)
                // Adjust this time based on how many cycles your Ed25519 core takes!
                // SHA-512 takes ~80 cycles per block, Ed25519 typically takes hundreds of thousands.
                #50000000; // 50ms timeout at 100MHz
                
                $display("==================================================");
                $display("[%0t] ERROR: SIMULATION TIMEOUT!", $time);
                $display("The system did not assert 'demo_done' in time.");
                $display("Check FSM states or Ed25519 core completion signal.");
                $display("==================================================");
                $stop;
            end
        join_any // Stop waiting as soon as one of the threads finishes

        // 5. End Simulation cleanly
        $finish;
    end

    // --------------------------------------------------------
    // Waveform Generation (Optional)
    // --------------------------------------------------------
    initial begin
        $dumpfile("fpga_demo_waves.vcd");
        // Dump all signals in the testbench and DUT
        $dumpvars(0, tb_fpga_demo_top);
    end

endmodule