//=============================================================================
// Module: fp8_sqrt_e4m3
// Description: FP8 E4M3 Square Root Unit (sqrt(a))
//              Simple algorithm optimized for small mantissa
// Format: E4M3 - 1 Sign bit, 4 Exponent bits, 3 Mantissa bits
// Author: Cognichip Co-Designer
//=============================================================================

module fp8_sqrt_e4m3 (
    input  logic       clock,
    input  logic       reset,
    input  logic       valid_in,      // Input valid signal
    input  logic [7:0] a,             // FP8 E4M3 input
    output logic [7:0] result,        // FP8 E4M3 result
    output logic       valid_out,     // Output valid signal
    output logic       invalid_op     // Invalid operation (sqrt of negative)
);

    //=========================================================================
    // FP8 E4M3 Format Parameters
    //=========================================================================
    localparam int EXPONENT_BIAS = 7;
    
    // Special value encodings
    localparam logic [7:0] FP8_ZERO_POS = 8'b0_0000_000;
    localparam logic [7:0] FP8_INF_POS  = 8'b0_1111_111;
    localparam logic [7:0] FP8_NAN      = 8'b0_1111_110;

    //=========================================================================
    // Pipeline Registers
    //=========================================================================
    // Stage 1: Unpack and classify
    logic        sign_s1;
    logic [3:0]  exp_s1;
    logic [2:0]  mant_s1;
    logic        is_zero_s1;
    logic        is_inf_s1;
    logic        is_nan_s1;
    logic        is_neg_s1;
    logic        valid_s1;
    

    // Stage 2: Compute square root
    logic        is_special_s2;
    logic [7:0]  special_result_s2;
    logic [3:0]  exp_result_s2;
    logic [7:0]  mant_sqrt_s2;     // Extended mantissa for sqrt
    logic        invalid_op_s2;
    logic        valid_s2;

    // Signals for Stage 2 computation
    logic [4:0] exp_biased;
    logic [3:0] mant_extended;
    logic [7:0] radicand;

    // Stage 3: Normalize and round
    logic [7:0]  result_s3;
    logic        invalid_op_s3;
    logic        valid_s3;
    // Signals for Stage 3
    logic [2:0] mant_final;
    logic [3:0] exp_final;

    // Stage 4: Output register (for consistent 4-cycle latency with FMA)
    logic [7:0]  result_s4;
    logic        invalid_op_s4;
    logic        valid_s4;

    //=========================================================================
    // Stage 1: Unpack and Classify
    //=========================================================================
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            sign_s1    <= 1'b0;
            exp_s1     <= 4'b0;
            mant_s1    <= 3'b0;
            is_zero_s1 <= 1'b0;
            is_inf_s1  <= 1'b0;
            is_nan_s1  <= 1'b0;
            is_neg_s1  <= 1'b0;
            valid_s1   <= 1'b0;
        end else begin
            sign_s1 <= a[7];
            exp_s1  <= a[6:3];
            mant_s1 <= a[2:0];
            
            is_zero_s1 <= (a[6:0] == 7'b0000_000);
            is_inf_s1  <= (a[6:3] == 4'b1111) && (a[2:0] == 3'b111);
            is_nan_s1  <= (a[6:3] == 4'b1111) && (a[2:0] != 3'b111);
            is_neg_s1  <= a[7] && (a[6:0] != 7'b0000_000);  // Negative non-zero
            
            valid_s1 <= valid_in;
        end
    end

    //=========================================================================
    // Stage 2: Square Root Computation
    //=========================================================================
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            is_special_s2     <= 1'b0;
            special_result_s2 <= 8'b0;
            exp_result_s2     <= 4'b0;
            mant_sqrt_s2      <= 8'b0;
            invalid_op_s2     <= 1'b0;
            valid_s2          <= 1'b0;
        end else begin
            invalid_op_s2 <= 1'b0;
            
            // Handle special cases
            if (is_nan_s1) begin
                // NaN propagation
                is_special_s2 <= 1'b1;
                special_result_s2 <= FP8_NAN;
            end else if (is_neg_s1) begin
                // Square root of negative number = NaN
                is_special_s2 <= 1'b1;
                special_result_s2 <= FP8_NAN;
                invalid_op_s2 <= 1'b1;
            end else if (is_zero_s1) begin
                // sqrt(0) = 0
                is_special_s2 <= 1'b1;
                special_result_s2 <= FP8_ZERO_POS;
            end else if (is_inf_s1) begin
                // sqrt(+Inf) = +Inf
                is_special_s2 <= 1'b1;
                special_result_s2 <= FP8_INF_POS;
            end else begin
                // Normal square root

                
                is_special_s2 <= 1'b0;
                
                // Compute exponent: (exp - bias) / 2 + bias
                // For even exponents: exp_result = (exp - 7) / 2 + 7
                // For odd exponents: need to adjust mantissa
                
                exp_biased = {1'b0, exp_s1} - EXPONENT_BIAS;
                
                if (exp_biased[0]) begin
                    // Odd exponent: multiply mantissa by 2 (shift left)
                    mant_extended = {1'b1, mant_s1};  // 1.xxx
                    radicand = {mant_extended, 4'b0};  // Shift left (multiply by 2)
                    exp_result_s2 <= ((exp_biased - 1) >> 1) + EXPONENT_BIAS;
                end else begin
                    // Even exponent
                    mant_extended = {1'b1, mant_s1};  // 1.xxx
                    radicand = {1'b0, mant_extended, 3'b0};  // Normal alignment
                    exp_result_s2 <= (exp_biased >> 1) + EXPONENT_BIAS;
                end
                
                // Compute square root of mantissa using digit-by-digit algorithm
                // For simplicity with FP8, use a small lookup/approximation
                // Extended to 8 bits for precision
                mant_sqrt_s2 <= sqrt_approx(radicand);
            end
            
            valid_s2 <= valid_s1;
        end
    end

    //=========================================================================
    // Square Root Approximation Function
    //=========================================================================
    function automatic logic [7:0] sqrt_approx(input logic [7:0] x);
        // Simple digit-by-digit square root for 8-bit value
        // Returns sqrt(x) * 16 (4-bit fractional result in upper 4 bits)
        logic [7:0] result;
        logic [7:0] remainder;
        logic [7:0] test_val;
        
        result = 8'b0;
        remainder = x;
        
        // Compute 4 bits of square root (enough for 3-bit mantissa + rounding)
        for (int i = 7; i >= 4; i--) begin
            test_val = {result[7:1], 1'b1};
            if ({remainder[7:1], 1'b0} >= test_val) begin
                remainder = {remainder[7:1], 1'b0} - test_val;
                result = {result[7:1], 1'b1};
            end else begin
                result = {result[7:1], 1'b0};
            end
        end
        
        return result;
    endfunction

    //=========================================================================
    // Stage 3: Normalize and Round
    //=========================================================================
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            result_s3     <= 8'b0;
            invalid_op_s3 <= 1'b0;
            valid_s3      <= 1'b0;
        end else begin
            invalid_op_s3 <= invalid_op_s2;
            
            if (is_special_s2) begin
                result_s3 <= special_result_s2;
            end else begin
                // Normalize and extract mantissa
                
                exp_final = exp_result_s2;
                
                // mant_sqrt_s2 has format: 1xxx.xxxx (leading 1 at bit 7)
                // Extract 3 bits of mantissa with rounding
                if (mant_sqrt_s2[4]) begin
                    // Round up
                    mant_final = mant_sqrt_s2[7:5] + 3'b001;
                    if (mant_final == 3'b000) begin
                        // Mantissa overflow
                        exp_final = exp_final + 4'b0001;
                    end
                end else begin
                    mant_final = mant_sqrt_s2[7:5];
                end
                
                result_s3 <= {1'b0, exp_final, mant_final};  // Always positive
            end
            
            valid_s3 <= valid_s2;
        end
    end

    //=========================================================================
    // Stage 4: Output Register
    //=========================================================================
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            result_s4     <= 8'b0;
            invalid_op_s4 <= 1'b0;
            valid_s4      <= 1'b0;
        end else begin
            result_s4     <= result_s3;
            invalid_op_s4 <= invalid_op_s3;
            valid_s4      <= valid_s3;
        end
    end

    //=========================================================================
    // Output Assignment
    //=========================================================================
    assign result     = result_s4;
    assign valid_out  = valid_s4;
    assign invalid_op = invalid_op_s4;

endmodule
