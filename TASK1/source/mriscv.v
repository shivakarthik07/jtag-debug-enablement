/**
 * riscv_jtag.v — SOC top-level with JTAG TAP integrated
 *
 * Changes from original riscv.v:
 *   1. Added TCK, TMS, TDI, TDO, TRST_N to SOC port list.
 *   2. Instantiated jtag_tap inside SOC.
 *   3. gpio_ip and UART wiring unchanged.
 *
 * NOTE: Memory, Processor, and peripheral modules are identical to
 *       riscv.v — only SOC is extended here.
 */

`timescale 1ns / 1ps
`default_nettype none
`include "clockworks.v"
`include "emitter_uart.v"
`include "jtag_tap.v"      // <-- new

// ============================================================
//  Memory  (unchanged)
// ============================================================
module Memory (
   input             clk,
   input      [31:0] mem_addr,
   output reg [31:0] mem_rdata,
   input             mem_rstrb,
   input      [31:0] mem_wdata,
   input      [3:0]  mem_wmask
);
   reg [31:0] MEM [0:1535];
   initial begin $readmemh("firmware.hex", MEM); end

   wire [29:0] word_addr = mem_addr[31:2];
   always @(posedge clk) begin
      if(mem_rstrb) mem_rdata <= MEM[word_addr];
      if(mem_wmask[0]) MEM[word_addr][ 7: 0] <= mem_wdata[ 7: 0];
      if(mem_wmask[1]) MEM[word_addr][15: 8] <= mem_wdata[15: 8];
      if(mem_wmask[2]) MEM[word_addr][23:16] <= mem_wdata[23:16];
      if(mem_wmask[3]) MEM[word_addr][31:24] <= mem_wdata[31:24];
   end
endmodule

// ============================================================
//  Processor  (unchanged — full implementation from riscv.v)
// ============================================================
module Processor (
    input         clk,
    input         resetn,
    output [31:0] mem_addr,
    input  [31:0] mem_rdata,
    output        mem_rstrb,
    output [31:0] mem_wdata,
    output [3:0]  mem_wmask
);
   reg [31:0] PC=0;
   reg [31:0] instr;

   wire isALUreg  = (instr[6:0] == 7'b0110011);
   wire isALUimm  = (instr[6:0] == 7'b0010011);
   wire isBranch  = (instr[6:0] == 7'b1100011);
   wire isJALR    = (instr[6:0] == 7'b1100111);
   wire isJAL     = (instr[6:0] == 7'b1101111);
   wire isAUIPC   = (instr[6:0] == 7'b0010111);
   wire isLUI     = (instr[6:0] == 7'b0110111);
   wire isLoad    = (instr[6:0] == 7'b0000011);
   wire isStore   = (instr[6:0] == 7'b0100011);
   wire isSYSTEM  = (instr[6:0] == 7'b1110011);

   wire [31:0] Uimm = {    instr[31],   instr[30:12], {12{1'b0}}};
   wire [31:0] Iimm = {{21{instr[31]}}, instr[30:20]};
   wire [31:0] Simm = {{21{instr[31]}}, instr[30:25], instr[11:7]};
   wire [31:0] Bimm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
   wire [31:0] Jimm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};

   wire [4:0] rs1Id = instr[19:15];
   wire [4:0] rs2Id = instr[24:20];
   wire [4:0] rdId  = instr[11:7];
   wire [2:0] funct3 = instr[14:12];
   wire [6:0] funct7 = instr[31:25];

   reg [31:0] RegisterBank [0:31];
   reg [31:0] rs1, rs2;
   wire [31:0] writeBackData;
   wire        writeBackEn;

`ifdef BENCH
   integer i;
   initial begin for(i=0;i<32;i=i+1) RegisterBank[i]=0; end
