module master_fsm (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start_verify,
    
    // Status to Top-Level / RISC-V Host
    output logic         verify_done,
    output logic         signature_valid,

    // Micro-Sequencer Interface
    output logic         start_seq,
    output logic [2:0]   seq_id,
    input  logic         seq_done,
    input  logic         math_error,
    
    // Datapath Data Interface
    input  logic [255:0] datapath_read_data, // Tapped from RegFile A_out
    output logic [1:0]   data_sel            // Controls the Datapath input MUX
);

    // --- State Encoding ---
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_LOAD_S,       // Trigger sequence to output REG[25]        
        ST_INIT_S2,      // Trigger sequence to write Neutral Point to REG[0:3]
        
        // Step 2: P1 = s * G Loop
        ST_S2_DOUBLE,
        ST_S2_CHECK_BIT,
        ST_S2_ADD,
        ST_S2_SHIFT,
        ST_S2_SAVE_P1,   // Trigger sequence to copy REG[0:3] -> REG[17:20]
        
        ST_DONE
    } state_t;

    state_t state, next_state;

    // --- Internal Shadow Registers ---
    logic [255:0] scalar_reg;
    logic [7:0]   bit_counter;
    logic         current_msb;
    
    assign current_msb = scalar_reg[255]; // Always look at the top bit

    // --- Sequential Logic (State, Shift, Counter) ---
    logic start_seq_reg;
    assign start_seq = start_seq_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            start_seq_reg <= 1'b0;
            bit_counter <= 8'd255;
            scalar_reg  <= 256'd0;
        end else begin
            state <= next_state;

            // Pulse start_seq_reg for exactly 1 cycle when entering a new active state
            if ((next_state != state) && (
                next_state == ST_LOAD_S    ||
                next_state == ST_INIT_S2   ||
                next_state == ST_S2_DOUBLE ||
                next_state == ST_S2_ADD    ||
                next_state == ST_S2_SAVE_P1
            )) begin
                start_seq_reg <= 1'b1;
            end else begin
                start_seq_reg <= 1'b0;
            end
            
            // Latch the scalar 's' when the datapath exposes it
            if (state == ST_LOAD_S && seq_done) begin
                scalar_reg <= datapath_read_data;
                bit_counter <= 8'd255; // Reset counter for the loop
            end
            // Shift left and decrement counter after each loop iteration
            else if (state == ST_S2_SHIFT) begin
                scalar_reg  <= scalar_reg << 1;
                bit_counter <= bit_counter - 1;
            end
        end
    end

    
    // --- Combinational Logic (Next State & Outputs) ---
    always_comb begin
        // Defaults
        next_state  = state;        
        seq_id      = 3'b000;
        data_sel    = 2'b00;
        verify_done = 1'b0;
        signature_valid = 1'b0;

        
        case (state)
            ST_IDLE: begin
                if (start_verify) next_state = ST_LOAD_S;
            end
            
            // 1. EXTRACT 's'
            ST_LOAD_S: begin
                seq_id = 3'b101;                  
                if (seq_done) next_state = ST_INIT_S2;
            end

                        
            // 3. INITIALIZE NEUTRAL POINT
            ST_INIT_S2: begin
                seq_id = 3'b111;                 
                if (seq_done) next_state = ST_S2_DOUBLE;
            end

            // ==========================================
            // STEP 2: LOOP (P1 = s * G)
            // ==========================================
            ST_S2_DOUBLE: begin
                seq_id = 3'b010;                 
                if (seq_done) next_state = ST_S2_CHECK_BIT;
            end
            
            ST_S2_CHECK_BIT: begin
                if (current_msb) next_state = ST_S2_ADD;
                else             next_state = ST_S2_SHIFT;
            end
            
            ST_S2_ADD: begin
                seq_id = 3'b011;                 
                if (seq_done) next_state = ST_S2_SHIFT;
            end
            
            ST_S2_SHIFT: begin
                // Maintained 8'd0 check. 256 perfectly counted iterations.
                if (bit_counter == 8'd0) next_state = ST_S2_SAVE_P1;
                else                     next_state = ST_S2_DOUBLE;
            end
            
            // ==========================================
            // SAVE RESULT AND FINISH
            // ==========================================
            ST_S2_SAVE_P1: begin
                seq_id = 3'b110;                 
                if (seq_done) next_state = ST_DONE; 
            end

            ST_DONE: begin
                verify_done = 1'b1;
            end
            
            default: next_state = ST_IDLE;
        endcase
    end
endmodule