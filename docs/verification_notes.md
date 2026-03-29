# AXI MM Dual Port BRAM with UVM 1.2 -Verification Notes  

- **DUT**: `dut/axi_mm_dual_port_bram.sv` 
- **TB Top**: `tb/axi_mm_top.sv` 
- **TB Methodology**: UVM 1.2
- **Simulator**: QuestaSim  

---

## Summary

- **axi_mm_smoke_test**
  -  Quick sanity check for basic Dual-port AXI-MM read/write behavior
- **axi_mm_directed_test** 
  - Deterministic directed scenarios for single-beat access, INCR/WRAP/FIXED bursts, partial `WSTRB`, same-address merge, cross-port visibility, and selected backpressure checks
- **axi_mm_random_test**
  - Long dual-port random stress with mixed read/write traffic, backpressure, burst variation, partial `WSTRB`, locality, and split-window operation
    - 44k WRITES / 36k READS for both ports, with 360k `commit_beats` level
- **axi_mm_corner_test**
  - WRAP/FIXED edges, boundary crossing, AW/AR contention, outstanding depth, mixed-ID ordering, reset during activity, max burst LEN=255, narrow-size lane mapping, ready backpressure
- **axi_mm_coverage_test**
  -  Coverage-driven sweeps (len/size sweep, `WSTRB` stress, boundary/end-of-mem stress, ordering suite, backpressure, reset injection)
- **Coverage closure**
  - Total covergroup coverage improved from **70.53%** to **96.14%**



## Verification Goals

This project verifies a verification-oriented, multi-clock dual AXI4-MM scratchpad model with:
- Two AXI4-MM slave ports 
  - `axi0_if` at `dma_clk`
  - `axi1_if` at `core_clk`

- Burst-level atomic commit semantics
- `READ_FIRST`  with no forwarding behavior
- AXI ready/valid backpressure behavior
- Multi-clock interaction correctness for Port1 write bridging (`core_clk` → `dma_clk`)

Main verification focus:
- AXI handshake correctness under backpressure
- Burst integrity (no partial commit/no beat-by-beat visibility into memory image)
- Correct address behavior for INCR / WRAP / FIXED
- Correct byte-lane masking with narrow sizes and `WSTRB`
- Deterministic scoreboard alignment around cross-clock commit/apply visibility



## Testbench Architecture

The UVM environment contains:
- Two AXI-MM agents (one per port)
- A scoreboard with byte-level reference memory model
- Commit/apply observation monitors
- Functional coverage subscribers
- Smoke, directed, random, corner, and coverage test layers



## Scoreboard Stability Assumption

Because this DUT is multi-clock and the commit engine lives in `dma_clk`, the scoreboard uses a conservative stabilization window to avoid false failures caused by cross-domain timing skew

- `COMMIT_STABLE_DELAY = 30ns`

TB-side meaning:
- After a burst becomes visible to the scoreboard model, the checker waits **30ns**
- Only then does it treat the byte image as stable for cross-domain read comparison

**This is a verification-side rule, not a DUT guarantee**



## Test List

- `axi_mm_smoke_test`
- `axi_mm_directed_test`
- `axi_mm_random_test`
- `axi_mm_corner_test`
- `axi_mm_coverage_test`



## Run Script

Entry script:
- `run.tcl`

Outputs:
- `logs/sim_YYYYMMDD_HHMMSS_seed<SEED>.log`
- `logs/sim_YYYYMMDD_HHMMSS_seed<SEED>.wlf`

Plusargs:
- `+UVM_TESTNAME=<test_name>`
- `+CASE=<tag>`
- `+CASELIST=<tag0,tag1,...>`
- `+UVM_VERBOSITY=UVM_HIGH`
- `+UVM_OBJECTION_TRACE`
- `+UVM_FINISH_ON_COMPLETION=1`



## Smoke Test Case Suite (`axi_mm_smoke_test`)

1. **Simple burst case**



