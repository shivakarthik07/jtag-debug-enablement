`timescale 1ns / 1ps
`default_nettype none

module jtag_tap #(
    parameter [31:0] IDCODE_VALUE = 32'h1CAFE003
) (
    input  wire        TCK,
    input  wire        TMS,
    input  wire        TDI,
    output reg         TDO,
    input  wire        TRST_N,

    output wire [3:0]  tap_ir_o,
    output wire        tap_capture_dr_o,
    output wire        tap_shift_dr_o,
    output wire        tap_update_dr_o,

    output reg         debug_halt_req,
    output reg         debug_resume_req,
    output reg         debug_reset_req,

    input  wire        debug_halted,
    input  wire [31:0] debug_pc
);

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

always @(posedge TCK or negedge TRST_N) begin
    if (!TRST_N)
        tap_state <= TEST_LOGIC_RESET;
    else
        tap_state <= next_state(tap_state, TMS);
end

wire state_capture_dr = (tap_state == CAPTURE_DR);
wire state_shift_dr   = (tap_state == SHIFT_DR);
wire state_update_dr  = (tap_state == UPDATE_DR);
wire state_capture_ir = (tap_state == CAPTURE_IR);
wire state_shift_ir   = (tap_state == SHIFT_IR);
wire state_update_ir  = (tap_state == UPDATE_IR);

assign tap_capture_dr_o = state_capture_dr;
assign tap_shift_dr_o   = state_shift_dr;
assign tap_update_dr_o   = state_update_dr;

localparam [3:0]
    INSTR_IDCODE       = 4'b0001,
    INSTR_DEBUG_CTRL   = 4'b0010,
    INSTR_DEBUG_STATUS = 4'b0011,
    INSTR_DEBUG_PC     = 4'b0100,
    INSTR_BYPASS       = 4'b1111;

reg [3:0] ir_shift;
reg [3:0] ir_reg;

always @(posedge TCK or negedge TRST_N) begin
    if (!TRST_N) begin
        ir_shift <= INSTR_IDCODE;
        ir_reg   <= INSTR_IDCODE;
    end else begin
        if (state_capture_ir)
            ir_shift <= INSTR_IDCODE;
      else if (state_shift_ir)
    ir_shift <= {TDI, ir_shift[3:1]};

        if (state_update_ir) begin
            ir_reg <= ir_shift;
`ifdef BENCH
            $display("IR UPDATE -> %b at time=%0t", ir_shift, $time);
`endif
        end
    end
end

assign tap_ir_o = ir_reg;

reg [31:0] idcode_shift;

always @(posedge TCK or negedge TRST_N) begin
    if (!TRST_N)
        idcode_shift <= IDCODE_VALUE;
    else begin
        if (state_capture_dr && (ir_reg == INSTR_IDCODE))
            idcode_shift <= IDCODE_VALUE;
        else if (state_shift_dr && (ir_reg == INSTR_IDCODE))
            idcode_shift <= {TDI, idcode_shift[31:1]};
    end
end

reg [2:0] dbg_ctrl_shift;
reg [2:0] dbg_ctrl_active;
reg [3:0] dbg_ctrl_hold;

always @(posedge TCK or negedge TRST_N) begin
    if (!TRST_N) begin
        dbg_ctrl_shift   <= 3'b000;
        dbg_ctrl_active   <= 3'b000;
        dbg_ctrl_hold    <= 4'd0;
        debug_halt_req   <= 1'b0;
        debug_resume_req <= 1'b0;
        debug_reset_req  <= 1'b0;
    end else begin
        if (state_capture_dr && (ir_reg == INSTR_DEBUG_CTRL))
            dbg_ctrl_shift <= 3'b000;
        else if (state_shift_dr && (ir_reg == INSTR_DEBUG_CTRL))
            dbg_ctrl_shift <= { dbg_ctrl_shift[1:0],TDI};

        if (state_update_dr && (ir_reg == INSTR_DEBUG_CTRL)) begin
            dbg_ctrl_active <= dbg_ctrl_shift;
            dbg_ctrl_hold   <= 4'd12;
