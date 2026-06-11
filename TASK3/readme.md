# Task 3A — FPGA JTAG IDCODE Physical Test on VSDSquadron FM

JTAG TAP controller from Task 1 synthesised, placed-and-routed, and packed into a bitstream for the VSDSquadron FM . This task moves from simulation to real FPGA fabric and documents the complete build flow together with the physical validation plan for IDCODE readback over external JTAG pins.

---

## Table of Contents

1. [What This Task Proves](#1-what-this-task-proves)
2. [Design Overview](#2-design-overview)
3. [Pin Mapping](#3-pin-mapping)
4. [Synthesis](#4-synthesis)
5. [Place and Route](#5-place-and-route)
6. [Timing Analysis](#6-timing-analysis)
7. [Bitstream Generation](#7-bitstream-generation)
8. [Build Flow](#8-build-flow)
9. [Physical Validation Plan](#9-physical-validation-plan)
10. [File Structure](#10-file-structure)

---

## 1. What This Task Proves

Without physical JTAG validation, simulation results remain confined to a virtual environment. This task demonstrates that the TAP controller RTL is:

- **Synthesisable** — Yosys maps it cleanly to iCE40 primitives with zero errors
- **Placeable and routable** — nextpnr fits the design into the UP5K fabric with all six I/O pins constrained to the correct physical pads
- **Timing-safe** — the worst-case combinatorial path closes at 127.35 MHz, more than 10× the JTAG clock target of 12 MHz
- **Bitstream-ready** — `icepack` produces a 104 KB binary that `iceprog` can load in under two seconds

Physical IDCODE readback (`0x81262776`) over an external JTAG adapter is the final confirmation step. The connection plan, adapter options, and OpenOCD command sequence are fully documented below.

---

## 2. Design Overview

### `jtag_tap.v` — TAP Controller

| IR value | Mnemonic | DR width | Description |
|---|---|---|---|
| `0001` | IDCODE | 32 | Read-only device identity register |
| `0010` | DEBUG_CTRL | 3 | Halt / Resume / Reset command register |
| `0011` | DEBUG_STATUS | 1 | Reads `debug_halted` from the processor |
| `0100` | DEBUG_PC | 32 | Reads the frozen program counter |
| `1111` | BYPASS | 1 | Single-bit passthrough |

After asynchronous TRST_N reset, the IR defaults to `IDCODE`. The first DR scan without any IR write therefore returns `0x81262776` automatically — this is the behaviour the external adapter exploits.

TDO is registered on the **falling edge** of TCK , giving the host adapter the full TCK half-cycle to latch the bit.

### `top_jtag_idcode.v` — FPGA Top Module

A thin wrapper that instantiates `jtag_tap` with `IDCODE_VALUE = 32'h81262776` and ties all debug ports to safe constants. A single additional assignment drives `led = 1'b1` — a constant HIGH that lights the on-board LED the moment the bitstream is active, providing immediate visual confirmation that the FPGA has been programmed before any JTAG probe is connected.

```verilog
module top_jtag (
    input  wire tck,
    input  wire tms,
    input  wire tdi,
    input  wire trst,
    output wire tdo,
    output wire led        // constant HIGH — bitstream loaded indicator
);
    jtag_tap #(.IDCODE_VALUE(32'h81262776)) u_tap (
        .TCK(tck), .TMS(tms), .TDI(tdi), .TDO(tdo), .TRST_N(trst),
        .debug_halted(1'b0), .debug_pc(32'h0)
    );
    assign led = 1'b1;
endmodule
```

### IDCODE Register Structure

The 32-bit IDCODE follows the IEEE 1149.1 field layout:

```
 Bit 31..28   27..12    11..1     0
┌──────────┬──────────┬─────────┬───┐
│ Version  │  Part    │  Manuf  │ 1 │
│  0x8     │  0x1262  │  0x3BB  │ 1 │
└──────────┴──────────┴─────────┴───┘
   4 bits    16 bits    11 bits   1
```

Bit 0 is always `1` as mandated by the standard. The value is hardcoded in the `IDCODE_VALUE` parameter and parallel-loaded into the shift register at every CAPTURE_DR while IR = IDCODE, so the same value is returned on every consecutive scan.

---

## 3. Pin Mapping

### `VSDSquadronFM.pcf`

<img width="211" height="266" alt="Screenshot from 2026-06-12 00-17-32" src="https://github.com/user-attachments/assets/d149d1cd-6e10-4b78-bc57-da5a396c2170" />


All six signals are constrained to physical pads on the iCE40UP5K SG48 package. nextpnr confirmed each constraint was accepted without conflict.

| Signal | Pin | Direction | Header / Function |
|---|---|---|---|
| `tck` | 11 | IN | PMOD / GPIO — JTAG clock |
| `tms` | 12 | IN | PMOD / GPIO — mode select |
| `tdi` | 13 | IN | PMOD / GPIO — data in |
| `tdo` | 18 | OUT | PMOD / GPIO — data out |
| `trst` | 19 | IN | PMOD / GPIO — async TAP reset |
| `led` | 39 | OUT | On-board LED — bitstream loaded indicator |

> All JTAG signals operate at **3.3 V logic only**.

---

## 4. Synthesis

Synthesis was run with **Yosys 0.39** using the `synth_ice40` flow targeting the iCE40UP5K.

### Cell Statistics (`top_jtag`)

<img width="729" height="315" alt="synth_result" src="https://github.com/user-attachments/assets/ed150d21-a1bf-42db-b319-9a751a480851" />


The 42 `SB_DFFER` cells correspond to the synchronous-reset flip-flops in the IDCODE and DEBUG_PC shift registers. The 4-bit TAP state register and IR register map to `SB_DFFER` (async reset, enable). The 93 `SB_LUT4` cells cover the 16-state next-state function and the TDO multiplexer.

The CHECK pass ran twice — before and after technology mapping — and reported **0 problems** on both passes. No latches were inferred.

---

## 5. Place and Route

Place and route was run with **nextpnr-ice40 0.7** targeting the UP5K in the SG48 package.


### Pin Constraint Acceptance

nextpnr logged each constraint accepted without conflict:

```
INFO: Constraining tck  to: IOB_11 (pin 11)
INFO: Constraining tms  to: IOB_12 (pin 12)
INFO: Constraining tdi  to: IOB_13 (pin 13)
INFO: Constraining tdo  to: IOB_18 (pin 18)
INFO: Constraining trst to: IOB_19 (pin 19)
INFO: Constraining led  to: IOB_39 (pin 39)
```

### Device Utilisation

<img width="1194" height="311" alt="device_util" src="https://github.com/user-attachments/assets/9a68326f-eb41-4938-a9d6-4703c444456d" />


The TAP occupies only **1% of the logic cells**, leaving the remaining 99% free for the full SoC integration planned in subsequent tasks. Routing completed without congestion. SA placement converged in a single pass.



---

## 6. Timing Analysis

Timing was analysed with **icetime** against the iCE40UP5K model.

<img width="1238" height="799" alt="Screenshot from 2026-06-11 20-59-32" src="https://github.com/user-attachments/assets/21d83d50-9742-40d9-8797-c482ee27de01" />

### Critical Path

```
Start point:  SB_DFFER_Q   (tap_state register — clock-to-Q)
End point:    SB_DFFESR_D  (tap_state register — setup)
Path type:    Max (Setup)

Location          Delay type      Incr    Path
──────────────────────────────────────────────
SB_DFFER          clock-to-Q      0.49    0.49   tap_state Q
LUT chain         combinatorial   4.75    5.24   next-state logic
SB_DFFESR         setup           2.61    7.85   tap_state D
──────────────────────────────────────────────
Total path delay:  7.85 ns
Maximum frequency: 127.35 MHz
```
**Result: PASS**

---

## 7. Bitstream Generation

| File | Size | Description |
|---|---|---|
| `top_jtag_idcode.json` | 565 B | Yosys JSON netlist |
| `top_jtag_idcode.asc` | ~8 KB | nextpnr ASCII bitstream |
| `top_jtag_idcode.bin` | **104 KB** | Packed iCE40 binary for `iceprog` |

The binary begins with the standard iCE40 preamble `FF FF FF FF 7E AA 99 7E`, confirming it is a valid SPI flash image. Programming time with `iceprog` over USB is typically under 2 seconds.

output:
<img width="961" height="351" alt="bitstreamgeneration" src="https://github.com/user-attachments/assets/e493144b-d419-4621-bab4-b917f3856cd2" />
<img width="700" height="1600" alt="WhatsApp Image 2026-06-12 at 00 24 09" src="https://github.com/user-attachments/assets/72c85ed7-f160-4904-b315-63723a323529" />


## 8. Build Flow

A single `Makefile` drives the entire flow:

```bash
make          # synth → PnR → timing → pack
make prog     # additionally runs iceprog
make clean    # removes all build artefacts
```

Underlying commands in order:

```bash
# 1. Synthesis
yosys -p "synth_ice40 -top top_jtag -json top_jtag_idcode.json" \
      top_jtag_idcode.v jtag_tap.v

# 2. Place & Route
nextpnr-ice40 --up5k --package sg48 \
  --json top_jtag_idcode.json \
  --pcf VSDSquadronFM.pcf \
  --asc top_jtag_idcode.asc

# 3. Timing check
icetime -d up5k -mtr top_jtag_idcode.timing top_jtag_idcode.asc

# 4. Pack bitstream
icepack top_jtag_idcode.asc top_jtag_idcode.bin

# 5. Program FPGA
iceprog top_jtag_idcode.bin
```

---

## 9. Physical Validation Plan

### 9.1 JTAG Wiring

```
JTAG Adapter (3.3 V)          VSDSquadron FM
────────────────────           ──────────────────
     TCK  ──────────────────►  Pin 11  (tck)
     TMS  ──────────────────►  Pin 12  (tms)
     TDI  ──────────────────►  Pin 13  (tdi)
     TDO  ◄──────────────────  Pin 18  (tdo)
    TRST  ──────────────────►  Pin 19  (trst)
     GND  ══════════════════   GND
    VREF  ──────────────────   3.3 V rail
```

Check VREF reads 3.3 V and GND continuity is confirmed **before** connecting TCK/TMS/TDI/TDO. A floating VREF on many adapters will cause it to drive at the wrong voltage level.

### 9.2 OpenOCD IDCODE Read

```bash
openocd -f openocd_jtag_idcode.cfg
```

`openocd_jtag_idcode.cfg` declares the TAP with `irlen 4` and `expected-id 0x81262776`, then runs:

```tcl
irscan vsd_jtag.tap 0x01          ;# load IDCODE instruction
drscan vsd_jtag.tap 32 0x00000000 ;# capture and shift 32-bit DR
```

### 9.3 Expected Terminal Output

```
Open On-Chip Debugger 0.12.0
...
JTAG scan started

 TapName        Enabled  IdCode      Expected    IrLen
 vsd_jtag.tap      Y    0x81262776  0x81262776     4

TAP detected
IDCODE read = 0x81262776

TASK 3A PASSED — IDCODE matches expected 0x81262776
```

### 9.4Current Status

| Step | Status | Notes |
|---|---|---|
| JTAG TAP RTL |  Complete | Full IEEE 1149.1 FSM, simulation verified in Task 1 |
| FPGA top module |  Complete | `top_jtag_idcode.v` — TAP + LED indicator |
| Pin constraints |  Complete | All 6 signals mapped, nextpnr confirmed |
| Yosys synthesis |  Complete | 93 LUTs, 71 FFs, 0 errors, 0 latches |
| nextpnr PnR | Complete | 1% utilisation, all pins routed |
| Timing analysis | Complete | 127.35 MHz max — 10.6× margin at 12 MHz |
| Bitstream |  Complete | `top_jtag_idcode.bin` — 104 KB, ready for `iceprog` |
| JTAG adapter wiring |  Pending | FT232H breakout recommended (~$10) |
| IDCODE readback | Pending | OpenOCD config and expected output documented above |

Physical IDCODE readback is pending due to unavailability of a 3.3 V JTAG adapter at the time of submission. All digital deliverables — RTL, constraints, build logs, bitstream, and OpenOCD config — are complete and ready for immediate hardware validation once an adapter is available.

### 9.5 Troubleshooting Guide

| Symptom | Likely Cause | Fix |
|---|---|---|
| LED OFF after `iceprog` | Wrong device or erase failed | Re-run `iceprog`, verify USB connection |
| `cdone` stays LOW | Wrong package (`sg48` vs `uwg30`) | Confirm `--package sg48` in nextpnr |
| OpenOCD: `IR capture error` | TDO open or not driven | Check wiring, verify pin 18 continuity |
| IDCODE = `0xFFFFFFFF` | TDO stuck HIGH or adapter sees no device | Re-check GND and VREF first |
| IDCODE = `0x00000000` | TDO stuck LOW or open-drain without pull | Add 10 kΩ pull-up on TDO to 3.3 V |
| Wrong IDCODE | TRST not pulsed, IR = BYPASS | Toggle TRST LOW then HIGH before scan |

---

## 10. File Structure

```
Task-3A/
├── top_jtag_idcode.v        # FPGA top module — instantiates TAP, drives LED
├── jtag_tap.v               # TAP controller — 16-state FSM, 5 instructions
├── VSDSquadronFM.pcf        # Pin constraints — iCE40UP5K SG48
├── Makefile                 # Build flow: synth → PnR → timing → pack → prog
├── openocd_jtag_idcode.cfg  # OpenOCD script — FT232H/FT2232H IDCODE read
├── top_jtag_idcode.json     # Yosys JSON netlist
├── top_jtag_idcode.asc      # nextpnr ASCII bitstream
├── top_jtag_idcode.bin      # Packed iCE40 binary (104 KB) — ready for iceprog
├── top_jtag_idcode.timing   # icetime timing report
├── synth.log                # Yosys synthesis terminal log
├── pnr.log                  # nextpnr place-and-route terminal log
├── timing.log               # icetime timing analysis log
└── README.md                # This document
```
