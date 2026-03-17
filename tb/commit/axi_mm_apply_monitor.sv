// File: tb/commit/axi_mm_apply_monitor.sv
`ifndef AXI_MM_APPLY_MONITOR_SV
`define AXI_MM_APPLY_MONITOR_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

class axi_mm_apply_monitor #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4,
    int BEAT_IDX_W = 8
) extends uvm_component;

    `uvm_component_param_utils(axi_mm_apply_monitor#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, BEAT_IDX_W))

    typedef axi_mm_apply_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, BEAT_IDX_W) apply_t;

    virtual axi_mm_apply_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, BEAT_IDX_W).mp_monitor vif;

    uvm_analysis_port #(apply_t) ap;

    bit          drive_ready_always   = 1;
    bit          stress_enable        = 0;
    int unsigned ready_prob           = 100;
    int unsigned force_ready_after    = 64;
    int unsigned ready_holdoff_cycles = 0;

    function automatic bit roll_prob(int unsigned prob_0_to_100);
        if (prob_0_to_100 >= 100) return 1;
        if (prob_0_to_100 == 0)   return 0;
        return ($urandom_range(0,99) < prob_0_to_100);
    endfunction

    function automatic bit compute_ready_next(int unsigned cyc_since_reset);
        bit r;

        if (drive_ready_always) begin
            r = 1'b1;
        end
        else begin
            if (cyc_since_reset <= ready_holdoff_cycles) begin
                r = 1'b0;
            end
            else if (!stress_enable) begin
                r = 1'b1;
            end
            else begin
                if (cyc_since_reset >= force_ready_after) r = 1'b1;
                else                                      r = roll_prob(ready_prob);
            end
        end

        return r;
    endfunction

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------
    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    // ------------------------------------------------------------
    // Build phase
    // ------------------------------------------------------------
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(virtual axi_mm_apply_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, BEAT_IDX_W).mp_monitor)::get(this, "", "vif", vif)) begin
            `uvm_fatal("APPLY_MON", "No virtual interface set for apply_monitor")
        end

        void'(uvm_config_db#(bit         )::get(this, "", "drive_ready_always",   drive_ready_always));
        void'(uvm_config_db#(bit         )::get(this, "", "stress_enable",        stress_enable));
        void'(uvm_config_db#(int unsigned)::get(this, "", "ready_prob",           ready_prob));
        void'(uvm_config_db#(int unsigned)::get(this, "", "force_ready_after",    force_ready_after));
        void'(uvm_config_db#(int unsigned)::get(this, "", "ready_holdoff_cycles", ready_holdoff_cycles));

        if (ready_prob > 100) ready_prob = 100;
    endfunction

    // ------------------------------------------------------------
    // Run phase
    // ------------------------------------------------------------
    task run_phase(uvm_phase phase);
        apply_t it;

        int unsigned cyc_since_reset;
        bit ready_cur;
        bit ready_next;

        cyc_since_reset = 0;

        `uvm_info("APPLY_MON", "Apply monitor started", UVM_LOW)

        ready_cur = (drive_ready_always ? 1'b1 : 1'b0);
        vif.cb_monitor.ready <= ready_cur;

        forever begin
            @(vif.cb_monitor);

            if (!vif.cb_monitor.rst_n) begin
                cyc_since_reset = 0;
                ready_cur  = 1'b0;
                ready_next = 1'b0;
                vif.cb_monitor.ready <= 1'b0;
                continue;
            end

            if (vif.cb_monitor.valid && ready_cur) begin
                it = apply_t::type_id::create("it");

                it.apply_time = $time;
                it.port       = vif.cb_monitor.port;
                it.id         = vif.cb_monitor.id;
                it.beat_idx   = vif.cb_monitor.beat_idx;
                it.byte_addr  = vif.cb_monitor.byte_addr;
                it.wdata      = vif.cb_monitor.wdata;
                it.wstrb      = vif.cb_monitor.wstrb;
                it.size       = vif.cb_monitor.size;
                it.last       = vif.cb_monitor.last;

                ap.write(it);

                `uvm_info("APPLY_MON", it.convert2string(), UVM_HIGH)
            end

            cyc_since_reset++;
            ready_next = compute_ready_next(cyc_since_reset);

            vif.cb_monitor.ready <= ready_next;
            ready_cur = ready_next;
        end
    endtask

endclass : axi_mm_apply_monitor

`endif