`endif

   wire [31:0] aluIn1 = rs1;
   wire [31:0] aluIn2 = isALUreg | isBranch ? rs2 : Iimm;
   wire [4:0]  shamt  = isALUreg ? rs2[4:0] : instr[24:20];
   wire [31:0] aluPlus = aluIn1 + aluIn2;
   wire [32:0] aluMinus = {1'b1,~aluIn2} + {1'b0,aluIn1} + 33'b1;
   wire        LT  = (aluIn1[31]^aluIn2[31]) ? aluIn1[31] : aluMinus[32];
   wire        LTU = aluMinus[32];
   wire        EQ  = (aluMinus[31:0]==0);

   function [31:0] flip32; input [31:0] x;
      flip32={x[0],x[1],x[2],x[3],x[4],x[5],x[6],x[7],
              x[8],x[9],x[10],x[11],x[12],x[13],x[14],x[15],
              x[16],x[17],x[18],x[19],x[20],x[21],x[22],x[23],
              x[24],x[25],x[26],x[27],x[28],x[29],x[30],x[31]};
   endfunction

   wire [31:0] shifter_in = (funct3==3'b001) ? flip32(aluIn1) : aluIn1;
   /* verilator lint_off WIDTH */
   wire [31:0] shifter = $signed({instr[30]&aluIn1[31],shifter_in}) >>> aluIn2[4:0];
   /* verilator lint_on WIDTH */
   wire [31:0] leftshift = flip32(shifter);

   reg [31:0] aluOut;
   always @(*) begin
      case(funct3)
         3'b000: aluOut=(funct7[5]&instr[5]) ? aluMinus[31:0] : aluPlus;
         3'b001: aluOut=leftshift;
         3'b010: aluOut={31'b0,LT};
         3'b011: aluOut={31'b0,LTU};
         3'b100: aluOut=(aluIn1^aluIn2);
         3'b101: aluOut=shifter;
         3'b110: aluOut=(aluIn1|aluIn2);
         3'b111: aluOut=(aluIn1&aluIn2);
      endcase
   end

   reg takeBranch;
   always @(*) begin
      case(funct3)
         3'b000: takeBranch=EQ;
         3'b001: takeBranch=!EQ;
         3'b100: takeBranch=LT;
         3'b101: takeBranch=!LT;
         3'b110: takeBranch=LTU;
         3'b111: takeBranch=!LTU;
         default: takeBranch=1'b0;
      endcase
   end

   wire [31:0] PCplusImm = PC + (instr[3] ? Jimm : instr[4] ? Uimm : Bimm);
   wire [31:0] PCplus4   = PC + 4;

   assign writeBackData = (isJAL||isJALR) ? PCplus4  :
                          isLUI           ? Uimm     :
                          isAUIPC         ? PCplusImm:
                          isLoad          ? LOAD_data:
                                            aluOut;

   wire [31:0] nextPC = ((isBranch&&takeBranch)||isJAL) ? PCplusImm  :
                        isJALR ? {aluPlus[31:1],1'b0} : PCplus4;

   wire [31:0] loadstore_addr = rs1 + (isStore ? Simm : Iimm);
   wire mem_byteAccess     = funct3[1:0]==2'b00;
   wire mem_halfwordAccess = funct3[1:0]==2'b01;
   wire [15:0] LOAD_halfword = loadstore_addr[1] ? mem_rdata[31:16] : mem_rdata[15:0];
   wire  [7:0] LOAD_byte     = loadstore_addr[0] ? LOAD_halfword[15:8] : LOAD_halfword[7:0];
   wire LOAD_sign = !funct3[2] & (mem_byteAccess ? LOAD_byte[7] : LOAD_halfword[15]);
   wire [31:0] LOAD_data =
         mem_byteAccess ? {{24{LOAD_sign}},LOAD_byte} :
     mem_halfwordAccess ? {{16{LOAD_sign}},LOAD_halfword} : mem_rdata;

   assign mem_wdata[ 7: 0] = rs2[7:0];
   assign mem_wdata[15: 8] = loadstore_addr[0] ? rs2[7:0]  : rs2[15:8];
   assign mem_wdata[23:16] = loadstore_addr[1] ? rs2[7:0]  : rs2[23:16];
   assign mem_wdata[31:24] = loadstore_addr[0] ? rs2[7:0]  :
                             loadstore_addr[1] ? rs2[15:8] : rs2[31:24];

   wire [3:0] STORE_wmask =
      mem_byteAccess      ? (loadstore_addr[1] ?
                               (loadstore_addr[0] ? 4'b1000 : 4'b0100) :
                               (loadstore_addr[0] ? 4'b0010 : 4'b0001)) :
      mem_halfwordAccess  ? (loadstore_addr[1] ? 4'b1100 : 4'b0011) :
                             4'b1111;

   localparam FETCH_INSTR=0,WAIT_INSTR=1,FETCH_REGS=2,EXECUTE=3,
              LOAD=4,WAIT_DATA=5,STORE=6;
   reg [2:0] state=FETCH_INSTR;

   always @(posedge clk) begin
      if(!resetn) begin PC<=0; state<=FETCH_INSTR; end
      else begin
         if(writeBackEn && rdId!=0) RegisterBank[rdId]<=writeBackData;
         case(state)
            FETCH_INSTR: state<=WAIT_INSTR;
            WAIT_INSTR:  begin instr<=mem_rdata; state<=FETCH_REGS; end
            FETCH_REGS:  begin rs1<=RegisterBank[rs1Id]; rs2<=RegisterBank[rs2Id]; state<=EXECUTE; end
            EXECUTE: begin
               if(!isSYSTEM) PC<=nextPC;
               state <= isLoad ? LOAD : isStore ? STORE : FETCH_INSTR;
`ifdef BENCH
               if(isSYSTEM) $finish();
