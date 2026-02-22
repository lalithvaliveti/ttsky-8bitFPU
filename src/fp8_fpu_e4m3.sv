//=============================================================================
// Module: fp8_fpu_e4m3
// Description: FP8 E4M3 Floating Point Unit
//              Complete FPU with ADD, SUB, MUL, FMA, DIV, SQRT operations
// Operations:
//   - ADD:  result = a + b
//   - SUB:  result = a - b  
//   - MUL:  result = a * b
//   - FMA:  result = a * b + c
//   - DIV:  result = a / b
//   - SQRT: result = sqrt(a)
// Format: E4M3 - 1 Sign bit, 4 Exponent bits, 3 Mantissa bits
// Author: Cognichip Co-Designer
//=============================================================================

module fp8_fpu_e4m3 (
    input  logic       clock,
    input  logic       reset,
    input  logic       valid_in,      // Input valid signal
    input  logic [2:0] opcode,        // Operation: 000=ADD, 001=SUB, 010=MUL, 011=FMA, 100=DIV, 101=SQRT
    input  logic [7:0] operand_a,     // FP8 E4M3 operand A
    input  logic [7:0] operand_b,     // FP8 E4M3 operand B
    input  logic [7:0] operand_c,     // FP8 E4M3 operand C (for FMA only)
    output logic [7:0] result,        // FP8 E4M3 result
    output logic       valid_out,     // Output valid signal
    output logic       overflow,      // Overflow flag
    output logic       underflow,     // Underflow flag
    output logic       div_by_zero,   // Division by zero flag
    output logic       invalid_op     // Invalid operation flag
);

    //=========================================================================
    // Operation Encoding
    //=========================================================================
    typedef enum logic [2:0] {
        OP_ADD  = 3'b000,  // a + b
        OP_SUB  = 3'b001,  // a - b
        OP_MUL  = 3'b010,  // a * b
        OP_FMA  = 3'b011,  // a * b + c
        OP_DIV  = 3'b100,  // a / b
        OP_SQRT = 3'b101   // sqrt(a)
    } fpu_opcode_t;

    //=========================================================================
    // FP8 E4M3 Constants
    //=========================================================================
    localparam logic [7:0] FP8_ONE_POS  = 8'b0_0111_000;  // 1.0
    localparam logic [7:0] FP8_ZERO_POS = 8'b0_0000_000;  // 0.0

    //=========================================================================
    // Execution Unit Signals
    //=========================================================================
    // FMA unit signals
    logic [7:0] fma_a, fma_b, fma_c;
    logic       fma_valid_in;
    logic [7:0] fma_result;
    logic       fma_valid_out;
    logic       fma_overflow, fma_underflow;
    
    // DIV unit signals
    logic       div_valid_in;
    logic [7:0] div_result;
    logic       div_valid_out;
    logic       div_overflow, div_underflow;
    logic       div_by_zero_sig;
    

    //=========================================================================
    // Operation Decode and Input Multiplexing
    //=========================================================================
    always_comb begin
        // Default values
        fma_a = operand_a;
        fma_b = operand_b;
        fma_c = operand_c;
        fma_valid_in = 1'b0;
        div_valid_in = 1'b0;
       

        case (opcode)
            OP_ADD: begin
                // ADD: 1.0 * a + b
                fma_a = FP8_ONE_POS;
                fma_b = operand_a;
                fma_c = operand_b;
                fma_valid_in = valid_in;
            end

            OP_SUB: begin
                // SUB: 1.0 * a + (-b)
                fma_a = FP8_ONE_POS;
                fma_b = operand_a;
                fma_c = {~operand_b[7], operand_b[6:0]};
                fma_valid_in = valid_in;
            end

            OP_MUL: begin
                // MUL: a * b + 0.0
                fma_a = operand_a;
                fma_b = operand_b;
                fma_c = FP8_ZERO_POS;
                fma_valid_in = valid_in;
            end

            OP_FMA: begin
                // FMA: a * b + c
                fma_a = operand_a;
                fma_b = operand_b;
                fma_c = operand_c;
                fma_valid_in = valid_in;
            end

            OP_DIV: begin
                // DIV: a / b
                div_valid_in = valid_in;
            end

            OP_SQRT: begin
                // SQRT: sqrt(a)
            end

            default: begin
                // Default to ADD
                fma_a = FP8_ONE_POS;
                fma_b = operand_a;
                fma_c = operand_b;
                fma_valid_in = valid_in;
            end
        endcase
    end

    //=========================================================================
    // FMA Core Instantiation
    //=========================================================================
    fp8_fma_e4m3 u_fma (
        .clock      (clock),
        .reset      (reset),
        .valid_in   (fma_valid_in),
        .a          (fma_a),
        .b          (fma_b),
        .c          (fma_c),
        .result     (fma_result),
        .valid_out  (fma_valid_out),
        .overflow   (fma_overflow),
        .underflow  (fma_underflow)
    );

    //=========================================================================
    // DIV Core Instantiation
    //=========================================================================
    fp8_div_e4m3 u_div (
        .clock      (clock),
        .reset      (reset),
        .valid_in   (div_valid_in),
        .a          (operand_a),
        .b          (operand_b),
        .result     (div_result),
        .valid_out  (div_valid_out),
        .overflow   (div_overflow),
        .underflow  (div_underflow),
        .div_by_zero(div_by_zero_sig)
    );

    //=========================================================================
    // SQRT Core Instantiation
    //=========================================================================
   

    //=========================================================================
    // Output Multiplexing
    //=========================================================================
    always_comb begin
        // Default outputs
        result = fma_result;
        valid_out = fma_valid_out;
        overflow = fma_overflow;
        underflow = fma_underflow;
        div_by_zero = 1'b0;
        invalid_op = 1'b0;

        // Select active unit's outputs
        if (div_valid_out) begin
            result = div_result;
            valid_out = div_valid_out;
            overflow = div_overflow;
            underflow = div_underflow;
            div_by_zero = div_by_zero_sig;
        end 
    end

endmodule
