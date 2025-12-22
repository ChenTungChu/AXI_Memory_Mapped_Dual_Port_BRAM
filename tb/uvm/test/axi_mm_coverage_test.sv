//---------------------------------------------------------------------
// axi_mm_coverage_test.sv
// Coverage-driven test (factory-safe, no parameterized test)
//---------------------------------------------------------------------
`ifndef AXI_MM_COVERAGE_TEST_SV
`define AXI_MM_COVERAGE_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

class axi_mm_coverage_test extends uvm_test;

    `uvm_component_utils(axi_mm_coverage_test)

    // ------------------------------------------------------------
    // Fixed parameters (DO NOT parameterize the test itself)
    // ------------------------------------------------------------
    localparam int ADDR_WIDTH = 32;
    localparam int DATA_WIDTH = 64;
    localparam int ID_WIDTH   = 4;

    // ------------------------------------------------------------
    // Environment
    // ------------------------------------------------------------
    axi_mm_env #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) env_h;

    // ------------------------------------------------------------
    // Coverage control
    // ------------------------------------------------------------
    real         coverage_goal = 90.0;   // percent
    int unsigned max_loops     = 1000;   // safety limit

    function new(string name = "axi_mm_coverage_test",
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
    // Run phase
    // ------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);

        axi_mm_cov_sequence #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) cov_seq;
        axi_mm_cov_scoreboard cov_scb;

        real cov;
        int  loop_cnt = 0;

        phase.raise_objection(this);

        `uvm_info("COV_TEST",
                  "Starting coverage-driven AXI-MM test",
                  UVM_MEDIUM)

        // --------------------------------------------------------
        // Get coverage scoreboard from environment
        // --------------------------------------------------------
        cov_scb = env_h.get_cov_scoreboard();

        if (cov_scb == null) begin
            `uvm_fatal("COV_TEST",
                       "Coverage scoreboard handle is null")
        end

        // --------------------------------------------------------
        // Main coverage loop
        // --------------------------------------------------------
        do begin

            uvm_sequencer_base seqr_base;

            cov_seq = axi_mm_cov_sequence#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("cov_seq");

            // seqr_base = env_h.p0_agent.seqr;   UVM1.1d does not support?
            cov_seq.start(uvm_sequencer_base'(env_h.p0_agent.seqr));

            cov = cov_scb.get_coverage();
            loop_cnt++;

            `uvm_info("COV_TEST", $sformatf("Coverage = %.2f%% (iteration %0d)", cov, loop_cnt), UVM_LOW)

            if (loop_cnt >= max_loops) begin
                `uvm_warning("COV_TEST", "Maximum iteration count reached")
                break;
            end

        end 
        
        while (cov < coverage_goal);

        `uvm_info("COV_TEST",$sformatf("Coverage test completed: %.2f%%", cov), UVM_MEDIUM)

        phase.drop_objection(this);
    endtask

endclass : axi_mm_coverage_test

`endif
