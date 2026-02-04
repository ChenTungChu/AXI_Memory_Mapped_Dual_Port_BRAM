// File: tb/uvm/axi_mm_seq_item.sv
`ifndef AXI_MM_SEQ_ITEM_SV
`define AXI_MM_SEQ_ITEM_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

typedef enum bit { AXI_READ = 0, AXI_WRITE = 1 } axi_rw_e;

// ------------------------------------------------------------
// op kind for split transactions
// Default is OP_FULL so legacy tests are NOT affected.
// ------------------------------------------------------------
typedef enum int unsigned {
    OP_FULL    = 0,   // legacy behavior: (WRITE) AW+W+B, (READ) AR+R
    OP_AW_ONLY = 1,   // only drive AW
    OP_W_ONLY  = 2,   // only drive W burst (len+1 beats)
    OP_B_WAIT  = 3,   // only wait B for wait_bid
    OP_AR_ONLY = 4,   // reserved (future)
    OP_R_ONLY  = 5    // reserved (future)
} axi_mm_op_kind_e;

class axi_mm_seq_item #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4
) extends uvm_sequence_item;

    `uvm_object_param_utils(axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

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

    // NEW: split transaction controls
    rand axi_mm_op_kind_e         op_kind;
    rand logic [ID_WIDTH-1:0]     wait_bid;

    // response fields (non-rand, filled by driver)
    logic [DATA_WIDTH-1:0]        rdata_beats[];
    logic [1:0]                   rresp_beats[];
    logic [1:0]                   bresp;

    string                        comment;

    // --------------------------
    // Constraints
    // --------------------------
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

    // keep legacy behavior unless explicitly overridden
    constraint c_op_kind_default { soft op_kind == OP_FULL; }

    // default wait_bid == id (for B_WAIT usage)
    constraint c_wait_bid_default { soft wait_bid == id; }

    // --------------------------
    // Constructor
    // --------------------------
    function new(string name = "axi_mm_seq_item");
        super.new(name);
        size     = $clog2(BYTES_PER_BEAT);
        burst    = 2'b01;
        id       = '0;
        len      = 8'd0;
        op_kind  = OP_FULL;
        wait_bid = '0;
        bresp    = 2'b00;
    endfunction

    // --------------------------
    // Post-Randomize: Allocate response arrays
    // --------------------------
    function void post_randomize();
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

        foreach (data_beats[i]) data_beats[i] = '0;
        foreach (wstrb_beats[i]) wstrb_beats[i] = {BYTES_PER_BEAT{1'b1}};
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
        printer.print_int("op_kind", op_kind, 32, UVM_DEC);
        printer.print_field("wait_bid", wait_bid, $bits(wait_bid), UVM_HEX);

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
        this.op_kind     = rhs_.op_kind;
        this.wait_bid    = rhs_.wait_bid;

        this.data_beats = new[rhs_.data_beats.size()];
        foreach (this.data_beats[i]) this.data_beats[i] = rhs_.data_beats[i];

        this.wstrb_beats = new[rhs_.wstrb_beats.size()];
        foreach (this.wstrb_beats[i]) this.wstrb_beats[i] = rhs_.wstrb_beats[i];

        this.rdata_beats = new[rhs_.rdata_beats.size()];
        foreach (this.rdata_beats[i]) this.rdata_beats[i] = rhs_.rdata_beats[i];

        this.rresp_beats = new[rhs_.rresp_beats.size()];
        foreach (this.rresp_beats[i]) this.rresp_beats[i] = rhs_.rresp_beats[i];
    endfunction

    // safer compare (avoid simulator differences on dynamic array ==)
    virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer = null);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) rhs_;
        if (!$cast(rhs_, rhs)) return 0;

        if (!super.do_compare(rhs, comparer)) return 0;

        if (this.rw    != rhs_.rw)    return 0;
        if (this.addr  != rhs_.addr)  return 0;
        if (this.id    != rhs_.id)    return 0;
        if (this.len   != rhs_.len)   return 0;
        if (this.size  != rhs_.size)  return 0;
        if (this.burst != rhs_.burst) return 0;

        if (this.op_kind  != rhs_.op_kind)  return 0;
        if (this.wait_bid != rhs_.wait_bid) return 0;

        if (this.data_beats.size() != rhs_.data_beats.size()) return 0;
        foreach (this.data_beats[i]) begin
            if (this.data_beats[i] !== rhs_.data_beats[i]) return 0;
        end

        if (this.wstrb_beats.size() != rhs_.wstrb_beats.size()) return 0;
        foreach (this.wstrb_beats[i]) begin
            if (this.wstrb_beats[i] !== rhs_.wstrb_beats[i]) return 0;
        end

        return 1;
    endfunction

    virtual function string convert2string();
        return $sformatf("axi_mm_seq_item: %s op=%0d addr=0x%0h len=%0d id=0x%0h wait_bid=0x%0h",
                         (rw==AXI_WRITE) ? "WRITE" : "READ",
                         op_kind, addr, len, id, wait_bid);
    endfunction

endclass

`endif
