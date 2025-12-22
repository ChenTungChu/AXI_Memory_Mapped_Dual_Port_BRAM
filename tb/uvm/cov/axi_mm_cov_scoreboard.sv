//---------------------------------------------------------------------
// Coverage Scoreboard / Coverage Collector for AXI-MM
//---------------------------------------------------------------------

`ifndef AXI_MM_COV_SCOREBOARD_SV
`define AXI_MM_COV_SCOREBOARD_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;  

class axi_mm_cov_scoreboard extends uvm_component;
    `uvm_component_utils(axi_mm_cov_scoreboard)

    uvm_analysis_imp #(axi_mm_seq_item, axi_mm_cov_scoreboard) analysis_export;

    //------------------------------------------------------------
    // Dummy clock for optional clocked covergroups
    //------------------------------------------------------------
    logic clk;

    //------------------------------------------------------------
    // Covergroup sample variables
    //------------------------------------------------------------
    bit [31:0] addr_cp;
    bit        rw_cp;

    //------------------------------------------------------------
    // Embedded Covergroup Declaration
    //------------------------------------------------------------
    // Note:
    // - This covergroup does not use an event, because sampling
    //   is performed manually in the sample() function.
    // - option.per_instance is recommended to distinguish multiple
    //   scoreboard instances in coverage reports.
    covergroup cg;
        option.per_instance = 1;
        coverpoint addr_cp;
        coverpoint rw_cp;
    endgroup

    //------------------------------------------------------------
    // Constructor
    //------------------------------------------------------------
    function new(string name = "cov_scoreboard", uvm_component parent = null);
        super.new(name, parent);
        clk = 0;
        cg = new();  // Instantiate embedded covergroup
        analysis_export = new("analysis_export", this);
    endfunction

    //------------------------------------------------------------
    // Write 
    //------------------------------------------------------------
    function void write(axi_mm_seq_item tr);
        sample(tr);
    endfunction

    //------------------------------------------------------------
    // Sample a transaction
    //------------------------------------------------------------
    function void sample(axi_mm_seq_item tr);
        addr_cp = tr.addr;
        rw_cp   = tr.rw;
        cg.sample();  // Manually trigger covergroup sampling
    endfunction

    //------------------------------------------------------------
    // Return coverage percentage
    //------------------------------------------------------------
    function real get_coverage();
        return cg.get_coverage();
    endfunction

endclass : axi_mm_cov_scoreboard

`endif
