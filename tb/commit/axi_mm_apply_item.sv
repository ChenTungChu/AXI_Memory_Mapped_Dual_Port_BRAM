// File: tb/commit/axi_mm_apply_item.sv
`ifndef AXI_MM_APPLY_ITEM_SV
`define AXI_MM_APPLY_ITEM_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

class axi_mm_apply_item #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4,
    int BEAT_IDX_W = 8
) extends uvm_sequence_item;

    `uvm_object_param_utils(axi_mm_apply_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, BEAT_IDX_W))

    localparam int STRB_WIDTH = (DATA_WIDTH/8);

    rand logic                  port;
    rand logic [ID_WIDTH-1:0]   id;
    rand logic [BEAT_IDX_W-1:0] beat_idx;
    rand logic [ADDR_WIDTH-1:0] byte_addr;
    rand logic [DATA_WIDTH-1:0] wdata;
    rand logic [STRB_WIDTH-1:0] wstrb;
    rand logic [2:0]            size;
    rand logic                  last;
    time                        apply_time;

    // ------------------------------------------------------------
    // Constructor phase
    // ------------------------------------------------------------
    function new(string name = "axi_mm_apply_item");
        super.new(name);
    endfunction

    function string convert2string();
        return $sformatf( "apply: t=%0t port=%0d id=0x%0h beat_idx=%0d addr=0x%0h data=0x%0h wstrb=0x%0h size=%0d last=%0b", apply_time, port, id, beat_idx, byte_addr, wdata, wstrb, size, last);
    endfunction

endclass : axi_mm_apply_item

`endif