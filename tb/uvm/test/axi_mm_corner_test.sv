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
    // Simple deterministic pattern:
    // [63:48]=id, [47:32]=beat_idx, [31:0]=addr[31:0]^constant
    logic [DATA_WIDTH-1:0] v;
    v = '0;
    v[63:48] = {12'h0, id};                 // id (4b) in low bits of this field
    v[47:32] = beat_idx[15:0];
    v[31:0]  = addr[31:0] ^ 32'hA5A5_5A5A;
    return v;
  endfunction

  // ------------------------------------------------------------
  // Helper: build a transaction item (corner-friendly)
  //
  // Notes:
  // - Allocates arrays with set_beats_len(len)
  // - For writes:
  //   * If fill_all_beats=1: fills every beat with deterministic data+mask
  //   * Else: fills only beat[0] (good for LEN=0)
  // - For reads: ignores wdata/wstrb
  // ------------------------------------------------------------
  function automatic axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) mk_tr(
      input bit                         is_read,
      input logic [ADDR_WIDTH-1:0]      addr,
      input logic [1:0]                 burst,         // 00 FIXED, 01 INCR, 10 WRAP
      input logic [2:0]                 size,          // AXI SIZE encoding
      input logic [7:0]                 len,           // AXI LEN (0-based)
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

    // Allocate arrays (beats = len+1)
    tr.set_beats_len(tr.len);
    beats = tr.len + 1;

    if (!is_read) begin
      if (fill_all_beats) begin
        // Fill all beats deterministically
        for (int unsigned i = 0; i < beats; i++) begin
          tr.data_beats[i]  = beat_data_seed(id, i, addr);
          tr.wstrb_beats[i] = wstrb0; // same mask for all beats (simple & deterministic)
        end
      end else begin
        // Default: only fill beat[0] (perfect for LEN=0)
        tr.data_beats[0]  = wdata0;
        tr.wstrb_beats[0] = wstrb0;
      end
    end

    return tr;
  endfunction

  // ------------------------------------------------------------
  // Helper: build a WRITE burst transaction with full payload
  //  - rw=WRITE
  //  - beats=len+1
  //  - fills data_beats[i] and wstrb_beats[i]
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
      tr.data_beats[i]  = data0 + i;        // deterministic stepping pattern
      tr.wstrb_beats[i] = wstrb_all;        // usually all-1 for boundary tests
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
  // Run phase: corner-case traffic
  // ------------------------------------------------------------
  virtual task run_phase(uvm_phase phase);

    phase.raise_objection(this);

    `uvm_info("CORNER_TEST", "Starting AXI-MM corner-case transaction test", UVM_MEDIUM)

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
    run_case_4_aw_ar_contention();


    `uvm_info("CORNER_TEST", "Corner-case transaction test completed", UVM_MEDIUM)

    phase.drop_objection(this);
  endtask

endclass : axi_mm_corner_test

`endif
