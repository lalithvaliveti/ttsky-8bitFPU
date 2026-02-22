//=============================================================================
// Module: fp8_fma_e4m3
// Description: FP8 E4M3 Fused Multiply-Add Unit (A * B + C)
//              Optimized for AI/ML workloads with native FP8 computation
// Format: E4M3 - 1 Sign bit, 4 Exponent bits, 3 Mantissa bits
// Author: Cognichip Co-Designer
//=============================================================================

module fp8_fma_e4m3 (
    input  logic       clock,
    input  logic       reset,
    input  logic       valid_in,      // Input valid signal
    input  logic [7:0] a,             // FP8 E4M3 operand A
    input  logic [7:0] b,             // FP8 E4M3 operand B
    input  logic [7:0] c,             // FP8 E4M3 operand C
    output logic [7:0] result,        // FP8 E4M3 result
    output logic       valid_out,     // Output valid signal
    output logic       overflow,      // Overflow flag
    output logic       underflow      // Underflow flag
);

    //=========================================================================
    // FP8 E4M3 Format Parameters
    //=========================================================================
    localparam int EXPONENT_BITS = 4;
    localparam int MANTISSA_BITS = 3;
    localparam int EXPONENT_BIAS = 7;          // 2^(4-1) - 1
    localparam int MAX_EXPONENT  = 15;         // 2^4 - 1
    localparam int MIN_EXPONENT  = 0;
    
    // Special value encodings
    localparam logic [7:0] FP8_ZERO_POS = 8'b0_0000_000;
    localparam logic [7:0] FP8_ZERO_NEG = 8'b1_0000_000;
    localparam logic [7:0] FP8_INF_POS  = 8'b0_1111_111;
    localparam logic [7:0] FP8_INF_NEG  = 8'b1_1111_111;
    localparam logic [7:0] FP8_NAN      = 8'b0_1111_110; // NaN representation

    //=========================================================================
    // Pipeline Stage 1: Unpack Inputs
    //=========================================================================
    logic        sign_a_s1, sign_b_s1, sign_c_s1;
    logic [3:0]  exp_a_s1, exp_b_s1, exp_c_s1;
    logic [2:0]  mant_a_s1, mant_b_s1, mant_c_s1;
    logic        is_zero_a_s1, is_zero_b_s1, is_zero_c_s1;
    logic        is_inf_a_s1, is_inf_b_s1, is_inf_c_s1;
    logic        is_nan_a_s1, is_nan_b_s1, is_nan_c_s1;
    logic        valid_s1;

    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            sign_a_s1 <= 1'b0;
            sign_b_s1 <= 1'b0;
            sign_c_s1 <= 1'b0;
            exp_a_s1  <= 4'b0;
            exp_b_s1  <= 4'b0;
            exp_c_s1  <= 4'b0;
            mant_a_s1 <= 3'b0;
            mant_b_s1 <= 3'b0;
            mant_c_s1 <= 3'b0;
            is_zero_a_s1 <= 1'b0;
            is_zero_b_s1 <= 1'b0;
            is_zero_c_s1 <= 1'b0;
            is_inf_a_s1  <= 1'b0;
            is_inf_b_s1  <= 1'b0;
            is_inf_c_s1  <= 1'b0;
            is_nan_a_s1  <= 1'b0;
            is_nan_b_s1  <= 1'b0;
            is_nan_c_s1  <= 1'b0;
            valid_s1  <= 1'b0;
        end else begin
            // Unpack A
            sign_a_s1 <= a[7];
            exp_a_s1  <= a[6:3];
            mant_a_s1 <= a[2:0];
            is_zero_a_s1 <= (a[6:0] == 7'b0000_000);
            is_inf_a_s1  <= (a[6:3] == 4'b1111) && (a[2:0] == 3'b111);
            is_nan_a_s1  <= (a[6:3] == 4'b1111) && (a[2:0] != 3'b111);
            
            // Unpack B
            sign_b_s1 <= b[7];
            exp_b_s1  <= b[6:3];
            mant_b_s1 <= b[2:0];
            is_zero_b_s1 <= (b[6:0] == 7'b0000_000);
            is_inf_b_s1  <= (b[6:3] == 4'b1111) && (b[2:0] == 3'b111);
            is_nan_b_s1  <= (b[6:3] == 4'b1111) && (b[2:0] != 3'b111);
            
            // Unpack C
            sign_c_s1 <= c[7];
            exp_c_s1  <= c[6:3];
            mant_c_s1 <= c[2:0];
            is_zero_c_s1 <= (c[6:0] == 7'b0000_000);
            is_inf_c_s1  <= (c[6:3] == 4'b1111) && (c[2:0] == 3'b111);
            is_nan_c_s1  <= (c[6:3] == 4'b1111) && (c[2:0] != 3'b111);
            
            valid_s1 <= valid_in;
        end
    end

    //=========================================================================
    // Pipeline Stage 2: Multiply A * B
    //=========================================================================
    logic        sign_prod_s2;
    logic [4:0]  exp_prod_s2;          // Extended for overflow detection
    logic [7:0]  mant_prod_s2;         // 3+1 * 3+1 = 8 bits max (with implicit 1)
    logic        is_zero_prod_s2;
    logic        is_inf_prod_s2;
    logic        is_nan_prod_s2;
    logic        sign_c_s2;
    logic [3:0]  exp_c_s2;
    logic [2:0]  mant_c_s2;
    logic        is_zero_c_s2;
    logic        is_inf_c_s2;
    logic        is_nan_c_s2;
    logic        valid_s2;

    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            sign_prod_s2    <= 1'b0;
            exp_prod_s2     <= 5'b0;
            mant_prod_s2    <= 8'b0;
            is_zero_prod_s2 <= 1'b0;
            is_inf_prod_s2  <= 1'b0;
            is_nan_prod_s2  <= 1'b0;
            sign_c_s2       <= 1'b0;
            exp_c_s2        <= 4'b0;
            mant_c_s2       <= 3'b0;
            is_zero_c_s2    <= 1'b0;
            is_inf_c_s2     <= 1'b0;
            is_nan_c_s2     <= 1'b0;
            valid_s2        <= 1'b0;
        end else begin
            // Multiply sign
            sign_prod_s2 <= sign_a_s1 ^ sign_b_s1;
            
            // Handle special cases for multiplication
            is_nan_prod_s2  <= is_nan_a_s1 || is_nan_b_s1 || 
                              (is_zero_a_s1 && is_inf_b_s1) || 
                              (is_inf_a_s1 && is_zero_b_s1);
            is_zero_prod_s2 <= is_zero_a_s1 || is_zero_b_s1;
            is_inf_prod_s2  <= (is_inf_a_s1 || is_inf_b_s1) && 
                              !(is_zero_a_s1 || is_zero_b_s1);
            
            // Multiply mantissas (add implicit leading 1 for normalized numbers)
            if (!is_zero_a_s1 && !is_zero_b_s1 && 
                !is_inf_a_s1 && !is_inf_b_s1 && 
                !is_nan_a_s1 && !is_nan_b_s1) begin
                logic [3:0] mant_a_ext;
                logic [3:0] mant_b_ext;
                logic [7:0] mant_temp;
                mant_a_ext = {1'b1, mant_a_s1};  // Add implicit 1
                mant_b_ext = {1'b1, mant_b_s1};  // Add implicit 1
                mant_temp = mant_a_ext * mant_b_ext;  // 4x4 = 8 bits
                
                // Normalize: ensure leading 1 is at bit [7]
                if (mant_temp[7]) begin
                    // Already normalized (product >= 2.0 in fixed point)
                    mant_prod_s2 <= mant_temp;
                    exp_prod_s2 <= exp_a_s1 + exp_b_s1 - EXPONENT_BIAS + 1;  // +1 for overflow
                end else begin
                    // Shift left to normalize (product < 2.0 in fixed point)
                    mant_prod_s2 <= {mant_temp[6:0], 1'b0};
                    exp_prod_s2 <= exp_a_s1 + exp_b_s1 - EXPONENT_BIAS;
                end
            end else begin
                mant_prod_s2 <= 8'b0;
                exp_prod_s2 <= 5'b0;
            end
            
            // Pass through C operand
            sign_c_s2    <= sign_c_s1;
            exp_c_s2     <= exp_c_s1;
            mant_c_s2    <= mant_c_s1;
            is_zero_c_s2 <= is_zero_c_s1;
            is_inf_c_s2  <= is_inf_c_s1;
            is_nan_c_s2  <= is_nan_c_s1;
            
            valid_s2 <= valid_s1;
        end
    end

    //=========================================================================
    // Pipeline Stage 3: Align and Add
    //=========================================================================
    logic        sign_result_s3;
    logic [4:0]  exp_result_s3;
    logic [9:0]  mant_result_s3;       // Extended for addition
    logic        is_zero_s3;
    logic        is_inf_s3;
    logic        is_nan_s3;
    logic        valid_s3;

    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            sign_result_s3 <= 1'b0;
            exp_result_s3  <= 5'b0;
            mant_result_s3 <= 10'b0;
            is_zero_s3     <= 1'b0;
            is_inf_s3      <= 1'b0;
            is_nan_s3      <= 1'b0;
            valid_s3       <= 1'b0;
        end else begin
            // Handle special cases
            if (is_nan_prod_s2 || is_nan_c_s2) begin
                // NaN propagation
                is_nan_s3 <= 1'b1;
                is_inf_s3 <= 1'b0;
                is_zero_s3 <= 1'b0;
                sign_result_s3 <= 1'b0;
                exp_result_s3 <= 5'b0;
                mant_result_s3 <= 10'b0;
            end else if (is_inf_prod_s2 && is_inf_c_s2 && (sign_prod_s2 != sign_c_s2)) begin
                // Inf - Inf = NaN
                is_nan_s3 <= 1'b1;
                is_inf_s3 <= 1'b0;
                is_zero_s3 <= 1'b0;
                sign_result_s3 <= 1'b0;
                exp_result_s3 <= 5'b0;
                mant_result_s3 <= 10'b0;
            end else if (is_inf_prod_s2 || is_inf_c_s2) begin
                // Infinity propagation
                is_inf_s3 <= 1'b1;
                is_nan_s3 <= 1'b0;
                is_zero_s3 <= 1'b0;
                sign_result_s3 <= is_inf_prod_s2 ? sign_prod_s2 : sign_c_s2;
                exp_result_s3 <= 5'b01111;
                mant_result_s3 <= 10'b0;
            end else if (is_zero_prod_s2 && is_zero_c_s2) begin
                // Zero result
                is_zero_s3 <= 1'b1;
                is_nan_s3 <= 1'b0;
                is_inf_s3 <= 1'b0;
                sign_result_s3 <= sign_prod_s2 & sign_c_s2;
                exp_result_s3 <= 5'b0;
                mant_result_s3 <= 10'b0;
            end else begin
                // Normal addition path
                // Declare all variables first
                logic [4:0] exp_large;
                logic [9:0] mant_large;
                logic [9:0] mant_small;
                logic       sign_large;
                logic       sign_small;
                logic [4:0] exp_diff;
                
                is_nan_s3 <= 1'b0;
                is_inf_s3 <= 1'b0;
                
                // Determine which operand is larger
                // Align both to have implicit 1 at bit [8], mantissa at [7:5], guard bits at [4:0]
                if (is_zero_prod_s2) begin
                    exp_large = {1'b0, exp_c_s2};
                    mant_large = {1'b1, mant_c_s2, 5'b0};  // bit[8]=1, bits[7:5]=mant, bits[4:0]=0
                    sign_large = sign_c_s2;
                    mant_small = 10'b0;
                    sign_small = sign_prod_s2;
                    exp_diff = 5'b0;
                end else if (is_zero_c_s2) begin
                    exp_large = exp_prod_s2;
                    // Product: 4x4=8 bits, leading 1 at bit[7]. Shift to put at bit[8]
                    mant_large = {mant_prod_s2[7:0], 1'b0};  // bit[8]=mant[7], down to bit[1]=mant[0]
                    sign_large = sign_prod_s2;
                    mant_small = 10'b0;
                    sign_small = sign_c_s2;
                    exp_diff = 5'b0;
                end else if (exp_prod_s2 > {1'b0, exp_c_s2}) begin
                    exp_large = exp_prod_s2;
                    mant_large = {mant_prod_s2[7:0], 1'b0};
                    sign_large = sign_prod_s2;
                    exp_diff = exp_prod_s2 - {1'b0, exp_c_s2};
                    mant_small = {1'b1, mant_c_s2, 5'b0} >> exp_diff;
                    sign_small = sign_c_s2;
                end else begin
                    exp_large = {1'b0, exp_c_s2};
                    mant_large = {1'b1, mant_c_s2, 5'b0};
                    sign_large = sign_c_s2;
                    exp_diff = {1'b0, exp_c_s2} - exp_prod_s2;
                    mant_small = {mant_prod_s2[7:0], 1'b0} >> exp_diff;
                    sign_small = sign_prod_s2;
                end
                
                // Perform addition or subtraction
                if (sign_large == sign_small) begin
                    // Same sign: add
                    mant_result_s3 <= mant_large + mant_small;
                    sign_result_s3 <= sign_large;
                end else begin
                    // Different signs: subtract
                    if (mant_large > mant_small) begin
                        mant_result_s3 <= mant_large - mant_small;
                        sign_result_s3 <= sign_large;
                    end else if (mant_small > mant_large) begin
                        mant_result_s3 <= mant_small - mant_large;
                        sign_result_s3 <= sign_small;
                    end else begin
                        // Exact cancellation: result is +0
                        mant_result_s3 <= 10'b0;
                        sign_result_s3 <= 1'b0;  // Positive zero
                    end
                end
                
                exp_result_s3 <= exp_large;
                is_zero_s3 <= (mant_large == mant_small) && (sign_large != sign_small);
            end
            
            valid_s3 <= valid_s2;
        end
    end

    //=========================================================================
    // Pipeline Stage 4: Normalize and Round
    //=========================================================================
    logic [7:0] result_s4;
    logic       valid_s4;
    logic       overflow_s4;
    logic       underflow_s4;

    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            result_s4    <= 8'b0;
            valid_s4     <= 1'b0;
            overflow_s4  <= 1'b0;
            underflow_s4 <= 1'b0;
        end else begin
            if (is_nan_s3) begin
                result_s4 <= FP8_NAN;
                overflow_s4 <= 1'b0;
                underflow_s4 <= 1'b0;
            end else if (is_inf_s3) begin
                result_s4 <= sign_result_s3 ? FP8_INF_NEG : FP8_INF_POS;
                overflow_s4 <= 1'b0;
                underflow_s4 <= 1'b0;
            end else if (is_zero_s3 || (mant_result_s3 == 10'b0)) begin
                result_s4 <= sign_result_s3 ? FP8_ZERO_NEG : FP8_ZERO_POS;
                overflow_s4 <= 1'b0;
                underflow_s4 <= 1'b0;
            end else begin
                logic [4:0] exp_normalized;
                logic [9:0] mant_normalized;
                logic [2:0] mant_final;
                logic [3:0] exp_final;
                logic       round_bit;
                logic       sticky_bit;
                
                // Normalize mantissa
                if (mant_result_s3[9]) begin
                    // Overflow in mantissa, shift right
                    mant_normalized = mant_result_s3 >> 1;
                    exp_normalized = exp_result_s3 + 1;
                end else if (mant_result_s3[8]) begin
                    // Already normalized
                    mant_normalized = mant_result_s3;
                    exp_normalized = exp_result_s3;
                end else begin
                    // Need to shift left to normalize
                    logic [4:0] shift_amount;
                    logic [9:0] temp_mant;
                    temp_mant = mant_result_s3;
                    shift_amount = 5'b0;
                    
                    // Find leading one
                    if (!temp_mant[8]) begin
                        for (int i = 7; i >= 0; i--) begin
                            if (temp_mant[i] && shift_amount == 5'b0) begin
                                shift_amount = 8 - i;
                            end
                        end
                        temp_mant = temp_mant << shift_amount;
                        exp_normalized = exp_result_s3 - shift_amount;
                    end else begin
                        exp_normalized = exp_result_s3;
                    end
                    mant_normalized = temp_mant;
                end
                
                // Check for overflow/underflow
                if (exp_normalized > 5'd15) begin
                    // Overflow to infinity
                    result_s4 <= sign_result_s3 ? FP8_INF_NEG : FP8_INF_POS;
                    overflow_s4 <= 1'b1;
                    underflow_s4 <= 1'b0;
                end else if (exp_normalized[4] || (exp_normalized == 5'b0)) begin
                    // Underflow to zero
                    result_s4 <= sign_result_s3 ? FP8_ZERO_NEG : FP8_ZERO_POS;
                    overflow_s4 <= 1'b0;
                    underflow_s4 <= 1'b1;
                end else begin
                    // Round to nearest, ties to even
                    // After normalization: bit[8]=implicit 1, bits[7:5]=mantissa, bit[4]=round, bits[3:0]=sticky
                    exp_final = exp_normalized[3:0];
                    round_bit = mant_normalized[4];
                    sticky_bit = |mant_normalized[3:0];
                    
                    if (round_bit && (sticky_bit || mant_normalized[5])) begin
                        // Round up
                        mant_final = mant_normalized[7:5] + 3'b001;
                        if (mant_final == 3'b000) begin
                            // Mantissa overflow, increment exponent
                            exp_final = exp_final + 4'b0001;
                        end
                    end else begin
                        mant_final = mant_normalized[7:5];
                    end
                    
                    result_s4 <= {sign_result_s3, exp_final, mant_final};
                    overflow_s4 <= 1'b0;
                    underflow_s4 <= 1'b0;
                end
            end
            
            valid_s4 <= valid_s3;
        end
    end

    //=========================================================================
    // Output Assignment
    //=========================================================================
    assign result    = result_s4;
    assign valid_out = valid_s4;
    assign overflow  = overflow_s4;
    assign underflow = underflow_s4;

endmodule
