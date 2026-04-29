module micro_sequencer (
    input  logic        clk, rst_n, start_seq, mult_done, cmp_flag,
    input  logic [2:0]  seq_id,

    output logic [4:0]  a_sel, b_sel, dest_sel,
    output logic        reg_we, seq_done, math_error,
    output logic [2:0]  alu_op,
    output logic        sel_hi,
    output logic        mult_kick,
    output logic        mod_p_en
    
);
    // --- ALU Opcodes ---
    localparam OP_ADD     = 3'b000;
    localparam OP_SUB_CND = 3'b001;
    localparam OP_MULT    = 3'b010;
    localparam OP_CMP     = 3'b011;
    localparam OP_PASS    = 3'b100;
    localparam OP_SUB_RAW = 3'b101;

    typedef enum logic [2:0] { S_IDLE, S_START, S_WAIT_DROP, S_EXE, S_WRITE } sub_step_t;
    sub_step_t sub_step;
    logic [5:0] step_counter;


    // --- Internal Wires & Registers ---
    logic rom_is_last_step;
    logic rom_panic;
    
    logic seq_done_reg;
    logic math_error_reg;
    logic rom_use_cmp_flag;

    // Drive outputs from clean flip-flops
    assign seq_done   = seq_done_reg;
    assign math_error = math_error_reg;

    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            step_counter   <= 0;
            sub_step       <= S_IDLE;
            reg_we         <= 1'b0;
            seq_done_reg   <= 1'b0;
            math_error_reg <= 1'b0;
        end else begin
            reg_we <= 1'b0; // Default clear

            case (sub_step)
                S_IDLE: begin
                    seq_done_reg   <= 1'b0;
                    math_error_reg <= 1'b0;
                    if (start_seq) begin
                        step_counter <= 0;
                        sub_step     <= S_START;
                    end
                end
                
                S_START: begin
                    // If it's a multiply, go to the new wait state so 'done' can fall.
                    // If combinational, skip directly to EXE to save cycles!
                    if (rom_alu_op == 3'b010) sub_step <= S_WAIT_DROP; 
                    else                      sub_step <= S_EXE;       
                end
                
                S_WAIT_DROP: begin
                    // The multiplier has now safely pulled 'done' to 0.
                    sub_step <= S_EXE; 
                end
                
                S_EXE: begin
                    // Now we safely wait for 'done' to rise back to 1.
                    if (rom_alu_op != 3'b010 || mult_done) begin
                        sub_step <= S_WRITE;
                        reg_we   <= 1'b1;
                    end
                end
                
                S_WRITE: begin
                    if (rom_is_last_step || rom_panic) begin
                        seq_done_reg   <= 1'b1;
                        math_error_reg <= rom_panic ? 1'b1 : (rom_use_cmp_flag ? cmp_flag : 1'b0); 
                        sub_step       <= S_IDLE;
                    end else begin
                        step_counter <= step_counter + 1;
                        sub_step     <= S_START;
                    end
                end
                
                default: sub_step <= S_IDLE;
            endcase
        end
    end

    
    // Notice: sub_step is NO LONGER in this block. No combinational loops!
    logic [2:0] rom_alu_op;    

    always_comb begin
        // Defaults to prevent latches
        a_sel = '0; b_sel = '0; dest_sel = '0; sel_hi = '0;
        rom_alu_op = OP_PASS; // Drive the temporary wire
        rom_is_last_step = 1'b0;
        rom_panic        = 1'b0;
        mod_p_en         = 1'b0;        
        rom_use_cmp_flag = 1'b0;
        
        if (seq_id == 3'b001) begin // BARRETT SEQUENCE
            case (step_counter)
                // UPDATE THESE TO DRIVE rom_alu_op INSTEAD OF alu_op
                5'd0:  begin a_sel = 5'd9;  b_sel = 5'd10; rom_alu_op = OP_MULT;    sel_hi = 1'b0; dest_sel = 5'd15; end
                5'd1:  begin a_sel = 5'd9;  b_sel = 5'd12; rom_alu_op = OP_MULT;    sel_hi = 1'b1; dest_sel = 5'd13; end
                5'd2:  begin a_sel = 5'd15; b_sel = 5'd13; rom_alu_op = OP_ADD;     sel_hi = 1'b0; dest_sel = 5'd15; end
                5'd3:  begin a_sel = 5'd8;  b_sel = 5'd10; rom_alu_op = OP_MULT;    sel_hi = 1'b1; dest_sel = 5'd13; end
                5'd4:  begin a_sel = 5'd15; b_sel = 5'd13; rom_alu_op = OP_ADD;     sel_hi = 1'b0; dest_sel = 5'd9;  end
                5'd5:  begin a_sel = 5'd9;  b_sel = 5'd11; rom_alu_op = OP_MULT;    sel_hi = 1'b0; dest_sel = 5'd15; end
                5'd6:  begin a_sel = 5'd8;  b_sel = 5'd15; rom_alu_op = OP_SUB_RAW; sel_hi = 1'b0; dest_sel = 5'd15; end
                5'd7:  begin a_sel = 5'd15; b_sel = 5'd11; rom_alu_op = OP_SUB_CND; sel_hi = 1'b0; dest_sel = 5'd15; end
                5'd8:  begin a_sel = 5'd15; b_sel = 5'd11; rom_alu_op = OP_SUB_CND; sel_hi = 1'b0; dest_sel = 5'd15; end
                5'd9:  begin a_sel = 5'd15; b_sel = 5'd11; rom_alu_op = OP_SUB_CND; sel_hi = 1'b0; dest_sel = 5'd15; end
                5'd10: begin 
                    a_sel = 5'd15; b_sel = 5'd11; rom_alu_op = OP_CMP; sel_hi = 1'b0; dest_sel = 5'd16; 
                    rom_is_last_step = 1'b1; 
                    rom_use_cmp_flag = 1'b1;
                end
                default: begin 
                    rom_alu_op = OP_PASS; 
                    rom_is_last_step = 1'b1; 
                    rom_panic = 1'b1; 
                end
            endcase
        end

        // =====================================================================
        // 2. POINT DOUBLING (14 Cycles)
        // Accumulator: REG[0:3] | Scratch: REG[8:14]
        // =====================================================================
        else if (seq_id == 3'b010) begin 
            mod_p_en = 1'b1; 
            case (step_counter)
                5'd0:  begin a_sel = 5'd0;  b_sel = 5'd0;  rom_alu_op = OP_MULT;    dest_sel = 5'd8;  end // A = X1^2
                5'd1:  begin a_sel = 5'd1;  b_sel = 5'd1;  rom_alu_op = OP_MULT;    dest_sel = 5'd9;  end // B = Y1^2
                5'd2:  begin a_sel = 5'd2;  b_sel = 5'd2;  rom_alu_op = OP_MULT;    dest_sel = 5'd10; end // Zsq = Z1^2
                5'd3:  begin a_sel = 5'd10; b_sel = 5'd10; rom_alu_op = OP_ADD;     dest_sel = 5'd10; end // C = 2 * Zsq
                5'd4:  begin a_sel = 5'd0;  b_sel = 5'd1;  rom_alu_op = OP_ADD;     dest_sel = 5'd11; end // X+Y
                5'd5:  begin a_sel = 5'd11; b_sel = 5'd11; rom_alu_op = OP_MULT;    dest_sel = 5'd11; end // Sxy = (X+Y)^2
                5'd6:  begin a_sel = 5'd8;  b_sel = 5'd9;  rom_alu_op = OP_ADD;     dest_sel = 5'd12; end // H = A + B
                5'd7:  begin a_sel = 5'd11; b_sel = 5'd12; rom_alu_op = OP_SUB_RAW; dest_sel = 5'd11; end // E = Sxy - H
                5'd8:  begin a_sel = 5'd9;  b_sel = 5'd8;  rom_alu_op = OP_SUB_RAW; dest_sel = 5'd13; end // G = B - A
                5'd9:  begin a_sel = 5'd10; b_sel = 5'd13; rom_alu_op = OP_SUB_RAW; dest_sel = 5'd14; end // F = C - G
                5'd10: begin a_sel = 5'd11; b_sel = 5'd14; rom_alu_op = OP_MULT;    dest_sel = 5'd0;  end // X3 = E * F
                5'd11: begin a_sel = 5'd13; b_sel = 5'd12; rom_alu_op = OP_MULT;    dest_sel = 5'd1;  end // Y3 = G * H
                5'd12: begin a_sel = 5'd11; b_sel = 5'd12; rom_alu_op = OP_MULT;    dest_sel = 5'd3;  end // T3 = E * H
                5'd13: begin a_sel = 5'd14; b_sel = 5'd13; rom_alu_op = OP_MULT;    dest_sel = 5'd2; rom_is_last_step = 1'b1; end // Z3 = F * G
                default: begin rom_alu_op = OP_PASS; rom_is_last_step = 1'b1; rom_panic = 1'b1; end
            endcase
        end

        // =====================================================================
        // 3. POINT ADDITION (18 Cycles)
        // Accumulator: REG[0:3] | Operand: REG[5:7] | Constant 2d: REG[15]
        // =====================================================================
        else if (seq_id == 3'b011) begin 
            mod_p_en = 1'b1; 
            case (step_counter)
                5'd0:  begin a_sel = 5'd1;  b_sel = 5'd0;  rom_alu_op = OP_SUB_RAW; dest_sel = 5'd8;  end 
                5'd1:  begin a_sel = 5'd5;  b_sel = 5'd4;  rom_alu_op = OP_SUB_RAW; dest_sel = 5'd9;  end 
                5'd2:  begin a_sel = 5'd8;  b_sel = 5'd9;  rom_alu_op = OP_MULT;    dest_sel = 5'd8;  end // A
                5'd3:  begin a_sel = 5'd1;  b_sel = 5'd0;  rom_alu_op = OP_ADD;     dest_sel = 5'd9;  end 
                5'd4:  begin a_sel = 5'd5;  b_sel = 5'd4;  rom_alu_op = OP_ADD;     dest_sel = 5'd10; end 
                5'd5:  begin a_sel = 5'd9;  b_sel = 5'd10; rom_alu_op = OP_MULT;    dest_sel = 5'd9;  end // B
                5'd6:  begin a_sel = 5'd15; b_sel = 5'd7;  rom_alu_op = OP_MULT;    dest_sel = 5'd10; end 
                5'd7:  begin a_sel = 5'd3;  b_sel = 5'd10; rom_alu_op = OP_MULT;    dest_sel = 5'd10; end // C
                5'd8:  begin a_sel = 5'd6;  b_sel = 5'd6;  rom_alu_op = OP_ADD;     dest_sel = 5'd11; end 
                5'd9:  begin a_sel = 5'd2;  b_sel = 5'd11; rom_alu_op = OP_MULT;    dest_sel = 5'd11; end // D
                5'd10: begin a_sel = 5'd9;  b_sel = 5'd8;  rom_alu_op = OP_SUB_RAW; dest_sel = 5'd12; end // E
                5'd11: begin a_sel = 5'd9;  b_sel = 5'd8;  rom_alu_op = OP_ADD;     dest_sel = 5'd8;  end // H
                5'd12: begin a_sel = 5'd11; b_sel = 5'd10; rom_alu_op = OP_SUB_RAW; dest_sel = 5'd13; end // F
                5'd13: begin a_sel = 5'd11; b_sel = 5'd10; rom_alu_op = OP_ADD;     dest_sel = 5'd14; end // G
                5'd14: begin a_sel = 5'd12; b_sel = 5'd13; rom_alu_op = OP_MULT;    dest_sel = 5'd0;  end // X3
                5'd15: begin a_sel = 5'd14; b_sel = 5'd8;  rom_alu_op = OP_MULT;    dest_sel = 5'd1;  end // Y3
                5'd16: begin a_sel = 5'd12; b_sel = 5'd8;  rom_alu_op = OP_MULT;    dest_sel = 5'd3;  end // T3
                5'd17: begin a_sel = 5'd13; b_sel = 5'd14; rom_alu_op = OP_MULT;    dest_sel = 5'd2; rom_is_last_step = 1'b1; end // Z3
                default: begin rom_alu_op = OP_PASS; rom_is_last_step = 1'b1; rom_panic = 1'b1; end
            endcase
        end

        // =====================================================================
        // 4. EXPORT SCALAR S (1 Cycle)
        // Reads REG[25] so Master FSM can latch it. Writes back to itself.
        // =====================================================================
        else if (seq_id == 3'b101) begin
            case (step_counter)
                5'd0: begin a_sel = 5'd25; b_sel = 5'd0; rom_alu_op = OP_PASS; dest_sel = 5'd25; rom_is_last_step = 1'b1; end
                default: begin rom_alu_op = OP_PASS; rom_is_last_step = 1'b1; rom_panic = 1'b1; end
            endcase
        end

        // =====================================================================
        // 5. SAVE P1 (4 Cycles)
        // Copies Accumulator REG[0:3] to Persistent Storage REG[17:20]
        // =====================================================================
        else if (seq_id == 3'b110) begin
            case (step_counter)
                5'd0: begin a_sel = 5'd0; b_sel = 5'd0; rom_alu_op = OP_PASS; dest_sel = 5'd17; end
                5'd1: begin a_sel = 5'd1; b_sel = 5'd0; rom_alu_op = OP_PASS; dest_sel = 5'd18; end
                5'd2: begin a_sel = 5'd2; b_sel = 5'd0; rom_alu_op = OP_PASS; dest_sel = 5'd19; end
                5'd3: begin a_sel = 5'd3; b_sel = 5'd0; rom_alu_op = OP_PASS; dest_sel = 5'd20; rom_is_last_step = 1'b1; end
                default: begin rom_alu_op = OP_PASS; rom_is_last_step = 1'b1; rom_panic = 1'b1; end
            endcase
        end

        // =====================================================================
        // 6. INIT NEUTRAL POINT (4 Cycles)
        // Copies Neutral Point from REG[26:29] to Accumulator REG[0:3]
        // =====================================================================
        else if (seq_id == 3'b111) begin
            case (step_counter)
                5'd0: begin a_sel = 5'd26; b_sel = 5'd0; rom_alu_op = OP_PASS; dest_sel = 5'd0; end
                5'd1: begin a_sel = 5'd27; b_sel = 5'd0; rom_alu_op = OP_PASS; dest_sel = 5'd1; end
                5'd2: begin a_sel = 5'd28; b_sel = 5'd0; rom_alu_op = OP_PASS; dest_sel = 5'd2; end
                5'd3: begin a_sel = 5'd29; b_sel = 5'd0; rom_alu_op = OP_PASS; dest_sel = 5'd3; rom_is_last_step = 1'b1; end
                default: begin rom_alu_op = OP_PASS; rom_is_last_step = 1'b1; rom_panic = 1'b1; end
            endcase
        end
    end

    // THE FIX: Only send the opcode to the ALU during S_EXE!
    // During S_WRITE or S_IDLE, force it to OP_PASS to reset the edge detector.
    assign alu_op = rom_alu_op;
    assign mult_kick = (sub_step == S_WAIT_DROP);
    

endmodule