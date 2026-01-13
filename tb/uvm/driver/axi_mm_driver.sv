`ifndef AXI_MM_DRIVER_SV
`define AXI_MM_DRIVER_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

// -------------------------------------------------------------------------
// AXI-MM Driver (MASTER)
// -------------------------------------------------------------------------
class axi_mm_driver #(
    int ADDR_WIDTH   = 32,
    int DATA_WIDTH   = 64,
    int ID_WIDTH     = 4,
    int WAIT_TIMEOUT = 1000
) extends uvm_driver #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH));

    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) vif;

    `uvm_component_param_utils(axi_mm_driver #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, WAIT_TIMEOUT))

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // ------------------------------------------------------------
    // Build
    // ------------------------------------------------------------
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))::get(
                this, "", "vif", vif)) begin
            `uvm_fatal("NOVIF", "axi_mm_driver: virtual interface not set")
        end
    endfunction

    // ------------------------------------------------------------
    // Run
    // ------------------------------------------------------------
    task run_phase(uvm_phase phase);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;

        init_signals();

        // wait reset release
        wait (vif.rst_n === 1'b1);
        @(posedge vif.clk);

        forever begin
            seq_item_port.get_next_item(tr);

            `uvm_info("DRV",
                $sformatf("Driving %s addr=0x%0h len=%0d id=%0d",
                          (tr.rw == AXI_WRITE) ? "WRITE" : "READ",
                          tr.addr, tr.len, tr.id),
                UVM_LOW)

            if (!check_beats(tr)) begin
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
    // Init signals
    // ------------------------------------------------------------
    task init_signals();
        vif.awvalid <= 0;
        vif.wvalid  <= 0;
        vif.wlast   <= 0;
        vif.bready  <= 0;

        vif.arvalid <= 0;
        vif.rready  <= 0;
    endtask

    // ------------------------------------------------------------
    // Check beats
    // ------------------------------------------------------------
    function bit check_beats(
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr
    );
        int beats = tr.len + 1;
        if (tr.rw == AXI_WRITE) begin
            if (tr.data_beats.size()  != beats) return 0;
            if (tr.wstrb_beats.size() != beats) return 0;
        end
        return 1;
    endfunction


    // ============================================================
    // WRITE
    // ============================================================
    task drive_write(
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr
    );
        int beats = tr.len + 1;
        int i;

        // ---------------- AW ----------------
        vif.awvalid <= 1;
        vif.awaddr  <= tr.addr;
        vif.awlen   <= tr.len;
        vif.awsize  <= tr.size;
        vif.awburst <= tr.burst;
        vif.awid    <= tr.id;

        do @(posedge vif.clk);
        while (!vif.awready);
        @(posedge vif.clk);
        vif.awvalid <= 0;

        // ---------------- W ----------------
        for (i = 0; i < beats; i++) begin
            vif.wvalid <= 1;
            vif.wdata  <= tr.data_beats[i];
            vif.wstrb  <= tr.wstrb_beats[i];
            vif.wlast  <= (i == beats-1);

            // Wait W handshake
            do @(posedge vif.clk);
            while (!vif.wready);
        end

        @(posedge vif.clk);
        vif.wvalid <= 0;
        vif.wlast  <= 0;


        // ---------------- B ----------------
        vif.bready <= 1;
        do @(posedge vif.clk);
        while (!vif.bvalid);
        tr.bresp = vif.bresp;
        @(posedge vif.clk);
        vif.bready <= 0;

        `uvm_info("DRV", $sformatf("WRITE done: id=%0d BRESP=%0d", tr.id, tr.bresp), UVM_LOW)
    endtask

    // ============================================================
    // READ
    // ============================================================
    task drive_read(
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr
    );
        int beats = tr.len + 1;
        int i;

        // ---------------- AR ----------------
        vif.arvalid <= 1;
        vif.araddr  <= tr.addr;
        vif.arlen   <= tr.len;
        vif.arsize  <= tr.size;
        vif.arburst <= tr.burst;
        vif.arid    <= tr.id;

        do @(posedge vif.clk);
        while (!vif.arready);
        @(posedge vif.clk);
        vif.arvalid <= 0;

        // ---------------- R ----------------
        vif.rready <= 1;

        for (i = 0; i < beats; i++) begin
            // Wait R handshake
            do @(posedge vif.clk);
            while (!vif.rvalid);

            tr.rdata_beats[i] = vif.rdata;
            tr.rresp_beats[i] = vif.rresp;

            if ((i == beats - 1) && !vif.rlast)
                `uvm_error("DRV", "Missing RLAST on final beat");
            if ((i < beats - 1) && vif.rlast)
                `uvm_error("DRV", "Early RLAST");
        end

        @(posedge vif.clk);
        vif.rready <= 0;

        `uvm_info("DRV", $sformatf("READ done: id=%0d beats=%0d first=0x%0h", tr.id, beats, tr.rdata_beats[0]), UVM_LOW)
    endtask

endclass
`endif
