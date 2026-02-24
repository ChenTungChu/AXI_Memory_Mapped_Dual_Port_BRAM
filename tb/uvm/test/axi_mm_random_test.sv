// File: tb/uvm/test/axi_mm_random_test.sv
`ifndef AXI_MM_RANDOM_TEST_SV
`define AXI_MM_RANDOM_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

// ------------------------------------------------------------
// AXI-MM Random Stress Test (dual-port)  [REGRESSION GATE v1]
// PASS criteria: scoreboard mismatches==0 (SCB report_phase)
// Adds:
//   - +PROFILE=BP_LOW|OOO_HIGH|MIX_CHAOS|SOAK_LONG
//   - +GATE=1  (run all 4 profiles sequentially in one sim)
//   - watchdog timeout (default per profile, override by +GATE_TIMEOUT_NS=<ns>)
// Keeps legacy:
//   - +CASE=10 / +CASELIST=...
//   - default legacy behavior: run "10" only if no args
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
  // Plusarg helpers
  // ------------------------------------------------------------
  function automatic string get_plusarg_str(string key);
    string v;
    if ($value$plusargs({key, "=%s"}, v)) return v;
    return "";
  endfunction

  function automatic bit get_plusarg_bit(string key);
    // +KEY (no '=') style
    if ($test$plusargs(key)) return 1;
    return 0;
  endfunction

  function automatic int unsigned get_plusarg_uint(string key, int unsigned default_v);
    int unsigned v;
    if ($value$plusargs({key, "=%d"}, v)) return v;
    return default_v;
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

  // ------------------------------------------------------------
  // Legacy +CASE / +CASELIST selection
  // ------------------------------------------------------------
  function automatic bit case_enabled(string tag);
    string one, list;
    one  = get_plusarg_str("CASE");
    list = get_plusarg_str("CASELIST");

    // Run all
    if (one == "all") return 1;

    // Single selection
    if (one != "") return (one == tag);

    // List selection (comma separated)
    if (list != "") begin
      string tmp;
      tmp = {",", list, ","};
      return (str_find(tmp, {",", tag, ","}) != -1);
    end

    // Default behavior if user didn't pass args:
    return (tag == "10");
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
  // Run one dual-port random case (UNCHANGED core)
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

    wp = (wrap_prob     > 100) ? 100 : wrap_prob;
    pp = (partial_prob  > 100) ? 100 : partial_prob;
    lp = (locality_prob > 100) ? 100 : locality_prob;

    `uvm_info("RANDOM_TEST",
      $sformatf(
        "=== %s: start | tx p0/p1=%0d/%0d max_beats p0/p1=%0d/%0d read%% p0/p1=%0d/%0d aligned p0/p1=%0d/%0d window=%0d (p0:0x%0h+%0d p1:0x%0h+%0d) size_rand=%0d partial_en=%0d fixed=%0d wrap=%0d wrap_prob=%0d partial_prob=%0d locality_en=%0d locality_prob=%0d ===",
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

    // Lock knobs from test
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
    seq1.partial_prob.rand_mode(0);
    seq1.enable_fixed.rand_mode(0);
    seq1.enable_wrap.rand_mode(0);
    seq1.wrap_prob.rand_mode(0);

    seq1.enable_locality.rand_mode(0);
    seq1.locality_prob.rand_mode(0);

    seq1.restrict_to_mem.rand_mode(0);
    seq1.mem_bytes.rand_mode(0);

    // Traffic knobs
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

    // ALWAYS clamp into BRAM range
    seq0.restrict_to_mem = 1;
    seq1.restrict_to_mem = 1;
    seq0.mem_bytes       = MEM_BYTES;
    seq1.mem_bytes       = MEM_BYTES;

    // Window split
    seq0.restrict_addr_window = window_en;
    seq1.restrict_addr_window = window_en;

    seq0.window_base  = win_base_p0;
    seq1.window_base  = win_base_p1;
    seq0.window_bytes = win_bytes_p0;
    seq1.window_bytes = win_bytes_p1;

    // Feature knobs
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

    seq0.wrap_prob            = wp;
    seq1.wrap_prob            = wp;

    seq0.enable_locality      = enable_locality;
    seq1.enable_locality      = enable_locality;
    seq0.locality_prob        = lp;
    seq1.locality_prob        = lp;

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
  // Watchdog wrapper: run a case with timeout protection
  // ------------------------------------------------------------
  task automatic run_case_with_watchdog(
    input string case_name,
    input time   timeout_ns,

    // pass-through args to run_case_dual_port
    input int unsigned           num_tx_p0,
    input int unsigned           num_tx_p1,
    input int unsigned           max_beats_p0,
    input int unsigned           max_beats_p1,
    input int unsigned           read_percent_p0,
    input int unsigned           read_percent_p1,
    input bit                    addr_aligned_p0,
    input bit                    addr_aligned_p1,

    input bit                    window_en,
    input logic [ADDR_WIDTH-1:0] win_base_p0,
    input logic [ADDR_WIDTH-1:0] win_base_p1,
    input int unsigned           win_bytes_p0,
    input int unsigned           win_bytes_p1,

    input bit                    enable_size_rand,
    input bit                    enable_partial_wstrb,
    input bit                    enable_fixed,
    input bit                    enable_wrap,
    input int unsigned           wrap_prob,
    input int unsigned           partial_prob,
    input bit                    enable_locality,
    input int unsigned           locality_prob
  );
    bit done;
    done = 0;

    fork
      begin : RUN_MAIN
        run_case_dual_port(case_name,
          num_tx_p0, num_tx_p1,
          max_beats_p0, max_beats_p1,
          read_percent_p0, read_percent_p1,
          addr_aligned_p0, addr_aligned_p1,
          window_en, win_base_p0, win_base_p1, win_bytes_p0, win_bytes_p1,
          enable_size_rand, enable_partial_wstrb, enable_fixed, enable_wrap,
          wrap_prob, partial_prob,
          enable_locality, locality_prob
        );
        done = 1;
      end

      begin : RUN_WD
        #(timeout_ns * 1ns);
        if (!done) begin
          `uvm_fatal("TIMEOUT",
            $sformatf("Watchdog timeout hit in %s after %0t ns. (Use +GATE_TIMEOUT_NS=<ns> to override)",
              case_name, timeout_ns))
        end
      end
    join_any

    disable fork;
  endtask

  // ------------------------------------------------------------
  // Gate profile runner (Regression Gate v1)
  // ------------------------------------------------------------
  task automatic run_gate_profile(
    input string profile_name,
    input int unsigned base_seed,
    input logic [ADDR_WIDTH-1:0] WIN0_BASE,
    input logic [ADDR_WIDTH-1:0] WIN1_BASE,
    input int unsigned WIN_BYTES,
    input time timeout_ns_override
  );
    time tmo_ns;

    // default timeout per profile (can be overridden)
    if (timeout_ns_override != 0) begin
      tmo_ns = timeout_ns_override;
    end else begin
      if (profile_name == "SOAK_LONG")      tmo_ns = 400_000_000; // 400ms (ns units)
      else                                 tmo_ns = 120_000_000; // 120ms
    end

    `uvm_info("RANDOM_GATE",
      $sformatf("=== RANDOM GATE v1 profile=%s timeout_ns=%0t ===", profile_name, tmo_ns),
      UVM_MEDIUM)

    // -------- Profile definitions (fixed knobs) --------
    if (profile_name == "BP_LOW") begin
      // Heavy backpressure, partial+wrap+locality ON (your proven case10-like)
      cfg_driver_hold_ready(0, 0);
      cfg_driver_stress(
        1,
        base_seed ^ 32'hBFE0_0001,
        10,  // bready_prob
        10,  // rready_prob
        6,   // aw_pre_delay_max
        6,   // ar_pre_delay_max
        1,   // w_streaming_mode
        4,   // w_beat_gap_max
        256  // force_ready_after
      );

      run_case_with_watchdog("GATE_BP_LOW",
        tmo_ns,
        9000, 9000,
        16,   16,
        35,   35,
        1,    1,
        1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
        0, 1, 0, 1,
        25,
        90,
        1,
        70
      );
    end
    else if (profile_name == "OOO_HIGH") begin
      // High throughput, moderate ready, enable size_rand+wrap to create variety
      cfg_driver_hold_ready(0, 0);
      cfg_driver_stress(
        1,
        base_seed ^ 32'h0FF0_0002,
        70,  // bready_prob
        70,  // rready_prob
        2,   // aw_pre_delay_max
        2,   // ar_pre_delay_max
        1,   // w_streaming_mode
        2,   // w_beat_gap_max
        128  // force_ready_after
      );

      run_case_with_watchdog("GATE_OOO_HIGH",
        tmo_ns,
        12000, 12000,
        16,    16,
        50,    50,
        1,     1,
        1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
        1, 0, 0, 1,
        35,
        0,
        1,
        55
      );
    end
    else if (profile_name == "MIX_CHAOS") begin
      // Mixed chaos: size_rand + partial + fixed + wrap + locality
      cfg_driver_hold_ready(0, 0);
      cfg_driver_stress(
        1,
        base_seed ^ 32'hC4A0_0003,
        40,  // bready_prob
        40,  // rready_prob
        12,  // aw_pre_delay_max
        12,  // ar_pre_delay_max
        1,   // w_streaming_mode
        6,   // w_beat_gap_max
        256  // force_ready_after
      );

      run_case_with_watchdog("GATE_MIX_CHAOS",
        tmo_ns,
        10000, 10000,
        16,    16,
        50,    50,
        1,     1,
        1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
        1, 1, 1, 1,
        30,
        50,
        1,
        60
      );
    end
    else if (profile_name == "SOAK_LONG") begin
      // Long soak: huge ops + heavy BP, keep features on to hit rare combos
      cfg_driver_hold_ready(0, 0);
      cfg_driver_stress(
        1,
        base_seed ^ 32'h504B_0004,
        10,  // bready_prob
        10,  // rready_prob
        6,   // aw_pre_delay_max
        6,   // ar_pre_delay_max
        1,   // w_streaming_mode
        4,   // w_beat_gap_max
        256  // force_ready_after
      );

      run_case_with_watchdog("GATE_SOAK_LONG",
        tmo_ns,
        50000, 50000,
        16,    16,
        45,    45,
        1,     1,
        1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
        1, 1, 1, 1,
        35,
        70,
        1,
        70
      );
    end
    else begin
      `uvm_fatal("BAD_PROFILE",
        $sformatf("Unknown +PROFILE=%s. Allowed: BP_LOW|OOO_HIGH|MIX_CHAOS|SOAK_LONG (or use +GATE=1)", profile_name))
    end

    `uvm_info("RANDOM_GATE",
      $sformatf("=== RANDOM GATE v1 profile=%s DONE ===", profile_name),
      UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Run phase
  // ------------------------------------------------------------
  virtual task run_phase(uvm_phase phase);

    int unsigned base_seed;
    string profile;
    bit do_gate;
    time gate_timeout_ns;

    // Split address space into two independent windows (8KB total)
    // Window 0: 0x0000_0000 .. 0x0000_0FFF (4096B)
    // Window 1: 0x0000_1000 .. 0x0000_1FFF (4096B)
    logic [ADDR_WIDTH-1:0] WIN0_BASE;
    logic [ADDR_WIDTH-1:0] WIN1_BASE;
    int unsigned           WIN_BYTES;

    // seed base (your original)
    base_seed = 32'h2026_0128;

    // allow overriding base seed via +BASE_SEED=<dec> (optional)
    base_seed = get_plusarg_uint("BASE_SEED", base_seed);

    profile = get_plusarg_str("PROFILE");
    do_gate = get_plusarg_bit("GATE");
    gate_timeout_ns = get_plusarg_uint("GATE_TIMEOUT_NS", 0);

    WIN0_BASE = 32'h0000_0000;
    WIN1_BASE = 32'h0000_1000;
    WIN_BYTES = 4096;

    phase.raise_objection(this);

    `uvm_info("RANDOM_TEST",
      $sformatf("Starting AXI-MM Random Stress Test (dual-port). BRAM MEM_BYTES=%0d (DEPTH_WORDS=%0d DATA_WIDTH=%0d) PROFILE=%s GATE=%0d CASE=%s CASELIST=%s BASE_SEED=0x%0h TIMEOUT_NS=%0d",
        MEM_BYTES, DEPTH_WORDS, DATA_WIDTH, profile, do_gate,
        get_plusarg_str("CASE"), get_plusarg_str("CASELIST"), base_seed, gate_timeout_ns),
      UVM_MEDIUM)

    // ------------------------------------------------------------
    // REGRESSION GATE path:
    //   +GATE=1 : run all 4 profiles in one sim
    //   +PROFILE=<name> : run that single profile
    // ------------------------------------------------------------
    if (do_gate) begin
      run_gate_profile("BP_LOW",     base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES, gate_timeout_ns);
      run_gate_profile("OOO_HIGH",   base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES, gate_timeout_ns);
      run_gate_profile("MIX_CHAOS",  base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES, gate_timeout_ns);
      run_gate_profile("SOAK_LONG",  base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES, gate_timeout_ns);
      `uvm_info("RANDOM_GATE", "=== RANDOM GATE v1: ALL PROFILES DONE ===", UVM_MEDIUM)
    end
    else if (profile != "") begin
      run_gate_profile(profile, base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES, gate_timeout_ns);
      `uvm_info("RANDOM_GATE", "=== RANDOM GATE v1: SINGLE PROFILE DONE ===", UVM_MEDIUM)
    end
    else begin
      // ------------------------------------------------------------
      // Legacy cases (your original behavior)
      // ------------------------------------------------------------

      // Case 1: Baseline (no stress), split window
      if (case_enabled("1")) begin
        cfg_driver_hold_ready(1, 1);
        cfg_driver_stress(
          1,
          base_seed ^ 32'h0000_0002,
          100, 100,
          0,   0,
          0,   0,
          64
        );

        run_case_dual_port("CASE_1_BASELINE_SPLIT",
          2000, 2000,
          8,    8,
          50,   50,
          1,    1,
          1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
          0, 1, 1, 0,
          0,
          0,
          0,
          0
        );
      end

      // Case 2: W streaming + gaps + split window
      if (case_enabled("2")) begin
        cfg_driver_hold_ready(1, 1);
        cfg_driver_stress(
          1,
          base_seed ^ 32'h0000_0002,
          100, 100,
          0,   0,
          1,   2,
          64
        );

        run_case_dual_port("CASE_2_W_STREAM_GAPS_SPLIT",
          3000, 3000,
          16,   16,
          50,   50,
          1,    1,
          1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
          0, 1, 1, 0,
          0,
          0,
          0,
          0
        );
      end

      // Case 3: Backpressure (toggle BREADY/RREADY)
      if (case_enabled("3")) begin
        cfg_driver_hold_ready(0, 0);
        cfg_driver_stress(
          1,
          base_seed ^ 32'h0000_0003,
          50, 50,
          0,  0,
          1,  2,
          64
        );

        run_case_dual_port("CASE_3_BACKPRESSURE_SPLIT",
          3000, 3000,
          16,   16,
          50,   50,
          1,    1,
          1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
          0, 1, 1, 0,
          0,
          0,
          0,
          0
        );
      end

      // Case 4: Heavy BACKPRESSURE (split window)
      if (case_enabled("4")) begin
        cfg_driver_hold_ready(0, 0);
        cfg_driver_stress(
          1,
          base_seed ^ 32'h0000_0004,
          40, 40,
          0,  0,
          1,  1,
          128
        );

        run_case_dual_port("CASE_4_BACKPRESSURE_SPLIT",
          6000, 6000,
          16,   16,
          50,   50,
          1,    1,
          1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
          0, 1, 1, 0,
          0,
          0,
          0,
          0
        );
      end

      // Case 5: TIMING JITTER + gaps (split window)
      if (case_enabled("5")) begin
        cfg_driver_hold_ready(0, 0);
        cfg_driver_stress(
          1,
          base_seed ^ 32'h0000_0005,
          70, 70,
          25, 25,
          1,  8,
          128
        );

        run_case_dual_port("CASE_5_TIMING_JITTER_SPLIT",
          8000, 8000,
          16,   16,
          50,   50,
          1,    1,
          1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
          0, 1, 1, 0,
          0,
          0,
          0,
          0
        );
      end

      // Case 6: SOAK (split window)
      if (case_enabled("6")) begin
        cfg_driver_hold_ready(0, 0);
        cfg_driver_stress(
          1,
          base_seed ^ 32'h0000_0006,
          85, 85,
          5,  5,
          1,  2,
          128
        );

        run_case_dual_port("CASE_6_SOAK_SPLIT",
          20000, 20000,
          16,    16,
          50,    50,
          1,     1,
          1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
          1, 1, 0, 0,
          0,
          0,
          0,
          0
        );
      end

      // Case 7: FIXED burst (split window)
      if (case_enabled("7")) begin
        cfg_driver_hold_ready(0, 0);
        cfg_driver_stress(
          1,
          base_seed ^ 32'h0000_0007,
          80, 80,
          5,  5,
          1,  2,
          128
        );

        run_case_dual_port("CASE_7_FIXED_SPLIT",
          12000, 12000,
          16,    16,
          50,    50,
          1,     1,
          1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
          0, 0, 1, 0,
          0,
          0,
          0,
          0
        );
      end

      // Case 8: WRAP + INCR (split window) - MIX + STRESS
      if (case_enabled("8")) begin
        cfg_driver_hold_ready(0, 0);
        cfg_driver_stress(
          1,
          base_seed ^ 32'h0000_5454,
          60, 60,
          6,  6,
          1,  4,
          256
        );

        run_case_dual_port("CASE_8_WRAP_SPLIT_MIX_STRESS",
          8000, 8000,
          16,   16,
          50,   50,
          1,    1,
          1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
          0, 0, 0, 1,
          30,
          0,
          1,
          50
        );
      end

      // Case 9: SIZE RAND (split window) - mixed stress
      if (case_enabled("9")) begin
        cfg_driver_hold_ready(0, 0);
        cfg_driver_stress(
          1,
          base_seed ^ 32'h0000_BEEF,
          65, 65,
          4,  4,
          1,  2,
          192
        );

        run_case_dual_port("CASE_9_SIZE_RAND_SPLIT_MIX",
          8000, 8000,
          16,   16,
          50,   50,
          1,    1,
          1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
          1, 0, 0, 1,
          35,
          0,
          1,
          55
        );
      end

      // Case 10: PARTIAL WSTRB (split window) - write-heavy + stress
      if (case_enabled("10")) begin
        cfg_driver_hold_ready(0, 0);
        cfg_driver_stress(
          1,
          base_seed ^ 32'h3333_7777,
          10, 10,
          6,  6,
          1,  4,
          256
        );

        run_case_dual_port("CASE_10_PARTIAL_WSTRB_SPLIT_STRESS",
          9000, 9000,
          16,   16,
          35,   35,
          1,    1,
          1, WIN0_BASE, WIN1_BASE, WIN_BYTES, WIN_BYTES,
          0, 1, 0, 1,
          25,
          90,
          1,
          70
        );
      end

      `uvm_info("RANDOM_TEST", "Random Stress Test completed (check SCB FINAL RESULT for PASS/FAIL).", UVM_MEDIUM)
    end

    phase.drop_objection(this);
  endtask

endclass : axi_mm_random_test

`endif
