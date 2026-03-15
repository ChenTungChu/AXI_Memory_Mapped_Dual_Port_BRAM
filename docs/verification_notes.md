# Verification Notes — AXI Dual-Port Multi-Clock BRAM (UVM 1.2)

Author: Eric  
DUT: `dut/axi_mm_dual_port_bram.sv`  
TB Top: `tb/axi_mm_top.sv`  
Methodology: UVM 1.2  
Simulator: Questa/ModelSim (driven by `run.tcl`)

---

## Highlights (what to look at first)

- **axi_mm_corner_test**: hand-picked corner cases (WRAP/FIXED edges, boundary crossing, AW/AR contention, outstanding depth, mixed-ID ordering, reset during activity, max burst LEN=255, narrow-size lane mapping, ready backpressure)
- **axi_mm_coverage_test**: coverage-driven sweeps (len/size sweep, wstrb stress, boundary/end-of-mem stress, ordering suite, backpressure, reset injection)
- **Case 4 rework**: the biggest debug item in the final stage; this was where the last mismatch issue was isolated and resolved
- **Coverage closure**: total covergroup coverage improved from **70.53%** to **96.14%**

---

## 1) Verification goals (what I wanted to prove)

This project verifies a verification-oriented, multi-clock dual AXI4-MM scratchpad model with:
- Two AXI4-MM slave ports (`axi0_if` @ `dma_clk`, `axi1_if` @ `core_clk`)
- Burst-level atomic commit semantics
- `READ_FIRST` / no forwarding behavior
- AXI ready/valid backpressure behavior
- Multi-clock interaction correctness for Port1 write bridging (`core_clk` → `dma_clk`)

Main verification focus:
- AXI handshake correctness under backpressure
- Burst integrity (no partial commit / no beat-by-beat visibility into memory image)
- Correct address behavior for INCR / WRAP / FIXED
- Correct byte-lane masking with narrow sizes and `WSTRB`
- Deterministic scoreboard alignment around cross-clock commit/apply visibility

---

## 2) Testbench architecture (high level)

The UVM environment contains:
- Two AXI-MM agents (one per port)
- A scoreboard with byte-level reference memory model
- Commit/apply observation monitors
- Functional coverage subscribers
- Directed, random, corner, and coverage-oriented test layers

High-level idea:
- The DUT is verification-oriented, so I exposed enough observation points to let the scoreboard align with actual visibility behavior
- The scoreboard models memory at byte level and compares reads against the expected visible image
- Special care is needed because this DUT is multi-clock and uses a burst commit engine

---

## 3) Scoreboard stability assumption (important)

Because this DUT is multi-clock and the commit engine lives in `dma_clk`, the scoreboard uses a conservative stabilization window to avoid false failures caused by cross-domain timing skew.

- `COMMIT_STABLE_DELAY = 30ns`

TB-side meaning:
- After a burst becomes visible to the scoreboard model, the checker waits **30ns**
- Only then does it treat the byte image as stable for cross-domain read comparison

This is a **verification-side rule**, not a DUT guarantee.

---

## 4) Test list

Implemented tests:
- `axi_mm_smoke_test`
- `axi_mm_random_test`
- `axi_mm_corner_test`
- `axi_mm_directed_test`
- `axi_mm_coverage_test`

---

## 5) How to run (Questa / ModelSim)

Entry script:
- `run.tcl`

What it does:
- Creates `logs/`
- Keeps newest logs/wlf files
- Runs the selected test/case
- Generates timestamped outputs
- Adds waves automatically

Typical outputs:
- `logs/sim_YYYYMMDD_HHMMSS_seed<SEED>.log`
- `logs/sim_YYYYMMDD_HHMMSS_seed<SEED>.wlf`

Useful plusargs:
- `+UVM_TESTNAME=<test_name>`
- `+CASE=<tag>`
- `+CASELIST=<tag0,tag1,...>`
- `+UVM_VERBOSITY=UVM_HIGH`
- `+UVM_OBJECTION_TRACE`
- `+UVM_FINISH_ON_COMPLETION=1`

