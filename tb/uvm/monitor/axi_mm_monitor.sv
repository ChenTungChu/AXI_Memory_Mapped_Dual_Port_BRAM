`ifndef AXI_MM_MONITOR_SV
`define AXI_MM_MONITOR_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

class axi_mm_monitor #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4
) extends uvm_component;

    // ------------------------------------------------------------
    // Virtual Interface (FULL IF, but we only READ signals)
    // ------------------------------------------------------------
    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) vif;

    // ------------------------------------------------------------
    // Analysis Port
    // ------------------------------------------------------------
    uvm_analysis_port #(
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)
    ) ap;

    `uvm_component_param_utils(
        axi_mm_monitor #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)
    )

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    // ------------------------------------------------------------
    // Build phase
    // ------------------------------------------------------------
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(
                virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)
            )::get(this, "", "vif", vif)) begin
            `uvm_fatal("NOVIF", "axi_mm_monitor: virtual interface not set")
        end
    endfunction

    // ------------------------------------------------------------
    // Run phase
    // ------------------------------------------------------------
    task run_phase(uvm_phase phase);
        `uvm_info("MON", "AXI-MM Monitor started", UVM_LOW)

        // Wait reset deasserted (sample via clock only)
        @(posedge vif.clk);
        while (vif.rst_n !== 1'b1)
            @(posedge vif.clk);

        fork
            monitor_write();
            monitor_read();
        join_none
    endtask

    // ============================================================
    // Write monitor (AW + W + B)
    // ============================================================
    task monitor_write();
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
        int beats, i;

        forever begin
            @(posedge vif.clk);

            if (vif.awvalid && vif.awready) begin
                tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)
                        ::type_id::create("wr_tr", this);

                tr.rw    = AXI_WRITE;
                tr.addr  = vif.awaddr;
                tr.id    = vif.awid;
                tr.len   = vif.awlen;
                tr.size  = vif.awsize;
                tr.burst = vif.awburst;

                beats = tr.len + 1;
                tr.set_beats_len(tr.len);

                // ---------------- W channel ----------------
                i = 0;
                while (i < beats) begin
                    @(posedge vif.clk);
                    if (vif.wvalid && vif.wready) begin
                        tr.data_beats[i]  = vif.wdata;
                        tr.wstrb_beats[i] = vif.wstrb;
                        i++;
                    end
                end

                // ---------------- B channel ----------------
                do @(posedge vif.clk);
                while (!(vif.bvalid && vif.bready));

                tr.bresp = vif.bresp;

                ap.write(tr);
            end
        end
    endtask

    // ============================================================
    // Read monitor (AR + R)
    // ============================================================
    task monitor_read();
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
        int beats, i;

        forever begin
            @(posedge vif.clk);

            if (vif.arvalid && vif.arready) begin
                tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)
                        ::type_id::create("rd_tr", this);

                tr.rw    = AXI_READ;
                tr.addr  = vif.araddr;
                tr.id    = vif.arid;
                tr.len   = vif.arlen;
                tr.size  = vif.arsize;
                tr.burst = vif.arburst;

                beats = tr.len + 1;
                tr.set_beats_len(tr.len);

                i = 0;
                while (i < beats) begin
                    @(posedge vif.clk);
                    if (vif.rvalid && vif.rready) begin
                        tr.rdata_beats[i] = vif.rdata;
                        tr.rresp_beats[i] = vif.rresp;
                        i++;
                    end
                end

                ap.write(tr);
            end
        end
    endtask

endclass

`endif
