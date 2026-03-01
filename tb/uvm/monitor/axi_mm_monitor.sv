// File: tb/uvm/monitor/axi_mm_monitor.sv
`ifndef AXI_MM_MONITOR_SV
`define AXI_MM_MONITOR_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

// -------------------------------------------------------------------------
// AXI-MM Monitor - cb_monitor version (robust, reset-agent friendly)
//
// Fixes / guarantees for commit-based scoreboard:
//  1) R: always fill rtime_beats[beat] with $time at each R handshake.
//  2) R: stamp done_time at RLAST.
//  3) B: DO NOT use edge-detect (bhs_prev) which drops back-to-back B handshakes.
//     Process every handshake (using prev-cycle sampled payload to avoid race).
//  4) reset listener split into assert/deassert watchdog tasks (non-blocking).
// -------------------------------------------------------------------------
class axi_mm_monitor #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4
) extends uvm_component;

    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_monitor vif;

    localparam int unsigned BYTES_PER_BEAT = (DATA_WIDTH/8);
    localparam int unsigned MAX_SIZE_LOG2  = $clog2(BYTES_PER_BEAT);

    // ---- ignore window after reset/flush ----
    localparam time IGNORE_WINDOW = 500ns; // tune: 200ns~2us based on your fabric

    // ---- Duplicate/late B suppression window after write completion ----
    localparam time DUP_B_DROP_WINDOW = 5us; // tune: >= worst-case response skid/backpressure latency

    typedef struct {
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
        int unsigned beat_cnt;

        bit                  b_seen;
        logic [1:0]          bresp;
        logic [ID_WIDTH-1:0] bid;

        bit                  w_done;
    } aw_tr_t;

    typedef struct {
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
        int unsigned beat_cnt;
    } ar_tr_t;

    // Outstanding tables
    aw_tr_t write_q[$];
    aw_tr_t wait_b_s[int unsigned];          // key = int'(ID)
    ar_tr_t pending_reads_s[int unsigned];   // key = int'(ID)

    // last completion timestamp per ID (for dup-B suppression)
    time last_wr_done_time[int unsigned];    // key = int'(ID)

    uvm_analysis_port #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)) ap;

    // Global reset/flush events (triggered by reset_agent / controller)
    uvm_event ev_reset_assert;
    uvm_event ev_reset_deassert;
    uvm_event ev_flush;
    uvm_event ev_flush_done;

    // Shared-state protection
    semaphore state_lock;

    // debug counters
    int unsigned aw_wait_cyc_w;
    int unsigned ar_wait_cyc_r;
    int unsigned r_wait_cyc_r;

    // reset-active latch (set by event listener; also used for gating late responses)
    bit reset_active;

    // ignore window deadline (drop unknown BID/RID during this window)
    time ignore_unknown_until;

    `uvm_component_param_utils(axi_mm_monitor #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Be robust: allow either "vif_mon" (new) or "vif" (legacy)
        if (!uvm_config_db#(
                virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_monitor
            )::get(this, "", "vif_mon", vif))
        begin
            if (!uvm_config_db#(
                    virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_monitor
                )::get(this, "", "vif", vif))
            begin
                `uvm_fatal("NOVIF", "axi_mm_monitor: virtual interface (mp_monitor) not set (keys tried: vif_mon, vif)")
            end
        end

        ev_reset_assert   = uvm_event_pool::get_global("axi_mm_reset_assert");
        ev_reset_deassert = uvm_event_pool::get_global("axi_mm_reset_deassert");
        ev_flush          = uvm_event_pool::get_global("axi_mm_flush");
        ev_flush_done     = uvm_event_pool::get_global("axi_mm_flush_done");

        state_lock = new(1);

        aw_wait_cyc_w = 0;
        ar_wait_cyc_r = 0;
        r_wait_cyc_r  = 0;

        reset_active = 1'b0;
        ignore_unknown_until = 0;

        `uvm_info("VIF", $sformatf("vif(mp_monitor)=%p", vif), UVM_LOW)
        `uvm_info("MON", "AXI-MM Monitor started", UVM_LOW)
    endfunction

    task run_phase(uvm_phase phase);
        fork
            reset_assert_watchdog();   // LISTEN only
            reset_deassert_watchdog(); // LISTEN only
            flush_watchdog();
            monitor_write();
            monitor_read();
        join_none
    endtask

    // ------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------
    function automatic int unsigned id_key(input logic [ID_WIDTH-1:0] id);
        return int'(id);
    endfunction

    function automatic bit in_ignore_window();
        return (reset_active || ($time < ignore_unknown_until));
    endfunction

    function automatic bit in_dup_b_window(input int unsigned id_k);
        if (!last_wr_done_time.exists(id_k)) return 1'b0;
        return (($time - last_wr_done_time[id_k]) <= DUP_B_DROP_WINDOW);
    endfunction

    // ------------------------------------------------------------
    // Centralized clear (reset/flush)
    // - also arms ignore window to drop late/stray B/R after reset/flush
    // ------------------------------------------------------------
    task automatic clear_state(string why);
        state_lock.get(1);

        write_q.delete();
        wait_b_s.delete();
        pending_reads_s.delete();
        last_wr_done_time.delete();

        aw_wait_cyc_w = 0;
        ar_wait_cyc_r = 0;
        r_wait_cyc_r  = 0;

        // Arm ignore window: during this window, unknown BID/RID will be DROPPED (not error)
        ignore_unknown_until = $time + IGNORE_WINDOW;

        state_lock.put(1);

        `uvm_info("MON_CLR",
            $sformatf("State cleared (%s) ignore_unknown_until=%0t reset_active=%0b",
                      why, ignore_unknown_until, reset_active),
            UVM_LOW)
    endtask

    // ------------------------------------------------------------
    // Reset watchdogs (NO trigger here; reset_agent owns triggers)
    // ------------------------------------------------------------
    task reset_assert_watchdog();
        forever begin
            ev_reset_assert.wait_trigger();
            reset_active = 1'b1;
            clear_state("reset_assert(event)");
            `uvm_info("MON_RST", "Got axi_mm_reset_assert (listen) -> cleared state", UVM_LOW)
        end
    endtask

    task reset_deassert_watchdog();
        forever begin
            ev_reset_deassert.wait_trigger();
            reset_active = 1'b0;
            // keep ignore window running after deassert (already armed in clear_state)
            `uvm_info("MON_RST", "Got axi_mm_reset_deassert (listen)", UVM_LOW)
        end
    endtask

    // ------------------------------------------------------------
    // Flush watchdog
    // ------------------------------------------------------------
    task flush_watchdog();
        forever begin
            ev_flush.wait_trigger();
            clear_state("flush_event");
            #0; // IMPORTANT: avoid missed-trigger race
            ev_flush_done.trigger();
            `uvm_info("MON_FLUSH", "Flush handled -> trigger axi_mm_flush_done (delta)", UVM_LOW)
        end
    endtask

    // ------------------------------------------------------------
    // Address per beat (INCR/WRAP support) with size clamp
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
        int unsigned size_u;

        size_u = int'(size);
        if (size_u > MAX_SIZE_LOG2) bytes_per_beat = BYTES_PER_BEAT;
        else                        bytes_per_beat = (1 << size_u);

        total_beats = len + 1;
        wrap_bytes  = total_beats * bytes_per_beat;

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
    // Helper: find outstanding write by ID (for early-B)
    // ------------------------------------------------------------
    function automatic int find_wr_idx_by_id(input logic [ID_WIDTH-1:0] id);
        for (int i = 0; i < write_q.size(); i++) begin
            if (write_q[i].tr.id === id) return i;
        end
        return -1;
    endfunction

    // ------------------------------------------------------------
    // Helper: emit completed write
    // ------------------------------------------------------------
    task automatic complete_and_emit(ref aw_tr_t e);
        int unsigned expected_beats;
        expected_beats = e.tr.len + 1;

        if (!(e.w_done && e.b_seen)) return;

        e.tr.bresp = e.bresp;

        // record completion time for duplicate-B suppression
        state_lock.get(1);
        last_wr_done_time[id_key(e.tr.id)] = $time;
        state_lock.put(1);

        // stamp done_time as well (useful for debug)
        e.tr.done_time = $time;

        `uvm_info("MON_WR_DONE",
            $sformatf("WRITE completed: ID=%0d addr=0x%0h beats=%0d bresp=%0d done_time=%0t",
                      int'(e.tr.id), e.tr.addr, expected_beats, e.tr.bresp, e.tr.done_time),
            UVM_LOW)

        ap.write(e.tr);
    endtask

    // ============================================================
    // Write monitor
    // ============================================================
    task monitor_write();
        aw_tr_t tr_struct;
        int unsigned beat_idx;
        int unsigned expected_beats;
        logic [ADDR_WIDTH-1:0] beat_addr;

        // locals for B
        logic [ID_WIDTH-1:0] bid_l;
        int unsigned id_k;
        int idx;
        aw_tr_t tmp;
        bit have_tmp;

        // local latch: clear once per reset-entry even if event missed
        bit local_reset_active;

        // previous-cycle signals (avoid same-cycle ready/data race)
        bit                  bhs;
        bit                  bvalid_prev;
        bit                  bready_prev;
        logic [ID_WIDTH-1:0] bid_prev;
        logic [1:0]          bresp_prev;

        local_reset_active = 1'b0;

        // Prime prev signals once
        @(vif.cb_monitor);
        bvalid_prev = vif.cb_monitor.bvalid;
        bready_prev = vif.cb_monitor.bready;
        bid_prev    = vif.cb_monitor.bid;
        bresp_prev  = vif.cb_monitor.bresp;

        forever begin
            @(vif.cb_monitor);

            // reset entry debounce
            if (vif.cb_monitor.rst_n === 1'b0) begin
                // if reset_agent didn't trigger events, still gate drops correctly
                reset_active = 1'b1;

                if (!local_reset_active) begin
                    local_reset_active = 1'b1;
                    clear_state("in_reset(write)");
                end
                aw_wait_cyc_w = 0;

                // reset: force prev handshake low + clear prev payload
                bvalid_prev = 1'b0;
                bready_prev = 1'b0;
                bid_prev    = '0;
                bresp_prev  = '0;
                continue;
            end else begin
                local_reset_active = 1'b0;
            end

            // AW debug wait
            if ((vif.cb_monitor.awvalid === 1'b1) && (vif.cb_monitor.awready === 1'b0)) begin
                aw_wait_cyc_w++;
                if ((aw_wait_cyc_w % 100) == 0) begin
                    `uvm_info("MON_AW_WAIT",
                        $sformatf("AW waiting (%0d cyc): v=%0b r=%0b addr=0x%0h id=%0d len=%0d burst=%02b size=%0d",
                                aw_wait_cyc_w,
                                vif.cb_monitor.awvalid, vif.cb_monitor.awready,
                                vif.cb_monitor.awaddr,  vif.cb_monitor.awid,
                                vif.cb_monitor.awlen,   vif.cb_monitor.awburst,
                                vif.cb_monitor.awsize),
                        UVM_LOW)
                end
            end else begin
                aw_wait_cyc_w = 0;
            end

            // AW capture
            if ((vif.cb_monitor.awvalid === 1'b1) && (vif.cb_monitor.awready === 1'b1)) begin
                int unsigned q_depth_after;

                state_lock.get(1);

                tr_struct.tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create(
                    $sformatf("wr_tr_id_%0d", int'(vif.cb_monitor.awid)), this);

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
                tr_struct.w_done = 0;

                write_q.push_back(tr_struct);
                q_depth_after = write_q.size();

                state_lock.put(1);

                `uvm_info("MON_AW_HS",
                    $sformatf("AW HS: ID=%0d addr=0x%0h len=%0d burst=%02b size=%0d (q_depth=%0d)",
                            int'(tr_struct.tr.id), tr_struct.tr.addr, tr_struct.tr.len,
                            tr_struct.tr.burst, tr_struct.tr.size, q_depth_after),
                    UVM_LOW)
            end

            // W capture
            if ((vif.cb_monitor.wvalid === 1'b1) && (vif.cb_monitor.wready === 1'b1)) begin
                state_lock.get(1);

                if (write_q.size() == 0) begin
                    state_lock.put(1);
                    `uvm_error("MON",
                        $sformatf("W HS but write_q empty. WDATA=0x%0h WSTRB=0x%0h WLAST=%0b",
                                vif.cb_monitor.wdata, vif.cb_monitor.wstrb, vif.cb_monitor.wlast))
                end else begin
                    beat_idx       = write_q[0].beat_cnt;
                    expected_beats = write_q[0].tr.len + 1;

                    if (beat_idx >= expected_beats) begin
                        state_lock.put(1);
                        `uvm_error("MON",
                            $sformatf("Extra W beat on head. head_id=%0d exp=%0d got_beat=%0d WDATA=0x%0h WSTRB=0x%0h WLAST=%0b",
                                    int'(write_q[0].tr.id), expected_beats, beat_idx,
                                    vif.cb_monitor.wdata, vif.cb_monitor.wstrb, vif.cb_monitor.wlast))
                    end else begin
                        beat_addr = calc_beat_addr(write_q[0].tr.addr,
                                                write_q[0].tr.size,
                                                write_q[0].tr.len,
                                                write_q[0].tr.burst,
                                                beat_idx);

                        write_q[0].tr.wdata_beats[beat_idx]  = vif.cb_monitor.wdata;
                        write_q[0].tr.wstrb_beats[beat_idx] = vif.cb_monitor.wstrb;
                        write_q[0].beat_cnt++;

                        `uvm_info("MON_W_HS",
                            $sformatf("W HS: head_id=%0d beat=%0d/%0d addr=0x%0h data=0x%0h wstrb=0x%0h wlast=%0b",
                                    int'(write_q[0].tr.id), beat_idx, expected_beats, beat_addr,
                                    vif.cb_monitor.wdata, vif.cb_monitor.wstrb, vif.cb_monitor.wlast),
                            UVM_HIGH)

                        if (vif.cb_monitor.wlast === 1'b1) begin
                            aw_tr_t done_e;
                            int unsigned done_k;

                            if (write_q[0].beat_cnt != expected_beats) begin
                                `uvm_error("MON",
                                    $sformatf("WLAST mismatch. head_id=%0d seen_beats=%0d exp_beats=%0d",
                                            int'(write_q[0].tr.id), write_q[0].beat_cnt, expected_beats))
                            end

                            write_q[0].w_done = 1'b1;

                            done_e = write_q[0];
                            write_q.pop_front();

                            state_lock.put(1);

                            if (done_e.b_seen) begin
                                complete_and_emit(done_e);
                            end else begin
                                done_k = id_key(done_e.tr.id);
                                state_lock.get(1);
                                wait_b_s[done_k] = done_e;
                                state_lock.put(1);
                            end
                        end else begin
                            state_lock.put(1);
                        end
                    end
                end
            end

            // ------------------------------------------------------------
            // B capture (prev-cycle handshake + payload) with de-dup
            // IMPORTANT FIX: process EVERY handshake (no edge-detect),
            // otherwise back-to-back B handshakes get dropped.
            // ------------------------------------------------------------
            bhs = (bvalid_prev === 1'b1) && (bready_prev === 1'b1);

            if (bhs) begin
                have_tmp = 0;

                bid_l = bid_prev;
                id_k  = id_key(bid_l);

                state_lock.get(1);

                if (wait_b_s.exists(id_k)) begin
                    if (!wait_b_s[id_k].b_seen) begin
                        wait_b_s[id_k].b_seen = 1;
                        wait_b_s[id_k].bresp  = bresp_prev;
                        wait_b_s[id_k].bid    = bid_prev;
                    end else begin
                        `uvm_error("MON",
                            $sformatf("Duplicate B HS for BID=%0d (already in wait_b). bresp=%0d",
                                    int'(bid_l), bresp_prev))
                    end

                    tmp = wait_b_s[id_k];
                    wait_b_s.delete(id_k);
                    have_tmp = 1;

                    state_lock.put(1);

                    if (have_tmp) complete_and_emit(tmp);
                end else begin
                    idx = find_wr_idx_by_id(bid_l);

                    if (idx < 0) begin
                        int unsigned qd = write_q.size();

                        if (in_ignore_window()) begin
                            state_lock.put(1);
                            `uvm_info("MON_B_DROP",
                                $sformatf("Drop late/stray B during reset/flush window: BID=%0d bresp=%0d q_depth=%0d (ignore_until=%0t reset_active=%0b)",
                                        int'(bid_l), bresp_prev, qd, ignore_unknown_until, reset_active),
                                UVM_LOW)
                        end
                        else if (in_dup_b_window(id_k)) begin
                            time dt = $time - last_wr_done_time[id_k];
                            state_lock.put(1);
                            `uvm_info("MON_B_DUP_DROP",
                                $sformatf("Drop DUP/late B after write completion: BID=%0d bresp=%0d dt=%0t q_depth=%0d",
                                        int'(bid_l), bresp_prev, dt, qd),
                                UVM_LOW)
                        end
                        else begin
                            state_lock.put(1);
                            `uvm_error("MON",
                                $sformatf("B HS for unknown BID=%0d (no matching AW yet). bresp=%0d q_depth=%0d",
                                        int'(bid_l), bresp_prev, qd))
                        end
                    end else begin
                        if (!write_q[idx].b_seen) begin
                            write_q[idx].b_seen = 1;
                            write_q[idx].bresp  = bresp_prev;
                            write_q[idx].bid    = bid_prev;
                        end else begin
                            `uvm_error("MON",
                                $sformatf("Duplicate B HS for BID=%0d (already seen). bresp=%0d",
                                        int'(bid_l), bresp_prev))
                        end

                        expected_beats = write_q[idx].tr.len + 1;
                        if (write_q[idx].beat_cnt != expected_beats) begin
                            `uvm_info("MON_B_EARLY",
                                $sformatf("B arrived early (stored). BID=%0d beats=%0d/%0d",
                                        int'(bid_l), write_q[idx].beat_cnt, expected_beats),
                                UVM_LOW)
                        end

                        state_lock.put(1);
                    end
                end
            end

            // Update prev at end of loop
            bvalid_prev = vif.cb_monitor.bvalid;
            bready_prev = vif.cb_monitor.bready;
            bid_prev    = vif.cb_monitor.bid;
            bresp_prev  = vif.cb_monitor.bresp;
        end
    endtask

    // ============================================================
    // Read monitor
    // ============================================================
    task monitor_read();
        int unsigned id_k;
        int unsigned beat_idx;
        int unsigned expected_beats;
        logic [ADDR_WIDTH-1:0] beat_addr;

        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) done_tr;
        bit have_done;

        bit local_reset_active;
        local_reset_active = 1'b0;

        forever begin
            @(vif.cb_monitor);

            // reset entry debounce
            if (vif.cb_monitor.rst_n === 1'b0) begin
                // if reset_agent didn't trigger events, still gate drops correctly
                reset_active = 1'b1;

                if (!local_reset_active) begin
                    local_reset_active = 1'b1;
                    clear_state("in_reset(read)");
                end
                ar_wait_cyc_r = 0;
                r_wait_cyc_r  = 0;
                continue;
            end else begin
                local_reset_active = 1'b0;
            end

            // AR debug wait
            if ((vif.cb_monitor.arvalid === 1'b1) && (vif.cb_monitor.arready === 1'b0)) begin
                ar_wait_cyc_r++;
                if ((ar_wait_cyc_r % 100) == 0) begin
                    `uvm_info("MON_AR_WAIT",
                        $sformatf("AR waiting (%0d cyc): v=%0b r=%0b addr=0x%0h id=%0d len=%0d burst=%02b size=%0d",
                                ar_wait_cyc_r,
                                vif.cb_monitor.arvalid, vif.cb_monitor.arready,
                                vif.cb_monitor.araddr,  vif.cb_monitor.arid,
                                vif.cb_monitor.arlen,   vif.cb_monitor.arburst,
                                vif.cb_monitor.arsize),
                        UVM_LOW)
                end
            end else begin
                ar_wait_cyc_r = 0;
            end

            // AR capture
            if ((vif.cb_monitor.arvalid === 1'b1) && (vif.cb_monitor.arready === 1'b1)) begin
                int unsigned pending_cnt_after;
                ar_tr_t new_e;

                id_k = id_key(vif.cb_monitor.arid);

                // Build fully initialized entry (avoid X/partial struct)
                new_e.tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create(
                    $sformatf("rd_tr_id_%0d", int'(vif.cb_monitor.arid)), this);

                new_e.tr.rw    = AXI_READ;
                new_e.tr.addr  = vif.cb_monitor.araddr;
                new_e.tr.id    = vif.cb_monitor.arid;
                new_e.tr.len   = vif.cb_monitor.arlen;
                new_e.tr.size  = vif.cb_monitor.arsize;
                new_e.tr.burst = vif.cb_monitor.arburst;

                new_e.tr.set_beats_len(new_e.tr.len);
                new_e.beat_cnt = 0;

                state_lock.get(1);

                if (pending_reads_s.exists(id_k)) begin
                    state_lock.put(1);
                    `uvm_error("MON", $sformatf("AR received while read pending ID=%0d", id_k))
                end else begin
                    pending_reads_s[id_k] = new_e;
                    pending_cnt_after = pending_reads_s.num();
                    state_lock.put(1);

                    `uvm_info("MON_AR_HS",
                        $sformatf("AR HS: ID=%0d addr=0x%0h len=%0d burst=%02b size=%0d (pending=%0d)",
                                int'(vif.cb_monitor.arid), vif.cb_monitor.araddr, vif.cb_monitor.arlen,
                                vif.cb_monitor.arburst, vif.cb_monitor.arsize,
                                pending_cnt_after),
                        UVM_LOW)
                end
            end

            // R debug wait
            if ((vif.cb_monitor.rvalid === 1'b1) && (vif.cb_monitor.rready === 1'b0)) begin
                r_wait_cyc_r++;
                if ((r_wait_cyc_r % 100) == 0) begin
                    `uvm_info("MON_R_WAIT",
                        $sformatf("R waiting (%0d cyc): v=%0b r=%0b rid=%0d rlast=%0b rresp=%0b rdata=0x%0h",
                                r_wait_cyc_r,
                                vif.cb_monitor.rvalid, vif.cb_monitor.rready,
                                int'(vif.cb_monitor.rid), vif.cb_monitor.rlast,
                                vif.cb_monitor.rresp, vif.cb_monitor.rdata),
                        UVM_LOW)
                end
            end else begin
                r_wait_cyc_r = 0;
            end

            // R capture
            if ((vif.cb_monitor.rvalid === 1'b1) && (vif.cb_monitor.rready === 1'b1)) begin
                have_done = 0;
                done_tr   = null;

                id_k = id_key(vif.cb_monitor.rid);

                state_lock.get(1);

                if (!pending_reads_s.exists(id_k)) begin
                    if (in_ignore_window()) begin
                        state_lock.put(1);
                        `uvm_info("MON_R_DROP",
                            $sformatf("Drop late/stray R during reset/flush window: RID=%0d rlast=%0b rresp=%0b rdata=0x%0h (ignore_until=%0t reset_active=%0b)",
                                    int'(vif.cb_monitor.rid), vif.cb_monitor.rlast, vif.cb_monitor.rresp, vif.cb_monitor.rdata,
                                    ignore_unknown_until, reset_active),
                            UVM_LOW)
                    end else begin
                        state_lock.put(1);
                        `uvm_error("MON", $sformatf("R for unknown ID %0d (no pending AR)", id_k))
                    end
                end else begin
                    expected_beats = pending_reads_s[id_k].tr.len + 1;
                    beat_idx       = pending_reads_s[id_k].beat_cnt;

                    beat_addr = calc_beat_addr(pending_reads_s[id_k].tr.addr,
                                            pending_reads_s[id_k].tr.size,
                                            pending_reads_s[id_k].tr.len,
                                            pending_reads_s[id_k].tr.burst,
                                            beat_idx);

                    if (beat_idx < expected_beats) begin
                        pending_reads_s[id_k].tr.rdata_beats[beat_idx] = vif.cb_monitor.rdata;
                        pending_reads_s[id_k].tr.rresp_beats[beat_idx] = vif.cb_monitor.rresp;

                        // IMPORTANT: per-beat timestamp (scoreboard uses this!)
                        pending_reads_s[id_k].tr.rtime_beats[beat_idx] = $time;

                        pending_reads_s[id_k].beat_cnt++;

                        `uvm_info("MON_R_HS",
                            $sformatf("R HS: ID=%0d beat=%0d/%0d addr=0x%0h data=0x%0h rresp=%0b rlast=%0b",
                                    int'(vif.cb_monitor.rid), beat_idx, expected_beats, beat_addr,
                                    vif.cb_monitor.rdata, vif.cb_monitor.rresp, vif.cb_monitor.rlast),
                            UVM_HIGH)
                    end else begin
                        `uvm_error("MON",
                            $sformatf("Extra R beat. ID=%0d beat=%0d exp=%0d addr=0x%0h data=0x%0h rresp=%0b rlast=%0b",
                                    int'(vif.cb_monitor.rid), beat_idx, expected_beats, beat_addr,
                                    vif.cb_monitor.rdata, vif.cb_monitor.rresp, vif.cb_monitor.rlast))
                    end

                    if (vif.cb_monitor.rlast === 1'b1) begin
                        if (pending_reads_s[id_k].beat_cnt != expected_beats) begin
                            `uvm_error("MON",
                                $sformatf("RLAST early/late. ID=%0d beats=%0d/%0d",
                                        int'(vif.cb_monitor.rid), pending_reads_s[id_k].beat_cnt, expected_beats))
                        end

                        // stamp txn done_time at RLAST
                        pending_reads_s[id_k].tr.done_time = $time;

                        done_tr = pending_reads_s[id_k].tr;
                        pending_reads_s.delete(id_k);
                        have_done = 1;
                    end

                    state_lock.put(1);

                    if (have_done) begin
                        `uvm_info("MON_RD_DONE",
                            $sformatf("READ completed: ID=%0d addr=0x%0h beats=%0d done_time=%0t",
                                      int'(done_tr.id), done_tr.addr, (done_tr.len+1), done_tr.done_time),
                            UVM_LOW)
                        ap.write(done_tr);
                    end
                end
            end
        end
    endtask

endclass

`endif