---

## 6) Case selection controls (`+CASE` / `+CASELIST`)

Both `axi_mm_corner_test` and `axi_mm_coverage_test` use a case selector helper.

Priority:
1. `+CASE=all` (or `ALL`)
   - runs all cases inside the test
2. `+CASE=<tag>`
   - runs one specific case
3. `+CASELIST=<tag0,tag1,...>`
   - runs multiple selected cases
4. If nothing is provided
   - falls back to `DEFAULT_CASE`

Examples:
- Run a single corner case:
  - `+UVM_TESTNAME=axi_mm_corner_test +CASE=11`
- Run multiple cases:
  - `+UVM_TESTNAME=axi_mm_corner_test +CASELIST=2,5,6,12`
- Run a full completion case:
  - `+UVM_TESTNAME=axi_mm_coverage_test +CASELIST=8`

Note:
- `+CASELIST=8` does **not** automatically include sub-cases like `8.1`, `8.2` unless those are explicitly supported and listed by the test

---

## 7) Corner case suite (`axi_mm_corner_test`)

The corner test is organized as selectable cases so I can isolate failures quickly.

### Case map
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

---

## 8) Coverage-driven suite (`axi_mm_coverage_test`)

Coverage test is organized into coarse-grain sweeps / stress suites:

1. `run_cov1_smoke()`
2. `run_cov2_burst_len_size_sweep()`
3. `run_cov3_wstrb_stress()`
4. `run_cov4_boundary_edge_sweep()`
5. `run_cov5_ordering_suite()`
6. `run_cov6_ready_backpressure()`
7. `run_cov7_reset_injection()`
8. `run_cov8_completion_suite()`

---

## 9) COV4 debug story: how the final mismatch issue was found and fixed

This was the main issue near project closure.

### 9.1 What happened

At one point, the earlier regressions were already passing, and the project looked close to done.  
The remaining problem showed up during:

- **Coverage Test Case 8: complete coverage suite**

That run exposed scoreboard mismatches that were not showing up in the simpler tests.

Because Case 8 is a completion/closure style suite, the next step was to figure out **which individual coverage case was actually causing the mismatch**.

After narrowing it down, the failure source was traced back to:

- **Coverage Case 4**

At that point, the first suspicion was:
- maybe this is a **boundary crossing** problem
- or maybe this is an **end-of-memory** problem

That turned out to be a useful direction, but not the full story.

---

### 9.2 Why Case 4 was reworked

Originally, Case 4 mixed together edge-biased traffic in a way that made debug harder.

So I reworked it into two clearer modes:

