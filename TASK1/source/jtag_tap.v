
`timescale 1ns / 1ps
`default_nettype none

module jtag_tap #(
 
    parameter [31:0] IDCODE_VALUE = 32'h1_CAFE_0_3   // example: version=1, part=CAFE, mfr=VSD
) (
    // JTAG pins
    input  wire TCK,
    input  wire TMS,
    input  wire TDI,
    output reg  TDO,
    input  wire TRST_N,          // asynchronous, active-low

   // expose current IR to the rest of the SOC
    output wire [3:0] tap_ir_o,
    output wire       tap_capture_dr_o,
    output wire       tap_shift_dr_o,
    output wire       tap_update_dr_o
);
//  TAP State Machine
localparam [3:0]
    TEST_LOGIC_RESET = 4'd0,
    RUN_TEST_IDLE    = 4'd1,
    SELECT_DR_SCAN   = 4'd2,
    CAPTURE_DR       = 4'd3,
    SHIFT_DR         = 4'd4,
    EXIT1_DR         = 4'd5,
    PAUSE_DR         = 4'd6,
    EXIT2_DR         = 4'd7,
    UPDATE_DR        = 4'd8,
    SELECT_IR_SCAN   = 4'd9,
    CAPTURE_IR       = 4'd10,
    SHIFT_IR         = 4'd11,
    EXIT1_IR         = 4'd12,
    PAUSE_IR         = 4'd13,
    EXIT2_IR         = 4'd14,
    UPDATE_IR        = 4'd15;

reg [3:0] tap_state;

// Next-state logic (pure combinatorial — evaluated on rising TCK)
function [3:0] next_state;
    input [3:0] current;
    input       tms;
    begin
        case (current)
            TEST_LOGIC_RESET: next_state = tms ? TEST_LOGIC_RESET : RUN_TEST_IDLE;
            RUN_TEST_IDLE:    next_state = tms ? SELECT_DR_SCAN   : RUN_TEST_IDLE;
            SELECT_DR_SCAN:   next_state = tms ? SELECT_IR_SCAN   : CAPTURE_DR;
            CAPTURE_DR:       next_state = tms ? EXIT1_DR         : SHIFT_DR;
            SHIFT_DR:         next_state = tms ? EXIT1_DR         : SHIFT_DR;
            EXIT1_DR:         next_state = tms ? UPDATE_DR        : PAUSE_DR;
            PAUSE_DR:         next_state = tms ? EXIT2_DR         : PAUSE_DR;
            EXIT2_DR:         next_state = tms ? UPDATE_DR        : SHIFT_DR;
            UPDATE_DR:        next_state = tms ? SELECT_DR_SCAN   : RUN_TEST_IDLE;
            SELECT_IR_SCAN:   next_state = tms ? TEST_LOGIC_RESET : CAPTURE_IR;
            CAPTURE_IR:       next_state = tms ? EXIT1_IR         : SHIFT_IR;
            SHIFT_IR:         next_state = tms ? EXIT1_IR         : SHIFT_IR;
            EXIT1_IR:         next_state = tms ? UPDATE_IR        : PAUSE_IR;
            PAUSE_IR:         next_state = tms ? EXIT2_IR         : PAUSE_IR;
            EXIT2_IR:         next_state = tms ? UPDATE_IR        : SHIFT_IR;
            UPDATE_IR:        next_state = tms ? SELECT_DR_SCAN   : RUN_TEST_IDLE;
            default:          next_state = TEST_LOGIC_RESET;
        endcase
    end
endfunction

// State register — clocked on rising TCK, async reset on TRST_N low
always @(posedge TCK or negedge TRST_N) begin
    if (!TRST_N)
        tap_state <= TEST_LOGIC_RESET;
    else
        tap_state <= next_state(tap_state, TMS);
end

// Convenience state signals
wire state_capture_dr = (tap_state == CAPTURE_DR);
wire state_shift_dr   = (tap_state == SHIFT_DR);
wire state_update_dr  = (tap_state == UPDATE_DR);
wire state_capture_ir = (tap_state == CAPTURE_IR);
wire state_shift_ir   = (tap_state == SHIFT_IR);
wire state_update_ir  = (tap_state == UPDATE_IR);