## Directed Test Case Suite (`axi_mm_directed_test`)

1. **Single beat write/read**
2. **Multi-beat INCR burst write/read**
3. **WRAP burst write/read** 
4. **Partial strobe write + readback**
5. **Cross-port coherence + same-address partial collision**
6. **Same-address cross-port collision + byte-merge**
7. **Burst integrity stress + cross-port coherence**
8. **Parallel same address INCR 8 beats with complementary WSTRB**
9. **Same address multi-beat byte merge across ports**
10. **Same address parallel INCR 8 beats + interleaved WSTRB**
11. **Stall `commit_if.ready` while issuing a P1 write burst**
12. **Stall P0 BREADY while issuing multiple write bursts**



## Random Test Case Suite (`axi_mm_random_test`)

1. **Baseline split**
2. **W stream gaps split**
3. **Backpressure split**
4. **Heavy backpressure split**
5. **Timing jitter split**
6. **Soak split**
7. **Fixed split**
8. **Wrap split mix stress**
9. **Size rand split mix**
10. **Partial WSTRB split stress**



## Corner Test Case Suite (`axi_mm_corner_test`)

1. **LEN=0 single-beat (INCR/FIXED) + WSTRB**
2. **Boundary crossing + end-of-window**
3. **Ordering + partial merge (per-window)**
4. **AW/AR contention overlap**
5. **WRAP (4-beat) edges + FIXED last-wins**
6. **WRAP (8-beat) edges**
7. **WSTRB patterns**
8. **Outstanding AW depth4 + observable stall**
   - 8.1 **Depth1-friendly split AW/W**
   - 8.2 **Outstanding + reverse B_WAIT**
9. Mixed-ID ordering
   - 9.1 **Mixed-ID ordering (Port0)**
   - 9.2 **Mixed-ID ordering (Port0/Port1)**
10. **Reset during activity**
11. **MAX LEN=255 INCR burst write/read**
12. **Narrow sizes lane mapping + merge**
13. **READY backpressure**
14. **Complete regression / completion suite**



## Coverage Test Case Suite (`axi_mm_coverage_test`)

1. **Plumbing smoke**
2. **Burst len size sweep**
3. **WSTRB stress**
4. **Boundary & End-of-mem bias**
5. **Ordering/Outstanding/ID**
6. **READY/backpressure**
7. **Reset injection**
8. **Completion coverage suite**



## Coverage Test COV4 Debug Story

This was the main issue near project closure.

### Preface

At one point, the earlier regressions were already passing, and the project looked close to done. The remaining problem showed up during:

- **Coverage Test Case 8: complete coverage suite**

That run exposed scoreboard mismatches that were not showing up in the simpler tests.

Because Case 8 is a completion/closure style suite, the next step was to figure out which individual coverage case was actually causing the mismatch.

After narrowing it down, the failure source was traced back to:

- **Coverage Case 4**

The first suspicion was:
- Maybe a **boundary crossing** problem
- Maybe this is an **end-of-memory** problem

### Rework

Originally, Case 4 mixed together edge-biased traffic in a way that made debug harder

So I reworked it into two clearer modes:


```systemverilog
bit COV4_RUN_BOUNDARY   = 1;
bit COV4_RUN_END_OF_MEM = 0;
```

The idea was to split COV4 into:

- Boundary-focused sweep

- End-of-memory-focused sweep

That made it much easier to isolate whether the mismatch was really caused by one specific address-region behavior.

### Boundary-only result

I first ran only the boundary side of Case 4.

That run eventually became clean:

- No scoreboard mismatch

- Scoreboard final result: PASS

This showed that the current environment could survive the boundary-focused stress after the scoreboard updates.

### End-of-memory-only result

Next I ran only the end-of-memory side.

That also completed clean:

- No scoreboard mismatch

- Scoreboard final result: PASS

This was important, because it showed the issue was not simply "boundary bad" or "end-of-mem bad" in isolation.

### Both enabled together

After that, I enabled both:

