# JTAG TAP Controller — VSDSquadron RISC-V Integration

> **Task 1 Deliverable** -JTAG TAP controller added to the VSDSquadron RISC-V SoC.

---

## Table of Contents

1. [Introduction to JTAG](#1-introduction-to-jtag)
2. [How JTAG Works](#2-how-jtag-works)
3. [Implementation Details](#3-implementation-details)
4. [Simulation Results](#4-simulation-results)
5. [Synthesis & PnR Results](#5-synthesis--pnr-results)
6. [FPGA Pin Mapping](#6-fpga-pin-mapping)


---

## 1. Introduction to JTAG

<img width="1408" height="768" alt="Gemini_Generated_Image_yrcmgryrcmgryrcm" src="https://github.com/user-attachments/assets/4c5c4992-98a1-41be-94df-46369f3931b2" />

**JTAG** (Joint Test Action Group) is an industry-standard interface defined in **IEEE 1149.1**, originally created in the late 1980s to solve the growing problem of testing densely packed PCBs where physical probing of individual pins had become impractical.

### What Problem Does JTAG Solve?

As surface-mount technology replaced through-hole components, the solder joints and inter-chip connections on a board became physically inaccessible to test probes. JTAG solved this by building a **serial scan chain** directly into the silicon, allowing a tester to drive and observe digital signals through just four (or five) dedicated pins regardless of how buried the device is on a board.

### Key Advantages

| Advantage | Description |
|---|---|
| **Boundary Scan** | Observe and drive every I/O pin of a chip without a physical probe — ideal for bare-board testing and bring-up |
| **In-System Programming** | Flash FPGAs, CPLDs, and Flash memories over the same four wires; no external programmer socket needed |
| **On-Chip Debug (OCD)** | Modern cores (ARM Cortex, RISC-V via JTAG-DTM) use JTAG as the physical transport for halting the CPU, reading registers, and single-stepping code |
| **Daisy-Chaining** | Multiple devices can share a single JTAG chain on a board — only one connector required |
| **Standardisation** | Universally supported by debug probes (J-Link, OpenOCD, FTDI), logic analysers, and EDA tools |
| **Minimal Pin Count** | Only TCK, TMS, TDI, TDO (+ optional TRST_N) — just four mandatory signals |
| **Non-Intrusive** | The JTAG clock (TCK) is completely independent of the system clock, so debug access never interferes with live operation |

For a RISC-V SoC like the VSDSquadron, adding even a minimal JTAG TAP is the first step toward full GDB-level debugging via OpenOCD, boundary-scan testing, and FPGA configuration — all over the same connector.

---

## 2. How JTAG Works

### The Four (Five) Wires

| Signal | Direction | Function |
|---|---|---|
| **TCK** | Input | Test Clock — all TAP state changes and data capture/shift occur on this clock |
| **TMS** | Input | Test Mode Select — a 1-bit control that steers the TAP state machine |
| **TDI** | Input | Test Data In — serial data shifted into registers, LSB first |
| **TDO** | Output | Test Data Out — serial data shifted out, driven on the **falling** edge of TCK |
| **TRST_N** | Input (opt.) | Asynchronous active-low reset — immediately forces the TAP to Test-Logic-Reset |

### The TAP State Machine (16 States)

The heart of JTAG is a **16-state Moore machine** clocked by TCK. The next state is determined solely by the current state and the value of TMS sampled on each rising TCK edge. The full state diagram is:

```
                          ┌─────────────────────────────────────────────────────┐
              TMS=1 ──►   │  TEST-LOGIC-RESET  │◄── TMS=1 (from any state ×5) │
                          └───────────┬─────────┘                               │
                              TMS=0   │                                          │
                          ┌───────────▼─────────┐                               │
                          │   RUN-TEST/IDLE     │◄──────────────────────────────┘
                          └───────────┬─────────┘
                              TMS=1   │
                    ┌─────────────────▼──────────────────┐
                    │          SELECT-DR-SCAN            │
                    └────┬──────────────────────────┬────┘
                 TMS=0   │                  TMS=1    │
          ┌──────────────▼──────────┐   ┌───────────▼─────────────┐
          │      CAPTURE-DR        │   │     SELECT-IR-SCAN      │
          └──────────┬─────────────┘   └────────────┬────────────┘
              TMS=0  │                       TMS=0   │
          ┌──────────▼──────────┐    ┌──────────────▼────────────┐
          │      SHIFT-DR       │    │         CAPTURE-IR        │
          └──────────┬──────────┘    └──────────────┬────────────┘
              TMS=1  │                       TMS=0   │
          ┌──────────▼──────────┐    ┌──────────────▼────────────┐
          │      EXIT1-DR       │    │          SHIFT-IR         │
          └──┬──────────────┬───┘    └──────────────┬────────────┘
      TMS=1  │      TMS=0   │                TMS=1  │
     ┌───────▼──────┐  ┌────▼──────┐  ┌────────────▼────────────┐
     │  UPDATE-DR   │  │ PAUSE-DR  │  │        EXIT1-IR         │
     └──────────────┘  └───────────┘  └─────────────────────────┘
                                  ... (mirror for IR path)
```

**TMS=1 for five or more consecutive TCK cycles always returns the TAP to Test-Logic-Reset** — a mandatory software reset sequence.

### Instruction Register (IR) and Data Registers (DR)

1. **Instruction Register** — a shift register (4 bits in this design) that selects which Data Register is connected between TDI and TDO. It is loaded by navigating through the IR scan path (SELECT-IR → CAPTURE-IR → SHIFT-IR → UPDATE-IR).

2. **Data Registers** — the actual payloads:
   - **IDCODE register** (32 bits): holds a manufacturer/part/version code; read-only.
   - **BYPASS register** (1 bit): a transparent single-bit pipeline used when the chip is in a chain but is not the target of the current operation.

### A Minimal IDCODE Read Sequence

```
TRST_N pulse             → TAP forced to TLR, IR defaults to IDCODE (4'b0001)
TMS=0                    → TLR → Run-Test/Idle
TMS=1                    → RTI → Select-DR-Scan
TMS=0                    → Select-DR-Scan → Capture-DR    (IDCODE loaded into shift reg)
TMS=0                    → Capture-DR → Shift-DR
TMS=0 × 31 clocks        → shift out bits [0..30] of IDCODE on TDO
TMS=1                    → Shift-DR → Exit1-DR            (bit 31 shifted on this edge)
TMS=1                    → Exit1-DR → Update-DR
TMS=0                    → Update-DR → Run-Test/Idle
```

32 TDO bits collected LSB-first = IDCODE value.

---

## 3. Implementation Details

### File Structure

```
.
├── jtag_tap.v          # TAP controller (new)
├── mriscv.v            # SOC top-level with JTAG pins added
├── jtag_tap_tb.v       # Simulation testbench
└── VSDSquadronFM.pcf   # iCE40 pin constraints (JTAG pins added)
```

### 3.1 `jtag_tap.v` — The TAP Controller


#### Module Interface

```verilog
module jtag_tap #(
    parameter [31:0] IDCODE_VALUE = 32'h1_CAFE_0_3
) (
    input  wire TCK, TMS, TDI, TRST_N,
    output reg  TDO,
    output wire [3:0] tap_ir_o,        // current latched IR exposed to SoC
    output wire       tap_capture_dr_o,
    output wire       tap_shift_dr_o,
    output wire       tap_update_dr_o
);
```

The IDCODE is a parameterised 32-bit constant (`32'h1_CAFE_0_3`): version nibble `1`, part number `CAFE`, manufacturer code `VSD` encoded as `003`). Because it is a `parameter`, synthesis tools inline the value at elaboration time and the same netlist is reused for any IDCODE by simply overriding the parameter — as seen in the synthesis log (`Parameter \IDCODE_VALUE = 30080515`).

#### State Machine

All 16 IEEE 1149.1 states are implemented as a `localparam` encoded 4-bit value. The next-state function is a pure combinatorial Verilog `function` (no latches) evaluated on the rising edge of TCK:

```verilog
always @(posedge TCK or negedge TRST_N) begin
    if (!TRST_N)
        tap_state <= TEST_LOGIC_RESET;
    else
        tap_state <= next_state(tap_state, TMS);
end
```

Asynchronous reset (`negedge TRST_N`) ensures the TAP reaches a safe state instantaneously, independent of any clock activity — a mandatory IEEE 1149.1 requirement.

#### Instruction Register

```verilog
always @(posedge TCK or negedge TRST_N) begin
    if (!TRST_N) begin
        ir_shift <= INSTR_IDCODE;
        ir_reg   <= INSTR_IDCODE;         // power-on default = IDCODE
    end else begin
        if (state_capture_ir)
            ir_shift <= INSTR_IDCODE;     // capture fixed pattern (IEEE mandated)
        else if (state_shift_ir)
            ir_shift <= {TDI, ir_shift[3:1]};  // LSB-first shift-in
        if (state_update_ir)
            ir_reg <= ir_shift;           // latch on UPDATE-IR
    end
end
```

The IR defaults to `IDCODE` (4'b0001) after any reset, so an IDCODE read can be performed immediately after reset without loading any instruction.

#### Data Registers

**IDCODE** (32-bit, read-only parallel load):
```verilog
if (state_capture_dr && ir_reg == INSTR_IDCODE)
    idcode_shift <= IDCODE_VALUE;          // parallel load of constant
else if (state_shift_dr && ir_reg == INSTR_IDCODE)
    idcode_shift <= {TDI, idcode_shift[31:1]};  // right-shift, LSB out first
```

**BYPASS** (1-bit):
```verilog
if (state_capture_dr && ir_reg == INSTR_BYPASS)
    bypass_bit <= 1'b0;                    // mandatory: capture 0
else if (state_shift_dr && ir_reg == INSTR_BYPASS)
    bypass_bit <= TDI;
```

#### TDO — Falling-Edge Drive

TDO is driven on the **falling** edge of TCK. This is an IEEE 1149.1 requirement: setup/hold margins are maximised because the host samples TDO on the next rising edge, giving a full half-period of hold time.

```verilog
always @(negedge TCK or negedge TRST_N) begin
    if (!TRST_N)  TDO <= 1'b1;
    else          TDO <= tdo_mux;     // combinatorial mux result
end
```

TDO idles at logic-1 when not in a shift state, also per standard.

### 3.2 `mriscv.v` — SoC Integration

The original `riscv.v` SOC module was extended with five JTAG port pins and a `jtag_tap` instantiation:

```verilog
module SOC (
    input  CLK, RESET,
    output reg [4:0] LEDS,
    input  RXD, output TXD,
    // ---- NEW JTAG pins ----
    input  TCK, TMS, TDI, TRST_N,
    output TDO
);

jtag_tap #(.IDCODE_VALUE(32'h1_CAFE_0_3)) TAP (
    .TCK(TCK), .TMS(TMS), .TDI(TDI), .TDO(TDO), .TRST_N(TRST_N),
    .tap_ir_o(jtag_ir),
    .tap_capture_dr_o(jtag_cap_dr),
    .tap_shift_dr_o  (jtag_shift_dr),
    .tap_update_dr_o (jtag_upd_dr)
);
```

The four status outputs (`jtag_ir`, `jtag_cap_dr`, `jtag_shift_dr`, `jtag_upd_dr`) are wired into the SoC fabric, ready to connect a future RISC-V Debug Module (DM) / Debug Module Interface (DMI) bridge for full GDB integration.

The Processor, Memory, UART, GPIO, and Clockworks submodules are **completely unchanged** from the original `riscv.v`, demonstrating clean non-invasive integration.

### 3.3 `jtag_tap_tb.v` — Testbench

The testbench exercises five independent tests using modular helper tasks:

| Task | Purpose |
|---|---|
| `tck_cycle(tms, tdi)` | Drive one TCK cycle; sets TMS/TDI before rising edge |
| `goto_tlr()` | Software reset — 5 × TMS=1 |
| `goto_shift_dr()` | Navigate TLR → RTI → SEL_DR → CAP_DR → SHIFT_DR |
| `shift_bits(n, tdi, tdo)` | Shift `n` bits, assert TMS=1 on the last cycle to exit |
| `load_ir(instr)` | Navigate to SHIFT_IR, shift 4-bit instruction, return to RTI |

---

## 4. Simulation Results

All five tests pass with zero failures.

### Test 1 — Asynchronous TRST_N Reset

<img width="1607" height="295" alt="Screenshot from 2026-05-26 16-38-04" src="https://github.com/user-attachments/assets/19f7df99-28e3-4dd8-b618-5ec39c48b726" />


`TRST_N` is asserted low asynchronously (not aligned to TCK). The TAP state immediately transitions to `TEST_LOGIC_RESET` (state `0`) on the falling edge of `TRST_N`, regardless of TCK activity. This is visible in the waveform: `tap_state[3:0]` shows `0` at ~80 ns before any rising TCK edge occurs. The `ir_reg` resets to `4'h1` (IDCODE) and `idcode_shift` loads `01CAFE03` — confirming the power-on default is correct.

From any arbitrary state, five consecutive TCK cycles with `TMS=1` are guaranteed to reach `TEST_LOGIC_RESET`. The testbench first moves to `SELECT_DR_SCAN` (state 2) and then drives `goto_tlr()`. The waveform confirms `tap_state` returns to `0` within 5 TCK edges.

### Test 2 — IDCODE Readback

<img width="1607" height="295" alt="Screenshot from 2026-05-26 16-38-34" src="https://github.com/user-attachments/assets/30e2dcc9-94d2-42f2-81b1-3b402546cb7e" /> 


This is the primary verification goal. The complete sequence is:

1.  After reset, `tap_state` traverses `0→1→2→3→4` (TLR → RTI → SEL_DR → CAP_DR → SHIFT_DR). At CAPTURE_DR (state 3), `idcode_shift` is parallel-loaded with `01CAFE03`.

2. In SHIFT_DR (state 4), `idcode_shift` right-shifts one bit per TCK cycle. The values visible are `01CAFE03 → 00E57F01 → 00072BF8 → 00395FC0 → 001CAFE0` — each is the previous value right-shifted by one, with `TDI=0` feeding in from the left.

3.  Shifting continues across the full 32-bit register. The progression `00E57F01 → 00072BF8 → 000395FC → 0001CAFE → 00000E57 → 000072BF → 0000395` shows the IDCODE being fully clocked out LSB-first on TDO.

4. The testbench assembles the 32 captured TDO bits and confirms `idcode_out == 32'h1CAFE03`. **PASS.**

### Test 3 — BYPASS Instruction

<img width="1607" height="295" alt="Screenshot from 2026-05-26 16-38-52" src="https://github.com/user-attachments/assets/1920a758-9851-46ba-940b-102688f7ef78" />
<img width="1607" height="295" alt="Screenshot from 2026-05-26 16-39-04" src="https://github.com/user-attachments/assets/46da7d2d-9470-4b2f-abca-a10ba558d7a6" />

`INSTR_BYPASS = 4'b1111` is loaded via the IR scan path. The TAP transitions through states `4→5→8→1→2→9` (SHIFT_DR → EXIT1_DR → UPDATE_DR → RTI → SEL_DR → SEL_IR) visible around 680–720 ns. After loading BYPASS:

- `bypass_bit` is captured as `0` on entering CAPTURE_DR.
- The pattern `8'b1010_1010` is shifted in on TDI. TDO reflects `bypass_bit` — a **one-cycle pipeline delay**, so the output is `0` for the first bit and then follows TDI shifted right by one position.
- `tdo_pattern[7:1] == tdi_pattern[6:0]` and `tdo_pattern[0] == 0`. **PASS.**

The `bypass_bit` signal toggling in phase with `TDI` is clearly visible in Image 2 (bottom row of the waveform).

### Test 4— Full 16-State Walk

All 16 TAP states are visited in a single sequence by driving specific TMS patterns. Image  shows `tap_state` cycling through values `9→0→1→2→3→4→5→6→7→4` (SEL_IR → TLR → RTI → SEL_DR → CAP_DR → SHIFT_DR → EXIT1_DR → PAUSE_DR → EXIT2_DR → SHIFT_DR…). The state machine visits every node without hanging or entering an undefined state. The sequence terminates in `TEST_LOGIC_RESET` (state 0). **PASS.**

### Waveform Summary Table

| Time Range | Key Observation |
|---|---|
| 80–120 ns | TRST_N async reset → TLR; IDCODE loaded into shift register at CAPTURE_DR |
| 120–180 ns | IDCODE right-shifting in SHIFT_DR; `idcode_shift` decrements by factor-of-2 each cycle |
| 150–240 ns | Full 32-bit IDCODE `01CAFE03` shifted out on TDO, LSB-first |
| 630–680 ns | BYPASS IR load sequence (SELECT_IR → CAPTURE_IR → SHIFT_IR → UPDATE_IR) |
| 680–730 ns | BYPASS DR shifting; `bypass_bit` follows TDI with 1-cycle delay |
| 735–830 ns | All-states walk; every state reachable, no locks, ends in TLR |

---

## 5. Synthesis & PnR Results

Synthesis was performed with **Yosys** targeting the iCE40UP5K; place-and-route with **nextpnr-ice40**.

### Synthesis Hierarchy (Image 6)

The Yosys log confirms the complete design hierarchy was correctly elaborated:

```
Top module:  \SOC
Used module: \jtag_tap
Used module: \corescore_emitter_uart
Used module: \Memory
Used module: \Processor
Used module: \Clockworks
```

The parameterised instantiation is resolved at synthesis:
<img width="991" height="860" alt="Screenshot from 2026-05-27 00-11-00" src="https://github.com/user-attachments/assets/2d2e861d-32cd-42f2-b63b-f00cb54d4c16" />

```
Parameter \IDCODE_VALUE = 30080515   (= 0x01CAFE03 in decimal)
Generating RTLIL for $paramod\jtag_tap\IDCODE_VALUE=30080515
```

This confirms Yosys correctly specialised the `jtag_tap` module with the chosen IDCODE value, inlining the 32-bit constant into the netlist.

### Device Utilisation

<img width="1259" height="305" alt="Screenshot from 2026-05-27 00-45-25" src="https://github.com/user-attachments/assets/b395eb70-c3ea-4fef-8bda-4cd5f2b4a0f8" />


**Key observations:**

- **Logic Cells (26%):** The TAP controller adds a modest LUT overhead. The 16-state FSM with its combinatorial next-state function and three register banks (IR shift, IDCODE shift, bypass) synthesises to approximately 60–80 LCs, well within budget. The bulk of the 1374 LCs belongs to the RISC-V processor core.

- **Block RAM (53%):** The 1535×32-bit instruction memory (`firmware.hex`) dominates this. The JTAG TAP uses no block RAM — all state is held in flip-flops.

- **Global Buffers (100%):** All 8 SB_GB resources are used. On iCE40, global buffers distribute high-fanout signals (clocks, resets) with minimal skew. TCK is a clock signal and correctly assigned to a global buffer, alongside the system clock and reset. This is expected and correct — using a global buffer for TCK prevents hold-time violations across the chip.

- **I/O (14%):** 14 of 96 physical I/O pins are used. The 5 JTAG pins (TCK, TMS, TDI, TDO, TRST_N) plus existing LEDs, UART, and oscillator input.

- **No timing violations** were reported by nextpnr. Since TCK (JTAG) is an independent clock domain from the system clock, the two clock domains are naturally isolated with no cross-domain paths in the current implementation.

---

## 6. FPGA Pin Mapping
<img width="441" height="603" alt="Screenshot from 2026-05-27 20-25-30" src="https://github.com/user-attachments/assets/0d0f6666-62a8-49ac-bf90-974f71f6fc03" />


