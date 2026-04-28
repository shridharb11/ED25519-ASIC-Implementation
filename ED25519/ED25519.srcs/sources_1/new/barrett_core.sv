module barrett_core (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start_seq,
    input  logic [2:0]   seq_id, 
    
    // NEW: External Data Inputs (Driven by Testbench or Master FSM)
    input  logic [255:0] ext_data_1, 
    input  logic [255:0] ext_data_2, 
    input  logic [255:0] otp_data,   
    
    output logic         seq_done,
    output logic         math_error
);

    // --- Internal Traces (Wires) ---
    logic [3:0]   a_sel, b_sel, dest_sel;
    logic         reg_we, sel_hi, cmp_flag, mult_done;
    logic [2:0]   alu_op;
    logic [255:0] src_a, src_b, alu_result;
    logic         mult_kick;
    logic         mod_p_en; 
    logic [1:0]   data_sel;      // NEW: Wire from Sequencer to Mux
    logic [255:0] reg_write_data; // NEW: Output of the MUX

    // 1. The Brain
    micro_sequencer u_seq (
        .clk        (clk),
        .rst_n      (rst_n),
        .start_seq  (start_seq),
        .seq_id     (seq_id),
        .mult_done  (mult_done),
        .cmp_flag   (cmp_flag),
        .a_sel      (a_sel),
        .b_sel      (b_sel),
        .dest_sel   (dest_sel),
        .reg_we     (reg_we),
        .seq_done   (seq_done),
        .math_error (math_error),
        .alu_op     (alu_op),
        .mult_kick  (mult_kick),
        .sel_hi     (sel_hi),
        .mod_p_en   (mod_p_en),
        .data_sel   (data_sel) // Wire up the new selector
    );

    // --- THE DATA SELECTION MULTIPLEXER ---
    always_comb begin
        case (data_sel)
            2'b00: reg_write_data = alu_result;
            2'b01: reg_write_data = ext_data_1; // e.g., SHA Lower 256 bits
            2'b10: reg_write_data = ext_data_2; // e.g., SHA Upper 256 bits
            2'b11: reg_write_data = otp_data;   // e.g., Base Point Coordinates
            default: reg_write_data = alu_result;
        endcase
    end

    // 2. The Memory
    reg_file u_regs (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_enable  (reg_we),
        .wr_addr    (dest_sel),
        .data_in    (reg_write_data), // Drive with MUX output, not raw ALU
        .A_select   (a_sel),
        .A_out      (src_a),
        .B_select   (b_sel),
        .B_out      (src_b)
    );

    // 3. The Muscle
    alu_top u_alu (
        .clk        (clk),
        .rst_n      (rst_n),
        .src_a      (src_a),
        .src_b      (src_b),
        .alu_op     (alu_op),
        .sel_hi     (sel_hi),
        .mod_p_en   (mod_p_en), 
        .alu_result (alu_result),
        .cmp_flag   (cmp_flag),
        .mult_done  (mult_done),
        .mult_kick  (mult_kick)
    );

endmodule