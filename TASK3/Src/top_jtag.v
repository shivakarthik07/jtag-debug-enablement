// top_jtag.v  — FPGA top module
// Target : VSDSquadron FM (Lattice iCE40UP5K)
`timescale 1ns / 1ps
`default_nettype none

module top_jtag (
    input  wire tck,
    input  wire tms,
    input  wire tdi,
    input  wire trst,   
    output wire tdo,
    output wire led
);

    jtag_tap #(
        .IDCODE_VALUE(32'h81262776)   // iCE40UP5K JTAG IDCODE
    ) u_tap (
        .TCK    (tck),
        .TMS    (tms),
        .TDI    (tdi),
        .TDO    (tdo),
        .TRST_N (trst)
    );

    // LED = constant 1 — proves bitstream is loaded (no system clock needed)
    assign led = 1'b1;

endmodule
