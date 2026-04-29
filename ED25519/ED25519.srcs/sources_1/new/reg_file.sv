// =============================================================================
// Module:      reg_file.sv
// Project:     ED25519 Hardware Accelerator
// Description: 16 x 256-bit Register File
//              - Asynchronous (combinational) read ports with write-through forwarding
//              - Single write port, dual read port
//              - No reset on storage array (SRAM compatible)
//              - No output registers (async read means zero read latency)
//              - Active low async assert, sync deassert reset             
//
// DISCIPLINED REGISTER MAP:
// --- Active Execution Zone (0-15) ---
//   REG[0:3]   = Accumulator (X, Y, Z, T)   -> Actively mutating during loops
//   REG[4:7]   = Operand (X, Y, Z, T)       -> Actively read during Additions
//   REG[8:14]  = ALU Scratchpads (A-H)      -> Violently overwritten every cycle
//   REG[15]    = Constant 2d                -> Locked read-only during Point Math
//
// --- Persistent Storage Zone (16-31) ---
//   REG[16]    = Final Scalar (h)      -> Stored here post-Barrett
//   REG[17:20] = Final P1 (X, Y, Z, T)      -> Safely parked after Step 2
//   REG[21:24] = Final P2 (X, Y, Z, T)      -> Safely parked after Step 3
//   REG[25]    = s
//   REG[26:31] = RESERVED / UNUSED          -> Left empty deliberately
//
// We can always change the register mapping. There was also an idea of storing those constants in a ROM.
// =============================================================================

module reg_file #(
    parameter WIDTH = 256,
    parameter DEPTH = 32,
    parameter ADDR_W = $clog2(DEPTH)
)(
    input logic clk,
    input logic rst_n,
    
    //Write
    input logic wr_enable,
    input logic [ADDR_W-1:0] wr_addr,
    input logic [WIDTH-1:0] data_in,
    
    //Read port A
    input logic [ADDR_W-1:0] A_select,
    output logic [WIDTH-1:0] A_out,
    
    //Read port B
    input logic [ADDR_W-1:0] B_select,
    output logic [WIDTH-1:0] B_out  
    );
    
    //storage 
    logic [WIDTH-1:0] mem[0:DEPTH-1];
    
    always_ff @(posedge clk) begin
        if (wr_enable)
            mem[wr_addr] <= data_in;
    end
    
    // Read Port A (Asynchronous / Combinational)
    // If writing to the same address we are reading, forward the new data (write-through)
    assign A_out = (wr_enable && wr_addr == A_select) ? data_in : mem[A_select];

    // Read Port B (Asynchronous / Combinational)
    assign B_out = (wr_enable && wr_addr == B_select) ? data_in : mem[B_select];
    

       
endmodule