COV4_RUN_BOUNDARY = 1

COV4_RUN_END_OF_MEM = 1

This combined run also passed with:

- Mismatches = 0

That was the key sign that Case 4 itself was finally stable enough to be put back into the full completion suite.

### Actual Issue

The root cause was not just an address-edge bug.

The real issue was that the scoreboard initially did not fully match the DUT's apply visibility behavior.

- **Important DUT behavior**

  - A burst is updated atomically in memory
  - Then `apply_if` emits beats one by one

  - So the memory image is already updated, but apply emission is still being drained over time

This means the scoreboard cannot simply assume: "Each apply beat becomes visible independently as it arrives" => That assumption is too weak for this DUT.

- **What was needed**
  - Treat a burst as having a common visibility point for the scoreboard
  - At the same time, defer read comparison when a read touches the future tail of an apply burst that has not been fully observed yet

That was the critical alignment that removed the false mismatches.

### Scoreboard Behavior After the Fix

The final scoreboard approach that worked was:

- Byte-level reference model

- `apply_if` driven visibility

- Burst-aware apply tracking

- Deferred read compare when a read overlaps the still-in-progress future tail of an apply burst

- `COMMIT_STABLE_DELAY` = 30ns

**After this change**

- Case 4 mismatch went away

- Full coverage completion became stable

- Regression runs also stayed clean

  

### Regression 

After fixing the scoreboard alignment problem, I reran the important tests (basically most the tests).

- **Smoke test**

  - PASS

  - Mismatches = 0

- **Directed test** **(All cases)**

  - PASS

  - Mismatches = 0

- **Random test (All cases)**

  - PASS

  - Mismatches = 0

- **Corner test Case 14 (complete suite)**

  - PASS
  - Mismatches = 0

  - `pending_read` = 0

- **Coverage test Case 8 (complete coverage suite)**

  - PASS

  - Mismatches = 0

  - `pending_read` = 0

This was the point where I considered the project functionally can be closed from the mismatch/debug perspective.

### Results summary
- Final regression status

  - Smoke test: PASS

  - Directed test: PASS	

  - Random test: PASS

  - Corner test: PASS

  - Coverage test: PASS

- Final scoreboard status

  - No remaining mismatches in the main regression runs

  - Case 8 (Coverage Test complete suite) passes cleanly

  - The issue that originally appeared only in coverage closure is now resolved

    

## Coverage status

Earlier functional coverage result:

- **70.53%** total covergroup coverage

After reworking COV4 and closing the scoreboard alignment issue:

- **96.14%** total covergroup coverage

### Reported result

- TOTAL COVERGROUP COVERAGE: 96.14%

- Errors: 0, Warnings: 0

This was a major improvement and is worth recording because it reflects both:

- Better coverage intent in the stimulus

- Successful closure of the hard mismatch issue that blocked the completion run

### Integration / known Limitation Notes
- Read burst admission (RD FIFO capacity)

- DUT Read path uses an internal per-port read FIFO (RD_FIFO_DEPTH)
- AR is admitted only if the whole burst can fit:
  - `(ARLEN + 1) <= RD_FIFO_DEPTH`

This is intentional for deterministic behavior, but it means:

- If a master issues read bursts longer than `RD_FIFO_DEPTH`, `ARREADY` may remain low

- The read can stall

Expected usage:

- Chunked/tiled reads
  - Or increase `RD_FIFO_DEPTH` if needed

### Debug notes

- For DUT, scoreboard alignment had to follow apply visibility semantics, not only commit completion

- In a multi-clock verification-oriented model, conservative stabilization rules are sometimes necessary to avoid false mismatches

- When the last issue only appears in a completion suite, it is usually worth isolating the responsible sub-case first before changing too much at once

  

## Project status

- No mismatches in all test cases

- Coverage completion suite (Case 8) passes

- Main regression tests pass

- Functional covergroup coverage improved to 96.14%
- Project is now in a good state to close