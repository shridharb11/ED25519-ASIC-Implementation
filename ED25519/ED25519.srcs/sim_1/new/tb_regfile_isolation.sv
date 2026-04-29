`timescale 1ns / 1ps

module tb_regfile_isolation;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic        wr_enable = 0;
    logic [4:0]  wr_addr   = 0;
    logic [255:0] data_in  = 0;
    logic [4:0]  A_select  = 0;
    logic [255:0] A_out;
    logic [4:0]  B_select  = 0;
    logic [255:0] B_out;

    reg_file u_regs (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_enable(wr_enable),
        .wr_addr  (wr_addr),
        .data_in  (data_in),
        .A_select (A_select),
        .A_out    (A_out),
        .B_select (B_select),
        .B_out    (B_out)
    );

    initial begin
        $display("=== REG FILE ISOLATION TEST ===");
        $display("DEPTH=%0d ADDR_W=%0d", u_regs.DEPTH, u_regs.ADDR_W);

        // Reset
        rst_n = 0;
        #20 rst_n = 1;
        @(posedge clk); #1;

        // TEST 1: Write to REG[25] via the actual write port
        $display("\n[TEST 1] Writing 0xDEAD to REG[25] via wr_enable...");
        wr_addr   = 5'd25;
        data_in   = 256'hDEAD;
        wr_enable = 1;
        @(posedge clk); #1;
        wr_enable = 0;

        // Read it back
        A_select = 5'd25;
        #1;
        $display("REG[25] readback: %h (expect 000...DEAD)", A_out);
        if (A_out === 256'hDEAD)
            $display("[PASS] Write port works correctly.");
        else
            $display("[FAIL] Write port broken! Got %h", A_out);

        // TEST 2: Write to REG[4] and REG[5]
        $display("\n[TEST 2] Writing known values to REG[4] and REG[5]...");
        wr_addr   = 5'd4;
        data_in   = 256'hAAAA;
        wr_enable = 1;
        @(posedge clk); #1;

        wr_addr   = 5'd5;
        data_in   = 256'hBBBB;
        @(posedge clk); #1;
        wr_enable = 0;

        A_select = 5'd4; B_select = 5'd5;
        #1;
        $display("REG[4]: %h (expect AAAA)", A_out);
        $display("REG[5]: %h (expect BBBB)", B_out);

        // TEST 3: Backdoor write - does it stick?
        $display("\n[TEST 3] Backdoor write to REG[10]...");
        u_regs.mem[10] = 256'hCAFE;
        #1;
        A_select = 5'd10;
        #1;
        $display("REG[10] after backdoor: %h (expect CAFE)", A_out);
        if (A_out === 256'hCAFE)
            $display("[PASS] Backdoor write works.");
        else
            $display("[FAIL] Backdoor write lost! Vivado is overwriting it.");

        // TEST 4: Does a clock edge after backdoor write preserve the value?
        $display("\n[TEST 4] Clock edge after backdoor write...");
        u_regs.mem[11] = 256'hF00D;
        @(posedge clk); #1;  // clock with wr_enable=0
        A_select = 5'd11;
        #1;
        $display("REG[11] after clock: %h (expect F00D)", A_out);
        if (A_out === 256'hF00D)
            $display("[PASS] Backdoor write survives clock edge.");
        else
            $display("[FAIL] Backdoor write wiped by clock edge!");

        $display("\n=== DONE ===");
        $finish;
    end

endmodule