`ifndef AXI_MM_APPLY_IF_SV
`define AXI_MM_APPLY_IF_SV
`timescale 1ns/1ps

interface axi_mm_apply_if #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 64,
    parameter int ID_WIDTH   = 4,
    parameter int BEAT_IDX_W = 8
)(
    input logic clk,
    input logic rst_n
);

    localparam int          IDW   = (ID_WIDTH > 0) ? ID_WIDTH : 1;
    localparam int unsigned STRBW = (DATA_WIDTH/8);

    logic                  valid;
    logic                  ready;

    logic                  port;
    logic [IDW-1:0]        id;
    logic [BEAT_IDX_W-1:0] beat_idx;
    logic [ADDR_WIDTH-1:0] byte_addr;
    logic [DATA_WIDTH-1:0] wdata;
    logic [STRBW-1:0]      wstrb;
    logic [2:0]            size;
    logic                  last;

    clocking cb_producer @(posedge clk);
        default input #1step output #0;
        input  rst_n;
        input  ready;
        output valid, port, id, beat_idx, byte_addr, wdata, wstrb, size, last;
    endclocking

    clocking cb_monitor @(posedge clk);
        default input #1step output #0;
        input  rst_n;
        input  valid, port, id, beat_idx, byte_addr, wdata, wstrb, size, last;
        output ready;
    endclocking

    modport mp_producer (
        clocking cb_producer,
        input  clk, rst_n
    );

    modport mp_monitor (
        clocking cb_monitor,
        input  clk, rst_n
    );

endinterface : axi_mm_apply_if

`endif