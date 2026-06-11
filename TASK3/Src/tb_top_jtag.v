`timescale 1ns / 1ps
`default_nettype none

module tb_idcode_sim;

    reg  tck = 0, tms = 1, tdi = 0, trst = 0;
    wire tdo;

    jtag_tap #(.IDCODE_VALUE(32'h81262776)) dut (
        .TCK(tck), .TMS(tms), .TDI(tdi), .TDO(tdo), .TRST_N(trst)
    );

    parameter H = 5;

    task tck_cycle;
        begin #H tck=1; #H tck=0; end
    endtask

    task tap_reset;
        integer i;
        begin tms=1; tdi=0; repeat(5) tck_cycle; tms=0; tck_cycle; end
    endtask

    task load_ir;
        input [3:0] instr;
        integer i;
        begin
            tms=1; tck_cycle;       // RTI→SEL_DR
            tms=1; tck_cycle;       // SEL_DR→SEL_IR
            tms=0; tck_cycle;       // SEL_IR→CAP_IR
            tms=0; tck_cycle;       // CAP_IR→SHIFT_IR (entry — no sample)
            for(i=0; i<4; i=i+1) begin
                tdi=instr[i]; tms=(i==3)?1:0; tck_cycle;
            end
            tms=1; tck_cycle;       // EXIT1_IR→UPDATE_IR
            tms=0; tck_cycle;       // UPDATE_IR→RTI
        end
    endtask

    reg [31:0] captured;
    task read_dr32;
        integer i;
        begin
            captured = 0;
            tms=1; tck_cycle;       // RTI→SEL_DR
            tms=0; tck_cycle;       // SEL_DR→CAP_DR  (loads shift reg)
            // Entry: CAP_DR→SHIFT_DR. Sample TDO on this negedge = bit[0]
            tms=0;
            #H tck=1; #H tck=0; #1 captured[0] = tdo;
            // 31 remaining bits
            for(i=1; i<32; i=i+1) begin
                tdi=0; tms=(i==31)?1:0;
                #H tck=1; #H tck=0; #1 captured[i] = tdo;
            end
            tms=1; tck_cycle;       // EXIT1_DR→UPDATE_DR
            tms=0; tck_cycle;       // UPDATE_DR→RTI
        end
    endtask

    initial begin
        $dumpfile("tb_idcode_sim.vcd");
        $dumpvars(0, tb_idcode_sim);
        #20 trst = 1;
        tap_reset;

        load_ir(4'b0001);   // IDCODE
        read_dr32;
        $display("IDCODE = 0x%08x (expected 0x81262776)", captured);

        if (captured === 32'h81262776)
            $display("TASK 3A SIM PASSED");
        else
            $display("FAIL: got 0x%08x", captured);

        $finish;
    end

endmodule
