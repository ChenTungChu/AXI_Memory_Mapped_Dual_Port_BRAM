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

  // ------------------------------------------------------------
  // Environment handle
  // ------------------------------------------------------------
  axi_mm_env #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) env_h;

  // ------------------------------------------------------------
  // Local sequence: run a fixed list of pre-built transactions
  // ------------------------------------------------------------
  class axi_mm_corner_list_seq extends uvm_sequence #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH));
    `uvm_object_utils(axi_mm_corner_list_seq)

    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) q[$];

    function new(string name="axi_mm_corner_list_seq");
      super.new(name);
    endfunction

    function void push_item(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
      q.push_back(tr);
    endfunction

    virtual task body();
      axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
      foreach (q[i]) begin
        tr = q[i];
        start_item(tr);
        finish_item(tr);
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
  // IMPORTANT:
  // - 不要在 reset_phase 內呼叫 env_h.do_initial_reset()
  // - 因為 reset_monitor 的 trigger 在 run_phase 才會跑
  // ------------------------------------------------------------
  virtual task reset_phase(uvm_phase phase);
    super.reset_phase(phase);

    `uvm_info("CORNER_TEST",
              "[RESET_PHASE] config-only (initial reset will be done in run_phase)",
              UVM_MEDIUM)

    // 如果你想覆寫 env knobs，可以放這裡（可選）
    // uvm_config_db#(bit)::set(this, "env_h", "do_initial_reset", 1);
    // uvm_config_db#(int unsigned)::set(this, "env_h", "rst_assert_cycles", 50);
    // uvm_config_db#(int unsigned)::set(this, "env_h", "rst_deassert_cycles", 10);
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
  // Helper: disable stress mode (keep directed corner cases clean)
  // ------------------------------------------------------------
  task automatic cfg_driver_stress_off();
    uvm_config_db#(bit)::set(this, "env_h.p0_agent.drv", "stress_enable", 0);
    uvm_config_db#(bit)::set(this, "env_h.p1_agent.drv", "stress_enable", 0);
  endtask

  // ------------------------------------------------------------
  // Helper: align an address to beat size (BYTES_PER_BEAT)
  // ------------------------------------------------------------
  function automatic logic [ADDR_WIDTH-1:0] align_to_beat(input logic [ADDR_WIDTH-1:0] a);
    return (a & ~(BYTES_PER_BEAT-1));
  endfunction

  // ------------------------------------------------------------
  // Helper: create deterministic per-beat data (useful for len>0 later)
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
      input bit                         fill_all_beats = 0
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

    tr.set_beats_len(tr.len);
    beats = tr.len + 1;

    if (!is_read) begin
      if (fill_all_beats) begin
        for (int unsigned i = 0; i < beats; i++) begin
          tr.data_beats[i]  = beat_data_seed(id, i, addr);
          tr.wstrb_beats[i] = wstrb0;
        end
      end else begin
        tr.data_beats[0]  = wdata0;
        tr.wstrb_beats[0] = wstrb0;
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
      input logic [BYTES_PER_BEAT-1:0]  wstrb_all
    );
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
    int unsigned beats;

    tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("tr_wr");

    tr.rw    = AXI_WRITE;
    tr.addr  = addr;
    tr.burst = burst;
    tr.size  = size;
    tr.len   = len;
    tr.id    = id;

    tr.set_beats_len(tr.len);
    beats = tr.len + 1;

    for (int i = 0; i < beats; i++) begin
      tr.data_beats[i]  = data0 + i;
      tr.wstrb_beats[i] = wstrb_all;
    end

    return tr;
  endfunction

  // ------------------------------------------------------------
  // Case 1: Zero-length & Single-beat bursts (LEN=0 => 1 beat)
  //  - Cover READ/WRITE
  //  - Cover INCR and FIXED (WRAP not required here)
  //  - Keep ready always-high and stress off
  //  - Strengthened:
  //    * WSTRB=0 must preserve previously written known value (no SCB skip)
  //    * Add a deterministic PARTIAL mask example (single beat)
  // ------------------------------------------------------------
  task automatic run_case_1_single_beat();
    axi_mm_corner_list_seq seq0;
    axi_mm_corner_list_seq seq1;

    logic [ADDR_WIDTH-1:0] a0, a1, a1z, a0p;

    // size=3 => 8 bytes/beat => align by 8
    a0  = align_to_beat(WIN0_BASE + 32'h000);
    a0p = align_to_beat(WIN0_BASE + 32'h060);
    a1  = align_to_beat(WIN1_BASE + 32'h080);
    a1z = align_to_beat(a1 + 32'h040);

    seq0 = axi_mm_corner_list_seq::type_id::create("C1_seq0");
    seq1 = axi_mm_corner_list_seq::type_id::create("C1_seq1");

    // -----------------
    // P0 list
    // -----------------
    // 1) WRITE, INCR, LEN=0
    seq0.push_item(mk_tr(
      0, a0, 2'b01, 3'd3, 8'd0, 4'h1,
      {BYTES_PER_BEAT{1'b1}}, 64'hC1C1_0000_0000_0001,
      "C1.P0.W.INCR.LEN0"
    ));

    // 2) READ, INCR, LEN=0
    seq0.push_item(mk_tr(
      1, a0, 2'b01, 3'd3, 8'd0, 4'h2,
      '0, '0,
      "C1.P0.R.INCR.LEN0"
    ));

    // 3) WRITE, FIXED, LEN=0
    seq0.push_item(mk_tr(
      0, align_to_beat(a0 + 32'h020), 2'b00, 3'd3, 8'd0, 4'h3,
      {BYTES_PER_BEAT{1'b1}}, 64'hC1C1_0000_0000_0003,
      "C1.P0.W.FIXED.LEN0"
    ));

    // 4) READ, FIXED, LEN=0
    seq0.push_item(mk_tr(
      1, align_to_beat(a0 + 32'h020), 2'b00, 3'd3, 8'd0, 4'h4,
      '0, '0,
      "C1.P0.R.FIXED.LEN0"
    ));

    // 5) PARTIAL mask single-beat (still Case 1 spirit)
    //    - Seed full write
    //    - Then partial write updates only some bytes
    //    - Readback must match merge
    //
    // Example: mask=0x0F updates low 4 bytes (byte lanes [3:0])
    seq0.push_item(mk_tr(
      0, a0p, 2'b01, 3'd3, 8'd0, 4'hA,
      8'hFF, 64'hAAAA_BBBB_CCCC_DDDD,
      "C1.P0.SEED.FULL"
    ));
    seq0.push_item(mk_tr(
      0, a0p, 2'b01, 3'd3, 8'd0, 4'hB,
      8'h0F, 64'h1111_2222_3333_4444,
      "C1.P0.W.PARTIAL.0F"
    ));
    seq0.push_item(mk_tr(
      1, a0p, 2'b01, 3'd3, 8'd0, 4'hC,
      '0, '0,
      "C1.P0.R.MERGECHK"
    ));

    // -----------------
    // P1 list
    // -----------------
    // Mirror basic pattern on the other window
    seq1.push_item(mk_tr(
      0, a1, 2'b01, 3'd3, 8'd0, 4'h5,
      8'hFF, 64'hC1C1_0000_0000_1001,
      "C1.P1.W.INCR.LEN0"
    ));
    seq1.push_item(mk_tr(
      1, a1, 2'b01, 3'd3, 8'd0, 4'h6,
      '0, '0,
      "C1.P1.R.INCR.LEN0"
    ));

    // Strengthened WSTRB=0 check:
    //  - seed known data
    //  - WSTRB=0 write different data (must NOT change memory)
    //  - read back must equal seed
    seq1.push_item(mk_tr(
      0, a1z, 2'b01, 3'd3, 8'd0, 4'h7,
      8'hFF, 64'h1111_2222_3333_4444,
      "C1.P1.SEED.KNOWN"
    ));
    seq1.push_item(mk_tr(
      0, a1z, 2'b01, 3'd3, 8'd0, 4'h8,
      8'h00, 64'hDEAD_BEEF_DEAD_BEEF,
      "C1.P1.WSTRB0.NOCHANGE"
    ));
    seq1.push_item(mk_tr(
      1, a1z, 2'b01, 3'd3, 8'd0, 4'h9,
      '0, '0,
      "C1.P1.R.BACK.KNOWN"
    ));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_1] Start: LEN=0 single-beat READ/WRITE (INCR/FIXED) + WSTRB(FF/00/partial). a0=0x%0h a1=0x%0h",
                a0, a1),
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

  // ------------------------------------------------------------
  // Case 2: Boundary crossing at window edge + end-of-memory edge
  //  - P0: INCR burst crosses 0x0FFF -> 0x1000 boundary (WIN0->WIN1)
  //  - P1: single-beat access at last valid beat address (0x1FF8)
  //  - stress off, ready always-high (clean + deterministic)
  // ------------------------------------------------------------
  task automatic run_case_2_boundary_edges();
    axi_mm_corner_list_seq seq0;
    axi_mm_corner_list_seq seq1;

    logic [ADDR_WIDTH-1:0] p0_a_cross_2b;
    logic [ADDR_WIDTH-1:0] p0_a_cross_4b;
    logic [ADDR_WIDTH-1:0] p1_last;

    // size=3 => 8B/beat
    // 4KB boundary is at 0x1000. Crossing happens when a beat lands at 0x1000.
    // 2-beat burst: start at 0x0FF8 (beats @0x0FF8, 0x1000)
    p0_a_cross_2b = 32'h0000_0FF8;

    // 4-beat burst: start at 0x0FE8 (beats @0x0FE8,0x0FF0,0x0FF8,0x1000)
    p0_a_cross_4b = 32'h0000_0FE8;

    // last valid 8B-aligned beat address in 8KB memory:
    // MEM_BYTES=8192 => last byte index 8191 => last 8B-aligned addr = 8192-8 = 8184 = 0x1FF8
    p1_last = 32'h0000_1FF8;

    // Alignment safety (optional but nice)
    p0_a_cross_2b &= ~(BYTES_PER_BEAT-1);
    p0_a_cross_4b &= ~(BYTES_PER_BEAT-1);
    p1_last        &= ~(BYTES_PER_BEAT-1);

    seq0 = axi_mm_corner_list_seq::type_id::create("C2_seq0");
    seq1 = axi_mm_corner_list_seq::type_id::create("C2_seq1");

    // -------------------------
    // P0: boundary crossing bursts
    // -------------------------

    // A) 2-beat INCR crossing (len=1 => beats=2)
    seq0.push_item(mk_wr_burst(
      /*addr*/      p0_a_cross_2b,
      /*burst*/     2'b01,      // INCR
      /*size*/      3'd3,       // 8B
      /*len*/       8'd1,       // 2 beats
      /*id*/        4'h1,
      /*data0*/     64'hC2C2_0000_0000_2000,
      /*wstrb_all*/ {BYTES_PER_BEAT{1'b1}}
    ));
    seq0.push_item(mk_tr(
      /*is_read*/ 1,
      /*addr*/    p0_a_cross_2b,
      /*burst*/   2'b01,
      /*size*/    3'd3,
      /*len*/     8'd1,
      /*id*/      4'h2,
      /*wstrb0*/  '0,
      /*wdata0*/  '0
    ));

    // B) 4-beat INCR crossing (len=3 => beats=4)
    seq0.push_item(mk_wr_burst(
      /*addr*/      p0_a_cross_4b,
      /*burst*/     2'b01,
      /*size*/      3'd3,
      /*len*/       8'd3,       // 4 beats
      /*id*/        4'h3,
      /*data0*/     64'hC2C2_0000_0000_4000,
      /*wstrb_all*/ {BYTES_PER_BEAT{1'b1}}
    ));
    seq0.push_item(mk_tr(
      1, p0_a_cross_4b, 2'b01, 3'd3, 8'd3, 4'h4,
      '0, '0
    ));

    // -------------------------
    // P1: end-of-memory edge (single beat)
    // -------------------------
    seq1.push_item(mk_tr(
      0, p1_last, 2'b01, 3'd3, 8'd0, 4'h5,
      {BYTES_PER_BEAT{1'b1}}, {32'hC2C2_0002, p1_last}
    ));
    seq1.push_item(mk_tr(
      1, p1_last, 2'b01, 3'd3, 8'd0, 4'h6,
      '0, '0
    ));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_2] Start: P0 boundary-cross bursts @0x%0h (2b) & 0x%0h (4b), P1 last-beat @0x%0h",
                p0_a_cross_2b, p0_a_cross_4b, p1_last),
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
    `uvm_info("CORNER_TEST", "[CASE_2] Done.", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 3: Ordering + cross-port overwrite + partial merge (deterministic)
  //  - Shared address A: P1 does FULL write first, then P0 does PARTIAL write
  //  - Expected: last writer wins per-byte (merge by WSTRB)
  //  - Also add a same-ID ordering sanity on P0
  //  - stress off, ready always-high (keep deterministic)
  // ------------------------------------------------------------
  task automatic run_case_3_ordering_and_conflict();
    axi_mm_corner_list_seq seq0;
    axi_mm_corner_list_seq seq1;

    logic [ADDR_WIDTH-1:0] A_shared;
    logic [ADDR_WIDTH-1:0] B0;
    logic [ADDR_WIDTH-1:0] B1;

    logic [DATA_WIDTH-1:0] p1_full;
    logic [DATA_WIDTH-1:0] p0_part;
    logic [DATA_WIDTH-1:0] exp_merged;

    logic [BYTES_PER_BEAT-1:0] wmask_low4; // low 4 bytes enabled

    // Pick a shared aligned address (intentionally used by BOTH ports)
    A_shared = 32'h0000_0060;
    A_shared &= ~(BYTES_PER_BEAT-1);

    // Two extra addresses for same-ID ordering check on P0
    B0 = 32'h0000_0080; B0 &= ~(BYTES_PER_BEAT-1);
    B1 = 32'h0000_00A0; B1 &= ~(BYTES_PER_BEAT-1);

    // Data patterns
    p1_full = 64'hC3C3_5100_1111_2222;
    p0_part = 64'hAAAA_BBBB_3333_4444;

    // low 4 bytes mask: 0x0F (for 8-byte WSTRB, bit0=lowest byte)
    wmask_low4 = '0;
    wmask_low4[3:0] = 4'hF;

    // Expected merge:
    // bytes[7:4] from p1_full, bytes[3:0] from p0_part
    exp_merged = (p1_full & 64'hFFFF_FFFF_0000_0000) |
                 (p0_part & 64'h0000_0000_FFFF_FFFF);

    seq0 = axi_mm_corner_list_seq::type_id::create("C3_seq0");
    seq1 = axi_mm_corner_list_seq::type_id::create("C3_seq1");

    // -------------------------
    // P1: write A_shared FULL, then read back later (optional)
    // -------------------------
    seq1.push_item(mk_tr(
      0, A_shared, 2'b01, 3'd3, 8'd0, 4'h5,
      {BYTES_PER_BEAT{1'b1}}, p1_full
    ));

    // (Optional) You can read here too, but the key read is after P0 partial write
    // seq1.push_item(mk_tr(1, A_shared, 2'b01, 3'd3, 8'd0, 4'h6, '0, '0));

    // -------------------------
    // P0: after P1, do PARTIAL write to same addr, then read to check merge
    // -------------------------
    seq0.push_item(mk_tr(
      0, A_shared, 2'b01, 3'd3, 8'd0, 4'h1,
      wmask_low4, p0_part
    ));
    seq0.push_item(mk_tr(
      1, A_shared, 2'b01, 3'd3, 8'd0, 4'h2,
      '0, '0
    ));

    // -------------------------
    // P0: same-ID ordering sanity (same ID=0x9)
    // -------------------------
    seq0.push_item(mk_tr(
      0, B0, 2'b01, 3'd3, 8'd0, 4'h9,
      {BYTES_PER_BEAT{1'b1}}, 64'hC3C3_0000_0000_00B0
    ));
    seq0.push_item(mk_tr(
      0, B1, 2'b01, 3'd3, 8'd0, 4'h9,
      {BYTES_PER_BEAT{1'b1}}, 64'hC3C3_0000_0000_00B1
    ));
    seq0.push_item(mk_tr(
      1, B0, 2'b01, 3'd3, 8'd0, 4'hA,
      '0, '0
    ));
    seq0.push_item(mk_tr(
      1, B1, 2'b01, 3'd3, 8'd0, 4'hB,
      '0, '0
    ));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_3] Start: shared=0x%0h P1_full=0x%0h P0_part(mask=0x%0h) exp_merged=0x%0h",
                A_shared, p1_full, wmask_low4, exp_merged),
      UVM_MEDIUM)

    // Key: make ordering deterministic
    // - Start P1 first (full write), then start P0 after a delay so P1 finishes first.
    fork
      begin
        seq1.start(env_h.p1_agent.seqr);
      end
      begin
        #300ns;
        seq0.start(env_h.p0_agent.seqr);
      end
    join

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_3] Done.", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 4: AW/AR contention + verified burst read (Scheme B, FORCED OVERLAP)
  //  - Phase A: prime both beats for len=1 reads
  //  - Phase B: run P0 long write while P1 injects AR early
  // ------------------------------------------------------------
  task automatic run_case_4_aw_ar_contention();
    axi_mm_corner_list_seq prime0, prime1;
    axi_mm_corner_list_seq cont0, cont1;

    logic [ADDR_WIDTH-1:0] p0_r0, p1_r0;
    logic [ADDR_WIDTH-1:0] p0_wburst, p1_wburst;

    p0_r0     = (WIN0_BASE + 32'h0280) & ~(BYTES_PER_BEAT-1);
    p1_r0     = (WIN1_BASE + 32'h0280) & ~(BYTES_PER_BEAT-1);
    p0_wburst = (WIN0_BASE + 32'h0200) & ~(BYTES_PER_BEAT-1);
    p1_wburst = (WIN1_BASE + 32'h0200) & ~(BYTES_PER_BEAT-1);

    // ============================================================
    // Phase A: PRIME (run first, finish completely)
    // ============================================================
    prime0 = axi_mm_corner_list_seq::type_id::create("C4_prime0");
    prime1 = axi_mm_corner_list_seq::type_id::create("C4_prime1");

    prime0.push_item(mk_wr_burst(
      p0_r0, 2'b01, 3'd3, 8'd1, 4'h1,
      64'hC4C4_F0E0_0000_0000,
      {BYTES_PER_BEAT{1'b1}}
    ));

    prime1.push_item(mk_wr_burst(
      p1_r0, 2'b01, 3'd3, 8'd1, 4'h5,
      64'hC4C4_F1E0_0000_0000,
      {BYTES_PER_BEAT{1'b1}}
    ));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_4] PhaseA PRIME start. p0_r0=0x%0h p1_r0=0x%0h", p0_r0, p1_r0),
      UVM_MEDIUM)

    fork
      prime0.start(env_h.p0_agent.seqr);
      begin
        #1ns;
        prime1.start(env_h.p1_agent.seqr);
      end
    join

    // small gap so you can clearly see phase separation in log
    #50ns;

    // ============================================================
    // Phase B: CONTENTION (this is the overlap we want)
    // ============================================================
    cont0 = axi_mm_corner_list_seq::type_id::create("C4_cont0");
    cont1 = axi_mm_corner_list_seq::type_id::create("C4_cont1");

    // P0: long write burst to occupy AW/W
    cont0.push_item(mk_wr_burst(
      p0_wburst, 2'b01, 3'd3, 8'd3, 4'h3,
      64'hC4C4_F0EB_0000_3000,
      {BYTES_PER_BEAT{1'b1}}
    ));

    // (optional) verify P0 read after contention
    cont0.push_item(mk_tr(
      1, p0_r0, 2'b01, 3'd3, 8'd1, 4'h4,
      '0, '0
    ));

    // P1: INJECT AR EARLY (should overlap with P0 long write)
    cont1.push_item(mk_tr(
      1, p1_r0, 2'b01, 3'd3, 8'd1, 4'h7,
      '0, '0
    ));

    // then add AW/W noise on P1
    cont1.push_item(mk_tr(
      0, (p1_r0 + 32'h040), 2'b01, 3'd3, 8'd0, 4'h6,
      {BYTES_PER_BEAT{1'b1}}, 64'hC4C4_F1E0_0000_0006
    ));

    cont1.push_item(mk_wr_burst(
      p1_wburst, 2'b01, 3'd3, 8'd3, 4'h8,
      64'hC4C4_F1EB_0000_8000,
      {BYTES_PER_BEAT{1'b1}}
    ));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_4] PhaseB CONTENTION start. p0_wburst=0x%0h p1_r0=0x%0h", p0_wburst, p1_r0),
      UVM_MEDIUM)

    fork
      cont0.start(env_h.p0_agent.seqr);
      begin
        // IMPORTANT: no need to wait for p1; start almost immediately
        #1ns;
        cont1.start(env_h.p1_agent.seqr);
      end
    join

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_4] Done.", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 5: WRAP burst edge cases + FIXED burst last-wins
  //  - WRAP burst (burst=2'b10) with len=3 (4 beats), size=3 (8B)
  //    * Exact-boundary start: start aligned to wrap boundary (32B)
  //    * Off-by-one (within-boundary) start: start at base+24B, causes wrap back
  //  - FIXED burst (burst=2'b00) len=3 (4 beats) to same address:
  //    * Verify "last beat wins" by a single-beat read after the burst
  //
  // Notes:
  //  - size=3 => 8 bytes/beat
  //  - len=3 => 4 beats
  //  - WRAP boundary = beats * bytes_per_beat = 4 * 8 = 32B
  // ------------------------------------------------------------
  task automatic run_case_5_wrap_fixed();
    axi_mm_corner_list_seq seq0;
    axi_mm_corner_list_seq seq1;

    logic [ADDR_WIDTH-1:0] p0_wrap_base, p0_wrap_off;
    logic [ADDR_WIDTH-1:0] p1_wrap_base, p1_wrap_off;
    logic [ADDR_WIDTH-1:0] p0_fixed;

    // constants for this case
    const int unsigned WRAP_BEATS = 4;
    const int unsigned WRAP_BYTES = WRAP_BEATS * BYTES_PER_BEAT; // 32 bytes when BYTES_PER_BEAT=8

    // -------------------------
    // Address plan (aligned)
    // -------------------------
    // Pick a 32B-aligned base inside each window.
    // WIN0: 0x0000_0000 .. 0x0000_0FFF
    // WIN1: 0x0000_1000 .. 0x0000_1FFF

    // Exact-boundary start (multiple of 32B)
    p0_wrap_base = (WIN0_BASE + 32'h0100);
    p1_wrap_base = (WIN1_BASE + 32'h0100);

    // Off-by-one (within boundary): base + 24B (still 8B aligned)
    // For WRAP len=3,size=3, addresses should be:
    //   beat0 @ base+24
    //   beat1 @ base+32 -> wraps to base+0
    //   beat2 @ base+8
    //   beat3 @ base+16
    p0_wrap_off  = p0_wrap_base + 32'(WRAP_BYTES - BYTES_PER_BEAT); // +24
    p1_wrap_off  = p1_wrap_base + 32'(WRAP_BYTES - BYTES_PER_BEAT); // +24

    // FIXED burst target (8B aligned)
    p0_fixed     = (WIN0_BASE + 32'h0180);

    // Alignment safety
    p0_wrap_base &= ~(BYTES_PER_BEAT-1);
    p1_wrap_base &= ~(BYTES_PER_BEAT-1);
    p0_wrap_off  &= ~(BYTES_PER_BEAT-1);
    p1_wrap_off  &= ~(BYTES_PER_BEAT-1);
    p0_fixed     &= ~(BYTES_PER_BEAT-1);

    // Optional: ensure 32B boundary alignment for wrap_base (nice to keep)
    p0_wrap_base &= ~(WRAP_BYTES-1);
    p1_wrap_base &= ~(WRAP_BYTES-1);

    // Re-derive off start after boundary align
    p0_wrap_off  = p0_wrap_base + 32'(WRAP_BYTES - BYTES_PER_BEAT);
    p1_wrap_off  = p1_wrap_base + 32'(WRAP_BYTES - BYTES_PER_BEAT);

    seq0 = axi_mm_corner_list_seq::type_id::create("C5_seq0");
    seq1 = axi_mm_corner_list_seq::type_id::create("C5_seq1");

    // ============================================================
    // P0: WRAP exact-boundary start (len=3 => 4 beats)
    // ============================================================
    seq0.push_item(mk_wr_burst(
      /*addr*/      p0_wrap_base,
      /*burst*/     2'b10,      // WRAP
      /*size*/      3'd3,       // 8B
      /*len*/       8'd3,       // 4 beats
      /*id*/        4'h1,
      /*data0*/     64'hC5C5_0000_0000_5000,
      /*wstrb_all*/ {BYTES_PER_BEAT{1'b1}}
    ));
    seq0.push_item(mk_tr(
      /*is_read*/  1,
      /*addr*/     p0_wrap_base,
      /*burst*/    2'b10,       // WRAP
      /*size*/     3'd3,
      /*len*/      8'd3,
      /*id*/       4'h2,
      /*wstrb0*/   '0,
      /*wdata0*/   '0
    ));

    // ============================================================
    // P0: WRAP off-by-one start (base+24B causes wrap)
    // ============================================================
    seq0.push_item(mk_wr_burst(
      /*addr*/      p0_wrap_off,
      /*burst*/     2'b10,      // WRAP
      /*size*/      3'd3,
      /*len*/       8'd3,
      /*id*/        4'h3,
      /*data0*/     64'hC5C5_0000_0000_5100,
      /*wstrb_all*/ {BYTES_PER_BEAT{1'b1}}
    ));
    seq0.push_item(mk_tr(
      1, p0_wrap_off, 2'b10, 3'd3, 8'd3, 4'h4,
      '0, '0
    ));

    // ============================================================
    // P0: FIXED burst "last beat wins"
    //  - burst=00, len=3 => 4 beats, all to same addr
    //  - After burst, do single-beat read and expect final value
    //    (mk_wr_burst increments data each beat => last = data0 + 3)
    // ============================================================
    seq0.push_item(mk_wr_burst(
      /*addr*/      p0_fixed,
      /*burst*/     2'b00,      // FIXED
      /*size*/      3'd3,
      /*len*/       8'd3,       // 4 beats (same address)
      /*id*/        4'h5,
      /*data0*/     64'hC5C5_F1E0_0000_6000,
      /*wstrb_all*/ {BYTES_PER_BEAT{1'b1}}
    ));
    seq0.push_item(mk_tr(
      /*is_read*/  1,
      /*addr*/     p0_fixed,
      /*burst*/    2'b01,       // INCR single beat read is fine
      /*size*/     3'd3,
      /*len*/      8'd0,        // 1 beat
      /*id*/       4'h6,
      /*wstrb0*/   '0,
      /*wdata0*/   '0
    ));

    // ============================================================
    // P1: Do the same two WRAP edge cases (no FIXED here to keep clean)
    // ============================================================
    seq1.push_item(mk_wr_burst(
      /*addr*/      p1_wrap_base,
      /*burst*/     2'b10,
      /*size*/      3'd3,
      /*len*/       8'd3,
      /*id*/        4'h9,
      /*data0*/     64'hC5C5_0001_0000_5000,
      /*wstrb_all*/ {BYTES_PER_BEAT{1'b1}}
    ));
    seq1.push_item(mk_tr(
      1, p1_wrap_base, 2'b10, 3'd3, 8'd3, 4'hA,
      '0, '0
    ));

    seq1.push_item(mk_wr_burst(
      /*addr*/      p1_wrap_off,
      /*burst*/     2'b10,
      /*size*/      3'd3,
      /*len*/       8'd3,
      /*id*/        4'hB,
      /*data0*/     64'hC5C5_0001_0000_5100,
      /*wstrb_all*/ {BYTES_PER_BEAT{1'b1}}
    ));
    seq1.push_item(mk_tr(
      1, p1_wrap_off, 2'b10, 3'd3, 8'd3, 4'hC,
      '0, '0
    ));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_5] Start: WRAP exact/off + FIXED last-wins. 
                p0_wrap_base=0x%0h p0_wrap_off=0x%0h p0_fixed=0x%0h | 
                p1_wrap_base=0x%0h p1_wrap_off=0x%0h",
                p0_wrap_base, p0_wrap_off, p0_fixed,
                p1_wrap_base, p1_wrap_off),
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
    `uvm_info("CORNER_TEST", "[CASE_5] Done.", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 6: WRAP burst edge cases (exact boundary + off-by-one)
  //  - size=3 => 8B/beat
  //  - len=7  => 8 beats (WRAP legal)
  //  - wrap boundary = 8*8 = 64B
  //
  //  P0: WRAP burst starting near end of 64B region to FORCE wrap
  //      A) start offset 0x38 (forces wrap on next beat to +0x00)
  //      B) start offset 0x30 (wrap happens earlier)
  //
  //  P1: same pattern in WIN1
  //
  //  Each WRAP write is followed by matching WRAP read (same addr/len/size/burst)
  //  so scoreboard can verify per-beat data on wrapped addresses.
  // ------------------------------------------------------------
  task automatic run_case_6_wrap_edges();
    axi_mm_corner_list_seq seq0;
    axi_mm_corner_list_seq seq1;

    logic [ADDR_WIDTH-1:0] p0_wrap_base, p1_wrap_base;
    logic [ADDR_WIDTH-1:0] p0_wA, p0_wB;
    logic [ADDR_WIDTH-1:0] p1_wA, p1_wB;

    // Choose a 64B-aligned base inside each window to make wrap math clean.
    // 64B boundary => align mask = ~(64-1) = ~6'h3F
    localparam int WRAP_BEATS = 8;
    localparam int WRAP_BYTES = WRAP_BEATS * BYTES_PER_BEAT; // 64
    logic [ADDR_WIDTH-1:0] wrap_align_mask;
    wrap_align_mask = ~(WRAP_BYTES-1);

    // Pick some arbitrary region inside WIN0/WIN1 then align it to 64B
    // (avoid window edges to keep it simple + deterministic)
    p0_wrap_base = (WIN0_BASE + 32'h0100) & wrap_align_mask; // e.g. 0x100 aligned to 0x40
    p1_wrap_base = (WIN1_BASE + 32'h0100) & wrap_align_mask; // e.g. 0x1100 aligned to 0x40

    // Two starting points inside the same 64B region:
    // A) exact-boundary forcing wrap on next beat: base+0x38 (8B aligned)
    //    beats: +0x38, +0x40->wrap to +0x00, +0x08, +0x10, +0x18, +0x20, +0x28, +0x30
    // B) off-by-one-ish: base+0x30 (wrap occurs earlier in sequence)
    //    beats: +0x30, +0x38, +0x40->wrap to +0x00, +0x08, +0x10, +0x18, +0x20, +0x28
    p0_wA = (p0_wrap_base + 32'h38) & ~(BYTES_PER_BEAT-1);
    p0_wB = (p0_wrap_base + 32'h30) & ~(BYTES_PER_BEAT-1);

    p1_wA = (p1_wrap_base + 32'h38) & ~(BYTES_PER_BEAT-1);
    p1_wB = (p1_wrap_base + 32'h30) & ~(BYTES_PER_BEAT-1);

    seq0 = axi_mm_corner_list_seq::type_id::create("C6_seq0");
    seq1 = axi_mm_corner_list_seq::type_id::create("C6_seq1");

    // ============================================================
    // P0: WRAP write + WRAP read verify
    // ============================================================

    // A) WRAP start at +0x38 (forces wrap behavior clearly)
    seq0.push_item(mk_wr_burst(
      /*addr*/      p0_wA,
      /*burst*/     2'b10,     // WRAP
      /*size*/      3'd3,      // 8B
      /*len*/       8'd7,      // 8 beats
      /*id*/        4'h1,
      /*data0*/     64'hC6C6_F0EA_0000_0000,
      /*wstrb_all*/ {BYTES_PER_BEAT{1'b1}}
    ));
    seq0.push_item(mk_tr(
      /*is_read*/  1,
      /*addr*/     p0_wA,
      /*burst*/    2'b10,      // WRAP
      /*size*/     3'd3,
      /*len*/      8'd7,
      /*id*/       4'h2,
      /*wstrb0*/   '0,
      /*wdata0*/   '0
    ));

    // B) WRAP start at +0x30 (off-by-one-ish: wrap occurs earlier beat)
    seq0.push_item(mk_wr_burst(
      /*addr*/      p0_wB,
      /*burst*/     2'b10,     // WRAP
      /*size*/      3'd3,
      /*len*/       8'd7,      // 8 beats
      /*id*/        4'h3,
      /*data0*/     64'hC6C6_F0EB_0000_0000,
      /*wstrb_all*/ {BYTES_PER_BEAT{1'b1}}
    ));
    seq0.push_item(mk_tr(
      1, p0_wB, 2'b10, 3'd3, 8'd7, 4'h4,
      '0, '0
    ));

    // ============================================================
    // P1: WRAP write + WRAP read verify
    // ============================================================

    // A) WRAP start at +0x38
    seq1.push_item(mk_wr_burst(
      /*addr*/      p1_wA,
      /*burst*/     2'b10,     // WRAP
      /*size*/      3'd3,
      /*len*/       8'd7,      // 8 beats
      /*id*/        4'h9,
      /*data0*/     64'hC6C6_F1EA_0000_0000,
      /*wstrb_all*/ {BYTES_PER_BEAT{1'b1}}
    ));
    seq1.push_item(mk_tr(
      1, p1_wA, 2'b10, 3'd3, 8'd7, 4'hA,
      '0, '0
    ));

    // B) WRAP start at +0x30
    seq1.push_item(mk_wr_burst(
      /*addr*/      p1_wB,
      /*burst*/     2'b10,     // WRAP
      /*size*/      3'd3,
      /*len*/       8'd7,      // 8 beats
      /*id*/        4'hB,
      /*data0*/     64'hC6C6_F1EB_0000_0000,
      /*wstrb_all*/ {BYTES_PER_BEAT{1'b1}}
    ));
    seq1.push_item(mk_tr(
      1, p1_wB, 2'b10, 3'd3, 8'd7, 4'hC,
      '0, '0
    ));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_6] Start: WRAP edges (8 beats, 64B boundary). P0 base=0x%0h A=0x%0h B=0x%0h | P1 base=0x%0h A=0x%0h B=0x%0h",
                p0_wrap_base, p0_wA, p0_wB, p1_wrap_base, p1_wA, p1_wB),
      UVM_MEDIUM)

    // Run both ports concurrently to get some natural interleaving
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
    `uvm_info("CORNER_TEST", "[CASE_6] Done.", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 7: Partial WSTRB patterns (all-zero / all-one / nibble / alternating)
  //  - size=3 => 8B/beat
  //  - all transactions are SINGLE-BEAT (len=0) so each write can have unique WSTRB
  //  - flow per port:
  //      1) Init full write (WSTRB=FF) -> readback
  //      2) WSTRB=00 (no-op)          -> readback (must be unchanged)
  //      3) WSTRB=0F (low 4 bytes)    -> readback
  //      4) WSTRB=F0 (high 4 bytes)   -> readback
  //      5) WSTRB=AA (1010...)        -> readback
  //      6) WSTRB=55 (0101...)        -> readback
  //
  //  P0 uses WIN0, P1 uses WIN1, run concurrently to interleave.
  // ------------------------------------------------------------
  task automatic run_case_7_wstrb_patterns();
    axi_mm_corner_list_seq seq0;
    axi_mm_corner_list_seq seq1;

    logic [ADDR_WIDTH-1:0] p0_addr, p1_addr;

    // pick a simple aligned address (8B aligned)
    p0_addr = (WIN0_BASE + 32'h0180) & ~(BYTES_PER_BEAT-1);
    p1_addr = (WIN1_BASE + 32'h0180) & ~(BYTES_PER_BEAT-1);

    seq0 = axi_mm_corner_list_seq::type_id::create("C7_seq0");
    seq1 = axi_mm_corner_list_seq::type_id::create("C7_seq1");

    // ----------------------------
    // P0 sequence (WIN0)
    // ----------------------------
    // 1) init full write -> read
    seq0.push_item(mk_tr(
      /*is_read*/ 0,
      /*addr*/    p0_addr,
      /*burst*/   2'b01,     // INCR (single beat anyway)
      /*size*/    3'd3,      // 8B
      /*len*/     8'd0,      // 1 beat
      /*id*/      4'h1,
      /*wstrb0*/  8'hFF,
      /*wdata0*/  64'hC7C7_F0A0_0000_0000
    ));
    seq0.push_item(mk_tr(1, p0_addr, 2'b01, 3'd3, 8'd0, 4'h2, '0, '0));

    // 2) WSTRB=00 no-op -> read (must stay same)
    seq0.push_item(mk_tr(0, p0_addr, 2'b01, 3'd3, 8'd0, 4'h3, 8'h00,
                        64'hDEAD_BEEF_DEAD_BEEF));
    seq0.push_item(mk_tr(1, p0_addr, 2'b01, 3'd3, 8'd0, 4'h4, '0, '0));

    // 3) WSTRB=0F update low 32b only -> read
    seq0.push_item(mk_tr(0, p0_addr, 2'b01, 3'd3, 8'd0, 4'h5, 8'h0F,
                        64'h1111_2222_3333_4444));
    seq0.push_item(mk_tr(1, p0_addr, 2'b01, 3'd3, 8'd0, 4'h6, '0, '0));

    // 4) WSTRB=F0 update high 32b only -> read
    seq0.push_item(mk_tr(0, p0_addr, 2'b01, 3'd3, 8'd0, 4'h7, 8'hF0,
                        64'hAAAA_BBBB_CCCC_DDDD));
    seq0.push_item(mk_tr(1, p0_addr, 2'b01, 3'd3, 8'd0, 4'h8, '0, '0));

    // 5) WSTRB=AA alternating bytes (1010...) -> read
    seq0.push_item(mk_tr(0, p0_addr, 2'b01, 3'd3, 8'd0, 4'h9, 8'hAA,
                        64'h0123_4567_89AB_CDEF));
    seq0.push_item(mk_tr(1, p0_addr, 2'b01, 3'd3, 8'd0, 4'hA, '0, '0));

    // 6) WSTRB=55 alternating bytes (0101...) -> read
    seq0.push_item(mk_tr(0, p0_addr, 2'b01, 3'd3, 8'd0, 4'hB, 8'h55,
                        64'hFEDC_BA98_7654_3210));
    seq0.push_item(mk_tr(1, p0_addr, 2'b01, 3'd3, 8'd0, 4'hC, '0, '0));

    // ----------------------------
    // P1 sequence (WIN1) - same idea, different data/IDs
    // ----------------------------
    seq1.push_item(mk_tr(0, p1_addr, 2'b01, 3'd3, 8'd0, 4'h9, 8'hFF,
                        64'hC7C7_F1A0_0000_0000));
    seq1.push_item(mk_tr(1, p1_addr, 2'b01, 3'd3, 8'd0, 4'hA, '0, '0));

    seq1.push_item(mk_tr(0, p1_addr, 2'b01, 3'd3, 8'd0, 4'hB, 8'h00,
                        64'hCAFE_BABE_CAFE_BABE));
    seq1.push_item(mk_tr(1, p1_addr, 2'b01, 3'd3, 8'd0, 4'hC, '0, '0));

    seq1.push_item(mk_tr(0, p1_addr, 2'b01, 3'd3, 8'd0, 4'hD, 8'h0F,
                        64'h5555_6666_7777_8888));
    seq1.push_item(mk_tr(1, p1_addr, 2'b01, 3'd3, 8'd0, 4'hE, '0, '0));

    seq1.push_item(mk_tr(0, p1_addr, 2'b01, 3'd3, 8'd0, 4'hF, 8'hF0,
                        64'h9999_AAAA_BBBB_CCCC));
    seq1.push_item(mk_tr(1, p1_addr, 2'b01, 3'd3, 8'd0, 4'h0, '0, '0));

    seq1.push_item(mk_tr(0, p1_addr, 2'b01, 3'd3, 8'd0, 4'h1, 8'hAA,
                        64'h0F0E_0D0C_0B0A_0908));
    seq1.push_item(mk_tr(1, p1_addr, 2'b01, 3'd3, 8'd0, 4'h2, '0, '0));

    seq1.push_item(mk_tr(0, p1_addr, 2'b01, 3'd3, 8'd0, 4'h3, 8'h55,
                        64'h0809_0A0B_0C0D_0E0F));
    seq1.push_item(mk_tr(1, p1_addr, 2'b01, 3'd3, 8'd0, 4'h4, '0, '0));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_7] Start: Partial WSTRB patterns. P0 addr=0x%0h | P1 addr=0x%0h",
                p0_addr, p1_addr),
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
    `uvm_info("CORNER_TEST", "[CASE_7] Done.", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 8A: Same-port multiple outstanding AW (2 writes), W in-order
  // ------------------------------------------------------------
  task automatic run_case_8a_multi_aw_no_interleave_fixed_for_depth1();
    axi_mm_corner_list_seq seq0;
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
    logic [ADDR_WIDTH-1:0] a_addr, b_addr;

    localparam logic [1:0] BURST_INCR = 2'b01;
    localparam logic [2:0] SIZE_8B    = 3'd3;
    localparam logic [7:0] LEN_4B     = 8'd3; // 4 beats
    localparam logic [BYTES_PER_BEAT-1:0] WSTRB_ALL = {BYTES_PER_BEAT{1'b1}};

    seq0 = axi_mm_corner_list_seq::type_id::create("C8A_seq0_fix");

    a_addr = align_to_beat(WIN0_BASE + 32'h0200);
    b_addr = align_to_beat(WIN0_BASE + 32'h0300);

    // ------------------------------------------------------------
    // A: AW then W (so slave releases AWREADY for next)
    // ------------------------------------------------------------
    tr = mk_tr(0, a_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8A.AW_A", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = 4'h1;
    seq0.push_item(tr);

    tr = mk_wr_burst(a_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h1,
                    64'hC8A0_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C8A.W_A";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h1;
    seq0.push_item(tr);

    // ------------------------------------------------------------
    // B: AW then W
    // ------------------------------------------------------------
    tr = mk_tr(0, b_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8A.AW_B", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = 4'h2;
    seq0.push_item(tr);

    tr = mk_wr_burst(b_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h2,
                    64'hC8B0_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C8A.W_B";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h2;
    seq0.push_item(tr);

    // ------------------------------------------------------------
    // Wait B responses (can reverse order if你想測 out-of-order)
    // ------------------------------------------------------------
    tr = mk_tr(0, b_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8A.BWAIT_B_FIRST", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = 4'h2;
    seq0.push_item(tr);

    tr = mk_tr(0, a_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8A.BWAIT_A_SECOND", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = 4'h1;
    seq0.push_item(tr);

    // ------------------------------------------------------------
    // Readback verify
    // ------------------------------------------------------------
    seq0.push_item(mk_tr(1, a_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C8A.R_A", 0));
    seq0.push_item(mk_tr(1, b_addr, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, '0, '0, "C8A.R_B", 0));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_8A_FIX] Start: depth1-friendly split write. A=0x%0h(id=1) B=0x%0h(id=2)",
                a_addr, b_addr),
      UVM_MEDIUM)

    seq0.start(env_h.p0_agent.seqr);

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_8A_FIX] Done.", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 8B: outstanding writes + out-of-order B response (per port)
  //  - Per port:
  //      AW_ONLY(A), AW_ONLY(B)
  //      W_ONLY(A),  W_ONLY(B)
  //      B_WAIT(B) then B_WAIT(A)   // reverse order to prove BID gating
  //      READ(A), READ(B)
  //
  //  - Run P0/P1 concurrently (fork)
  // ------------------------------------------------------------
  task automatic run_case_8b_outstanding_ooo_b_p0p1();
    axi_mm_corner_list_seq seq0;
    axi_mm_corner_list_seq seq1;
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;

    localparam logic [1:0] BURST_INCR = 2'b01;
    localparam logic [2:0] SIZE_8B    = 3'd3;
    localparam logic [7:0] LEN_4B     = 8'd3; // 4 beats
    localparam logic [BYTES_PER_BEAT-1:0] WSTRB_ALL = {BYTES_PER_BEAT{1'b1}};

    logic [ADDR_WIDTH-1:0] p0_a, p0_b, p1_a, p1_b;

    // addresses (separate windows)
    p0_a = align_to_beat(WIN0_BASE + 32'h0200);
    p0_b = align_to_beat(WIN0_BASE + 32'h0300);

    p1_a = align_to_beat(WIN1_BASE + 32'h0200);
    p1_b = align_to_beat(WIN1_BASE + 32'h0300);

    seq0 = axi_mm_corner_list_seq::type_id::create("C8B_seq0");
    seq1 = axi_mm_corner_list_seq::type_id::create("C8B_seq1");

    // ============================================================
    // P0
    // ============================================================

    // AW_ONLY A(id=1), B(id=2)
    tr = mk_tr(0, p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8B.P0.AW_A", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = 4'h1;
    seq0.push_item(tr);

    tr = mk_tr(0, p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8B.P0.AW_B", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = 4'h2;
    seq0.push_item(tr);

    // W_ONLY A then B (payload full)
    tr = mk_wr_burst(p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, 64'hC8A0_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C8B.P0.W_A";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h1;
    seq0.push_item(tr);

    tr = mk_wr_burst(p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, 64'hC8B0_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C8B.P0.W_B";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h2;
    seq0.push_item(tr);

    // B_WAIT reverse: wait id=2 then id=1
    tr = mk_tr(0, p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8B.P0.BWAIT_B_FIRST", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = 4'h2;
    seq0.push_item(tr);

    tr = mk_tr(0, p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8B.P0.BWAIT_A_SECOND", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = 4'h1;
    seq0.push_item(tr);

    // Readback verify
    seq0.push_item(mk_tr(1, p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C8B.P0.R_A", 0));
    seq0.push_item(mk_tr(1, p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, '0, '0, "C8B.P0.R_B", 0));

    // ============================================================
    // P1 (same structure, same IDs are OK because independent interface)
    // ============================================================

    tr = mk_tr(0, p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8B.P1.AW_A", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = 4'h1;
    seq1.push_item(tr);

    tr = mk_tr(0, p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8B.P1.AW_B", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = 4'h2;
    seq1.push_item(tr);

    tr = mk_wr_burst(p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, 64'hC8A1_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C8B.P1.W_A";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h1;
    seq1.push_item(tr);

    tr = mk_wr_burst(p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, 64'hC8B1_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C8B.P1.W_B";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h2;
    seq1.push_item(tr);

    tr = mk_tr(0, p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8B.P1.BWAIT_B_FIRST", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = 4'h2;
    seq1.push_item(tr);

    tr = mk_tr(0, p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8B.P1.BWAIT_A_SECOND", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = 4'h1;
    seq1.push_item(tr);

    seq1.push_item(mk_tr(1, p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C8B.P1.R_A", 0));
    seq1.push_item(mk_tr(1, p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, '0, '0, "C8B.P1.R_B", 0));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_8B] Start: outstanding writes + reverse B_WAIT. P0(A=0x%0h,B=0x%0h) P1(A=0x%0h,B=0x%0h)",
                p0_a, p0_b, p1_a, p1_b),
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
    `uvm_info("CORNER_TEST", "[CASE_8B] Done.", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 8:
  //  - Goal: make AW backpressure observable and measurable in log
  //  - Key idea (avoid deadlock with single-thread driver):
  //      1) Push AW A/B/C to fill outstanding contexts
  //      2) Drive W_ONLY(A) so DUT can progress and eventually emit B
  //      3) Immediately push AW D (should stall until credit is freed)
  //         - While driver is blocked on AW(D), background b_collector()
  //           can still accept B -> releases credit -> AW(D) proceeds.
  //      4) Then finish remaining W and B waits, then readback.
  //
  //  - Run P0/P1 concurrently (fork)
  // ------------------------------------------------------------
  task automatic run_case_8_outstanding_aw_depth4_p0p1();
    axi_mm_corner_list_seq seq0;
    axi_mm_corner_list_seq seq1;
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;

    localparam logic [1:0] BURST_INCR = 2'b01;
    localparam logic [2:0] SIZE_8B    = 3'd3;
    localparam logic [7:0] LEN_4B     = 8'd3; // 4 beats
    localparam logic [BYTES_PER_BEAT-1:0] WSTRB_ALL = {BYTES_PER_BEAT{1'b1}};

    logic [ADDR_WIDTH-1:0] p0_a, p0_b, p0_c, p0_d;
    logic [ADDR_WIDTH-1:0] p1_a, p1_b, p1_c, p1_d;

    // addresses (separate windows)
    p0_a = align_to_beat(WIN0_BASE + 32'h0200);
    p0_b = align_to_beat(WIN0_BASE + 32'h0300);
    p0_c = align_to_beat(WIN0_BASE + 32'h0400);
    p0_d = align_to_beat(WIN0_BASE + 32'h0500);

    p1_a = align_to_beat(WIN1_BASE + 32'h0200);
    p1_b = align_to_beat(WIN1_BASE + 32'h0300);
    p1_c = align_to_beat(WIN1_BASE + 32'h0400);
    p1_d = align_to_beat(WIN1_BASE + 32'h0500);

    seq0 = axi_mm_corner_list_seq::type_id::create("C8_seq0");
    seq1 = axi_mm_corner_list_seq::type_id::create("C8_seq1");

    // ============================================================
    // P0 (BONUS ordering)
    //   AW A,B,C -> W(A) -> AW(D expects stall) -> W(B,C,D) -> B_WAIT -> READs
    // ============================================================

    // AW_ONLY A(id=1), B(id=2), C(id=3)
    tr = mk_tr(0, p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8B.P0.AW_A", 0);
    tr.op_kind  = OP_AW_ONLY; tr.wait_bid = 4'h1; seq0.push_item(tr);

    tr = mk_tr(0, p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8B.P0.AW_B", 0);
    tr.op_kind  = OP_AW_ONLY; tr.wait_bid = 4'h2; seq0.push_item(tr);

    tr = mk_tr(0, p0_c, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C8B.P0.AW_C", 0);
    tr.op_kind  = OP_AW_ONLY; tr.wait_bid = 4'h3; seq0.push_item(tr);

    // W_ONLY A first (let DUT start consuming context and potentially generate B)
    tr = mk_wr_burst(p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, 64'hC8A0_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C8B.P0.W_A_FIRST";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h1;
    seq0.push_item(tr);

    // AW_ONLY D(id=4) - EXPECT BACKPRESSURE STALL HERE
    tr = mk_tr(0, p0_d, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, '0, '0, "C8B.P0.AW_D_EXPECT_STALL", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = 4'h4;
    seq0.push_item(tr);

    // Remaining W_ONLY: B then C then D
    tr = mk_wr_burst(p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, 64'hC8B0_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C8B.P0.W_B";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h2;
    seq0.push_item(tr);

    tr = mk_wr_burst(p0_c, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, 64'hC8C0_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C8B.P0.W_C";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h3;
    seq0.push_item(tr);

    tr = mk_wr_burst(p0_d, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, 64'hC8D0_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C8B.P0.W_D";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h4;
    seq0.push_item(tr);

    // B_WAIT reverse: D, C, B, A
    tr = mk_tr(0, p0_d, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, '0, '0, "C8B.P0.BWAIT_D_FIRST", 0);
    tr.op_kind  = OP_B_WAIT; tr.wait_bid = 4'h4; seq0.push_item(tr);

    tr = mk_tr(0, p0_c, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C8B.P0.BWAIT_C_SECOND", 0);
    tr.op_kind  = OP_B_WAIT; tr.wait_bid = 4'h3; seq0.push_item(tr);

    tr = mk_tr(0, p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8B.P0.BWAIT_B_THIRD", 0);
    tr.op_kind  = OP_B_WAIT; tr.wait_bid = 4'h2; seq0.push_item(tr);

    tr = mk_tr(0, p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8B.P0.BWAIT_A_FOURTH", 0);
    tr.op_kind  = OP_B_WAIT; tr.wait_bid = 4'h1; seq0.push_item(tr);

    // Readback verify (use different R IDs)
    seq0.push_item(mk_tr(1, p0_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h8, '0, '0, "C8B.P0.R_A", 0));
    seq0.push_item(mk_tr(1, p0_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h9, '0, '0, "C8B.P0.R_B", 0));
    seq0.push_item(mk_tr(1, p0_c, BURST_INCR, SIZE_8B, LEN_4B, 4'hA, '0, '0, "C8B.P0.R_C", 0));
    seq0.push_item(mk_tr(1, p0_d, BURST_INCR, SIZE_8B, LEN_4B, 4'hB, '0, '0, "C8B.P0.R_D", 0));

    // ============================================================
    // P1 (same BONUS ordering)
    // ============================================================

    tr = mk_tr(0, p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8B.P1.AW_A", 0);
    tr.op_kind  = OP_AW_ONLY; tr.wait_bid = 4'h1; seq1.push_item(tr);

    tr = mk_tr(0, p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8B.P1.AW_B", 0);
    tr.op_kind  = OP_AW_ONLY; tr.wait_bid = 4'h2; seq1.push_item(tr);

    tr = mk_tr(0, p1_c, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C8B.P1.AW_C", 0);
    tr.op_kind  = OP_AW_ONLY; tr.wait_bid = 4'h3; seq1.push_item(tr);

    // W_ONLY A first
    tr = mk_wr_burst(p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, 64'hC8A1_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C8B.P1.W_A_FIRST";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h1;
    seq1.push_item(tr);

    // AW_ONLY D expects stall
    tr = mk_tr(0, p1_d, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, '0, '0, "C8B.P1.AW_D_EXPECT_STALL", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = 4'h4;
    seq1.push_item(tr);

    // Remaining W_ONLY: B,C,D
    tr = mk_wr_burst(p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, 64'hC8B1_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C8B.P1.W_B";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h2;
    seq1.push_item(tr);

    tr = mk_wr_burst(p1_c, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, 64'hC8C1_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C8B.P1.W_C";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h3;
    seq1.push_item(tr);

    tr = mk_wr_burst(p1_d, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, 64'hC8D1_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C8B.P1.W_D";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h4;
    seq1.push_item(tr);

    // B_WAIT reverse: D, C, B, A
    tr = mk_tr(0, p1_d, BURST_INCR, SIZE_8B, LEN_4B, 4'h4, '0, '0, "C8B.P1.BWAIT_D_FIRST", 0);
    tr.op_kind  = OP_B_WAIT; tr.wait_bid = 4'h4; seq1.push_item(tr);

    tr = mk_tr(0, p1_c, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C8B.P1.BWAIT_C_SECOND", 0);
    tr.op_kind  = OP_B_WAIT; tr.wait_bid = 4'h3; seq1.push_item(tr);

    tr = mk_tr(0, p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C8B.P1.BWAIT_B_THIRD", 0);
    tr.op_kind  = OP_B_WAIT; tr.wait_bid = 4'h2; seq1.push_item(tr);

    tr = mk_tr(0, p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C8B.P1.BWAIT_A_FOURTH", 0);
    tr.op_kind  = OP_B_WAIT; tr.wait_bid = 4'h1; seq1.push_item(tr);

    // Readbacks
    seq1.push_item(mk_tr(1, p1_a, BURST_INCR, SIZE_8B, LEN_4B, 4'h8, '0, '0, "C8B.P1.R_A", 0));
    seq1.push_item(mk_tr(1, p1_b, BURST_INCR, SIZE_8B, LEN_4B, 4'h9, '0, '0, "C8B.P1.R_B", 0));
    seq1.push_item(mk_tr(1, p1_c, BURST_INCR, SIZE_8B, LEN_4B, 4'hA, '0, '0, "C8B.P1.R_C", 0));
    seq1.push_item(mk_tr(1, p1_d, BURST_INCR, SIZE_8B, LEN_4B, 4'hB, '0, '0, "C8B.P1.R_D", 0));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_8_BONUS] Start: AW backpressure observable (AW A/B/C fill, W(A) first, then AW(D) should stall).
                P0(A=0x%0h,B=0x%0h,C=0x%0h,D=0x%0h) P1(A=0x%0h,B=0x%0h,C=0x%0h,D=0x%0h)",
                p0_a, p0_b, p0_c, p0_d, p1_a, p1_b, p1_c, p1_d),
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
    `uvm_info("CORNER_TEST", "[CASE_8_BONUS] Done.", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 9a:
  //  - Single port (P0) mixed-ID ordering stress
  //  - Issue multiple outstanding writes with different IDs
  //  - Send all W data, then WAIT B in a permuted order (not 1->2->3)
  //
  // Goal:
  //  - Ensure TB tracks completion by BID (ID-based), not FIFO order.
  //  - No driver special switch required.
  // ------------------------------------------------------------
  task automatic run_case_9a_mixed_id_ordering_p0();
    axi_mm_corner_list_seq seq0;
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;

    localparam logic [1:0] BURST_INCR = 2'b01;
    localparam logic [2:0] SIZE_8B    = 3'd3;
    localparam logic [7:0] LEN_4B     = 8'd3; // 4 beats
    localparam logic [BYTES_PER_BEAT-1:0] WSTRB_ALL = {BYTES_PER_BEAT{1'b1}};

    logic [ADDR_WIDTH-1:0] a1, a2, a3;

    // 3 independent addresses (same window, aligned)
    a1 = align_to_beat(WIN0_BASE + 32'h0200);
    a2 = align_to_beat(WIN0_BASE + 32'h0300);
    a3 = align_to_beat(WIN0_BASE + 32'h0400);

    seq0 = axi_mm_corner_list_seq::type_id::create("C9A_seq0");

    // --------------------------
    // 1) AW_ONLY: push 3 contexts
    // --------------------------
    tr = mk_tr(0, a1, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C9A.P0.AW_ID1", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = 4'h1;
    seq0.push_item(tr);

    tr = mk_tr(0, a2, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C9A.P0.AW_ID2", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = 4'h2;
    seq0.push_item(tr);

    tr = mk_tr(0, a3, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C9A.P0.AW_ID3", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = 4'h3;
    seq0.push_item(tr);

    // --------------------------
    // 2) W_ONLY: send data for all
    // --------------------------
    tr = mk_wr_burst(a1, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, 64'hC9A1_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C9A.P0.W_ID1";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h1;
    seq0.push_item(tr);

    tr = mk_wr_burst(a2, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, 64'hC9A2_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C9A.P0.W_ID2";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h2;
    seq0.push_item(tr);

    tr = mk_wr_burst(a3, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, 64'hC9A3_0000_0000_0000, WSTRB_ALL);
    tr.comment  = "C9A.P0.W_ID3";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = 4'h3;
    seq0.push_item(tr);

    // --------------------------
    // 3) B_WAIT in permuted order
    //    (deliberately NOT 1->2->3)
    // --------------------------
    tr = mk_tr(0, a2, BURST_INCR, SIZE_8B, LEN_4B, 4'h2, '0, '0, "C9A.P0.BWAIT_ID2_FIRST", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = 4'h2;
    seq0.push_item(tr);

    tr = mk_tr(0, a1, BURST_INCR, SIZE_8B, LEN_4B, 4'h1, '0, '0, "C9A.P0.BWAIT_ID1_SECOND", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = 4'h1;
    seq0.push_item(tr);

    tr = mk_tr(0, a3, BURST_INCR, SIZE_8B, LEN_4B, 4'h3, '0, '0, "C9A.P0.BWAIT_ID3_THIRD", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = 4'h3;
    seq0.push_item(tr);

    // --------------------------
    // 4) Readback verify (use different R IDs)
    // --------------------------
    seq0.push_item(mk_tr(1, a1, BURST_INCR, SIZE_8B, LEN_4B, 4'h8, '0, '0, "C9A.P0.R_ID8_ADDR1", 0));
    seq0.push_item(mk_tr(1, a2, BURST_INCR, SIZE_8B, LEN_4B, 4'h9, '0, '0, "C9A.P0.R_ID9_ADDR2", 0));
    seq0.push_item(mk_tr(1, a3, BURST_INCR, SIZE_8B, LEN_4B, 4'hA, '0, '0, "C9A.P0.R_IDA_ADDR3", 0));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_9A] Start: P0 mixed-ID write completion by BID (AW1/AW2/AW3 + W1/W2/W3, then B_WAIT order=2,1,3). addr1=0x%0h addr2=0x%0h addr3=0x%0h",
                a1, a2, a3),
      UVM_MEDIUM)

    seq0.start(env_h.p0_agent.seqr);

    #200ns;
    `uvm_info("CORNER_TEST", "[CASE_9A] Done.", UVM_MEDIUM)
  endtask

  // ------------------------------------------------------------
  // Case 9b: Mixed-ID ordering (P0/P1 concurrent)
  //  - Purpose:
  //      Stress "wait by BID (count[bid])" under multi-port concurrency.
  //      Even if DUT returns B in-order, the TB will wait out-of-order by ID.
  //  - Per port (example pattern):
  //      AW_ONLY:  ID1(A), ID2(B), ID3(C)
  //      W_ONLY :  ID1(A), ID2(B), ID3(C)
  //      B_WAIT:   permuted order
  //        P0: 2 -> 1 -> 3
  //        P1: 3 -> 1 -> 2
  //      READ verify: (use different R IDs)
  //  - Run P0/P1 concurrently (fork)
  // ------------------------------------------------------------
  task automatic run_case_9b_mixed_id_ordering_p0p1();
    axi_mm_corner_list_seq seq0;
    axi_mm_corner_list_seq seq1;
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;

    localparam logic [1:0] BURST_INCR = 2'b01;
    localparam logic [2:0] SIZE_8B    = 3'd3;
    localparam logic [7:0] LEN_4B     = 8'd3; // 4 beats
    localparam logic [BYTES_PER_BEAT-1:0] WSTRB_ALL = {BYTES_PER_BEAT{1'b1}};

    // IDs
    localparam logic [ID_WIDTH-1:0] ID1 = 'h1;
    localparam logic [ID_WIDTH-1:0] ID2 = 'h2;
    localparam logic [ID_WIDTH-1:0] ID3 = 'h3;

    // Read IDs (avoid collision with write IDs)
    localparam logic [ID_WIDTH-1:0] RID_A = 'h8;
    localparam logic [ID_WIDTH-1:0] RID_B = 'h9;
    localparam logic [ID_WIDTH-1:0] RID_C = 'hA;

    logic [ADDR_WIDTH-1:0] p0_a, p0_b, p0_c;
    logic [ADDR_WIDTH-1:0] p1_a, p1_b, p1_c;

    // addresses (separate windows)
    p0_a = align_to_beat(WIN0_BASE + 32'h0200);
    p0_b = align_to_beat(WIN0_BASE + 32'h0300);
    p0_c = align_to_beat(WIN0_BASE + 32'h0400);

    p1_a = align_to_beat(WIN1_BASE + 32'h0200);
    p1_b = align_to_beat(WIN1_BASE + 32'h0300);
    p1_c = align_to_beat(WIN1_BASE + 32'h0400);

    seq0 = axi_mm_corner_list_seq::type_id::create("C9b_seq0");
    seq1 = axi_mm_corner_list_seq::type_id::create("C9b_seq1");

    // ============================================================
    // P0 program
    // ============================================================

    // AW_ONLY A/B/C
    tr = mk_tr(0, p0_a, BURST_INCR, SIZE_8B, LEN_4B, ID1, '0, '0, "C9B.P0.AW_A(ID1)", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = ID1;
    seq0.push_item(tr);

    tr = mk_tr(0, p0_b, BURST_INCR, SIZE_8B, LEN_4B, ID2, '0, '0, "C9B.P0.AW_B(ID2)", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = ID2;
    seq0.push_item(tr);

    tr = mk_tr(0, p0_c, BURST_INCR, SIZE_8B, LEN_4B, ID3, '0, '0, "C9B.P0.AW_C(ID3)", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = ID3;
    seq0.push_item(tr);

    // W_ONLY A/B/C (in-order)
    tr = mk_wr_burst(p0_a, BURST_INCR, SIZE_8B, LEN_4B, ID1, 64'hC9B0_A000_0000_0000, WSTRB_ALL);
    tr.comment  = "C9B.P0.W_A(ID1)";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = ID1;
    seq0.push_item(tr);

    tr = mk_wr_burst(p0_b, BURST_INCR, SIZE_8B, LEN_4B, ID2, 64'hC9B0_B000_0000_0000, WSTRB_ALL);
    tr.comment  = "C9B.P0.W_B(ID2)";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = ID2;
    seq0.push_item(tr);

    tr = mk_wr_burst(p0_c, BURST_INCR, SIZE_8B, LEN_4B, ID3, 64'hC9B0_C000_0000_0000, WSTRB_ALL);
    tr.comment  = "C9B.P0.W_C(ID3)";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = ID3;
    seq0.push_item(tr);

    // B_WAIT (permuted): 2 -> 1 -> 3
    tr = mk_tr(0, p0_b, BURST_INCR, SIZE_8B, LEN_4B, ID2, '0, '0, "C9B.P0.BWAIT_ID2_FIRST", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = ID2;
    seq0.push_item(tr);

    tr = mk_tr(0, p0_a, BURST_INCR, SIZE_8B, LEN_4B, ID1, '0, '0, "C9B.P0.BWAIT_ID1_SECOND", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = ID1;
    seq0.push_item(tr);

    tr = mk_tr(0, p0_c, BURST_INCR, SIZE_8B, LEN_4B, ID3, '0, '0, "C9B.P0.BWAIT_ID3_THIRD", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = ID3;
    seq0.push_item(tr);

    // Readback verify
    seq0.push_item(mk_tr(1, p0_a, BURST_INCR, SIZE_8B, LEN_4B, RID_A, '0, '0, "C9B.P0.R_A", 0));
    seq0.push_item(mk_tr(1, p0_b, BURST_INCR, SIZE_8B, LEN_4B, RID_B, '0, '0, "C9B.P0.R_B", 0));
    seq0.push_item(mk_tr(1, p0_c, BURST_INCR, SIZE_8B, LEN_4B, RID_C, '0, '0, "C9B.P0.R_C", 0));

    // ============================================================
    // P1 program (same but different data + different B_WAIT order)
    // ============================================================

    // AW_ONLY A/B/C
    tr = mk_tr(0, p1_a, BURST_INCR, SIZE_8B, LEN_4B, ID1, '0, '0, "C9B.P1.AW_A(ID1)", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = ID1;
    seq1.push_item(tr);

    tr = mk_tr(0, p1_b, BURST_INCR, SIZE_8B, LEN_4B, ID2, '0, '0, "C9B.P1.AW_B(ID2)", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = ID2;
    seq1.push_item(tr);

    tr = mk_tr(0, p1_c, BURST_INCR, SIZE_8B, LEN_4B, ID3, '0, '0, "C9B.P1.AW_C(ID3)", 0);
    tr.op_kind  = OP_AW_ONLY;
    tr.wait_bid = ID3;
    seq1.push_item(tr);

    // W_ONLY A/B/C (in-order)
    tr = mk_wr_burst(p1_a, BURST_INCR, SIZE_8B, LEN_4B, ID1, 64'hC9B1_A000_0000_0000, WSTRB_ALL);
    tr.comment  = "C9B.P1.W_A(ID1)";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = ID1;
    seq1.push_item(tr);

    tr = mk_wr_burst(p1_b, BURST_INCR, SIZE_8B, LEN_4B, ID2, 64'hC9B1_B000_0000_0000, WSTRB_ALL);
    tr.comment  = "C9B.P1.W_B(ID2)";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = ID2;
    seq1.push_item(tr);

    tr = mk_wr_burst(p1_c, BURST_INCR, SIZE_8B, LEN_4B, ID3, 64'hC9B1_C000_0000_0000, WSTRB_ALL);
    tr.comment  = "C9B.P1.W_C(ID3)";
    tr.op_kind  = OP_W_ONLY;
    tr.wait_bid = ID3;
    seq1.push_item(tr);

    // B_WAIT (permuted): 3 -> 1 -> 2
    tr = mk_tr(0, p1_c, BURST_INCR, SIZE_8B, LEN_4B, ID3, '0, '0, "C9B.P1.BWAIT_ID3_FIRST", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = ID3;
    seq1.push_item(tr);

    tr = mk_tr(0, p1_a, BURST_INCR, SIZE_8B, LEN_4B, ID1, '0, '0, "C9B.P1.BWAIT_ID1_SECOND", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = ID1;
    seq1.push_item(tr);

    tr = mk_tr(0, p1_b, BURST_INCR, SIZE_8B, LEN_4B, ID2, '0, '0, "C9B.P1.BWAIT_ID2_THIRD", 0);
    tr.op_kind  = OP_B_WAIT;
    tr.wait_bid = ID2;
    seq1.push_item(tr);

    // Readback verify
    seq1.push_item(mk_tr(1, p1_a, BURST_INCR, SIZE_8B, LEN_4B, RID_A, '0, '0, "C9B.P1.R_A", 0));
    seq1.push_item(mk_tr(1, p1_b, BURST_INCR, SIZE_8B, LEN_4B, RID_B, '0, '0, "C9B.P1.R_B", 0));
    seq1.push_item(mk_tr(1, p1_c, BURST_INCR, SIZE_8B, LEN_4B, RID_C, '0, '0, "C9B.P1.R_C", 0));

    `uvm_info("CORNER_TEST",
      $sformatf("[CASE_9B] Start: Mixed-ID ordering P0/P1 concurrent. 
                P0(A=0x%0h,B=0x%0h,C=0x%0h) P1(A=0x%0h,B=0x%0h,C=0x%0h)",
                p0_a, p0_b, p0_c, p1_a, p1_b, p1_c),
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
    `uvm_info("CORNER_TEST", "[CASE_9B] Done.", UVM_MEDIUM)
  endtask

  // ============================================================
  // Case 10: Reset / Flush During Activity  (STABLE VERSION)
  // - Use reset as flush
  // - Phase A: in-flight traffic (NO verify)
  // - Mid-flight: assert reset
  // - DO NOT stop_sequences()
  // - DO NOT seq.stop()
  // - Phase B: clean verify after reset
  // ============================================================
  task automatic run_case_10_reset_during_activity();

    axi_mm_corner_list_seq seq0_a, seq1_a;
    axi_mm_corner_list_seq seq0_b, seq1_b;
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
    axi_mm_reset_seq rst_seq;

    localparam logic [1:0] BURST_INCR = 2'b01;
    localparam logic [2:0] SIZE_8B    = 3'd3;

    localparam logic [7:0] LEN_A = 8'd15;
    localparam logic [7:0] LEN_B = 8'd3;

    localparam logic [BYTES_PER_BEAT-1:0] WSTRB_ALL =
        {BYTES_PER_BEAT{1'b1}};

    localparam logic [ID_WIDTH-1:0] WID1 = 'h1;
    localparam logic [ID_WIDTH-1:0] WID2 = 'h2;
    localparam logic [ID_WIDTH-1:0] WID3 = 'h3;
    localparam logic [ID_WIDTH-1:0] WID4 = 'h4;

    localparam logic [ID_WIDTH-1:0] RID_A = 'h8;
    localparam logic [ID_WIDTH-1:0] RID_B = 'h9;
    localparam logic [ID_WIDTH-1:0] RID_C = 'hA;
    localparam logic [ID_WIDTH-1:0] RID_D = 'hB;

    logic [ADDR_WIDTH-1:0] p0_a, p0_b, p0_c, p0_d;
    logic [ADDR_WIDTH-1:0] p1_a, p1_b, p1_c, p1_d;

    // ------------------------------------------------------------
    // Address plan
    // ------------------------------------------------------------
    p0_a = align_to_beat(WIN0_BASE + 32'h0200);
    p0_b = align_to_beat(WIN0_BASE + 32'h0300);
    p0_c = align_to_beat(WIN0_BASE + 32'h0400);
    p0_d = align_to_beat(WIN0_BASE + 32'h0500);

    p1_a = align_to_beat(WIN1_BASE + 32'h0200);
    p1_b = align_to_beat(WIN1_BASE + 32'h0300);
    p1_c = align_to_beat(WIN1_BASE + 32'h0400);
    p1_d = align_to_beat(WIN1_BASE + 32'h0500);

    // ============================================================
    // Phase A (fire and forget)
    // ============================================================
    seq0_a = axi_mm_corner_list_seq::type_id::create("C10_seq0_A");
    seq1_a = axi_mm_corner_list_seq::type_id::create("C10_seq1_A");

    // P0
    tr = mk_wr_burst(p0_a, BURST_INCR, SIZE_8B, LEN_A, WID1,
                    64'hC10A_0A00_0000_0000, WSTRB_ALL);
    seq0_a.push_item(tr);

    tr = mk_wr_burst(p0_b, BURST_INCR, SIZE_8B, LEN_A, WID2,
                    64'hC10A_0B00_0000_0000, WSTRB_ALL);
    seq0_a.push_item(tr);

    tr = mk_wr_burst(p0_c, BURST_INCR, SIZE_8B, LEN_A, WID3,
                    64'hC10A_0C00_0000_0000, WSTRB_ALL);
    seq0_a.push_item(tr);

    tr = mk_wr_burst(p0_d, BURST_INCR, SIZE_8B, LEN_A, WID4,
                    64'hC10A_0D00_0000_0000, WSTRB_ALL);
    seq0_a.push_item(tr);

    // P1
    tr = mk_wr_burst(p1_a, BURST_INCR, SIZE_8B, LEN_A, WID1,
                    64'hC10A_1A00_0000_0000, WSTRB_ALL);
    seq1_a.push_item(tr);

    tr = mk_wr_burst(p1_b, BURST_INCR, SIZE_8B, LEN_A, WID2,
                    64'hC10A_1B00_0000_0000, WSTRB_ALL);
    seq1_a.push_item(tr);

    tr = mk_wr_burst(p1_c, BURST_INCR, SIZE_8B, LEN_A, WID3,
                    64'hC10A_1C00_0000_0000, WSTRB_ALL);
    seq1_a.push_item(tr);

    tr = mk_wr_burst(p1_d, BURST_INCR, SIZE_8B, LEN_A, WID4,
                    64'hC10A_1D00_0000_0000, WSTRB_ALL);
    seq1_a.push_item(tr);

    `uvm_info("CORNER_TEST",
        "[CASE_10] Phase A start (no stop, reset will abort driver)",
        UVM_MEDIUM)

    fork
      seq0_a.start(env_h.p0_agent.seqr);
      begin
        #1ns;
        seq1_a.start(env_h.p1_agent.seqr);
      end
    join_none

    // ============================================================
    // Mid-flight reset
    // ============================================================
    #400ns;

    `uvm_info("CORNER_TEST",
        "[CASE_10] *** MID-FLIGHT RESET ASSERT ***",
        UVM_MEDIUM)

    rst_seq = axi_mm_reset_seq::type_id::create("case10_mid_reset");
    rst_seq.assert_cycles   = 50;
    rst_seq.deassert_cycles = 10;
    rst_seq.start(env_h.rst_agent.seqr);

    // let system recover
    #800ns;

    // ============================================================
    // Phase B (must PASS)
    // ============================================================
    `uvm_info("CORNER_TEST",
        "[CASE_10] Phase B start (post-reset verify)",
        UVM_MEDIUM)

    seq0_b = axi_mm_corner_list_seq::type_id::create("C10_seq0_B");
    seq1_b = axi_mm_corner_list_seq::type_id::create("C10_seq1_B");

    seq0_b.push_item(
        mk_wr_burst(p0_a, BURST_INCR, SIZE_8B, LEN_B,
                    WID1, 64'hC10B_0A00_0000_0000, WSTRB_ALL));

    seq0_b.push_item(
        mk_tr(1, p0_a, BURST_INCR, SIZE_8B,
              LEN_B, RID_A, '0, '0, "C10B.P0.R_A", 0));

    seq1_b.push_item(
        mk_wr_burst(p1_c, BURST_INCR, SIZE_8B, LEN_B,
                    WID3, 64'hC10B_1C00_0000_0000, WSTRB_ALL));

    seq1_b.push_item(
        mk_tr(1, p1_c, BURST_INCR, SIZE_8B,
              LEN_B, RID_C, '0, '0, "C10B.P1.R_C", 0));

    fork
      seq0_b.start(env_h.p0_agent.seqr);
      begin
        #1ns;
        seq1_b.start(env_h.p1_agent.seqr);
      end
    join

    #200ns;

    `uvm_info("CORNER_TEST",
        "[CASE_10] Done.",
        UVM_MEDIUM)

  endtask




  // ------------------------------------------------------------
  // Run phase: corner-case traffic
  // ------------------------------------------------------------
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);

    `uvm_info("CORNER_TEST", "Starting AXI-MM corner-case transaction test", UVM_MEDIUM)

    env_h.do_initial_reset(
      phase,
      "corner_test initial reset",
      1_000_000ns 
    );

    `uvm_info("CORNER_TEST", "Initial reset done, start traffic.", UVM_MEDIUM)

    // Case1 should be clean and deterministic
    cfg_driver_stress_off();
    cfg_driver_hold_ready(1, 1);

    // Case 1
    // run_case_1_single_beat();

    // Case 2
    // run_case_2_boundary_edges();

    // Case 3
    // run_case_3_ordering_and_conflict();

    // Case 4
    // run_case_4_aw_ar_contention();

    // Case 5
    // run_case_5_wrap_fixed();

    // Case 6
    // run_case_6_wrap_edges();

    // Case 7
    // run_case_7_wstrb_patterns();

    // Case 8a
    // run_case_8a_multi_aw_no_interleave_fixed_for_depth1();

    // Case 8b
    // run_case_8b_outstanding_ooo_b_p0p1();

    // Case 8
    // run_case_8_outstanding_aw_depth4_p0p1();

    // Case 9a
    // run_case_9a_mixed_id_ordering_p0();

    // Case 9b
    // run_case_9b_mixed_id_ordering_p0p1();

    // Case 10
    run_case_10_reset_during_activity();

    `uvm_info("CORNER_TEST", "Corner-case transaction test completed", UVM_MEDIUM)

    phase.drop_objection(this);
  endtask

endclass : axi_mm_corner_test

`endif
