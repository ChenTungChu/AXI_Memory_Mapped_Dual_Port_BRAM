// File: tb/uvm/axi/axi_mm_driver.sv
`ifndef AXI_MM_DRIVER_SV
`define AXI_MM_DRIVER_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

// -------------------------------------------------------------------------
// AXI-MM Driver
// Drives axi_mm_seq_item transactions onto axi_mm_if (master side)
// -------------------------------------------------------------------------

class axi_mm_driver #(
    int ADDR_WIDTH   = 32,
    int DATA_WIDTH   = 64,
    int ID_WIDTH     = 4,
    int WAIT_TIMEOUT = 1000    // clock cycles timeout
) extends uvm_driver#(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH));

    // ------------------------------------------------------------
    // Virtual interface (FULL interface, NOT modport)
    // ------------------------------------------------------------
    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) vif;

    `uvm_component_param_utils(
        axi_mm_driver #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, WAIT_TIMEOUT)
    )

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // ------------------------------------------------------------
    // Build phase: get virtual interface
    // ------------------------------------------------------------
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))::get(this, "", "vif", vif)) begin
            `uvm_fatal("NOVIF", "axi_mm_driver: virtual interface not set")
        end
    endfunction

    // ------------------------------------------------------------
    // Utility: wait for signal to reach expected value (clocking-safe)
    // ------------------------------------------------------------
    task automatic wait_sig(
        ref  logic sig,
        input logic expected_val,
        input int   timeout,
        input string err_msg
    );
        int cnt = 0;
        while (sig !== expected_val) begin
            if (cnt >= timeout) begin
                `uvm_error("DRV", err_msg)
                return;
            end
            @(vif.cb_master);
            cnt++;
        end
    endtask

    // ------------------------------------------------------------
    // Run phase
    // ------------------------------------------------------------
    task run_phase(uvm_phase phase);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;

        // Initialize interface signals
        init_signals();

        // Wait reset deassert (active low)
        if (!$isunknown(vif.rst_n)) begin
            wait (vif.rst_n === 1'b1);
        end

        @(vif.cb_master);

        forever begin
            seq_item_port.get_next_item(tr);

            `uvm_info("DRV", $sformatf("Driving %s addr=0x%0h len=%0d id=0x%0h", (tr.rw == AXI_WRITE) ? "WRITE" : "READ", tr.addr, tr.len, tr.id), UVM_HIGH)

            if (!check_beats(tr)) begin
                `uvm_error("DRV", "Beat array size mismatch, dropping transaction")
                seq_item_port.item_done();
                continue;
            end

            if (tr.rw == AXI_WRITE)
                drive_write(tr);
            else
                drive_read(tr);

            seq_item_port.item_done();
        end
    endtask

    // ------------------------------------------------------------
    // Initialize master signals
    // ------------------------------------------------------------
    task init_signals();
        vif.cb_master.awvalid <= 0;
        vif.cb_master.awaddr  <= '0;
        vif.cb_master.awlen   <= '0;
        vif.cb_master.awsize  <= '0;
        vif.cb_master.awburst <= '0;
        vif.cb_master.awid    <= '0;

        vif.cb_master.wvalid  <= 0;
        vif.cb_master.wdata   <= '0;
        vif.cb_master.wstrb   <= '0;
        vif.cb_master.wlast   <= 0;

        vif.cb_master.bready  <= 0;

        vif.cb_master.arvalid <= 0;
        vif.cb_master.araddr  <= '0;
        vif.cb_master.arlen   <= '0;
        vif.cb_master.arsize  <= '0;
        vif.cb_master.arburst <= '0;
        vif.cb_master.arid    <= '0;

        vif.cb_master.rready  <= 0;
    endtask

    // ------------------------------------------------------------
    // Check beat array sizes
    // ------------------------------------------------------------
    function bit check_beats(
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr
    );
        int unsigned beats = tr.len + 1;

        if (tr.rw == AXI_WRITE) begin
            if (tr.data_beats.size() != beats) begin
                `uvm_warning("DRV", "data_beats.size() != len+1")
                return 0;
            end
            if (tr.wstrb_beats.size() != beats) begin
                `uvm_warning("DRV", "wstrb_beats.size() != len+1")
                return 0;
            end
        end
        else begin
            if ((tr.rdata_beats.size() != 0) &&
                (tr.rdata_beats.size() != beats)) begin
                `uvm_warning("DRV", "rdata_beats pre-allocated but size mismatch")
            end
        end
        return 1;
    endfunction

    // ------------------------------------------------------------
    // Drive WRITE transaction
    // ------------------------------------------------------------
    task drive_write(
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr
    );
        int beats = tr.len + 1;
        int i;

        // ---------------- Default values ----------------
        vif.cb_master.awvalid <= 0;
        vif.cb_master.wvalid  <= 0;
        vif.cb_master.wlast   <= 0;
        vif.cb_master.bready  <= 0;

        fork
            // ---------------- AW channel ----------------
            begin : AW_CH
                @(vif.cb_master);
                vif.cb_master.awvalid <= 1;
                vif.cb_master.awaddr  <= tr.addr;
                vif.cb_master.awlen   <= tr.len;
                vif.cb_master.awsize  <= tr.size;
                vif.cb_master.awburst <= tr.burst;
                vif.cb_master.awid    <= tr.id;

                wait_sig(vif.cb_master.awready, 1'b1, WAIT_TIMEOUT, "Timeout waiting for AWREADY");

                @(vif.cb_master);
                vif.cb_master.awvalid <= 0;
            end

            // ---------------- W channel ----------------
            begin : W_CH
                i = 0;

                while (i < beats) begin
                    @(vif.cb_master);
                    vif.cb_master.wvalid <= 1;
                    vif.cb_master.wdata  <= tr.data_beats[i];
                    vif.cb_master.wstrb  <= tr.wstrb_beats[i];
                    vif.cb_master.wlast  <= (i == beats - 1);

                    // Advance beat only when handshake occurs
                    if (vif.cb_master.wready) begin
                        i++;
                    end
                end

                @(vif.cb_master);
                vif.cb_master.wvalid <= 0;
                vif.cb_master.wlast  <= 0;
            end
        join

        // ---------------- B channel ----------------
        @(vif.cb_master);
        vif.cb_master.bready <= 1;

        wait_sig(vif.cb_master.bvalid, 1'b1, WAIT_TIMEOUT, "Timeout waiting for BVALID");

        tr.bresp = vif.cb_master.bresp;

        @(vif.cb_master);
        vif.cb_master.bready <= 0;

        `uvm_info("DRV", $sformatf("WRITE done: BRESP=%0d", tr.bresp), UVM_LOW)
    endtask

    // ------------------------------------------------------------
    // Drive READ transaction
    // ------------------------------------------------------------
    task drive_read(
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr
    );
        int beats = tr.len + 1;
        int beat_cnt = 0;
        int timeout_cnt;

        // ---------------- AR channel ----------------
        @(vif.cb_master);
        vif.cb_master.arvalid <= 1;
        vif.cb_master.araddr  <= tr.addr;
        vif.cb_master.arlen   <= tr.len;
        vif.cb_master.arsize  <= tr.size;
        vif.cb_master.arburst <= tr.burst;
        vif.cb_master.arid    <= tr.id;

        // Wait for one beat to let DUT have the chance to see arvalid   
        @(vif.cb_master);

        // Wait for AR handshake
        timeout_cnt = 0;
        while (!vif.cb_master.arready) begin
            if (timeout_cnt >= WAIT_TIMEOUT) begin
        `       uvm_error("DRV", "Timeout waiting for ARREADY")
                vif.cb_master.arvalid <= 0;
                return;
            end
            @(vif.cb_master);
            timeout_cnt++;
        end

        // Deassert ARVALID after handshake
        @(vif.cb_master);
        vif.cb_master.arvalid <= 0;

        // ---------------- R channel ----------------
        vif.cb_master.rready <= 1;

        timeout_cnt = 0;
        beat_cnt    = 0;

        while (beat_cnt < beats) begin
            @(vif.cb_master);

            if (vif.cb_master.rvalid && vif.cb_master.rready) begin
                // Consume one R beat
                tr.rdata_beats[beat_cnt] = vif.cb_master.rdata;
                tr.rresp_beats[beat_cnt] = vif.cb_master.rresp;

                // RLAST checking
                if ((beat_cnt == beats - 1) && !vif.cb_master.rlast) begin
                    `uvm_error("DRV", "Expected RLAST on final read beat but got 0")
                end
                else if ((beat_cnt < beats - 1) && vif.cb_master.rlast) begin
                    `uvm_error("DRV", "Unexpected RLAST before final read beat")
                end

                beat_cnt++;
                timeout_cnt = 0; // reset timeout on progress
            end

            if (!vif.cb_master.rvalid) begin
                timeout_cnt++;
                if (timeout_cnt >= WAIT_TIMEOUT) begin
                    `uvm_error("DRV", "Timeout waiting for RVALID && RREADY")
                    break;
                end
            end
            else begin
                timeout_cnt = 0;
            end
        end

        vif.cb_master.rready <= 0;

        `uvm_info("DRV", $sformatf("READ done: beats=%0d first beat=0x%0h", beat_cnt, (tr.rdata_beats.size() > 0) ? tr.rdata_beats[0] : '0), UVM_LOW)
    endtask


endclass : axi_mm_driver

`endif
