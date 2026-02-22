//=============================================================================
// TinyTapeout Wrapper for FP8 FPU
// Author: Your Name
// 
// Description: 8-bit Floating Point Unit (FP8 E4M3 format)
// Supports ADD, SUB, MUL, DIV, SQRT, and FMA operations
//=============================================================================

`default_nettype none

module tt_um_fp8_fpu (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    //=========================================================================
    // Internal Signals
    //=========================================================================
    
    // Convert active-low reset to active-high
    logic reset;
    assign reset = ~rst_n;

    // FPU operand registers
    logic [7:0] operand_a_reg;
    logic [7:0] operand_b_reg;
    logic [7:0] operand_c_reg;
    logic [2:0] fpu_opcode;
    logic [1:0] load_state;
    
    // FPU outputs
    logic [7:0] fpu_result;
    logic fpu_valid_out;
    logic fpu_overflow;
    logic fpu_underflow;
    logic fpu_div_by_zero;
    logic fpu_invalid_op;
    
    // Result registers
    logic [7:0] result_reg;
    logic result_valid;
    logic fpu_valid_in;
    
    // Button edge detection
    logic btn_load_prev, btn_execute_prev;
    logic btn_load_pulse;
    logic btn_execute_pulse;
    
    //=========================================================================
    // Input Mapping
    // ui_in[7:0] = 8-bit data input for operands
    // uio_in[0] = Load button (KEY[1])
    // uio_in[1] = Execute button (KEY[0])
    // uio_in[4:2] = 3-bit opcode (for manual opcode input if needed)
    //=========================================================================
    
    logic [7:0] data_in;
    logic btn_load;
    logic btn_execute;
    logic [2:0] opcode_in;
    
    assign data_in = ui_in[7:0];
    assign btn_load = uio_in[0];
    assign btn_execute = uio_in[1];
    assign opcode_in = uio_in[4:2];
    
    //=========================================================================
    // Output Mapping
    // uo_out[7:0] = 8-bit result
    // uio_out[0] = result_valid
    // uio_out[1] = error (overflow | underflow | div_by_zero | invalid_op)
    // uio_out[2] = busy
    // uio_out[7:3] = unused
    //=========================================================================
    
    assign uo_out[7:0] = result_reg;
    assign uio_out[0] = result_valid;
    assign uio_out[1] = fpu_overflow | fpu_underflow | fpu_div_by_zero | fpu_invalid_op;
    assign uio_out[2] = fpu_valid_in;
    assign uio_out[7:3] = 5'b00000;
    
    //=========================================================================
    // Bidirectional Pin Configuration
    // uio[0] = output (result_valid)
    // uio[1] = output (error)
    // uio[2] = output (busy)
    // uio[4:2] = input (opcode bits)
    //=========================================================================
    assign uio_oe = 8'b00000111; // bits 0-2 as outputs, 3-7 as inputs
    
    //=========================================================================
    // Button Edge Detection
    //=========================================================================
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            btn_load_prev <= 1'b0;
            btn_execute_prev <= 1'b0;
        end else begin
            btn_load_prev <= btn_load;
            btn_execute_prev <= btn_execute;
        end
    end
    
    assign btn_load_pulse = btn_load & ~btn_load_prev;
    assign btn_execute_pulse = btn_execute & ~btn_execute_prev;
    
    //=========================================================================
    // Load State Machine
    // Sequential loading: Load A -> Load B -> Load C -> Load Opcode
    //=========================================================================
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            load_state <= 2'b00;
        end else if (btn_load_pulse) begin
            if (load_state == 2'b11)
                load_state <= 2'b00;
            else
                load_state <= load_state + 1'b1;
        end
    end
    
    //=========================================================================
    // Operand Registers with Sequential Load Control
    //=========================================================================
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            operand_a_reg <= 8'h00;
            operand_b_reg <= 8'h00;
            operand_c_reg <= 8'h00;
            fpu_opcode <= 3'b000;
        end else if (btn_load_pulse) begin
            case (load_state)
                2'b00: operand_a_reg <= data_in;
                2'b01: operand_b_reg <= data_in;
                2'b10: operand_c_reg <= data_in;
                2'b11: fpu_opcode <= opcode_in;
                default: ;
            endcase
        end
    end
    
    //=========================================================================
    // Execution State Machine
    //=========================================================================
    typedef enum logic [1:0] {
        IDLE    = 2'b00,
        EXECUTE = 2'b01,
        WAIT    = 2'b10
    } state_t;
    
    state_t state;
    
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            fpu_valid_in <= 1'b0;
            result_reg <= 8'h00;
            result_valid <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    fpu_valid_in <= 1'b0;
                    if (btn_execute_pulse) begin
                        state <= EXECUTE;
                    end
                end
                
                EXECUTE: begin
                    fpu_valid_in <= 1'b1;
                    result_valid <= 1'b0;
                    state <= WAIT;
                end
                
                WAIT: begin
                    fpu_valid_in <= 1'b0;
                    if (fpu_valid_out) begin
                        result_reg <= fpu_result;
                        result_valid <= 1'b1;
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end
    
    //=========================================================================
    // FP8 FPU Core Instance
    //=========================================================================
    fp8_fpu_e4m3 u_fpu (
        .clock(clk),
        .reset(reset),
        .valid_in(fpu_valid_in),
        .opcode(fpu_opcode),
        .operand_a(operand_a_reg),
        .operand_b(operand_b_reg),
        .operand_c(operand_c_reg),
        .result(fpu_result),
        .valid_out(fpu_valid_out),
        .overflow(fpu_overflow),
        .underflow(fpu_underflow),
        .div_by_zero(fpu_div_by_zero),
        .invalid_op(fpu_invalid_op)
    );
    
    //=========================================================================
    // Unused Signal Handling
    //=========================================================================
    logic _unused;
    assign _unused = &{ena, 1'b0};

endmodule

`default_nettype wire
