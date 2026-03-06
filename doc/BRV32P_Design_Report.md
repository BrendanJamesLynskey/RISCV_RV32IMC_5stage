# BRV32P Design Report

**5-Stage Pipelined RV32IMC RISC-V SoC**

---

## 1. Overview

BRV32P is a synthesisable, in-order, 5-stage pipelined RISC-V microcontroller targeting FPGA and ASIC flows. It implements the RV32IMC ISA (Base Integer + Multiply/Divide + Compressed) and is written in Verilog-2001 for broad toolchain compatibility, including Icarus Verilog and Verilator.

The SoC integrates the processor core with 2-way set-associative instruction and data caches, an AXI4-Lite bus fabric, 32 KB SRAM, and a small peripheral set (GPIO, UART, Timer).

---

## 2. Instruction Set

| Extension | Instructions |
|---|---|
| RV32I | Integer ALU, loads/stores, branches, jumps, `FENCE`, `ECALL`, `EBREAK` |
| RV32M | `MUL`, `MULH`, `MULHU`, `MULHSU`, `DIV`, `DIVU`, `REM`, `REMU` |
| RV32C | All standard 16-bit compressed encodings, expanded to 32-bit in ID |

Machine-mode CSRs implemented: `mstatus`, `mie`, `mip`, `mepc`, `mcause`, `mtvec`, `mcycle`, `minstret`.

---

## 3. Pipeline Micro-architecture

### 3.1 Stage Overview

```
 ┌──────────────────────────────────────────────────────────────┐
 │  IF        ID        EX        MEM       WB                  │
 │                                                              │
 │  PC+4     Decode    ALU       Cache     Regfile write        │
 │  BTB hit  RegRead   Mul/Div   SRAM      CSR update           │
 │  I-cache  CSR dec   Branch    Periph                         │
 │           Haz det   Fwd mux                                  │
 └──────────────────────────────────────────────────────────────┘
```

### 3.2 Instruction Fetch (IF)

- The PC register is updated each cycle. Normal flow: PC ← PC + 4 (or PC + 2 for a compressed instruction).
- The BTB is checked in parallel with the I-cache lookup. On a BTB hit and a predicted-taken condition, the next PC is taken from the BTB target field.
- I-cache miss: pipeline stalls for the AXI4-Lite fetch latency; the IF/ID register is held.

### 3.3 Instruction Decode (ID)

- 16-bit compressed instructions are detected by checking bits [1:0]. The `compressed_decoder` module expands them to their 32-bit equivalents before the main `decoder`.
- The main decoder produces a full set of control signals: ALU operation, source operand selects, memory width, write-back enable, and CSR operation.
- The hazard unit checks for RAW hazards against in-flight instructions and generates stall and flush signals.
- The register file is read at the end of ID (write-then-read in the same cycle via internal bypassing).

### 3.4 Execute (EX)

- Two forwarding muxes sit at the ALU inputs. They select between the register file output, the EX/MEM pipeline register (forward from immediately preceding instruction), and the MEM/WB pipeline register (forward from two instructions back).
- For load-use hazards, a one-cycle bubble is inserted by the hazard unit; the forwarding mux then selects the loaded value from MEM/WB.
- The M-extension `muldiv` unit is iterative. The pipeline stalls (holding the EX/MEM register) until the result is valid.
- Branch conditions are evaluated in EX. Mispredictions cause a 2-cycle flush of the IF and ID stages.

**Branch predictor detail:** The BHT holds 64 entries indexed by PC[7:2]. Each entry is a 2-bit saturating counter (00=strongly not-taken … 11=strongly taken). The BTB holds 32 entries holding {valid, tag, target}. Both structures are updated at the end of the EX stage.

### 3.5 Memory (MEM)

- D-cache access (load or store) happens in this stage.
- **Policy:** write-through, no-write-allocate. Stores write to both the cache and the backing SRAM via AXI.
- Peripheral accesses are routed through the AXI peripheral bridge; they stall the pipeline until the AXI handshake completes.

### 3.6 Write-Back (WB)

- The selected result (ALU, load data, or CSR read) is written to the register file.
- `mcycle` and `minstret` are incremented here, conditioned on `minstret` not being the target of a CSR write in the same cycle.

---

## 4. Hazard Unit

```
Signal          Source          Action
─────────────   ─────────────   ─────────────────────────────────────
fwd_a_sel       EX/MEM, MEM/WB  Mux select for ALU operand A
fwd_b_sel       EX/MEM, MEM/WB  Mux select for ALU operand B
stall_if        Load-use        Hold PC and IF/ID for 1 cycle
stall_id        Load-use        Hold ID/EX for 1 cycle; insert bubble
flush_if        Branch mispr.   Invalidate IF/ID register
flush_id        Branch mispr.   Invalidate ID/EX register
```

Forwarding priority: EX/MEM result takes priority over MEM/WB result (covers back-to-back ALU chains with no stall).

---

## 5. Cache Organisation

Both caches share the same organisation:

| Parameter | Value |
|---|---|
| Capacity | 2 KB |
| Associativity | 2-way set-associative |
| Line size | 32 bytes (8 words) |
| Sets | 32 |
| Replacement | LRU (1-bit pseudo-LRU per set) |
| Write policy (D-cache) | Write-through, no-write-allocate |

