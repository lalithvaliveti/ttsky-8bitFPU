//=============================================================================
// Module: fp8_div_e4m3
// Description: FP8 E4M3 Division Unit (a / b)
//              Iterative non-restoring division algorithm
// Format: E4M3 - 1 Sign bit, 4 Exponent bits, 3 Mantissa bits
// Author: Cognichip Co-Designer
//=============================================================================

module fp8_div_e4m3 (
    input  logic       clock,
    input  logic       reset,
    input  logic       valid_in,      // Input valid signal
    input  logic [7:0] a,             // FP8 E4M3 dividend
    input  logic [7:0] b,             // FP8 E4M3 divisor
    output logic [7:0] result,        // FP8 E4M3 result
    output logic       valid_out,     // Output valid signal
    output logic       overflow,      // Overflow flag
    output logic       underflow,     // Underflow flag
    output logic       div_by_zero    // Division by zero flag
);

    //=========================================================================
    // FP8 E4M3 Format Parameters
    //=========================================================================
    localparam int EXPONENT_BIAS = 7;
    
    // Special value encodings
    localparam logic [7:0] FP8_ZERO_POS = 8'b0_0000_000;
    localparam logic [7:0] FP8_ZERO_NEG = 8'b1_0000_000;
    localparam logic [7:0] FP8_INF_POS  = 8'b0_1111_111;
    localparam logic [7:0] FP8_INF_NEG  = 8'b1_1111_111;
    localparam logic [7:0] FP8_NAN      = 8'b0_1111_110;

    //=========================================================================
    // Pipeline Registers
    //=========================================================================
    // Stage 1: Unpack and classify
    logic        sign_result_s1;
    logic [3:0]  exp_a_s1, exp_b_s1;
    logic [2:0]  mant_a_s1, mant_b_s1;
    logic        is_zero_a_s1, is_zero_b_s1;
    logic        is_inf_a_s1, is_inf_b_s1;
    logic        is_nan_a_s1, is_nan_b_s1;
    logic        valid_s1;

    // Stage 2: Perform division
    logic        sign_result_s2;
    logic [4:0]  exp_result_s2;
    logic [6:0]  mant_result_s2;  // Extended mantissa for division
    logic        is_special_s2;
    logic [7:0]  special_result_s2;
    logic        div_by_zero_s2;
    logic        valid_s2;

    // Stage 3: Normalize and round
    logic [7:0]  result_s3;
    logic        overflow_s3;
    logic        underflow_s3;
    logic        div_by_zero_s3;
    logic        valid_s3;

    // Stage 4: Output register (for consistent 4-cycle latency with FMA)
    logic [7:0]  result_s4;
    logic        overflow_s4;
    logic        underflow_s4;
    logic        div_by_zero_s4;
    logic        valid_s4;

    //=========================================================================
    // Stage 1: Unpack and Classify
    //=========================================================================
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            sign_result_s1 <= 1'b0;
            exp_a_s1      <= 4'b0;
            exp_b_s1      <= 4'b0;
            mant_a_s1     <= 3'b0;
            mant_b_s1     <= 3'b0;
            is_zero_a_s1  <= 1'b0;
            is_zero_b_s1  <= 1'b0;
            is_inf_a_s1   <= 1'b0;
            is_inf_b_s1   <= 1'b0;
            is_nan_a_s1   <= 1'b0;
            is_nan_b_s1   <= 1'b0;
            valid_s1      <= 1'b0;
        end else begin
            // Sign is XOR of input signs
            sign_result_s1 <= a[7] ^ b[7];
            
            // Unpack A (dividend)
            exp_a_s1  <= a[6:3];
            mant_a_s1 <= a[2:0];
            is_zero_a_s1 <= (a[6:0] == 7'b0000_000);
            is_inf_a_s1  <= (a[6:3] == 4'b1111) && (a[2:0] == 3'b111);
            is_nan_a_s1  <= (a[6:3] == 4'b1111) && (a[2:0] != 3'b111);
            
            // Unpack B (divisor)
            exp_b_s1  <= b[6:3];
            mant_b_s1 <= b[2:0];
            is_zero_b_s1 <= (b[6:0] == 7'b0000_000);
            is_inf_b_s1  <= (b[6:3] == 4'b1111) && (b[2:0] == 3'b111);
            is_nan_b_s1  <= (b[6:3] == 4'b1111) && (b[2:0] != 3'b111);
            
            valid_s1 <= valid_in;
        end
    end

    //=========================================================================
    // Stage 2: Division
    //=========================================================================
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            sign_result_s2    <= 1'b0;
            exp_result_s2     <= 5'b0;
            mant_result_s2    <= 7'b0;
            is_special_s2     <= 1'b0;
            special_result_s2 <= 8'b0;
            div_by_zero_s2    <= 1'b0;
            valid_s2          <= 1'b0;
        end else begin
            sign_result_s2 <= sign_result_s1;
            div_by_zero_s2 <= 1'b0;
            
            // Handle special cases
            if (is_nan_a_s1 || is_nan_b_s1) begin
                // NaN propagation
                is_special_s2 <= 1'b1;
                special_result_s2 <= FP8_NAN;
            end else if (is_zero_a_s1 && is_zero_b_s1) begin
                // 0 / 0 = NaN
                is_special_s2 <= 1'b1;
                special_result_s2 <= FP8_NAN;
            end else if (is_inf_a_s1 && is_inf_b_s1) begin
                // Inf / Inf = NaN
                is_special_s2 <= 1'b1;
                special_result_s2 <= FP8_NAN;
            end else if (is_zero_b_s1) begin
                // Division by zero
                is_special_s2 <= 1'b1;
                special_result_s2 <= sign_result_s1 ? FP8_INF_NEG : FP8_INF_POS;
                div_by_zero_s2 <= 1'b1;
            end else if (is_zero_a_s1) begin
                // 0 / b = 0
                is_special_s2 <= 1'b1;
                special_result_s2 <= sign_result_s1 ? FP8_ZERO_NEG : FP8_ZERO_POS;
            end else if (is_inf_a_s1) begin
                // Inf / b = Inf
                is_special_s2 <= 1'b1;
                special_result_s2 <= sign_result_s1 ? FP8_INF_NEG : FP8_INF_POS;
            end else if (is_inf_b_s1) begin
                // a / Inf = 0
                is_special_s2 <= 1'b1;
                special_result_s2 <= sign_result_s1 ? FP8_ZERO_NEG : FP8_ZERO_POS;
            end else begin
                // Normal division
                // Declare variables first
                logic [3:0] dividend_ext;
                logic [3:0] divisor_ext;
                logic [6:0] quotient;
                
                is_special_s2 <= 1'b0;
                
                // Divide mantissas (with implicit leading 1)
                dividend_ext = {1'b1, mant_a_s1};  // 1.xxx (4 bits)
                divisor_ext  = {1'b1, mant_b_s1};  // 1.xxx (4 bits)
                
                // Division: {dividend, 3'b0} gives us (dividend * 8) / divisor
                // This provides extra precision bits
                // Result will be 8x the true quotient
                quotient = {dividend_ext, 3'b0} / divisor_ext;
                mant_result_s2 <= quotient;
                
                // Exponent: (exp_a - exp_b + bias) - 3
                // The -3 accounts for the 8x scaling from shifting dividend left by 3
                exp_result_s2 <= {1'b0, exp_a_s1} - {1'b0, exp_b_s1} + EXPONENT_BIAS - 3;
            end
            
            valid_s2 <= valid_s1;
        end
    end

    //=========================================================================
    // Stage 3: Normalize and Round
    //=========================================================================
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            result_s3      <= 8'b0;
            overflow_s3    <= 1'b0;
            underflow_s3   <= 1'b0;
            div_by_zero_s3 <= 1'b0;
            valid_s3       <= 1'b0;
        end else begin
            div_by_zero_s3 <= div_by_zero_s2;
            
            if (is_special_s2) begin
                result_s3 <= special_result_s2;
                overflow_s3 <= 1'b0;
                underflow_s3 <= 1'b0;
            end else begin
                // Normalize mantissa
                // Declare variables first
                logic [4:0] exp_normalized;
                logic [6:0] mant_normalized;
                logic [2:0] mant_final;
                logic [3:0] exp_final;
                
                // Normalize quotient to have leading 1 at bit 6
                // The quotient from {dividend*8}/divisor needs normalization
                // After division, leading 1 can be at various bit positions
                if (mant_result_s2[6]) begin
                    // Leading 1 already at bit 6 - no shift needed
                    mant_normalized = mant_result_s2;
                    exp_normalized = exp_result_s2;
                end else if (mant_result_s2[5]) begin
                    // Leading 1 at bit 5 - shift left by 1
                    mant_normalized = mant_result_s2 << 1;
                    exp_normalized = exp_result_s2 + 1;  // Shifting left decreases value, so increase exp
                end else if (mant_result_s2[4]) begin
                    // Leading 1 at bit 4 - shift left by 2
                    mant_normalized = mant_result_s2 << 2;
                    exp_normalized = exp_result_s2 + 2;
                end else if (mant_result_s2[3]) begin
                    // Leading 1 at bit 3 - shift left by 3
                    mant_normalized = mant_result_s2 << 3;
                    exp_normalized = exp_result_s2 + 3;
                end else if (mant_result_s2[2]) begin
                    // Leading 1 at bit 2 - shift left by 4
                    mant_normalized = mant_result_s2 << 4;
                    exp_normalized = exp_result_s2 + 4;
                end else begin
                    // Leading 1 at bit 1 or 0 - shift left by 5 or 6
                    mant_normalized = mant_result_s2 << 5;
                    exp_normalized = exp_result_s2 + 5;
                end
                
                // Check for overflow/underflow
                if (exp_normalized > 5'd15) begin
                    // Overflow to infinity
                    result_s3 <= sign_result_s2 ? FP8_INF_NEG : FP8_INF_POS;
                    overflow_s3 <= 1'b1;
                    underflow_s3 <= 1'b0;
                end else if (exp_normalized[4] || (exp_normalized == 5'b0)) begin
                    // Underflow to zero
                    result_s3 <= sign_result_s2 ? FP8_ZERO_NEG : FP8_ZERO_POS;
                    overflow_s3 <= 1'b0;
                    underflow_s3 <= 1'b1;
                end else begin
                    // Extract final mantissa: leading 1 at bit 6, mantissa at bits [5:3]
                    exp_final = exp_normalized[3:0];
                    
                    // Round: check bit 2 (guard bit)
                    if (mant_normalized[2]) begin
                        mant_final = mant_normalized[5:3] + 3'b001;
                        if (mant_final == 3'b000) begin
                            exp_final = exp_final + 4'b0001;
                        end
                    end else begin
                        mant_final = mant_normalized[5:3];
                    end
                    
                    result_s3 <= {sign_result_s2, exp_final, mant_final};
                    overflow_s3 <= 1'b0;
                    underflow_s3 <= 1'b0;
                end
            end
            
            valid_s3 <= valid_s2;
        end
    end

    //=========================================================================
    // Stage 4: Output Register
    //=========================================================================
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            result_s4      <= 8'b0;
            overflow_s4    <= 1'b0;
            underflow_s4   <= 1'b0;
            div_by_zero_s4 <= 1'b0;
            valid_s4       <= 1'b0;
        end else begin
            result_s4      <= result_s3;
            overflow_s4    <= overflow_s3;
            underflow_s4   <= underflow_s3;
            div_by_zero_s4 <= div_by_zero_s3;
            valid_s4       <= valid_s3;
        end
    end

    //=========================================================================
    // Output Assignment
    //=========================================================================
    assign result      = result_s4;
    assign valid_out   = valid_s4;
    assign overflow    = overflow_s4;
    assign underflow   = underflow_s4;
    assign div_by_zero = div_by_zero_s4;

endmodule
