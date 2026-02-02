// File: tb/uvm/test/axi_mm_random_test.sv
`ifndef AXI_MM_RANDOM_TEST_SV
`define AXI_MM_RANDOM_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

// ------------------------------------------------------------
// AXI-MM Random Stress Test (dual-port)
// PASS criteria: scoreboard mismatches==0 (SCB report_phase)
// ------------------------------------------------------------
class axi_mm_random_test extends uvm_test;

  `uvm_component_utils(axi_mm_random_test)

  // Fixed params
  localparam int ADDR_WIDTH = 32;
  localparam int DATA_WIDTH = 64;
  localparam int ID_WIDTH   = 4;

  // BRAM info (given by you)
  localparam int unsigned DEPTH_WORDS    = 1024;
  localparam int unsigned BYTES_PER_BEAT = (DATA_WIDTH/8);
  localparam int unsigned MEM_BYTES      = DEPTH_WORDS * BYTES_PER_BEAT; // 8192

  axi_mm_env #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) env_h;

  function new(string name = "axi_mm_random_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_h = axi_mm_env#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("env_h", this);
  endfunction

  // ------------------------------------------------------------
  // Configure BOTH drivers with same stress knobs
  // ------------------------------------------------------------
  task automatic cfg_driver_stress(
      input bit          stress_enable,
      input int unsigned stress_seed,

      input int unsigned bready_prob,
      input int unsigned rready_prob,

      input int unsigned aw_pre_delay_max,
      input int unsigned ar_pre_delay_max,

      input bit          w_streaming_mode,
      input int unsigned w_beat_gap_max,

      input int unsigned force_ready_after
  );
    uvm_config_db#(bit)::set(this, "env_h.p0_agent.drv", "stress_enable", stress_enable);
    uvm_config_db#(bit)::set(this, "env_h.p1_agent.drv", "stress_enable", stress_enable);

    // deterministic but different per port
    uvm_config_db#(int unsigned)::set(this, "env_h.p0_agent.drv", "stress_seed", stress_seed ^ 32'h0000_0000);
    uvm_config_db#(int unsigned)::set(this, "env_h.p1_agent.drv", "stress_seed", stress_seed ^ 32'h0000_0001);

    uvm_config_db#(int unsigned)::set(this, "env_h.p0_agent.drv", "bready_prob", bready_prob);
    uvm_config_db#(int unsigned)::set(this, "env_h.p1_agent.drv", "bready_prob", bready_prob);

    uvm_config_db#(int unsigned)::set(this, "env_h.p0_agent.drv", "rready_prob", rready_prob);
    uvm_config_db#(int unsigned)::set(this, "env_h.p1_agent.drv", "rready_prob", rready_prob);

    uvm_config_db#(int unsigned)::set(this, "env_h.p0_agent.drv", "aw_pre_delay_max", aw_pre_delay_max);
    uvm_config_db#(int unsigned)::set(this, "env_h.p1_agent.drv", "aw_pre_delay_max", aw_pre_delay_max);

    uvm_config_db#(int unsigned)::set(this, "env_h.p0_agent.drv", "ar_pre_delay_max", ar_pre_delay_max);
    uvm_config_db#(int unsigned)::set(this, "env_h.p1_agent.drv", "ar_pre_delay_max", ar_pre_delay_max);

    uvm_config_db#(bit)::set(this, "env_h.p0_agent.drv", "w_streaming_mode", w_streaming_mode);
    uvm_config_db#(bit)::set(this, "env_h.p1_agent.drv", "w_streaming_mode", w_streaming_mode);

    uvm_config_db#(int unsigned)::set(this, "env_h.p0_agent.drv", "w_beat_gap_max", w_beat_gap_max);
    uvm_config_db#(int unsigned)::set(this, "env_h.p1_agent.drv", "w_beat_gap_max", w_beat_gap_max);

    uvm_config_db#(int unsigned)::set(this, "env_h.p0_agent.drv", "force_ready_after", force_ready_after);
    uvm_config_db#(int unsigned)::set(this, "env_h.p1_agent.drv", "force_ready_after", force_ready_after);
  endtask

  // ------------------------------------------------------------
  // Baseline READY policy on both drivers
  // ------------------------------------------------------------
  task automatic cfg_driver_hold_ready(
      input bit hold_bready_high,
      input bit hold_rready_high
  );
    uvm_config_db#(bit)::set(this, "env_h.p0_agent.drv", "hold_bready_high", hold_bready_high);
    uvm_config_db#(bit)::set(this, "env_h.p1_agent.drv", "hold_bready_high", hold_bready_high);

    uvm_config_db#(bit)::set(this, "env_h.p0_agent.drv", "hold_rready_high", hold_rready_high);
    uvm_config_db#(bit)::set(this, "env_h.p1_agent.drv", "hold_rready_high", hold_rready_high);
  endtask

  // ------------------------------------------------------------
  // Run one dual-port random case (single latest version)
  //
  // This version is "future-proof": pass all knobs explicitly.
  // Older cases (R3~R8) you can later update to add missing args.
  //
  // Assumes axi_mm_seq has these fields:
  //   directed_mode, num_transactions, max_beats, read_percent, addr_aligned
  //   restrict_addr_window, window_base, window_bytes
  //   enable_size_rand, enable_partial_wstrb, enable_fixed, enable_wrap
  //   wrap_prob
  //   enable_locality, locality_prob
  //   restrict_to_mem, mem_bytes
  // ------------------------------------------------------------
  task automatic run_case_dual_port(
    input string                 case_name,

    // traffic knobs
    input int unsigned           num_tx_p0,
    input int unsigned           num_tx_p1,
    input int unsigned           max_beats_p0,
    input int unsigned           max_beats_p1,
    input int unsigned           read_percent_p0,
    input int unsigned           read_percent_p1,
    input bit                    addr_aligned_p0,
    input bit                    addr_aligned_p1,

    // window knobs
    input bit                    window_en,
    input logic [ADDR_WIDTH-1:0] win_base_p0,
    input logic [ADDR_WIDTH-1:0] win_base_p1,
    input int unsigned           win_bytes_p0,
    input int unsigned           win_bytes_p1,

    // feature knobs
    input bit                    enable_size_rand,
    input bit                    enable_partial_wstrb,
    input bit                    enable_fixed,
    input bit                    enable_wrap,

    // WRAP behavior knobs
    input int unsigned           wrap_prob,        // 0 - 100

    // PARTIAL behavior knobs
    input int unsigned           partial_prob,     // 0 - 100

    // locality knobs
    input bit                    enable_locality,
    input int unsigned           locality_prob     // 0 - 100
  );
    axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) seq0;
    axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) seq1;

    int unsigned wp;
    int unsigned pp;
    int unsigned lp;

    wp = (wrap_prob    > 100) ? 100 : wrap_prob;
    pp = (partial_prob > 100) ? 100 : partial_prob;
    lp = (locality_prob> 100) ? 100 : locality_prob;

    `uvm_info("RANDOM_TEST",
      $sformatf(
        "=== %s: start | tx p0/p1=%0d/%0d max_beats p0/p1=%0d/%0d read%% p0/p1=%0d/%0d aligned p0/p1=%0d/%0d 
        window=%0d (p0:0x%0h+%0d p1:0x%0h+%0d) 
        size_rand=%0d partial_en=%0d fixed=%0d wrap=%0d wrap_prob=%0d partial_prob=%0d 
        locality_en=%0d locality_prob=%0d ===",
        case_name,
        num_tx_p0, num_tx_p1,
        max_beats_p0, max_beats_p1,
        read_percent_p0, read_percent_p1,
        addr_aligned_p0, addr_aligned_p1,
        window_en, win_base_p0, win_bytes_p0, win_base_p1, win_bytes_p1,
        enable_size_rand, enable_partial_wstrb, enable_fixed, enable_wrap, wp, pp,
        enable_locality, lp),
      UVM_MEDIUM)

    seq0 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create({case_name, "_seq0"});
    seq1 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create({case_name, "_seq1"});

    // ------------------------------------------------------------
    // Lock the knobs we set from the test
    // ------------------------------------------------------------
    seq0.num_transactions.rand_mode(0);
    seq0.max_beats.rand_mode(0);
    seq0.read_percent.rand_mode(0);
    seq0.addr_aligned.rand_mode(0);

    seq0.restrict_addr_window.rand_mode(0);
    seq0.window_base.rand_mode(0);
    seq0.window_bytes.rand_mode(0);

    seq0.enable_size_rand.rand_mode(0);
    seq0.enable_partial_wstrb.rand_mode(0);
    seq0.partial_prob.rand_mode(0);        
    seq0.enable_fixed.rand_mode(0);
    seq0.enable_wrap.rand_mode(0);
    seq0.wrap_prob.rand_mode(0);

    seq0.enable_locality.rand_mode(0);
    seq0.locality_prob.rand_mode(0);

    seq0.restrict_to_mem.rand_mode(0);
    seq0.mem_bytes.rand_mode(0);

    // same for seq1
    seq1.num_transactions.rand_mode(0);
    seq1.max_beats.rand_mode(0);
    seq1.read_percent.rand_mode(0);
    seq1.addr_aligned.rand_mode(0);

    seq1.restrict_addr_window.rand_mode(0);
    seq1.window_base.rand_mode(0);
    seq1.window_bytes.rand_mode(0);

    seq1.enable_size_rand.rand_mode(0);
    seq1.enable_partial_wstrb.rand_mode(0);
    seq1.partial_prob.rand_mode(0);          // NEW
    seq1.enable_fixed.rand_mode(0);
    seq1.enable_wrap.rand_mode(0);
    seq1.wrap_prob.rand_mode(0);

    seq1.enable_locality.rand_mode(0);
    seq1.locality_prob.rand_mode(0);

    seq1.restrict_to_mem.rand_mode(0);
    seq1.mem_bytes.rand_mode(0);

    // -----------------------
    // Traffic knobs
    // -----------------------
    seq0.directed_mode    = 0;
    seq0.num_transactions = num_tx_p0;
    seq0.max_beats        = max_beats_p0;
    seq0.read_percent     = read_percent_p0;
    seq0.addr_aligned     = addr_aligned_p0;

    seq1.directed_mode    = 0;
    seq1.num_transactions = num_tx_p1;
    seq1.max_beats        = max_beats_p1;
    seq1.read_percent     = read_percent_p1;
    seq1.addr_aligned     = addr_aligned_p1;

    // ------------------------------------------------------------
    // ALWAYS clamp into BRAM range (even when using window)
    // ------------------------------------------------------------
    seq0.restrict_to_mem = 1;
    seq1.restrict_to_mem = 1;
    seq0.mem_bytes       = MEM_BYTES;
    seq1.mem_bytes       = MEM_BYTES;

    // -----------------------
    // Window split
    // -----------------------
    seq0.restrict_addr_window = window_en;
    seq1.restrict_addr_window = window_en;

    seq0.window_base  = win_base_p0;
    seq1.window_base  = win_base_p1;
    seq0.window_bytes = win_bytes_p0;
    seq1.window_bytes = win_bytes_p1;

    // -----------------------
    // Feature knobs
    // -----------------------
    seq0.enable_size_rand     = enable_size_rand;
    seq1.enable_size_rand     = enable_size_rand;

    seq0.enable_partial_wstrb = enable_partial_wstrb;
    seq1.enable_partial_wstrb = enable_partial_wstrb;
    seq0.partial_prob         = pp;          
    seq1.partial_prob         = pp;          

    seq0.enable_fixed         = enable_fixed;
    seq1.enable_fixed         = enable_fixed;

    seq0.enable_wrap          = enable_wrap;
    seq1.enable_wrap          = enable_wrap;

    // WRAP probability (only meaningful if enable_wrap=1)
    seq0.wrap_prob            = wp;
    seq1.wrap_prob            = wp;

    // Locality
    seq0.enable_locality      = enable_locality;
    seq1.enable_locality      = enable_locality;
    seq0.locality_prob        = lp;
    seq1.locality_prob        = lp;

    // Debug: print what seq really has
    `uvm_info("RANDOM_TEST",
      $sformatf("%s SEQ0: win_en=%0d base=0x%0h bytes=%0d mem_en=%0d mem_bytes=%0d wrap_en=%0d wrap_prob=%0d partial_en=%0d partial_prob=%0d loc=%0d/%0d",
        case_name,
        seq0.restrict_addr_window, seq0.window_base, seq0.window_bytes,
        seq0.restrict_to_mem, seq0.mem_bytes,
        seq0.enable_wrap, seq0.wrap_prob,
        seq0.enable_partial_wstrb, seq0.partial_prob,
        seq0.enable_locality, seq0.locality_prob),
      UVM_MEDIUM)

    `uvm_info("RANDOM_TEST",
      $sformatf("%s SEQ1: win_en=%0d base=0x%0h bytes=%0d mem_en=%0d mem_bytes=%0d wrap_en=%0d wrap_prob=%0d partial_en=%0d partial_prob=%0d loc=%0d/%0d",
        case_name,
        seq1.restrict_addr_window, seq1.window_base, seq1.window_bytes,
        seq1.restrict_to_mem, seq1.mem_bytes,
        seq1.enable_wrap, seq1.wrap_prob,
        seq1.enable_partial_wstrb, seq1.partial_prob,
        seq1.enable_locality, seq1.locality_prob),
      UVM_MEDIUM)

    fork
      begin
        seq0.start(env_h.p0_agent.seqr);
      end
      begin
        #1ns;
        seq1.start(env_h.p1_agent.seqr);
      end
    join

    #200ns;

    `uvm_info("RANDOM_TEST", $sformatf("=== %s: done ===", case_name), UVM_MEDIUM)
  endtask



  // ------------------------------------------------------------
  // Run phase
  // ------------------------------------------------------------
  virtual task run_phase(uvm_phase phase);

    int unsigned base_seed;

    // Split address space into two independent windows (8KB total)
    // Window 0: 0x0000_0000 .. 0x0000_0FFF (4096B)
    // Window 1: 0x0000_1000 .. 0x0000_1FFF (4096B)
    logic [ADDR_WIDTH-1:0] WIN0_BASE;
    logic [ADDR_WIDTH-1:0] WIN1_BASE;
    int unsigned           WIN_BYTES;

    base_seed = 32'h2026_0128;
    WIN0_BASE = 32'h0000_0000;
    WIN1_BASE = 32'h0000_1000;
    WIN_BYTES = 4096;

    phase.raise_objection(this);

    `uvm_info("RANDOM_TEST", $sformatf("Starting AXI-MM Random Stress Test (dual-port). BRAM MEM_BYTES=%0d (DEPTH_WORDS=%0d DATA_WIDTH=%0d)", MEM_BYTES, DEPTH_WORDS, DATA_WIDTH), UVM_MEDIUM)

    // // ----------------------------------------------------------------
    // // Case 1: Baseline (no stress), split window
    // // ----------------------------------------------------------------
    // cfg_driver_hold_ready(1, 1);
    // cfg_driver_stress(
    //   /*stress_enable*/     1,
    //   /*seed*/              base_seed ^ 32'h0000_0002,
    //   /*bready_prob*/       100,     
    //   /*rready_prob*/       100,     
    //   /*aw_pre_delay_max*/  0,
    //   /*ar_pre_delay_max*/  0,
    //   /*w_streaming_mode*/  0,
    //   /*w_beat_gap_max*/    0,     
    //   /*force_ready_after*/ 64     
    // );

    // run_case_dual_port("CASE_1_BASELINE_SPLIT",
    //   // traffic knobs
    //   2000, 2000,
    //   8,   8,
    //   50,   50,
    //   1,    1,
    //   // window knobs
    //   1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
    //   0, 1, 1, 0
    //   // WRAP behavior knobs
    //   0,
    //   0,
    //   // locality knobs
    //   0,
    //   0  

    // // ----------------------------------------------------------------
    // // Case 2: W streaming + gaps + split window
    // // ----------------------------------------------------------------
    // cfg_driver_hold_ready(1, 1);
    // cfg_driver_stress(
    //   /*stress_enable*/     1,
    //   /*seed*/              base_seed ^ 32'h0000_0002,
    //   /*bready_prob*/       100,     
    //   /*rready_prob*/       100,     
    //   /*aw_pre_delay_max*/  0,
    //   /*ar_pre_delay_max*/  0,
    //   /*w_streaming_mode*/  1,
    //   /*w_beat_gap_max*/    2,     
    //   /*force_ready_after*/ 64     
    // );

    // run_case_dual_port("CASE_2_W_STREAM_GAPS_SPLIT",
    //   // traffic knobs
    //   3000, 3000,
    //   16,   16,
    //   50,   50,
    //   1,    1,
    //   // window knobs
    //   1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
    //   0, 1, 1, 0
    //   // WRAP behavior knobs
    //   0,
    //   0,
    //   // locality knobs
    //   0,
    //   0   
    // );

    // // ----------------------------------------------------------------
    // // Case 3: Backpressure (toggle BREADY/RREADY)
    // // ----------------------------------------------------------------
    // cfg_driver_hold_ready(0, 0);
    // cfg_driver_stress(
    //   /*stress_enable*/     1,
    //   /*seed*/              base_seed ^ 32'h0000_0003,
    //   /*bready_prob*/       50,     // heavy-ish backpressure
    //   /*rready_prob*/       50,     // heavy-ish backpressure
    //   /*aw_pre_delay_max*/  0,
    //   /*ar_pre_delay_max*/  0,
    //   /*w_streaming_mode*/  1,
    //   /*w_beat_gap_max*/    2,      
    //   /*force_ready_after*/ 64     
    // );

    // run_case_dual_port("CASE_3_BACKPRESSURE_SPLIT",
    //   // traffic knobs
    //   3000, 3000,
    //   16,   16,
    //   50,   50,
    //   1,    1,
    //   // window knobs
    //   1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
    //   0, 1, 1, 0
    //   // WRAP behavior knobs
    //   0,
    //   0,
    //   // locality knobs
    //   0,
    //   0   
    // );

    // // ----------------------------------------------------------------
    // // Case 4: Heavy BACKPRESSURE (split window)
    // // - hold_*_high=0 so probs actually toggle ready
    // // - Enable streaming mode (closer to real AXI master behavior)
    // // - Use small gaps initially to avoid obscuring root causes
    // // ----------------------------------------------------------------
    // cfg_driver_hold_ready(0, 0);
    // cfg_driver_stress(
    //   /*stress_enable*/     1,
    //   /*seed*/              base_seed ^ 32'h0000_0004,
    //   /*bready_prob*/       40,     // 40% ready
    //   /*rready_prob*/       40,     // 40% ready
    //   /*aw_pre_delay_max*/  0,
    //   /*ar_pre_delay_max*/  0,
    //   /*w_streaming_mode*/  1,
    //   /*w_beat_gap_max*/    1,      // tiny random gaps
    //   /*force_ready_after*/ 128     // more tolerant for heavy BP
    // );

    // run_case_dual_port("CASE_4_BACKPRESSURE_SPLIT",
    //   // traffic knobs
    //   6000, 6000,
    //   16,   16,
    //   50,   50,
    //   1,    1,
    //   // windos knobs
    //   1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
    //   // feature knobs
    //   0, 1, 1, 0
    //   // WRAP behavior knobs
    //   0,
    //   0,
    //   // locality knobs
    //   0,
    //   0       
    // );

    // // ----------------------------------------------------------------
    // // Case 5: TIMING JITTER + gaps (split window)
    // // - Add AW/AR pre-delay
    // // - Increase W gaps
    // // - Slightly raise ready_prob to avoid overly extreme jitter + heavy backpressure at the same time
    // // ----------------------------------------------------------------
    // cfg_driver_hold_ready(0, 0);
    // cfg_driver_stress(
    //   /*stress_enable*/     1,
    //   /*seed*/              base_seed ^ 32'h0000_0005,
    //   /*bready_prob*/       70,
    //   /*rready_prob*/       70,
    //   /*aw_pre_delay_max*/  25,     // random delay before AWVALID
    //   /*ar_pre_delay_max*/  25,     // random delay before ARVALID
    //   /*w_streaming_mode*/  1,
    //   /*w_beat_gap_max*/    8,      // bigger jitter inside burst
    //   /*force_ready_after*/ 128
    // );

    // run_case_dual_port("CASE_5_TIMING_JITTER_SPLIT",
    //   // traffic knobs
    //   8000, 8000,
    //   16,   16,
    //   50,   50,
    //   1,    1,
    //   // window knobs
    //   1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
    //   // feature knobs
    //   0, 1, 1, 0
    //   // WRAP behavior knobs 
    //   0,
    //   0,
    //   // locality knobs
    //   0,
    //   0       
    // );

    // // ----------------------------------------------------------------
    // // Case 6: SOAK (split window)
    // // - Long-running with moderate stress
    // // - Primarily to catch rare corner cases
    // // ----------------------------------------------------------------
    // cfg_driver_hold_ready(0, 0);
    // cfg_driver_stress(
    //   /*stress_enable*/     1,
    //   /*seed*/              base_seed ^ 32'h0000_0006,
    //   /*bready_prob*/       85,
    //   /*rready_prob*/       85,
    //   /*aw_pre_delay_max*/  5,
    //   /*ar_pre_delay_max*/  5,
    //   /*w_streaming_mode*/  1,
    //   /*w_beat_gap_max*/    2,
    //   /*force_ready_after*/ 128
    // );

    // run_case_dual_port("CASE_6_SOAK_SPLIT",
    //   // traffic knobs
    //   20000, 20000,
    //   16,    16,
    //   50,    50,
    //   1,     1,
    //   // window knobs
    //   1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
    //   // feature knobs
    //   1, 1, 0, 0
    //   // WRAP behavior knobs
    //   0,
    //   0,
    //   // locality knobs
    //   0,
    //   0       
    // );

    // // ----------------------------------------------------------------
    // // Case 7: FIXED burst (split window)
    // // - Medium stress to verify protocol/addr bookkeeping
    // // - No WRAP yet
    // // - partial/size_rand off to isolate FIXED
    // // ----------------------------------------------------------------
    // cfg_driver_hold_ready(0, 0);
    // cfg_driver_stress(
    // /*stress_enable*/     1,
    // /*seed*/              base_seed ^ 32'h0000_0007,
    // /*bready_prob*/       80,
    // /*rready_prob*/       80,
    // /*aw_pre_delay_max*/  5,
    // /*ar_pre_delay_max*/  5,
    // /*w_streaming_mode*/  1,
    // /*w_beat_gap_max*/    2,
    // /*force_ready_after*/ 128
    // );

    // run_case_dual_port("CASE_7_FIXED_SPLIT",
    //   // traffic knobs
    //   12000, 12000,
    //   16,    16,
    //   50,    50,
    //   1,     1,
    //   // window knobs
    //   1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
    //   // feature knobs
    //   0, 0, 1, 0
    //   // WRAP behavior knobs
    //   0,
    //   0,
    //   // locality knobs
    //   0,
    //   0       
    // );

    // // ----------------------------------------------------------------
    // // Case 8: WRAP + INCR (split window) - MIX + STRESS
    // // - Goal: true R8 — validate under mixed WRAP/INCR traffic:
    // //   1. Model consistency of WRAP foldback and INCR linear advance
    // //   2. Monitor + SCB address expansion remains correct under
    // //      backpressure / gap / jitter
    // // - Compared to R8b: WRAP no longer dominates; INCR has sufficient coverage
    // // ----------------------------------------------------------------
    // cfg_driver_hold_ready(0, 0);
    // cfg_driver_stress(
    //   /*stress_enable*/     1,
    //   /*seed*/              base_seed ^ 32'h0000_5454,
    //   /*bready_prob*/       60,
    //   /*rready_prob*/       60,
    //   /*aw_pre_delay_max*/  6,
    //   /*ar_pre_delay_max*/  6,
    //   /*w_streaming_mode*/  1,
    //   /*w_beat_gap_max*/    4,
    //   /*force_ready_after*/ 256
    // );

    // run_case_dual_port("CASE_8_WRAP_SPLIT_MIX_STRESS",
    //   // traffic knobs
    //   8000, 8000,     
    //   16,   16,       // max_beats=16
    //   50,   50,
    //   1,    1,
    //   // window knobs
    //   1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
    //   // feature knobs
    //   0, 0, 0, 1,     // size_rand=0, partial=0, fixed=0, wrap=1 
    //   // WRAP behavior knobs
    //   30,             // wrap_prob: Recommend 30~40 
    //   0,
    //   // locality knobs
    //   1,              // enable_locality: Keep for hazard/interleaving
    //   50              // locality_prob: Recommend 40~60
    // );

    // // ----------------------------------------------------------------
    // // Case 9: SIZE RAND (split window) - mixed stress
    // // - Goal: validate address stepping, alignment, and SCB model consistency for sizes 0..3 (1/2/4/8B)
    // // - Keep some WRAP ratio to ensure size_rand + wrap interaction doesn't break
    // // - Medium stress: ready 65%, moderate delay/gap
    // // ----------------------------------------------------------------
    // cfg_driver_hold_ready(0, 0);
    // cfg_driver_stress(
    //   /*stress_enable*/     1,
    //   /*seed*/              base_seed ^ 32'h0000_BEEF,
    //   /*bready_prob*/       65,
    //   /*rready_prob*/       65,
    //   /*aw_pre_delay_max*/  4,
    //   /*ar_pre_delay_max*/  4,
    //   /*w_streaming_mode*/  1,
    //   /*w_beat_gap_max*/    2,
    //   /*force_ready_after*/ 192
    // );

    // run_case_dual_port("CASE_9_SIZE_RAND_SPLIT_MIX",
    //   // traffic knobs
    //   8000, 8000,
    //   16,   16,
    //   50,   50,
    //   1,    1,        // addr_aligned=1
    //   // window knobs
    //   1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
    //   // feature knobs
    //   1, 0, 0, 1,     // enable_size_rand=1, partial=0, fixed=0, wrap=1
    //   // WRAP behavior knobs
    //   35,             // wrap_prob: keep enabled but not dominant (avoid tests becoming mostly WRAP)
    //   0,
    //   // locality knobs
    //   1,
    //   55
    // );

    // ----------------------------------------------------------------
    // Case 10: PARTIAL WSTRB (split window) - write-heavy + stress
    // - Goal：Large partial byte-enable write + interleaving, verify SCB byte mask model
    // - Disable size randomization (fixed 8B)
    // - This avoids excessive legality and scoreboard complexity
    // - Med-high pressure：ready 60%, wider gap, higher trading volume, higher write ratio
    // ----------------------------------------------------------------
    cfg_driver_hold_ready(0, 0);
    cfg_driver_stress(
      /*stress_enable*/     1,
      /*seed*/              base_seed ^ 32'h0000_ABCD,
      /*bready_prob*/       60,
      /*rready_prob*/       60,
      /*aw_pre_delay_max*/  6,
      /*ar_pre_delay_max*/  6,
      /*w_streaming_mode*/  1,
      /*w_beat_gap_max*/    4,
      /*force_ready_after*/ 256
    );

    run_case_dual_port("CASE_10_PARTIAL_WSTRB_SPLIT_STRESS",
      // traffic knobs
      9000, 9000,
      16,   16,
      35,   35,       // lower read_percent, allow more writes (so partial makes sense)
      1,    1,
      // window knobs
      1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
      // feature knobs
      0, 1, 0, 1,     // size_rand=0, partial=1, fixed=0, wrap=1 (keep some wrap)
      // WRAP behavior knobs
      25,             // small only, partial is the main feature
      90,             // partial_prob
      // locality knobs
      1,
      70
    );

    `uvm_info("RANDOM_TEST", "Random Stress Test completed (check SCB FINAL RESULT for PASS/FAIL).", UVM_MEDIUM)

    phase.drop_objection(this);
  endtask

endclass : axi_mm_random_test

`endif
