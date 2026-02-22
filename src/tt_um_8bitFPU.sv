module tt_um_8bitFPU (
    input  logic [7:0] ui_in,    // Dedicated inputs
    output logic [7:0] uo_out,   // Dedicated outputs
    input  logic [7:0] uio_in,   // IOs: Input path
    output logic [7:0] uio_out,  // IOs: Output path
    output logic [7:0] uio_oe,   // IOs: Enable path
    input  logic       ena,      // always 1
    input  logic       clk,      // clock
    input  logic       rst_n     // reset_n (active low)
);

    // Internal Registers to hold operands
    logic [7:0] reg_a, reg_b, reg_c;
    logic [2:0] reg_opcode;
    logic       load_valid;

    // FPU Output signals
    logic [7:0] fpu_result;
    logic fpu_valid_out, fpu_overflow, fpu_underflow, fpu_div_zero, fpu_invalid;

    // --- Input Logic (Multiplexing) ---
    // ui_in[7:6] will act as a selector:
    // 00: Load Operand A | 01: Load Operand B | 10: Load Operand C | 11: Load Opcode
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            reg_a <= 8'b0; reg_b <= 8'b0; reg_c <= 8'b0; reg_opcode <= 3'b0;
            load_valid <= 1'b0;
        end else begin
            case (ui_in[7:6])
                2'b00: reg_a <= ui_in[5:0] << 2; // Rough mapping for demo
                2'b01: reg_b <= ui_in;
                2'b10: reg_c <= ui_in;
                2'b11: begin 
                    reg_opcode <= ui_in[2:0];
                    load_valid <= 1'b1; // Trigger FPU
                end
            endcase
            if (load_valid) load_valid <= 1'b0; 
        end
    end

    // --- Instantiate your FPU ---
    tt_um_8bitFPU fpu_inst (
        .clock(clk),
        .reset(!rst_n), // Convert active-low to active-high for your design [cite: 196]
        .valid_in(load_valid),
        .opcode(reg_opcode),
        .operand_a(reg_a),
        .operand_b(reg_b),
        .operand_c(reg_c),
        .result(fpu_result),
        .valid_out(fpu_valid_out),
        .overflow(fpu_overflow),
        .underflow(fpu_underflow),
        .div_by_zero(fpu_div_zero),
        .invalid_op(fpu_invalid)
    );

    // --- Output Mapping ---
    assign uo_out = fpu_result; 
    assign uio_out = {3'b0, fpu_invalid, fpu_div_zero, fpu_underflow, fpu_overflow, fpu_valid_out};
    assign uio_oe  = 8'b11111111; // Set all UIO to outputs for flags

    // Prevent warnings
    wire _unused = &{ena, uio_in, 1'b0};

endmodule
