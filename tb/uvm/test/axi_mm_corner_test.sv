// File: tb/uvm/test/axi_mm_corner_test.sv
`ifndef AXI_MM_CORNER_TEST_SV
`define AXI_MM_CORNER_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

// ------------------------------------------------------------
// Corner Test (non-parameterized, factory-safe)
// ------------------------------------------------------------
class axi_mm_corner_test extends uvm_test;

    `uvm_component_utils(axi_mm_corner_test)

    // ------------------------------------------------------------
    // Local parameters (fixed at test level)
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
    function new(string name = "axi_mm_corner_test", uvm_component parent = null);
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
    // Run phase: corner-case traffic
    // ------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);

        axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr_max_burst;
        axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr_unaligned;
        axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr_fixed;
        int b;

        phase.raise_objection(this);

        `uvm_info("CORNER_TEST",
                  "Starting AXI-MM corner-case transaction test",
                  UVM_MEDIUM)

        // --------------------------------------------------------
        // Corner-case 1: maximum burst length (INCR)
        // --------------------------------------------------------
        tr_max_burst =
            axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create(
                "tr_max_burst"
            );

        tr_max_burst.rw    = AXI_WRITE;
        tr_max_burst.addr  = 32'h0;
        tr_max_burst.len   = 15; // 16 beats
        tr_max_burst.size  = $clog2(DATA_WIDTH/8);
        tr_max_burst.burst = 2'b01; // INCR
        tr_max_burst.id    = 0;

        tr_max_burst.data_beats  = new[tr_max_burst.len + 1];
        tr_max_burst.wstrb_beats = new[tr_max_burst.len + 1];

        for (b = 0; b <= tr_max_burst.len; b++) begin
            tr_max_burst.data_beats[b]  = 'hA5A5A5A5A5A5A5A5;
            tr_max_burst.wstrb_beats[b] = {DATA_WIDTH/8{1'b1}};
        end

        tr_max_burst.start_item(env_h.p0_agent.seqr);
        tr_max_burst.finish_item(env_h.p0_agent.seqr);

        // --------------------------------------------------------
        // Corner-case 2: unaligned address write
        // --------------------------------------------------------
        tr_unaligned =
            axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create(
                "tr_unaligned"
            );

        tr_unaligned.rw    = AXI_WRITE;
        tr_unaligned.addr  = 32'h3; // intentionally unaligned
        tr_unaligned.len   = 3;
        tr_unaligned.size  = 2;     // 4 bytes
        tr_unaligned.burst = 2'b01; // INCR
        tr_unaligned.id    = 1;

        tr_unaligned.data_beats  = new[tr_unaligned.len + 1];
        tr_unaligned.wstrb_beats = new[tr_unaligned.len + 1];

        for (b = 0; b <= tr_unaligned.len; b++) begin
            tr_unaligned.data_beats[b]  = $urandom;
            tr_unaligned.wstrb_beats[b] = $urandom;
        end

        tr_unaligned.start_item(env_h.p0_agent.seqr);
        tr_unaligned.finish_item(env_h.p0_agent.seqr);

        // --------------------------------------------------------
        // Corner-case 3: FIXED burst (address does not increment)
        // --------------------------------------------------------
        tr_fixed =
            axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create(
                "tr_fixed"
            );

        tr_fixed.rw    = AXI_WRITE;
        tr_fixed.addr  = 32'h10;
        tr_fixed.len   = 3;
        tr_fixed.size  = 2;
        tr_fixed.burst = 2'b00; // FIXED
        tr_fixed.id    = 2;

        tr_fixed.data_beats  = new[tr_fixed.len + 1];
        tr_fixed.wstrb_beats = new[tr_fixed.len + 1];

        for (b = 0; b <= tr_fixed.len; b++) begin
            tr_fixed.data_beats[b]  = $urandom;
            tr_fixed.wstrb_beats[b] = $urandom;
        end

        tr_fixed.start_item(env_h.p0_agent.seqr);
        tr_fixed.finish_item(env_h.p0_agent.seqr);

        `uvm_info("CORNER_TEST",
                  "Corner-case transaction test completed",
                  UVM_MEDIUM)

        phase.drop_objection(this);
    endtask

endclass : axi_mm_corner_test

`endif
