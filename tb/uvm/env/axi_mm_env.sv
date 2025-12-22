// File: tb/uvm/axi_mm_env.sv

`ifndef AXI_MM_ENV_SV
`define AXI_MM_ENV_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

class axi_mm_env #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4,
    int DEPTH_WORDS = 1024
) extends uvm_env;

    `uvm_component_utils(axi_mm_env #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS))

    // ------------------------------------------------------------
    // Agents
    // ------------------------------------------------------------
    axi_mm_agent #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_agent;  
    axi_mm_agent #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_agent;

    // ------------------------------------------------------------
    // Scoreboards
    // ------------------------------------------------------------
    axi_mm_scoreboard #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS) scb;
    axi_mm_cov_scoreboard cov_scoreboard_h;

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------
    function new(string name = "axi_mm_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // ------------------------------------------------------------
    // Build phase: create components
    // ------------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Create agents
        p0_agent = axi_mm_agent#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_agent", this);
        p1_agent = axi_mm_agent#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_agent", this);

        // Create scoreboard
        scb = axi_mm_scoreboard#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS)::type_id::create("scb", this);

        // Create coverage scoreboard
        cov_scoreboard_h = axi_mm_cov_scoreboard::type_id::create("cov_scoreboard_h", this);
    endfunction

    // ------------------------------------------------------------
    // Connect phase: hook monitors → scoreboard
    // ------------------------------------------------------------
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // Connect monitors to scoreboard
        p0_agent.mon.ap.connect(scb.ap_export_p0);
        p1_agent.mon.ap.connect(scb.ap_export_p1);

        // Connect monitors to coverage scoreboard
        p0_agent.mon.ap.connect(cov_scoreboard_h.analysis_export);
        p1_agent.mon.ap.connect(cov_scoreboard_h.analysis_export);

        `uvm_info("ENV", "axi_mm_env connected monitors to scoreboard", UVM_LOW)
    endfunction

    // ------------------------------------------------------------
    // Getter for coverage scoreboard
    // ------------------------------------------------------------
    function axi_mm_cov_scoreboard get_cov_scoreboard();
        return cov_scoreboard_h;
    endfunction

endclass : axi_mm_env

`endif
