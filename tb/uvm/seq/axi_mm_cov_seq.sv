// File: tb/uvm/seq/axi_mm_cov_seq.sv
`ifndef AXI_MM_COV_SEQ_SV
`define AXI_MM_COV_SEQ_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

class axi_mm_cov_seq #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4
) extends uvm_sequence #(axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH));

    `uvm_object_param_utils(axi_mm_cov_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

    // Number of transactions to generate
    rand int unsigned num_transactions = 200;

    constraint c_num_tx {
        num_transactions inside {[50:2000]};  // reasonable range
    }

    function new(string name="axi_mm_cov_seq");
        super.new(name);
    endfunction

    // ------------------------------------------------------------
    // Body: generate high-volume randomized AXI MM traffic
    // ------------------------------------------------------------
    virtual task body();
        // Task-local variables (declare at top)
        axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) req;
        int i;

        `uvm_info(get_type_name(), $sformatf("Starting coverage sequence: %0d transactions", num_transactions), UVM_MEDIUM)

        for (i = 0; i < num_transactions; i++) begin
            // Create new item
            req = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create($sformatf("req_%0d", i));

            start_item(req);

            // Constrain burst_len and addr to model RAM size (optional)
            if (!req.randomize() with {
                do_write dist {1 := 50, 0 := 50};        // read/write 50:50
                addr % 4 == 0;                            // 4-byte aligned
                burst_len inside {[1:16]};                // burst length
                addr + burst_len * (DATA_WIDTH/8) < (1<<ADDR_WIDTH);
            }) begin
                `uvm_fatal(get_type_name(), "Randomization failed! Check constraints.")
            end

            finish_item(req);

            // Optional: occasional cycle delay
            if ($urandom_range(0,5) == 0)
                #(1);
        end

        `uvm_info(get_type_name(), "Coverage sequence completed!", UVM_MEDIUM)
    endtask

endclass

`endif