```systemverilog
// COV4 mode control
bit COV4_RUN_BOUNDARY   = 1;
bit COV4_RUN_END_OF_MEM = 0;

The idea was to split COV4 into:

boundary-focused sweep

end-of-memory-focused sweep

That made it much easier to isolate whether the mismatch was really caused by one specific address-region behavior.

9.3 Boundary-only result

I first ran only the boundary side of Case 4.

That run eventually became clean:

no scoreboard mismatch

scoreboard final result: PASS

This showed that the current environment could survive the boundary-focused stress after the scoreboard updates.

9.4 End-of-memory-only result

Next I ran only the end-of-memory side.

That also completed clean:

no scoreboard mismatch

scoreboard final result: PASS

This was important, because it showed the issue was not simply "boundary bad" or "end-of-mem bad" in isolation.

9.5 Both enabled together

After that, I enabled both:

COV4_RUN_BOUNDARY = 1

COV4_RUN_END_OF_MEM = 1

This combined run also passed with:

mismatches = 0

That was the key sign that Case 4 itself was finally stable enough to be put back into the full completion suite.

9.6 What the real issue actually was

The root cause was not just an address-edge bug.

The real issue was that the scoreboard initially did not fully match the DUT's apply visibility behavior.

Important DUT behavior:

a burst is updated atomically in memory

then apply_if emits beats one by one

so the memory image is already updated, but apply emission is still being drained over time

This means the scoreboard cannot simply assume:

"each apply beat becomes visible independently as it arrives"

That assumption is too weak for this DUT.

What was needed:

Treat a burst as having a common visibility point for the scoreboard model

At the same time, defer read comparison when a read touches the future tail of an apply burst that has not been fully observed yet

That was the critical alignment that removed the false mismatches.

9.7 Final scoreboard behavior used for closure

The final scoreboard approach that worked was:

byte-level reference model

apply_if-driven visibility

burst-aware apply tracking

deferred read compare when a read overlaps the still-in-progress future tail of an apply burst

conservative COMMIT_STABLE_DELAY = 30ns

After this change:

the previous Case 4 mismatch went away

full coverage completion became stable

later regression runs also stayed clean

10) Regression status after the fix

After fixing the scoreboard alignment problem, I reran the important tests.

Smoke test

PASS

mismatches = 0

Directed test

PASS

mismatches = 0

Random test

PASS

mismatches = 0

Corner test Case 14 (complete suite / regression)

PASS

mismatches = 0

pending_read = 0

Coverage test Case 8 (complete coverage suite)

PASS

mismatches = 0

pending_read = 0

This was the point where I considered the project functionally closed from the mismatch/debug perspective.

11) Results summary
Final regression status

Smoke test: PASS

Directed test: PASS

Random test: PASS

Corner complete suite: PASS

Coverage completion suite: PASS

Final scoreboard status

No remaining mismatches in the main regression runs

Case 8 now passes cleanly

The issue that originally appeared only in coverage closure is now resolved

12) Coverage status

Earlier functional coverage result:

70.53% total covergroup coverage

After reworking COV4 and closing the scoreboard alignment issue:

96.14% total covergroup coverage

Reported result:

TOTAL COVERGROUP COVERAGE: 96.14%

Errors: 0, Warnings: 0

This was a major improvement and is worth recording because it reflects both:

better coverage intent in the stimulus

successful closure of the hard mismatch issue that blocked the completion run

13) Why the remaining deferred reads were not treated as a blocker

During some intermediate runs, the scoreboard still reported non-zero pending_read counts at end of test.

Important point:

these pending reads were not the original mismatch bug

they were mostly scoreboard bookkeeping / end-of-test timing artifacts

the real blocking problem was the mismatch

once mismatch was gone and full completion regressions passed, reducing pending_read further became an optimization topic, not a correctness blocker

This was especially clear after:

Case 4 passed

Case 8 passed

smoke/directed/random/corner regression also passed

So for project closure, the correct priority was:

eliminate mismatches

confirm coverage completion suite passes

rerun main regression tests

document the result

That sequence is now complete.

14) Integration / known limitation notes
Read burst admission (RD FIFO capacity)

The DUT read path uses an internal per-port read FIFO (RD_FIFO_DEPTH).
AR is admitted only if the whole burst can fit:

(ARLEN + 1) <= RD_FIFO_DEPTH

This is intentional for deterministic behavior, but it means:

if a master issues read bursts longer than RD_FIFO_DEPTH, ARREADY may remain low

the read can stall

Expected usage:

chunked/tiled reads

or increase RD_FIFO_DEPTH if needed

15) Practical debug notes / lessons learned

A few things that helped during closure:

Splitting a failing coverage case into smaller modes was worth it
(boundary vs end_of_mem)

For this DUT, scoreboard alignment had to follow apply visibility semantics, not only commit completion

In a multi-clock verification-oriented model, conservative stabilization rules are sometimes necessary to avoid false mismatches

When the last issue only appears in a completion suite, it is usually worth isolating the responsible sub-case first before changing too much at once

16) Project status

At this point:

the original mismatch issue found during coverage closure has been resolved

Case 4 passes in boundary-only, end-of-memory-only, and combined mode

Coverage completion suite (Case 8) passes

Main regression tests pass

functional covergroup coverage improved to 96.14%

So from the verification side, this project is now in a good state to close and document.