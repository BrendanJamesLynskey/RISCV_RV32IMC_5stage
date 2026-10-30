# Pipeline trace

The ISA testbench can record, every cycle, what each of the five stages holds
and what the hazard unit decided: stalls, flushes, forwarding, cache misses,
mispredicts, traps. `scripts/pipeview.py` turns that record into instruction
lifetimes (which instruction was in which stage on which cycle, and whether it
retired, was squashed or trapped), draws them as pipeline diagrams, and exports
them as JSON for animation.

Every ISA test checks its own trace (below), so the diagrams here are the
pipeline's real behaviour, not a model of it.

## Recording a trace

`tests/isa/run_isa.sh` records one for every test it runs
(`tests/isa/build/<suite>-<test>.pipe`; `PIPE=0` turns it off). For a single
test by hand:

```sh
tests/isa/run_isa.sh rv32ui/lw                     # builds the test and its trace
cd tests/isa/build
vvp -n tb_isa.vvp +hex=$PWD/rv32ui-lw.hex +tohost=<addr> +pipe=$PWD/rv32ui-lw.pipe
```

The file has one line per cycle, sampled on the falling clock edge: the
registers then hold this cycle's contents and the combinational control has
settled. Fields, in groups separated by `|` (the first line of the file names
them):

| Group | Fields |
|---|---|
| IF | `pc_if`, `fetch_valid` (0 while the first half of a straddling instruction waits), `straddle`, `imem_stall`, predicted taken |
| ID | valid, pc, encoding |
| EX | valid, pc, encoding, `rs1`/`rs2`, forwarding select for each (0 register file, 1 from MEM, 2 from WB) |
| MEM | valid, pc, encoding, `rd`, data-memory read/write, `dmem_stall` |
| WB | valid (high once, the cycle the instruction retires), pc, encoding, register write enable, `rd`, data |
| Control | `stall_if/id/ex`, `flush_id/ex/mem`, `mem_stall`, load-use, divide busy, mispredict, trap, exception in MEM, interrupt taken, MRET, FENCE.I, trap cause, mul-use, csr-use (both added later, at the end, so older traces still parse) |

## Rebuilding instructions, and checking the rebuild

The trace has no instruction IDs. `pipeview.py` follows each instruction by
applying the pipeline registers' own rules to the recorded control signals:

| Register | Cleared (the instruction entering is squashed) | Loads | Otherwise |
|---|---|---|---|
| IF/ID | `flush_id` | `!stall_id && !mem_stall` (a bubble while a straddling instruction completes) | holds |
| ID/EX | `flush_ex && !mem_stall` (load-use bubble: ID holds; mispredict: ID is squashed) | `!stall_ex && !mem_stall` | holds |
| EX/MEM | `flush_mem` (a trap) | `!mem_stall`; a bubble while EX is stalled by a divide | holds |
| MEM/WB | — | `!mem_stall`; an instruction that traps in MEM does not go on | holds |

`pipeview.py check <x.pipe> <x.trace>` then compares the rebuild with the RTL
on every cycle: each stage's recorded pc and encoding must be the instruction
the rules put there, a bubble must be a bubble, and the instructions leaving
WB must be exactly the retire trace, which the Spike lockstep has already
compared with the reference model. A test fails if its trace does not check.

All 102 ISA and directed tests pass this check: 125,382 cycles, 37,874
retired, 5,790 squashed and 6 trapped instructions.

The check was itself tested by putting back two of the bugs fixed earlier (see
the README) in a scratch copy:

| Mutant | Caught by the pipe check |
|---|---|
| Load-use bubble fires during a memory stall | 6 tests (`ld_st`, `lhu`, `lb`, ... : "EX is a bubble, rebuilt as pc ...") |
| Divide copies leak from EX into MEM | `rv32um/div` ("MEM holds pc ..., rebuilt as a bubble") |

## Diagrams

```sh
scripts/pipeview.py diagram x.pipe --dis x.dis --from 100 --cycles 40
scripts/pipeview.py diagram x.pipe --dis x.dis --event load-use     # first load-use bubble
scripts/pipeview.py json    x.pipe --dis x.dis --event mispredict --cycles 30 -o scene.json
```

