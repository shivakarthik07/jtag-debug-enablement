`timescale 1ns / 1ps
`default_nettype none

module tb_jtag_debug;

    reg         RESET   = 1'b0;
    reg         RXD     = 1'b1;
    wire [4:0]  LEDS;
    wire        TXD;

    reg         TCK    = 1'b0;
    reg         TMS    = 1'b1;
    reg         TDI    = 1'b0;
    wire        TDO;
    reg         TRST_N = 1'b0;

    wire        debug_halt_req;
    wire        debug_resume_req;
    wire        debug_reset_req;
    wire        debug_halted;
    wire [31:0] debug_pc;

    SOC dut (
        .RESET            (RESET),
        .LEDS             (LEDS),
        .RXD              (RXD),
        .TXD              (TXD),
        .TCK              (TCK),
        .TMS              (TMS),
        .TDI              (TDI),
        .TDO              (TDO),
        .TRST_N           (TRST_N),
        .debug_halt_req   (debug_halt_req),
        .debug_resume_req (debug_resume_req),
        .debug_reset_req  (debug_reset_req),
        .debug_halted     (debug_halted),
        .debug_pc         (debug_pc)
    );

    localparam [3:0]
        JTAG_IDCODE       = 4'b0001,
        JTAG_DEBUG_CTRL   = 4'b0010,
        JTAG_DEBUG_STATUS = 4'b0011,
        JTAG_DEBUG_PC     = 4'b0100,
        JTAG_BYPASS       = 4'b1111;

    task automatic jtag_cycle;
        input  tms_i;
        input  tdi_i;
        output tdo_o;
        begin
            TMS = tms_i;
            TDI = tdi_i;
            #5 TCK = 1'b1;
            #4 tdo_o = TDO;
            #1 TCK = 1'b0;
            #5;
        end
    endtask

    task automatic jtag_reset_tap;
        integer k;
        reg dummy;
        begin
            for (k = 0; k < 5; k = k + 1)
                jtag_cycle(1'b1, 1'b0, dummy);
            jtag_cycle(1'b0, 1'b0, dummy);
        end
    endtask

    task automatic jtag_set_ir;
        input [3:0] instr;
        reg dummy;
        begin
            jtag_reset_tap();
            $display("SET_IR request=%b", instr);
            // RTI -> SELECT_DR_SCAN -> SELECT_IR_SCAN
            jtag_cycle(1'b1, 1'b0, dummy);
            jtag_cycle(1'b1, 1'b0, dummy);
            // SELECT_IR_SCAN -> CAPTURE_IR -> SHIFT_IR
            jtag_cycle(1'b0, 1'b0, dummy);
            jtag_cycle(1'b0, 1'b0, dummy);
            // Shift 4-bit IR, TMS=1 on last bit to exit
            jtag_cycle(1'b0, instr[0], dummy);
            jtag_cycle(1'b0, instr[1], dummy);
            jtag_cycle(1'b0, instr[2], dummy);
            jtag_cycle(1'b1, instr[3], dummy);
            // EXIT1_IR -> UPDATE_IR -> RTI
            jtag_cycle(1'b1, 1'b0, dummy);
            jtag_cycle(1'b0, 1'b0, dummy);
        end
    endtask

    task automatic jtag_write_ctrl;
        input [2:0] ctrl;
        reg dummy;
        begin
            jtag_set_ir(JTAG_DEBUG_CTRL);
            // RTI -> SELECT_DR
            jtag_cycle(1'b1, 1'b0, dummy);
            // SELECT_DR -> CAPTURE_DR
            jtag_cycle(1'b0, 1'b0, dummy);
            // CAPTURE_DR -> SHIFT_DR
            jtag_cycle(1'b0, 1'b0, dummy);
            // TAP assembles with {shift[1:0], TDI} so first bit in lands at bit[0]
            // after three shifts. Send bit[2] first so it ends up at bit[2].
            jtag_cycle(1'b0, ctrl[2], dummy);
            jtag_cycle(1'b0, ctrl[1], dummy);
            jtag_cycle(1'b1, ctrl[0], dummy);
            // EXIT1_DR -> UPDATE_DR
            jtag_cycle(1'b1, 1'b0, dummy);
            // UPDATE_DR -> RTI
            jtag_cycle(1'b0, 1'b0, dummy);
        end
    endtask

    task automatic jtag_read_dr1;
        input  [3:0] instr;
        output       value;
        reg dummy;
        reg tdo_bit;
        begin
            jtag_set_ir(instr);
            // RTI -> SELECT_DR
            jtag_cycle(1'b1, 1'b0, dummy);
            // SELECT_DR -> CAPTURE_DR
            jtag_cycle(1'b0, 1'b0, dummy);
            // CAPTURE_DR -> SHIFT_DR
            jtag_cycle(1'b0, 1'b0, dummy);
            // Shift one bit and exit (TMS=1)
            jtag_cycle(1'b1, 1'b0, tdo_bit);
            value = tdo_bit;
            // EXIT1_DR -> UPDATE_DR
            jtag_cycle(1'b1, 1'b0, dummy);
            // UPDATE_DR -> RTI
            jtag_cycle(1'b0, 1'b0, dummy);
        end
    endtask

    task automatic jtag_read_dr32;
        input  [3:0]  instr;
        output [31:0] value;
        integer i;
        reg dummy;
        reg tdo_bit;
        begin
            value = 32'h0;
            jtag_set_ir(instr);
            // RTI -> SELECT_DR
            jtag_cycle(1'b1, 1'b0, dummy);
            // SELECT_DR -> CAPTURE_DR
            jtag_cycle(1'b0, 1'b0, dummy);
            // CAPTURE_DR -> SHIFT_DR
            jtag_cycle(1'b0, 1'b0, dummy);
            // Shift 32 bits, TMS=1 on the last cycle to exit
            for (i = 0; i < 32; i = i + 1) begin
                jtag_cycle((i == 31), 1'b0, tdo_bit);
                value[i] = tdo_bit;
            end
            // EXIT1_DR -> UPDATE_DR
            jtag_cycle(1'b1, 1'b0, dummy);
            // UPDATE_DR -> RTI
            jtag_cycle(1'b0, 1'b0, dummy);
        end
    endtask

    task automatic wait_core_cycles;
        input integer n;
        integer j;
        begin
            for (j = 0; j < n; j = j + 1)
                @(posedge dut.clk);
        end
    endtask

    task automatic wait_for_halted;
        input integer max_cycles;
        integer i;
        begin
            for (i = 0; i < max_cycles; i = i + 1) begin
                if (debug_halted === 1'b1)
                    disable wait_for_halted;
                @(posedge dut.clk);
            end
            $display("FAIL: timeout waiting for halted");
            $finish;
        end
    endtask

    task automatic wait_for_running;
        input integer max_cycles;
        integer i;
        begin
            for (i = 0; i < max_cycles; i = i + 1) begin
                if (debug_halted === 1'b0)
                    disable wait_for_running;
                @(posedge dut.clk);
            end
            $display("FAIL: timeout waiting for running");
            $finish;
        end
    endtask

    task automatic fail;
        input [1023:0] msg;
        begin
            $display("FAIL: %0s", msg);
            $finish;
        end
    endtask

    reg [31:0] pc0;
    reg [31:0] pc1;
    reg [31:0] pc2;
    reg [31:0] expected_pc;
    reg [31:0] read_pc;
    reg        status_bit;

    initial begin
        $dumpfile("jtag_debug.vcd");
        $dumpvars(0, tb_jtag_debug);

        TMS    = 1'b1;
        TDI    = 1'b0;
        TCK    = 1'b0;
        TRST_N = 1'b0;
        RESET  = 1'b0;

        #100;
        TRST_N = 1'b1;

        jtag_reset_tap();
        wait_core_cycles(50);

        pc0 = debug_pc;
        $display("Core is running");
        $display("Initial PC = %08x", pc0);

        wait_core_cycles(50);
        pc1 = debug_pc;
        if (pc1 == pc0)
            fail("PC did not change while running");

        // ----------------------------------------------------------------
        // FIX 3: was 3'b001 (RESET); correct value for HALT is 3'b100
        //   bit[2]=halt_req, bit[1]=resume_req, bit[0]=reset_req
        // ----------------------------------------------------------------
        $display("Sending HALT through JTAG");
        jtag_write_ctrl(3'b100);
        wait_for_halted(200);

        if (debug_halted !== 1'b1)
            fail("Core did not enter halted state");

        expected_pc = debug_pc;
        wait_core_cycles(20);
        pc2 = debug_pc;
        if (pc2 !== expected_pc)
            fail("PC changed while halted");

        $display("Reading STATUS through JTAG");
        jtag_read_dr1(JTAG_DEBUG_STATUS, status_bit);
        if (status_bit !== 1'b1)
            fail("STATUS read was not HALTED");

        $display("Reading PC through JTAG");
        jtag_read_dr32(JTAG_DEBUG_PC, read_pc);
        $display("EXPECTED_PC = %08x", expected_pc);
        $display("READ_PC     = %08x", read_pc);
        if (read_pc !== expected_pc)
            fail("DEBUG_PC read did not match the frozen PC");

        $display("Sending RESUME through JTAG");
        jtag_write_ctrl(3'b010);
        wait_for_running(200);

        pc1 = debug_pc;
        wait_core_cycles(50);
        pc2 = debug_pc;
        if (pc2 == pc1)
            fail("PC did not change after resume");

        $display("PASS");
        $finish;
    end

endmodule