Cache tags include a valid bit. There is no dirty bit in the I-cache. The D-cache does not implement a dirty bit because it is write-through; every store updates SRAM.

**Coherence note:** There is no hardware coherence between I-cache and D-cache. Self-modifying code must explicitly flush the I-cache (write `1` to the I-cache flush CSR at address `0x7C0`).

---

## 6. AXI4-Lite Interconnect

The bus fabric is a 2-master, 2-slave crossbar.

```
            Master 0       Master 1
            (I-cache)      (D-cache / Periph)
                │               │
         ┌──────▼───────────────▼──────┐
         │     AXI4-Lite Interconnect  │
         │     (priority arbiter)      │
         └──────────────┬──────────────┘
                        │
              ┌─────────┴──────────┐
          Slave 0              Slave 1
          (SRAM)               (Periph bridge)
```

- Address decoding is combinatorial; slaves are selected based on the upper address bits (see memory map).
- The arbiter uses fixed priority: Master 1 (D-cache) has priority over Master 0 (I-cache) to avoid store-to-load forwarding stalls through the cache.
- Transactions are single-beat (no burst support). The `AWVALID`/`WVALID` handshakes are asserted together; `ARVALID` is asserted for a single cycle.

---

## 7. Peripheral Register Map

### GPIO (`0x1000_0000`)

| Offset | Register | Description |
|---|---|---|
| `0x00` | `GPIO_DATA` | Read: pin values. Write: output values |
| `0x04` | `GPIO_DIR` | Direction: 1 = output, 0 = input (per bit) |
| `0x08` | `GPIO_IE` | Interrupt enable (per bit) |
| `0x0C` | `GPIO_IF` | Interrupt flag (write 1 to clear) |

### UART (`0x1000_0100`)

| Offset | Register | Description |
|---|---|---|
| `0x00` | `UART_DATA` | TX write / RX read (byte) |
| `0x04` | `UART_STATUS` | Bit 0: TX ready. Bit 1: RX valid. Bit 2: RX overrun |
| `0x08` | `UART_BAUD` | Baud divisor (default set in `brv32p_defs.vh`) |

### Timer (`0x1000_0200`)

| Offset | Register | Description |
|---|---|---|
| `0x00` | `TIMER_CNT` | Current counter value (read-only) |
| `0x04` | `TIMER_CMP` | Compare value; interrupt fires when CNT == CMP |
| `0x08` | `TIMER_CTRL` | Bit 0: enable. Bit 1: interrupt enable. Bit 2: auto-reload |
| `0x0C` | `TIMER_IF` | Interrupt flag (write 1 to clear) |

---

## 8. CSR Reference

| Address | Name | Description |
|---|---|---|
| `0x300` | `mstatus` | Machine status (MIE, MPIE, MPP) |
| `0x304` | `mie` | Machine interrupt enable |
| `0x305` | `mtvec` | Trap vector base address |
| `0x341` | `mepc` | Exception program counter |
| `0x342` | `mcause` | Trap cause |
| `0x344` | `mip` | Machine interrupt pending (read-only) |
| `0xB00` | `mcycle` | Cycle counter (lower 32 bits) |
| `0xB02` | `minstret` | Retired instruction counter (lower 32 bits) |
| `0x7C0` | (custom) | I-cache flush (write any value) |

---

## 9. Verification

### Testbench (`tb/tb_brv32p_soc.v`)

The Verilog testbench loads `firmware.hex` into the SRAM model at time zero and drives `clk` and `rst_n`. It monitors a dedicated `sim_done` signal and a `sim_result` bus driven by the firmware to report pass/fail for each test case.

### CocoTB (`cocotb/test_brv32p_soc.py`)

The Python test suite uses CocoTB to drive the same SoC top-level. It covers:

- ALU operations (all RV32I arithmetic and logic instructions)
- Load/store (byte, halfword, word; signed and unsigned)
- Branch and jump instructions (taken and not-taken; BTB warm-up)
- M-extension multiply and divide (including edge cases: division by zero, overflow)
- Compressed instruction expansion
- CSR read/write and `mret`
- GPIO and UART loopback
- Timer interrupt delivery

### Known gaps

- No formal verification (property checking or bounded model checking)
- No RISC-V Compliance Suite integration yet
- Coverage model not implemented

---

## 10. Synthesis Notes

The design targets Verilog-2001 (`-g2005` in Icarus; `default_nettype none` recommended for synthesis). All `always` blocks use blocking assignments only in combinatorial logic and non-blocking assignments only in clocked logic. No latches are inferred.

The M-extension multiply/divide unit (`muldiv.v`) uses a shift-and-add/subtract algorithm and will not infer DSP blocks; replace with a vendor multiply primitive if targeting an FPGA for performance.

Estimated resource utilisation (rough, unmapped):

| Resource | Estimate |
|---|---|
| LUTs (FPGA) | ~8,000 – 12,000 |
| FFs | ~2,500 – 3,500 |
| BRAM | 1× 32 KB (SRAM), 2× 2 KB (caches) |

---

## 11. Revision History

| Version | Date | Notes |
|---|---|---|
| 0.1 | Initial | Core pipeline, no caches |
| 0.2 | | I-cache and D-cache added |
| 0.3 | | AXI interconnect, peripherals |
| 0.4 | | M-extension, BTB, CocoTB suite |
| 0.5 | Current | Full RV32IMC; 2-bit BHT; write-through D-cache |