One row per instruction, one column per cycle. `F D X M W` are IF, ID, EX,
MEM and WB; lower case means the instruction is still in that stage (held);
`*` marks the cycle it is gone, squashed; `!` a trap. The `events` row gives
the main event of each cycle: `I` I-cache miss, `D` D-cache miss, `L`
load-use bubble, `U` mul-use bubble, `C` csr-use bubble, `B` divide busy, `P` mispredict, `T` trap, `Q` interrupt,
`R` MRET, `F` FENCE.I.

The examples below are from the test runs, unedited.

### Load-use: one bubble

`lw a4,4(a3)` is in EX on cycle 465 while `mv t1,a4` in ID needs `a4`, which
the load only has at the end of MEM. ID holds for one cycle (`Dd`), a bubble
goes to EX on cycle 466, and on cycle 467 `mv` takes the loaded value forwarded
from WB. (The load itself took `a3` forwarded from MEM, from the `addi` just
before it.)

```
   cycle                             460       470       4
                                    9012345678901234567890
80000190 li tp,0                    wwwwww                
80000194 auipc a3,0x1               mmmmmmW               
80000198 addi a3,a3,-320            xxxxxxMW              
8000019c lw a4,4(a3)                ddddddXMW             
800001a0 mv t1,a4                   ffffffDdXMWwwwwwwwwwww
800001a4 lui t2,0xff01                    FfDXMmmmmmmmmmmm
800001a8 addi t2,t2,-16                     FDXxxxxxxxxxxx
800001ac bne t1,t2,800002f8 <fail>           FDddddddddddd
800001b0 addi tp,tp,1                         Ffffffffffff
  events                            IIIII.L...IIIIIIIIIIII
```

### Mispredicts: two instructions squashed

The predictor starts empty, so taken branches mispredict until they are
learned. The branch resolves in EX; the two younger instructions in ID and IF
are squashed and fetch restarts at the target the next cycle (penalty: two
cycles).

```
   cycle                                     80        90   
                                    123456789012345678901234
80000030 li ra,0                    wwwwwww                 
80000034 li sp,0                    mmmmmmmW                
80000038 beq ra,sp,80000044 <reset_ xxxxxxxMW               
8000003c bne zero,gp,800002ec <fail ddddddd*                 (squashed: mispredict)
80000040 bne zero,gp,8000004c <test fffffff*                 (squashed: mispredict)
80000044 beq ra,sp,80000040 <reset_        FDXMW            
80000048 bne zero,gp,800002ec <fail         FD*              (squashed: mispredict)
8000004c li gp,3                             F*              (squashed: mispredict)
80000040 bne zero,gp,8000004c <test           FDXMWwwwwwwwww
80000044 beq ra,sp,80000040 <reset_            FD*           (squashed: mispredict)
80000040 bne zero,gp,8000004c <test             F*           (squashed: mispredict)
8000004c li gp,3                                 FDddddddddd
80000050 li ra,1                                  Ffffffffff
  events                            IIIIIIP..P..P.IIIIIIIIII
```

### Mul-use: a multiply's result is ready after MEM

