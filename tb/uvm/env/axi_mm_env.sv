// File: tb/uvm/env/axi_mm_env.sv
`ifndef AXI_MM_ENV_SV
`define AXI_MM_ENV_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

class axi_mm_env #(
    int ADDR_WIDTH  = 32,
    int DATA_WIDTH  = 64,
    int ID_WIDTH    = 4,
    int DEPTH_WORDS = 1024
) extends uvm_env;

  `uvm_component_utils(axi_mm_env #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS))

  // ------------------------------------------------------------
  // Local params
  // ------------------------------------------------------------
  localparam int COMMIT_BEAT_IDX_W = 8;
  localparam int APPLY_BEAT_IDX_W  = 8;

  // ------------------------------------------------------------
  // Agents
  // ------------------------------------------------------------
  axi_mm_agent #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_agent;
  axi_mm_agent #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_agent;

  // Reset agent (TB-owned)
  reset_agent rst_agent;

  // ------------------------------------------------------------
  // Commit monitor
  // ------------------------------------------------------------
  axi_mm_commit_monitor #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, COMMIT_BEAT_IDX_W) commit_mon;

  // ------------------------------------------------------------
  // Apply monitor
  // ------------------------------------------------------------
  axi_mm_apply_monitor #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, APPLY_BEAT_IDX_W) apply_mon;

  // ------------------------------------------------------------
  // Scoreboards
  // ------------------------------------------------------------
  axi_mm_scoreboard     #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS, 0) scb;
  axi_mm_cov_scoreboard #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)                 cov_scoreboard_h;

  // ------------------------------------------------------------
  // Coverage subscriber
  // ------------------------------------------------------------
  axi_mm_cov_subscriber #(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH) cov_p0;
  axi_mm_cov_subscriber #(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH) cov_p1;

  // ------------------------------------------------------------
  // Reset control knobs (config_db can overwrite)
  // ------------------------------------------------------------
  bit          initial_reset        = 1;
  int unsigned rst_assert_cycles    = 50;
  int unsigned rst_deassert_cycles  = 10;

  // ------------------------------------------------------------
  // Window bases (scoreboard mapping)
  // ------------------------------------------------------------
  logic [ADDR_WIDTH-1:0] win0_base;
  logic [ADDR_WIDTH-1:0] win1_base;

  // Global reset events
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

    // ------------------------------------------------------------
    // Window bases:
    // 1) Prefer config_db override (from test)
    // 2) Else fall back to `ifdef WIN0_BASE/WIN1_BASE
    // ------------------------------------------------------------
    if (!uvm_config_db#(logic [ADDR_WIDTH-1:0])::get(this, "", "WIN0_BASE", win0_base)) begin
      `ifdef WIN0_BASE
        win0_base = WIN0_BASE;
      `else
        win0_base = '0;
      `endif
    end

    if (!uvm_config_db#(logic [ADDR_WIDTH-1:0])::get(this, "", "WIN1_BASE", win1_base)) begin
      `ifdef WIN1_BASE
        win1_base = WIN1_BASE;
      `else
        win1_base = '0;
      `endif
    end

    // Publish to all descendants
    uvm_config_db#(logic [ADDR_WIDTH-1:0])::set(this, "*", "WIN0_BASE", win0_base);
    uvm_config_db#(logic [ADDR_WIDTH-1:0])::set(this, "*", "WIN1_BASE", win1_base);

    `uvm_info("ENV",
              $sformatf("WIN bases: WIN0_BASE=0x%0h WIN1_BASE=0x%0h", win0_base, win1_base),
              UVM_LOW)

    // ------------------------------------------------------------
    // Commit monitor defaults
    // ------------------------------------------------------------
    uvm_config_db#(bit)::set(this, "commit_mon", "drive_ready_always", 1);
    uvm_config_db#(bit)::set(this, "commit_mon", "stress_enable",      0);

    // ------------------------------------------------------------
    // Apply monitor defaults
    // ------------------------------------------------------------
    uvm_config_db#(bit)::set(this, "apply_mon", "drive_ready_always", 1);
    uvm_config_db#(bit)::set(this, "apply_mon", "stress_enable",      0);

    // Agents
    p0_agent  = axi_mm_agent#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_agent", this);
    p1_agent  = axi_mm_agent#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_agent", this);
    rst_agent = reset_agent::type_id::create("rst_agent", this);

    // Commit monitor
    commit_mon = axi_mm_commit_monitor#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, COMMIT_BEAT_IDX_W)
                 ::type_id::create("commit_mon", this);

    // Apply monitor
    apply_mon = axi_mm_apply_monitor#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, APPLY_BEAT_IDX_W)
            ::type_id::create("apply_mon", this);

    // Scoreboards
    scb = axi_mm_scoreboard#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS, 0)
          ::type_id::create("scb", this);

    cov_scoreboard_h = axi_mm_cov_scoreboard#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)
                       ::type_id::create("cov_scoreboard_h", this);

    // Subscribers
    cov_p0 = axi_mm_cov_subscriber#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH)::type_id::create("cov_p0", this);
    cov_p1 = axi_mm_cov_subscriber#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH)::type_id::create("cov_p1", this);

    // Global reset events
    ev_reset_assert   = uvm_event_pool::get_global("axi_mm_reset_assert");
    ev_reset_deassert = uvm_event_pool::get_global("axi_mm_reset_deassert");
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // ------------------------------------------------------------
    // Hard checks (fail fast)
    // ------------------------------------------------------------
    if (p0_agent == null)
      `uvm_fatal("ENV", "p0_agent is null (build failed)")
    if (p1_agent == null)
      `uvm_fatal("ENV", "p1_agent is null (build failed)")
    if (rst_agent == null)
      `uvm_fatal("ENV", "rst_agent is null (build failed)")
    if (commit_mon == null)
      `uvm_fatal("ENV", "commit_mon is null (build failed)")
    if (apply_mon == null)
      `uvm_fatal("ENV", "apply_mon is null (build failed)")
    if (scb == null)
      `uvm_fatal("ENV", "scb is null (build failed)")
    if (cov_scoreboard_h == null)
      `uvm_fatal("ENV", "cov_scoreboard_h is null (build failed)")
    if (cov_p0 == null || cov_p1 == null)
      `uvm_fatal("ENV", "cov subscribers are null (build failed)")

    // agent analysis ports must exist
    if (p0_agent.ap == null)
      `uvm_fatal("ENV", "p0_agent.ap is null (agent monitor not built or ap not exported)")
    if (p1_agent.ap == null)
      `uvm_fatal("ENV", "p1_agent.ap is null (agent monitor not built or ap not exported)")

    // commit/apply monitor analysis ports must exist
    if (commit_mon.ap == null)
      `uvm_fatal("ENV", "commit_mon.ap is null (commit monitor build failed)")
    if (apply_mon.ap == null)
      `uvm_fatal("ENV", "apply_mon.ap is null (apply monitor build failed)")

    // scoreboard analysis imps must exist
    if (scb.ap_imp_p0 == null ||
        scb.ap_imp_p1 == null ||
        scb.ap_imp_commit == null ||
        scb.ap_imp_apply == null)
      `uvm_fatal("ENV", "scb analysis imps are null (scoreboard build failed)")

    // coverage scoreboard imps must exist
    if (cov_scoreboard_h.analysis_imp_p0 == null || cov_scoreboard_h.analysis_imp_p1 == null)
      `uvm_fatal("ENV", "cov_scoreboard_h analysis imps are null")

    // ------------------------------------------------------------
    // Connections
    // ------------------------------------------------------------

    // Monitors -> Functional scoreboard (p0/p1)
    p0_agent.ap.connect(scb.ap_imp_p0);
    p1_agent.ap.connect(scb.ap_imp_p1);

    // Commit monitor -> Functional scoreboard
    commit_mon.ap.connect(scb.ap_imp_commit);

    // Apply monitor -> Functional scoreboard
    apply_mon.ap.connect(scb.ap_imp_apply);

    // Monitors -> Coverage scoreboard
    p0_agent.ap.connect(cov_scoreboard_h.analysis_imp_p0);
    p1_agent.ap.connect(cov_scoreboard_h.analysis_imp_p1);

    // Monitors -> Subscribers
    p0_agent.ap.connect(cov_p0.analysis_export);
    p1_agent.ap.connect(cov_p1.analysis_export);

    `uvm_info("ENV",
              "axi_mm_env connected: p0/p1 monitor -> scb + cov_scoreboard + cov_subscribers; commit_mon/apply_mon -> scb",
              UVM_LOW)
  endfunction

  // ------------------------------------------------------------
  // Optional helper: initial reset
  // ------------------------------------------------------------
  task automatic do_initial_reset(
      uvm_phase    phase,
      string       reason  = "axi_mm_env do_initial_reset",
      time         timeout = 5_000_000ns
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

    rst_seq.start(rst_agent.seqr);

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