`ifdef BENCH
            $display("JTAG CTRL UPDATE: shift=%b time=%0t", dbg_ctrl_shift, $time);
`endif
        end else if (dbg_ctrl_hold != 4'd0) begin
            dbg_ctrl_hold <= dbg_ctrl_hold - 4'd1;
        end
debug_halt_req <=
    ((state_update_dr && (ir_reg == INSTR_DEBUG_CTRL) && dbg_ctrl_shift[2]) ||
     ((dbg_ctrl_hold != 4'd0) && dbg_ctrl_active[2]));

debug_resume_req <=
    ((state_update_dr && (ir_reg == INSTR_DEBUG_CTRL) && dbg_ctrl_shift[1]) ||
     ((dbg_ctrl_hold != 4'd0) && dbg_ctrl_active[1]));

debug_reset_req <=
    ((state_update_dr && (ir_reg == INSTR_DEBUG_CTRL) && dbg_ctrl_shift[0]) ||
     ((dbg_ctrl_hold != 4'd0) && dbg_ctrl_active[0]));
    end
end

reg dbg_status_shift;

always @(posedge TCK or negedge TRST_N) begin
    if (!TRST_N) begin
        dbg_status_shift <= 1'b0;
    end else begin
        if (state_capture_dr && (ir_reg == INSTR_DEBUG_STATUS)) begin
            dbg_status_shift <= debug_halted;
`ifdef BENCH
            $display("STATUS CAPTURE halted=%b at time=%0t", debug_halted, $time);
`endif
        end
    end
end

reg [31:0] dbg_pc_shift;

always @(posedge TCK or negedge TRST_N) begin
    if (!TRST_N)
        dbg_pc_shift <= 32'h0;
    else begin
        if (state_capture_dr && (ir_reg == INSTR_DEBUG_PC))
            dbg_pc_shift <= debug_pc;
        else if (state_shift_dr && (ir_reg == INSTR_DEBUG_PC))
           dbg_pc_shift <= {1'b0, dbg_pc_shift[31:1]};
    end
end
always @(posedge TCK) begin
    if(state_shift_dr && ir_reg == INSTR_DEBUG_PC)
        $display("PC SHIFT tdo=%b shift=%08x time=%0t",
                 dbg_pc_shift[0],
                 dbg_pc_shift,
                 $time);
end
reg bypass_bit;

always @(posedge TCK or negedge TRST_N) begin
    if (!TRST_N)
        bypass_bit <= 1'b0;
    else begin
        if (state_capture_dr && (ir_reg == INSTR_BYPASS))
            bypass_bit <= 1'b0;
        else if (state_shift_dr && (ir_reg == INSTR_BYPASS))
            bypass_bit <= TDI;
    end
end

reg tdo_mux;

always @(*) begin
    if (state_shift_ir) begin
        tdo_mux = ir_shift[0];
    end else if (state_shift_dr && (ir_reg == INSTR_IDCODE)) begin
        tdo_mux = idcode_shift[0];
    end else if (state_shift_dr && (ir_reg == INSTR_DEBUG_CTRL)) begin
        tdo_mux = dbg_ctrl_shift[0];
    end else if (state_shift_dr && (ir_reg == INSTR_DEBUG_STATUS)) begin
        tdo_mux = dbg_status_shift;
    end else if (state_shift_dr && (ir_reg == INSTR_DEBUG_PC)) begin
        tdo_mux = dbg_pc_shift[0];
    end else if (state_shift_dr && (ir_reg == INSTR_BYPASS)) begin
        tdo_mux = bypass_bit;
    end else begin
        tdo_mux = 1'b1;
    end
end

always @(negedge TCK or negedge TRST_N) begin
    if (!TRST_N)
        TDO <= 1'b1;
    else
        TDO <= tdo_mux;
end
always @(posedge TCK) begin
    if(state_capture_dr && ir_reg==INSTR_DEBUG_PC)
        $display("PC CAPTURE debug_pc=%08x time=%0t",
                 debug_pc,$time);
end
always @(posedge TCK) begin
    if(state_update_dr && ir_reg==INSTR_DEBUG_CTRL)
       $display("CTRL UPDATE shift=%b time=%0t",
         dbg_ctrl_shift,
         $time);
end
always @(posedge TCK) begin
    if(state_shift_dr && ir_reg==INSTR_DEBUG_CTRL)
       $display("CTRL SHIFT TDI=%b shift=%b state=%0d time=%0t",
         TDI, dbg_ctrl_shift, tap_state, $time);
                 
end
always @(posedge TCK) begin
    if(state_shift_ir)
        $display("IR SHIFT TDI=%b ir_shift=%b time=%0t",
                 TDI,
                 ir_shift,
                 $time);
                 end
                 always @(negedge TCK)
begin
    if(state_shift_dr && ir_reg==INSTR_DEBUG_PC)
        $display("NEGEDGE TDO=%b dbg_pc_shift=%08x",
                 TDO,
                 dbg_pc_shift);end
                 
                 always @(posedge TCK)
begin
    if(state_update_ir)
        $display("IR UPDATE ir_shift=%b ir_reg=%b",
                 ir_shift,
                 ir_reg);
end


endmodule
