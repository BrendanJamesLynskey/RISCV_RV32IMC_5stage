"""
test_brv32p_soc.py — CocoTB Testbench for BRV32P Pipelined RISC-V SoC
======================================================================
Tests pipeline execution, forwarding, cache behaviour, branch prediction,
and all functional instruction categories.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


DATA_WORD = 0x4000 // 4   # firmware data area (0x0000_4000) as an SRAM word index
END_PC_X20 = 0xA4         # AUIPC x20 at 0xA4 runs only once the whole program has run


async def reset_dut(dut, cycles=10):
    # All tests share one simulation and the SRAM is not reset, so clear the
    # data words; otherwise a broken store could pass on a previous test's data.
    for i in range(2):
        dut.u_sram.mem[DATA_WORD + i].value = 0
    dut.rst_n.value = 0
    dut.gpio_in.value = 0
    dut.uart_rx.value = 1
    await ClockCycles(dut.clk, cycles)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def get_reg(dut, idx):
    if idx == 0:
        return 0
    return int(dut.u_core.u_regfile.regs[idx].value)


async def wait_reg(dut, idx, val, timeout=50000):
    """Wait until register idx == val, with timeout."""
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        try:
            if get_reg(dut, idx) == val:
                return True
        except ValueError:   # X or Z before the register is first written
            pass
    dut._log.warning(f"Timeout waiting for x{idx} = 0x{val:08X}")
    return False


async def wait_reg_nonzero(dut, idx, timeout=50000):
    """Wait until register idx != 0."""
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        try:
            if get_reg(dut, idx) != 0:
                return True
        except ValueError:   # X or Z before the register is first written
            pass
    return False


# ── Tests ────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_01_reset(dut):
    """Verify PC starts at reset vector."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    dut.rst_n.value = 0
    dut.gpio_in.value = 0
    dut.uart_rx.value = 1
    await ClockCycles(dut.clk, 10)
    pc = int(dut.u_core.pc_if.value)
    assert pc == 0, f"Reset PC = 0x{pc:08X}"
    dut._log.info("PASS: Reset PC = 0x00000000")


@cocotb.test()
async def test_02_alu_pipeline(dut):
    """Test ALU instructions execute correctly through pipeline with forwarding."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # Wait for the last of the checked results (SRLI x9) to reach the register file
    ok = await wait_reg(dut, 9, 40)
    assert ok, "x9 never reached 40"

    checks = [
        (1, 42, "ADDI"), (2, 10, "ADDI"), (3, 52, "ADD"),
        (4, 32, "SUB"),  (5, 52, "ANDI"), (6, 0x55, "ORI"),
        (7, 0xAA, "XORI"), (8, 160, "SLLI"), (9, 40, "SRLI"),
    ]
    for reg, exp, name in checks:
        val = get_reg(dut, reg)
        assert val == exp, f"{name} x{reg}: got {val}, expected {exp}"
        dut._log.info(f"PASS: {name} x{reg} = {val}")


@cocotb.test()
async def test_03_forwarding(dut):
    """Verify data forwarding: ADD x3=x1+x2 uses freshly-written x1, x2."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    ok = await wait_reg(dut, 3, 52)
    assert ok, "Forwarding failed: x3 != 52"
    dut._log.info("PASS: EX-EX forwarding verified (x3=x1+x2=52)")


@cocotb.test()
async def test_04_load_store_cache(dut):
    """Test load/store through the D-cache."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    ok = await wait_reg(dut, 11, 52)
    assert ok, "LW through D-cache failed"
    dut._log.info(f"PASS: LW x11 = {get_reg(dut, 11)}")

    ok = await wait_reg(dut, 12, 0x55)
    assert ok, "LBU through D-cache failed"
    dut._log.info(f"PASS: LBU x12 = 0x{get_reg(dut, 12):02X}")


@cocotb.test()
async def test_05_branches(dut):
    """Test BEQ/BNE through pipeline with prediction."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    ok = await wait_reg(dut, 15, 2)
    assert ok, "Branch test failed"
    dut._log.info(f"PASS: Branches — x15 = {get_reg(dut, 15)}")


