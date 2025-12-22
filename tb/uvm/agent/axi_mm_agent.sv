// File: tb/uvm/axi_mm_agent.sv
`ifndef AXI_MM_AGENT_SV
`define AXI_MM_AGENT_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

class axi_mm_agent #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4
) extends uvm_agent;

    `uvm_component_param_utils(axi_mm_agent #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

    //-----------------------------------------
    // Sub-components
    //-----------------------------------------
    axi_mm_sequencer #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) seqr;
    axi_mm_driver    #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) drv;
    axi_mm_monitor   #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) mon;

    //-----------------------------------------
    // Virtual interface
    //-----------------------------------------
    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) vif;

    //-----------------------------------------
    // Agent mode: ACTIVE / PASSIVE
    //-----------------------------------------
    uvm_active_passive_enum is_active = UVM_ACTIVE;

    //-----------------------------------------
    // Export monitor transactions (to ENV/SCOREBOARD)
    //-----------------------------------------
    uvm_analysis_port #(axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)) ap;

    //-----------------------------------------
    // Constructor
    //-----------------------------------------
    function new(string name = "axi_mm_agent", uvm_component parent = null);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    //-----------------------------------------
    // Build phase
    //-----------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Get virtual interface
        if (!uvm_config_db#(virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))::get(
            this, "", "vif", vif))
        begin
            `uvm_fatal("NOVIF", "virtual interface must be set for axi_mm_agent")
        end

        // Get ACTIVE / PASSIVE configuration
        void'(uvm_config_db#(uvm_active_passive_enum)::get(
            this, "", "is_active", is_active));

        // Debug printing
        `uvm_info("AGENT",
                  $sformatf("Building agent '%s' (%s)",
                            get_full_name(),
                            (is_active == UVM_ACTIVE) ? "ACTIVE" : "PASSIVE"),
                  UVM_LOW)

        // Always create monitor
        mon = axi_mm_monitor#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("mon", this);
        uvm_config_db#(virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))::set(
            this, "mon", "vif", vif);

        // If ACTIVE, also create driver + sequencer
        if (is_active == UVM_ACTIVE) begin
            seqr = axi_mm_sequencer#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("seqr", this);
            drv  = axi_mm_driver   #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("drv",  this);

            // Pass interface to driver
            uvm_config_db#(virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))::set(
                this, "drv", "vif", vif);
        end
    endfunction

    //-----------------------------------------
    // Connect phase
    //-----------------------------------------
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // Driver <-> sequencer connection (ACTIVE only)
        if (is_active == UVM_ACTIVE) begin
            drv.seq_item_port.connect(seqr.seq_item_export);
        end

        // Connect monitor's analysis port → agent's analysis port
        if (mon != null)
            mon.ap.connect(ap);
    endfunction

endclass

`endif
