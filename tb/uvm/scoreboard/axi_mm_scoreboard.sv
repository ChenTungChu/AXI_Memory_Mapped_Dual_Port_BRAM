// File: tb/uvm/axi_mm_scoreboard.sv
//
// Scoreboard for axi_mm_dual_port_bram
// - byte-addressable memory model (mem_model)
// - accepts transactions from monitors (per-port) via uvm_analysis_imp
// - applies writes according to WSTRB / size / burst
// - reconstructs expected read data and compares to DUT read beats
//
// Limitations / Caveats:
// - Port1 (core) writes in DUT are staged and ultimately committed by the dma domain.
//   Monitors observe the Port1 interface timing (core domain). This scoreboard applies
//   writes at the time the monitor publishes them. If your DUT delays commit of Port1
//   writes (i.e., the memory update happens later in dma_clk), you may need to
//   either (a) make your monitors publish commit events, or (b) use only Port0 writes
//   for tests where immediate visibility is required. For many verification flows
//   this simple model is acceptable, but be mindful of cross-domain visibility tests.
//
// Usage:
// - Create an instance in your env and connect monitors' ap to scoreboard's analysis_exports.
//   e.g. mon0.ap.connect(scoreboard.ap_export_p0); mon1.ap.connect(scoreboard.ap_export_p1);
//
// ----------------------------------------------------------------------------

`ifndef AXI_MM_SCOREBOARD_SV
`define AXI_MM_SCOREBOARD_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