`endif
            end
            LOAD:      state<=WAIT_DATA;
            WAIT_DATA: state<=FETCH_INSTR;
            STORE:     state<=FETCH_INSTR;
         endcase
      end
   end

   assign writeBackEn = (state==EXECUTE && !isBranch && !isStore) || (state==WAIT_DATA);
   assign mem_addr    = (state==WAIT_INSTR||state==FETCH_INSTR) ? PC : loadstore_addr;
   assign mem_rstrb   = (state==FETCH_INSTR || state==LOAD);
   assign mem_wmask   = {4{(state==STORE)}} & STORE_wmask;
endmodule


// ============================================================
//  SOC — extended with JTAG pins
// ============================================================
module SOC (
    input         CLK,          // 12 MHz board oscillator
    input         RESET,
    output reg [4:0] LEDS,
    input         RXD,
    output        TXD,

    // ---- JTAG pins (new) ----
    input         TCK,
    input         TMS,
    input         TDI,
    output        TDO,
    input         TRST_N        // async reset for TAP
);

`ifdef BENCH
reg  clk;
wire resetn;
`else
wire clk;
wire resetn;

// Clockworks: generates divided/gated clk and power-on resetn
Clockworks #(.SLOW(0)) CW (
   .CLK   (CLK),
   .RESET (RESET),
   .clk   (clk),
   .resetn(resetn)
);
`endif

   wire [31:0] mem_addr, mem_rdata, mem_wdata;
   wire        mem_rstrb;
   wire [3:0]  mem_wmask;

   Processor CPU(
      .clk(clk), .resetn(resetn),
      .mem_addr(mem_addr), .mem_rdata(mem_rdata),
      .mem_rstrb(mem_rstrb),
      .mem_wdata(mem_wdata), .mem_wmask(mem_wmask)
   );

   wire [31:0] RAM_rdata;
   wire [29:0] mem_wordaddr = mem_addr[31:2];
   wire isIO  = mem_addr[22];
   wire isRAM = !isIO;
   wire mem_wstrb = |mem_wmask;

   Memory RAM(
      .clk(clk), .mem_addr(mem_addr),
      .mem_rdata(RAM_rdata),
      .mem_rstrb(isRAM & mem_rstrb),
      .mem_wdata(mem_wdata),
      .mem_wmask({4{isRAM}} & mem_wmask)
   );

   localparam IO_LEDS_bit      = 0;
   localparam IO_UART_DAT_bit  = 1;
   localparam IO_UART_CNTL_bit = 2;
   localparam IO_GPIO_bit      = 3;

   always @(posedge clk) begin
      if(isIO & mem_wstrb & mem_wordaddr[IO_LEDS_bit])
         LEDS <= mem_wdata;
   end

   wire uart_valid = isIO & mem_wstrb & mem_wordaddr[IO_UART_DAT_bit];
   wire uart_ready;

   corescore_emitter_uart #(
      .clk_freq_hz(12*1000000),
      .baud_rate(9600)
   ) UART(
      .i_clk(clk), .i_rst(!resetn),
      .i_data(mem_wdata[7:0]),
      .i_valid(uart_valid), .o_ready(uart_ready),
      .o_uart_tx(TXD)
   );

   wire [31:0] gpio_rdata, gpio_data;
   wire gpio_sel   = isIO && (mem_wordaddr == 30'h00100008);
   wire gpio_wr_en = gpio_sel && |mem_wmask;
   wire gpio_rd_en = gpio_sel && mem_rstrb;

   gpio_ip GPIO(
      .clk(clk), .resetn(resetn),
      .wr_en(gpio_wr_en), .rd_en(gpio_rd_en),
      .wdata(mem_wdata), .rdata(gpio_rdata),
      .gpio_data(gpio_data)
   );

   wire [31:0] IO_rdata =
      mem_wordaddr[IO_UART_CNTL_bit] ? {22'b0, !uart_ready, 9'b0} :
      gpio_sel                        ? gpio_rdata : 32'b0;

   assign mem_rdata = isRAM ? RAM_rdata : IO_rdata;

   // ----------------------------------------------------------
   //  JTAG TAP instantiation (new)
   // ----------------------------------------------------------
   wire [3:0] jtag_ir;
   wire       jtag_cap_dr, jtag_shift_dr, jtag_upd_dr;

   jtag_tap #(
      .IDCODE_VALUE(32'h1_CAFE_0_3)   // version=1, part=CAFE, mfr=VSD
   ) TAP (
      .TCK             (TCK),
      .TMS             (TMS),
      .TDI             (TDI),
      .TDO             (TDO),
      .TRST_N          (TRST_N),
      .tap_ir_o        (jtag_ir),
      .tap_capture_dr_o(jtag_cap_dr),
      .tap_shift_dr_o  (jtag_shift_dr),
      .tap_update_dr_o (jtag_upd_dr)
   );
   // jtag_ir / jtag_*_dr signals are available here to connect
   // a future debug module (e.g. DM / DMI bridge).

`ifdef BENCH
   initial begin
      $dumpfile("soc.vcd");
      $dumpvars(0, SOC);
   end
   always @(posedge clk) begin
      if(uart_valid) begin
         $write("%c", mem_wdata[7:0]);
         $fflush(32'h8000_0001);
      end
   end

   // Clock & reset for bench
   initial clk = 0;
   always #5 clk = ~clk;

   reg resetn_reg;
   assign resetn = resetn_reg;
   initial begin resetn_reg=0; #20; resetn_reg=1; end
`endif

endmodule
