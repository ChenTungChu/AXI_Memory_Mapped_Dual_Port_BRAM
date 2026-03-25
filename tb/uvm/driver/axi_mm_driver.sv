// File: tb/uvm/driver/axi_mm_driver.sv
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

    // Knobs
    bit          hold_bready_high     = 1;
    bit          hold_rready_high     = 1;

    bit          stress_enable        = 0;
    int unsigned bready_prob          = 100;
    int unsigned rready_prob          = 100;

    int unsigned aw_pre_delay_max     = 0;
    int unsigned ar_pre_delay_max     = 0;

    bit          w_streaming_mode     = 0;
    int unsigned w_beat_gap_max       = 0;

    int unsigned force_ready_after    = 64;
    int unsigned stress_seed          = 0;

    bit          align_wdata_to_wstrb = 1'b1;

    bit          strict_consume_b     = 1'b1;    // Strict checking for B consume

    // ------------------------------------------------------------
    // Latches
    // ------------------------------------------------------------
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

    // B response storage 
    bit                    b_seen       [int unsigned];
    logic [1:0]            b_resp_store [int unsigned];
    int unsigned           b_count      [int unsigned];

    // Generic reset/flush event interface
    uvm_event              ev_reset_assert;
    uvm_event              ev_reset_deassert;
    uvm_event              ev_flush;
    uvm_event              ev_flush_done;

    // Driver state
    bit                    in_reset;
    bit                    abort_drive;
    bit                    in_flush;

    bit                    have_item;

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // ------------------------------------------------------------
    // Build phase
    // ------------------------------------------------------------
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_master)::get(this, "", "vif_m", vif))
        begin
            if (!uvm_config_db#(virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_master)::get(this, "", "vif", vif))
            begin
                `uvm_fatal("NOVIF", $sformatf("Driver mp_master vif not set, drv=%s", get_full_name()))
            end
        end

        void'(uvm_config_db#(bit         )::get(this, "", "hold_bready_high", hold_bready_high));
        void'(uvm_config_db#(bit         )::get(this, "", "hold_rready_high", hold_rready_high));
        void'(uvm_config_db#(bit         )::get(this, "", "stress_enable", stress_enable));
        void'(uvm_config_db#(int unsigned)::get(this, "", "bready_prob", bready_prob));
        void'(uvm_config_db#(int unsigned)::get(this, "", "rready_prob", rready_prob));
        void'(uvm_config_db#(int unsigned)::get(this, "", "aw_pre_delay_max", aw_pre_delay_max));
        void'(uvm_config_db#(int unsigned)::get(this, "", "ar_pre_delay_max", ar_pre_delay_max));
        void'(uvm_config_db#(bit         )::get(this, "", "w_streaming_mode", w_streaming_mode));
        void'(uvm_config_db#(int unsigned)::get(this, "", "w_beat_gap_max", w_beat_gap_max));
        void'(uvm_config_db#(int unsigned)::get(this, "", "force_ready_after", force_ready_after));
        void'(uvm_config_db#(int unsigned)::get(this, "", "stress_seed", stress_seed));
        void'(uvm_config_db#(bit         )::get(this, "", "align_wdata_to_wstrb", align_wdata_to_wstrb));
        void'(uvm_config_db#(bit         )::get(this, "", "strict_consume_b", strict_consume_b));

        if (bready_prob > 100) bready_prob = 100;
        if (rready_prob > 100) rready_prob = 100;

        ev_reset_assert   = uvm_event_pool::get_global("axi_mm_reset_assert");
        ev_reset_deassert = uvm_event_pool::get_global("axi_mm_reset_deassert");
        ev_flush          = uvm_event_pool::get_global("axi_mm_flush");
        ev_flush_done     = uvm_event_pool::get_global("axi_mm_flush_done");

        in_reset          = 1'b0;
        abort_drive       = 1'b0;
        in_flush          = 1'b0;
        have_item         = 1'b0;
    endfunction

    // ------------------------------------------------------------
    // Helper functions
    // ------------------------------------------------------------
    function automatic int unsigned id_key(input logic [ID_WIDTH-1:0] id);
        return int'(id);
    endfunction

    function automatic bit is_reset();
        return (vif.cb_master.rst_n !== 1'b1);
    endfunction

    function automatic bit should_abort();
        return abort_drive;
    endfunction

    function bit check_beats(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats = tr.len + 1;
        if (tr.rw == AXI_WRITE) begin
            if (tr.wdata_beats.size() != beats) return 0;
            if (tr.wstrb_beats.size() != beats) return 0;
        end
        return 1;
    endfunction

    // ------------------------------------------------------------
    // bus/state utilities
    // ------------------------------------------------------------
    task automatic clear_driver_state(string why);
        b_seen.delete();
        b_resp_store.delete();
        b_count.delete();
        `uvm_info("DRV_CLR", $sformatf("Driver state cleared (%s)", why), UVM_LOW)
    endtask

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

    task automatic drive_idle_abort();
        vif.cb_master.awvalid <= 1'b0;
        vif.cb_master.arvalid <= 1'b0;

        vif.cb_master.wvalid  <= 1'b0;
        vif.cb_master.wlast   <= 1'b0;
        vif.cb_master.wdata   <= '0;
        vif.cb_master.wstrb   <= '0;

        // Hold low during abort/reset/flush
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
    // Stress helper functions
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
        if (!stress_enable) begin
            vif.cb_master.bready <= 1'b1;
            return;
        end
        if (hold_bready_high) begin
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
        if (!stress_enable) begin
            vif.cb_master.rready <= 1'b1;
            return;
        end
        if (hold_rready_high) begin
            vif.cb_master.rready <= 1'b1;
            return;
        end
        if (wait_cyc >= force_ready_after) vif.cb_master.rready <= 1'b1;
        else                               vif.cb_master.rready <= roll_prob(rready_prob);
    endtask

    task automatic maybe_wait_cycles(int unsigned max_cycles);
        int unsigned d;
        if (max_cycles == 0) return;
        d = $urandom_range(0, max_cycles);
        repeat (d) begin
            @(vif.cb_master);
            if (should_abort() || is_reset()) return;
        end
    endtask

    // ------------------------------------------------------------
    // Event wait
    // - Only accept triggers after t0
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
    // Drain sequencer during reset/flush
    // ------------------------------------------------------------
    task automatic drain_sequencer_fifo(string why, int unsigned max_drain = 100000);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr_d;
        int unsigned n;
        n = 0;

        forever begin
            tr_d = null;
            seq_item_port.try_next_item(tr_d);
            if (tr_d == null) break;

            n++;
            `uvm_info("DRV_DRAIN",
                $sformatf("Drain item (%s): rw=%0d op=%0d addr=0x%0h id=%0d drain_cnt=%0d", why, tr_d.rw, tr_d.op_kind, tr_d.addr, tr_d.id, n), UVM_LOW)

            seq_item_port.item_done();

            if (n >= max_drain) begin
                `uvm_warning("DRV_DRAIN", $sformatf("Drain reached max_drain=%0d, stop draining %s", max_drain, why))
                break;
            end
        end
    endtask

    // ------------------------------------------------------------
    // Reset/flush subscribers
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

            `uvm_info("DRV_RST", "Reset asserted -> abort_drive=1, in_reset=1", UVM_LOW)
            wait_event_after(ev_reset_deassert, t_rst);
            `uvm_info("DRV_RST", "Reset deasserted", UVM_LOW)

            in_reset = 1'b0;
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

            `uvm_info("DRV_FLUSH", "Flushed -> abort_drive=1, in_flush=1", UVM_LOW)
            wait_event_after(ev_flush_done, t_flush);
            `uvm_info("DRV_FLUSH", "Flush done", UVM_LOW)

            in_flush = 1'b0;
        end
    endtask

    // ------------------------------------------------------------
    // B collector
    // ------------------------------------------------------------
    task automatic b_collector();
        int unsigned cyc;
        cyc = 0;

        @(vif.cb_master);
        update_bready(cyc);

        forever begin
            @(vif.cb_master);

            if (is_reset() || should_abort()) begin
                cyc = 0;
                update_bready(cyc);
                continue;
            end

            if ((vif.cb_master.bvalid === 1'b1) && (vif.bready === 1'b1)) begin
                logic [ID_WIDTH-1:0] id_got;
                logic [1:0]          resp_got;
                int unsigned         k;

                id_got   = vif.cb_master.bid;
                resp_got = vif.cb_master.bresp;
                k        = id_key(id_got);

                if (!b_count.exists(k)) b_count[k] = 0;
                b_count[k]++;

                b_resp_store[k] = resp_got;
                b_seen[k]       = 1'b1;

                `uvm_info("DRV_B", $sformatf("B_COLLECT: HS bid=%0d bresp=%0d pending_count[%0d]=%0d", int'(id_got), resp_got, int'(id_got), b_count[k]), UVM_HIGH)
            end

            cyc++;
            update_bready(cyc);
        end
    endtask

    // ------------------------------------------------------------
    // Consume exactly one pending B for a given ID
    // ------------------------------------------------------------
    task automatic consume_one_b(input logic [ID_WIDTH-1:0] bid);
        int unsigned k;
        k = id_key(bid);

        if (!b_count.exists(k)) begin
            if (strict_consume_b) begin
                `uvm_error("DRV_B", $sformatf("CONSUME_ONE_B: b_count key NOT exist for ID=%0d, b_seen=%0b", int'(bid), (b_seen.exists(k) ? b_seen[k] : 1'b0)))
            end
            return;
        end

        if (b_count[k] == 0) begin
            if (strict_consume_b) begin
                `uvm_error("DRV_B", $sformatf("CONSUME_ONE_B: b_count already 0 for ID=%0d, b_seen=%0b", int'(bid), (b_seen.exists(k) ? b_seen[k] : 1'b0)))
            end
            return;
        end

        b_count[k]--;
        if (b_count[k] == 0) b_seen[k] = 1'b0;

        `uvm_info("DRV_B", $sformatf("CONSUME_ONE_B: ID=%0d -> remaining b_count=%0d b_seen=%0b", int'(bid), b_count[k], b_seen[k]), UVM_HIGH)
    endtask

    // ------------------------------------------------------------
    // Pack payload bytes into WDATA lanes indicated by WSTRB
    // ------------------------------------------------------------
    function automatic logic [DATA_WIDTH-1:0] pack_wdata_by_wstrb(
        input logic [DATA_WIDTH-1:0] src_data,
        input logic [(DATA_WIDTH/8)-1:0] wstrb
    );
        logic [DATA_WIDTH-1:0] out;
        int src_idx;
        int lanes;

        out     = '0;
        src_idx = 0;
        lanes   = DATA_WIDTH/8;

        for (int lane = 0; lane < lanes; lane++) begin
            if (wstrb[lane] === 1'b1) begin
                out[lane*8 +: 8] = src_data[src_idx*8 +: 8];
                src_idx++;
            end
        end
        return out;
    endfunction

    // ------------------------------------------------------------
    // OP_AW_ONLY
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

            if ((vif.awvalid === 1'b1) && (vif.cb_master.awready === 1'b1)) begin
                aw_hs        = 1;
                aw_addr_lat  = vif.awaddr;
                aw_len_lat   = vif.awlen;
                aw_size_lat  = vif.awsize;
                aw_burst_lat = vif.awburst;
                aw_id_lat    = vif.awid;

                vif.cb_master.awvalid <= 1'b0;
                break;
            end
        end

        if (!aw_hs) begin
            vif.cb_master.awvalid <= 1'b0;
            `uvm_fatal("HS_TIMEOUT", $sformatf("AW_ONLY TIMEOUT %0d cycles, addr=0x%0h id=%0d", WAIT_TIMEOUT, tr.addr, tr.id))
        end
    endtask

    // ------------------------------------------------------------
    // OP_W_ONLY
    // ------------------------------------------------------------
    task automatic drive_w_only(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats;
        beats = tr.len + 1;

        if (tr.wdata_beats.size() != beats || tr.wstrb_beats.size() != beats) begin
            `uvm_fatal("DRV_ITEM", $sformatf("W_ONLY bad payload size: beats=%0d data=%0d wstrb=%0d addr=0x%0h id=%0d", beats, tr.wdata_beats.size(), tr.wstrb_beats.size(), tr.addr, tr.id))
        end

        for (int i = 0; i < beats; i++) begin
            bit w_hs;
            logic [DATA_WIDTH-1:0]       wdata_drive;
            logic [(DATA_WIDTH/8)-1:0]   wstrb_drive;

            w_hs = 0;
            wstrb_drive = tr.wstrb_beats[i];

            if (align_wdata_to_wstrb) wdata_drive = pack_wdata_by_wstrb(tr.wdata_beats[i], wstrb_drive);
            else                      wdata_drive = tr.wdata_beats[i];

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
            vif.cb_master.wdata  <= wdata_drive;
            vif.cb_master.wstrb  <= wstrb_drive;
            vif.cb_master.wlast  <= (i == beats-1);

            for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                @(vif.cb_master);

                if (is_reset() || should_abort()) begin
                    vif.cb_master.wvalid <= 1'b0;
                    vif.cb_master.wlast  <= 1'b0;
                    return;
                end

                if ((vif.wvalid === 1'b1) && (vif.cb_master.wready === 1'b1)) begin
                    w_hs = 1;
                    vif.cb_master.wvalid <= 1'b0;
                    vif.cb_master.wlast  <= 1'b0;
                    break;
                end
            end

            if (!w_hs) begin
                vif.cb_master.wvalid <= 1'b0;
                vif.cb_master.wlast  <= 1'b0;
                `uvm_fatal("HS_TIMEOUT", $sformatf("W_ONLY TIMEOUT %0d cycles, addr=0x%0h id=%0d beat=%0d", WAIT_TIMEOUT, tr.addr, tr.id, i))
            end
        end
    endtask

    // ------------------------------------------------------------
    // OP_B_WAIT
    // ------------------------------------------------------------
    task automatic wait_b_only(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        bit got;
        int unsigned k;

        got = 0;
        k   = id_key(tr.wait_bid);

        if (is_reset() || should_abort()) begin
            tr.bresp = '0;
            return;
        end

        if (b_count.exists(k) && (b_count[k] > 0)) begin
            got = 1;
        end else begin
            for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                @(vif.cb_master);
                if (is_reset() || should_abort()) begin
                    tr.bresp = '0;
                    return;
                end
                if (b_count.exists(k) && (b_count[k] > 0)) begin
                    got = 1;
                    break;
                end
            end
        end

        if (!got) begin
            `uvm_fatal("HS_TIMEOUT", $sformatf("B_WAIT TIMEOUT %0d cycles, wait_bid=%0d addr=0x%0h id=%0d op_kind=%0d", WAIT_TIMEOUT, tr.wait_bid, tr.addr, tr.id, tr.op_kind))
        end

        tr.bresp = b_resp_store[k];
        consume_one_b(tr.wait_bid);
    endtask

    // ------------------------------------------------------------
    // Drive write
    // ------------------------------------------------------------
    task automatic drive_write(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats;
        bit aw_hs;
        int unsigned k;

        beats = tr.len + 1;
        aw_hs = 0;
        k     = id_key(tr.id);

        if (tr.wdata_beats.size() != beats || tr.wstrb_beats.size() != beats) begin
            `uvm_fatal("DRV_ITEM", $sformatf("Bad payload array size: beats=%0d data=%0d wstrb=%0d addr=0x%0h id=%0d", beats, tr.wdata_beats.size(), tr.wstrb_beats.size(), tr.addr, tr.id))
        end

        // Bookkeeping for ID reuse
        if (b_count.exists(k) && (b_count[k] > 0)) begin
            `uvm_warning("DRV_ID", $sformatf("Reusing ID=%0d while pending unconsumed B count=%0d", tr.id, b_count[k]))
        end
        if (!b_count.exists(k)) b_count[k] = 0;
        if (b_count[k] == 0) b_seen[k] = 1'b0;

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

            if ((vif.awvalid === 1'b1) && (vif.cb_master.awready === 1'b1)) begin
                aw_hs        = 1;
                aw_addr_lat  = vif.awaddr;
                aw_len_lat   = vif.awlen;
                aw_size_lat  = vif.awsize;
                aw_burst_lat = vif.awburst;
                aw_id_lat    = vif.awid;

                vif.cb_master.awvalid <= 1'b0;
                break;
            end
        end

        if (!aw_hs) begin
            vif.cb_master.awvalid <= 1'b0;
            `uvm_fatal("HS_TIMEOUT", $sformatf("AW TIMEOUT %0d cycles, addr=0x%0h id=%0d", WAIT_TIMEOUT, tr.addr, tr.id))
        end

        // W burst
        drive_w_only(tr);
        if (is_reset() || should_abort()) return;

        // B wait by ID
        begin
            bit got;
            got = 0;

            for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                @(vif.cb_master);
                if (is_reset() || should_abort()) begin
                    tr.bresp = '0;
                    return;
                end
                if (b_count.exists(k) && (b_count[k] > 0)) begin
                    got = 1;
                    break;
                end
            end

            if (!got) begin
                `uvm_fatal("HS_TIMEOUT", $sformatf("B TIMEOUT %0d cycles, addr=0x%0h id=%0d", WAIT_TIMEOUT, tr.addr, tr.id))
            end
        end

        tr.bresp = b_resp_store[k];
        consume_one_b(tr.id);

        if (b_count.exists(k) && (b_count[k] > 0)) begin
            `uvm_error("DRV_B", $sformatf("After consuming one B, still pending B for ID=%0d: b_count=%0d.", int'(tr.id), b_count[k]))
        end
    endtask

    // ------------------------------------------------------------
    // Drive read
    // ------------------------------------------------------------
    task automatic drive_read(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats;
        bit ar_hs;

        beats = tr.len + 1;
        ar_hs = 0;

        if (tr.rdata_beats.size() != beats) tr.rdata_beats = new[beats];
        if (tr.rresp_beats.size() != beats) tr.rresp_beats = new[beats];

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

            if ((vif.arvalid === 1'b1) && (vif.cb_master.arready === 1'b1)) begin
                ar_hs        = 1;
                ar_addr_lat  = vif.araddr;
                ar_len_lat   = vif.arlen;
                ar_size_lat  = vif.arsize;
                ar_burst_lat = vif.arburst;
                ar_id_lat    = vif.arid;

                vif.cb_master.arvalid <= 1'b0;
                break;
            end
        end

        if (!ar_hs) begin
            vif.cb_master.arvalid <= 1'b0;
            `uvm_fatal("HS_TIMEOUT", $sformatf("AR TIMEOUT %0d cycles, addr=0x%0h id=%0d", WAIT_TIMEOUT, tr.addr, tr.id))
        end

        // RREADY
        if (!hold_rready_high) begin
            @(vif.cb_master);
            vif.cb_master.rready <= 1'b0;
        end

        update_rready(0);

        for (int i = 0; i < beats; i++) begin
            bit r_hs;
            r_hs = 0;

            for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                @(vif.cb_master);

                if (is_reset() || should_abort()) begin
                    drive_idle_abort();
                    return;
                end

                if ((vif.cb_master.rvalid === 1'b1) && (vif.rready === 1'b1)) begin
                    r_hs = 1;
                    tr.rdata_beats[i] = vif.cb_master.rdata;
                    tr.rresp_beats[i] = vif.cb_master.rresp;
                    update_rready(cyc+1);
                    break;
                end

                update_rready(cyc+1);
            end

            if (!r_hs) begin
                `uvm_fatal("HS_TIMEOUT", $sformatf("R TIMEOUT %0d cycles, addr=0x%0h id=%0d beat=%0d", WAIT_TIMEOUT, tr.addr, tr.id, i))
            end
        end

        @(vif.cb_master);
        vif.cb_master.rready <= (hold_rready_high) ? 1'b1 : 1'b0;
    endtask

    // ------------------------------------------------------------
    // Run phase
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
            if (is_reset() || should_abort() || in_flush || in_reset) begin
                @(vif.cb_master);
                drive_idle_abort();

                drain_sequencer_fifo(is_reset() ? "is_reset" : 
                                    (in_flush   ? "in_flush" : 
                                    (in_reset   ? "in_reset" : "abort_drive")));

                if (is_reset()) begin
                    wait_reset_release();
                    in_reset = 1'b0;
                end

                if (in_flush) begin
                    continue;
                end

                if (!is_reset() && !in_flush) begin
                    abort_drive = 1'b0;
                    @(vif.cb_master);
                    drive_idle_now();
                    `uvm_info("DRV_RECOVER", "Recovered from reset/flush -> resume driving", UVM_LOW)
                end
            end

            have_item = 1'b0;
            tr        = null;
            seq_item_port.get_next_item(tr);
            have_item = 1'b1;

            if (is_reset() || should_abort() || in_flush || in_reset) begin
                drive_idle_abort();
                if (have_item) begin
                    seq_item_port.item_done();
                    have_item = 1'b0;
                end
                continue;
            end

            // Payload check only when needed
            need_payload_check = 0;
            if (tr.rw == AXI_WRITE) begin
                if ((tr.op_kind == OP_FULL) || (tr.op_kind == OP_W_ONLY))
                    need_payload_check = 1;
            end

            if (need_payload_check) begin
                if (!check_beats(tr)) begin
                    `uvm_error("DRV", $sformatf("Bad beats payload sizes: rw=%0d op=%0d addr=0x%0h len=%0d id=%0d", tr.rw, tr.op_kind, tr.addr, tr.len, tr.id))
                    if (have_item) begin
                        seq_item_port.item_done();
                        have_item = 1'b0;
                    end
                    continue;
                end
            end

            // Do drive
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

            // Complete item
            if (have_item) begin
                seq_item_port.item_done();
                have_item = 1'b0;
            end
        end
    endtask

endclass : axi_mm_driver

`endif