// File: tb/uvm/test/axi_mm_coverage_test.sv
`ifndef AXI_MM_COVERAGE_TEST_SV
`define AXI_MM_COVERAGE_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

class axi_mm_coverage_test extends axi_mm_corner_test; // ←重點：不要 extends uvm_test
  `uvm_component_utils(axi_mm_coverage_test)

  function new(string name="axi_mm_coverage_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  // -----------------------------
  // knobs（先用比較保守的數量，避免第一次就跑太久）
  // -----------------------------
  int unsigned N_SMOKE  = 200;
  int unsigned N_SWEEP  = 1500;
  int unsigned N_WSTRB  = 1200;
  int unsigned N_EDGE   = 1200;
  int unsigned N_READY  = 1200;

  // COV4 mode control
  bit COV4_RUN_BOUNDARY   = 1;
  bit COV4_RUN_END_OF_MEM = 1;


  // ------------------------------------------------------------
  // Plusarg-driven case selection (Method A) - Questa safe
  //   +CASE=5.3
  //   +CASELIST=3.1,5.3,2
  //   +CASE=all
  // default: run DEFAULT_CASE only (set below)
  // ------------------------------------------------------------
  localparam string DEFAULT_CASE = "1";

  function automatic string get_plusarg_str(string key);
      string v;
      if ($value$plusargs({key, "=%s"}, v)) return v;
      return "";
  endfunction

  function automatic int str_find(input string hay, input string needle);
      int i, j;
      if (needle.len() == 0) return 0;
      if (hay.len() < needle.len()) return -1;

      for (i = 0; i <= hay.len()-needle.len(); i++) begin
          for (j = 0; j < needle.len(); j++) begin
              if (hay[i+j] != needle[j]) break;
          end
          if (j == needle.len()) return i;
      end
      return -1;
  endfunction

  function automatic bit case_enabled(string tag);
      string one, list;
      one  = get_plusarg_str("CASE");
      list = get_plusarg_str("CASELIST");

      // Run all
      if ((one == "all") || (one == "ALL")) return 1;

      // Single selection
      if (one != "") return (one == tag);

      // List selection (comma separated)
      if (list != "") begin
          string tmp;
          tmp = {",", list, ","};
          return (str_find(tmp, {",", tag, ","}) != -1);
      end

      // Default behavior if user didn't pass args:
      return (tag == DEFAULT_CASE);
  endfunction


  // helper: start sequence (typed)
  task automatic run_cov_seq(uvm_sequencer_base seqr, axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH) seq);
    seq.start(seqr);
  endtask

  // ---------------------------------------
  // COV1: plumbing smoke（最穩定）
  // ---------------------------------------
  task automatic run_cov1_smoke();
    axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH) s0, s1;
    banner_case("COV1", "Smoke (no stress, size=8B, INCR only)");

    cfg_driver_stress_off();
    cfg_driver_hold_ready(1,1);

    s0 = axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH)::type_id::create("cov1_s0");
    s1 = axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH)::type_id::create("cov1_s1");
    s0.n_tr = N_SMOKE; s1.n_tr = N_SMOKE;

    // window base：建議從 base/env cfg 取，不要 hardcode
    s0.win0_base = WIN0_BASE; s0.win1_base = WIN1_BASE;
    s1.win0_base = WIN0_BASE; s1.win1_base = WIN1_BASE;

    // easy dist
    s0.pct_incr = 100; s0.pct_fixed = 0; s0.pct_wrap = 0;
    s1.pct_incr = 100; s1.pct_fixed = 0; s1.pct_wrap = 0;
    s0.pct_size_8 = 100; s1.pct_size_8 = 100;

    fork
      run_cov_seq(env_h.p0_agent.seqr, s0);
      begin #1ns; run_cov_seq(env_h.p1_agent.seqr, s1); end
    join
  endtask

  // ---------------------------------------
  // COV2: main sweep（closure 主力）
  // ---------------------------------------
  task automatic run_cov2_burst_len_size_sweep();
    axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH) s0, s1;
    banner_case("COV2", "Balanced Burst/Len/Size Sweep (no stress)");

    cfg_driver_stress_off();
    cfg_driver_hold_ready(1,1);

    s0 = axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH)::type_id::create("cov2_s0");
    s1 = axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH)::type_id::create("cov2_s1");
    s0.n_tr = N_SWEEP; s1.n_tr = N_SWEEP;

    s0.win0_base = WIN0_BASE; s0.win1_base = WIN1_BASE;
    s1.win0_base = WIN0_BASE; s1.win1_base = WIN1_BASE;

    // burst distribution
    s0.pct_incr=50; s0.pct_fixed=20; s0.pct_wrap=30;
    s1.pct_incr=50; s1.pct_fixed=20; s1.pct_wrap=30;

    // sizes (1/2/4/8B)
    s0.pct_size_1=25; s0.pct_size_2=25; s0.pct_size_4=25; s0.pct_size_8=25;
    s1.pct_size_1=25; s1.pct_size_2=25; s1.pct_size_4=25; s1.pct_size_8=25;

    // length bins：中長為主、偶爾 max
    s0.pct_len_short = 40; s0.pct_len_mid = 45; s0.pct_len_long = 13; s0.pct_len_max = 2;
    s1.pct_len_short = 40; s1.pct_len_mid = 45; s1.pct_len_long = 13; s1.pct_len_max = 2;

    fork
      run_cov_seq(env_h.p0_agent.seqr, s0);
      begin #1ns; run_cov_seq(env_h.p1_agent.seqr, s1); end
    join
  endtask

  // ---------------------------------------
  // COV3: WSTRB stress（write-heavy）
  // ---------------------------------------
  task automatic run_cov3_wstrb_stress();
    axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH) s0, s1;
    banner_case("COV3", "WSTRB Pattern Stress (write-heavy)");

    cfg_driver_stress_off();
    cfg_driver_hold_ready(1,1);

    s0 = axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH)::type_id::create("cov3_s0");
    s1 = axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH)::type_id::create("cov3_s1");
    s0.n_tr = N_WSTRB; s1.n_tr = N_WSTRB;

    s0.win0_base = WIN0_BASE; s0.win1_base = WIN1_BASE;
    s1.win0_base = WIN0_BASE; s1.win1_base = WIN1_BASE;

    s0.pct_wr = 80; s1.pct_wr = 80;
    s0.enable_wstrb_bias = 1;
    s1.enable_wstrb_bias = 1;

    // bins
    s0.pct_w_all0=10; s0.pct_w_all1=20; s0.pct_w_0f=15; s0.pct_w_f0=15;
    s0.pct_w_aa=10;   s0.pct_w_55=10;   s0.pct_w_onehot=10; s0.pct_w_sparse=10;

    s1.pct_w_all0=10; s1.pct_w_all1=20; s1.pct_w_0f=15; s1.pct_w_f0=15;
    s1.pct_w_aa=10;   s1.pct_w_55=10;   s1.pct_w_onehot=10; s1.pct_w_sparse=10;

    fork
      run_cov_seq(env_h.p0_agent.seqr, s0);
      begin #1ns; run_cov_seq(env_h.p1_agent.seqr, s1); end
    join
  endtask

  // ---------------------------------------
  // COV4: boundary/end-of-mem bias
  // ---------------------------------------
  task automatic run_cov4_boundary_edge_sweep();
    axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH) s0, s1;

    banner_case("COV4",
      $sformatf("Boundary/End-of-mem biased sweep (boundary=%0d end_of_mem=%0d)",
                COV4_RUN_BOUNDARY, COV4_RUN_END_OF_MEM));

    cfg_driver_stress_off();
    cfg_driver_hold_ready(1,1);

    if (!COV4_RUN_BOUNDARY && !COV4_RUN_END_OF_MEM) begin
      `uvm_warning("COV4",
        "run_cov4_boundary_edge_sweep() skipped because both COV4_RUN_BOUNDARY and COV4_RUN_END_OF_MEM are 0")
      return;
    end

    // -----------------------------
    // phase A: boundary
    // -----------------------------
    if (COV4_RUN_BOUNDARY) begin
      s0 = axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH)::type_id::create("cov4_boundary_s0");
      s1 = axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH)::type_id::create("cov4_boundary_s1");

      s0.n_tr = N_EDGE;
      s1.n_tr = N_EDGE;

      s0.win0_base = WIN0_BASE; s0.win1_base = WIN1_BASE;
      s1.win0_base = WIN0_BASE; s1.win1_base = WIN1_BASE;

      s0.bias_boundary   = 1;
      s1.bias_boundary   = 1;
      s0.bias_end_of_mem = 0;
      s1.bias_end_of_mem = 0;

      fork
        run_cov_seq(env_h.p0_agent.seqr, s0);
        begin #1ns; run_cov_seq(env_h.p1_agent.seqr, s1); end
      join
    end

    // -----------------------------
    // phase B: end-of-mem
    // -----------------------------
    if (COV4_RUN_END_OF_MEM) begin
      s0 = axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH)::type_id::create("cov4_eom_s0");
      s1 = axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH)::type_id::create("cov4_eom_s1");

      s0.n_tr = N_EDGE;
      s1.n_tr = N_EDGE;

      s0.win0_base = WIN0_BASE; s0.win1_base = WIN1_BASE;
      s1.win0_base = WIN0_BASE; s1.win1_base = WIN1_BASE;

      s0.bias_boundary   = 0;
      s1.bias_boundary   = 0;
      s0.bias_end_of_mem = 1;
      s1.bias_end_of_mem = 1;

      fork
        run_cov_seq(env_h.p0_agent.seqr, s0);
        begin #1ns; run_cov_seq(env_h.p1_agent.seqr, s1); end
      join
    end
  endtask

  // ---------------------------------------
  // COV5: ordering/outstanding/ID (reuse directed)
  // ---------------------------------------
  task automatic run_cov5_ordering_suite();
    banner_case("COV5", "Ordering/Outstanding/ID closure (reuse directed)");
    run_case_8a_multi_aw_no_interleave_fixed_for_depth1();
    run_case_8b_outstanding_ooo_b_p0p1();
    run_case_9a_mixed_id_ordering_p0();
    run_case_9b_mixed_id_ordering_p0p1();
  endtask

  // ---------------------------------------
  // COV6: READY/backpressure（最後才開）
  // ---------------------------------------
  task automatic run_cov6_ready_backpressure();
    axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH) s0, s1;
    banner_case("COV6", "READY/backpressure stress (commit-based monitor)");


    // 關鍵：你現在的 commit monitor/SCB 扛得住，但第一次別玩太兇
    cfg_driver_hold_ready(0,0);
    cfg_driver_stress_on();

    s0 = axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH)::type_id::create("cov6_s0");
    s1 = axi_mm_cov_rand_seq#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH)::type_id::create("cov6_s1");
    s0.n_tr = N_READY; s1.n_tr = N_READY;
    s0.win0_base = WIN0_BASE; s0.win1_base = WIN1_BASE;
    s1.win0_base = WIN0_BASE; s1.win1_base = WIN1_BASE;

    fork
      run_cov_seq(env_h.p0_agent.seqr, s0);
      begin #1ns; run_cov_seq(env_h.p1_agent.seqr, s1); end
    join

    cfg_driver_stress_off();
    cfg_driver_hold_ready(1,1);
  endtask

  // ---------------------------------------
  // COV7: reset injection（reuse directed Case10）
  // ---------------------------------------
  task automatic run_cov7_reset_injection();
    banner_case("COV7", "Reset injection during activity (reuse Case10)");
    run_case_10_reset_during_activity();
  endtask

  // ---------------------------------------
  // Suite
  // ---------------------------------------
  task automatic run_cov8_completion_suite();
    banner_case("COV8", "COVERAGE COMPLETION SUITE");
    run_cov1_smoke();
    run_cov2_burst_len_size_sweep();
    run_cov3_wstrb_stress();
    run_cov4_boundary_edge_sweep();
    run_cov5_ordering_suite();
    run_cov6_ready_backpressure();
    run_cov7_reset_injection();
  endtask

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);

    `uvm_info("COVERAGE_TEST", "Starting AXI-MM Coverage Test", UVM_MEDIUM)

    cfg_driver_stress_off();
    cfg_driver_hold_ready(1,1);

    if (case_enabled("1")) run_cov1_smoke();
    if (case_enabled("2")) run_cov2_burst_len_size_sweep();
    if (case_enabled("3")) run_cov3_wstrb_stress();
    if (case_enabled("4")) run_cov4_boundary_edge_sweep();
    if (case_enabled("5")) run_cov5_ordering_suite();
    if (case_enabled("6")) run_cov6_ready_backpressure();
    if (case_enabled("7")) run_cov7_reset_injection();
    if (case_enabled("8")) run_cov8_completion_suite();

    `uvm_info("COVERAGE_TEST", "Coverage Test completed", UVM_MEDIUM)
    phase.drop_objection(this);
  endtask

endclass

`endif