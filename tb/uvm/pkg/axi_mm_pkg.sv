//---------------------------------------------------------------------
// axi_mm_pkg.sv
// Central UVM package for AXI Memory-Mapped Verification Environment
//---------------------------------------------------------------------
`ifndef AXI_MM_PKG_SV
`define AXI_MM_PKG_SV

package axi_mm_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    //------------------------------------------------------------
    // Interface
    //------------------------------------------------------------
    // `include "../../interface/axi_mm_if.sv"

    //------------------------------------------------------------
    // Sequence Item
    //------------------------------------------------------------
    `include "../seq_item/axi_mm_seq_item.sv"

    //------------------------------------------------------------
    // Sequencer
    //------------------------------------------------------------
    `include "../sequencer/axi_mm_sequencer.sv"

    //------------------------------------------------------------
    // Sequences
    //------------------------------------------------------------
    `include "../seq/axi_mm_seq.sv"
    `include "../seq/axi_mm_cov_seq.sv"
    `include "../cov/axi_mm_cov_sequence.sv"

    //------------------------------------------------------------
    // Driver + Monitor + Agent
    //------------------------------------------------------------
    `include "../driver/axi_mm_driver.sv"
    `include "../monitor/axi_mm_monitor.sv"
    `include "../agent/axi_mm_agent.sv"

    //------------------------------------------------------------
    // Scoreboard + Environment
    //------------------------------------------------------------
    `include "../scoreboard/axi_mm_scoreboard.sv"
    `include "../cov/axi_mm_cov_scoreboard.sv"
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
