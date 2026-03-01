// File: tb/commit/axi_mm_commit_if.sv
`ifndef AXI_MM_COMMIT_IF_SV
`define AXI_MM_COMMIT_IF_SV
`timescale 1ns/1ps

interface axi_mm_commit_if #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 64,
    parameter int ID_WIDTH   = 4,
    parameter int BEAT_IDX_W = 8   // enough for AWLEN up to 255 beats
)(
    input logic clk,
    input logic rst_n
);

    localparam int          IDW   = (ID_WIDTH > 0) ? ID_WIDTH : 1;
    localparam int unsigned STRBW = (DATA_WIDTH/8);

    // ------------------------------------------------------------
    // Commit stream (1 beat per handshake)
    // valid/ready asserted when a beat is committed to memory model
    //
    // NOTE:
    // - valid/payload are driven by DUT (mp_producer)
    // - ready is driven by TB monitor/consumer (mp_monitor)
    // - interface itself does not "init" these; TB/DUT own them.
    // ------------------------------------------------------------
    logic                  valid;
    logic                  ready;

    logic                  port;        // 0: axi0 / 1: axi1
    logic [IDW-1:0]        id;          // burst ID
    logic [BEAT_IDX_W-1:0] beat_idx;    // beat index within burst (debug)
    logic [ADDR_WIDTH-1:0] byte_addr;   // byte address of this beat
    logic [DATA_WIDTH-1:0] wdata;       // full data bus
    logic [STRBW-1:0]      wstrb;       // byte enables
    logic [2:0]            size;        // AXI size (bytes = 1<<size)
    logic                  last;        // last beat of burst commit

    // ------------------------------------------------------------
    // Clocking blocks
    // ------------------------------------------------------------
    // Producer (DUT) drives payload + valid, samples ready
    clocking cb_producer @(posedge clk);
        default input #1step output #0;
        input  rst_n;
        input  ready;
        output valid, port, id, beat_idx, byte_addr, wdata, wstrb, size, last;
    endclocking

    // Monitor/consumer samples payload + valid, drives ready
    clocking cb_monitor @(posedge clk);
        default input #1step output #0;
        input  rst_n;
        input  valid, port, id, beat_idx, byte_addr, wdata, wstrb, size, last;
        output ready;
    endclocking

    // ------------------------------------------------------------
    // Modports
    // ------------------------------------------------------------
    modport mp_producer (
        clocking cb_producer,
        input  clk, rst_n
    );

    modport mp_monitor (
        clocking cb_monitor,
        input  clk, rst_n
    );

endinterface : axi_mm_commit_if

`endif