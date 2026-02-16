// File: tb/commit/axi_mm_commit_item.sv
`ifndef AXI_MM_COMMIT_ITEM_SV
`define AXI_MM_COMMIT_ITEM_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

class axi_mm_commit_item #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4,
    int BEAT_IDX_W = 8
) extends uvm_sequence_item;

    localparam int IDW   = (ID_WIDTH > 0) ? ID_WIDTH : 1;
    localparam int STRBW = DATA_WIDTH/8;

    // fields
    bit                  port;       // 0/1
    logic [IDW-1:0]       id;
    logic [BEAT_IDX_W-1:0] beat_idx;
    logic [ADDR_WIDTH-1:0] byte_addr;
    logic [DATA_WIDTH-1:0] wdata;
    logic [STRBW-1:0]      wstrb;
    logic [2:0]            size;
    bit                   last;

    `uvm_object_param_utils_begin(axi_mm_commit_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, BEAT_IDX_W))
        `uvm_field_int(port,      UVM_DEFAULT)
        `uvm_field_int(id,        UVM_DEFAULT)
        `uvm_field_int(beat_idx,  UVM_DEFAULT)
        `uvm_field_int(byte_addr, UVM_DEFAULT)
        `uvm_field_int(wdata,     UVM_DEFAULT)
        `uvm_field_int(wstrb,     UVM_DEFAULT)
        `uvm_field_int(size,      UVM_DEFAULT)
        `uvm_field_int(last,      UVM_DEFAULT)
    `uvm_object_utils_end

    function new(string name = "axi_mm_commit_item");
        super.new(name);
    endfunction

    function string convert2string();
        return $sformatf("commit: port=%0d id=0x%0h beat_idx=%0d addr=0x%0h data=0x%0h wstrb=0x%0h size=%0d last=%0d",
                         port, id, beat_idx, byte_addr, wdata, wstrb, size, last);
    endfunction

endclass : axi_mm_commit_item

`endif