assign tap_capture_dr_o = state_capture_dr;
assign tap_shift_dr_o   = state_shift_dr;
assign tap_update_dr_o  = state_update_dr;

localparam [3:0] INSTR_IDCODE = 4'b0001;
localparam [3:0] INSTR_BYPASS = 4'b1111;

reg [3:0] ir_shift;   // shift register
reg [3:0] ir_reg;     // latched instruction (updated on UPDATE_IR)

// IR shift register — rising TCK
always @(posedge TCK or negedge TRST_N) begin
    if (!TRST_N) begin
        ir_shift <= INSTR_IDCODE;
        ir_reg   <= INSTR_IDCODE;
    end else begin
        if (state_capture_ir)
            ir_shift <= INSTR_IDCODE;       // capture fixed pattern
        else if (state_shift_ir)
            ir_shift <= {TDI, ir_shift[3:1]};  // shift in LSB-first
        if (state_update_ir)
            ir_reg <= ir_shift;
    end
end

assign tap_ir_o = ir_reg;
//   IDCODE Data Register — 32 bits
reg [31:0] idcode_shift;

always @(posedge TCK or negedge TRST_N) begin
    if (!TRST_N) begin
        idcode_shift <= IDCODE_VALUE;
    end else begin
        if (state_capture_dr && (ir_reg == INSTR_IDCODE))
            idcode_shift <= IDCODE_VALUE;           // parallel load
        else if (state_shift_dr && (ir_reg == INSTR_IDCODE))
            idcode_shift <= {TDI, idcode_shift[31:1]};  // shift right, LSB out first
    end
end


//  BYPASS Register — 1 bit

reg bypass_bit;

always @(posedge TCK or negedge TRST_N) begin
    if (!TRST_N) begin
        bypass_bit <= 1'b0;
    end else begin
        if (state_capture_dr && (ir_reg == INSTR_BYPASS))
            bypass_bit <= 1'b0;                     // mandatory capture value
        else if (state_shift_dr && (ir_reg == INSTR_BYPASS))
            bypass_bit <= TDI;
    end
end

//  TDO mux — driven on FALLING edge of TCK (standard requirement)

reg tdo_mux;

always @(*) begin
    case (1'b1)
        state_shift_ir:
            tdo_mux = ir_shift[0];          // LSB of IR shift register
        (state_shift_dr && ir_reg == INSTR_IDCODE):
            tdo_mux = idcode_shift[0];      // LSB of IDCODE shift register
        (state_shift_dr && ir_reg == INSTR_BYPASS):
            tdo_mux = bypass_bit;
        default:
            tdo_mux = 1'b1;                 // TDO idles high
    endcase
end

always @(negedge TCK or negedge TRST_N) begin
    if (!TRST_N)
        TDO <= 1'b1;
    else
        TDO <= tdo_mux;
end

// $display state names in simulation

`ifdef BENCH
reg [127:0] state_name;
always @(*) begin
    case (tap_state)
        TEST_LOGIC_RESET: state_name = "TLR";
        RUN_TEST_IDLE:    state_name = "RTI";
        SELECT_DR_SCAN:   state_name = "SEL_DR";
        CAPTURE_DR:       state_name = "CAP_DR";
        SHIFT_DR:         state_name = "SHIFT_DR";
        EXIT1_DR:         state_name = "EXIT1_DR";
        PAUSE_DR:         state_name = "PAUSE_DR";
        EXIT2_DR:         state_name = "EXIT2_DR";
        UPDATE_DR:        state_name = "UPD_DR";
        SELECT_IR_SCAN:   state_name = "SEL_IR";
        CAPTURE_IR:       state_name = "CAP_IR";
        SHIFT_IR:         state_name = "SHIFT_IR";
        EXIT1_IR:         state_name = "EXIT1_IR";
        PAUSE_IR:         state_name = "PAUSE_IR";
        EXIT2_IR:         state_name = "EXIT2_IR";
        UPDATE_IR:        state_name = "UPD_IR";
        default:          state_name = "UNKNOWN";
    endcase
end
`endif

endmodule
