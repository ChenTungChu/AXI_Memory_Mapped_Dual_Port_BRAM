`ifndef AXI_MM_ENV_SV
`define AXI_MM_ENV_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

// axi_mm_env.sv

class axi_mm_env #(
    int ADDR_WIDTH  = 32,
    int DATA_WIDTH  = 64,
    int ID_WIDTH    = 4,
    int DEPTH_WORDS = 1024
) extends uvm_env;

  `uvm_component_utils(axi_mm_env #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS))

  // ------------------------------------------------------------
  // Agents
  // ------------------------------------------------------------
  axi_mm_agent #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_agent;
  axi_mm_agent #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_agent;

  // Reset agent (TB-owned)
  reset_agent rst_agent;

  // ------------------------------------------------------------
  // Commit monitor (Route A)  <<< NEW
  // ------------------------------------------------------------
  // 這裡假設你的 commit_monitor class 名字是 axi_mm_commit_monitor
  // 且可 parameterize (ADDR/DATA/ID/...)；若你的 class 不帶參數，這行改掉即可。
  axi_mm_commit_monitor #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) commit_mon;

  // ------------------------------------------------------------
  // Scoreboards
  // ------------------------------------------------------------
  axi_mm_scoreboard     #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS, 0) scb;
  axi_mm_cov_scoreboard #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)                 cov_scoreboard_h;

  // ------------------------------------------------------------
  // Reset control knobs (config_db can overwrite)
  // ------------------------------------------------------------
  bit             initial_reset     = 1;
  int unsigned rst_assert_cycles    = 50;
  int unsigned rst_deassert_cycles  = 10;

  // Global reset events (published by reset_monitor inside reset_agent)
  uvm_event ev_reset_assert;
  uvm_event ev_reset_deassert;

  function new(string name="axi_mm_env", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // Optional overrides
    void'(uvm_config_db#(bit         )::get(this, "", "do_initial_reset",     initial_reset));
    void'(uvm_config_db#(int unsigned)::get(this, "", "rst_assert_cycles",    rst_assert_cycles));
    void'(uvm_config_db#(int unsigned)::get(this, "", "rst_deassert_cycles",  rst_deassert_cycles));

    // Agents
    p0_agent  = axi_mm_agent#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_agent", this);
    p1_agent  = axi_mm_agent#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_agent", this);
    rst_agent = reset_agent::type_id::create("rst_agent", this);

    // Commit monitor  <<< NEW
    commit_mon = axi_mm_commit_monitor#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("commit_mon", this);

    // Scoreboards
    scb = axi_mm_scoreboard#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS, 0)::type_id::create("scb", this);
    cov_scoreboard_h =
      axi_mm_cov_scoreboard#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("cov_scoreboard_h", this);

    // Global reset events (monitor is the single source of truth)
    ev_reset_assert   = uvm_event_pool::get_global("axi_mm_reset_assert");
    ev_reset_deassert = uvm_event_pool::get_global("axi_mm_reset_deassert");
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    if (p0_agent == null || p0_agent.mon == null)
      `uvm_fatal("ENV", "p0_agent/mon is null")
    if (p1_agent == null || p1_agent.mon == null)
      `uvm_fatal("ENV", "p1_agent/mon is null")
    if (rst_agent == null)
      `uvm_fatal("ENV", "rst_agent is null")
    if (commit_mon == null)
      `uvm_fatal("ENV", "commit_mon is null")
    if (scb == null)
      `uvm_fatal("ENV", "scb is null")
    if (cov_scoreboard_h == null)
      `uvm_fatal("ENV", "cov_scoreboard_h is null")

    // Monitors -> Scoreboard (原本的 AXI 觀測)
    p0_agent.mon.ap.connect(scb.ap_imp_p0);
    p1_agent.mon.ap.connect(scb.ap_imp_p1);

    // Commit monitor -> Scoreboard (Route A 的 commit 事件)  <<< NEW
    // 這裡假設 scoreboard 新增了一個 ap_imp_commit 來接 axi_mm_commit_item
    commit_mon.ap.connect(scb.ap_imp_commit);

    // Monitors -> Coverage
    p0_agent.mon.ap.connect(cov_scoreboard_h.analysis_imp_p0);
    p1_agent.mon.ap.connect(cov_scoreboard_h.analysis_imp_p1);

    `uvm_info("ENV", "axi_mm_env connected monitors to scoreboard/coverage (+rst_agent +commit_mon)", UVM_LOW)
  endfunction


  task automatic do_initial_reset(
      uvm_phase    phase,
      string       reason  = "axi_mm_env do_initial_reset",
      time         timeout = 5_000_000ns   // kept for API compatibility (unused)
  );
    axi_mm_reset_seq rst_seq;

    if (!initial_reset) begin
      `uvm_info("ENV_RST", "do_initial_reset=0 => skip", UVM_LOW)
      return;
    end

    if (rst_agent == null || rst_agent.seqr == null) begin
      `uvm_fatal("ENV_RST", "rst_agent/seqr is null (reset_agent not ACTIVE or build failed)")
    end

    if (phase != null) phase.raise_objection(this, reason);

    rst_seq = axi_mm_reset_seq::type_id::create("env_init_rst_seq");
    rst_seq.assert_cycles   = rst_assert_cycles;
    rst_seq.deassert_cycles = rst_deassert_cycles;

    `uvm_info("ENV_RST",
      $sformatf("Starting initial reset: assert_cycles=%0d deassert_cycles=%0d",
                rst_assert_cycles, rst_deassert_cycles),
      UVM_LOW)

    // drive reset (blocking until seq completes)
    rst_seq.start(rst_agent.seqr);

    // Let same-timestep observers (monitor/scoreboard/driver) settle
    #0;
    #1step;

    `uvm_info("ENV_RST", "Initial reset completed (seq done)", UVM_LOW)

    if (phase != null) phase.drop_objection(this, reason);
  endtask

  function axi_mm_cov_scoreboard#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) get_cov_scoreboard();
    return cov_scoreboard_h;
  endfunction

endclass : axi_mm_env

`endif
