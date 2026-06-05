
# JTAG Debug Interface — VSDSquadron RISC-V Integration

> **Task 2 Deliverable** — JTAG-based halt, resume, status, and PC read debug interface added to the VSDSquadron RISC-V SoC.

---

## Table of Contents

1. [Introduction to JTAG Debug](#1-introduction-to-jtag-debug)
2. [How the Debug Interface Works](#2-how-the-debug-interface-works)
3. [Implementation Details](#3-implementation-details)
4. [Simulation Results](#4-simulation-results)
5. [Known Limitations](#5-known-limitations)
6. [File Structure](#6-file-structure)

---

## 1. Introduction to JTAG Debug

JTAG (Joint Test Action Group, IEEE 1149.1) is the industry-standard four-wire interface for chip testing and in-system programming. Task 1 added the foundational TAP controller with IDCODE and BYPASS instructions. **Task 2 extends it into a functional debug interface**, allowing an external host to:

- **Halt** the RISC-V core mid-execution
- **Resume** execution from the frozen state
- **Read the program counter** of the halted core
- **Read the halted/running status** of the core

This is the first step toward full GDB-level debugging via OpenOCD. The same four JTAG pins (TCK, TMS, TDI, TDO) are used — no new wires are required on the board.

### What Problem Does This Solve?

Without a debug interface, the only way to observe a running RISC-V core is through its outputs (LEDs, UART). With this interface, a developer can stop the core at any point in time, inspect the PC to determine exactly which instruction was executing, and then resume — all non-intrusively over JTAG, without modifying the firmware.

### Debug Signal Overview

| Signal | Direction | Description |
|---|---|---|
| `debug_halt_req` | TAP → Core | Instructs the processor to freeze |
| `debug_resume_req` | TAP → Core | Instructs the processor to continue |
| `debug_reset_req` | TAP → Core | Resets PC to 0 and clears halted state |
| `debug_halted` | Core → TAP | Reflects whether the processor is currently frozen |
| `debug_pc[31:0]` | Core → TAP | Exposes the live (or frozen) program counter |

---

## 2. How the Debug Interface Works

### New JTAG Instructions

Three new data registers are added alongside the existing IDCODE and BYPASS registers. The instruction register remains 4 bits wide.

| IR value | Mnemonic | DR width | Description |
|----------|----------|----------|-------------|
| `0001` | IDCODE | 32 | Read device ID (unchanged from Task 1) |
| `0010` | DEBUG_CTRL | 3 | Write halt / resume / reset commands to the core |
| `0011` | DEBUG_STATUS | 1 | Read halted status (0 = running, 1 = halted) |
| `0100` | DEBUG_PC | 32 | Read current program counter |
| `1111` | BYPASS | 1 | Standard JTAG bypass (unchanged from Task 1) |

### DEBUG_CTRL Bit Encoding

The 3-bit control register maps directly to the three debug request signals:

| Bit | Signal | Effect when 1 |
|-----|--------|---------------|
| [2] | `debug_halt_req` | Freezes the core |
| [1] | `debug_resume_req` | Resumes the core |
| [0] | `debug_reset_req` | Resets PC to 0 and clears halted |

Example values: `3'b100` = HALT, `3'b010` = RESUME, `3'b001` = RESET.

### The Halt/Resume Handshake

Because the JTAG clock (TCK) is completely independent of the processor system clock, a hold-counter bridges the two clock domains. When the host shifts a command and UPDATE_DR fires, the relevant request signal is asserted and held high for 12 TCK cycles — long enough for the system clock domain to reliably sample it. Once sampled, the processor latches `halted = 1` internally and the request line is released.

```
JTAG domain                         Core clock domain
───────────                         ─────────────────
UPDATE_DR fires
dbg_ctrl_active = 3'b100
hold counter = 12          ──────►  debug_halt_req sampled
debug_halt_req held high            halted ← 1
  for 12 TCK cycles                 state machine frozen
debug_halt_req returns low          PC stops changing (halted stays 1)
```

### PC Read Sequence

Reading the 32-bit program counter follows the standard JTAG DR scan path. The DEBUG_PC instruction is loaded into the IR, then a DR scan is performed: the current `debug_pc` value is parallel-loaded into the shift register at CAPTURE_DR, then clocked out LSB-first on TDO over 32 SHIFT_DR cycles. When the core is halted, repeating this read returns the same value every time — confirming the core is genuinely frozen.

---

## 3. Implementation Details

### File Structure

```
.
├── soc.v               # Top-level SOC: Processor + Memory + UART + JTAG
├── jtag_tap.v          # TAP controller with debug instructions (extended)
├── clockworks.v        # Clock/reset management (FPGA only, unchanged)
├── emitter_uart.v      # UART transmitter (unchanged)
├── firmware.hex        # Program loaded into RAM at startup
└── tb_jtag_debug.v     # Self-checking simulation testbench
```

### 3.1 `jtag_tap.v` — Extended TAP Controller

The TAP module interface gains five new ports compared to Task 1 — three outbound request signals driven toward the processor, and two inbound status signals read back from it. The existing 16-state FSM, IR path, IDCODE register, BYPASS register, and falling-edge TDO drive are all unchanged.

**DEBUG_CTRL register** — a 3-bit shift register captures the host command on SHIFT_DR. On UPDATE_DR the value is latched into an active register and a 4-bit hold counter is loaded to 12. Each of the three request outputs is driven high either on the UPDATE_DR pulse itself or for as long as the hold counter is non-zero, whichever is longer. This ensures the system clock domain has ample time to see the request regardless of the TCK-to-system-clock frequency ratio.

**DEBUG_STATUS register** — a 1-bit register that captures `debug_halted` on CAPTURE_DR and holds it for the subsequent SHIFT_DR cycle. The TDO mux routes this bit when the STATUS instruction is active.

**DEBUG_PC register** — a 32-bit shift register loaded from `debug_pc` at CAPTURE_DR. During SHIFT_DR it right-shifts one bit per TCK cycle, presenting the LSB on TDO each cycle. The host assembles the 32 captured TDO bits to recover the program counter.

**TDO multiplexer** — all five register outputs are combined into a single combinatorial mux. The result is registered on the falling edge of TCK, as required by IEEE 1149.1, to maximise setup and hold margins at the host receiver.

### 3.2 `soc.v` — Processor Halt/Resume Logic

A single `halted` register is added to the processor. The entire state machine body — PC update, register file writeback, and memory interface — is gated behind `if(!halted)`. This means the core freezes atomically: no partial instruction execution, no memory side-effects, no register writes occur while halted.

Priority on the same clock edge is: reset first, then resume, then halt. When `debug_halt_req` arrives, `halted` latches to 1 and stays there until `debug_resume_req` or `debug_reset_req` is seen. While halted, `mem_addr` is switched to output the frozen PC directly, allowing an external debugger to read instruction memory at the stalled address without disturbing any other state.

### 3.3 `tb_jtag_debug.v` — Self-Checking Testbench

The testbench is built from a small library of reusable helper tasks:

| Task | Purpose |
|---|---|
| `jtag_cycle(tms, tdi, tdo)` | Drive one TCK cycle; capture TDO on the falling edge |
| `jtag_reset_tap()` | Software reset — 5 × TMS=1 followed by TMS=0 |
| `jtag_set_ir(instr)` | Navigate to SHIFT_IR, shift 4-bit instruction, return to RTI |
| `jtag_write_ctrl(ctrl)` | Load DEBUG_CTRL, shift 3-bit command, UPDATE_DR |
| `jtag_read_dr1(instr)` | Load instruction, capture and shift 1-bit DR, return value |
| `jtag_read_dr32(instr)` | Load instruction, capture and shift 32-bit DR, return value |
| `wait_for_halted(n)` | Poll `debug_halted` for up to n core cycles; fail on timeout |
| `wait_for_running(n)` | Poll `debug_halted == 0` for up to n core cycles; fail on timeout |

---

## 4. Simulation Results

The testbench performs eleven sequential checks. All pass; the final output is `PASS`.

### Test Sequence and Waveform Walkthrough

**Steps 1–2 — Core starts running, PC advances**

After TRST_N is released and 50 core cycles elapse, `debug_pc` is sampled twice 50 cycles apart. The two values differ, confirming the core is fetching and executing instructions.

**Step 3 — JTAG sends HALT**

The TAP navigates to SHIFT_DR with `ir_reg = DEBUG_CTRL`. Three bits are shifted in LSB-first to place `3'b100` into the shift register. On UPDATE_DR, `debug_halt_req` goes high and the hold counter is loaded to 12.

**Steps 4–5 — Core enters halted state, PC freezes**

Within 200 core clock cycles of the halt request, `debug_halted` goes high and `debug_pc` stops changing. The testbench captures `expected_pc` at the moment `debug_halted` is seen, waits 20 more cycles, and confirms `debug_pc` still equals `expected_pc`.

**Step 6 — JTAG reads STATUS = 1**

The DEBUG_STATUS instruction is loaded. One DR scan cycle captures `debug_halted = 1` and shifts it out on TDO. The assertion `status_bit == 1` passes.

**Step 7 — JTAG reads frozen PC**

The DEBUG_PC instruction is loaded. One 32-bit DR scan captures the frozen `debug_pc` and shifts it out LSB-first. The assembled value is compared against `expected_pc`. Values match.

**Step 8 — JTAG sends RESUME**

`jtag_write_ctrl(3'b010)` asserts `debug_resume_req`. The processor samples it on the next system clock edge and clears `halted`.

**Steps 9–10 — Core restarts, PC advances again**

`wait_for_running(200)` confirms `debug_halted` goes low. Two PC samples 50 cycles apart are taken; they differ, proving the state machine is executing instructions again.

**Step 11 — PASS printed**

### Waveform Signal Reference

| Signal path | Description |
|---|---|
| `tb_jtag_debug.TCK` | JTAG clock |
| `tb_jtag_debug.TMS` | JTAG mode select |
| `tb_jtag_debug.TDI` | Data into TAP |
| `tb_jtag_debug.TDO` | Data out of TAP (driven on falling TCK) |
| `tb_jtag_debug.debug_halt_req` | Halt request pulse from TAP |
| `tb_jtag_debug.debug_resume_req` | Resume request pulse from TAP |
| `tb_jtag_debug.debug_halted` | Core frozen indicator |
| `tb_jtag_debug.debug_pc` | Program counter (frozen when halted) |
| `tb_jtag_debug.dut.CPU.PC` | Internal PC register inside the processor |

The VCD dump is written to `jtag_debug.vcd` and captures the full design hierarchy, so all signals above are accessible in GTKWave without any additional instrumentation.

---

## 5.

---

## 6. File Structure

```
.
├── soc.v               # SOC top-level — Processor, Memory, UART, JTAG integration
├── jtag_tap.v          # TAP controller — full 16-state FSM + 5 instructions
├── clockworks.v        # Clock divider and reset synchroniser (FPGA, unchanged)
├── emitter_uart.v      # 9600-baud UART transmitter (unchanged)
├── firmware.hex        # Intel HEX program image (1536 × 32-bit words)
├── tb_jtag_debug.v     # Self-checking testbench — 11-step halt/resume/PC sequence
└── jtag_debug.vcd      # Simulation waveform output (GTKWave compatible)
```

### Running the Simulation

```bash
iverilog -D BENCH \
         -o sim.out \
         tb_jtag_debug.v soc.v jtag_tap.v clockworks.v emitter_uart.v

vvp sim.out
```

Expected final line:

```
PASS
```

View the waveform:

```bash
gtkwave jtag_debug.vcd
```
