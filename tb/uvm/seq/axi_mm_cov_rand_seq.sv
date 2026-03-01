`ifndef AXI_MM_COV_RAND_SEQ_SV
`define AXI_MM_COV_RAND_SEQ_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

// Constrained-random traffic for coverage closure.
// Key fixes:
// 1) If enable_split_ops=1, generate a *coherent triplet*:
//    AW_ONLY -> W_ONLY -> B_WAIT (same id/addr/len/size/burst)
//    so DUT/monitor/scoreboard won't explode.
// 2) WRAP start address aligned to wrap boundary = beats * size_bytes
// 3) FIXED burst footprint uses 1 beat
//
class axi_mm_cov_rand_seq #(
  int ADDR_WIDTH = 32,
  int DATA_WIDTH = 64,
  int ID_WIDTH   = 4
) extends uvm_sequence #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH));

  `uvm_object_param_utils(axi_mm_cov_rand_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

  localparam int BYTES_PER_BEAT = (DATA_WIDTH/8);

  // -----------------------
  // knobs
  // -----------------------
  rand int unsigned n_tr = 2000;

  rand logic [ADDR_WIDTH-1:0] win0_base  = '0;
  rand logic [ADDR_WIDTH-1:0] win1_base  = '0;
  rand int unsigned           win0_bytes = 4096;
  rand int unsigned           win1_bytes = 4096;

  rand int unsigned pct_win0 = 50;

  rand int unsigned pct_wr = 50; // write %

  // burst mix (00 FIXED, 01 INCR, 10 WRAP)
  rand int unsigned pct_incr  = 60;
  rand int unsigned pct_fixed = 20;
  rand int unsigned pct_wrap  = 20;

  // size mix (bytes): 1/2/4/8 but capped by bus width
  rand int unsigned pct_size_1 = 25;
  rand int unsigned pct_size_2 = 25;
  rand int unsigned pct_size_4 = 25;
  rand int unsigned pct_size_8 = 25;

  // length (beats) mix
  rand int unsigned pct_len_1     = 20; // 1 beat
  rand int unsigned pct_len_short = 40; // 2~4
  rand int unsigned pct_len_mid   = 35; // 5~16
  rand int unsigned pct_len_long  = 3;  // 17~64
  rand int unsigned pct_len_max   = 2;  // 256

  // WSTRB bias
  rand bit enable_wstrb_bias = 0;
  rand int unsigned pct_w_all0   = 5;
  rand int unsigned pct_w_all1   = 20;
  rand int unsigned pct_w_onehot = 20;
  rand int unsigned pct_w_sparse = 55;

  // edge bias
  rand bit bias_boundary   = 0;
  rand bit bias_end_of_mem = 0;

  // split ops control
  rand bit enable_split_ops = 0;

  // if split ops enabled: percentage to use split-triplet vs full write
  rand int unsigned pct_split_triplet = 20; // 20% triplet, 80% full

  // randomize retry
  int unsigned rand_retry = 30;

  // -----------------------
  // sanity constraints
  // -----------------------
  constraint c_pct_range {
    pct_win0 inside {[0:100]};
    pct_wr   inside {[0:100]};

    pct_incr + pct_fixed + pct_wrap == 100;
    pct_size_1 + pct_size_2 + pct_size_4 + pct_size_8 == 100;
    pct_len_1 + pct_len_short + pct_len_mid + pct_len_long + pct_len_max == 100;

    pct_w_all0 + pct_w_all1 + pct_w_onehot + pct_w_sparse == 100;
    pct_split_triplet inside {[0:100]};
  }

  function new(string name="axi_mm_cov_rand_seq");
    super.new(name);
  endfunction

  // -----------------------
  // helper: pick by 4-way pct
  // -----------------------
  function automatic int unsigned pick_by_pct4(
    int unsigned p0, int unsigned p1, int unsigned p2, int unsigned p3
  );
    int unsigned sum, r;
    sum = p0 + p1 + p2 + p3;
    r   = $urandom_range(1, sum);
    if (r <= p0) return 0;
    r -= p0;
    if (r <= p1) return 1;
    r -= p1;
    if (r <= p2) return 2;
    return 3;
  endfunction

  function automatic int unsigned pick_len_beats();
    int unsigned r;
    r = $urandom_range(1, 100);
    if (r <= pct_len_1) return 1;
    r -= pct_len_1;
    if (r <= pct_len_short) return $urandom_range(2,4);
    r -= pct_len_short;
    if (r <= pct_len_mid) return $urandom_range(5,16);
    r -= pct_len_mid;
    if (r <= pct_len_long) return $urandom_range(17,64);
    return 256;
  endfunction

  function automatic int unsigned pick_size_bytes();
    int unsigned idx;
    int unsigned max_bytes;
    max_bytes = BYTES_PER_BEAT;

    idx = pick_by_pct4(pct_size_1, pct_size_2, pct_size_4, pct_size_8);
    case (idx)
      0: return (1  <= max_bytes) ? 1 : max_bytes;
      1: return (2  <= max_bytes) ? 2 : max_bytes;
      2: return (4  <= max_bytes) ? 4 : max_bytes;
      default: return (8 <= max_bytes) ? 8 : max_bytes;
    endcase
  endfunction

  function automatic logic [1:0] pick_burst();
    int unsigned r;
    r = $urandom_range(1, 100);
    if (r <= pct_fixed) return 2'b00;
    r -= pct_fixed;
    if (r <= pct_incr)  return 2'b01;
    return 2'b10;
  endfunction

  function automatic logic [BYTES_PER_BEAT-1:0] gen_wstrb_pattern();
    logic [BYTES_PER_BEAT-1:0] w;
    int unsigned r;

    if (!enable_wstrb_bias) return {BYTES_PER_BEAT{1'b1}};

    r = $urandom_range(1,100);
    if (r <= pct_w_all0) return '0;
    r -= pct_w_all0;
    if (r <= pct_w_all1) return {BYTES_PER_BEAT{1'b1}};
    r -= pct_w_all1;
    if (r <= pct_w_onehot) begin
      w = '0;
      w[$urandom_range(0, BYTES_PER_BEAT-1)] = 1'b1;
      return w;
    end

    do begin
      w = $urandom();
    end while (w == '0);
    return w;
  endfunction

  // pick a start addr within window; aligns to:
  // - FIXED/INCR: align to size_bytes
  // - WRAP: align to wrap boundary = beats*size_bytes
  function automatic logic [ADDR_WIDTH-1:0] pick_addr(
      logic [ADDR_WIDTH-1:0] base,
      int unsigned win_bytes,
      int unsigned size_bytes,
      int unsigned beats,
      logic [1:0] burst_sel
  );
      logic [ADDR_WIDTH-1:0] a;
      int unsigned total_bytes;
      int unsigned align_bytes;
      int unsigned max_off;

      if (burst_sel == 2'b00) begin
        total_bytes = size_bytes;        // FIXED footprint = 1 beat
        align_bytes = size_bytes;
      end
      else begin
        total_bytes = beats * size_bytes; // INCR/WRAP footprint
        if (burst_sel == 2'b10) align_bytes = total_bytes; // WRAP boundary align
        else                    align_bytes = size_bytes;
      end

      if (win_bytes > total_bytes) max_off = win_bytes - total_bytes;
      else                         max_off = 0;

      if (bias_end_of_mem) begin
        int unsigned tail;
        tail = (max_off > 256) ? 256 : max_off;
        a = base + (max_off - $urandom_range(0, tail));
      end
      else if (bias_boundary) begin
        int unsigned boundary;
        int signed target, jitter, off_s;

        boundary = 4096;
        target   = boundary - total_bytes;
        jitter   = $urandom_range(-64, 64);

        if (target < 0) target = 0;
        off_s = target + jitter;

        if (off_s < 0)       off_s = 0;
        if (off_s > max_off) off_s = max_off;

        a = base + logic'(off_s);
      end
      else begin
        a = base + $urandom_range(0, max_off);
      end

      if (align_bytes != 0)
        a = (a / align_bytes) * align_bytes;

      return a;
  endfunction

  // randomize helper with retries (casts included)
  function automatic bit rand_item(
    ref axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr,
    input axi_rw_e rw_sel,
    input axi_mm_op_kind_e op_sel,
    input logic [ADDR_WIDTH-1:0] addr_sel,
    input int unsigned beats,
    input int unsigned size_bytes,
    input logic [1:0] burst_sel,
    input logic [ID_WIDTH-1:0] id_sel
  );
    bit ok;
    int unsigned i;
    logic [7:0] len8;
    logic [2:0] size3;
    logic [1:0] burst2;

    len8   = logic'(beats-1);
    size3  = logic'($clog2(size_bytes));
    burst2 = burst_sel;

    ok = 0;
    for (i = 0; i < rand_retry; i++) begin
      if (tr.randomize() with {
            rw      == rw_sel;
            op_kind == op_sel;

            addr    == addr_sel;
            id      == id_sel;

            len     == len8;
            size    == size3;
            burst   == burst2;
          }) begin
        ok = 1;
        break;
      end
    end
    return ok;
  endfunction

  // -----------------------
  // main body
  // -----------------------
  virtual task body();
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr2;
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr3;

    if (n_tr == 0) return;

    repeat (n_tr) begin
      bit is_write;
      bit do_split_triplet;

      int unsigned beats;
      int unsigned size_bytes;
      logic [1:0]  burst_sel;

      logic [ADDR_WIDTH-1:0] base;
      int unsigned win_bytes;
      logic [ADDR_WIDTH-1:0] addr_sel;

      logic [ID_WIDTH-1:0] id_sel;

      // decide R/W
      is_write = ($urandom_range(1,100) <= pct_wr);

      // decide split-triplet only for WRITE when enabled
      do_split_triplet = 0;
      if (is_write && enable_split_ops) begin
        do_split_triplet = ($urandom_range(1,100) <= pct_split_triplet);
      end

      // choose basic fields
      beats      = pick_len_beats();
      size_bytes = pick_size_bytes();
      burst_sel  = pick_burst();

      // WRAP legality: beats must be power-of-2, else force INCR
      if (burst_sel == 2'b10) begin
        if (!((beats != 0) && ((beats & (beats-1)) == 0))) begin
          burst_sel = 2'b01;
        end
      end

      // pick window
      if ($urandom_range(1,100) <= pct_win0) begin
        base      = win0_base;
        win_bytes = win0_bytes;
      end else begin
        base      = win1_base;
        win_bytes = win1_bytes;
      end

      addr_sel = pick_addr(base, win_bytes, size_bytes, beats, burst_sel);

      // id selection
      id_sel = $urandom();

      // -------------------------
      // READ: always OP_FULL
      // -------------------------
      if (!is_write) begin
        tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("cov_rd");

        if (!rand_item(tr, AXI_READ, OP_FULL, addr_sel, beats, size_bytes, burst_sel, id_sel)) begin
          `uvm_error("COV_SEQ",
            $sformatf("READ randomize failed (beats=%0d sizeB=%0d burst=%0b addr=0x%0h)",
                      beats, size_bytes, burst_sel, addr_sel))
          continue;
        end

        start_item(tr);
        finish_item(tr);
        continue;
      end

      // -------------------------
      // WRITE: either FULL, or coherent split-triplet
      // -------------------------
      if (!do_split_triplet) begin
        tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("cov_wr_full");

        if (!rand_item(tr, AXI_WRITE, OP_FULL, addr_sel, beats, size_bytes, burst_sel, id_sel)) begin
          `uvm_error("COV_SEQ",
            $sformatf("WRITE(OP_FULL) randomize failed (beats=%0d sizeB=%0d burst=%0b addr=0x%0h)",
                      beats, size_bytes, burst_sel, addr_sel))
          continue;
        end

        // override payload after randomize (seq_item allocates arrays for OP_FULL)
        if (tr.wdata_beats.size() != (tr.len+1) || tr.wstrb_beats.size() != (tr.len+1))
          tr.set_beats_len(tr.len);

        foreach (tr.wdata_beats[i]) tr.wdata_beats[i] = {$urandom(), $urandom()};
        foreach (tr.wstrb_beats[i]) tr.wstrb_beats[i] = gen_wstrb_pattern();

        start_item(tr);
        finish_item(tr);
      end
      else begin
        // Split triplet: AW_ONLY -> W_ONLY -> B_WAIT (same ID/fields)
        tr  = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("cov_aw");
        tr2 = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("cov_w");
        tr3 = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("cov_b");

        // AW_ONLY (keep same beats/size/burst)
        if (!rand_item(tr, AXI_WRITE, OP_AW_ONLY, addr_sel, beats, size_bytes, burst_sel, id_sel)) begin
          `uvm_error("COV_SEQ",
            $sformatf("WRITE(OP_AW_ONLY) randomize failed (beats=%0d sizeB=%0d burst=%0b addr=0x%0h)",
                      beats, size_bytes, burst_sel, addr_sel))
          continue;
        end

        // W_ONLY: must match AW
        if (!rand_item(tr2, AXI_WRITE, OP_W_ONLY, addr_sel, beats, size_bytes, burst_sel, id_sel)) begin
          `uvm_error("COV_SEQ",
            $sformatf("WRITE(OP_W_ONLY) randomize failed (beats=%0d sizeB=%0d burst=%0b addr=0x%0h)",
                      beats, size_bytes, burst_sel, addr_sel))
          continue;
        end

        // Payload for W_ONLY
        if (tr2.wdata_beats.size() != (tr2.len+1) || tr2.wstrb_beats.size() != (tr2.len+1))
          tr2.set_beats_len(tr2.len);

        foreach (tr2.wdata_beats[i]) tr2.wdata_beats[i] = {$urandom(), $urandom()};
        foreach (tr2.wstrb_beats[i]) tr2.wstrb_beats[i] = gen_wstrb_pattern();

        // B_WAIT: wait_bid must match id
        // For B_WAIT semantics, keep len soft to 0; don't force beats here.
        // We'll just randomize with minimal constraints and explicitly set wait_bid=id.
        if (!tr3.randomize() with {
              rw      == AXI_WRITE;
              op_kind == OP_B_WAIT;
              id      == id_sel;
              wait_bid== id_sel;
            }) begin
          `uvm_error("COV_SEQ", "WRITE(OP_B_WAIT) randomize failed")
          continue;
        end

        // Send triplet in order
        start_item(tr);  finish_item(tr);
        start_item(tr2); finish_item(tr2);
        start_item(tr3); finish_item(tr3);
      end
    end
  endtask

endclass

`endif