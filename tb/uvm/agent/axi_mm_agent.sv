// File: tb/uvm/axi_mm_agent.sv
`ifndef AXI_MM_AGENT_SV
`define AXI_MM_AGENT_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

class axi_mm_agent #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4,
    bit HAS_BURST  = 1
) extends uvm_agent;

    `uvm_component_param_utils(axi_mm_agent #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST))

    // Sub-components
    axi_mm_sequencer #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) seqr;
    axi_mm_driver    #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) drv;
    axi_mm_monitor   #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) mon;

    // Split vifs by modport type (IMPORTANT)
    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_master  vif_m;
    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_monitor vif_mon;

    uvm_active_passive_enum is_active = UVM_ACTIVE;

    // Export monitor transactions
    uvm_analysis_port #(axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)) ap;

    function new(string name="axi_mm_agent", uvm_component parent=null);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Get ACTIVE/PASSIVE config (optional)
        void'(uvm_config_db#(uvm_active_passive_enum)::get(this, "", "is_active", is_active));

        // ------------------------------------------------------------
        // Get monitor vif (REQUIRED)
        // Key priority:
        //  1) "vif_mon" (new split-vif style)
        //  2) fallback to "vif" (old single-key style)
        // ------------------------------------------------------------
        if (!uvm_config_db#(
                virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_monitor
            )::get(this, "", "vif_mon", vif_mon))
        begin
            if (!uvm_config_db#(
                    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_monitor
                )::get(this, "", "vif", vif_mon))
            begin
                `uvm_fatal("NOVIF",
                    $sformatf("virtual interface mp_monitor must be set for axi_mm_agent (keys tried: vif_mon, vif). agent=%s",
                              get_full_name()))
            end
        end

        // ------------------------------------------------------------
        // Get master vif (REQUIRED only if ACTIVE)
        // Key priority:
        //  1) "vif_m"
        //  2) fallback to "vif"
        // ------------------------------------------------------------
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
                        $sformatf("virtual interface mp_master must be set for ACTIVE axi_mm_agent (keys tried: vif_m, vif). agent=%s",
                                  get_full_name()))
                end
            end
        end

        `uvm_info("AGENT",
            $sformatf("Building agent '%s' (%s)",
                      get_full_name(),
                      (is_active == UVM_ACTIVE) ? "ACTIVE" : "PASSIVE"),
            UVM_LOW)

        // ---------------- Monitor ----------------
        mon = axi_mm_monitor#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("mon", this);

        // Be robust: set BOTH keys so monitor code can use either.
        uvm_config_db#(
            virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_monitor
        )::set(this, "mon", "vif", vif_mon);

        uvm_config_db#(
            virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_monitor
        )::set(this, "mon", "vif_mon", vif_mon);

        // ---------------- Driver + Sequencer (ACTIVE only) ----------------
        if (is_active == UVM_ACTIVE) begin
            seqr = axi_mm_sequencer#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("seqr", this);
            drv  = axi_mm_driver   #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("drv",  this);

            // Be robust: set BOTH keys so driver code can use either.
            uvm_config_db#(
                virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_master
            )::set(this, "drv", "vif", vif_m);

            uvm_config_db#(
                virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, HAS_BURST).mp_master
            )::set(this, "drv", "vif_m", vif_m);
        end
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        if (is_active == UVM_ACTIVE) begin
            drv.seq_item_port.connect(seqr.seq_item_export);
        end

        if (mon != null) begin
            mon.ap.connect(ap);
        end
    endfunction

endclass

`endif
