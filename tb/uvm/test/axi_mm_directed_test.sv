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
    function new(string name = "axi_mm_directed_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // ------------------------------------------------------------
    // Build phase
    // ------------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env_h =
            axi_mm_env#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create(
                "env_h", this
            );
    endfunction

    // ------------------------------------------------------------
    // Run phase: deterministic directed stimulus
    // ------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);

        axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) wr_tr;
        axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) rd_tr;

        phase.raise_objection(this);

        `uvm_info("DIRECT_TEST",
                  "Starting AXI-MM directed RAM test",
                  UVM_MEDIUM)

        // --------------------------------------------------------
        // Test #1: single-beat write
        // --------------------------------------------------------
        wr_tr =
            axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create(
                "wr_tr"
            );

        wr_tr.rw    = AXI_WRITE;
        wr_tr.addr  = 32'h0000_0100;
        wr_tr.len   = 0; // single beat
        wr_tr.size  = $clog2(DATA_WIDTH/8);
        wr_tr.burst = 2'b01; // INCR
        wr_tr.id    = 0;

        wr_tr.data_beats  = new[1];
        wr_tr.wstrb_beats = new[1];

        wr_tr.data_beats[0]  = 64'hDEAD_BEEF_1234_5678;
        wr_tr.wstrb_beats[0] = {DATA_WIDTH/8{1'b1}};

        wr_tr.start_item(env_h.p0_agent.seqr);
        wr_tr.finish_item(env_h.p0_agent.seqr);

        // --------------------------------------------------------
        // Test #2: read-back same address
        // --------------------------------------------------------
        rd_tr =
            axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create(
                "rd_tr"
            );

        rd_tr.rw    = AXI_READ;
        rd_tr.addr  = wr_tr.addr;
        rd_tr.len   = 0;
        rd_tr.size  = wr_tr.size;
        rd_tr.burst = 2'b01;
        rd_tr.id    = 1;

        rd_tr.data_beats   = new[1]; // unused, but keep clean
        rd_tr.wstrb_beats  = new[1];
        rd_tr.rdata_beats  = new[1];

        rd_tr.start_item(env_h.p0_agent.seqr);
        rd_tr.finish_item(env_h.p0_agent.seqr);

        `uvm_info("DIRECT_TEST",
                  "Directed RAM test completed",
                  UVM_MEDIUM)

        phase.drop_objection(this);
    endtask

endclass : axi_mm_directed_test

`endif
