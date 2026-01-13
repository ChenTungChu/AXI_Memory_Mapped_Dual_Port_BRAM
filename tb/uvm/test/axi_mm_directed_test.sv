// File: tb/uvm/test/axi_mm_directed_test.sv
`ifndef AXI_MM_DIRECTED_TEST_SV
`define AXI_MM_DIRECTED_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

// ------------------------------------------------------------
// Directed AXI-MM test (factory-safe, non-parameterized)
// ------------------------------------------------------------
class axi_mm_directed_test extends uvm_test;

    `uvm_component_utils(axi_mm_directed_test)

    // ------------------------------------------------------------
    // Local parameters (fixed for factory)
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
    function new(string name = "axi_mm_directed_test", uvm_component parent = null);
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
    // Run phase: deterministic directed stimulus
    // ------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);

        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) seq;

        phase.raise_objection(this);

        `uvm_info("DIRECT_TEST", "Starting AXI-MM directed RAM test (case 0: single-beat RAW)", UVM_MEDIUM)

        // --------------------------------------------------------
        // Case 0: single-beat WRITE/READ
        // --------------------------------------------------------
        // Write
        seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("wr_seq");

        seq.directed_mode = 1;
        seq.dir_rw        = AXI_WRITE;
        seq.dir_addr      = 32'h0000_0100;
        seq.dir_wdata     = 64'hDEAD_BEEF_1234_5678;
        seq.dir_beats     = 1;
        seq.dir_id        = 0;

        seq.start(env_h.p0_agent.seqr);

        // Read
        seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("rd_seq");

        seq.directed_mode = 1;
        seq.dir_rw        = AXI_READ;
        seq.dir_addr      = 32'h0000_0100;
        seq.dir_beats     = 1;
        seq.dir_id        = 1;

        seq.start(env_h.p0_agent.seqr);

        `uvm_info("DIRECT_TEST", "Directed RAM test case 0 completed", UVM_MEDIUM)

        // ========================================================
        // Case 1: multi-beat INCR burst write/read
        // ========================================================
        `uvm_info("DIRECT_TEST", "Case 1: INCR burst write/read", UVM_MEDIUM)

        // Write burst (4 beats)
        seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("wr_seq_case1");

        seq.directed_mode = 1;
        seq.dir_rw        = AXI_WRITE;
        seq.dir_addr      = 32'h0000_0200;
        seq.dir_beats     = 4;          // burst = 4 beats
        seq.dir_id        = 2;

        seq.start(env_h.p0_agent.seqr);

        // Read burst (4 beats)
        seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("rd_seq_case1");

        seq.directed_mode = 1;
        seq.dir_rw        = AXI_READ;
        seq.dir_addr      = 32'h0000_0200;
        seq.dir_beats     = 4;
        seq.dir_id        = 3;

        seq.start(env_h.p0_agent.seqr);    

       `uvm_info("DIRECT_TEST", "Directed RAM test case 1 completed", UVM_MEDIUM)

        phase.drop_objection(this);
    endtask

endclass : axi_mm_directed_test

`endif
