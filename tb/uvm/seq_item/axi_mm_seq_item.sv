// File: tb/uvm/seq_item/axi_mm_seq_item.sv
`ifndef AXI_MM_SEQ_ITEM_SV
`define AXI_MM_SEQ_ITEM_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

typedef enum bit { AXI_READ = 0, AXI_WRITE = 1 } axi_rw_e;

// ------------------------------------------------------------
// op kind for split transactions
// Default is OP_FULL so legacy tests are NOT affected.
// NOTE: use logic[2:0] base type for broad simulator compatibility.
// ------------------------------------------------------------
typedef enum logic [2:0] {
    OP_FULL    = 3'd0,   // legacy: (WRITE) AW+W+B, (READ) AR+R
    OP_AW_ONLY = 3'd1,   // only drive AW
    OP_W_ONLY  = 3'd2,   // only drive W burst (len+1 beats)
    OP_B_WAIT  = 3'd3,   // only wait B for wait_bid
    OP_AR_ONLY = 3'd4,   // reserved (future)
    OP_R_ONLY  = 3'd5    // reserved (future)
} axi_mm_op_kind_e;

class axi_mm_seq_item #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4
) extends uvm_sequence_item;

    `uvm_object_param_utils(axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

    // Use plain int localparam for maximum parser compatibility
    localparam int BYTES_PER_BEAT = (DATA_WIDTH/8);
    localparam int MAX_SIZE_LOG2  = $clog2(BYTES_PER_BEAT);

    // ----- stimulus (rand) -----
    rand axi_rw_e                rw;
    rand logic [ADDR_WIDTH-1:0]  addr;
    rand logic [ID_WIDTH-1:0]    id;

    rand logic [7:0]             len;    // 0-based
    rand logic [2:0]             size;   // log2(bytes)
    rand logic [1:0]             burst;  // 00 FIXED, 01 INCR, 10 WRAP

    // payloads (WRITE only)
    rand logic [DATA_WIDTH-1:0]        wdata_beats[];
    rand logic [BYTES_PER_BEAT-1:0]    wstrb_beats[];

    // split transaction controls
    rand axi_mm_op_kind_e         op_kind;
    rand logic [ID_WIDTH-1:0]     wait_bid;

    // response fields (non-rand, filled by driver/monitor)
    logic [DATA_WIDTH-1:0]        rdata_beats[];
    logic [1:0]                   rresp_beats[];
    time                          rtime_beats[];   // per-beat R handshake time
    logic [1:0]                   bresp;

    // timestamps (monitor/driver may fill)
    time                          start_time;      // optional
    time                          done_time;       // monitor sets on completion (RLAST / B)

    string                        comment;

    // --------------------------
    // Constraints
    // --------------------------

    // Keep legacy behavior unless explicitly overridden
    constraint c_op_kind_default { soft op_kind == OP_FULL; };

    // op_kind consistent with rw
    constraint c_op_kind_rw_consistency {
        if (op_kind inside {OP_AW_ONLY, OP_W_ONLY, OP_B_WAIT}) rw == AXI_WRITE;
        if (op_kind inside {OP_AR_ONLY, OP_R_ONLY})            rw == AXI_READ;
    };

    // Size default + legal range
    constraint c_size_default { soft size == logic'(MAX_SIZE_LOG2); };
    constraint c_size_legal   { size <= logic'(MAX_SIZE_LOG2); };

    // Burst default
    constraint c_burst_dist   { soft burst dist { 2'b01 := 90, 2'b10 := 10 }; };

    // Address alignment (soft)
    // IMPORTANT: avoid (addr & ((1<<size)-1)) form inside constraints (solver unfriendly).
    constraint c_addr_align {
        soft (
            (size == 0) ? 1 :
            (size == 1) ? (addr[0]   == 1'b0) :
            (size == 2) ? (addr[1:0] == 2'b00) :
            (size == 3) ? (addr[2:0] == 3'b000) :
            (size == 4) ? (addr[3:0] == 4'b0000) :
            (size == 5) ? (addr[4:0] == 5'b0) :
            (size == 6) ? (addr[5:0] == 6'b0) :
            (size == 7) ? (addr[6:0] == 7'b0) :
                          1
        );
    };

    // WRAP burst legality:
    // - (len+1) must be power of 2  => (len+1) & len == 0
    // - align at transfer size
    constraint c_wrap_legal {
        if (burst == 2'b10) {
            (((len + 1) & len) == 0);
            (
                (size == 0) ? 1 :
                (size == 1) ? (addr[0]   == 1'b0) :
                (size == 2) ? (addr[1:0] == 2'b00) :
                (size == 3) ? (addr[2:0] == 3'b000) :
                (size == 4) ? (addr[3:0] == 4'b0000) :
                (size == 5) ? (addr[4:0] == 5'b0) :
                (size == 6) ? (addr[5:0] == 6'b0) :
                (size == 7) ? (addr[6:0] == 7'b0) :
                              1
            );
        }
    };

    // For READ: do NOT force write payload arrays to exist.
    // For WRITE: must have payload arrays sized to beats only when we will actually drive W.
    constraint c_array_size {
        if ((rw == AXI_WRITE) && (op_kind inside {OP_FULL, OP_W_ONLY})) {
            wdata_beats.size()  == (len + 1);
            wstrb_beats.size()  == (len + 1);
        } else {
            wdata_beats.size()  == 0;
            wstrb_beats.size()  == 0;
        }
    };

    // Default wait_bid == id only makes semantic sense for B_WAIT
    constraint c_wait_bid_default {
        if (op_kind == OP_B_WAIT) soft wait_bid == id;
    };

    // Guardrails: ops that do not actually stream beats => default len=0
    constraint c_len_guardrails {
        if (rw == AXI_WRITE) {
            if (op_kind inside {OP_AW_ONLY, OP_B_WAIT}) soft len == 0;
        }
    };

    // --------------------------
    // Constructor
    // --------------------------
    function new(string name = "axi_mm_seq_item");
        super.new(name);

        rw       = AXI_READ;
        addr     = '0;
        id       = '0;
        len      = 8'd0;
        size     = logic'(MAX_SIZE_LOG2); // safe cast to 3-bit
        burst    = 2'b01;

        op_kind  = OP_FULL;
        wait_bid = '0;

        bresp    = 2'b00;
        comment  = "";

        start_time = 0;
        done_time  = 0;

        wdata_beats  = new[0];
        wstrb_beats  = new[0];
        rdata_beats  = new[0];
        rresp_beats  = new[0];
        rtime_beats  = new[0];
    endfunction

    // --------------------------
    // Post-Randomize
    // - READ : allocate rdata/rresp/rtime arrays
    // - WRITE: keep them empty
    // - Force default wstrb to all-1 (for write payload cases)
    // --------------------------
    function void post_randomize();
        int beats;
        bit need_payload;

        beats = int'(len) + 1;

        if (rw == AXI_READ) begin
            if (rdata_beats.size() != beats) rdata_beats = new[beats];
            if (rresp_beats.size() != beats) rresp_beats = new[beats];
            if (rtime_beats.size() != beats) rtime_beats = new[beats];
            foreach (rtime_beats[i]) rtime_beats[i] = 0;

            // ensure write payload empty
            if (wdata_beats.size()  != 0) wdata_beats  = new[0];
            if (wstrb_beats.size()  != 0) wstrb_beats  = new[0];
        end
        else begin
            // WRITE: keep read-response arrays empty by default
            if (rdata_beats.size() != 0) rdata_beats = new[0];
            if (rresp_beats.size() != 0) rresp_beats = new[0];
            if (rtime_beats.size() != 0) rtime_beats = new[0];

            need_payload = (op_kind inside {OP_FULL, OP_W_ONLY});
            if (need_payload) begin
                foreach (wstrb_beats[i]) begin
                    // If random produced X or all-0, force sane default all-1
                    if ((^wstrb_beats[i] === 1'bX) || (wstrb_beats[i] === '0))
                        wstrb_beats[i] = {BYTES_PER_BEAT{1'b1}};
                end
            end
        end
    endfunction

    // --------------------------
    // Helper: Manual allocation (for non-randomized usage)
    // beats_len_0based is AXI LEN field (0-based)
    // --------------------------
    function void set_beats_len(int beats_len_0based);
        int beats;
        bit need_payload;

        if (beats_len_0based < 0) begin
            `uvm_fatal("SEQ_ITEM", "len < 0 in set_beats_len")
        end

        beats = beats_len_0based + 1;
        len   = beats_len_0based[7:0];

        if (rw == AXI_READ) begin
            rdata_beats = new[beats];
            rresp_beats = new[beats];
            rtime_beats = new[beats];
            foreach (rtime_beats[i]) rtime_beats[i] = 0;

            wdata_beats  = new[0];
            wstrb_beats  = new[0];
        end
        else begin
            rdata_beats  = new[0];
            rresp_beats  = new[0];
            rtime_beats  = new[0];

            need_payload = (op_kind inside {OP_FULL, OP_W_ONLY});
            if (need_payload) begin
                wdata_beats  = new[beats];
                wstrb_beats  = new[beats];
                foreach (wdata_beats[i])  wdata_beats[i]  = '0;
                foreach (wstrb_beats[i]) wstrb_beats[i] = {BYTES_PER_BEAT{1'b1}};
            end else begin
                wdata_beats  = new[0];
                wstrb_beats  = new[0];
            end
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
        printer.print_int("op_kind", int'(op_kind), 32, UVM_DEC);
        printer.print_field("wait_bid", wait_bid, $bits(wait_bid), UVM_HEX);
        printer.print_field("bresp", bresp, $bits(bresp), UVM_BIN);
        printer.print_time("start_time", start_time);
        printer.print_time("done_time", done_time);

        if (wdata_beats.size() > 0)
            printer.print_field("data[0]", wdata_beats[0], $bits(wdata_beats[0]), UVM_HEX);
        if (wstrb_beats.size() > 0)
            printer.print_field("wstrb[0]", wstrb_beats[0], BYTES_PER_BEAT, UVM_BIN);

        if (rdata_beats.size() > 0)
            printer.print_field("rdata[0]", rdata_beats[0], $bits(rdata_beats[0]), UVM_HEX);
        if (rresp_beats.size() > 0)
            printer.print_field("rresp[0]", rresp_beats[0], $bits(rresp_beats[0]), UVM_BIN);
        if (rtime_beats.size() > 0)
            printer.print_time("rtime[0]", rtime_beats[0]);
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

        this.op_kind     = rhs_.op_kind;
        this.wait_bid    = rhs_.wait_bid;

        this.bresp       = rhs_.bresp;
        this.comment     = rhs_.comment;

        this.start_time  = rhs_.start_time;
        this.done_time   = rhs_.done_time;

        // payload arrays
        this.wdata_beats = new[rhs_.wdata_beats.size()];
        foreach (this.wdata_beats[i]) this.wdata_beats[i] = rhs_.wdata_beats[i];

        this.wstrb_beats = new[rhs_.wstrb_beats.size()];
        foreach (this.wstrb_beats[i]) this.wstrb_beats[i] = rhs_.wstrb_beats[i];

        // response arrays
        this.rdata_beats = new[rhs_.rdata_beats.size()];
        foreach (this.rdata_beats[i]) this.rdata_beats[i] = rhs_.rdata_beats[i];

        this.rresp_beats = new[rhs_.rresp_beats.size()];
        foreach (this.rresp_beats[i]) this.rresp_beats[i] = rhs_.rresp_beats[i];

        this.rtime_beats = new[rhs_.rtime_beats.size()];
        foreach (this.rtime_beats[i]) this.rtime_beats[i] = rhs_.rtime_beats[i];
    endfunction

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

        if (this.wdata_beats.size() != rhs_.wdata_beats.size()) return 0;
        foreach (this.wdata_beats[i]) begin
            if (this.wdata_beats[i] !== rhs_.wdata_beats[i]) return 0;
        end

        if (this.wstrb_beats.size() != rhs_.wstrb_beats.size()) return 0;
        foreach (this.wstrb_beats[i]) begin
            if (this.wstrb_beats[i] !== rhs_.wstrb_beats[i]) return 0;
        end

        // response arrays intentionally not compared here
        return 1;
    endfunction

    virtual function string convert2string();
        return $sformatf(
            "axi_mm_seq_item: %s op=%0d addr=0x%0h len=%0d size=%0d burst=%0b id=0x%0h wait_bid=0x%0h done=%0t",
            (rw==AXI_WRITE) ? "WRITE" : "READ",
            int'(op_kind), addr, len, size, burst, id, wait_bid, done_time
        );
    endfunction

endclass

`endif