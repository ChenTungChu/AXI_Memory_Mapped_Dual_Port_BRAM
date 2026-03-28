// File: tb/uvm/sequencer/axi_mm_sequencer.sv
`ifndef AXI_MM_SEQUENCER_SV
`define AXI_MM_SEQUENCER_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

class axi_mm_sequencer #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4
) extends uvm_sequencer#(
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)
);

    `uvm_component_param_utils(axi_mm_sequencer #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

endclass

`endif
