`timescale 1ns/1ps
import sha512_pkg::*;

module tb_sha512_machine_code;

    localparam CLK_PERIOD = 10;
    localparam NUM_WORDS  = 65536;           // 65536 × 32-bit = 262144 bytes
    localparam MSG_BITS   = NUM_WORDS * 32;  // 2097152 bits

    logic        clk, rst_n;
    logic [5:0]  addr_i;
    logic        wr_en_i;
    logic [31:0] wdata_i;
    logic [31:0] rdata_o;
    logic        intr_o;

    sha512_top uut (
        .clk     (clk),
        .rst_n   (rst_n),
        .addr_i  (addr_i),
        .wr_en_i (wr_en_i),
        .wdata_i (wdata_i),
        .rdata_o (rdata_o),
        .intr_o  (intr_o)
    );

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic [31:0] machine_code [0:NUM_WORDS-1];

    task bus_idle();
        addr_i = 0; wdata_i = 0; wr_en_i = 0;
    endtask

    function automatic logic [31:0] bswap32(input logic [31:0] w);
        return {w[7:0], w[15:8], w[23:16], w[31:24]};
    endfunction

    task write_reg(input [5:0] addr, input [31:0] data);
        @(negedge clk);
        addr_i  = addr;
        wdata_i = data;
        wr_en_i = 1'b1;
        @(posedge clk);
        @(negedge clk);
        wr_en_i = 1'b0;
        addr_i  = 0;
        wdata_i = 0;
    endtask

    task read_reg(input [5:0] addr, output logic [31:0] data);
        @(negedge clk);
        addr_i  = addr;
        wr_en_i = 1'b0;
        @(posedge clk);
        #1;
        data = rdata_o;
        @(negedge clk);
        addr_i = 0;
    endtask

    task wait_done();
        @(posedge intr_o);
        @(posedge clk);
        @(posedge clk);
    endtask

    task wait_ready_fast();
        wait (uut.state == 3'd1 || uut.state == 3'd0);
        @(posedge clk);
    endtask

    task read_hash(output logic [511:0] hash);
        logic [31:0] word;
        for (int i = 0; i < 16; i++) begin
            read_reg(6'h22 + 6'(i), word);
            hash[511 - i*32 -: 32] = word;
        end
    endtask

    // -------------------------------------------------------
    // Main test
    // -------------------------------------------------------
    initial begin
        logic [511:0] got;
        logic [511:0] expected;

        // hash.hex has 16 lines of 8 hex chars each (32-bit words, MSW first)
        // $readmemh loads them cleanly into a 32-bit array
        begin
            logic [31:0] hash_words [0:15];
            $readmemh("hash.hex", hash_words);
            for (int i = 0; i < 16; i++)
                expected[511 - i*32 -: 32] = hash_words[i];
        end

        $readmemh("machine_code.hex", machine_code);

        bus_idle();
        rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        $display("--------------------------------------------------");
        $display("Test: machine_code.hex  (%0d bits)", MSG_BITS);
        $display("Expected: %0128h", expected);

        // 1. Write message length in 32-bit words
        write_reg(6'h32, NUM_WORDS);

        // 2. Start + init_first_block
        write_reg(6'h20, 32'h3);

        // 3. Stream words - byte-swap BE→LE, sync at block boundaries
        for (int i = 0; i < NUM_WORDS; i++) begin
            write_reg(6'(i % 32), bswap32(machine_code[i]));

            if ((i % 32) == 31 && i != (NUM_WORDS - 1)) begin
                wait_ready_fast();
            end
        end

        // 4. Wait for final interrupt
        wait_done();

        // 5. Read hash
        read_hash(got);

        // 6. Compare
        if (got === expected)
            $display("PASS: machine_code.hex");
        else begin
            $display("FAIL: machine_code.hex");
            $display("  Expected: %0128h", expected);
            $display("  Got     : %0128h", got);
        end

        $display("--------------------------------------------------");
        $finish;
    end

endmodule
