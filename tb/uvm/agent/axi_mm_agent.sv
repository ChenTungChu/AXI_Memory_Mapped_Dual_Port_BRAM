// File: tb/uvm/axi_mm_agent.sv
`ifndef AXI_MM_AGENT_SV
`define AXI_MM_AGENT_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

// 若你的 axi_mm_seq_item / enum / if 都在 axi_mm_pkg，保留這行；
// 若不是在 package 裡，這行也不會傷害（只要 package 存在）。
import axi_mm_pkg::*;

class axi_mm_agent #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4,
    bit HAS_BURST  = 1
) extends uvm_agent;

    `uvm_component_param_utils(axi_mm_agent #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST))

    // ------------------------------------------------------------
    // Sub-components
    // ------------------------------------------------------------
    axi_mm_sequencer #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) seqr;
    axi_mm_driver    #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) drv;
    axi_mm_monitor   #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) mon;

    // ------------------------------------------------------------
    // Virtual interfaces (split modports)
    // ------------------------------------------------------------
    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_master  vif_m;
    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_monitor vif_mon;

    // ------------------------------------------------------------
    // Analysis port (agent-level re-export)
    // env: p0_agent.ap.connect(scb.ap_imp_p0)  (合法)
    // ------------------------------------------------------------
    uvm_analysis_port #(axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)) ap;

    function new(string name="axi_mm_agent", uvm_component parent=null);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    // ------------------------------------------------------------
    // Build phase
    // ------------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // ACTIVE / PASSIVE (allow config override)
        void'(uvm_config_db#(uvm_active_passive_enum)::get(this, "", "is_active", is_active));

        `uvm_info("AGENT",
            $sformatf("Building agent '%s' (%s)",
                      get_full_name(),
                      (is_active == UVM_ACTIVE) ? "ACTIVE" : "PASSIVE"),
            UVM_LOW)

        // --------------------------------------------------------
        // Get monitor vif (REQUIRED always)
        // Keys tried: vif_mon (preferred), vif (legacy)
        // --------------------------------------------------------
        if (!uvm_config_db#(
                virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_monitor
            )::get(this, "", "vif_mon", vif_mon))
        begin
            if (!uvm_config_db#(
                    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_monitor
                )::get(this, "", "vif", vif_mon))
            begin
                `uvm_fatal("NOVIF",
                    $sformatf("mp_monitor vif not set (keys tried: vif_mon, vif). agent=%s",
                              get_full_name()))
            end
        end

        // --------------------------------------------------------
        // Get master vif (REQUIRED if ACTIVE)
        // Keys tried: vif_m (preferred), vif (legacy)
        // --------------------------------------------------------
        if (is_active == UVM_ACTIVE) begin
            if (!uvm_config_db#(
                    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_master
                )::get(this, "", "vif_m", vif_m))
            begin
                if (!uvm_config_db#(
                        virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_master
                    )::get(this, "", "vif", vif_m))
                begin
                    `uvm_fatal("NOVIF",
                        $sformatf("mp_master vif not set (keys tried: vif_m, vif). agent=%s",
                                  get_full_name()))
                end
            end
        end

        // --------------------------------------------------------
        // IMPORTANT: set config_db BEFORE creating children
        // --------------------------------------------------------

        // Monitor always present
        uvm_config_db#(
            virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_monitor
        )::set(this, "mon", "vif_mon", vif_mon);

        // legacy fallback key (your monitor build_phase tries vif_mon then vif)
        uvm_config_db#(
            virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_monitor
        )::set(this, "mon", "vif", vif_mon);

        mon = axi_mm_monitor#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("mon", this);

        // Driver + Sequencer (ACTIVE only)
        if (is_active == UVM_ACTIVE) begin
            // set before create drv
            uvm_config_db#(
                virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_master
            )::set(this, "drv", "vif_m", vif_m);

            // legacy fallback key (driver 常見用 vif)
            uvm_config_db#(
                virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_master
            )::set(this, "drv", "vif", vif_m);

            seqr = axi_mm_sequencer#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("seqr", this);
            drv  = axi_mm_driver   #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("drv",  this);
        end
    endfunction

    // ------------------------------------------------------------
    // Connect phase
    // ------------------------------------------------------------
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        if (mon == null)
            `uvm_fatal("AGENT", $sformatf("mon is null in connect_phase (%s)", get_full_name()))

        if (is_active == UVM_ACTIVE) begin
            if (drv == null || seqr == null)
                `uvm_fatal("AGENT", $sformatf("drv/seqr is null in ACTIVE agent (%s)", get_full_name()))
            drv.seq_item_port.connect(seqr.seq_item_export);
        end

        // re-export monitor analysis
        mon.ap.connect(ap);
    endfunction

endclass : axi_mm_agent

`endif