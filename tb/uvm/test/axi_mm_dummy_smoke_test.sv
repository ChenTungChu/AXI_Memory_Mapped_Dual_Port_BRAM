//------------------------------------------------------------------------------
// File: axi_mm_dummy_smoke_test.sv
// Description:
//   Minimal AXI-MM protocol smoke test using dummy slave
//   Purpose: verify AXI handshake correctness (no timeout)
//------------------------------------------------------------------------------

`ifndef AXI_MM_DUMMY_SMOKE_TEST_SV
`define AXI_MM_DUMMY_SMOKE_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

//------------------------------------------------------------
// AXI-MM Dummy Smoke Test
//------------------------------------------------------------
class axi_mm_dummy_smoke_test extends uvm_test;

    `uvm_component_utils(axi_mm_dummy_smoke_test)

    //------------------------------------------------------------
    // Environment handle (parameterized)
    //------------------------------------------------------------
    axi_mm_env#(32,64,4) env_h;

    //------------------------------------------------------------
    // Constructor
    //------------------------------------------------------------
    function new(string name = "axi_mm_dummy_smoke_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    //------------------------------------------------------------
    // Build phase
    //------------------------------------------------------------
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        `uvm_info("DUMMY_SMOKE",
                  "Building AXI-MM dummy smoke test",
                  UVM_LOW)

        env_h = axi_mm_env#(32,64,4)::type_id::create("env_h", this);
    endfunction

    //------------------------------------------------------------
    // Run phase
    //------------------------------------------------------------
    task run_phase(uvm_phase phase);
        axi_mm_seq#(32,64,4) seq;

        phase.raise_objection(this);

        `uvm_info("DUMMY_SMOKE",
                  "Starting AXI-MM dummy slave protocol smoke test",
                  UVM_LOW)

        //--------------------------------------------------------
        // Create sequence
        //--------------------------------------------------------
        seq = axi_mm_seq#(32,64,4)::type_id::create("seq");

        //--------------------------------------------------------
        // Minimal, deterministic configuration
        //--------------------------------------------------------
        seq.num       = 1;     // only one transaction
        seq.max_beats = 1;     // single beat (len=0)
        // seq.read_pct  = 100;   // READ only (simplest path)
        seq.read_pct = 50;   // 若要同時驗 write 可改

        //--------------------------------------------------------
        // Start sequence on master sequencer (port 0)
        //--------------------------------------------------------
        seq.start(env_h.p0_agent.seqr);

        `uvm_info("DUMMY_SMOKE",
                  "AXI-MM dummy smoke sequence finished",
                  UVM_LOW)

        phase.drop_objection(this);
    endtask

endclass : axi_mm_dummy_smoke_test

`endif