class axi_mm_scoreboard #(
    int ADDR_WIDTH      = 32,
    int DATA_WIDTH      = 64,
    int ID_WIDTH        = 4,
    int DEPTH_WORDS     = 1024
) extends uvm_component;

    `uvm_component_utils(axi_mm_scoreboard #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS))

    // derived params
    localparam int BYTES_PER_BEAT = DATA_WIDTH / 8;
    localparam int MEM_BYTES      = DEPTH_WORDS * BYTES_PER_BEAT;
    localparam int ADDR_IDX_W     = $clog2(MEM_BYTES);

    // -------------------------------------------------------------------------
    // TLM / analysis ports
    // -------------------------------------------------------------------------
    uvm_analysis_export #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)) ap_export_p0;
    uvm_analysis_export #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)) ap_export_p1;

    uvm_analysis_imp #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH), axi_mm_scoreboard) ap_imp_p0;
    uvm_analysis_imp #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH), axi_mm_scoreboard) ap_imp_p1;

    // -------------------------------------------------------------------------
    // memory model: byte array
    // -------------------------------------------------------------------------
    bit [7:0] mem_model [0:MEM_BYTES-1];
    bit       written_model[0:MEM_BYTES-1]; // track initialized bytes

    // statistics
    int unsigned writes_seen_p0;
    int unsigned writes_seen_p1;
    int unsigned reads_seen_p0;
    int unsigned reads_seen_p1;
    int unsigned mismatches;

    // constructor
    function new(string name = "axi_mm_scoreboard", uvm_component parent = null);
        super.new(name, parent);
        ap_export_p0 = new("ap_export_p0", this);
        ap_export_p1 = new("ap_export_p1", this);

        ap_imp_p0 = new("ap_imp_p0", this);
        ap_imp_p1 = new("ap_imp_p1", this);

        ap_export_p0.connect(ap_imp_p0);
        ap_export_p1.connect(ap_imp_p1);
    endfunction

    // -------------------------------------------------------------------------
    // helper functions (pure calculation)
    // -------------------------------------------------------------------------
    function automatic int size_to_bytes(logic [2:0] size_field);
        return (1 << size_field);
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] compute_incr_addr(
        logic [ADDR_WIDTH-1:0] addr,
        logic [2:0]            size_field,
        int                    beat_index
    );
        return addr + (beat_index * size_to_bytes(size_field));
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] compute_wrap_addr(
        logic [ADDR_WIDTH-1:0] addr,
        logic [2:0]            size_field,
        int                    len,
        int                    beat_index
    );
        int beat_bytes;
        int wrap_bytes;
        logic [ADDR_WIDTH-1:0] base;
        beat_bytes = size_to_bytes(size_field);
        wrap_bytes = (len + 1) * beat_bytes;
        base = (addr / wrap_bytes) * wrap_bytes;

        return  base + ((addr - base + beat_index * beat_bytes) % wrap_bytes);
    endfunction

    function automatic int unsigned byte_index(logic [ADDR_WIDTH-1:0] addr);
        return addr[ADDR_IDX_W-1:0];
    endfunction

    // -------------------------------------------------------------------------
    // WRITE
    // -------------------------------------------------------------------------
    task automatic apply_beat_write(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [2:0]            size_field,
        input logic [DATA_WIDTH-1:0] wdata,
        input logic [BYTES_PER_BEAT-1:0] wstrb
    );
        int bytes, b, strobe_lane;
        int unsigned mem_idx;
        int off;

        bytes = size_to_bytes(size_field);
        off = addr % BYTES_PER_BEAT;

        for (b = 0; b < bytes; b++) begin
            strobe_lane = (off + b) % BYTES_PER_BEAT;
            mem_idx     = byte_index(addr + b);
            if (mem_idx < MEM_BYTES) begin
                if (wstrb[strobe_lane]) mem_model[mem_idx] = wdata[8*strobe_lane +: 8];
            end
            else begin
                `uvm_warning("SCB", $sformatf("apply_beat_write: mem_idx out-of-range addr=0x%0h idx=%0d MEM_BYTES=%0d", addr, mem_idx, MEM_BYTES));
            end
        end
    endtask

    task automatic handle_write(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr, int src_port);
        int beats, i;
        logic [ADDR_WIDTH-1:0] beat_addr;

        beats = tr.len + 1;

        for (i = 0; i < beats; i++) begin
            if (tr.burst == 2'b10) beat_addr = compute_wrap_addr(tr.addr, tr.size, tr.len, i);
            else if (tr.burst == 2'b01) beat_addr = compute_incr_addr(tr.addr, tr.size, i);
            else beat_addr = tr.addr;

            apply_beat_write(beat_addr, tr.size, tr.data_beats[i], tr.wstrb_beats[i]);
        end

        if (src_port == 0) writes_seen_p0++;
        else               writes_seen_p1++;
    endtask

    // -------------------------------------------------------------------------
    // READ
    // -------------------------------------------------------------------------
    function automatic bit beat_is_fully_written(
        logic [ADDR_WIDTH-1:0] addr,
        logic [2:0]            size_field
    );
        int bytes = size_to_bytes(size_field);
        int off   = addr % BYTES_PER_BEAT;
        int unsigned idx;

        for (int b = 0; b < bytes; b++) begin
            idx = byte_index(addr + b);
            if (idx >= MEM_BYTES || !written_model[idx])
                return 0;
        end
        return 1;
    endfunction

    task automatic compute_expected_beat_read(
        input  logic [ADDR_WIDTH-1:0] addr,
        input  logic [2:0]            size_field,
        input  int                    beat_index,
        input  logic [1:0]            burst,
        input  int                    len,
        output logic [DATA_WIDTH-1:0] rdata
    );
        logic [ADDR_WIDTH-1:0] beat_addr;
        int bytes, b, strobe_lane;
        int unsigned mem_idx;
        int off;

        if (burst == 2'b10) beat_addr = compute_wrap_addr(addr, size_field, len, beat_index);
        else if (burst == 2'b01) beat_addr = compute_incr_addr(addr, size_field, beat_index);
        else beat_addr = addr;

        bytes = size_to_bytes(size_field);
        rdata = '0;
        off = beat_addr % BYTES_PER_BEAT;

        for (b = 0; b < bytes; b++) begin
            strobe_lane = (off + b) % BYTES_PER_BEAT;
            mem_idx     = byte_index(beat_addr + b);
            if (mem_idx < MEM_BYTES) rdata[8*strobe_lane +: 8] = mem_model[mem_idx];
            else                     rdata[8*strobe_lane +: 8] = '0;
        end
    endtask

    task automatic handle_read(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr, int src_port);
        int beats, i;
        logic [DATA_WIDTH-1:0] expected, got;
        logic [ADDR_WIDTH-1:0] a;

        beats = tr.len + 1;

        for (i = 0; i < beats; i++) begin
            if      (tr.burst == 2'b10) a = compute_wrap_addr(tr.addr, tr.size, tr.len, i);
            else if (tr.burst == 2'b01) a = compute_incr_addr(tr.addr, tr.size, i);
            else                        a = tr.addr;

            if (!beat_is_fully_written(a, tr.size)) begin
                `uvm_info("SCB",
                          $sformatf("Skip read compare: unwritten addr=0x%0h beat=%0d port=%0d",
                                    a, i, src_port),
                          UVM_HIGH)
                continue;
            end

            compute_expected_beat_read(tr.addr, tr.size, i, tr.burst, tr.len, expected);
            got = tr.rdata_beats[i];

            if (got !== expected) begin
                mismatches++;
                `uvm_error("SCB", $sformatf("READ MISMATCH port=%0d addr=0x%0h beat=%0d exp=0x%0h got=0x%0h id=0x%0h",
                                             src_port, compute_incr_addr(tr.addr, tr.size, i), i, expected, got, tr.id));
            end
        end

        if (src_port == 0) reads_seen_p0++;
        else               reads_seen_p1++;
    endtask

    // -------------------------------------------------------------------------
    // uvm_analysis_imp callbacks
    // -------------------------------------------------------------------------
    virtual function void write(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);

        // If monitor modified tr contenet, this could let the scoreboard grasp the wrong data
        // For safety, clone tr before fork
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr_clone;
        $cast(tr_clone, tr.clone());

        fork
            if (tr.rw == AXI_WRITE) handle_write(tr, 0);
            else                    handle_read(tr, 0);
        join_none
    endfunction

    function void ap_imp_p0_write(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        fork
            if (tr.rw == AXI_WRITE) handle_write(tr, 0);
            else                    handle_read(tr, 0);            
        join_none

    endfunction

    function void ap_imp_p1_write(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        fork
            if (tr.rw == AXI_WRITE) handle_write(tr, 1);
            else                    handle_read(tr, 1);
        join_none

    endfunction

    // -------------------------------------------------------------------------
    // build/connect phases
    // -------------------------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        //ap_export_p0.set_name({"ap_export_p0"});
        //ap_export_p1.set_name({"ap_export_p1"});
    endfunction

    // -------------------------------------------------------------------------
    // run_phase: periodic stats
    // -------------------------------------------------------------------------
    task run_phase(uvm_phase phase);
        `uvm_info("SCB", "Scoreboard started", UVM_LOW)

        mismatches = 0;
        writes_seen_p0 = 0;
        writes_seen_p1 = 0;
        reads_seen_p0  = 0;
        reads_seen_p1  = 0;

        forever begin
            #10000ns;
            `uvm_info("SCB", $sformatf("stats: writes_p0=%0d writes_p1=%0d reads_p0=%0d reads_p1=%0d mismatches=%0d",
                                      writes_seen_p0, writes_seen_p1, reads_seen_p0, reads_seen_p1, mismatches),
                      UVM_LOW);
        end
    endtask

endclass : axi_mm_scoreboard

`endif
