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

    // latches
    logic [ADDR_WIDTH-1:0] aw_addr_lat;
    logic [7:0]            aw_len_lat;
    logic [2:0]            aw_size_lat;
    logic [1:0]            aw_burst_lat;
    logic [ID_WIDTH-1:0]   aw_id_lat;
    bit                    aw_lat_valid;

    logic [ADDR_WIDTH-1:0] ar_addr_lat;
    logic [7:0]            ar_len_lat;
    logic [2:0]            ar_size_lat;
    logic [1:0]            ar_burst_lat;
    logic [ID_WIDTH-1:0]   ar_id_lat;
    bit                    ar_lat_valid;

    logic [ID_WIDTH-1:0]   b_id_lat;
    logic [1:0]            b_resp_lat;
    bit                    b_lat_valid;

    logic                  r_last_lat;
    logic [ID_WIDTH-1:0]   r_id_lat;
    bit                    r_lat_valid;

    // ============================================================
    // NEW: B response storage (by ID)
    // - b_seen[id] indicates at least one B captured for this ID
    // - b_resp_store[id] stores last seen BRESP for that ID
    // - b_count[id] counts how many B captured for that ID (optional debug)
    // ============================================================
    bit                    b_seen      [logic [ID_WIDTH-1:0]];
    logic [1:0]            b_resp_store[logic [ID_WIDTH-1:0]];
    int unsigned           b_count     [logic [ID_WIDTH-1:0]];

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

        `uvm_info("DRV_CFG", $sformatf(
            "hold_bready_high=%0d hold_rready_high=%0d stress_enable=%0d bready_prob=%0d rready_prob=%0d aw_pre_delay_max=%0d ar_pre_delay_max=%0d w_streaming_mode=%0d w_beat_gap_max=%0d force_ready_after=%0d seed=%0d",
            hold_bready_high, hold_rready_high, stress_enable, bready_prob, rready_prob,
            aw_pre_delay_max, ar_pre_delay_max, w_streaming_mode, w_beat_gap_max, force_ready_after, stress_seed),
            UVM_LOW)
    endfunction

    task automatic wait_reset_release();
        @(vif.cb_master);
        while (vif.rst_n !== 1'b1) @(vif.cb_master);
        @(vif.cb_master);
    endtask

    task automatic abort_if_reset(input string where);
        if (vif.rst_n !== 1'b1)
            `uvm_fatal("HS_ABORT_RST", $sformatf("%s aborted by reset", where))
    endtask

    // ---------------- Stress helpers ----------------
    function automatic bit roll_prob(int unsigned prob_0_to_100);
        if (prob_0_to_100 >= 100) return 1;
        if (prob_0_to_100 == 0)   return 0;
        return ($urandom_range(0,99) < prob_0_to_100);
    endfunction

    task automatic maybe_wait_cycles(int unsigned max_cycles);
        int unsigned d;
        if (!stress_enable || max_cycles == 0) return;
        d = $urandom_range(0, max_cycles);
        repeat (d) begin
            @(vif.cb_master);
            abort_if_reset("STRESS_DELAY");
        end
    endtask

    // NOTE:
    // - update_bready() will be used ONLY by the background b_collector().
    // - We do NOT let per-transaction tasks force bready low anymore,
    //   because that creates deadlocks when DUT returns B in-order.
    task automatic update_bready(input int unsigned wait_cyc);
        if (hold_bready_high && !stress_enable) begin
            vif.cb_master.bready <= 1'b1;
            return;
        end
        if (!stress_enable) begin
            // keep whatever it was
            vif.cb_master.bready <= vif.cb_master.bready;
            return;
        end
        if (wait_cyc >= force_ready_after) vif.cb_master.bready <= 1'b1;
        else                               vif.cb_master.bready <= roll_prob(bready_prob);
    endtask

    task automatic update_rready(input int unsigned wait_cyc);
        if (hold_rready_high && !stress_enable) begin
            vif.cb_master.rready <= 1'b1;
            return;
        end
        if (!stress_enable) begin
            vif.cb_master.rready <= vif.cb_master.rready;
            return;
        end
        if (wait_cyc >= force_ready_after) vif.cb_master.rready <= 1'b1;
        else                               vif.cb_master.rready <= roll_prob(rready_prob);
    endtask

    // ---------------- Init ----------------
    task automatic init_signals();
        @(vif.cb_master);
        vif.cb_master.awvalid <= 1'b0;
        vif.cb_master.arvalid <= 1'b0;

        vif.cb_master.wvalid  <= 1'b0;
        vif.cb_master.wlast   <= 1'b0;
        vif.cb_master.wdata   <= '0;
        vif.cb_master.wstrb   <= '0;

        // IMPORTANT:
        // bready is now owned by b_collector() (background consumer).
        // Set an initial value here; collector will keep updating per-cycle.
        vif.cb_master.bready  <= (hold_bready_high) ? 1'b1 : 1'b0;
        vif.cb_master.rready  <= (hold_rready_high) ? 1'b1 : 1'b0;

        aw_addr_lat <= '0; aw_len_lat <= '0; aw_size_lat <= '0; aw_burst_lat <= '0; aw_id_lat <= '0; aw_lat_valid <= 0;
        ar_addr_lat <= '0; ar_len_lat <= '0; ar_size_lat <= '0; ar_burst_lat <= '0; ar_id_lat <= '0; ar_lat_valid <= 0;

        b_id_lat    <= '0; b_resp_lat <= '0; b_lat_valid <= 0;
        r_last_lat  <= 1'b0; r_id_lat  <= '0; r_lat_valid <= 0;

        // clear B storage
        b_seen.delete();
        b_resp_store.delete();
        b_count.delete();

        if (stress_seed != 0) void'($urandom(stress_seed));
    endtask

    function bit check_beats(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats = tr.len + 1;
        if (tr.rw == AXI_WRITE) begin
            if (tr.data_beats.size()  != beats) return 0;
            if (tr.wstrb_beats.size() != beats) return 0;
        end
        return 1;
    endfunction

    // ============================================================
    // NEW: Background B collector
    // - Always tries to accept B responses (bready high or randomized)
    // - On each B handshake: store by ID and mark seen
    // ============================================================
    task automatic b_collector();
        int unsigned cyc;
        cyc = 0;

        // start aligned to clock
        @(vif.cb_master);

        forever begin
            @(vif.cb_master);
            abort_if_reset("B_COLLECTOR_TICK");

            // update bready policy every cycle
            update_bready(cyc);
            cyc++;

            #1step;
            abort_if_reset("B_COLLECTOR_SAMPLE");

            if ((vif.cb_master.bvalid === 1'b1) && (vif.cb_master.bready === 1'b1)) begin
                logic [ID_WIDTH-1:0] id_got;
                logic [1:0]          resp_got;

                id_got   = vif.cb_master.bid;
                resp_got = vif.cb_master.bresp;

                b_seen[id_got]       = 1'b1;
                b_resp_store[id_got] = resp_got;

                if (!b_count.exists(id_got)) b_count[id_got] = 0;
                b_count[id_got]++;

                `uvm_info("DRV_B",
                    $sformatf("B_COLLECT: HS bid=%0d bresp=%0d (count[%0d]=%0d)",
                              id_got, resp_got, id_got, b_count[id_got]),
                    UVM_HIGH)
            end
        end
    endtask

    // ------------------------------------------------------------
    // AW_ONLY: only drive AW handshake
    // ------------------------------------------------------------
    task automatic drive_aw_only(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        bit aw_hs;

        aw_lat_valid = 0;

        maybe_wait_cycles(aw_pre_delay_max);

        @(vif.cb_master);
        abort_if_reset("AW_ONLY_START");

        vif.cb_master.awvalid <= 1'b1;
        vif.cb_master.awaddr  <= tr.addr;
        vif.cb_master.awlen   <= tr.len;
        vif.cb_master.awsize  <= tr.size;
        vif.cb_master.awburst <= tr.burst;
        vif.cb_master.awid    <= tr.id;

        aw_hs = 0;
        for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
            #1step;
            abort_if_reset("AW_ONLY_WAIT");
            if ((vif.cb_master.awvalid === 1'b1) && (vif.cb_master.awready === 1'b1)) begin
                aw_hs = 1;
                aw_addr_lat  = vif.cb_master.awaddr;
                aw_len_lat   = vif.cb_master.awlen;
                aw_size_lat  = vif.cb_master.awsize;
                aw_burst_lat = vif.cb_master.awburst;
                aw_id_lat    = vif.cb_master.awid;
                aw_lat_valid = 1;
                break;
            end
            @(vif.cb_master);
        end

        if (!aw_hs) begin
            `uvm_fatal("HS_TIMEOUT",
                $sformatf("AW_ONLY TIMEOUT (%0d cycles). addr=0x%0h id=%0d", WAIT_TIMEOUT, tr.addr, tr.id))
        end

        @(vif.cb_master);
        vif.cb_master.awvalid <= 1'b0;

        `uvm_info("DRV",
            $sformatf("WRITE(AW_ONLY) done: id=%0d | AW(addr=0x%0h len=%0d size=%0d burst=%02b id=%0d)",
                      tr.id,
                      (aw_lat_valid ? aw_addr_lat  : tr.addr),
                      (aw_lat_valid ? aw_len_lat   : tr.len),
                      (aw_lat_valid ? aw_size_lat  : tr.size),
                      (aw_lat_valid ? aw_burst_lat : tr.burst),
                      (aw_lat_valid ? aw_id_lat    : tr.id)),
            UVM_LOW)
    endtask

    // ------------------------------------------------------------
    // W_ONLY: only drive W beats (assume AW already accepted)
    // ------------------------------------------------------------
    task automatic drive_w_only(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats;

        beats = tr.len + 1;

        if (tr.data_beats.size() != beats || tr.wstrb_beats.size() != beats) begin
            `uvm_fatal("DRV_ITEM",
                $sformatf("W_ONLY bad payload size: beats=%0d data=%0d wstrb=%0d (addr=0x%0h id=%0d)",
                          beats, tr.data_beats.size(), tr.wstrb_beats.size(), tr.addr, tr.id))
        end

        if (!w_streaming_mode) begin
            for (int i = 0; i < beats; i++) begin
                bit w_hs;

                w_hs = 0;
                maybe_wait_cycles(w_beat_gap_max);

                @(vif.cb_master);
                abort_if_reset("W_ONLY_BEAT_START");

                vif.cb_master.wvalid <= 1'b1;
                vif.cb_master.wdata  <= tr.data_beats[i];
                vif.cb_master.wstrb  <= tr.wstrb_beats[i];
                vif.cb_master.wlast  <= (i == beats-1);

                for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                    #1step;
                    abort_if_reset("W_ONLY_WAIT");
                    if ((vif.cb_master.wvalid === 1'b1) && (vif.cb_master.wready === 1'b1)) begin
                        w_hs = 1;
                        break;
                    end
                    @(vif.cb_master);
                end

                if (!w_hs) begin
                    `uvm_fatal("HS_TIMEOUT",
                        $sformatf("W_ONLY TIMEOUT (%0d cycles). addr=0x%0h id=%0d beat=%0d",
                                  WAIT_TIMEOUT, tr.addr, tr.id, i))
                end

                `uvm_info("DRV_DBG",
                    $sformatf("W_ONLY HS beat=%0d data=0x%0h wstrb=0x%0h last=%0b",
                              i, tr.data_beats[i], tr.wstrb_beats[i], (i==beats-1)),
                    UVM_HIGH)

                @(vif.cb_master);
                abort_if_reset("W_ONLY_BEAT_END");
                vif.cb_master.wvalid <= 1'b0;
                vif.cb_master.wlast  <= 1'b0;
            end
        end
        else begin
            int i;
            i = 0;

            maybe_wait_cycles(w_beat_gap_max);

            @(vif.cb_master);
            abort_if_reset("W_ONLY_STREAM_START");

            vif.cb_master.wvalid <= 1'b1;
            vif.cb_master.wdata  <= tr.data_beats[0];
            vif.cb_master.wstrb  <= tr.wstrb_beats[0];
            vif.cb_master.wlast  <= (beats == 1);

            while (i < beats) begin
                bit hs_now;
                hs_now = 0;

                for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                    #1step;
                    abort_if_reset("W_ONLY_STREAM_WAIT");
                    if ((vif.cb_master.wvalid === 1'b1) && (vif.cb_master.wready === 1'b1)) begin
                        hs_now = 1;
                        break;
                    end
                    @(vif.cb_master);
                end

                if (!hs_now) begin
                    `uvm_fatal("HS_TIMEOUT",
                        $sformatf("W_ONLY(stream) TIMEOUT (%0d cycles). addr=0x%0h id=%0d beat=%0d",
                                  WAIT_TIMEOUT, tr.addr, tr.id, i))
                end

                `uvm_info("DRV_DBG",
                    $sformatf("W_ONLY HS(stream) beat=%0d data=0x%0h wstrb=0x%0h last=%0b",
                              i, tr.data_beats[i], tr.wstrb_beats[i], (i==beats-1)),
                    UVM_HIGH)

                i++;
                if (i >= beats) break;

                if (stress_enable && (w_beat_gap_max != 0)) begin
                    vif.cb_master.wvalid <= 1'b0;
                    vif.cb_master.wlast  <= 1'b0;
                    maybe_wait_cycles(w_beat_gap_max);
                    @(vif.cb_master);
                    vif.cb_master.wvalid <= 1'b1;
                end else begin
                    @(vif.cb_master);
                end

                vif.cb_master.wdata <= tr.data_beats[i];
                vif.cb_master.wstrb <= tr.wstrb_beats[i];
                vif.cb_master.wlast <= (i == beats-1);
            end

            @(vif.cb_master);
            abort_if_reset("W_ONLY_STREAM_END");
            vif.cb_master.wvalid <= 1'b0;
            vif.cb_master.wlast  <= 1'b0;
        end

        `uvm_info("DRV",
            $sformatf("WRITE(W_ONLY) done: id=%0d addr=0x%0h len=%0d (no AW/B driven)", tr.id, tr.addr, tr.len),
            UVM_LOW)
    endtask

    // ------------------------------------------------------------
    // NEW B_WAIT: wait until collector has captured BID==wait_bid
    // - DOES NOT control bready
    // - Safe for in-order and out-of-order B
    // ------------------------------------------------------------
    task automatic wait_b_only(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        bit got;
        got = 0;

        // If already seen, return immediately
        if (b_seen.exists(tr.wait_bid) && (b_seen[tr.wait_bid] == 1'b1)) begin
            got = 1;
        end else begin
            for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                @(vif.cb_master);
                abort_if_reset("B_WAIT_TICK");
                if (b_seen.exists(tr.wait_bid) && (b_seen[tr.wait_bid] == 1'b1)) begin
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

        // consume value (do NOT delete by default; keep for debug)
        tr.bresp = b_resp_store[tr.wait_bid];

        `uvm_info("DRV",
            $sformatf("WRITE(B_WAIT) done: wait_bid=%0d bresp=%0d (count=%0d)",
                      tr.wait_bid, tr.bresp,
                      (b_count.exists(tr.wait_bid) ? b_count[tr.wait_bid] : 0)),
            UVM_LOW)
    endtask

    // ============================================================
    // LEGACY WRITE (OP_FULL): AW + W + then wait for B of SAME ID
    // - Because collector is consuming B continuously, OP_FULL must
    //   wait via b_seen[id] instead of doing its own handshake.
    // ============================================================
    task automatic drive_write(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats;
        bit aw_hs;

        beats = tr.len + 1;
        aw_lat_valid = 0;

        if (tr.data_beats.size() != beats || tr.wstrb_beats.size() != beats) begin
            `uvm_fatal("DRV_ITEM",
                $sformatf("Bad payload array size: beats=%0d data=%0d wstrb=%0d (addr=0x%0h id=%0d)",
                          beats, tr.data_beats.size(), tr.wstrb_beats.size(), tr.addr, tr.id))
        end

        // clear seen flag for this ID so we can detect new completion
        b_seen[tr.id] = 1'b0;

        maybe_wait_cycles(aw_pre_delay_max);

        // AW
        @(vif.cb_master);
        abort_if_reset("AW_START");

        vif.cb_master.awvalid <= 1'b1;
        vif.cb_master.awaddr  <= tr.addr;
        vif.cb_master.awlen   <= tr.len;
        vif.cb_master.awsize  <= tr.size;
        vif.cb_master.awburst <= tr.burst;
        vif.cb_master.awid    <= tr.id;

        aw_hs = 0;
        for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
            #1step;
            abort_if_reset("AW_WAIT");
            if ((vif.cb_master.awvalid === 1'b1) && (vif.cb_master.awready === 1'b1)) begin
                aw_hs = 1;
                aw_addr_lat  = vif.cb_master.awaddr;
                aw_len_lat   = vif.cb_master.awlen;
                aw_size_lat  = vif.cb_master.awsize;
                aw_burst_lat = vif.cb_master.awburst;
                aw_id_lat    = vif.cb_master.awid;
                aw_lat_valid = 1;
                break;
            end
            @(vif.cb_master);
        end
        if (!aw_hs)
            `uvm_fatal("HS_TIMEOUT", $sformatf("AW TIMEOUT (%0d cycles). addr=0x%0h id=%0d", WAIT_TIMEOUT, tr.addr, tr.id))

        @(vif.cb_master);
        vif.cb_master.awvalid <= 1'b0;

        // W
        drive_w_only(tr);

        // wait for B of this ID (collector-driven)
        begin
            bit got;
            got = 0;
            for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                @(vif.cb_master);
                abort_if_reset("B_WAIT_BYID");
                if (b_seen.exists(tr.id) && (b_seen[tr.id] == 1'b1)) begin
                    got = 1;
                    break;
                end
            end
            if (!got)
                `uvm_fatal("HS_TIMEOUT", $sformatf("B(by-id) TIMEOUT (%0d cycles). addr=0x%0h id=%0d", WAIT_TIMEOUT, tr.addr, tr.id))
        end

        tr.bresp = b_resp_store[tr.id];

        `uvm_info("DRV",
            $sformatf("WRITE done: id=%0d BRESP=%0d | \n\n\
                                            AW(addr=0x%0h len=%0d size=%0d burst=%02b id=%0d) | \n\n\
                                            B(byid=%0d bresp=%0d count=%0d)",
                    tr.id, tr.bresp,
                    (aw_lat_valid ? aw_addr_lat  : tr.addr),
                    (aw_lat_valid ? aw_len_lat   : tr.len),
                    (aw_lat_valid ? aw_size_lat  : tr.size),
                    (aw_lat_valid ? aw_burst_lat : tr.burst),
                    (aw_lat_valid ? aw_id_lat    : tr.id),
                    tr.id, tr.bresp,
                    (b_count.exists(tr.id) ? b_count[tr.id] : 0)),
            UVM_LOW)
    endtask

    // ------------------------------------------------------------
    // READ: AR then capture R beats (legacy)
    // ------------------------------------------------------------
    task automatic drive_read(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats;
        bit ar_hs;

        beats = tr.len + 1;
        ar_lat_valid = 0;
        r_lat_valid  = 0;

        maybe_wait_cycles(ar_pre_delay_max);

        @(vif.cb_master);
        abort_if_reset("AR_START");

        vif.cb_master.arvalid <= 1'b1;
        vif.cb_master.araddr  <= tr.addr;
        vif.cb_master.arlen   <= tr.len;
        vif.cb_master.arsize  <= tr.size;
        vif.cb_master.arburst <= tr.burst;
        vif.cb_master.arid    <= tr.id;

        ar_hs = 0;
        for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
            #1step;
            abort_if_reset("AR_WAIT");
            if ((vif.cb_master.arvalid === 1'b1) && (vif.cb_master.arready === 1'b1)) begin
                ar_hs = 1;
                ar_addr_lat  = vif.cb_master.araddr;
                ar_len_lat   = vif.cb_master.arlen;
                ar_size_lat  = vif.cb_master.arsize;
                ar_burst_lat = vif.cb_master.arburst;
                ar_id_lat    = vif.cb_master.arid;
                ar_lat_valid = 1;
                break;
            end
            @(vif.cb_master);
        end
        if (!ar_hs)
            `uvm_fatal("HS_TIMEOUT", $sformatf("AR TIMEOUT (%0d cycles). addr=0x%0h id=%0d", WAIT_TIMEOUT, tr.addr, tr.id))

        @(vif.cb_master);
        vif.cb_master.arvalid <= 1'b0;

        if (!hold_rready_high) begin
            @(vif.cb_master);
            vif.cb_master.rready <= 1'b0;
        end

        for (int i = 0; i < beats; i++) begin
            bit r_hs;
            r_hs = 0;

            for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                @(vif.cb_master);
                abort_if_reset("R_WAIT_TICK");

                update_rready(cyc);

                #1step;
                abort_if_reset("R_WAIT_SAMPLE");

                if ((vif.cb_master.rvalid === 1'b1) && (vif.cb_master.rready === 1'b1)) begin
                    r_hs = 1;
                    break;
                end
            end

            if (!r_hs)
                `uvm_fatal("HS_TIMEOUT", $sformatf("R TIMEOUT (%0d cycles). addr=0x%0h id=%0d beat=%0d",
                                                  WAIT_TIMEOUT, tr.addr, tr.id, i))

            tr.rdata_beats[i] = vif.cb_master.rdata;
            tr.rresp_beats[i] = vif.cb_master.rresp;

            if (i == beats - 1) begin
                r_last_lat  = vif.cb_master.rlast;
                r_id_lat    = vif.cb_master.rid;
                r_lat_valid = 1;
            end

            if ((i == beats - 1) && (vif.cb_master.rlast !== 1'b1))
                `uvm_error("DRV", "Missing RLAST on final beat");
            if ((i < beats - 1) && (vif.cb_master.rlast === 1'b1))
                `uvm_error("DRV", "Early RLAST");
        end

        @(vif.cb_master);
        vif.cb_master.rready <= (hold_rready_high) ? 1'b1 : 1'b0;

        `uvm_info("DRV", $sformatf("READ done: id=%0d beats=%0d first=0x%0h | \n\n\
                                    AR(addr=0x%0h len=%0d size=%0d burst=%02b id=%0d) | \n\n\
                                    R(last=%0b rid=%0d)",
                                    tr.id, beats, tr.rdata_beats[0],
                                    (ar_lat_valid ? ar_addr_lat  : tr.addr),
                                    (ar_lat_valid ? ar_len_lat   : tr.len),
                                    (ar_lat_valid ? ar_size_lat  : tr.size),
                                    (ar_lat_valid ? ar_burst_lat : tr.burst),
                                    (ar_lat_valid ? ar_id_lat    : tr.id),
                                    (r_lat_valid ? r_last_lat : 1'bx),
                                    (r_lat_valid ? r_id_lat   : 'x)),
        UVM_LOW)
    endtask

    // ------------------------------------------------------------
    // RUN PHASE (dispatch by op_kind)
    // - Fork background b_collector so B is always drained
    // ------------------------------------------------------------
    task run_phase(uvm_phase phase);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
        bit need_payload_check;

        init_signals();
        wait_reset_release();

        // Start background B collector
        fork
            b_collector();
        join_none

        forever begin
            seq_item_port.get_next_item(tr);

            `uvm_info("DRV",
                $sformatf("Driving %s op=%0d addr=0x%0h len=%0d id=%0d wait_bid=%0d",
                          (tr.rw == AXI_WRITE) ? "WRITE" : " READ",
                          tr.op_kind, tr.addr, tr.len, tr.id, tr.wait_bid),
                UVM_LOW)

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
                    seq_item_port.item_done();
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

            seq_item_port.item_done();
        end
    endtask

endclass

`endif
