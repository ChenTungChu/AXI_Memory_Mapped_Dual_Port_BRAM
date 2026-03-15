//---------------------------------------------------------------------
// Coverage Scoreboard / Coverage Collector for AXI-MM (2-IMP CLEAN)
// - Exposes TWO analysis_imps: analysis_imp_p0 / analysis_imp_p1
// - Uses unique uvm_analysis_imp_decl suffix to avoid typedef collisions
//---------------------------------------------------------------------
`ifndef AXI_MM_COV_SCOREBOARD_SV
`define AXI_MM_COV_SCOREBOARD_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

// IMPORTANT:
// Do NOT use _p0/_p1 here because other files (e.g. axi_mm_scoreboard)
// already declared them inside the same package compile scope.
`uvm_analysis_imp_decl(_cov_p0)
`uvm_analysis_imp_decl(_cov_p1)

class axi_mm_cov_scoreboard #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4
) extends uvm_component;

  `uvm_component_param_utils(axi_mm_cov_scoreboard #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

  typedef axi_mm_cov_scoreboard#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) this_t;

  // Two sinks (field names match your ENV expectation)
  uvm_analysis_imp_cov_p0 #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH), this_t) analysis_imp_p0;
  uvm_analysis_imp_cov_p1 #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH), this_t) analysis_imp_p1;

  localparam int BYTES_PER_BEAT = (DATA_WIDTH/8);

  // Window bases (published by env via config_db)
  logic [ADDR_WIDTH-1:0] win0_base;
  logic [ADDR_WIDTH-1:0] win1_base;

  // Sample variables
  logic [ADDR_WIDTH-1:0] addr_cp;
  logic [ADDR_WIDTH-1:0] addr_off_cp;   // address offset within window (more meaningful than full 32-bit addr)
  axi_rw_e               rw_cp;
  logic [ID_WIDTH-1:0]   id_cp;
  logic [7:0]            len_cp;
  logic [2:0]            size_cp;
  logic [1:0]            burst_cp;
  int unsigned           src_port_cp; // 0=p0, 1=p1

  covergroup cg;
    option.per_instance = 1;

    // ----------------------------
    // Source + direction
    // ----------------------------
    cp_src : coverpoint src_port_cp { bins p0 = {0}; bins p1 = {1}; }

    cp_rw  : coverpoint rw_cp {
      bins READ  = {AXI_READ};
      bins WRITE = {AXI_WRITE};
    }

    // ----------------------------
    // Addressing (use offset bins; avoid 32-bit auto-bins black hole)
    // ----------------------------
    // addr_off_cp is in BYTES relative to the corresponding window base.
    // Keep bins coarse + edge-focused (good for boundary/crossing tests).
    cp_addr_off : coverpoint addr_off_cp {
      bins LOW_EDGE   = {[0 : (BYTES_PER_BEAT*4 - 1)]};
      bins MID_RANGE  = default;
      // Upper edge bins are hard without knowing exact window size;
      // MID_RANGE still captures the rest without creating massive bin counts.
    }

    // Keep raw addr visible but do not let it dominate bins
    // (Make it very coarse to avoid 64 auto-bins across 4GB.)
    cp_addr_coarse : coverpoint addr_cp {
      option.auto_bin_max = 4;
    }

    // ----------------------------
    // IDs / burst / size / len
    // ----------------------------
    cp_id : coverpoint id_cp {
      // If ID_WIDTH small, this will still be meaningful; keep bins bounded.
      option.auto_bin_max = 16;
    }

    cp_burst : coverpoint burst_cp {
      bins FIXED = {2'b00};
      bins INCR  = {2'b01};
      bins WRAP  = {2'b10};
      illegal_bins RSV = {2'b11};
    }

    cp_size : coverpoint size_cp {
      bins B1 = {3'd0};
      bins B2 = {3'd1};
      bins B4 = {3'd2};
      bins B8 = {3'd3};
      illegal_bins TOO_WIDE = {[3'd4:3'd7]};
    }

    cp_len : coverpoint len_cp {
      bins LEN0 = {8'd0};
      bins S[]  = {[8'd1:8'd3]};
      bins M[]  = {[8'd4:8'd15]};
      bins L[]  = {[8'd16:8'd63]};
      bins MAX  = {8'd255};

      // Optional: explicitly track WRAP-legal lengths
      bins WRAP_LEGAL = {8'd1, 8'd3, 8'd7, 8'd15};
    }

    // ----------------------------
    // Crosses (keep original intent)
    // ----------------------------
    x_src_rw   : cross cp_src, cp_rw;
    x_rw_burst : cross cp_rw, cp_burst;
    x_rw_size  : cross cp_rw, cp_size;
    x_rw_len   : cross cp_rw, cp_len;

  endgroup

  function new(string name="cov_scoreboard_h", uvm_component parent=null);
    super.new(name, parent);
    cg = new();
    analysis_imp_p0 = new("analysis_imp_p0", this);
    analysis_imp_p1 = new("analysis_imp_p1", this);

    win0_base = '0;
    win1_base = '0;
  endfunction

  // Pull window bases from config_db (env publishes these keys to "*")
  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(logic [ADDR_WIDTH-1:0])::get(this, "", "WIN0_BASE", win0_base));
    void'(uvm_config_db#(logic [ADDR_WIDTH-1:0])::get(this, "", "WIN1_BASE", win1_base));
  endfunction

  // uvm_analysis_imp_decl(_cov_p0) expects write_cov_p0(...)
  function void write_cov_p0(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
    do_sample(tr, 0);
  endfunction

  // uvm_analysis_imp_decl(_cov_p1) expects write_cov_p1(...)
  function void write_cov_p1(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
    do_sample(tr, 1);
  endfunction

  function void do_sample(
      axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr,
      int unsigned src_port
  );
    // Match cov_subscriber behavior: only count FULL transactions
    if (tr.op_kind != OP_FULL) return;

    src_port_cp = src_port;

    addr_cp  = tr.addr;
    rw_cp    = tr.rw;
    id_cp    = tr.id;
    len_cp   = tr.len;
    size_cp  = tr.size;
    burst_cp = tr.burst;

    // Compute per-port window offset (byte offset)
    if (src_port == 0) addr_off_cp = (tr.addr - win0_base);
    else               addr_off_cp = (tr.addr - win1_base);

    cg.sample();
  endfunction

  function real get_coverage();
    return cg.get_coverage();
  endfunction

endclass : axi_mm_cov_scoreboard

`endif