@cocotb.test()
async def test_06_jal(dut):
    """Test JAL saves link and reaches target."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    ok = await wait_reg(dut, 17, 3)
    assert ok, "JAL target not reached"
    assert get_reg(dut, 16) == 0x6C, f"JAL link x16 = 0x{get_reg(dut, 16):08X}, expected 0x6C"
    dut._log.info(f"PASS: JAL — x17={get_reg(dut, 17)}, x16=0x{get_reg(dut, 16):08X}")


@cocotb.test()
async def test_07_loop_bp_training(dut):
    """Test BNE countdown loop trains the branch predictor."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # x23 resets to 0, so wait for the program's end (after the loop) instead
    ok = await wait_reg(dut, 20, END_PC_X20, timeout=100000)
    assert ok, "Program did not reach AUIPC at 0xA4 (AUIPC result wrong, or earlier hang)"
    assert get_reg(dut, 23) == 0, f"Loop counter x23 = {get_reg(dut, 23)}"
    dut._log.info("PASS: Countdown loop x23 = 0 at program end")

    # Check BHT was trained
    bht = dut.u_core.u_bp.bht
    trained = sum(1 for i in range(len(bht)) if int(bht[i].value) != 1)  # reset value 2'b01
    assert trained > 0, "No BHT entries trained"
    dut._log.info(f"PASS: BHT has {trained} trained entries")


@cocotb.test()
async def test_08_icache(dut):
    """Verify I-cache fills lines during execution."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    await wait_reg(dut, 3, 52)  # Wait for some execution

    # Icarus exposes valid_mem[SETS][WAYS] as one flat array of SETS*WAYS bits
    valid_mem = dut.u_icache.valid_mem
    valid_count = sum(int(valid_mem[i].value) for i in range(len(valid_mem)))

    assert valid_count > 0, "I-cache has no valid lines"
    dut._log.info(f"PASS: I-cache has {valid_count} valid lines")


@cocotb.test()
async def test_09_gpio_input(dut):
    """Test GPIO input synchronisation."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    await ClockCycles(dut.clk, 20)

    dut.gpio_in.value = 0xCAFEBABE
    await ClockCycles(dut.clk, 5)

    synced = int(dut.u_gpio.gpio_in_sync.value)
    assert synced == 0xCAFEBABE, f"Got 0x{synced:08X}"
    dut._log.info(f"PASS: GPIO input sync = 0x{synced:08X}")


@cocotb.test()
async def test_10_csr_mcycle(dut):
    """Test mcycle counter increments."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    await ClockCycles(dut.clk, 100)

    mcycle = int(dut.u_core.u_csr.mcycle.value) & 0xFFFFFFFF
    assert mcycle > 0, f"mcycle = {mcycle}"
    dut._log.info(f"PASS: mcycle = {mcycle}")


@cocotb.test()
async def test_11_load_use_stall(dut):
    """Load-use: ADDI x25, x24, 1 straight after LW x24 must see the loaded 52."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # Firmware at 0xAC/0xB0: LW x24, 0(x10); ADDI x25, x24, 1.
    # Without the load-use stall, x25 would be computed from a stale x24.
    ok = await wait_reg(dut, 25, 53, timeout=100000)
    assert ok, f"Load-use failed: x25 = {get_reg(dut, 25)}, expected 53"
    dut._log.info("PASS: Load-use stall correctly handled")


@cocotb.test()
async def test_12_pipeline_throughput(dut):
    """Measure approximate IPC by counting retired instructions vs cycles."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    ok = await wait_reg(dut, 20, END_PC_X20, timeout=100000)
    assert ok, "Program did not reach its end"

    mcycle = int(dut.u_core.u_csr.mcycle.value) & 0xFFFFFFFF
    minstret = int(dut.u_core.u_csr.minstret.value) & 0xFFFFFFFF

    # A sanity bound only: minstret is known to be inaccurate (it counts only
    # some instruction types, and counts again on stalled cycles; see README)
    assert 0 < minstret <= mcycle, f"minstret={minstret}, mcycle={mcycle}"
    dut._log.info(f"PASS: {minstret} counted instructions / {mcycle} cycles = {minstret / mcycle:.3f}")


@cocotb.test()
async def test_13_precise_ecall(dut):
    """ECALL traps with mcause = 11, and the instruction after it does not run."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    for _ in range(100000):
        await RisingEdge(dut.clk)
        if int(dut.u_core.u_csr.mcause.value) == 11:
            break
    else:
        assert False, "ECALL never trapped"
    await ClockCycles(dut.clk, 20)
    assert get_reg(dut, 26) != 0x77, "Imprecise trap: ADDI x26 after ECALL executed"
    dut._log.info("PASS: ECALL trapped precisely (mcause = 11, x26 untouched)")


@cocotb.test()
async def test_14_gpio_output(dut):
    """The firmware sets GPIO DIR = 0xFF and OUT = 52, so gpio_out = 52."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    ok = await wait_reg(dut, 20, END_PC_X20, timeout=100000)
    assert ok, "Program did not reach its end"
    assert int(dut.gpio_out.value) == 52, f"gpio_out = {int(dut.gpio_out.value)}"
    dut._log.info("PASS: GPIO output = 52")
