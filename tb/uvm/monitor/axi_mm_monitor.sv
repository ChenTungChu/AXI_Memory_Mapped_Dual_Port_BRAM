`ifndef AXI_MM_MONITOR_SV
`define AXI_MM_MONITOR_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

// -------------------------------------------------------------------------
// AXI-MM Monitor - cb_monitor version
// - Uses axi_mm_if.mp_monitor + cb_monitor for all sampling
// - Robust to early-B (stores B then completes after W beats done)
// - Matches B by BID (since you have bid)
// - W has no ID: assumes W follows AW order (AXI rule)
// -------------------------------------------------------------------------
class axi_mm_monitor #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4
) extends uvm_component;

    // IMPORTANT:
    //  - Must match axi_mm_if parameter list (ADDR, DATA, ID, HAS_BURST)
    //  - Must be mp_monitor so it can see cb_monitor and all inputs
    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_monitor vif;

    typedef struct {
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
        int unsigned beat_cnt;

        // track B response even if it arrives early
        bit                 b_seen;
        logic [1:0]         bresp;
        logic [ID_WIDTH-1:0] bid;
    } aw_tr_t;

    typedef struct {
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
        int unsigned beat_cnt;
    } ar_tr_t;

    // Outstanding tables
    aw_tr_t write_q[$];                      // AW/W ordered queue
    ar_tr_t pending_reads_s[int unsigned];   // AR/R per ID

    uvm_analysis_port #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)) ap;

    `uvm_component_param_utils(axi_mm_monitor #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // KEY FIX:
        // 你現在整套(Agent/Driver)既然已經用 vif_m / vif_mon 命名，
        // monitor 這裡一定要跟著拿 "vif_mon" 才會抓得到。
        if (!uvm_config_db#(
                virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_monitor
            )::get(this, "", "vif_mon", vif)) begin
            `uvm_fatal("NOVIF", "axi_mm_monitor: virtual interface (mp_monitor) not set (key=vif_mon)")
        end

        `uvm_info("VIF", $sformatf("vif(mp_monitor)=%p", vif), UVM_LOW)
        `uvm_info("MON", "AXI-MM Monitor started", UVM_LOW)
    endfunction

    task run_phase(uvm_phase phase);
        fork
            monitor_write();
            monitor_read();
        join_none
    endtask

    // ------------------------------------------------------------
    // Address per beat (INCR/WRAP support)
    // ------------------------------------------------------------
    function automatic logic [ADDR_WIDTH-1:0] calc_beat_addr(
        input logic [ADDR_WIDTH-1:0] start_addr,
        input logic [2:0]            size,       // log2(bytes_per_beat)
        input logic [7:0]            len,        // AXI len (0-based)
        input logic [1:0]            burst,      // 00 FIXED, 01 INCR, 10 WRAP
        input int unsigned           beat_idx
    );
        int unsigned bytes_per_beat;
        int unsigned total_beats;
        int unsigned wrap_bytes;
        logic [ADDR_WIDTH-1:0] wrap_base;
        int unsigned offset;

        bytes_per_beat = (1 << size);
        total_beats    = len + 1;
        wrap_bytes     = total_beats * bytes_per_beat;

        unique case (burst)
            2'b00: return start_addr; // FIXED
            2'b01: return start_addr + (beat_idx * bytes_per_beat); // INCR
            2'b10: begin // WRAP
                if ((wrap_bytes & (wrap_bytes - 1)) != 0) begin
                    `uvm_error("MON", $sformatf(
                        "Illegal WRAP: wrap_bytes=%0d not power-of-2 (start=0x%0h len=%0d size=%0d)",
                        wrap_bytes, start_addr, len, size))
                    return start_addr;
                end
                wrap_base = start_addr & ~(wrap_bytes - 1);
                offset    = (start_addr - wrap_base) + (beat_idx * bytes_per_beat);
                offset    = offset % wrap_bytes;
                return wrap_base + offset;
            end
            default: return start_addr;
        endcase
    endfunction

    // ------------------------------------------------------------
    // Helper: find an outstanding write entry by ID (BID matching)
    // returns index or -1 if not found
    // ------------------------------------------------------------
    function automatic int find_wr_idx_by_id(input logic [ID_WIDTH-1:0] id);
        for (int i = 0; i < write_q.size(); i++) begin
            if (write_q[i].tr.id === id) return i;
        end
        return -1;
    endfunction

    // ------------------------------------------------------------
    // Helper: attempt to complete the head transaction if possible
    // Rule: Only "complete" when (W beats complete) AND (B seen).
    // If B arrived early, we keep it and complete later.
    // NOTE: only head can be completed based on W ordering (no WID).
    // ------------------------------------------------------------
    task automatic try_complete_head();
        int unsigned expected_beats;

        if (write_q.size() == 0) return;

        expected_beats = write_q[0].tr.len + 1;

        if ((write_q[0].beat_cnt == expected_beats) && (write_q[0].b_seen)) begin
            write_q[0].tr.bresp = write_q[0].bresp;

            `uvm_info("MON_WR_DONE",
                $sformatf("WRITE completed: ID=%0d addr=0x%0h beats=%0d bresp=%0d",
                          write_q[0].tr.id, write_q[0].tr.addr, expected_beats, write_q[0].tr.bresp),
                UVM_LOW)

            ap.write(write_q[0].tr);
            write_q.pop_front();
        end
    endtask

    // ============================================================
    // Write monitor (cb_monitor)
    // ============================================================
    task monitor_write();
        aw_tr_t       tr_struct;
        int unsigned  beat_idx;
        int unsigned  expected_beats;
        logic [ADDR_WIDTH-1:0] beat_addr;

        int unsigned aw_wait_cyc;
        aw_wait_cyc = 0;

        forever begin
            @(vif.cb_monitor);

            if (vif.cb_monitor.rst_n === 1'b0) begin
                write_q.delete();
                aw_wait_cyc = 0;
                continue;
            end

            // ---------------- AW debug wait ----------------
            if ((vif.cb_monitor.awvalid === 1'b1) && (vif.cb_monitor.awready === 1'b0)) begin
                aw_wait_cyc++;
                if ((aw_wait_cyc % 100) == 0) begin
                    `uvm_info("MON_AW_WAIT",
                        $sformatf("AW waiting (%0d cyc): v=%0b r=%0b addr=0x%0h id=%0d len=%0d burst=%02b size=%0d",
                                  aw_wait_cyc,
                                  vif.cb_monitor.awvalid, vif.cb_monitor.awready,
                                  vif.cb_monitor.awaddr,  vif.cb_monitor.awid,
                                  vif.cb_monitor.awlen,   vif.cb_monitor.awburst,
                                  vif.cb_monitor.awsize),
                        UVM_LOW)
                end
            end else begin
                aw_wait_cyc = 0;
            end

            // ---------------- AW capture (handshake) ----------------
            if ((vif.cb_monitor.awvalid === 1'b1) && (vif.cb_monitor.awready === 1'b1)) begin
                tr_struct.tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create(
                    $sformatf("wr_tr_id_%0d", vif.cb_monitor.awid), this);

                tr_struct.tr.rw    = AXI_WRITE;
                tr_struct.tr.addr  = vif.cb_monitor.awaddr;
                tr_struct.tr.id    = vif.cb_monitor.awid;
                tr_struct.tr.len   = vif.cb_monitor.awlen;
                tr_struct.tr.size  = vif.cb_monitor.awsize;
                tr_struct.tr.burst = vif.cb_monitor.awburst;

                tr_struct.tr.set_beats_len(tr_struct.tr.len);
                tr_struct.beat_cnt = 0;

                tr_struct.b_seen = 0;
                tr_struct.bresp  = '0;
                tr_struct.bid    = '0;

                write_q.push_back(tr_struct);

                `uvm_info("MON_AW_HS",
                    $sformatf("AW HS: ID=%0d addr=0x%0h len=%0d burst=%02b size=%0d (q_depth=%0d)",
                              tr_struct.tr.id, tr_struct.tr.addr, tr_struct.tr.len,
                              tr_struct.tr.burst, tr_struct.tr.size, write_q.size()),
                    UVM_LOW)
            end

            // ---------------- W capture (handshake) ----------------
            if ((write_q.size() > 0) &&
                (vif.cb_monitor.wvalid === 1'b1) && (vif.cb_monitor.wready === 1'b1)) begin

                beat_idx       = write_q[0].beat_cnt;
                expected_beats = write_q[0].tr.len + 1;

                if (beat_idx >= expected_beats) begin
                    `uvm_error("MON",
                        $sformatf("Extra W beat on head. head_id=%0d exp=%0d got_beat=%0d WDATA=0x%0h WSTRB=0x%0h WLAST=%0b",
                                  write_q[0].tr.id, expected_beats, beat_idx,
                                  vif.cb_monitor.wdata, vif.cb_monitor.wstrb, vif.cb_monitor.wlast))
                end else begin
                    beat_addr = calc_beat_addr(write_q[0].tr.addr,
                                               write_q[0].tr.size,
                                               write_q[0].tr.len,
                                               write_q[0].tr.burst,
                                               beat_idx);

                    write_q[0].tr.data_beats[beat_idx]  = vif.cb_monitor.wdata;
                    write_q[0].tr.wstrb_beats[beat_idx] = vif.cb_monitor.wstrb;
                    write_q[0].beat_cnt++;

                    `uvm_info("MON_W_HS",
                        $sformatf("W HS: head_id=%0d beat=%0d/%0d addr=0x%0h data=0x%0h wstrb=0x%0h wlast=%0b",
                                  write_q[0].tr.id, beat_idx, expected_beats, beat_addr,
                                  vif.cb_monitor.wdata, vif.cb_monitor.wstrb, vif.cb_monitor.wlast),
                        UVM_HIGH)
                end

                if (vif.cb_monitor.wlast === 1'b1) begin
                    if (write_q[0].beat_cnt != expected_beats) begin
                        `uvm_error("MON",
                            $sformatf("WLAST mismatch. head_id=%0d seen_beats=%0d exp_beats=%0d",
                                      write_q[0].tr.id, write_q[0].beat_cnt, expected_beats))
                    end
                end

                try_complete_head();
            end

            // ---------------- B capture (handshake) ----------------
            if ((vif.cb_monitor.bvalid === 1'b1) && (vif.cb_monitor.bready === 1'b1)) begin
                int idx;
                logic [ID_WIDTH-1:0] bid_l;

                bid_l = vif.cb_monitor.bid;
                idx   = find_wr_idx_by_id(bid_l);

                if (idx < 0) begin
                    `uvm_error("MON",
                        $sformatf("B HS for unknown BID=%0d (no matching AW yet). bresp=%0d q_depth=%0d",
                                  bid_l, vif.cb_monitor.bresp, write_q.size()))
                end else begin
                    if (!write_q[idx].b_seen) begin
                        write_q[idx].b_seen = 1;
                        write_q[idx].bresp  = vif.cb_monitor.bresp;
                        write_q[idx].bid    = bid_l;
                    end else begin
                        `uvm_error("MON",
                            $sformatf("Duplicate B HS for BID=%0d (already seen). bresp=%0d",
                                      bid_l, vif.cb_monitor.bresp))
                    end

                    expected_beats = write_q[idx].tr.len + 1;
                    if (write_q[idx].beat_cnt != expected_beats) begin
                        `uvm_error("MON",
                            $sformatf("B HS EARLY/INCOMPLETE. BID=%0d beats=%0d/%0d (stored; will complete after W)",
                                      bid_l, write_q[idx].beat_cnt, expected_beats))
                    end

                    if (idx == 0) begin
                        try_complete_head();
                    end
                end
            end
        end
    endtask

    // ============================================================
    // Read monitor (cb_monitor) - per-ID pending table
    // ============================================================
    task monitor_read();
        int unsigned id;
        int unsigned beat_idx;
        int unsigned expected_beats;
        logic [ADDR_WIDTH-1:0] beat_addr;

        int unsigned ar_wait_cyc;
        int unsigned r_wait_cyc;
        ar_wait_cyc = 0;
        r_wait_cyc  = 0;

        forever begin
            @(vif.cb_monitor);

            if (vif.cb_monitor.rst_n === 1'b0) begin
                pending_reads_s.delete();
                ar_wait_cyc = 0;
                r_wait_cyc  = 0;
                continue;
            end

            // ---------------- AR debug wait ----------------
            if ((vif.cb_monitor.arvalid === 1'b1) && (vif.cb_monitor.arready === 1'b0)) begin
                ar_wait_cyc++;
                if ((ar_wait_cyc % 100) == 0) begin
                    `uvm_info("MON_AR_WAIT",
                        $sformatf("AR waiting (%0d cyc): v=%0b r=%0b addr=0x%0h id=%0d len=%0d burst=%02b size=%0d",
                                  ar_wait_cyc,
                                  vif.cb_monitor.arvalid, vif.cb_monitor.arready,
                                  vif.cb_monitor.araddr,  vif.cb_monitor.arid,
                                  vif.cb_monitor.arlen,   vif.cb_monitor.arburst,
                                  vif.cb_monitor.arsize),
                        UVM_LOW)
                end
            end else begin
                ar_wait_cyc = 0;
            end

            // ---------------- AR capture (handshake) ----------------
            if ((vif.cb_monitor.arvalid === 1'b1) && (vif.cb_monitor.arready === 1'b1)) begin
                id = vif.cb_monitor.arid;

                if (pending_reads_s.exists(id)) begin
                    `uvm_error("MON", $sformatf("AR received while read pending ID=%0d", id))
                end else begin
                    pending_reads_s[id].tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create(
                        $sformatf("rd_tr_id_%0d", id), this);

                    pending_reads_s[id].tr.rw    = AXI_READ;
                    pending_reads_s[id].tr.addr  = vif.cb_monitor.araddr;
                    pending_reads_s[id].tr.id    = id;
                    pending_reads_s[id].tr.len   = vif.cb_monitor.arlen;
                    pending_reads_s[id].tr.size  = vif.cb_monitor.arsize;
                    pending_reads_s[id].tr.burst = vif.cb_monitor.arburst;

                    pending_reads_s[id].tr.set_beats_len(pending_reads_s[id].tr.len);
                    pending_reads_s[id].beat_cnt = 0;

                    `uvm_info("MON_AR_HS",
                        $sformatf("AR HS: ID=%0d addr=0x%0h len=%0d burst=%02b size=%0d (pending=%0d)",
                                  id, vif.cb_monitor.araddr, vif.cb_monitor.arlen,
                                  vif.cb_monitor.arburst, vif.cb_monitor.arsize,
                                  pending_reads_s.num()),
                        UVM_LOW)
                end
            end

            // ---------------- R debug wait ----------------
            if ((vif.cb_monitor.rvalid === 1'b1) && (vif.cb_monitor.rready === 1'b0)) begin
                r_wait_cyc++;
                if ((r_wait_cyc % 100) == 0) begin
                    `uvm_info("MON_R_WAIT",
                        $sformatf("R waiting (%0d cyc): v=%0b r=%0b rid=%0d rlast=%0b rresp=%0b rdata=0x%0h",
                                  r_wait_cyc,
                                  vif.cb_monitor.rvalid, vif.cb_monitor.rready,
                                  vif.cb_monitor.rid, vif.cb_monitor.rlast,
                                  vif.cb_monitor.rresp, vif.cb_monitor.rdata),
                        UVM_LOW)
                end
            end else begin
                r_wait_cyc = 0;
            end

            // ---------------- R capture (handshake) ----------------
            if ((vif.cb_monitor.rvalid === 1'b1) && (vif.cb_monitor.rready === 1'b1)) begin
                id = vif.cb_monitor.rid;

                if (!pending_reads_s.exists(id)) begin
                    `uvm_error("MON", $sformatf("R for unknown ID %0d (no pending AR)", id))
                end else begin
                    expected_beats = pending_reads_s[id].tr.len + 1;
                    beat_idx       = pending_reads_s[id].beat_cnt;

                    beat_addr = calc_beat_addr(pending_reads_s[id].tr.addr,
                                               pending_reads_s[id].tr.size,
                                               pending_reads_s[id].tr.len,
                                               pending_reads_s[id].tr.burst,
                                               beat_idx);

                    if (beat_idx < expected_beats) begin
                        pending_reads_s[id].tr.rdata_beats[beat_idx] = vif.cb_monitor.rdata;
                        pending_reads_s[id].tr.rresp_beats[beat_idx] = vif.cb_monitor.rresp;
                        pending_reads_s[id].beat_cnt++;

                        `uvm_info("MON_R_HS",
                            $sformatf("R HS: ID=%0d beat=%0d/%0d addr=0x%0h data=0x%0h rresp=%0b rlast=%0b",
                                      id, beat_idx, expected_beats, beat_addr,
                                      vif.cb_monitor.rdata, vif.cb_monitor.rresp, vif.cb_monitor.rlast),
                            UVM_HIGH)
                    end else begin
                        `uvm_error("MON",
                            $sformatf("Extra R beat. ID=%0d beat=%0d exp=%0d addr=0x%0h data=0x%0h rresp=%0b rlast=%0b",
                                      id, beat_idx, expected_beats, beat_addr,
                                      vif.cb_monitor.rdata, vif.cb_monitor.rresp, vif.cb_monitor.rlast))
                    end

                    if (vif.cb_monitor.rlast === 1'b1) begin
                        if (pending_reads_s[id].beat_cnt != expected_beats) begin
                            `uvm_error("MON",
                                $sformatf("RLAST early/late. ID=%0d beats=%0d/%0d",
                                          id, pending_reads_s[id].beat_cnt, expected_beats))
                        end

                        ap.write(pending_reads_s[id].tr);
                        pending_reads_s.delete(id);
                    end
                end
            end
        end
    endtask

endclass

`endif
