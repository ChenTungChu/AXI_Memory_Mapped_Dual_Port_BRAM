// File: tb/uvm/pkg/axi_mm_pkg.sv
`ifndef AXI_MM_PKG_SV
`define AXI_MM_PKG_SV

package axi_mm_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  //------------------------------------------------------------
  // Sequence Item
  //------------------------------------------------------------
  `include "../seq_item/axi_mm_seq_item.sv"

  //------------------------------------------------------------
  // Commit
  //------------------------------------------------------------
  `include "../commit/axi_mm_commit_item.sv"
  `include "../commit/axi_mm_commit_monitor.sv"
  `include "../commit/axi_mm_apply_item.sv"
  `include "../commit/axi_mm_apply_monitor.sv"

  //------------------------------------------------------------
  // Sequencer
  //------------------------------------------------------------
  `include "../sequencer/axi_mm_sequencer.sv"

  //------------------------------------------------------------
  // Sequences
  //------------------------------------------------------------
  `include "../seq/axi_mm_seq.sv"
  `include "../seq/axi_mm_cov_rand_seq.sv"
  // `include "../seq/axi_mm_cov_seq.sv"     
  `include "../cov/axi_mm_cov_sequence.sv"

  //------------------------------------------------------------
  // Reset Agent
  //------------------------------------------------------------
  `include "../reset/axi_mm_reset_agent.sv"

  //------------------------------------------------------------
  // Driver / Monitor / Agent
  //------------------------------------------------------------
  `include "../driver/axi_mm_driver.sv"
  `include "../monitor/axi_mm_monitor.sv"
  `include "../agent/axi_mm_agent.sv"

  //------------------------------------------------------------
  // Scoreboard / Coverage / Env
  //------------------------------------------------------------
  `include "../scoreboard/axi_mm_scoreboard.sv"
  `include "../cov/axi_mm_cov_scoreboard.sv"
  `include "../cov/axi_mm_cov_subscriber.sv"
  `include "../env/axi_mm_env.sv"

  //------------------------------------------------------------
  // Tests
  //------------------------------------------------------------
  `include "../test/axi_mm_smoke_test.sv"
  `include "../test/axi_mm_random_test.sv"
  `include "../test/axi_mm_corner_test.sv"
  `include "../test/axi_mm_directed_test.sv"
  `include "../test/axi_mm_coverage_test.sv"
  `include "../test/axi_mm_dummy_smoke_test.sv"

endpackage : axi_mm_pkg

`endif