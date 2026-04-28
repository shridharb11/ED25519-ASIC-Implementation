`timescale 1ns/1ps 
import sha512_pkg::*;

module tb_sha512_top;

    localparam CLK_PERIOD = 10;

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

    task bus_idle();
        addr_i = 0; wdata_i = 0; wr_en_i = 0;
    endtask

    // Byte-reverse a 32-bit word (big-endian to little-endian)
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
        fork
            begin //: w fork
                @(posedge intr_o);
            end
            begin// : t fork
                #500000;
                $display("TIMEOUT!");
                $finish;
            end
        join_any
        disable fork;
        @(posedge clk);
        @(posedge clk);
    endtask

    // Read hash - rdata_o already byte-swaps back, pack MSW first
    task read_hash(output logic [511:0] hash);
        logic [31:0] word;
        for (int i = 0; i < 16; i++) begin
            read_reg(6'h22 + 6'(i), word);
            hash[511 - i*32 -: 32] = word;
        end
    endtask
    
    task wait_ready();
        logic [31:0] stat;
        do begin
            read_reg(6'h21, stat);
        end while (stat[0] == 1'b0);
    endtask

    // --------------------------------------------------------
    // run_test
    //
    // msg_words[]: big-endian 32-bit words of the message,
    //              MSW first. e.g. "abcd" = '{32'h61626364}
    // num_words  : number of 32-bit words
    // msg_len_bits: bit length of message
    //
    // Write protocol:
    //   For each 64-bit word pair (slots 2k, 2k+1):
    //     - High half (msg_words[2k],   big-endian) → odd addr  (2k+1)
    //       written as bswap so scheduler re-swaps to correct BE value
    //     - Low  half (msg_words[2k+1], big-endian) → even addr (2k)
    //       written as bswap
    //   If num_words is odd, the last word has no low-half pair;
    //   write zero to the even addr so word_count stays aligned.
    // --------------------------------------------------------
    task run_test(
        input string      test_name,
        input [31:0]      msg_words [],
        input int         num_words,
        input [31:0]      msg_len_bits,
        input [511:0]     expected
    );
        logic [511:0] got;
        int           slot;
        begin
            $display("--------------------------------------------------");
            $display("Test: %s (%0d bits)", test_name, msg_len_bits);

            // 1. Write message length in 32-bit words
            write_reg(6'h32, msg_len_bits >> 5);

            // 2. Start + init_first_block
            write_reg(6'h20, 32'h3);

            // 3. Write message words
            //    Pair up into 64-bit words. For each pair:
            //      slot 2k+1 (odd,  high half) ← msg_words[2k]   byte-reversed
            //      slot 2k   (even, low  half) ← msg_words[2k+1] byte-reversed
            //    If num_words is odd, last high-half has no partner → write 0 to even slot
            slot = 0;
            for (int i = 0; i < num_words; i++) begin
                // Wrap address modulo 32 to stay within the scheduler memory map
                write_reg(6'(i % 32), msg_words[i]);
                
                // If we just filled a 32-word block, and it's not the final word, 
                // wait for the FSM to process the block and return to S_RECV
                if ((i % 32) == 31 && i != (num_words - 1)) begin
                    wait_ready();
                end
            end

            // 4. Wait
            wait_done();

            // 5. Read hash
            read_hash(got);

            // 6. Compare
            if (got === expected)
                $display("PASS: %s", test_name);
            else begin
                $display("FAIL: %s", test_name);
                $display("  Expected: %0128h", expected);
                $display("  Got     : %0128h", got);
            end

            repeat(5) @(posedge clk);
        end
    endtask

    initial begin
        bus_idle();
        rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        // TEST 1: "abcd" - 1 word, 32 bits
        // Big-endian: 0x61626364
        begin
            automatic logic [31:0] msg [] = '{32'h64636261};
            run_test("abcd", msg, 1, 32,
                512'hd8022f2060ad6efd297ab73dcc5355c9b214054b0d1776a136a669d26a7d3b14f73aa0d0ebff19ee333368f0164b6419a96da49e3e481753e7e96b716bdccb6f
            );
        end

        // TEST 2: "12345678" - 2 words, 64 bits
        // Big-endian: 0x31323334 35363738
        begin
            automatic logic [31:0] msg [] = '{32'h34333231, 32'h38373635};
            run_test("12345678", msg, 2, 64,
                512'hfa585d89c851dd338a70dcf535aa2a92fee7836dd6aff1226583e88e0996293f16bc009c652826e0fc5c706695a03cddce372f139eff4d13959da6f1f5d3eabe
            );
        end

        // TEST 3: "ABCDEFGHIJKLMNOP" - 4 words, 128 bits
        begin
        automatic logic [31:0] msg [] = '{      
            32'h44434241, 32'h48474645,
            32'h4C4B4A49, 32'h504F4E4D
        };
            run_test("ABCDEFGHIJKLMNOP", msg, 4, 128,
                512'hd8793427996dc6d27e3b09a4666a4ba403331859ef548ffc71f81ba717a3e7e9321c35eeca408f2a373ae684f5ff8b04204f64f7542e420a3621bba9597d4d51
            );
        end
        
        begin
        automatic logic [31:0] msg [] = '{
        };
            run_test("", msg, 0, 0,
                512'hcf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e
            );
        end
        
        begin
    automatic logic [31:0] msg [] = '{
        32'h33323130, // "0123"
        32'h37363534, // "4567"
        32'h42413938, // "89AB"
        32'h46454443, // "CDEF"
        32'h4A494847, // "GHIJ"
        32'h4E4D4C4B, // "KLMN"
        32'h5251504F, // "OPQR"
        32'h56555453, // "STUV"
        32'h5A595857, // "WXYZ"
        32'h64636261, // "abcd"
        32'h68676665, // "efgh"
        32'h6C6B6A69, // "ijkl"
        32'h706F6E6D, // "mnop"
        32'h74737271, // "qrst"
        32'h78777675, // "uvwx"
        32'h2B2B7A79, // "yz++"
        32'h33323130, // "0123"
        32'h37363534, // "4567"
        32'h42413938, // "89AB"
        32'h46454443, // "CDEF"
        32'h4A494847, // "GHIJ"
        32'h4E4D4C4B, // "KLMN"
        32'h5251504F, // "OPQR"
        32'h56555453, // "STUV"
        32'h5A595857, // "WXYZ"
        32'h64636261, // "abcd"
        32'h68676665, // "efgh"
        32'h6C6B6A69, // "ijkl"
        32'h706F6E6D, // "mnop"
        32'h74737271, // "qrst"
        32'h78777675, // "uvwx"
        32'h2B2B7A79, // "yz++"
        32'h33323130  // "0123"
    };
    run_test(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz++0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz++0123", msg, 33, 1056,
        512'h1b4f844688a95e262e55d68129b113520cacc38adc1066bbe654ade911385536e180a098f7fd661f4040c4b4daffa6c6445fc4b5ff9de1d06aef511945a82aa1
    );
end

        begin
    automatic logic [31:0] msg [] = '{
        32'h33323130, // "0123"
        32'h37363534, // "4567"
        32'h42413938, // "89AB"
        32'h46454443, // "CDEF"
        32'h4A494847, // "GHIJ"
        32'h4E4D4C4B, // "KLMN"
        32'h5251504F, // "OPQR"
        32'h56555453, // "STUV"
        32'h5A595857, // "WXYZ"
        32'h64636261, // "abcd"
        32'h68676665, // "efgh"
        32'h6C6B6A69, // "ijkl"
        32'h706F6E6D, // "mnop"
        32'h74737271, // "qrst"
        32'h78777675, // "uvwx"
        32'h2B2B7A79, // "yz++"
        32'h33323130, // "0123"
        32'h37363534, // "4567"
        32'h42413938, // "89AB"
        32'h46454443, // "CDEF"
        32'h4A494847, // "GHIJ"
        32'h4E4D4C4B, // "KLMN"
        32'h5251504F, // "OPQR"
        32'h56555453, // "STUV"
        32'h5A595857, // "WXYZ"
        32'h64636261, // "abcd"
        32'h68676665, // "efgh"
        32'h6C6B6A69, // "ijkl"
        32'h706F6E6D, // "mnop"
        32'h74737271, // "qrst"
        32'h78777675
    };
    run_test(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz++0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwx", msg, 31, 992,
        512'hf74e0f5f91dc55e83892754d68a44a60d976bf8d7abbf16c5436167bed486c73959d006a6c41c010daead5cdc28a03430dbe4e73be4960e77a8bf5eb6c5d5f9e
    );
end

        begin
    automatic logic [31:0] msg [] = '{
        32'h33323130, // "0123"
        32'h37363534, // "4567"
        32'h42413938, // "89AB"
        32'h46454443, // "CDEF"
        32'h4A494847, // "GHIJ"
        32'h4E4D4C4B, // "KLMN"
        32'h5251504F, // "OPQR"
        32'h56555453, // "STUV"
        32'h5A595857, // "WXYZ"
        32'h64636261, // "abcd"
        32'h68676665, // "efgh"
        32'h6C6B6A69, // "ijkl"
        32'h706F6E6D, // "mnop"
        32'h74737271, // "qrst"
        32'h78777675, // "uvwx"
        32'h2B2B7A79, // "yz++"
        32'h33323130, // "0123"
        32'h37363534, // "4567"
        32'h42413938, // "89AB"
        32'h46454443, // "CDEF"
        32'h4A494847, // "GHIJ"
        32'h4E4D4C4B, // "KLMN"
        32'h5251504F, // "OPQR"
        32'h56555453, // "STUV"
        32'h5A595857, // "WXYZ"
        32'h64636261, // "abcd"
        32'h68676665, // "efgh"
        32'h6C6B6A69, // "ijkl"
        32'h706F6E6D, // "mnop"
        32'h74737271, // "qrst"
        32'h78777675, // "uvwx"
        32'h2B2B7A79 // "yz++"
    };
    run_test(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz++0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz++", msg, 32, 1024,
        512'h548296782539d1422471958f9e9a2a480aab390f6c7eb2fa88eeeb45844b9b40ed483354e3b860341ae3ee9e1edbb1cafd631fa314d69dbf366b3be2d05a77c0
    );
end
        $display("--------------------------------------------------");
        $display("All tests done.");
        $finish;
    end

endmodule
