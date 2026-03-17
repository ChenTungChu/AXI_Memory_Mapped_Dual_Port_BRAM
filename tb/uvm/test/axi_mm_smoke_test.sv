// File: tb/uvm/test/axi_mm_smoke_test.sv
`ifndef AXI_MM_SMOKE_TEST_SV
`define AXI_MM_SMOKE_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

class axi_mm_smoke_test extends uvm_test;
  `uvm_component_utils(axi_mm_smoke_test)

  localparam int ADDR_WIDTH = 32;
  localparam int DATA_WIDTH = 64;
  localparam int ID_WIDTH   = 4;

  axi_mm_env#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) env_h;

  function new(string name = "axi_mm_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_h = axi_mm_env#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("env_h", this);
  endfunction

  virtual task run_phase(uvm_phase phase);
    axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) seq0;
    axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) seq1;

    phase.raise_objection(this);
    `uvm_info("SMOKE_TEST", "Starting AXI-MM Smoke Test (Deterministic P0/P1 contention)", UVM_LOW)

    seq0 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("seq0");
    seq1 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("seq1");

    // P0
    seq0.num_transactions     = 16;
    seq0.max_beats            = 8;
    seq0.read_percent         = 20; 

    seq0.restrict_addr_window = 1'b1;
    seq0.window_base          = 32'h0000_0000;
    seq0.window_bytes         = 64;         
    seq0.enable_locality      = 1'b1;
    seq0.locality_prob        = 80;

    // P1
    seq1.num_transactions = 16;
    seq1.max_beats        = 8;
    seq1.read_percent     = 20;

    seq1.restrict_addr_window = 1'b1;
    seq1.window_base          = 32'h0000_0000;
    seq1.window_bytes         = 64;
    seq1.enable_locality      = 1'b1;
    seq1.locality_prob        = 80;

    // Simple burst
    seq0.enable_wrap          = 1'b0;
    seq0.enable_fixed         = 1'b0;
    seq0.enable_size_rand     = 1'b0;
    seq0.enable_partial_wstrb = 1'b0;

    seq1.enable_wrap          = 1'b0;
    seq1.enable_fixed         = 1'b0;
    seq1.enable_size_rand     = 1'b0;
    seq1.enable_partial_wstrb = 1'b0;

    fork
      seq0.start(env_h.p0_agent.seqr);
      seq1.start(env_h.p1_agent.seqr);
    join

    `uvm_info("SMOKE_TEST", "Smoke Test Finished", UVM_LOW)
    phase.drop_objection(this);
  endtask

endclass : axi_mm_smoke_test

`endif
