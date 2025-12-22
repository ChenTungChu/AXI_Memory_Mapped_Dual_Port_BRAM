// File: tb/uvm/test/axi_mm_smoke_test.sv
`ifndef AXI_MM_SMOKE_TEST_SV
`define AXI_MM_SMOKE_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

// ------------------------------------------------------------
// NOTE:
//  - Test is NOT parameterized (UVM factory requirement)
//  - Parameters are fixed here and passed to env / seq_item
// ------------------------------------------------------------
class axi_mm_smoke_test extends uvm_test;

    `uvm_component_utils(axi_mm_smoke_test)

    // ------------------------------------------------------------
    // Local parameters (test-level constants)
    // ------------------------------------------------------------
    localparam int ADDR_WIDTH = 32;
    localparam int DATA_WIDTH = 64;
    localparam int ID_WIDTH   = 4;

    // ------------------------------------------------------------
    // Environment handle
    // ------------------------------------------------------------
    axi_mm_env #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) env_h;

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------
    function new(string name = "axi_mm_smoke_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // ------------------------------------------------------------
    // Build phase
    // ------------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env_h = axi_mm_env#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("env_h", this);
    endfunction

    // ------------------------------------------------------------
    // Run phase: simple smoke test
    // ------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);

        //--------------------------------------------------------
        // 1. Declare sequence
        //--------------------------------------------------------
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) seq;

        phase.raise_objection(this);

        `uvm_info("SMOKE_TEST", "Starting AXI-MM Smoke Test", UVM_LOW)

        // --------------------------------------------------------
        // 2. Instantiate sequence
        // --------------------------------------------------------

        seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("seq");

        // --------------------------------------------------------
        // 3. Setup sequence parameters
        // --------------------------------------------------------
        seq.num_transactions = 4;  
        seq.max_beats        = 16;   
        seq.read_percent     = 50;  

        seq.start(env_h.p0_agent.seqr);

        // --------------------------------------------------------
        // 4. Report
        // --------------------------------------------------------
        `uvm_info("SMOKE_TEST", "Sequence Finished", UVM_LOW)

        phase.drop_objection(this);
    endtask

endclass : axi_mm_smoke_test

`endif
