// File: tb/commit/axi_mm_commit_monitor.sv
`ifndef AXI_MM_COMMIT_MONITOR_SV
`define AXI_MM_COMMIT_MONITOR_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

class axi_mm_commit_monitor #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4,
    int BEAT_IDX_W = 8
) extends uvm_component;

    `uvm_component_param_utils(axi_mm_commit_monitor#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, BEAT_IDX_W))

    // ------------------------------------------------------------
    // virtual interface (MODPORT)
    // ------------------------------------------------------------
    virtual axi_mm_commit_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, BEAT_IDX_W).mp_monitor vif;

    // analysis port -> scoreboard
    uvm_analysis_port #(axi_mm_commit_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, BEAT_IDX_W)) ap;

    // behavior knobs
    bit          drive_ready_always = 1;   // legacy: ready always 1 (no backpressure)

    // backpressure knobs
    bit          stress_enable      = 0;   // when 1, ready is controlled by probability
    int unsigned ready_prob         = 100; // 0..100 (only used when stress_enable=1)
    int unsigned force_ready_after  = 64;  // after N cycles, force ready=1 (safety)

    // Optional: initial holdoff
    int unsigned ready_holdoff_cycles = 0; // hold ready low for first N cycles after reset deassert

    // ------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------
    function automatic bit roll_prob(int unsigned prob_0_to_100);
        if (prob_0_to_100 >= 100) return 1;
        if (prob_0_to_100 == 0)   return 0;
        return ($urandom_range(0,99) < prob_0_to_100);
    endfunction

    // Compute the next value to drive on ready.
    function automatic bit compute_ready_next(int unsigned cyc_since_reset);
        bit r;

        if (drive_ready_always) begin
            r = 1'b1;
        end
        else begin
            // holdoff window (optional)
            if (cyc_since_reset <= ready_holdoff_cycles) begin
                r = 1'b0;
            end
            else if (!stress_enable) begin
                // if not stress, default to ready=1 (unless holdoff)
                r = 1'b1;
            end
            else begin
                // stress mode probability + safety escape
                if (cyc_since_reset >= force_ready_after) r = 1'b1;
                else                                      r = roll_prob(ready_prob);
            end
        end

        return r;
    endfunction

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(
                virtual axi_mm_commit_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, BEAT_IDX_W).mp_monitor
            )::get(this, "", "vif", vif)) begin
            `uvm_fatal("COMMIT_MON", "No virtual interface set for axi_mm_commit_monitor (config_db key: 'vif')")
        end

        void'(uvm_config_db#(bit         )::get(this, "", "drive_ready_always",    drive_ready_always));
        void'(uvm_config_db#(bit         )::get(this, "", "stress_enable",         stress_enable));
        void'(uvm_config_db#(int unsigned)::get(this, "", "ready_prob",            ready_prob));
        void'(uvm_config_db#(int unsigned)::get(this, "", "force_ready_after",     force_ready_after));
        void'(uvm_config_db#(int unsigned)::get(this, "", "ready_holdoff_cycles",  ready_holdoff_cycles));

        if (ready_prob > 100) ready_prob = 100;
    endfunction

    task run_phase(uvm_phase phase);
        axi_mm_commit_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, BEAT_IDX_W) it;

        int unsigned cyc_since_reset;

        // ready_cur = "current effective ready for this cycle"
        // ready_next = "what we will drive to take effect next cycle"
        bit ready_cur;
        bit ready_next;

        cyc_since_reset = 0;

        `uvm_info("COMMIT_MON", "Commit monitor started", UVM_LOW)

        // Drive an initial value before the first clocking event.
        // Also initialize ready_cur to match what will be effective at the first sample.
        ready_cur = (drive_ready_always ? 1'b1 : 1'b0);
        vif.cb_monitor.ready <= ready_cur;

        forever begin
            @(vif.cb_monitor);

            // During reset: keep ready low, reset counter
            if (!vif.cb_monitor.rst_n) begin
                cyc_since_reset = 0;
                ready_cur  = 1'b0;
                ready_next = 1'b0;
                vif.cb_monitor.ready <= 1'b0;
                continue;
            end

            // ------------------------------------------------------------
            // 1) Observe REAL handshake for THIS cycle using ready_cur
            //    (ready_cur is what was driven previously and is effective now)
            // ------------------------------------------------------------
            if (vif.cb_monitor.valid && ready_cur) begin
                it = axi_mm_commit_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, BEAT_IDX_W)::type_id::create("it");
                it.commit_time = $time;
                it.port        = vif.cb_monitor.port;
                it.id          = vif.cb_monitor.id;
                it.beat_idx    = vif.cb_monitor.beat_idx;
                it.byte_addr   = vif.cb_monitor.byte_addr;
                it.wdata       = vif.cb_monitor.wdata;
                it.wstrb       = vif.cb_monitor.wstrb;
                it.size        = vif.cb_monitor.size;
                it.last        = vif.cb_monitor.last;

                ap.write(it);

                `uvm_info("COMMIT_MON", it.convert2string(), UVM_HIGH)
            end

            // ------------------------------------------------------------
            // 2) Compute + drive next ready (effective next cycle)
            // ------------------------------------------------------------
            cyc_since_reset++;
            ready_next = compute_ready_next(cyc_since_reset);

            vif.cb_monitor.ready <= ready_next;

            // 3) Update ready_cur for next loop
            ready_cur = ready_next;
        end
    endtask

endclass : axi_mm_commit_monitor

`endif