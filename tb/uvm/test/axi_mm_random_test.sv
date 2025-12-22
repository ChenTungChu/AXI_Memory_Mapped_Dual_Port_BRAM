// File: tb/uvm/test/axi_mm_random_test.sv
`ifndef AXI_MM_RANDOM_TEST_SV
`define AXI_MM_RANDOM_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

// ------------------------------------------------------------
// NOTE:
//  - Test is NOT parameterized (UVM factory requirement)
//  - Parameters are fixed here and passed to env / seq_item
// ------------------------------------------------------------
class axi_mm_random_test extends uvm_test;

    `uvm_component_utils(axi_mm_random_test)

    // ------------------------------------------------------------
    // Local parameters
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
    function new(string name = "axi_mm_random_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // ------------------------------------------------------------
    // Build phase
    // ------------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env_h = axi_mm_env#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create(
            "env_h", this
        );
    endfunction

    // ------------------------------------------------------------
    // Run phase: random traffic
    // ------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);

        localparam int NUM_TX = 100;
        axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;

        phase.raise_objection(this);

        `uvm_info("RANDOM_TEST",
                  "Starting AXI-MM random transaction test",
                  UVM_MEDIUM)

        repeat (NUM_TX) begin
            tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("tr");

            // ----------------------------------------------------
            // Randomize with enum-safe constraints
            // ----------------------------------------------------
            if (!tr.randomize() with {
                rw inside {AXI_READ, AXI_WRITE};
                burst inside {2'b00, 2'b01}; // FIXED or INCR
                len inside {[0:7]};           // up to 8 beats
            }) begin
                `uvm_error("RANDOM_TEST", "Transaction randomization failed")
            end

            tr.start_item(env_h.p0_agent.seqr);
            tr.finish_item(env_h.p0_agent.seqr);

            #1ns;
        end

        `uvm_info("RANDOM_TEST",
                  "Random transaction test completed",
                  UVM_MEDIUM)

        phase.drop_objection(this);
    endtask

endclass : axi_mm_random_test

`endif
