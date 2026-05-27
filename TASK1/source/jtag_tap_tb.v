/**
 * jtag_tap_tb.v — Testbench for jtag_tap.v
 *
 * Tests:
 *   1. TRST_N asynchronous reset → state goes to TEST_LOGIC_RESET
 *   2. Navigate to SHIFT_DR and read out the 32-bit IDCODE
 *   3. Write BYPASS instruction, verify single-bit pipeline delay
 *   4. Navigate through all 16 states, confirm no hang
 */

`timescale 1ns / 1ps
`default_nettype none
`define BENCH

module jtag_tap_tb;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam [31:0] EXPECTED_IDCODE = 32'h1_CAFE_0_3;

// ---------------------------------------------------------------------------
// Signals
// ---------------------------------------------------------------------------
reg  TCK    = 0;
reg  TMS    = 1;
reg  TDI    = 0;
wire TDO;
reg  TRST_N = 0;

wire [3:0] tap_ir;
wire       cap_dr, shift_dr, upd_dr;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
jtag_tap #(
    .IDCODE_VALUE(EXPECTED_IDCODE)
) dut (
    .TCK           (TCK),
    .TMS           (TMS),
    .TDI           (TDI),
    .TDO           (TDO),
    .TRST_N        (TRST_N),
    .tap_ir_o      (tap_ir),
    .tap_capture_dr_o(cap_dr),
    .tap_shift_dr_o  (shift_dr),
    .tap_update_dr_o (upd_dr)
);

// ---------------------------------------------------------------------------
// Clock generation — 10 ns period (100 MHz TCK for sim speed)
// ---------------------------------------------------------------------------
always #5 TCK = ~TCK;

// ---------------------------------------------------------------------------
// Helper tasks
// ---------------------------------------------------------------------------

// Send one TCK cycle with given TMS/TDI values
task tck_cycle;
    input tms_val;
    input tdi_val;
    begin
        @(negedge TCK);   // set up data before rising edge
        TMS = tms_val;
        TDI = tdi_val;
        @(posedge TCK);   // TAP samples here
        #1;               // small settle
    end
endtask

// Go to TEST_LOGIC_RESET by sending TMS=1 for 5 cycles (guaranteed reset)
task goto_tlr;
    integer i;
    begin
        for (i = 0; i < 5; i = i + 1)
            tck_cycle(1, 0);
        $display("[%0t] → TEST_LOGIC_RESET via TMS=1 x5", $time);
    end
endtask

// Navigate from TLR to SHIFT_DR (IDCODE selected by default)
// TLR → RTI (TMS=0) → SEL_DR (TMS=1) → CAP_DR (TMS=0) → SHIFT_DR (TMS=0)
task goto_shift_dr;
    begin
        tck_cycle(0, 0);  // TLR → RTI
        tck_cycle(1, 0);  // RTI → SEL_DR
        tck_cycle(0, 0);  // SEL_DR → CAP_DR
        tck_cycle(0, 0);  // CAP_DR → SHIFT_DR
        $display("[%0t] → SHIFT_DR", $time);
    end
endtask

// Shift n bits, capture TDO into result (LSB first — JTAG convention)
// To exit SHIFT_DR after the last bit, set TMS=1 on the last cycle
task shift_bits;
    input  integer      n;
    input  [63:0]       tdi_data;   // data to shift in
    output reg [63:0]   tdo_data;   // data shifted out
    integer i;
    begin
        tdo_data = 64'b0;
        for (i = 0; i < n; i = i + 1) begin
            // last bit: assert TMS=1 to go EXIT1_DR
            tck_cycle((i == n-1) ? 1 : 0, tdi_data[i]);
            tdo_data[i] = TDO;
        end
    end
endtask

// Go back to RTI from EXIT1_DR  (EXIT1_DR → UPDATE_DR → RTI)
task exit1_to_rti;
    begin
        tck_cycle(1, 0);  // EXIT1_DR → UPDATE_DR
        tck_cycle(0, 0);  // UPDATE_DR → RTI
        $display("[%0t] → RUN_TEST_IDLE", $time);
    end
endtask

// Load an IR instruction
// From RTI: RTI → SEL_DR → SEL_IR → CAP_IR → SHIFT_IR
task load_ir;
    input [3:0] instr;
    reg   [63:0] dummy;
    integer i;
    begin
        tck_cycle(1, 0);  // RTI → SEL_DR
        tck_cycle(1, 0);  // SEL_DR → SEL_IR
        tck_cycle(0, 0);  // SEL_IR → CAP_IR
        tck_cycle(0, 0);  // CAP_IR → SHIFT_IR
        // shift 4 IR bits
        for (i = 0; i < 4; i = i + 1)
            tck_cycle((i == 3) ? 1 : 0, instr[i]);
        // EXIT1_IR → UPDATE_IR → RTI
        tck_cycle(1, 0);
        tck_cycle(0, 0);
        $display("[%0t] Loaded IR = 4'b%b", $time, instr);
    end
endtask

// ---------------------------------------------------------------------------
// Main stimulus
// ---------------------------------------------------------------------------
integer      pass_count = 0;
integer      fail_count = 0;
reg [63:0]   captured;
reg [31:0]   idcode_out;

initial begin
    $dumpfile("jtag_tap_tb.vcd");
    $dumpvars(0, jtag_tap_tb);

    // -----------------------------------------------------------------------
    // TEST 1: Asynchronous TRST_N reset
    // -----------------------------------------------------------------------
    $display("\n=== TEST 1: TRST_N async reset ===");
    TRST_N = 0;
    #12;                    // hold reset across a rising TCK edge
    TRST_N = 1;
    #2;
    if (dut.tap_state === 4'd0) begin
        $display("PASS: TAP in TEST_LOGIC_RESET after TRST_N");
        pass_count = pass_count + 1;
    end else begin
        $display("FAIL: TAP state = %0d (expected 0)", dut.tap_state);
        fail_count = fail_count + 1;
    end

    // -----------------------------------------------------------------------
    // TEST 2: TMS=1 x5 software reset
    // -----------------------------------------------------------------------
    $display("\n=== TEST 2: Software reset (TMS=1 x5) ===");
    // First move out of TLR into RTI
    tck_cycle(0, 0);
    // Then scatter some transitions
    tck_cycle(1, 0);
    tck_cycle(1, 0);
    // Now force back with 5 x TMS=1
    goto_tlr();
    if (dut.tap_state === 4'd0) begin
        $display("PASS: TAP in TEST_LOGIC_RESET after TMS=1 x5");
        pass_count = pass_count + 1;
    end else begin
        $display("FAIL: TAP state = %0d (expected 0)", dut.tap_state);
        fail_count = fail_count + 1;
    end

    // -----------------------------------------------------------------------
    // TEST 3: Read IDCODE (default instruction after reset)
    // -----------------------------------------------------------------------
    $display("\n=== TEST 3: Read IDCODE ===");
    goto_shift_dr();

    shift_bits(32, 64'b0, captured);
    idcode_out = captured[31:0];

    exit1_to_rti();

    $display("IDCODE read: 32'h%08X  (expected 32'h%08X)",
             idcode_out, EXPECTED_IDCODE);
    if (idcode_out === EXPECTED_IDCODE) begin
        $display("PASS: IDCODE matches");
        pass_count = pass_count + 1;
    end else begin
        $display("FAIL: IDCODE mismatch");
        fail_count = fail_count + 1;
    end

    // -----------------------------------------------------------------------
    // TEST 4: BYPASS instruction — verify 1-cycle pipeline delay
    // -----------------------------------------------------------------------
    $display("\n=== TEST 4: BYPASS instruction ===");
    load_ir(4'b1111);   // INSTR_BYPASS

    // Enter SHIFT_DR for BYPASS
    tck_cycle(1, 0);  // RTI → SEL_DR
    tck_cycle(0, 0);  // SEL_DR → CAP_DR
    tck_cycle(0, 0);  // CAP_DR → SHIFT_DR

    // Send pattern 1010_1010 and read back (expect 1-bit delay: first TDO=0)
    begin
        reg [7:0] tdi_pattern;
        reg [7:0] tdo_pattern;
        integer   j;
        tdi_pattern = 8'b1010_1010;
        tdo_pattern = 8'b0;
        for (j = 0; j < 8; j = j + 1) begin
            tck_cycle((j == 7) ? 1 : 0, tdi_pattern[j]);
            tdo_pattern[j] = TDO;
        end
        // Expected: tdo_pattern should be tdi_pattern shifted right by 1
        // tdo_pattern[7:1] == tdi_pattern[6:0], tdo_pattern[0] == 0 (cap value)
        $display("BYPASS TDI sent    : 8'b%b", tdi_pattern);
        $display("BYPASS TDO received: 8'b%b", tdo_pattern);
        if (tdo_pattern[7:1] === tdi_pattern[6:0] && tdo_pattern[0] === 1'b0) begin
            $display("PASS: BYPASS 1-bit delay correct");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: BYPASS data unexpected");
            fail_count = fail_count + 1;
        end
    end
    exit1_to_rti();

    // -----------------------------------------------------------------------
    // TEST 5: Walk all 16 states — just confirm no lockup
    // -----------------------------------------------------------------------
    $display("\n=== TEST 5: Walk all 16 states ===");
    goto_tlr();
    // TLR→RTI→SEL_DR→CAP_DR→SHIFT_DR→EXIT1_DR→PAUSE_DR→EXIT2_DR→SHIFT_DR
    //  →EXIT1_DR→UPDATE_DR→SEL_DR→SEL_IR→CAP_IR→SHIFT_IR→EXIT1_IR
    //  →PAUSE_IR→EXIT2_IR→SHIFT_IR→EXIT1_IR→UPDATE_IR→SEL_DR→TLR
    begin
        // Sequence of TMS values to tour all states
        // (documented against IEEE 1149.1 state diagram)
        reg [21:0] tms_seq;
        integer    k;
        // TLR(0)→RTI(1)→SELDR(2)→CAPDR(3)→SHDR(4)→EX1DR(5)→PAUSDR(6)
        // →EX2DR(7)→SHDR(4)→EX1DR(5)→UPDDR(8)→SELDR(2)→SELIR(9)
        // →CAPIR(10)→SHIR(11)→EX1IR(12)→PAUSIR(13)→EX2IR(14)→SHIR(11)
        // →EX1IR(12)→UPDIR(15)→SELDR(2)→TLR(0) via TMS=1x2
        tms_seq = 22'b11_1_0_1_1_0_1_1_0_1_1_0_0_0_1_0_0_0_1_0_0;
        //           ^TLR entry guard    
        // Easier to just drive the tested sequence explicitly:
        tck_cycle(0,0); // →RTI
        tck_cycle(1,0); // →SEL_DR
        tck_cycle(0,0); // →CAP_DR
        tck_cycle(0,0); // →SHIFT_DR
        tck_cycle(1,0); // →EXIT1_DR
        tck_cycle(0,0); // →PAUSE_DR
        tck_cycle(1,0); // →EXIT2_DR
        tck_cycle(0,0); // →SHIFT_DR  (back)
        tck_cycle(1,0); // →EXIT1_DR
        tck_cycle(1,0); // →UPDATE_DR
        tck_cycle(1,0); // →SEL_DR
        tck_cycle(1,0); // →SEL_IR
        tck_cycle(0,0); // →CAP_IR
        tck_cycle(0,0); // →SHIFT_IR
        tck_cycle(1,0); // →EXIT1_IR
        tck_cycle(0,0); // →PAUSE_IR
        tck_cycle(1,0); // →EXIT2_IR
        tck_cycle(0,0); // →SHIFT_IR  (back)
        tck_cycle(1,0); // →EXIT1_IR
        tck_cycle(1,0); // →UPDATE_IR
        tck_cycle(1,0); // →SEL_DR
        tck_cycle(1,0); // →SEL_IR → ... TMS=1 path from SEL_IR = TLR
        tck_cycle(1,0); // →TLR
        if (dut.tap_state === 4'd0) begin
            $display("PASS: All 16 states traversed, landed in TLR");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: Ended in state %0d (expected TLR=0)", dut.tap_state);
            fail_count = fail_count + 1;
        end
    end

    // -----------------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------------
    $display("\n=== RESULTS: %0d passed, %0d failed ===\n",
             pass_count, fail_count);
    if (fail_count == 0)
        $display("ALL TESTS PASSED");
    else
        $display("SOME TESTS FAILED — review log above");

    $finish;
end

endmodule
