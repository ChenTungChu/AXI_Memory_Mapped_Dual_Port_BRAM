// File: tb/uvm/test/axi_mm_random_test.sv
`ifndef AXI_MM_RANDOM_TEST_SV
`define AXI_MM_RANDOM_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

// ------------------------------------------------------------
// Random Test
// ------------------------------------------------------------
class axi_mm_random_test extends uvm_test;

  `uvm_component_utils(axi_mm_random_test)

  // Fixed params
  localparam int ADDR_WIDTH = 32;
  localparam int DATA_WIDTH = 64;
  localparam int ID_WIDTH   = 4;

  // BRAM configuration
  localparam int unsigned DEPTH_WORDS    = 1024;
  localparam int unsigned BYTES_PER_BEAT = (DATA_WIDTH/8);
  localparam int unsigned MEM_BYTES      = DEPTH_WORDS * BYTES_PER_BEAT; // 8192

  // Environment handle
  axi_mm_env #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) env_h;

  // ------------------------------------------------------------
  // Constructor
  // ------------------------------------------------------------
  function new(string name = "axi_mm_random_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ------------------------------------------------------------
  // Build phase
  // ------------------------------------------------------------
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

  // Case selection
  localparam string DEFAULT_CASE = "1";  

  function automatic bit case_enabled(string tag);
    string one, list;
    one  = get_plusarg_str("CASE");
    list = get_plusarg_str("CASELIST");

    // Run all
    if (one == "all") return 1;

    // Single selection
    if (one != "") return (one == tag);

    // List selection
    if (list != "") begin
      string tmp;
      tmp = {",", list, ","};
      return (str_find(tmp, {",", tag, ","}) != -1);
    end

    // Default
    return (tag == DEFAULT_CASE);
  endfunction

  task automatic banner_case(string cid, string title);
    `uvm_info("RANDOM_TEST", $sformatf("========== RUN CASE %s : %s ==========", cid, title), UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Helper task: Configure both drivers with same stress knobs
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
  // Helper task: Baseline READY policy on both drivers
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
  // Helper task: Run one dual-port random case
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
    input int unsigned           wrap_prob,        // 0-100

    // PARTIAL behavior knobs
    input int unsigned           partial_prob,     // 0-100

    // locality knobs
    input bit                    enable_locality,
    input int unsigned           locality_prob     // 0-100
  );
    axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) seq0;
    axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) seq1;

    int unsigned wp;
    int unsigned pp;
    int unsigned lp;

    wp = (wrap_prob     > 100) ? 100 : wrap_prob;
    pp = (partial_prob  > 100) ? 100 : partial_prob;
    lp = (locality_prob > 100) ? 100 : locality_prob;

    `uvm_info("RANDOM_TEST", $sformatf("=== %s: start | tx p0/p1=%0d/%0d max_beats p0/p1=%0d/%0d read%% p0/p1=%0d/%0d aligned p0/p1=%0d/%0d window=%0d (p0:0x%0h+%0d p1:0x%0h+%0d) size_rand=%0d partial_en=%0d fixed=%0d wrap=%0d wrap_prob=%0d partial_prob=%0d locality_en=%0d locality_prob=%0d ===", case_name, num_tx_p0, num_tx_p1, max_beats_p0, max_beats_p1, read_percent_p0, read_percent_p1, addr_aligned_p0, addr_aligned_p1, window_en, win_base_p0, win_base_p1, win_bytes_p0, win_bytes_p1, enable_size_rand, enable_partial_wstrb, enable_fixed, enable_wrap, wp, pp, enable_locality, lp), UVM_MEDIUM)

    seq0 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create({case_name, "_seq0"});
    seq1 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create({case_name, "_seq1"});

    // Lock knobs from test (seq0)
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

    // Lock knobs from test (seq1)
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

    // Always clamp into BRAM range
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

    // seq0
    `uvm_info("RANDOM_TEST", $sformatf("%s SEQ0: win_en=%0d base=0x%0h bytes=%0d mem_en=%0d mem_bytes=%0d wrap_en=%0d wrap_prob=%0d partial_en=%0d partial_prob=%0d loc=%0d/%0d", case_name, seq0.restrict_addr_window, seq0.window_base, seq0.window_bytes, seq0.restrict_to_mem, seq0.mem_bytes, seq0.enable_wrap, seq0.wrap_prob, seq0.enable_partial_wstrb, seq0.partial_prob, seq0.enable_locality, seq0.locality_prob), UVM_MEDIUM)

    // seq1
    `uvm_info("RANDOM_TEST", $sformatf("%s SEQ1: win_en=%0d base=0x%0h bytes=%0d mem_en=%0d mem_bytes=%0d wrap_en=%0d wrap_prob=%0d partial_en=%0d partial_prob=%0d loc=%0d/%0d", case_name, seq1.restrict_addr_window, seq1.window_base, seq1.window_bytes, seq1.restrict_to_mem, seq1.mem_bytes, seq1.enable_wrap, seq1.wrap_prob, seq1.enable_partial_wstrb, seq1.partial_prob, seq1.enable_locality, seq1.locality_prob), UVM_MEDIUM)

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
  // Helper task: Watchdog wrapper
  // ------------------------------------------------------------
  task automatic run_case_with_watchdog(
    input string case_name,
    input time   timeout_ns,

    // Pass-through args to run_case_dual_port
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
        run_case_dual_port(case_name, num_tx_p0, num_tx_p1, max_beats_p0, max_beats_p1, read_percent_p0, read_percent_p1, addr_aligned_p0, addr_aligned_p1, window_en, win_base_p0, win_base_p1, win_bytes_p0, win_bytes_p1, enable_size_rand, enable_partial_wstrb, enable_fixed, enable_wrap,wrap_prob, partial_prob, enable_locality, locality_prob);
        done = 1;
      end

      begin : RUN_WD
        #(timeout_ns * 1ns);
        if (!done) begin
          `uvm_fatal("TIMEOUT", $sformatf("Watchdog timeout hit in %s after %0t ns.", case_name, timeout_ns))
        end
      end
    join_any

    disable fork;
  endtask

  // ------------------------------------------------------------
  // Helper task: Gate profile runner
  // ------------------------------------------------------------
  task automatic run_gate_profile(
    input string                 profile_name,
    input int unsigned           base_seed,
    input logic [ADDR_WIDTH-1:0] WIN0_BASE,
    input logic [ADDR_WIDTH-1:0] WIN1_BASE,
    input int unsigned           WIN_BYTES,
    input time                   timeout_ns_override
  );
    time tmo_ns;

    // Default timeout
    if (timeout_ns_override != 0) begin
      tmo_ns = timeout_ns_override;
    end else begin
      if (profile_name == "SOAK_LONG")      tmo_ns = 400_000_000; // 400ms
      else                                  tmo_ns = 120_000_000; // 120ms
    end

    `uvm_info("RANDOM_GATE",
      $sformatf("=== RANDOM GATE v1 profile=%s timeout_ns=%0t ===", profile_name, tmo_ns),
      UVM_MEDIUM)

    // Profile definitions
    if (profile_name == "BP_LOW") begin
      cfg_driver_hold_ready(0, 0);
      cfg_driver_stress(
        1,
        base_seed ^ 32'hBFE0_0001,
        10,
        10,
        6,
        6,
        1,
        4,
        256
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
      cfg_driver_hold_ready(0, 0);
      cfg_driver_stress(
        1,
        base_seed ^ 32'h0FF0_0002,
        70,
        70,
        2,
        2,
        1,
        2,
        128
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
      cfg_driver_hold_ready(0, 0);
      cfg_driver_stress(
        1,
        base_seed ^ 32'hC4A0_0003,
        40,
        40,
        12,
        12,
        1,
        6,
        256
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
      cfg_driver_hold_ready(0, 0);
      cfg_driver_stress(
        1,
        base_seed ^ 32'h504B_0004,
        10,
        10,
        6,
        6,
        1,
        4,
        256
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
      `uvm_fatal("BAD_PROFILE", $sformatf("Unknown +PROFILE=%s. Allowed: BP_LOW | OOO_HIGH | MIX_CHAOS | SOAK_LONG", profile_name))
    end

    `uvm_info("RANDOM_GATE", $sformatf("=== RANDOM GATE profile=%s DONE ===", profile_name), UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 1: Baseline split
  // ------------------------------------------------------------
  task automatic run_case_1_baseline_split(
    input int unsigned           base_seed,
    input logic [ADDR_WIDTH-1:0] WIN0_BASE,
    input logic [ADDR_WIDTH-1:0] WIN1_BASE,
    input int unsigned           WIN_BYTES
  );
    banner_case("1", "Baseline split");

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

    `uvm_info("RANDOM_TEST", "[CASE_1] Done", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 2: W stream gaps split
  // ------------------------------------------------------------
  task automatic run_case_2_w_stream_gaps_split(
    input int unsigned           base_seed,
    input logic [ADDR_WIDTH-1:0] WIN0_BASE,
    input logic [ADDR_WIDTH-1:0] WIN1_BASE,
    input int unsigned           WIN_BYTES
  );
    banner_case("2", "W stream gaps split");

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

    `uvm_info("RANDOM_TEST", "[CASE_2] Done", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 3: Backpressure split
  // ------------------------------------------------------------
  task automatic run_case_3_backpressure_split(
    input int unsigned           base_seed,
    input logic [ADDR_WIDTH-1:0] WIN0_BASE,
    input logic [ADDR_WIDTH-1:0] WIN1_BASE,
    input int unsigned           WIN_BYTES
  );
    banner_case("3", "Backpressure split");

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

    `uvm_info("RANDOM_TEST", "[CASE_3] Done", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 4: Heavy backpressure split
  // ------------------------------------------------------------
  task automatic run_case_4_heavy_backpressure_split(
    input int unsigned           base_seed,
    input logic [ADDR_WIDTH-1:0] WIN0_BASE,
    input logic [ADDR_WIDTH-1:0] WIN1_BASE,
    input int unsigned           WIN_BYTES
  );
    banner_case("4", "Heavy backpressure split");

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

    `uvm_info("RANDOM_TEST", "[CASE_4] Done", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 5: Timing jitter split
  // ------------------------------------------------------------
  task automatic run_case_5_timing_jitter_split(
    input int unsigned           base_seed,
    input logic [ADDR_WIDTH-1:0] WIN0_BASE,
    input logic [ADDR_WIDTH-1:0] WIN1_BASE,
    input int unsigned           WIN_BYTES
  );
    banner_case("5", "Timing jitter split");

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

    `uvm_info("RANDOM_TEST", "[CASE_5] Done", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 6: Soak split
  // ------------------------------------------------------------
  task automatic run_case_6_soak_split(
    input int unsigned           base_seed,
    input logic [ADDR_WIDTH-1:0] WIN0_BASE,
    input logic [ADDR_WIDTH-1:0] WIN1_BASE,
    input int unsigned           WIN_BYTES
  );
    banner_case("6", "Soak split");

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

    `uvm_info("RANDOM_TEST", "[CASE_6] Done", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 7: Fixed split
  // ------------------------------------------------------------
  task automatic run_case_7_fixed_split(
    input int unsigned           base_seed,
    input logic [ADDR_WIDTH-1:0] WIN0_BASE,
    input logic [ADDR_WIDTH-1:0] WIN1_BASE,
    input int unsigned           WIN_BYTES
  );
    banner_case("7", "Fixed split");

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

    `uvm_info("RANDOM_TEST", "[CASE_7] Done", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 8: Wrap split mix stress
  // ------------------------------------------------------------
  task automatic run_case_8_wrap_split_mix_stress(
    input int unsigned           base_seed,
    input logic [ADDR_WIDTH-1:0] WIN0_BASE,
    input logic [ADDR_WIDTH-1:0] WIN1_BASE,
    input int unsigned           WIN_BYTES
  );
    banner_case("8", "Wrap split mix stress");

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

    `uvm_info("RANDOM_TEST", "[CASE_8] Done", UVM_MEDIUM)
  endtask
  
  // ------------------------------------------------------------
  // Case 9: Size rand split mix
  // ------------------------------------------------------------
  task automatic run_case_9_size_rand_split_mix(
    input int unsigned           base_seed,
    input logic [ADDR_WIDTH-1:0] WIN0_BASE,
    input logic [ADDR_WIDTH-1:0] WIN1_BASE,
    input int unsigned           WIN_BYTES
  );
    banner_case("9", "Size rand split mix");

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

    `uvm_info("RANDOM_TEST", "[CASE_9] Done", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 10: Partial WSTRB split stress
  // ------------------------------------------------------------
  task automatic run_case_10_partial_wstrb_split_stress(
    input int unsigned           base_seed,
    input logic [ADDR_WIDTH-1:0] WIN0_BASE,
    input logic [ADDR_WIDTH-1:0] WIN1_BASE,
    input int unsigned           WIN_BYTES
  );
    banner_case("10", "Partial WSTRB split stress");

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

    `uvm_info("RANDOM_TEST", "[CASE_10] Done", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Run phase
  // ------------------------------------------------------------
  virtual task run_phase(uvm_phase phase);

    int unsigned base_seed;
    string profile;
    bit do_gate;
    time gate_timeout_ns;

    // Window 0: 0x0000_0000 - 0x0000_0FFF (4096B)
    // Window 1: 0x0000_1000 - 0x0000_1FFF (4096B)
    logic [ADDR_WIDTH-1:0] WIN0_BASE;
    logic [ADDR_WIDTH-1:0] WIN1_BASE;
    int unsigned           WIN_BYTES;

    // Base seed
    base_seed = 32'h2026_0128;

    // Based seed allow overriding
    base_seed       = get_plusarg_uint("BASE_SEED", base_seed);
    profile         = get_plusarg_str("PROFILE");
    do_gate         = get_plusarg_bit("GATE");
    gate_timeout_ns = get_plusarg_uint("GATE_TIMEOUT_NS", 0);

    WIN0_BASE = 32'h0000_0000;
    WIN1_BASE = 32'h0000_1000;
    WIN_BYTES = 4096;

    phase.raise_objection(this);

    `uvm_info("RANDOM_TEST", "Starting AXI-MM Random Test", UVM_MEDIUM)
    `uvm_info("RANDOM_TEST", $sformatf("MEM_BYTES=%0d | DEPTH_WORDS=%0d | DATA_WIDTH=%0d | PROFILE=%s | GATE=%0d | CASE=%s | CASELIST=%s | BASE_SEED=0x%0h | TIMEOUT_NS=%0d", MEM_BYTES, DEPTH_WORDS, DATA_WIDTH, profile, do_gate, get_plusarg_str("CASE"), get_plusarg_str("CASELIST"), base_seed, gate_timeout_ns), UVM_LOW)

    if (do_gate) begin
      run_gate_profile("BP_LOW",    base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES, gate_timeout_ns);
      run_gate_profile("OOO_HIGH",  base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES, gate_timeout_ns);
      run_gate_profile("MIX_CHAOS", base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES, gate_timeout_ns);
      run_gate_profile("SOAK_LONG", base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES, gate_timeout_ns);
      `uvm_info("RANDOM_GATE", "RANDOM GATE: ALL PROFILES DONE", UVM_MEDIUM)
    end
    else if (profile != "") begin
      run_gate_profile(profile, base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES, gate_timeout_ns);
      `uvm_info("RANDOM_GATE", "RANDOM GATE: SINGLE PROFILE DONE", UVM_MEDIUM)
    end
    else begin
      if (case_enabled("1"))  run_case_1_baseline_split             (base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES);
      if (case_enabled("2"))  run_case_2_w_stream_gaps_split        (base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES);
      if (case_enabled("3"))  run_case_3_backpressure_split         (base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES);
      if (case_enabled("4"))  run_case_4_heavy_backpressure_split   (base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES);
      if (case_enabled("5"))  run_case_5_timing_jitter_split        (base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES);
      if (case_enabled("6"))  run_case_6_soak_split                 (base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES);
      if (case_enabled("7"))  run_case_7_fixed_split                (base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES);
      if (case_enabled("8"))  run_case_8_wrap_split_mix_stress      (base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES);
      if (case_enabled("9"))  run_case_9_size_rand_split_mix        (base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES);
      if (case_enabled("10")) run_case_10_partial_wstrb_split_stress(base_seed, WIN0_BASE, WIN1_BASE, WIN_BYTES);

      `uvm_info("RANDOM_TEST", "Random Test completed", UVM_MEDIUM)
    end

    phase.drop_objection(this);
  endtask

endclass : axi_mm_random_test

`endif