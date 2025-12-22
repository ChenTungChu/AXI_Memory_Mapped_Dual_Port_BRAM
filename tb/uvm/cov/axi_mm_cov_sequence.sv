// File: tb/uvm/cov/axi_mm_cov_sequence.sv

//---------------------------------------------------------------------
// Coverage Sequence for AXI-MM
//---------------------------------------------------------------------

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

class axi_mm_cov_sequence #(int ADDR_WIDTH = 32,
                            int DATA_WIDTH = 64,
                            int ID_WIDTH   = 4)
    extends uvm_sequence #(axi_mm_seq_item);

    `uvm_object_param_utils(axi_mm_cov_sequence #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

    function new(string name = "axi_mm_cov_sequence");
        super.new(name);
    endfunction

    virtual task body();
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;

        repeat (100) begin
            tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("tr");

            if (!tr.randomize()) begin
                `uvm_error("COV_SEQ", "Randomization failed")
            end

            start_item(tr);
            finish_item(tr);
        end
    endtask

endclass
