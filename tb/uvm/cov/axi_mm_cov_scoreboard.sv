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

  // Sample variables
  logic [ADDR_WIDTH-1:0] addr_cp;
  bit                    rw_cp;
  logic [ID_WIDTH-1:0]   id_cp;
  logic [7:0]            len_cp;
  logic [2:0]            size_cp;
  logic [1:0]            burst_cp;
  int unsigned           src_port_cp; // 0=p0, 1=p1

  covergroup cg;
    option.per_instance = 1;

    cp_src   : coverpoint src_port_cp { bins p0 = {0}; bins p1 = {1}; }
    cp_rw    : coverpoint rw_cp;
    cp_addr  : coverpoint addr_cp;
    cp_id    : coverpoint id_cp;
    cp_len   : coverpoint len_cp;
    cp_size  : coverpoint size_cp;
    cp_burst : coverpoint burst_cp;

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
    src_port_cp = src_port;
    addr_cp     = tr.addr;
    rw_cp       = tr.rw;
    id_cp       = tr.id;
    len_cp      = tr.len;
    size_cp     = tr.size;
    burst_cp    = tr.burst;
    cg.sample();
  endfunction

  function real get_coverage();
    return cg.get_coverage();
  endfunction

endclass : axi_mm_cov_scoreboard

`endif
