// File: tb/uvm/test/axi_mm_corner_test.sv
`ifndef AXI_MM_CORNER_TEST_SV
`define AXI_MM_CORNER_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

// ------------------------------------------------------------
// Corner Test (non-parameterized, factory-safe)
// ------------------------------------------------------------
class axi_mm_corner_test extends uvm_test;

  `uvm_component_utils(axi_mm_corner_test)

  // ------------------------------------------------------------
  // Local parameters (fixed at test level)
  // ------------------------------------------------------------
  localparam int ADDR_WIDTH = 32;
  localparam int DATA_WIDTH = 64;
  localparam int ID_WIDTH   = 4;

  // Match your BRAM config used in random_test
  localparam int unsigned DEPTH_WORDS    = 1024;
  localparam int unsigned BYTES_PER_BEAT = (DATA_WIDTH/8);
  localparam int unsigned MEM_BYTES      = DEPTH_WORDS * BYTES_PER_BEAT; // 8192

  // Split windows (avoid cross-port overwrite noise)
  localparam logic [ADDR_WIDTH-1:0] WIN0_BASE = 32'h0000_0000;
  localparam logic [ADDR_WIDTH-1:0] WIN1_BASE = 32'h0000_1000;
  localparam int unsigned           WIN_BYTES = 4096;

  // IMPORTANT:
  // Scoreboard compares only when (beat_t - last_commit_time) >= COMMIT_STABLE_DELAY (25ns).
  // Also commit stream apply can lag due to arbitration/backpressure.
  // So we insert a conservative post-write delay to make READ checks meaningful.
  localparam time POST_WRITE_DELAY = 100ns;

  // After reset/flush, your monitor has IGNORE_WINDOW = 500ns;
  // keep post-reset gap comfortably larger.
  localparam time POST_RESET_DELAY = 1us;

  // ------------------------------------------------------------
  // Environment handle
  // ------------------------------------------------------------
  axi_mm_env #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) env_h;

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

  task automatic banner_case(string cid, string title);
    `uvm_info("CORNER_TEST",
      $sformatf("========== RUN CASE %s : %s ==========", cid, title),
      UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Local sequence: run a fixed list of steps (items + delays)
  //
  // Motivation:
  //   Scoreboard compares READ only after commit visibility + stable delay.
  //   Plain "list of items" can't insert wait time between W and R.
  // ------------------------------------------------------------
  class axi_mm_corner_step_seq extends uvm_sequence #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH));
    `uvm_object_utils(axi_mm_corner_step_seq)

    typedef axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) seq_t;

    typedef struct {
      bit   is_delay;
      time  dt;
      seq_t tr;
    } step_t;

    step_t steps[$];

    function new(string name="axi_mm_corner_step_seq");
      super.new(name);
    endfunction

    function void push_item(seq_t tr);
      step_t s;
      s.is_delay = 0;
      s.dt       = 0;
      s.tr       = tr;
      steps.push_back(s);
    endfunction

    function void push_delay(time dt);
      step_t s;
      s.is_delay = 1;
      s.dt       = dt;
      s.tr       = null;
      steps.push_back(s);
    endfunction

    virtual task body();
      seq_t tr;
      foreach (steps[i]) begin
        if (steps[i].is_delay) begin
          #(steps[i].dt);
        end else begin
          tr = steps[i].tr;
          start_item(tr);
          finish_item(tr);
        end
      end
    endtask
  endclass

  // ------------------------------------------------------------
  // Constructor
  // ------------------------------------------------------------
  function new(string name = "axi_mm_corner_test", uvm_component parent = null);
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
  // Reset phase (config-only)
  // ------------------------------------------------------------
  virtual task reset_phase(uvm_phase phase);
    super.reset_phase(phase);

    `uvm_info("CORNER_TEST",
              "[RESET_PHASE] config-only (initial reset will be done in run_phase)",
              UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Helper: configure both drivers' READY policy
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
  // Helper: disable stress mode
  // ------------------------------------------------------------
  task automatic cfg_driver_stress_off();
    uvm_config_db#(bit)::set(this, "env_h.p0_agent.drv", "stress_enable", 0);
    uvm_config_db#(bit)::set(this, "env_h.p1_agent.drv", "stress_enable", 0);
  endtask

  // enable stress mode (if your driver supports it)
  task automatic cfg_driver_stress_on();
    uvm_config_db#(bit)::set(this, "env_h.p0_agent.drv", "stress_enable", 1);
    uvm_config_db#(bit)::set(this, "env_h.p1_agent.drv", "stress_enable", 1);
  endtask

  // ------------------------------------------------------------
  // Helper: align an address to beat size (BYTES_PER_BEAT)
  // ------------------------------------------------------------
  function automatic logic [ADDR_WIDTH-1:0] align_to_beat(input logic [ADDR_WIDTH-1:0] a);
    return (a & ~(BYTES_PER_BEAT-1));
  endfunction

  // ------------------------------------------------------------
  // Helper: create deterministic per-beat data
  // ------------------------------------------------------------
  function automatic logic [DATA_WIDTH-1:0] beat_data_seed(
      input logic [ID_WIDTH-1:0] id,
      input int unsigned beat_idx,
      input logic [ADDR_WIDTH-1:0] addr
  );
    logic [DATA_WIDTH-1:0] v;
    v = '0;
    v[63:48] = {12'h0, id};
    v[47:32] = beat_idx[15:0];
    v[31:0]  = addr[31:0] ^ 32'hA5A5_5A5A;
    return v;
  endfunction

  // ------------------------------------------------------------
  // Helper: build a transaction item (corner-friendly)
  // IMPORTANT:
  //  - op_kind/wait_bid set BEFORE set_beats_len()
  // ------------------------------------------------------------
  function automatic axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) mk_tr(
      input bit                         is_read,
      input logic [ADDR_WIDTH-1:0]      addr,
      input logic [1:0]                 burst,
      input logic [2:0]                 size,
      input logic [7:0]                 len,
      input logic [ID_WIDTH-1:0]        id,
      input logic [BYTES_PER_BEAT-1:0]  wstrb0,
      input logic [DATA_WIDTH-1:0]      wdata0,
      input string                      comment = "",
      input bit                         fill_all_beats = 0,
      input axi_mm_op_kind_e            op_kind = OP_FULL,
      input logic [ID_WIDTH-1:0]        wait_bid = '0
    );
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
    string nm;
    int unsigned beats;

    nm = $sformatf("tr_%s_id%0h_addr%0h_len%0d",
                   (is_read ? "R" : "W"),
                   id, addr, len);

    tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create(nm);

    tr.rw      = (is_read) ? AXI_READ : AXI_WRITE;
    tr.addr    = addr;
    tr.burst   = burst;
    tr.size    = size;
    tr.len     = len;
    tr.id      = id;
    tr.comment = comment;

    tr.op_kind  = op_kind;
    tr.wait_bid = wait_bid;

    tr.set_beats_len(tr.len);
    beats = tr.len + 1;

    if (!is_read) begin
      if (fill_all_beats) begin
        for (int unsigned i = 0; i < beats; i++) begin
          tr.wdata_beats[i]  = beat_data_seed(id, i, addr);
          tr.wstrb_beats[i]  = wstrb0;
        end
      end else begin
        if (tr.wdata_beats.size() > 0) begin
          tr.wdata_beats[0]  = wdata0;
          tr.wstrb_beats[0]  = wstrb0;
        end
      end
    end

    return tr;
  endfunction

  // ------------------------------------------------------------
  // Helper: build a WRITE burst transaction with full payload
  // ------------------------------------------------------------
  function automatic axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) mk_wr_burst(
      input logic [ADDR_WIDTH-1:0]      addr,
      input logic [1:0]                 burst,
      input logic [2:0]                 size,
      input logic [7:0]                 len,
      input logic [ID_WIDTH-1:0]        id,
      input logic [DATA_WIDTH-1:0]      data0,
      input logic [BYTES_PER_BEAT-1:0]  wstrb_all,
      input axi_mm_op_kind_e            op_kind = OP_FULL,
      input logic [ID_WIDTH-1:0]        wait_bid = '0,
      input string                      comment = ""
    );
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
    int unsigned beats;

    tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("tr_wr");

    tr.rw      = AXI_WRITE;
    tr.addr    = addr;
    tr.burst   = burst;
    tr.size    = size;
    tr.len     = len;
    tr.id      = id;
    tr.comment = comment;

    tr.op_kind  = op_kind;
    tr.wait_bid = wait_bid;

    tr.set_beats_len(tr.len);
    beats = tr.len + 1;

    if (tr.wdata_beats.size() == beats) begin
      for (int i = 0; i < beats; i++) begin
        tr.wdata_beats[i]  = data0 + i;
        tr.wstrb_beats[i]  = wstrb_all;
      end
    end

    return tr;
  endfunction

  // ============================================================
  // Case 1: Zero-length & Single-beat bursts (LEN=0 => 1 beat)
  // ============================================================
  task automatic run_case_1_single_beat();
    axi_mm_corner_step_seq seq0;
    axi_mm_corner_step_seq seq1;

    logic [ADDR_WIDTH-1:0] a0, a1, a1z, a0p;

    a0  = align_to_beat(WIN0_BASE + 32'h000);
    a0p = align_to_beat(WIN0_BASE + 32'h060);
    a1  = align_to_beat(WIN1_BASE + 32'h080);
    a1z = align_to_beat(a1 + 32'h040);

    seq0 = axi_mm_corner_step_seq::type_id::create("C1_seq0");
    seq1 = axi_mm_corner_step_seq::type_id::create("C1_seq1");

    // P0: write then wait then read
    seq0.push_item(mk_tr(0, a0, 2'b01, 3'd3, 8'd0, 4'h1, {BYTES_PER_BEAT{1'b1}}, 64'hC1C1_0000_0000_0001, "C1.P0.W.INCR.LEN0"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, a0, 2'b01, 3'd3, 8'd0, 4'h2, '0, '0, "C1.P0.R.INCR.LEN0"));

    seq0.push_item(mk_tr(0, align_to_beat(a0 + 32'h020), 2'b00, 3'd3, 8'd0, 4'h3, {BYTES_PER_BEAT{1'b1}}, 64'hC1C1_0000_0000_0003, "C1.P0.W.FIXED.LEN0"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, align_to_beat(a0 + 32'h020), 2'b00, 3'd3, 8'd0, 4'h4, '0, '0, "C1.P0.R.FIXED.LEN0"));

    // Partial merge: seed full -> partial -> wait -> read
    seq0.push_item(mk_tr(0, a0p, 2'b01, 3'd3, 8'd0, 4'hA, 8'hFF, 64'hAAAA_BBBB_CCCC_DDDD, "C1.P0.SEED.FULL"));
    seq0.push_item(mk_tr(0, a0p, 2'b01, 3'd3, 8'd0, 4'hB, 8'h0F, 64'h1111_2222_3333_4444, "C1.P0.W.PARTIAL.0F"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, a0p, 2'b01, 3'd3, 8'd0, 4'hC, '0, '0, "C1.P0.R.MERGECHK"));

    // P1: WSTRB=0 check: seed -> wstrb0 -> wait -> read
    seq1.push_item(mk_tr(0, a1, 2'b01, 3'd3, 8'd0, 4'h5, 8'hFF, 64'hC1C1_0000_0000_1001, "C1.P1.W.INCR.LEN0"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, a1, 2'b01, 3'd3, 8'd0, 4'h6, '0, '0, "C1.P1.R.INCR.LEN0"));

    seq1.push_item(mk_tr(0, a1z, 2'b01, 3'd3, 8'd0, 4'h7, 8'hFF, 64'h1111_2222_3333_4444, "C1.P1.SEED.KNOWN"));
    seq1.push_item(mk_tr(0, a1z, 2'b01, 3'd3, 8'd0, 4'h8, 8'h00, 64'hDEAD_BEEF_DEAD_BEEF, "C1.P1.WSTRB0.NOCHANGE"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, a1z, 2'b01, 3'd3, 8'd0, 4'h9, '0, '0, "C1.P1.R.BACK.KNOWN"));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_1] Start: LEN=0 single-beat READ/WRITE + WSTRB patterns (with post-write delay=%0t). a0=0x%0h a1=0x%0h",
                POST_WRITE_DELAY, a0, a1),
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
    `uvm_info("CORNER_TEST", "[CASE_1] Done.", UVM_MEDIUM)
  endtask

  // ============================================================
  // Case 2: Boundary crossing at window edge + end-of-window edge
  // ============================================================
  task automatic run_case_2_boundary_edges();
    axi_mm_corner_step_seq seq0;
    axi_mm_corner_step_seq seq1;

    logic [ADDR_WIDTH-1:0] p0_a_cross_2b;
    logic [ADDR_WIDTH-1:0] p0_a_cross_4b;
    logic [ADDR_WIDTH-1:0] p1_last;

    // Derive from window sizes (avoid magic constants)
    p0_a_cross_2b = align_to_beat(WIN0_BASE + (WIN_BYTES - BYTES_PER_BEAT));         // last beat in window
    p0_a_cross_4b = align_to_beat(WIN0_BASE + (WIN_BYTES - (4*BYTES_PER_BEAT)));     // last 4 beats region
    p1_last       = align_to_beat(WIN1_BASE + (WIN_BYTES - BYTES_PER_BEAT));

    seq0 = axi_mm_corner_step_seq::type_id::create("C2_seq0");
    seq1 = axi_mm_corner_step_seq::type_id::create("C2_seq1");

    // P0: cross boundary with len=1 (2 beats)
    seq0.push_item(mk_wr_burst(p0_a_cross_2b, 2'b01, 3'd3, 8'd1, 4'h1, 64'hC2C2_0000_0000_2000, {BYTES_PER_BEAT{1'b1}}));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_a_cross_2b, 2'b01, 3'd3, 8'd1, 4'h2, '0, '0, "C2.P0.R.CROSS2"));

    // P0: cross boundary with len=3 (4 beats)
    seq0.push_item(mk_wr_burst(p0_a_cross_4b, 2'b01, 3'd3, 8'd3, 4'h3, 64'hC2C2_0000_0000_4000, {BYTES_PER_BEAT{1'b1}}));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_a_cross_4b, 2'b01, 3'd3, 8'd3, 4'h4, '0, '0, "C2.P0.R.CROSS4"));

    // P1: last beat write/read
    seq1.push_item(mk_tr(0, p1_last, 2'b01, 3'd3, 8'd0, 4'h5, {BYTES_PER_BEAT{1'b1}}, {32'hC2C2_0002, p1_last}, "C2.P1.W.LAST"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, p1_last, 2'b01, 3'd3, 8'd0, 4'h6, '0, '0, "C2.P1.R.LAST"));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_2] Start: boundary-cross bursts (derived) @0x%0h(len1) & 0x%0h(len3), P1 last-beat @0x%0h",
                p0_a_cross_2b, p0_a_cross_4b, p1_last),
      UVM_MEDIUM)

    fork
      begin seq0.start(env_h.p0_agent.seqr); end
      begin #1ns; seq1.start(env_h.p1_agent.seqr); end
    join

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_2] Done.", UVM_MEDIUM)
  endtask

  // ============================================================
  // Case 3: Ordering + partial merge (NO cross-window fake conflict)
  // ============================================================
  task automatic run_case_3_ordering_and_conflict();
    axi_mm_corner_step_seq seq0;
    axi_mm_corner_step_seq seq1;

    logic [ADDR_WIDTH-1:0] A0, A1;
    logic [ADDR_WIDTH-1:0] B0, B1;

    logic [DATA_WIDTH-1:0] full0, part0;
    logic [BYTES_PER_BEAT-1:0] wmask_low4;

    A0 = align_to_beat(WIN0_BASE + 32'h0060);
    A1 = align_to_beat(WIN1_BASE + 32'h0060);

    B0 = align_to_beat(WIN0_BASE + 32'h0080);
    B1 = align_to_beat(WIN0_BASE + 32'h00A0);

    full0 = 64'hC3C3_5100_1111_2222;
    part0 = 64'hAAAA_BBBB_3333_4444;

    wmask_low4 = '0;
    wmask_low4[3:0] = 4'hF;

    seq0 = axi_mm_corner_step_seq::type_id::create("C3_seq0");
    seq1 = axi_mm_corner_step_seq::type_id::create("C3_seq1");

    // P0: seed full -> partial low4 -> wait -> read
    seq0.push_item(mk_tr(0, A0, 2'b01, 3'd3, 8'd0, 4'h1, 8'hFF, full0, "C3.P0.SEED.FULL"));
    seq0.push_item(mk_tr(0, A0, 2'b01, 3'd3, 8'd0, 4'h2, wmask_low4, part0, "C3.P0.W.PARTIAL.LOW4"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, A0, 2'b01, 3'd3, 8'd0, 4'h3, '0, '0, "C3.P0.R.MERGECHK"));

    // extra ordering: back-to-back writes same ID then reads
    seq0.push_item(mk_tr(0, B0, 2'b01, 3'd3, 8'd0, 4'h9, 8'hFF, 64'hC3C3_0000_0000_00B0, "C3.P0.W.B0"));
    seq0.push_item(mk_tr(0, B1, 2'b01, 3'd3, 8'd0, 4'h9, 8'hFF, 64'hC3C3_0000_0000_00B1, "C3.P0.W.B1"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, B0, 2'b01, 3'd3, 8'd0, 4'hA, '0, '0, "C3.P0.R.B0"));
    seq0.push_item(mk_tr(1, B1, 2'b01, 3'd3, 8'd0, 4'hB, '0, '0, "C3.P0.R.B1"));

    // P1: do its own merge at its own window address (avoid out-of-window mapping ambiguity)
    seq1.push_item(mk_tr(0, A1, 2'b01, 3'd3, 8'd0, 4'h5, 8'hFF, 64'hC3C3_6100_3333_4444, "C3.P1.SEED.FULL"));
    seq1.push_item(mk_tr(0, A1, 2'b01, 3'd3, 8'd0, 4'h6, wmask_low4, 64'hDEAD_BEEF_5555_6666, "C3.P1.W.PARTIAL.LOW4"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, A1, 2'b01, 3'd3, 8'd0, 4'h7, '0, '0, "C3.P1.R.MERGECHK"));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_3] Start: ordering + partial merge (per-window). A0=0x%0h A1=0x%0h",
                A0, A1),
      UVM_MEDIUM)

    fork
      begin seq1.start(env_h.p1_agent.seqr); end
      begin #300ns; seq0.start(env_h.p0_agent.seqr); end
    join

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_3] Done.", UVM_MEDIUM)
  endtask

  // ============================================================
  // Case 4: AW/AR contention + verified burst read (FORCED OVERLAP)
  // ============================================================
  task automatic run_case_4_aw_ar_contention();
    axi_mm_corner_step_seq prime0, prime1;
    axi_mm_corner_step_seq cont0, cont1;

    logic [ADDR_WIDTH-1:0] p0_r0, p1_r0;
    logic [ADDR_WIDTH-1:0] p0_wburst, p1_wburst;

    p0_r0     = align_to_beat(WIN0_BASE + 32'h0280);
    p1_r0     = align_to_beat(WIN1_BASE + 32'h0280);
    p0_wburst = align_to_beat(WIN0_BASE + 32'h0200);
    p1_wburst = align_to_beat(WIN1_BASE + 32'h0200);

    prime0 = axi_mm_corner_step_seq::type_id::create("C4_prime0");
    prime1 = axi_mm_corner_step_seq::type_id::create("C4_prime1");

    prime0.push_item(mk_wr_burst(p0_r0, 2'b01, 3'd3, 8'd1, 4'h1, 64'hC4C4_F0E0_0000_0000, {BYTES_PER_BEAT{1'b1}}));
    prime1.push_item(mk_wr_burst(p1_r0, 2'b01, 3'd3, 8'd1, 4'h5, 64'hC4C4_F1E0_0000_0000, {BYTES_PER_BEAT{1'b1}}));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_4] PhaseA PRIME start. p0_r0=0x%0h p1_r0=0x%0h", p0_r0, p1_r0),
      UVM_MEDIUM)

    fork
      prime0.start(env_h.p0_agent.seqr);
      begin #1ns; prime1.start(env_h.p1_agent.seqr); end
    join

    // allow commits to settle before we do contention reads (avoid scoreboard skip)
    #POST_WRITE_DELAY;

    cont0 = axi_mm_corner_step_seq::type_id::create("C4_cont0");
    cont1 = axi_mm_corner_step_seq::type_id::create("C4_cont1");

    cont0.push_item(mk_wr_burst(p0_wburst, 2'b01, 3'd3, 8'd3, 4'h3, 64'hC4C4_F0EB_0000_3000, {BYTES_PER_BEAT{1'b1}}));
    cont0.push_delay(POST_WRITE_DELAY);
    cont0.push_item(mk_tr(1, p0_r0, 2'b01, 3'd3, 8'd1, 4'h4, '0, '0, "C4.P0.R.PRIMECHK"));

    cont1.push_item(mk_tr(1, p1_r0, 2'b01, 3'd3, 8'd1, 4'h7, '0, '0, "C4.P1.R.PRIMECHK"));

    cont1.push_item(mk_tr(0, (p1_r0 + 32'h040), 2'b01, 3'd3, 8'd0, 4'h6, {BYTES_PER_BEAT{1'b1}}, 64'hC4C4_F1E0_0000_0006, "C4.P1.W.OTHER"));
    cont1.push_item(mk_wr_burst(p1_wburst, 2'b01, 3'd3, 8'd3, 4'h8, 64'hC4C4_F1EB_0000_8000, {BYTES_PER_BEAT{1'b1}}));
    cont1.push_delay(POST_WRITE_DELAY);

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_4] PhaseB CONTENTION start. p0_wburst=0x%0h p1_wburst=0x%0h", p0_wburst, p1_wburst),
      UVM_MEDIUM)

    fork
      cont0.start(env_h.p0_agent.seqr);
      begin #1ns; cont1.start(env_h.p1_agent.seqr); end
    join

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_4] Done.", UVM_MEDIUM)
  endtask

  // ============================================================
  // Case 5: WRAP burst edge cases + FIXED burst last-wins
  // ============================================================
  task automatic run_case_5_wrap_fixed();
    axi_mm_corner_step_seq seq0;
    axi_mm_corner_step_seq seq1;

    logic [ADDR_WIDTH-1:0] p0_wrap_base, p0_wrap_off;
    logic [ADDR_WIDTH-1:0] p1_wrap_base, p1_wrap_off;
    logic [ADDR_WIDTH-1:0] p0_fixed;

    localparam int unsigned WRAP_BEATS = 4;
    localparam int unsigned WRAP_BYTES = WRAP_BEATS * BYTES_PER_BEAT; // 32

    p0_wrap_base = align_to_beat(WIN0_BASE + 32'h0100);
    p1_wrap_base = align_to_beat(WIN1_BASE + 32'h0100);
    p0_fixed     = align_to_beat(WIN0_BASE + 32'h0180);

    // ensure 32B boundary alignment for wrap_base
    p0_wrap_base &= ~(WRAP_BYTES-1);
    p1_wrap_base &= ~(WRAP_BYTES-1);

    // Off-by-one start = base + (32-8)=24
    p0_wrap_off  = p0_wrap_base + (WRAP_BYTES - BYTES_PER_BEAT);
    p1_wrap_off  = p1_wrap_base + (WRAP_BYTES - BYTES_PER_BEAT);

    seq0 = axi_mm_corner_step_seq::type_id::create("C5_seq0");
    seq1 = axi_mm_corner_step_seq::type_id::create("C5_seq1");

    seq0.push_item(mk_wr_burst(p0_wrap_base, 2'b10, 3'd3, 8'd3, 4'h1, 64'hC5C5_0000_0000_5000, {BYTES_PER_BEAT{1'b1}}));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_wrap_base, 2'b10, 3'd3, 8'd3, 4'h2, '0, '0, "C5.P0.R.WRAP_BASE"));

    seq0.push_item(mk_wr_burst(p0_wrap_off, 2'b10, 3'd3, 8'd3, 4'h3, 64'hC5C5_0000_0000_5100, {BYTES_PER_BEAT{1'b1}}));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_wrap_off, 2'b10, 3'd3, 8'd3, 4'h4, '0, '0, "C5.P0.R.WRAP_OFF"));

    // FIXED: last beat overwrites same address (driver sends beat0..3; addr fixed)
    seq0.push_item(mk_wr_burst(p0_fixed, 2'b00, 3'd3, 8'd3, 4'h5, 64'hC5C5_F1E0_0000_6000, {BYTES_PER_BEAT{1'b1}}));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_fixed, 2'b01, 3'd3, 8'd0, 4'h6, '0, '0, "C5.P0.R.FIXED_LAST"));

    seq1.push_item(mk_wr_burst(p1_wrap_base, 2'b10, 3'd3, 8'd3, 4'h9, 64'hC5C5_0001_0000_5000, {BYTES_PER_BEAT{1'b1}}));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, p1_wrap_base, 2'b10, 3'd3, 8'd3, 4'hA, '0, '0, "C5.P1.R.WRAP_BASE"));

    seq1.push_item(mk_wr_burst(p1_wrap_off, 2'b10, 3'd3, 8'd3, 4'hB, 64'hC5C5_0001_0000_5100, {BYTES_PER_BEAT{1'b1}}));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, p1_wrap_off, 2'b10, 3'd3, 8'd3, 4'hC, '0, '0, "C5.P1.R.WRAP_OFF"));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_5] Start: WRAP exact/off + FIXED last-wins. p0_wrap_base=0x%0h p0_wrap_off=0x%0h p0_fixed=0x%0h | p1_wrap_base=0x%0h p1_wrap_off=0x%0h",
                p0_wrap_base, p0_wrap_off, p0_fixed, p1_wrap_base, p1_wrap_off),
      UVM_MEDIUM)

    fork
      begin seq0.start(env_h.p0_agent.seqr); end
      begin #1ns; seq1.start(env_h.p1_agent.seqr); end
    join

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_5] Done.", UVM_MEDIUM)
  endtask

  // ============================================================
  // Case 6: WRAP burst edge cases (8 beats, 64B boundary)
  // ============================================================
  task automatic run_case_6_wrap_edges();
    axi_mm_corner_step_seq seq0;
    axi_mm_corner_step_seq seq1;

    logic [ADDR_WIDTH-1:0] p0_wrap_base, p1_wrap_base;
    logic [ADDR_WIDTH-1:0] p0_wA, p0_wB;
    logic [ADDR_WIDTH-1:0] p1_wA, p1_wB;

    localparam int WRAP_BEATS = 8;
    localparam int WRAP_BYTES = WRAP_BEATS * BYTES_PER_BEAT; // 64
    logic [ADDR_WIDTH-1:0] wrap_align_mask;

    wrap_align_mask = ~(WRAP_BYTES-1);

    p0_wrap_base = (WIN0_BASE + 32'h0100) & wrap_align_mask;
    p1_wrap_base = (WIN1_BASE + 32'h0100) & wrap_align_mask;

    p0_wA = align_to_beat(p0_wrap_base + 32'h38);
    p0_wB = align_to_beat(p0_wrap_base + 32'h30);

    p1_wA = align_to_beat(p1_wrap_base + 32'h38);
    p1_wB = align_to_beat(p1_wrap_base + 32'h30);

    seq0 = axi_mm_corner_step_seq::type_id::create("C6_seq0");
    seq1 = axi_mm_corner_step_seq::type_id::create("C6_seq1");

    seq0.push_item(mk_wr_burst(p0_wA, 2'b10, 3'd3, 8'd7, 4'h1, 64'hC6C6_F0EA_0000_0000, {BYTES_PER_BEAT{1'b1}}));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_wA, 2'b10, 3'd3, 8'd7, 4'h2, '0, '0, "C6.P0.R.WA"));

    seq0.push_item(mk_wr_burst(p0_wB, 2'b10, 3'd3, 8'd7, 4'h3, 64'hC6C6_F0EB_0000_0000, {BYTES_PER_BEAT{1'b1}}));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_wB, 2'b10, 3'd3, 8'd7, 4'h4, '0, '0, "C6.P0.R.WB"));

    seq1.push_item(mk_wr_burst(p1_wA, 2'b10, 3'd3, 8'd7, 4'h9, 64'hC6C6_F1EA_0000_0000, {BYTES_PER_BEAT{1'b1}}));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, p1_wA, 2'b10, 3'd3, 8'd7, 4'hA, '0, '0, "C6.P1.R.WA"));

    seq1.push_item(mk_wr_burst(p1_wB, 2'b10, 3'd3, 8'd7, 4'hB, 64'hC6C6_F1EB_0000_0000, {BYTES_PER_BEAT{1'b1}}));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, p1_wB, 2'b10, 3'd3, 8'd7, 4'hC, '0, '0, "C6.P1.R.WB"));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_6] Start: WRAP edges (8 beats, 64B boundary). P0 base=0x%0h A=0x%0h B=0x%0h | P1 base=0x%0h A=0x%0h B=0x%0h",
                p0_wrap_base, p0_wA, p0_wB, p1_wrap_base, p1_wA, p1_wB),
      UVM_MEDIUM)

    fork
      begin seq0.start(env_h.p0_agent.seqr); end
      begin #1ns; seq1.start(env_h.p1_agent.seqr); end
    join

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_6] Done.", UVM_MEDIUM)
  endtask

  // ============================================================
  // Case 7: Partial WSTRB patterns (insert delay before each read)
  // ============================================================
  task automatic run_case_7_wstrb_patterns();
    axi_mm_corner_step_seq seq0;
    axi_mm_corner_step_seq seq1;

    logic [ADDR_WIDTH-1:0] p0_addr, p1_addr;

    p0_addr = align_to_beat(WIN0_BASE + 32'h0180);
    p1_addr = align_to_beat(WIN1_BASE + 32'h0180);

    seq0 = axi_mm_corner_step_seq::type_id::create("C7_seq0");
    seq1 = axi_mm_corner_step_seq::type_id::create("C7_seq1");

    // P0 patterns
    seq0.push_item(mk_tr(0, p0_addr, 2'b01, 3'd3, 8'd0, 4'h1, 8'hFF, 64'hC7C7_F0A0_0000_0000, "C7.P0.SEED"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_addr, 2'b01, 3'd3, 8'd0, 4'h2, '0, '0, "C7.P0.R.SEED"));

    seq0.push_item(mk_tr(0, p0_addr, 2'b01, 3'd3, 8'd0, 4'h3, 8'h00, 64'hDEAD_BEEF_DEAD_BEEF, "C7.P0.WSTRB00"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_addr, 2'b01, 3'd3, 8'd0, 4'h4, '0, '0, "C7.P0.R.AFTER00"));

    seq0.push_item(mk_tr(0, p0_addr, 2'b01, 3'd3, 8'd0, 4'h5, 8'h0F, 64'h1111_2222_3333_4444, "C7.P0.WSTRB0F"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_addr, 2'b01, 3'd3, 8'd0, 4'h6, '0, '0, "C7.P0.R.AFTER0F"));

    seq0.push_item(mk_tr(0, p0_addr, 2'b01, 3'd3, 8'd0, 4'h7, 8'hF0, 64'hAAAA_BBBB_CCCC_DDDD, "C7.P0.WSTRBF0"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_addr, 2'b01, 3'd3, 8'd0, 4'h8, '0, '0, "C7.P0.R.AFTERF0"));

    seq0.push_item(mk_tr(0, p0_addr, 2'b01, 3'd3, 8'd0, 4'h9, 8'hAA, 64'h0123_4567_89AB_CDEF, "C7.P0.WSTRBAA"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_addr, 2'b01, 3'd3, 8'd0, 4'hA, '0, '0, "C7.P0.R.AFTERAA"));

    seq0.push_item(mk_tr(0, p0_addr, 2'b01, 3'd3, 8'd0, 4'hB, 8'h55, 64'hFEDC_BA98_7654_3210, "C7.P0.WSTRB55"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_addr, 2'b01, 3'd3, 8'd0, 4'hC, '0, '0, "C7.P0.R.AFTER55"));

    // P1 patterns
    seq1.push_item(mk_tr(0, p1_addr, 2'b01, 3'd3, 8'd0, 4'h9, 8'hFF, 64'hC7C7_F1A0_0000_0000, "C7.P1.SEED"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, p1_addr, 2'b01, 3'd3, 8'd0, 4'hA, '0, '0, "C7.P1.R.SEED"));

    seq1.push_item(mk_tr(0, p1_addr, 2'b01, 3'd3, 8'd0, 4'hB, 8'h00, 64'hCAFE_BABE_CAFE_BABE, "C7.P1.WSTRB00"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, p1_addr, 2'b01, 3'd3, 8'd0, 4'hC, '0, '0, "C7.P1.R.AFTER00"));

    seq1.push_item(mk_tr(0, p1_addr, 2'b01, 3'd3, 8'd0, 4'hD, 8'h0F, 64'h5555_6666_7777_8888, "C7.P1.WSTRB0F"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, p1_addr, 2'b01, 3'd3, 8'd0, 4'hE, '0, '0, "C7.P1.R.AFTER0F"));

    seq1.push_item(mk_tr(0, p1_addr, 2'b01, 3'd3, 8'd0, 4'hF, 8'hF0, 64'h9999_AAAA_BBBB_CCCC, "C7.P1.WSTRBF0"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, p1_addr, 2'b01, 3'd3, 8'd0, 4'h0, '0, '0, "C7.P1.R.AFTERF0"));

    seq1.push_item(mk_tr(0, p1_addr, 2'b01, 3'd3, 8'd0, 4'h1, 8'hAA, 64'h0F0E_0D0C_0B0A_0908, "C7.P1.WSTRBAA"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, p1_addr, 2'b01, 3'd3, 8'd0, 4'h2, '0, '0, "C7.P1.R.AFTERAA"));

    seq1.push_item(mk_tr(0, p1_addr, 2'b01, 3'd3, 8'd0, 4'h3, 8'h55, 64'h0809_0A0B_0C0D_0E0F, "C7.P1.WSTRB55"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, p1_addr, 2'b01, 3'd3, 8'd0, 4'h4, '0, '0, "C7.P1.R.AFTER55"));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_7] Start: Partial WSTRB patterns (with delay=%0t). P0 addr=0x%0h | P1 addr=0x%0h",
                POST_WRITE_DELAY, p0_addr, p1_addr),
      UVM_MEDIUM)

    fork
      begin seq0.start(env_h.p0_agent.seqr); end
      begin #1ns; seq1.start(env_h.p1_agent.seqr); end
    join

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_7] Done.", UVM_MEDIUM)
  endtask

  // ============================================================
  // Case 8A: Same-port multiple outstanding AW (split ops)
  // ============================================================
  task automatic run_case_8a_multi_aw_no_interleave_fixed_for_depth1();
    axi_mm_corner_step_seq seq0;
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
    logic [ADDR_WIDTH-1:0] a_addr, b_addr;

    localparam logic [1:0] BURST_INCR = 2'b01;
    localparam logic [2:0] SIZE_8B    = 3'd3;
    localparam logic [7:0] LEN_4B     = 8'd3; // 4 beats
    localparam logic [BYTES_PER_BEAT-1:0] WSTRB_ALL = {BYTES_PER_BEAT{1'b1}};

    seq0 = axi_mm_corner_step_seq::type_id::create("C8A_seq0_fix");

    a_addr = align_to_beat(WIN0_BASE + 32'h0200);
    b_addr = align_to_beat(WIN0_BASE + 32'h0300);

    // A: AW only
    tr = mk_tr(0, a_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8A.AW_A", 0, OP_AW_ONLY, 4'h1);
    seq0.push_item(tr);

    // A: W only
    tr = mk_wr_burst(a_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, 64'hC8A0_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h1, "C8A.W_A");
    seq0.push_item(tr);

    // B: AW only
    tr = mk_tr(0, b_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8A.AW_B", 0, OP_AW_ONLY, 4'h2);
    seq0.push_item(tr);

    // B: W only
    tr = mk_wr_burst(b_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, 64'hC8B0_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h2, "C8A.W_B");
    seq0.push_item(tr);

    // Wait B (reverse order)
    tr = mk_tr(0, b_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8A.BWAIT_B_FIRST", 0, OP_B_WAIT, 4'h2);
    seq0.push_item(tr);
    tr = mk_tr(0, a_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8A.BWAIT_A_SECOND", 0, OP_B_WAIT, 4'h1);
    seq0.push_item(tr);

    // Ensure visibility before reads
    seq0.push_delay(POST_WRITE_DELAY);

    // Readback verify
    seq0.push_item(mk_tr(1, a_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C8A.R_A", 0));
    seq0.push_item(mk_tr(1, b_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, '0, '0, "C8A.R_B", 0));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_8A_FIX] Start: depth1-friendly split write + post-write delay=%0t. A=0x%0h(id=1) B=0x%0h(id=2)",
                POST_WRITE_DELAY, a_addr, b_addr),
      UVM_MEDIUM)

    seq0.start(env_h.p0_agent.seqr);

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_8A_FIX] Done.", UVM_MEDIUM)
  endtask

  // ============================================================
  // Case 8B: outstanding writes + out-of-order B response (per port)
  // ============================================================
  task automatic run_case_8b_outstanding_ooo_b_p0p1();
    axi_mm_corner_step_seq seq0;
    axi_mm_corner_step_seq seq1;

    localparam logic [1:0] BURST_INCR = 2'b01;
    localparam logic [2:0] SIZE_8B    = 3'd3;
    localparam logic [7:0] LEN_4B     = 8'd3; // 4 beats
    localparam logic [BYTES_PER_BEAT-1:0] WSTRB_ALL = {BYTES_PER_BEAT{1'b1}};

    logic [ADDR_WIDTH-1:0] p0_a, p0_b, p1_a, p1_b;

    p0_a = align_to_beat(WIN0_BASE + 32'h0200);
    p0_b = align_to_beat(WIN0_BASE + 32'h0300);
    p1_a = align_to_beat(WIN1_BASE + 32'h0200);
    p1_b = align_to_beat(WIN1_BASE + 32'h0300);

    seq0 = axi_mm_corner_step_seq::type_id::create("C8B_seq0");
    seq1 = axi_mm_corner_step_seq::type_id::create("C8B_seq1");

    // P0 plan
    seq0.push_item(mk_tr(0, p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8B.P0.AW_A", 0, OP_AW_ONLY, 4'h1));
    seq0.push_item(mk_tr(0, p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8B.P0.AW_B", 0, OP_AW_ONLY, 4'h2));
    seq0.push_item(mk_wr_burst(p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, 64'hC8A0_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h1, "C8B.P0.W_A"));
    seq0.push_item(mk_wr_burst(p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, 64'hC8B0_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h2, "C8B.P0.W_B"));
    seq0.push_item(mk_tr(0, p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8B.P0.BWAIT_B_FIRST", 0, OP_B_WAIT, 4'h2));
    seq0.push_item(mk_tr(0, p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8B.P0.BWAIT_A_SECOND", 0, OP_B_WAIT, 4'h1));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C8B.P0.R_A", 0));
    seq0.push_item(mk_tr(1, p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, '0, '0, "C8B.P0.R_B", 0));

    // P1 plan
    seq1.push_item(mk_tr(0, p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8B.P1.AW_A", 0, OP_AW_ONLY, 4'h1));
    seq1.push_item(mk_tr(0, p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8B.P1.AW_B", 0, OP_AW_ONLY, 4'h2));
    seq1.push_item(mk_wr_burst(p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, 64'hC8A1_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h1, "C8B.P1.W_A"));
    seq1.push_item(mk_wr_burst(p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, 64'hC8B1_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h2, "C8B.P1.W_B"));
    seq1.push_item(mk_tr(0, p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8B.P1.BWAIT_B_FIRST", 0, OP_B_WAIT, 4'h2));
    seq1.push_item(mk_tr(0, p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8B.P1.BWAIT_A_SECOND", 0, OP_B_WAIT, 4'h1));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C8B.P1.R_A", 0));
    seq1.push_item(mk_tr(1, p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, '0, '0, "C8B.P1.R_B", 0));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_8B] Start: outstanding writes + reverse B_WAIT + post-write delay=%0t. P0(A=0x%0h,B=0x%0h) P1(A=0x%0h,B=0x%0h)",
                POST_WRITE_DELAY, p0_a, p0_b, p1_a, p1_b),
      UVM_MEDIUM)

    fork
      begin seq0.start(env_h.p0_agent.seqr); end
      begin #1ns; seq1.start(env_h.p1_agent.seqr); end
    join

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_8B] Done.", UVM_MEDIUM)
  endtask

  // ============================================================
  // Case 8 (BONUS): AW backpressure observable (depth4 style)
  // NOTE: add post-write delay before reads
  // ============================================================
  task automatic run_case_8_outstanding_aw_depth4_p0p1();
    axi_mm_corner_step_seq seq0;
    axi_mm_corner_step_seq seq1;

    localparam logic [1:0] BURST_INCR = 2'b01;
    localparam logic [2:0] SIZE_8B    = 3'd3;
    localparam logic [7:0] LEN_4B     = 8'd3; // 4 beats
    localparam logic [BYTES_PER_BEAT-1:0] WSTRB_ALL = {BYTES_PER_BEAT{1'b1}};

    logic [ADDR_WIDTH-1:0] p0_a, p0_b, p0_c, p0_d;
    logic [ADDR_WIDTH-1:0] p1_a, p1_b, p1_c, p1_d;

    p0_a = align_to_beat(WIN0_BASE + 32'h0200);
    p0_b = align_to_beat(WIN0_BASE + 32'h0300);
    p0_c = align_to_beat(WIN0_BASE + 32'h0400);
    p0_d = align_to_beat(WIN0_BASE + 32'h0500);

    p1_a = align_to_beat(WIN1_BASE + 32'h0200);
    p1_b = align_to_beat(WIN1_BASE + 32'h0300);
    p1_c = align_to_beat(WIN1_BASE + 32'h0400);
    p1_d = align_to_beat(WIN1_BASE + 32'h0500);

    seq0 = axi_mm_corner_step_seq::type_id::create("C8_seq0");
    seq1 = axi_mm_corner_step_seq::type_id::create("C8_seq1");

    // P0: AW A,B,C
    seq0.push_item(mk_tr(0, p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8.P0.AW_A", 0, OP_AW_ONLY, 4'h1));
    seq0.push_item(mk_tr(0, p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8.P0.AW_B", 0, OP_AW_ONLY, 4'h2));
    seq0.push_item(mk_tr(0, p0_c, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C8.P0.AW_C", 0, OP_AW_ONLY, 4'h3));

    // W(A) first
    seq0.push_item(mk_wr_burst(p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, 64'hC8A0_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h1, "C8.P0.W_A_FIRST"));

    // AW(D) expect stall
    seq0.push_item(mk_tr(0, p0_d, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, '0, '0, "C8.P0.AW_D_EXPECT_STALL", 0, OP_AW_ONLY, 4'h4));

    // remaining W B,C,D
    seq0.push_item(mk_wr_burst(p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, 64'hC8B0_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h2, "C8.P0.W_B"));
    seq0.push_item(mk_wr_burst(p0_c, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, 64'hC8C0_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h3, "C8.P0.W_C"));
    seq0.push_item(mk_wr_burst(p0_d, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, 64'hC8D0_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h4, "C8.P0.W_D"));

    // B_WAIT reverse D,C,B,A
    seq0.push_item(mk_tr(0, p0_d, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, '0, '0, "C8.P0.BWAIT_D", 0, OP_B_WAIT, 4'h4));
    seq0.push_item(mk_tr(0, p0_c, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C8.P0.BWAIT_C", 0, OP_B_WAIT, 4'h3));
    seq0.push_item(mk_tr(0, p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8.P0.BWAIT_B", 0, OP_B_WAIT, 4'h2));
    seq0.push_item(mk_tr(0, p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8.P0.BWAIT_A", 0, OP_B_WAIT, 4'h1));

    seq0.push_delay(POST_WRITE_DELAY);

    // Reads
    seq0.push_item(mk_tr(1, p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h8, '0, '0, "C8.P0.R_A", 0));
    seq0.push_item(mk_tr(1, p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h9, '0, '0, "C8.P0.R_B", 0));
    seq0.push_item(mk_tr(1, p0_c, BURST_INCR, SIZE_8B, LEN_4B, 4'hA, '0, '0, "C8.P0.R_C", 0));
    seq0.push_item(mk_tr(1, p0_d, BURST_INCR, SIZE_8B, LEN_4B, 4'hB, '0, '0, "C8.P0.R_D", 0));

    // P1: same plan
    seq1.push_item(mk_tr(0, p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8.P1.AW_A", 0, OP_AW_ONLY, 4'h1));
    seq1.push_item(mk_tr(0, p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8.P1.AW_B", 0, OP_AW_ONLY, 4'h2));
    seq1.push_item(mk_tr(0, p1_c, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C8.P1.AW_C", 0, OP_AW_ONLY, 4'h3));

    seq1.push_item(mk_wr_burst(p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, 64'hC8A1_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h1, "C8.P1.W_A_FIRST"));
    seq1.push_item(mk_tr(0, p1_d, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, '0, '0, "C8.P1.AW_D_EXPECT_STALL", 0, OP_AW_ONLY, 4'h4));

    seq1.push_item(mk_wr_burst(p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, 64'hC8B1_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h2, "C8.P1.W_B"));
    seq1.push_item(mk_wr_burst(p1_c, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, 64'hC8C1_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h3, "C8.P1.W_C"));
    seq1.push_item(mk_wr_burst(p1_d, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, 64'hC8D1_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h4, "C8.P1.W_D"));

    seq1.push_item(mk_tr(0, p1_d, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, '0, '0, "C8.P1.BWAIT_D", 0, OP_B_WAIT, 4'h4));
    seq1.push_item(mk_tr(0, p1_c, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C8.P1.BWAIT_C", 0, OP_B_WAIT, 4'h3));
    seq1.push_item(mk_tr(0, p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8.P1.BWAIT_B", 0, OP_B_WAIT, 4'h2));
    seq1.push_item(mk_tr(0, p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8.P1.BWAIT_A", 0, OP_B_WAIT, 4'h1));

    seq1.push_delay(POST_WRITE_DELAY);

    seq1.push_item(mk_tr(1, p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h8, '0, '0, "C8.P1.R_A", 0));
    seq1.push_item(mk_tr(1, p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h9, '0, '0, "C8.P1.R_B", 0));
    seq1.push_item(mk_tr(1, p1_c, BURST_INCR, SIZE_8B, LEN_4B, 4'hA, '0, '0, "C8.P1.R_C", 0));
    seq1.push_item(mk_tr(1, p1_d, BURST_INCR, SIZE_8B, LEN_4B, 4'hB, '0, '0, "C8.P1.R_D", 0));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_8_BONUS] Start: AW backpressure observable + post-write delay=%0t. P0(A=0x%0h,B=0x%0h,C=0x%0h,D=0x%0h) P1(A=0x%0h,B=0x%0h,C=0x%0h,D=0x%0h)",
                POST_WRITE_DELAY, p0_a, p0_b, p0_c, p0_d, p1_a, p1_b, p1_c, p1_d),
      UVM_MEDIUM)

    fork
      begin seq0.start(env_h.p0_agent.seqr); end
      begin #1ns; seq1.start(env_h.p1_agent.seqr); end
    join

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_8_BONUS] Done.", UVM_MEDIUM)
  endtask

  // ============================================================
  // Case 9A / 9B: Mixed-ID ordering
  // NOTE: add post-write delay before readbacks
  // ============================================================
  task automatic run_case_9a_mixed_id_ordering_p0();
    axi_mm_corner_step_seq seq0;

    localparam logic [1:0] BURST_INCR = 2'b01;
    localparam logic [2:0] SIZE_8B    = 3'd3;
    localparam logic [7:0] LEN_4B     = 8'd3; // 4 beats
    localparam logic [BYTES_PER_BEAT-1:0] WSTRB_ALL = {BYTES_PER_BEAT{1'b1}};

    logic [ADDR_WIDTH-1:0] a1, a2, a3;

    a1 = align_to_beat(WIN0_BASE + 32'h0200);
    a2 = align_to_beat(WIN0_BASE + 32'h0300);
    a3 = align_to_beat(WIN0_BASE + 32'h0400);

    seq0 = axi_mm_corner_step_seq::type_id::create("C9A_seq0");

    seq0.push_item(mk_tr(0, a1, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C9A.P0.AW_ID1", 0, OP_AW_ONLY, 4'h1));
    seq0.push_item(mk_tr(0, a2, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C9A.P0.AW_ID2", 0, OP_AW_ONLY, 4'h2));
    seq0.push_item(mk_tr(0, a3, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C9A.P0.AW_ID3", 0, OP_AW_ONLY, 4'h3));

    seq0.push_item(mk_wr_burst(a1, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, 64'hC9A1_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h1, "C9A.P0.W_ID1"));
    seq0.push_item(mk_wr_burst(a2, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, 64'hC9A2_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h2, "C9A.P0.W_ID2"));
    seq0.push_item(mk_wr_burst(a3, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, 64'hC9A3_0000_0000_0000, WSTRB_ALL, OP_W_ONLY, 4'h3, "C9A.P0.W_ID3"));

    seq0.push_item(mk_tr(0, a2, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C9A.P0.BWAIT_ID2_FIRST", 0, OP_B_WAIT, 4'h2));
    seq0.push_item(mk_tr(0, a1, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C9A.P0.BWAIT_ID1_SECOND", 0, OP_B_WAIT, 4'h1));
    seq0.push_item(mk_tr(0, a3, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C9A.P0.BWAIT_ID3_THIRD", 0, OP_B_WAIT, 4'h3));

    seq0.push_delay(POST_WRITE_DELAY);

    seq0.push_item(mk_tr(1, a1, BURST_INCR, SIZE_8B, LEN_4B, 4'h8, '0, '0, "C9A.P0.R_ADDR1", 0));
    seq0.push_item(mk_tr(1, a2, BURST_INCR, SIZE_8B, LEN_4B, 4'h9, '0, '0, "C9A.P0.R_ADDR2", 0));
    seq0.push_item(mk_tr(1, a3, BURST_INCR, SIZE_8B, LEN_4B, 4'hA, '0, '0, "C9A.P0.R_ADDR3", 0));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_9A] Start: P0 mixed-ID ordering + post-write delay=%0t. addr1=0x%0h addr2=0x%0h addr3=0x%0h",
                POST_WRITE_DELAY, a1, a2, a3),
      UVM_MEDIUM)

    seq0.start(env_h.p0_agent.seqr);

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_9A] Done.", UVM_MEDIUM)
  endtask

  task automatic run_case_9b_mixed_id_ordering_p0p1();
    axi_mm_corner_step_seq seq0;
    axi_mm_corner_step_seq seq1;

    localparam logic [1:0] BURST_INCR = 2'b01;
    localparam logic [2:0] SIZE_8B    = 3'd3;
    localparam logic [7:0] LEN_4B     = 8'd3; // 4 beats
    localparam logic [BYTES_PER_BEAT-1:0] WSTRB_ALL = {BYTES_PER_BEAT{1'b1}};

    localparam logic [ID_WIDTH-1:0] ID1 = 'h1;
    localparam logic [ID_WIDTH-1:0] ID2 = 'h2;
    localparam logic [ID_WIDTH-1:0] ID3 = 'h3;

    localparam logic [ID_WIDTH-1:0] RID_A = 'h8;
    localparam logic [ID_WIDTH-1:0] RID_B = 'h9;
    localparam logic [ID_WIDTH-1:0] RID_C = 'hA;

    logic [ADDR_WIDTH-1:0] p0_a, p0_b, p0_c;
    logic [ADDR_WIDTH-1:0] p1_a, p1_b, p1_c;

    p0_a = align_to_beat(WIN0_BASE + 32'h0200);
    p0_b = align_to_beat(WIN0_BASE + 32'h0300);
    p0_c = align_to_beat(WIN0_BASE + 32'h0400);

    p1_a = align_to_beat(WIN1_BASE + 32'h0200);
    p1_b = align_to_beat(WIN1_BASE + 32'h0300);
    p1_c = align_to_beat(WIN1_BASE + 32'h0400);

    seq0 = axi_mm_corner_step_seq::type_id::create("C9b_seq0");
    seq1 = axi_mm_corner_step_seq::type_id::create("C9b_seq1");

    // P0
    seq0.push_item(mk_tr(0, p0_a, BURST_INCR, SIZE_8B, LEN_4B, ID1, '0, '0, "C9B.P0.AW_A(ID1)", 0, OP_AW_ONLY, ID1));
    seq0.push_item(mk_tr(0, p0_b, BURST_INCR, SIZE_8B, LEN_4B, ID2, '0, '0, "C9B.P0.AW_B(ID2)", 0, OP_AW_ONLY, ID2));
    seq0.push_item(mk_tr(0, p0_c, BURST_INCR, SIZE_8B, LEN_4B, ID3, '0, '0, "C9B.P0.AW_C(ID3)", 0, OP_AW_ONLY, ID3));

    seq0.push_item(mk_wr_burst(p0_a, BURST_INCR, SIZE_8B, LEN_4B, ID1, 64'hC9B0_A000_0000_0000, WSTRB_ALL, OP_W_ONLY, ID1, "C9B.P0.W_A(ID1)"));
    seq0.push_item(mk_wr_burst(p0_b, BURST_INCR, SIZE_8B, LEN_4B, ID2, 64'hC9B0_B000_0000_0000, WSTRB_ALL, OP_W_ONLY, ID2, "C9B.P0.W_B(ID2)"));
    seq0.push_item(mk_wr_burst(p0_c, BURST_INCR, SIZE_8B, LEN_4B, ID3, 64'hC9B0_C000_0000_0000, WSTRB_ALL, OP_W_ONLY, ID3, "C9B.P0.W_C(ID3)"));

    seq0.push_item(mk_tr(0, p0_b, BURST_INCR, SIZE_8B, LEN_4B, ID2, '0, '0, "C9B.P0.BWAIT_ID2_FIRST", 0, OP_B_WAIT, ID2));
    seq0.push_item(mk_tr(0, p0_a, BURST_INCR, SIZE_8B, LEN_4B, ID1, '0, '0, "C9B.P0.BWAIT_ID1_SECOND", 0, OP_B_WAIT, ID1));
    seq0.push_item(mk_tr(0, p0_c, BURST_INCR, SIZE_8B, LEN_4B, ID3, '0, '0, "C9B.P0.BWAIT_ID3_THIRD", 0, OP_B_WAIT, ID3));

    seq0.push_delay(POST_WRITE_DELAY);

    seq0.push_item(mk_tr(1, p0_a, BURST_INCR, SIZE_8B, LEN_4B, RID_A, '0, '0, "C9B.P0.R_A", 0));
    seq0.push_item(mk_tr(1, p0_b, BURST_INCR, SIZE_8B, LEN_4B, RID_B, '0, '0, "C9B.P0.R_B", 0));
    seq0.push_item(mk_tr(1, p0_c, BURST_INCR, SIZE_8B, LEN_4B, RID_C, '0, '0, "C9B.P0.R_C", 0));

    // P1
    seq1.push_item(mk_tr(0, p1_a, BURST_INCR, SIZE_8B, LEN_4B, ID1, '0, '0, "C9B.P1.AW_A(ID1)", 0, OP_AW_ONLY, ID1));
    seq1.push_item(mk_tr(0, p1_b, BURST_INCR, SIZE_8B, LEN_4B, ID2, '0, '0, "C9B.P1.AW_B(ID2)", 0, OP_AW_ONLY, ID2));
    seq1.push_item(mk_tr(0, p1_c, BURST_INCR, SIZE_8B, LEN_4B, ID3, '0, '0, "C9B.P1.AW_C(ID3)", 0, OP_AW_ONLY, ID3));

    seq1.push_item(mk_wr_burst(p1_a, BURST_INCR, SIZE_8B, LEN_4B, ID1, 64'hC9B1_A000_0000_0000, WSTRB_ALL, OP_W_ONLY, ID1, "C9B.P1.W_A(ID1)"));
    seq1.push_item(mk_wr_burst(p1_b, BURST_INCR, SIZE_8B, LEN_4B, ID2, 64'hC9B1_B000_0000_0000, WSTRB_ALL, OP_W_ONLY, ID2, "C9B.P1.W_B(ID2)"));
    seq1.push_item(mk_wr_burst(p1_c, BURST_INCR, SIZE_8B, LEN_4B, ID3, 64'hC9B1_C000_0000_0000, WSTRB_ALL, OP_W_ONLY, ID3, "C9B.P1.W_C(ID3)"));

    seq1.push_item(mk_tr(0, p1_c, BURST_INCR, SIZE_8B, LEN_4B, ID3, '0, '0, "C9B.P1.BWAIT_ID3_FIRST", 0, OP_B_WAIT, ID3));
    seq1.push_item(mk_tr(0, p1_a, BURST_INCR, SIZE_8B, LEN_4B, ID1, '0, '0, "C9B.P1.BWAIT_ID1_SECOND", 0, OP_B_WAIT, ID1));
    seq1.push_item(mk_tr(0, p1_b, BURST_INCR, SIZE_8B, LEN_4B, ID2, '0, '0, "C9B.P1.BWAIT_ID2_THIRD", 0, OP_B_WAIT, ID2));

    seq1.push_delay(POST_WRITE_DELAY);

    seq1.push_item(mk_tr(1, p1_a, BURST_INCR, SIZE_8B, LEN_4B, RID_A, '0, '0, "C9B.P1.R_A", 0));
    seq1.push_item(mk_tr(1, p1_b, BURST_INCR, SIZE_8B, LEN_4B, RID_B, '0, '0, "C9B.P1.R_B", 0));
    seq1.push_item(mk_tr(1, p1_c, BURST_INCR, SIZE_8B, LEN_4B, RID_C, '0, '0, "C9B.P1.R_C", 0));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_9B] Start: Mixed-ID ordering P0/P1 concurrent + post-write delay=%0t.",
                POST_WRITE_DELAY),
      UVM_MEDIUM)

    fork
      begin seq0.start(env_h.p0_agent.seqr); end
      begin #1ns; seq1.start(env_h.p1_agent.seqr); end
    join

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_9B] Done.", UVM_MEDIUM)
  endtask

  // ============================================================
  // Case 10: Reset During Activity (STABLE VERSION)
  // ============================================================
  task automatic run_case_10_reset_during_activity();

    axi_mm_corner_step_seq seq0_a, seq1_a;
    axi_mm_corner_step_seq seq0_b, seq1_b;
    axi_mm_reset_seq rst_seq;

    localparam logic [1:0] BURST_INCR = 2'b01;
    localparam logic [2:0] SIZE_8B    = 3'd3;

    localparam logic [7:0] LEN_A = 8'd15;
    localparam logic [7:0] LEN_B = 8'd3;

    localparam logic [BYTES_PER_BEAT-1:0] WSTRB_ALL = {BYTES_PER_BEAT{1'b1}};

    localparam logic [ID_WIDTH-1:0] WID1 = 'h1;
    localparam logic [ID_WIDTH-1:0] WID2 = 'h2;
    localparam logic [ID_WIDTH-1:0] WID3 = 'h3;
    localparam logic [ID_WIDTH-1:0] WID4 = 'h4;

    localparam logic [ID_WIDTH-1:0] RID_A = 'h8;
    localparam logic [ID_WIDTH-1:0] RID_C = 'hA;

    logic [ADDR_WIDTH-1:0] p0_a, p0_b, p0_c, p0_d;
    logic [ADDR_WIDTH-1:0] p1_a, p1_b, p1_c, p1_d;

    p0_a = align_to_beat(WIN0_BASE + 32'h0200);
    p0_b = align_to_beat(WIN0_BASE + 32'h0300);
    p0_c = align_to_beat(WIN0_BASE + 32'h0400);
    p0_d = align_to_beat(WIN0_BASE + 32'h0500);

    p1_a = align_to_beat(WIN1_BASE + 32'h0200);
    p1_b = align_to_beat(WIN1_BASE + 32'h0300);
    p1_c = align_to_beat(WIN1_BASE + 32'h0400);
    p1_d = align_to_beat(WIN1_BASE + 32'h0500);

    // Phase A (fire and forget)
    seq0_a = axi_mm_corner_step_seq::type_id::create("C10_seq0_A");
    seq1_a = axi_mm_corner_step_seq::type_id::create("C10_seq1_A");

    seq0_a.push_item(mk_wr_burst(p0_a, BURST_INCR, SIZE_8B, LEN_A, WID1, 64'hC10A_0A00_0000_0000, WSTRB_ALL));
    seq0_a.push_item(mk_wr_burst(p0_b, BURST_INCR, SIZE_8B, LEN_A, WID2, 64'hC10A_0B00_0000_0000, WSTRB_ALL));
    seq0_a.push_item(mk_wr_burst(p0_c, BURST_INCR, SIZE_8B, LEN_A, WID3, 64'hC10A_0C00_0000_0000, WSTRB_ALL));
    seq0_a.push_item(mk_wr_burst(p0_d, BURST_INCR, SIZE_8B, LEN_A, WID4, 64'hC10A_0D00_0000_0000, WSTRB_ALL));

    seq1_a.push_item(mk_wr_burst(p1_a, BURST_INCR, SIZE_8B, LEN_A, WID1, 64'hC10A_1A00_0000_0000, WSTRB_ALL));
    seq1_a.push_item(mk_wr_burst(p1_b, BURST_INCR, SIZE_8B, LEN_A, WID2, 64'hC10A_1B00_0000_0000, WSTRB_ALL));
    seq1_a.push_item(mk_wr_burst(p1_c, BURST_INCR, SIZE_8B, LEN_A, WID3, 64'hC10A_1C00_0000_0000, WSTRB_ALL));
    seq1_a.push_item(mk_wr_burst(p1_d, BURST_INCR, SIZE_8B, LEN_A, WID4, 64'hC10A_1D00_0000_0000, WSTRB_ALL));

    `uvm_info("CORNER_TEST",
        "[CASE_10] Phase A start (no stop, reset will abort driver)",
        UVM_MEDIUM)

    fork
      seq0_a.start(env_h.p0_agent.seqr);
      begin #1ns; seq1_a.start(env_h.p1_agent.seqr); end
    join_none

    #400ns;

    `uvm_info("CORNER_TEST",
        "[CASE_10] *** MID-FLIGHT RESET ASSERT ***",
        UVM_MEDIUM)

    rst_seq = axi_mm_reset_seq::type_id::create("case10_mid_reset");
    rst_seq.assert_cycles   = 50;
    rst_seq.deassert_cycles = 10;
    rst_seq.start(env_h.rst_agent.seqr);

    // wait for monitor ignore window + scoreboard resume
    #(POST_RESET_DELAY);

    `uvm_info("CORNER_TEST",
        "[CASE_10] Phase B start (post-reset verify)",
        UVM_MEDIUM)

    seq0_b = axi_mm_corner_step_seq::type_id::create("C10_seq0_B");
    seq1_b = axi_mm_corner_step_seq::type_id::create("C10_seq1_B");

    seq0_b.push_item(mk_wr_burst(p0_a, BURST_INCR, SIZE_8B, LEN_B, WID1, 64'hC10B_0A00_0000_0000, WSTRB_ALL));
    seq0_b.push_delay(POST_WRITE_DELAY);
    seq0_b.push_item(mk_tr(1, p0_a, BURST_INCR, SIZE_8B, LEN_B, RID_A, '0, '0, "C10B.P0.R_A", 0));

    seq1_b.push_item(mk_wr_burst(p1_c, BURST_INCR, SIZE_8B, LEN_B, WID3, 64'hC10B_1C00_0000_0000, WSTRB_ALL));
    seq1_b.push_delay(POST_WRITE_DELAY);
    seq1_b.push_item(mk_tr(1, p1_c, BURST_INCR, SIZE_8B, LEN_B, RID_C, '0, '0, "C10B.P1.R_C", 0));

    fork
      seq0_b.start(env_h.p0_agent.seqr);
      begin #1ns; seq1_b.start(env_h.p1_agent.seqr); end
    join

    #200ns;
    `uvm_info("CORNER_TEST","[CASE_10] Done.", UVM_MEDIUM)
  endtask

  // ============================================================
  // Case 11 - MAX legal burst length (LEN=255)
  // ============================================================
  task automatic run_case_11_max_len_burst();
    axi_mm_corner_step_seq seq0;
    axi_mm_corner_step_seq seq1;

    logic [ADDR_WIDTH-1:0] p0_addr, p1_addr;
    localparam logic [1:0] BURST_INCR = 2'b01;
    localparam logic [2:0] SIZE_8B    = 3'd3;
    localparam logic [7:0] LEN_MAX    = 8'd255;

    p0_addr = align_to_beat(WIN0_BASE + 32'h0400);
    p1_addr = align_to_beat(WIN1_BASE + 32'h0400);

    seq0 = axi_mm_corner_step_seq::type_id::create("C11_seq0");
    seq1 = axi_mm_corner_step_seq::type_id::create("C11_seq1");

    seq0.push_item(mk_wr_burst(p0_addr, BURST_INCR, SIZE_8B, LEN_MAX, 4'h1, 64'hC11_0000_0000_0000, {BYTES_PER_BEAT{1'b1}}));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, p0_addr, BURST_INCR, SIZE_8B, LEN_MAX, 4'h2, '0, '0, "C11.P0.R.MAXLEN", 0));

    seq1.push_item(mk_wr_burst(p1_addr, BURST_INCR, SIZE_8B, LEN_MAX, 4'h3, 64'hC11_1000_0000_0000, {BYTES_PER_BEAT{1'b1}}));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, p1_addr, BURST_INCR, SIZE_8B, LEN_MAX, 4'h4, '0, '0, "C11.P1.R.MAXLEN", 0));

    banner_case("11", "MAX LEN=255 INCR burst write/read (with post-write delay)");

    fork
      seq0.start(env_h.p0_agent.seqr);
      begin #1ns; seq1.start(env_h.p1_agent.seqr); end
    join

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_11] Done.", UVM_MEDIUM)
  endtask

  // ============================================================
  // Case 12 / 13 / 14
  // - Case12/13 already have lots of ops; we only add one delay before final reads
  // ============================================================

  task automatic run_case_12_narrow_sizes();
    // Keep your original content mostly intact,
    // but switch to step-seq so we can insert delays before key reads.
    axi_mm_corner_step_seq seq0;
    axi_mm_corner_step_seq seq1;

    logic [ADDR_WIDTH-1:0] base0, base1;
    logic [DATA_WIDTH-1:0] seed0, seed1;
    logic [DATA_WIDTH-1:0] wdata;
    logic [BYTES_PER_BEAT-1:0] wmask;

    base0 = align_to_beat(WIN0_BASE + 32'h0700);
    base1 = align_to_beat(WIN1_BASE + 32'h0700);

    seq0 = axi_mm_corner_step_seq::type_id::create("C12_seq0");
    seq1 = axi_mm_corner_step_seq::type_id::create("C12_seq1");

    seed0 = 64'h1212_3434_5656_7878;
    seed1 = seed0 ^ 64'hFFFF_0000_FFFF_0000;

    banner_case("12", "Narrow sizes (1B/2B/4B) lane mapping + merge (with strategic delays)");

    // ---------------- P0 ----------------
    seq0.push_item(mk_tr(0, base0, 2'b01, 3'd3, 8'd0, 4'h1, 8'hFF, seed0, "C12.P0.SEED.FULL8B"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, base0, 2'b01, 3'd3, 8'd0, 4'h2, '0, '0, "C12.P0.R.SEED"));

    wmask = 8'b0000_0001; wdata = 64'h0000_0000_0000_00AA;
    seq0.push_item(mk_tr(0, base0, 2'b01, 3'd0, 8'd0, 4'h3, wmask, wdata, "C12.P0.W.1B@0"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, base0, 2'b01, 3'd3, 8'd0, 4'h4, '0, '0, "C12.P0.R.AFTER1B@0"));

    // (rest kept same pattern, but insert a delay before each read)
    wmask = 8'b0000_1000; wdata = 64'h0000_0000_AA00_0000;
    seq0.push_item(mk_tr(0, base0, 2'b01, 3'd0, 8'd0, 4'h5, wmask, wdata, "C12.P0.W.1B@3"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, base0, 2'b01, 3'd3, 8'd0, 4'h6, '0, '0, "C12.P0.R.AFTER1B@3"));

    wmask = 8'b1000_0000; wdata = 64'hAA00_0000_0000_0000;
    seq0.push_item(mk_tr(0, base0, 2'b01, 3'd0, 8'd0, 4'h7, wmask, wdata, "C12.P0.W.1B@7"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, base0, 2'b01, 3'd3, 8'd0, 4'h8, '0, '0, "C12.P0.R.AFTER1B@7"));

    wmask = 8'b0000_0011; wdata = 64'h0000_0000_0000_BEEF;
    seq0.push_item(mk_tr(0, base0, 2'b01, 3'd1, 8'd0, 4'h9, wmask, wdata, "C12.P0.W.2B@0"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, base0, 2'b01, 3'd3, 8'd0, 4'hA, '0, '0, "C12.P0.R.AFTER2B@0"));

    wmask = 8'b0000_1100; wdata = 64'h0000_0000_BEEF_0000;
    seq0.push_item(mk_tr(0, base0, 2'b01, 3'd1, 8'd0, 4'hB, wmask, wdata, "C12.P0.W.2B@2"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, base0, 2'b01, 3'd3, 8'd0, 4'hC, '0, '0, "C12.P0.R.AFTER2B@2"));

    wmask = 8'b0000_1111; wdata = 64'h0000_0000_CAFE_BABE;
    seq0.push_item(mk_tr(0, base0, 2'b01, 3'd2, 8'd0, 4'hD, wmask, wdata, "C12.P0.W.4B@0"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, base0, 2'b01, 3'd3, 8'd0, 4'hE, '0, '0, "C12.P0.R.AFTER4B@0"));

    wmask = 8'b1111_0000; wdata = 64'hCAFE_BABE_0000_0000;
    seq0.push_item(mk_tr(0, base0, 2'b01, 3'd2, 8'd0, 4'hF, wmask, wdata, "C12.P0.W.4B@4"));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, base0, 2'b01, 3'd3, 8'd0, 4'h0, '0, '0, "C12.P0.R.AFTER4B@4"));

    // ---------------- P1 ----------------
    seq1.push_item(mk_tr(0, base1, 2'b01, 3'd3, 8'd0, 4'h1, 8'hFF, seed1, "C12.P1.SEED.FULL8B"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, base1, 2'b01, 3'd3, 8'd0, 4'h2, '0, '0, "C12.P1.R.SEED"));

    wmask = 8'b0001_0000; wdata = 64'h0000_00AA_0000_0000;
    seq1.push_item(mk_tr(0, base1, 2'b01, 3'd0, 8'd0, 4'h3, wmask, wdata, "C12.P1.W.1B@4"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, base1, 2'b01, 3'd3, 8'd0, 4'h4, '0, '0, "C12.P1.R.AFTER1B@4"));

    wmask = 8'b1000_0000; wdata = 64'hAA00_0000_0000_0000;
    seq1.push_item(mk_tr(0, base1, 2'b01, 3'd0, 8'd0, 4'h5, wmask, wdata, "C12.P1.W.1B@7"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, base1, 2'b01, 3'd3, 8'd0, 4'h6, '0, '0, "C12.P1.R.AFTER1B@7"));

    wmask = 8'b0011_0000; wdata = 64'h0000_BEEF_0000_0000;
    seq1.push_item(mk_tr(0, base1, 2'b01, 3'd1, 8'd0, 4'h7, wmask, wdata, "C12.P1.W.2B@4"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, base1, 2'b01, 3'd3, 8'd0, 4'h8, '0, '0, "C12.P1.R.AFTER2B@4"));

    wmask = 8'b0000_1100; wdata = 64'h0000_0000_BEEF_0000;
    seq1.push_item(mk_tr(0, base1, 2'b01, 3'd1, 8'd0, 4'h9, wmask, wdata, "C12.P1.W.2B@2"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, base1, 2'b01, 3'd3, 8'd0, 4'hA, '0, '0, "C12.P1.R.AFTER2B@2"));

    wmask = 8'b1111_0000; wdata = 64'hCAFE_BABE_0000_0000;
    seq1.push_item(mk_tr(0, base1, 2'b01, 3'd2, 8'd0, 4'hB, wmask, wdata, "C12.P1.W.4B@4"));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, base1, 2'b01, 3'd3, 8'd0, 4'hC, '0, '0, "C12.P1.R.AFTER4B@4"));

    fork
      seq0.start(env_h.p0_agent.seqr);
      begin #1ns; seq1.start(env_h.p1_agent.seqr); end
    join

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_12] Done.", UVM_MEDIUM)
  endtask

  task automatic run_case_13_ready_backpressure_stress();
    axi_mm_corner_step_seq seq0;
    axi_mm_corner_step_seq seq1;

    logic [ADDR_WIDTH-1:0] a0, a1;

    a0 = align_to_beat(WIN0_BASE + 32'h0900);
    a1 = align_to_beat(WIN1_BASE + 32'h0900);

    seq0 = axi_mm_corner_step_seq::type_id::create("C13_seq0");
    seq1 = axi_mm_corner_step_seq::type_id::create("C13_seq1");

    seq0.push_item(mk_wr_burst(a0, 2'b01, 3'd3, 8'd7, 4'h1, 64'hC13_0A00_0000_0000, 8'hFF));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, a0, 2'b01, 3'd3, 8'd7, 4'h2, '0, '0, "C13.P0.R.8beats", 0));
    seq0.push_item(mk_tr(0, a0+32'h40, 2'b01, 3'd3, 8'd0, 4'h3, 8'h0F, 64'h1111_2222_3333_4444, "C13.P0.W.PARTIAL", 0));
    seq0.push_delay(POST_WRITE_DELAY);
    seq0.push_item(mk_tr(1, a0+32'h40, 2'b01, 3'd3, 8'd0, 4'h4, '0, '0, "C13.P0.R.PARTIAL", 0));

    seq1.push_item(mk_wr_burst(a1, 2'b01, 3'd3, 8'd3, 4'h5, 64'hC13_1A00_0000_0000, 8'hFF));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, a1, 2'b01, 3'd3, 8'd3, 4'h6, '0, '0, "C13.P1.R.4beats", 0));
    seq1.push_item(mk_tr(0, a1+32'h20, 2'b00, 3'd3, 8'd3, 4'h7, 8'hFF, 64'hC13_F1CED_0000_0000, "C13.P1.W.FIXED.4beats", 1));
    seq1.push_delay(POST_WRITE_DELAY);
    seq1.push_item(mk_tr(1, a1+32'h20, 2'b01, 3'd3, 8'd0, 4'h8, '0, '0, "C13.P1.R.FIXED_LAST", 0));

    banner_case("13", "READY backpressure + (optional) stress");

    cfg_driver_hold_ready(0, 0);
    cfg_driver_stress_on();

    fork
      seq0.start(env_h.p0_agent.seqr);
      begin #1ns; seq1.start(env_h.p1_agent.seqr); end
    join

    cfg_driver_stress_off();
    cfg_driver_hold_ready(1, 1);

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_13] Done.", UVM_MEDIUM)
  endtask

  task automatic run_case_14_corner_completion_suite();
    axi_mm_corner_step_seq seq_sanity0, seq_sanity1;
    logic [ADDR_WIDTH-1:0] a0, a1;

    banner_case("14", "CORNER COMPLETION SUITE (run all required cases once)");

    cfg_driver_stress_off();
    cfg_driver_hold_ready(1, 1);

    banner_case("1", "LEN=0 single-beat (INCR/FIXED) + WSTRB");
    run_case_1_single_beat();

    banner_case("2", "Boundary crossing + end-of-window");
    run_case_2_boundary_edges();

    banner_case("3", "Ordering + merge (per-window)");
    run_case_3_ordering_and_conflict();

    banner_case("4", "AW/AR contention overlap");
    run_case_4_aw_ar_contention();

    banner_case("5", "WRAP(4beat) edges + FIXED last-wins");
    run_case_5_wrap_fixed();

    banner_case("6", "WRAP(8beat) edges");
    run_case_6_wrap_edges();

    banner_case("7", "WSTRB patterns");
    run_case_7_wstrb_patterns();

    banner_case("8.1", "8A depth1-friendly split AW/W");
    run_case_8a_multi_aw_no_interleave_fixed_for_depth1();

    banner_case("8.2", "8B outstanding + reverse B_WAIT");
    run_case_8b_outstanding_ooo_b_p0p1();

    banner_case("9.1", "9A mixed-ID ordering P0");
    run_case_9a_mixed_id_ordering_p0();

    banner_case("9.2", "9B mixed-ID ordering P0/P1");
    run_case_9b_mixed_id_ordering_p0p1();

    banner_case("10", "Reset during activity");
    run_case_10_reset_during_activity();

    banner_case("11", "MAX LEN=255 INCR burst write/read");
    run_case_11_max_len_burst();

    banner_case("12", "Narrow sizes lane mapping + merge");
    run_case_12_narrow_sizes();

    banner_case("13", "READY backpressure");
    run_case_13_ready_backpressure_stress();

    cfg_driver_stress_off();
    cfg_driver_hold_ready(1, 1);

    a0 = align_to_beat(WIN0_BASE + 32'h0A00);
    a1 = align_to_beat(WIN1_BASE + 32'h0A00);

    seq_sanity0 = axi_mm_corner_step_seq::type_id::create("C14_sanity_p0");
    seq_sanity1 = axi_mm_corner_step_seq::type_id::create("C14_sanity_p1");

    seq_sanity0.push_item(mk_tr(0, a0, 2'b01, 3'd3, 8'd0, 4'h1, 8'hFF, 64'hC14C_0FAE_0000_0001, "C14.SAN.P0.W"));
    seq_sanity0.push_delay(POST_WRITE_DELAY);
    seq_sanity0.push_item(mk_tr(1, a0, 2'b01, 3'd3, 8'd0, 4'h2, '0, '0, "C14.SAN.P0.R", 0));

    seq_sanity1.push_item(mk_tr(0, a1, 2'b01, 3'd3, 8'd0, 4'h3, 8'hFF, 64'hC14C_1FAE_0000_0001, "C14.SAN.P1.W"));
    seq_sanity1.push_delay(POST_WRITE_DELAY);
    seq_sanity1.push_item(mk_tr(1, a1, 2'b01, 3'd3, 8'd0, 4'h4, '0, '0, "C14.SAN.P1.R", 0));

    fork
      seq_sanity0.start(env_h.p0_agent.seqr);
      begin #1ns; seq_sanity1.start(env_h.p1_agent.seqr); end
    join

    #300ns;

    `uvm_info("CORNER_TEST",
              "[CASE_14] Completion suite finished. If scoreboard FINAL RESULT is PASS => CORNER TEST COMPLETE.",
              UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Run phase: corner-case traffic
  // ------------------------------------------------------------
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);

    `uvm_info("CORNER_TEST", "Starting AXI-MM corner-case transaction test", UVM_MEDIUM)

    // `uvm_info("CORNER_TEST", "Initial reset done, start traffic.", UVM_MEDIUM)

    cfg_driver_stress_off();
    cfg_driver_hold_ready(1, 1);

    if (case_enabled("1"))   begin banner_case("1",   "LEN=0 single-beat (INCR/FIXED) + WSTRB");              run_case_1_single_beat(); end
    if (case_enabled("2"))   begin banner_case("2",   "Boundary crossing + end-of-window");                   run_case_2_boundary_edges(); end
    if (case_enabled("3"))   begin banner_case("3",   "Ordering + partial merge (per-window)");               run_case_3_ordering_and_conflict(); end
    if (case_enabled("4"))   begin banner_case("4",   "AW/AR contention overlap");                            run_case_4_aw_ar_contention(); end
    if (case_enabled("5"))   begin banner_case("5",   "WRAP(4beat) edges + FIXED last-wins");                 run_case_5_wrap_fixed(); end
    if (case_enabled("6"))   begin banner_case("6",   "WRAP(8beat) edges");                                   run_case_6_wrap_edges(); end
    if (case_enabled("7"))   begin banner_case("7",   "WSTRB patterns");                                      run_case_7_wstrb_patterns(); end

    if (case_enabled("8"))   begin banner_case("8",   "Outstanding AW depth4 + observable stall");            run_case_8_outstanding_aw_depth4_p0p1(); end
    if (case_enabled("8.1")) begin banner_case("8.1", "8A depth1-friendly split AW/W");                       run_case_8a_multi_aw_no_interleave_fixed_for_depth1(); end
    if (case_enabled("8.2")) begin banner_case("8.2", "8B outstanding + reverse B_WAIT");                     run_case_8b_outstanding_ooo_b_p0p1(); end

    if (case_enabled("9.1")) begin banner_case("9.1", "9A mixed-ID ordering P0");                             run_case_9a_mixed_id_ordering_p0(); end
    if (case_enabled("9.2")) begin banner_case("9.2", "9B mixed-ID ordering P0/P1");                          run_case_9b_mixed_id_ordering_p0p1(); end

    if (case_enabled("10"))  begin banner_case("10",  "Reset during activity");                               run_case_10_reset_during_activity(); end
    if (case_enabled("11"))  begin banner_case("11",  "MAX LEN=255 INCR burst write/read");                   run_case_11_max_len_burst(); end
    if (case_enabled("12"))  begin banner_case("12",  "Narrow sizes lane mapping + merge");                   run_case_12_narrow_sizes(); end
    if (case_enabled("13"))  begin banner_case("13",  "READY backpressure");                                  run_case_13_ready_backpressure_stress(); end
    if (case_enabled("14"))  begin banner_case("14",  "Complete regression");                                 run_case_14_corner_completion_suite(); end

    `uvm_info("CORNER_TEST", "Corner-case transaction test completed", UVM_MEDIUM)

    phase.drop_objection(this);
  endtask

endclass : axi_mm_corner_test

`endif