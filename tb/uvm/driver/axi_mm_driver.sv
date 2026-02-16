`ifndef AXI_MM_DRIVER_SV
`define AXI_MM_DRIVER_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

class axi_mm_driver #(
    int ADDR_WIDTH   = 32,
    int DATA_WIDTH   = 64,
    int ID_WIDTH     = 4,
    int WAIT_TIMEOUT = 1000
) extends uvm_driver #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH));

    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_master vif;

    `uvm_component_param_utils(axi_mm_driver #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, WAIT_TIMEOUT))

    // ----------------------------
    // knobs
    // ----------------------------
    bit hold_bready_high = 1;
    bit hold_rready_high = 1;

    bit stress_enable = 0;
    int unsigned bready_prob = 100;
    int unsigned rready_prob = 100;

    int unsigned aw_pre_delay_max = 0;
    int unsigned ar_pre_delay_max = 0;

    bit          w_streaming_mode = 0;
    int unsigned w_beat_gap_max   = 0;

    int unsigned force_ready_after = 64;
    int unsigned stress_seed = 0;

    // ----------------------------
    // latches (debug)
    // ----------------------------
    logic [ADDR_WIDTH-1:0] aw_addr_lat;
    logic [7:0]            aw_len_lat;
    logic [2:0]            aw_size_lat;
    logic [1:0]            aw_burst_lat;
    logic [ID_WIDTH-1:0]   aw_id_lat;

    logic [ADDR_WIDTH-1:0] ar_addr_lat;
    logic [7:0]            ar_len_lat;
    logic [2:0]            ar_size_lat;
    logic [1:0]            ar_burst_lat;
    logic [ID_WIDTH-1:0]   ar_id_lat;

    // ----------------------------
    // B response storage (by ID)
    //
    // IMPORTANT (FIXED):
    // - b_count[id] now means: number of *unconsumed* B responses for that ID
    // - b_seen[id] is kept consistent with (b_count[id] > 0)
    // ----------------------------
    bit          b_seen       [logic [ID_WIDTH-1:0]];
    logic [1:0]  b_resp_store [logic [ID_WIDTH-1:0]];
    int unsigned b_count      [logic [ID_WIDTH-1:0]];

    // ------------------------------------------------------------
    // Generic reset/flush event interface (Case C10)
    // ------------------------------------------------------------
    uvm_event ev_reset_assert;
    uvm_event ev_reset_deassert;
    uvm_event ev_flush;
    uvm_event ev_flush_done;

    // driver state
    bit in_reset;
    bit abort_drive;
    bit in_flush;

    // SAFETY: track whether we currently own an outstanding request from sequencer
    bit have_item;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(
                virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_master
            )::get(this, "", "vif", vif)) begin
            `uvm_fatal("NOVIF", "axi_mm_driver: virtual interface (mp_master) not set (key=vif)")
        end

        void'(uvm_config_db#(bit)::get(this, "", "hold_bready_high", hold_bready_high));
        void'(uvm_config_db#(bit)::get(this, "", "hold_rready_high", hold_rready_high));

        void'(uvm_config_db#(bit)::get(this, "", "stress_enable", stress_enable));
        void'(uvm_config_db#(int unsigned)::get(this, "", "bready_prob", bready_prob));
        void'(uvm_config_db#(int unsigned)::get(this, "", "rready_prob", rready_prob));
        void'(uvm_config_db#(int unsigned)::get(this, "", "aw_pre_delay_max", aw_pre_delay_max));
        void'(uvm_config_db#(int unsigned)::get(this, "", "ar_pre_delay_max", ar_pre_delay_max));
        void'(uvm_config_db#(bit)::get(this, "", "w_streaming_mode", w_streaming_mode));
        void'(uvm_config_db#(int unsigned)::get(this, "", "w_beat_gap_max", w_beat_gap_max));
        void'(uvm_config_db#(int unsigned)::get(this, "", "force_ready_after", force_ready_after));
        void'(uvm_config_db#(int unsigned)::get(this, "", "stress_seed", stress_seed));

        if (bready_prob > 100) bready_prob = 100;
        if (rready_prob > 100) rready_prob = 100;

        ev_reset_assert   = uvm_event_pool::get_global("axi_mm_reset_assert");
        ev_reset_deassert = uvm_event_pool::get_global("axi_mm_reset_deassert");
        ev_flush          = uvm_event_pool::get_global("axi_mm_flush");
        ev_flush_done     = uvm_event_pool::get_global("axi_mm_flush_done");

        in_reset    = 1'b0;
        abort_drive = 1'b0;
        in_flush    = 1'b0;
        have_item   = 1'b0;
    endfunction

    // ------------------------------------------------------------
    // tiny helpers
    // ------------------------------------------------------------
    function automatic bit is_reset();
        return (vif.cb_master.rst_n !== 1'b1);
    endfunction

    function automatic bit should_abort();
        return abort_drive;
    endfunction

    function bit check_beats(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats = tr.len + 1;
        if (tr.rw == AXI_WRITE) begin
            if (tr.data_beats.size()  != beats) return 0;
            if (tr.wstrb_beats.size() != beats) return 0;
        end
        return 1;
    endfunction

    // ------------------------------------------------------------
    // bus / state utilities
    // ------------------------------------------------------------
    task automatic clear_driver_state(string why);
        b_seen.delete();
        b_resp_store.delete();
        b_count.delete();
        `uvm_info("DRV_CLR", $sformatf("Driver state cleared (%s)", why), UVM_LOW)
    endtask

    // Normal idle policy (may keep ready high if configured)
    task automatic drive_idle_now();
        vif.cb_master.awvalid <= 1'b0;
        vif.cb_master.arvalid <= 1'b0;

        vif.cb_master.wvalid  <= 1'b0;
        vif.cb_master.wlast   <= 1'b0;
        vif.cb_master.wdata   <= '0;
        vif.cb_master.wstrb   <= '0;

        vif.cb_master.bready  <= (hold_bready_high) ? 1'b1 : 1'b0;
        vif.cb_master.rready  <= (hold_rready_high) ? 1'b1 : 1'b0;
    endtask

    // Abort/reset safe idle (DO NOT consume responses)
    task automatic drive_idle_abort();
        vif.cb_master.awvalid <= 1'b0;
        vif.cb_master.arvalid <= 1'b0;

        vif.cb_master.wvalid  <= 1'b0;
        vif.cb_master.wlast   <= 1'b0;
        vif.cb_master.wdata   <= '0;
        vif.cb_master.wstrb   <= '0;

        vif.cb_master.bready  <= 1'b0;
        vif.cb_master.rready  <= 1'b0;
    endtask

    task automatic init_signals();
        @(vif.cb_master);
        drive_idle_now();
        clear_driver_state("init_signals");
        if (stress_seed != 0) void'($urandom(stress_seed));
    endtask

    task automatic wait_reset_release();
        @(vif.cb_master);
        while (vif.cb_master.rst_n !== 1'b1) @(vif.cb_master);
        @(vif.cb_master);
    endtask

    // ------------------------------------------------------------
    // stress helpers
    // ------------------------------------------------------------
    function automatic bit roll_prob(int unsigned prob_0_to_100);
        if (prob_0_to_100 >= 100) return 1;
        if (prob_0_to_100 == 0)   return 0;
        return ($urandom_range(0,99) < prob_0_to_100);
    endfunction

    task automatic update_bready(input int unsigned wait_cyc);
        if (should_abort() || is_reset()) begin
            vif.cb_master.bready <= 1'b0;
            return;
        end

        // -----------------------------
        // Non-stress default policy
        // -----------------------------
        if (!stress_enable) begin
            // default accept responses
            vif.cb_master.bready <= (hold_bready_high) ? 1'b1 : 1'b1;
            return;
        end

        // -----------------------------
        // Stress mode (probability)
        // -----------------------------
        if (hold_bready_high) begin
            // If hold_bready_high is meant to override everything:
            vif.cb_master.bready <= 1'b1;
            return;
        end

        if (wait_cyc >= force_ready_after) vif.cb_master.bready <= 1'b1;
        else                               vif.cb_master.bready <= roll_prob(bready_prob);
    endtask


    task automatic update_rready(input int unsigned wait_cyc);
        if (should_abort() || is_reset()) begin
            vif.cb_master.rready <= 1'b0;
            return;
        end
        if (hold_rready_high && !stress_enable) begin
            vif.cb_master.rready <= 1'b1;
            return;
        end
        if (!stress_enable) return;

        if (wait_cyc >= force_ready_after) vif.cb_master.rready <= 1'b1;
        else                               vif.cb_master.rready <= roll_prob(rready_prob);
    endtask

    task automatic maybe_wait_cycles(int unsigned max_cycles);
        int unsigned d;
        if (!stress_enable || max_cycles == 0) return;
        d = $urandom_range(0, max_cycles);
        repeat (d) begin
            @(vif.cb_master);
            if (should_abort() || is_reset()) return;
        end
    endtask

    // ------------------------------------------------------------
    // Robust event wait (avoid missing pulse-style uvm_event)
    // ------------------------------------------------------------
    task automatic wait_event_after(uvm_event ev, time t0);
        time t;
        t = ev.get_trigger_time();
        if (t > t0) return;

        do begin
            ev.wait_trigger();
            t = ev.get_trigger_time();
        end while (t <= t0);
    endtask

    // ------------------------------------------------------------
    // IMPORTANT: drain sequencer FIFO safely during reset/flush
    // - This replaces stop_sequences() (which breaks bookkeeping)
    // - We keep pulling queued items and immediately item_done() them
    // ------------------------------------------------------------
    task automatic drain_sequencer_fifo(string why, int unsigned max_drain = 100000);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr_d;
        int unsigned n;

        n = 0;

        // non-blocking drain (UVM 1.1d style)
        forever begin
            tr_d = null;

            // try_next_item is a TASK (non-blocking)
            seq_item_port.try_next_item(tr_d);

            // no item available -> done draining
            if (tr_d == null)
                break;

            n++;

            `uvm_info("DRV_DRAIN",
                $sformatf("Drain item (%s): rw=%0d op=%0d addr=0x%0h id=%0d (drain_cnt=%0d)",
                        why, tr_d.rw, tr_d.op_kind, tr_d.addr, tr_d.id, n),
                UVM_LOW)

            // Pairing: only call item_done() when you actually got an item
            seq_item_port.item_done();

            if (n >= max_drain) begin
                `uvm_warning("DRV_DRAIN",
                    $sformatf("Drain reached max_drain=%0d, stop draining to avoid infinite loop (%s)",
                            max_drain, why))
                break;
            end
        end
    endtask

    // ------------------------------------------------------------
    // Reset/Flush subscribers (robust)
    // ------------------------------------------------------------
    task automatic reset_subscriber();
        time t_rst;

        forever begin
            ev_reset_assert.wait_trigger();
            t_rst = ev_reset_assert.get_trigger_time();

            abort_drive = 1'b1;
            in_reset    = 1'b1;

            @(vif.cb_master);
            drive_idle_abort();
            clear_driver_state("reset_assert");

            `uvm_info("DRV_RST", "Got axi_mm_reset_assert -> abort_drive=1, in_reset=1", UVM_LOW)

            wait_event_after(ev_reset_deassert, t_rst);

            `uvm_info("DRV_RST", "Got axi_mm_reset_deassert (matched to last assert)", UVM_LOW)

            in_reset = 1'b0;
            // NOTE: abort_drive will be cleared by run_phase recovery gate
        end
    endtask

    task automatic flush_subscriber();
        time t_flush;

        forever begin
            ev_flush.wait_trigger();
            t_flush = ev_flush.get_trigger_time();

            abort_drive = 1'b1;
            in_flush    = 1'b1;

            @(vif.cb_master);
            drive_idle_abort();
            clear_driver_state("flush_event");

            `uvm_info("DRV_FLUSH", "Got axi_mm_flush -> abort_drive=1, in_flush=1", UVM_LOW)

            wait_event_after(ev_flush_done, t_flush);

            in_flush = 1'b0;
            `uvm_info("DRV_FLUSH", "Got axi_mm_flush_done (matched to last flush)", UVM_LOW)
        end
    endtask

    // ------------------------------------------------------------
    // Background B collector (reset/flush aware) - deglitched + dedup
    // ------------------------------------------------------------
    task automatic b_collector();
        int unsigned cyc;

        // prev-cycle samples (to avoid same-cycle race)
        bit                  bvalid_prev;
        bit                  bready_prev;
        logic [ID_WIDTH-1:0] bid_prev;
        logic [1:0]          bresp_prev;

        // handshake de-dup latch: if (bvalid&bready) stays high, count only once
        bit hs_hold;
        bit hs_prev;

        cyc     = 0;
        hs_hold = 1'b0;

        // prime prev signals once
        @(vif.cb_master);
        update_bready(cyc);
        bvalid_prev = vif.cb_master.bvalid;
        bready_prev = vif.cb_master.bready;
        bid_prev    = vif.cb_master.bid;
        bresp_prev  = vif.cb_master.bresp;

        forever begin
            @(vif.cb_master);

            if (is_reset() || should_abort()) begin
                cyc = 0;
                update_bready(cyc);

                // clear prev + dedup latch
                bvalid_prev = 1'b0;
                bready_prev = 1'b0;
                bid_prev    = '0;
                bresp_prev  = '0;
                hs_hold     = 1'b0;
                continue;
            end

            // Evaluate previous-cycle handshake
            hs_prev = (bvalid_prev === 1'b1) && (bready_prev === 1'b1);

            // De-dup: only count on first cycle entering hs_prev==1
            if (hs_prev && !hs_hold) begin
                logic [ID_WIDTH-1:0] id_got;
                logic [1:0]          resp_got;

                id_got   = bid_prev;    // use prev payload
                resp_got = bresp_prev;

                if (!b_count.exists(id_got)) b_count[id_got] = 0;
                b_count[id_got]++;

                b_resp_store[id_got] = resp_got;
                b_seen[id_got]       = 1'b1;

                `uvm_info("DRV_B",
                    $sformatf("B_COLLECT: HS bid=%0d bresp=%0d (pending_count[%0d]=%0d)",
                            id_got, resp_got, id_got, b_count[id_got]),
                    UVM_HIGH)

                hs_hold = 1'b1; // latch until hs_prev goes low
            end
            else if (!hs_prev) begin
                hs_hold = 1'b0;
            end

            // advance cycle + drive next-cycle bready policy
            cyc++;
            update_bready(cyc);

            // update prev samples at end of loop
            bvalid_prev = vif.cb_master.bvalid;
            bready_prev = vif.cb_master.bready;
            bid_prev    = vif.cb_master.bid;
            bresp_prev  = vif.cb_master.bresp;
        end
    endtask




    // knob: enable strict checking for B consume
    bit strict_consume_b = 1'b1;

    // ------------------------------------------------------------
    // Helper: consume exactly one pending B for a given ID
    // ------------------------------------------------------------
    task automatic consume_one_b(input logic [ID_WIDTH-1:0] bid);
        // Missing key or zero count -> suspicious
        if (!b_count.exists(bid)) begin
            if (strict_consume_b) begin
                `uvm_error("DRV_B",
                    $sformatf("consume_one_b: b_count key NOT exist for ID=%0d (b_seen=%0b). Possible consume-before-collect or bookkeeping bug.",
                            int'(bid),
                            (b_seen.exists(bid) ? b_seen[bid] : 1'b0)))
            end
            return;
        end

        if (b_count[bid] == 0) begin
            if (strict_consume_b) begin
                `uvm_error("DRV_B",
                    $sformatf("consume_one_b: b_count already 0 for ID=%0d (b_seen=%0b). Possible double-consume.",
                            int'(bid),
                            (b_seen.exists(bid) ? b_seen[bid] : 1'b0)))
            end
            return;
        end

        // Normal consume
        b_count[bid]--;

        if (b_count[bid] == 0) begin
            b_seen[bid] = 1'b0;
        end

        `uvm_info("DRV_B",
            $sformatf("consume_one_b: ID=%0d -> remaining b_count=%0d b_seen=%0b",
                    int'(bid), b_count[bid], b_seen[bid]),
            UVM_HIGH)
    endtask


    // ------------------------------------------------------------
    // AW_ONLY
    // ------------------------------------------------------------
    task automatic drive_aw_only(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        bit aw_hs;
        aw_hs = 0;

        maybe_wait_cycles(aw_pre_delay_max);
        if (is_reset() || should_abort()) begin
            @(vif.cb_master);
            drive_idle_abort();
            return;
        end

        @(vif.cb_master);
        if (is_reset() || should_abort()) begin
            drive_idle_abort();
            return;
        end

        vif.cb_master.awvalid <= 1'b1;
        vif.cb_master.awaddr  <= tr.addr;
        vif.cb_master.awlen   <= tr.len;
        vif.cb_master.awsize  <= tr.size;
        vif.cb_master.awburst <= tr.burst;
        vif.cb_master.awid    <= tr.id;

        for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
            @(vif.cb_master);

            if (is_reset() || should_abort()) begin
                vif.cb_master.awvalid <= 1'b0;
                return;
            end

            if ((vif.cb_master.awvalid === 1'b1) && (vif.cb_master.awready === 1'b1)) begin
                aw_hs = 1;
                aw_addr_lat  = vif.cb_master.awaddr;
                aw_len_lat   = vif.cb_master.awlen;
                aw_size_lat  = vif.cb_master.awsize;
                aw_burst_lat = vif.cb_master.awburst;
                aw_id_lat    = vif.cb_master.awid;

                vif.cb_master.awvalid <= 1'b0;
                break;
            end
        end

        if (!aw_hs) begin
            vif.cb_master.awvalid <= 1'b0;
            `uvm_fatal("HS_TIMEOUT",
                $sformatf("AW_ONLY TIMEOUT (%0d cycles). addr=0x%0h id=%0d", WAIT_TIMEOUT, tr.addr, tr.id))
        end
    endtask

    // ------------------------------------------------------------
    // W_ONLY
    // ------------------------------------------------------------
    task automatic drive_w_only(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats;
        beats = tr.len + 1;

        if (tr.data_beats.size() != beats || tr.wstrb_beats.size() != beats) begin
            `uvm_fatal("DRV_ITEM",
                $sformatf("W_ONLY bad payload size: beats=%0d data=%0d wstrb=%0d (addr=0x%0h id=%0d)",
                          beats, tr.data_beats.size(), tr.wstrb_beats.size(), tr.addr, tr.id))
        end

        for (int i = 0; i < beats; i++) begin
            bit w_hs;
            w_hs = 0;

            maybe_wait_cycles(w_beat_gap_max);
            if (is_reset() || should_abort()) begin
                @(vif.cb_master);
                drive_idle_abort();
                return;
            end

            @(vif.cb_master);
            if (is_reset() || should_abort()) begin
                drive_idle_abort();
                return;
            end

            vif.cb_master.wvalid <= 1'b1;
            vif.cb_master.wdata  <= tr.data_beats[i];
            vif.cb_master.wstrb  <= tr.wstrb_beats[i];
            vif.cb_master.wlast  <= (i == beats-1);

            for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                @(vif.cb_master);

                if (is_reset() || should_abort()) begin
                    vif.cb_master.wvalid <= 1'b0;
                    vif.cb_master.wlast  <= 1'b0;
                    return;
                end

                if ((vif.cb_master.wvalid === 1'b1) && (vif.cb_master.wready === 1'b1)) begin
                    w_hs = 1;
                    vif.cb_master.wvalid <= 1'b0;
                    vif.cb_master.wlast  <= 1'b0;
                    break;
                end
            end

            if (!w_hs) begin
                vif.cb_master.wvalid <= 1'b0;
                vif.cb_master.wlast  <= 1'b0;
                `uvm_fatal("HS_TIMEOUT",
                    $sformatf("W_ONLY TIMEOUT (%0d cycles). addr=0x%0h id=%0d beat=%0d",
                              WAIT_TIMEOUT, tr.addr, tr.id, i))
            end
        end
    endtask

    // ------------------------------------------------------------
    // B_WAIT (consume exactly one pending B for wait_bid)
    // ------------------------------------------------------------
    task automatic wait_b_only(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        bit got;
        got = 0;

        if (is_reset() || should_abort()) begin
            tr.bresp = '0;
            return;
        end

        // Fast path: already pending
        if (b_count.exists(tr.wait_bid) && (b_count[tr.wait_bid] > 0)) begin
            got = 1;
        end else begin
            for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                @(vif.cb_master);
                if (is_reset() || should_abort()) begin
                    tr.bresp = '0;
                    return;
                end
                if (b_count.exists(tr.wait_bid) && (b_count[tr.wait_bid] > 0)) begin
                    got = 1;
                    break;
                end
            end
        end

        if (!got) begin
            `uvm_fatal("HS_TIMEOUT",
                $sformatf("B_WAIT TIMEOUT (%0d cycles). wait_bid=%0d (addr=0x%0h id=%0d op_kind=%0d)",
                          WAIT_TIMEOUT, tr.wait_bid, tr.addr, tr.id, tr.op_kind))
        end

        tr.bresp = b_resp_store[tr.wait_bid];

        // Consume exactly one pending B for this ID (FIXED)
        consume_one_b(tr.wait_bid);
    endtask

    // ------------------------------------------------------------
    // OP_FULL write: AW + W + wait B (consume exactly one B for tr.id)
    // ------------------------------------------------------------
    task automatic drive_write(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats;
        bit aw_hs;

        beats = tr.len + 1;
        aw_hs = 0;

        if (tr.data_beats.size() != beats || tr.wstrb_beats.size() != beats) begin
            `uvm_fatal("DRV_ITEM",
                $sformatf("Bad payload array size: beats=%0d data=%0d wstrb=%0d (addr=0x%0h id=%0d)",
                          beats, tr.data_beats.size(), tr.wstrb_beats.size(), tr.addr, tr.id))
        end

        // Now this warning is meaningful: it indicates you have unconsumed B(s) for this ID
        if (b_count.exists(tr.id) && (b_count[tr.id] > 0)) begin
            `uvm_warning("DRV_ID",
                $sformatf("Reusing ID=%0d while pending unconsumed B count=%0d. (Likely missing B_WAIT/consume in your test)",
                          tr.id, b_count[tr.id]))
        end

        // Make sure keys exist and consistent
        if (!b_count.exists(tr.id)) b_count[tr.id] = 0;
        if (b_count[tr.id] == 0) b_seen[tr.id] = 1'b0;

        maybe_wait_cycles(aw_pre_delay_max);
        if (is_reset() || should_abort()) begin
            @(vif.cb_master);
            drive_idle_abort();
            return;
        end

        @(vif.cb_master);
        if (is_reset() || should_abort()) begin
            drive_idle_abort();
            return;
        end

        // AW
        vif.cb_master.awvalid <= 1'b1;
        vif.cb_master.awaddr  <= tr.addr;
        vif.cb_master.awlen   <= tr.len;
        vif.cb_master.awsize  <= tr.size;
        vif.cb_master.awburst <= tr.burst;
        vif.cb_master.awid    <= tr.id;

        for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
            @(vif.cb_master);

            if (is_reset() || should_abort()) begin
                vif.cb_master.awvalid <= 1'b0;
                return;
            end

            if ((vif.cb_master.awvalid === 1'b1) && (vif.cb_master.awready === 1'b1)) begin
                aw_hs = 1;
                aw_addr_lat  = vif.cb_master.awaddr;
                aw_len_lat   = vif.cb_master.awlen;
                aw_size_lat  = vif.cb_master.awsize;
                aw_burst_lat = vif.cb_master.awburst;
                aw_id_lat    = vif.cb_master.awid;

                vif.cb_master.awvalid <= 1'b0;
                break;
            end
        end

        if (!aw_hs) begin
            vif.cb_master.awvalid <= 1'b0;
            `uvm_fatal("HS_TIMEOUT",
                $sformatf("AW TIMEOUT (%0d cycles). addr=0x%0h id=%0d", WAIT_TIMEOUT, tr.addr, tr.id))
        end

        // W
        drive_w_only(tr);
        if (is_reset() || should_abort()) return;

        // B wait by ID (wait until at least one pending B arrives)
        begin
            bit got;
            got = 0;

            for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                @(vif.cb_master);
                if (is_reset() || should_abort()) begin
                    tr.bresp = '0;
                    return;
                end
                if (b_count.exists(tr.id) && (b_count[tr.id] > 0)) begin
                    got = 1;
                    break;
                end
            end

            if (!got) begin
                `uvm_fatal("HS_TIMEOUT",
                    $sformatf("B(by-id) TIMEOUT (%0d cycles). addr=0x%0h id=%0d",
                              WAIT_TIMEOUT, tr.addr, tr.id))
            end
        end

        tr.bresp = b_resp_store[tr.id];

        // Consume exactly one pending B for this ID
        consume_one_b(tr.id);

        // If still pending, that's suspicious (duplicate B or double-count)
        if (b_count.exists(tr.id) && (b_count[tr.id] > 0)) begin
            `uvm_error("DRV_B",
                $sformatf("After consuming one B, still pending B(s) for ID=%0d: b_count=%0d. Possible DUPLICATE B or collector double-count.",
                        int'(tr.id), b_count[tr.id]))
        end
    endtask

    // ------------------------------------------------------------
    // READ: AR + R beats
    // ------------------------------------------------------------
    task automatic drive_read(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats;
        bit ar_hs;

        beats = tr.len + 1;
        ar_hs = 0;

        maybe_wait_cycles(ar_pre_delay_max);
        if (is_reset() || should_abort()) begin
            @(vif.cb_master);
            drive_idle_abort();
            return;
        end

        @(vif.cb_master);
        if (is_reset() || should_abort()) begin
            drive_idle_abort();
            return;
        end

        // AR
        vif.cb_master.arvalid <= 1'b1;
        vif.cb_master.araddr  <= tr.addr;
        vif.cb_master.arlen   <= tr.len;
        vif.cb_master.arsize  <= tr.size;
        vif.cb_master.arburst <= tr.burst;
        vif.cb_master.arid    <= tr.id;

        for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
            @(vif.cb_master);

            if (is_reset() || should_abort()) begin
                vif.cb_master.arvalid <= 1'b0;
                return;
            end

            if ((vif.cb_master.arvalid === 1'b1) && (vif.cb_master.arready === 1'b1)) begin
                ar_hs = 1;
                ar_addr_lat  = vif.cb_master.araddr;
                ar_len_lat   = vif.cb_master.arlen;
                ar_size_lat  = vif.cb_master.arsize;
                ar_burst_lat = vif.cb_master.arburst;
                ar_id_lat    = vif.cb_master.arid;

                vif.cb_master.arvalid <= 1'b0;
                break;
            end
        end

        if (!ar_hs) begin
            vif.cb_master.arvalid <= 1'b0;
            `uvm_fatal("HS_TIMEOUT",
                $sformatf("AR TIMEOUT (%0d cycles). addr=0x%0h id=%0d", WAIT_TIMEOUT, tr.addr, tr.id))
        end

        // R channel ready policy
        if (!hold_rready_high) begin
            @(vif.cb_master);
            vif.cb_master.rready <= 1'b0;
        end
        update_rready(0);

        // R beats
        for (int i = 0; i < beats; i++) begin
            bit r_hs;
            r_hs = 0;

            for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                @(vif.cb_master);

                if (is_reset() || should_abort()) begin
                    drive_idle_abort();
                    return;
                end

                if ((vif.cb_master.rvalid === 1'b1) && (vif.cb_master.rready === 1'b1)) begin
                    r_hs = 1;
                    tr.rdata_beats[i] = vif.cb_master.rdata;
                    tr.rresp_beats[i] = vif.cb_master.rresp;
                    update_rready(cyc+1);
                    break;
                end

                update_rready(cyc+1);
            end

            if (!r_hs) begin
                `uvm_fatal("HS_TIMEOUT",
                    $sformatf("R TIMEOUT (%0d cycles). addr=0x%0h id=%0d beat=%0d",
                              WAIT_TIMEOUT, tr.addr, tr.id, i))
            end
        end

        @(vif.cb_master);
        vif.cb_master.rready <= (hold_rready_high) ? 1'b1 : 1'b0;
    endtask

    // ------------------------------------------------------------
    // RUN PHASE
    // ------------------------------------------------------------
    task run_phase(uvm_phase phase);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
        bit need_payload_check;

        init_signals();

        fork
            reset_subscriber();
            flush_subscriber();
            b_collector();
        join_none

        wait_reset_release();
        abort_drive = 1'b0;
        in_reset    = 1'b0;

        forever begin
            // ----------------------------------------------------
            // Abort / reset / flush gate:
            // - drive idle_abort
            // - drain sequencer FIFO so "pre-reset leftovers" don't run after reset
            // ----------------------------------------------------
            if (is_reset() || should_abort() || in_flush || in_reset) begin
                @(vif.cb_master);
                drive_idle_abort();

                // drain any queued items safely (this is the KEY fix for Case10 timeouts)
                drain_sequencer_fifo(is_reset() ? "is_reset" :
                                     (in_flush ? "in_flush" :
                                      (in_reset ? "in_reset" : "abort_drive")));

                // Wait out hard reset
                if (is_reset()) begin
                    wait_reset_release();
                    in_reset = 1'b0;
                end

                // If still flushing, keep looping
                if (in_flush) begin
                    continue;
                end

                // Recover when safe
                if (!is_reset() && !in_flush) begin
                    abort_drive = 1'b0;
                    @(vif.cb_master);
                    drive_idle_now();
                    `uvm_info("DRV_RECOVER", "Recovered from reset/flush -> resume driving", UVM_LOW)
                end
            end

            // ----------------------------------------------------
            // Normal: get next item (blocking)
            // ----------------------------------------------------
            have_item = 1'b0;
            tr = null;
            seq_item_port.get_next_item(tr);
            have_item = 1'b1;

            // If reset hits right after get_next_item, do NOT drive it; just finish it.
            if (is_reset() || should_abort() || in_flush || in_reset) begin
                drive_idle_abort();
                if (have_item) begin
                    seq_item_port.item_done();
                    have_item = 1'b0;
                end
                continue;
            end

            need_payload_check = 0;
            if (tr.rw == AXI_WRITE) begin
                if ((tr.op_kind == OP_FULL) || (tr.op_kind == OP_W_ONLY))
                    need_payload_check = 1;
            end

            if (need_payload_check) begin
                if (!check_beats(tr)) begin
                    `uvm_error("DRV",
                        $sformatf("Bad beats payload sizes. rw=%0d op=%0d addr=0x%0h len=%0d id=%0d",
                                  tr.rw, tr.op_kind, tr.addr, tr.len, tr.id))
                    if (have_item) begin
                        seq_item_port.item_done();
                        have_item = 1'b0;
                    end
                    continue;
                end
            end

            if (tr.rw == AXI_WRITE) begin
                unique case (tr.op_kind)
                    OP_FULL:    drive_write(tr);
                    OP_AW_ONLY: drive_aw_only(tr);
                    OP_W_ONLY:  drive_w_only(tr);
                    OP_B_WAIT:  wait_b_only(tr);
                    default: begin
                        `uvm_warning("DRV_OP", $sformatf("Unknown op_kind=%0d -> fallback OP_FULL", tr.op_kind))
                        drive_write(tr);
                    end
                endcase
            end
            else begin
                drive_read(tr);
            end

            if (have_item) begin
                seq_item_port.item_done();
                have_item = 1'b0;
            end
        end
    endtask

endclass

`endif
