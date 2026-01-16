// File: tb/uvm/axi_mm_seq_item.sv
`ifndef AXI_MM_SEQ_ITEM_SV
`define AXI_MM_SEQ_ITEM_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

typedef enum bit { AXI_READ = 0, AXI_WRITE = 1 } axi_rw_e;

class axi_mm_seq_item #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4
) extends uvm_sequence_item;

    // factory registration
    `uvm_object_param_utils(axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

    // derived
    localparam int BYTES_PER_BEAT = DATA_WIDTH/8;

    // ----- stimulus (rand) -----
    rand axi_rw_e                rw;
    rand logic [ADDR_WIDTH-1:0]  addr;
    rand logic [ID_WIDTH-1:0]    id;

    rand logic [7:0]             len;    // 0-based
    rand logic [2:0]             size;   // log2(bytes)
    rand logic [1:0]             burst;  // 00 FIXED, 01 INCR, 10 WRAP

    // payloads (rand)
    rand logic [DATA_WIDTH-1:0]        data_beats[];
    rand logic [(BYTES_PER_BEAT)-1:0]  wstrb_beats[];

    // response fields (non-rand, filled by monitor/driver)
    logic [DATA_WIDTH-1:0]        rdata_beats[];
    logic [1:0]                   rresp_beats[];
    logic [1:0]                   bresp;

    string                        comment;

    // --------------------------
    // Constraints
    // --------------------------
    
    // SystemVerilog will auto-resize dynamic arrays to satisfy this
    constraint c_array_size {
        data_beats.size()  == (len + 1);
        wstrb_beats.size() == (len + 1);
    }

    constraint c_size_default { soft size == $clog2(BYTES_PER_BEAT); }
    constraint c_burst_dist   { soft burst dist { 2'b01 := 90, 2'b10 := 10 }; }
    constraint c_addr_align   { soft addr % BYTES_PER_BEAT == 0; }

    constraint c_wstrb_default {
        foreach (wstrb_beats[i]) soft wstrb_beats[i] == {BYTES_PER_BEAT{1'b1}};
    }

    // --------------------------
    // Constructor
    // --------------------------
    function new(string name = "axi_mm_seq_item");
        super.new(name);
        size           = $clog2(BYTES_PER_BEAT);
        burst          = 2'b01;
        id             = '0;
        len            = 8'd0;
    endfunction

    // --------------------------
    // Post-Randomize: Allocate response arrays
    // --------------------------
    function void post_randomize();
        // Allocate space for response data so Driver/Monitor can just write to it
        int unsigned beats = len + 1;
        rdata_beats = new[beats];
        rresp_beats = new[beats];
    endfunction

    // --------------------------
    // Helper: Manual allocation (for non-randomized usage)
    // --------------------------
    function void set_beats_len(int len);

        assert (len >= 0)
        else `uvm_fatal("SEQ_ITEM", "len < 0 in set_beats_len");

        data_beats  = new[len + 1];
        wstrb_beats = new[len + 1];
        rdata_beats = new[len + 1];
        rresp_beats = new[len + 1];

        foreach (data_beats[i]) begin
            data_beats[i] = '0;
        end

        foreach (wstrb_beats[i]) begin
            wstrb_beats[i] = {BYTES_PER_BEAT{1'b1}};
        end
    endfunction

    // --------------------------
    // UVM Standard Overrides
    // --------------------------
    virtual function void do_print(uvm_printer printer);
        super.do_print(printer);
        printer.print_string("rw", (rw == AXI_WRITE) ? "WRITE" : "READ");
        printer.print_field("addr", addr, $bits(addr), UVM_HEX);
        printer.print_field("id", id, $bits(id), UVM_HEX);
        printer.print_field("len", len, $bits(len), UVM_DEC);
        printer.print_field("size", size, $bits(size), UVM_DEC);
        printer.print_field("burst", burst, $bits(burst), UVM_BIN);
        
        // Print first beat data sample
        if (data_beats.size() > 0)
            printer.print_field("data[0]", data_beats[0], $bits(data_beats[0]), UVM_HEX);
        if (wstrb_beats.size() > 0)
            printer.print_field("wstrb[0]", wstrb_beats[0], BYTES_PER_BEAT, UVM_BIN);
    endfunction

    virtual function void do_copy(uvm_object rhs);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) rhs_;
        if (!$cast(rhs_, rhs)) return;

        super.do_copy(rhs);

        this.rw          = rhs_.rw;
        this.addr        = rhs_.addr;
        this.id          = rhs_.id;
        this.len         = rhs_.len;
        this.size        = rhs_.size;
        this.burst       = rhs_.burst;
        this.bresp       = rhs_.bresp;
        this.comment     = rhs_.comment;

        // Deep copy dynamic arrays
        this.data_beats  = new[rhs_.data_beats.size()];
        this.wstrb_beats = new[rhs_.wstrb_beats.size()];
        foreach (this.data_beats[i]) begin
            this.data_beats[i]  = rhs_.data_beats[i];
            this.wstrb_beats[i] = rhs_.wstrb_beats[i];
        end

        this.rdata_beats = new[rhs_.rdata_beats.size()];
        this.rresp_beats = new[rhs_.rresp_beats.size()];
        foreach (this.rdata_beats[i]) begin
            this.rdata_beats[i] = rhs_.rdata_beats[i];
            this.rresp_beats[i] = rhs_.rresp_beats[i];
        end
    endfunction

    virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer = null);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) rhs_;
        if (!$cast(rhs_, rhs)) return 0;
        
        return (super.do_compare(rhs, comparer) &&
                this.rw    == rhs_.rw &&
                this.addr  == rhs_.addr &&
                this.id    == rhs_.id &&
                this.len   == rhs_.len &&
                this.size  == rhs_.size &&
                this.burst == rhs_.burst &&
                this.data_beats == rhs_.data_beats &&
                this.wstrb_beats == rhs_.wstrb_beats);
    endfunction

    virtual function string convert2string();
        string s = $sformatf("axi_mm_seq_item: %s addr=0x%0h len=%0d id=0x%0h", (rw==AXI_WRITE) ? "WRITE" : "READ", addr, len, id);
        return s;
    endfunction

endclass

`endif