A multiply computes in MEM (it was moved out of EX to take it off the critical
path; see the README's FPGA section). Its result cannot be forwarded from MEM
into EX, so an instruction that uses it at once waits a cycle in ID, exactly
as after a load, and takes the product forwarded from WB:

```
   cycle                              60        70
                                    89012345678901234567
80000028 li a1,7                    xxxxxMW
8000002c li a2,6                    dddddXMW
80000030 mul a3,a1,a2               fffffDXMW
80000034 addi a4,a3,1                    FDdXMmmmmmmmmmm
80000038 li t1,43                         FfDXxxxxxxxxxx
  events                            IIII..U..IIIIIIIIIII
```

### Divide: EX held for 32 steps

`div` is a 32-step restoring divider: it occupies EX for 34 cycles (cycles
64 to 97: start, 32 steps, result), holding everything behind it. Here it
overlaps a fetch miss (cycles 64 to 76; `B` is shown over `I`): the miss
freezes the rest of the pipeline, so `li a2` waits in MEM, but the divider
keeps stepping, so the divide hides most of the miss. MEM then takes bubbles
until the result is ready.

```
   cycle                              60        70        80        90        100 
                                    8901234567890123456789012345678901234567890123
80000010 j 8000002c <reset_done>    www                                           
8000002c li gp,2                    dddXMW                                        
80000030 li a1,20                   fffDXMWwwwwwwwwwwwww                          
80000034 li a2,6                       FDXMmmmmmmmmmmmmmW                         
80000038 div a4,a1,a2                   FDXxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxMW    
8000003c li t2,3                         FDdddddddddddddddddddddddddddddddddXMW   
80000040 bne a4,t2,80000108 <fail>        FfffffffffffffffffffffffffffffffffDXMWww
80000044 li gp,3                                                            FDXMmm
80000048 li a1,-20                                                           FDXxx
8000004c li a2,6                                                              FDdd
80000050 div a4,a1,a2                                                          Fff
  events                            II....BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB....III
```

### Interrupt: precise, at the instruction in EX

The timer interrupt is taken at the instruction in EX (`lw t2`, which becomes
`mepc`), so it and everything younger is squashed, while the older `sw` in MEM
completes. The test checks that after MRET `lw t2` runs again, so nothing is
lost or run twice.

```
   cycle                              190       200       210     
                                    890123456789012345678901234567
8000006e addi s5,s5,1               wwwwwww                       
80000070 sw s5,0(s7)                mmmmmmmWwwwwwwwwwwwwwww       
80000074 lw t2,0(s7)                xxxxxxx*                       (squashed: trap)
80000078 bne t2,s5,800000a2 <fail>  ddddddd*                       (squashed: trap)
8000007c addi s6,s6,-1              fffffff*                       (squashed: trap)
800000d4 csrr t5,mcause                    FfffffffffffffffDXMmmmm
800000d8 lui t6,0x80000                                    FDXxxxx
800000dc addi t6,t6,7                                       FDdddd
800000de beq t5,t6,800000e4 <handle                          Fffff
  events                            DDDDDDQIIIIIIIIIIIIIII...IIIII
```

### D-cache: a store waits for memory

The D-cache is write-through, so the store in MEM waits for the write to reach
the SRAM (`D`, 13 cycles), holding the whole pipeline.

```
   cycle                             90        100       110
                                    901234567890123456789012
80000040 auipc a5,0x0               wwwwww                  
80000044 addi a5,a5,20              mmmmmmWwwwwwwwwwwwww    
80000048 sw ra,0(sp)                xxxxxxMmmmmmmmmmmmmmW   
8000004c lw a4,0(sp)                ddddddXxxxxxxxxxxxxxMW  
80000050 j 80000058 <reset_done+0x2 ffffffDdddddddddddddXMW 
80000054 mv a4,ra                         FfffffffffffffD*   (squashed: mispredict)
80000058 lui t2,0xaa0                                   F*   (squashed: mispredict)
80000058 lui t2,0xaa0                                    FDX
8000005c addi t2,t2,170                                   FD
80000060 bne a4,t2,80000530 <fail>                         F
  events                            IIIII.DDDDDDDDDDDDD.P..I
```

### I-cache misses dominate these tests

The I-cache has 16-byte lines (four 32-bit instructions), filled one word at a
time over AXI4-Lite: 13 cycles a line. Each line misses once, but a miss stops
the whole pipeline (`mem_stall`), so the older instructions wait too:

```
   cycle                                     10        20        30     
                                    123456789012345678901234567890123456
80000000 auipc t0,0x0               FffffffffffffDXMWwwwwwwwwwwwww      
80000004 addi t0,t0,20                           FDXMmmmmmmmmmmmmmW     
80000008 csrw mtvec,t0                            FDXxxxxxxxxxxxxxMW    
8000000c li gp,0                                   FDdddddddddddddXMWwww
80000010 j 8000002c <reset_done>                    FfffffffffffffDXMmmm
80000014 lui gp,0x1                                               FD*    (squashed: mispredict)
80000018 addi gp,gp,-1421                                          F*    (squashed: mispredict)
8000002c li gp,2                                                    Ffff
  events                            IIIIIIIIIIII....IIIIIIIIIIIII..PIIII
```

In `rv32ui/add`, 1,104 of 1,613 cycles are fetch stalls (85 misses, one per
line: the tests are straight-line code that runs once).

**A fix that does not work.** Since the older instructions need nothing from
fetch, it is tempting to let them carry on during a fetch miss, with bubbles
going into ID. That change was built and measured: every test still passed
(and matched Spike), but the total went down by only 1.0% (125,212 to 123,966
cycles), and a few tests got 1% slower. The reason is visible in the diagram:
this code is limited by fetch bandwidth, one line every 13 cycles, and
draining the back end early does not make the next line arrive sooner. It only
helps where the back end has its own wait (a divide, a store) to overlap.
What would help is moving words faster (a pipelined or burst bus, or a wider
SRAM path), and loops, which run from the cache once the first iteration has
fetched them. The change was not kept.

### A bug the trace made visible: FENCE.I during a fill

Reviewing the I-cache for that change turned up a real bug. FENCE.I acts in
EX, and when the instruction two behind it starts a line that has never been
fetched, the fence waits in EX for the fill and acts in the cycle the filled
word is delivered. The I-cache ignored `invalidate` in that state, so the
invalidate was lost and a routine patched before the fence ran its old code.
`tests/directed/fence_i_fill.S` sets this up; before the fix the core ran
`li a0,1` where Spike ran the patched `li a0,2`:

```
   cycle                             150       160       170
                                    901234567890123456789012345678
80000050 nop                        wwwwwww
80000054 nop                        mmmmmmmW
80000058 fence.i                    xxxxxxxMW
8000005c nop                        ddddddd*                       (squashed: fence.i)
80000060 jal 800000a0 <patch_me>    fffffff*                       (squashed: fence.i)
8000005c nop                               FDXMW
80000060 jal 800000a0 <patch_me>            FDXMW
80000064 li t1,2                             FD*                   (squashed: mispredict)
80000066 bne a0,t1,8000006e <fail>            F*                   (squashed: mispredict)
800000a0 li a0,1                               FDXMW
800000a4 ret                                    FDXMW
```

`fence.i` sits in EX (`xxxxxxx`) while `jal` misses in IF, and acts at cycle
155, the cycle the fill completes. Five cycles later `li a0,1`, the old code,
is fetched from the I-cache as if nothing had happened. The I-cache now drops
every line in that cycle too.

## Where the cycles go

`pipeview.lost_cycles` explains every cycle in which no instruction retires.
Either the pipeline was held (a D-cache wait or an I-cache miss), or WB holds a
bubble, which is followed back register by register to the cycle that made it:
a flush (mispredict, trap, MRET, FENCE.I), a load-use, mul-use or csr-use
bubble, a divide holding EX, or fetch delivering nothing while it assembles a 32-bit instruction that
straddles two words. The DSP benchmarks (`tests/bench`) report their cycles
this way.

## JSON for animation

`pipeview.py json` writes the same rebuild for a window of cycles (here, the
load-use example: the load's last cycles, and cycle 467, where it retires and
its value is forwarded to `mv` in EX):

```json
{
  "format": "brv32p-pipeview-1",
  "insns":  [ ... {"id": 99, "pc": "8000019c", "raw": "0046a703", "asm": "lw a4,4(a3)", "fate": "retired", "end": 467, "cause": null, "stages": [["ID", 464], ["EX", 465], ["MEM", 466], ["WB", 467]]} ... ],
  "cycles": [ ... {"n": 467, "stages": {"IF": 102, "ID": 101, "EX": 100, "MEM": null, "WB": 99}, "events": ["forward"], "retire": true, "fetch": {"pc": "800001a8", "valid": true, "straddle": false, "predict_taken": false}, "fwd": {"rs1": [14, "WB"], "rs2": [0, null]}, "write": [14, "0ff00ff0"]} ... ]
}
```

`stages` maps each stage to the instruction id it holds that cycle (`null` is
a bubble); `fwd` gives the forwarded source registers and where each value
came from; `write` is the register written as an instruction retires; `fetch`
gives the fetch pc, whether a complete instruction was fetched (false on the
first cycle of a 32-bit instruction that straddles two words), and whether the
predictor said taken.
