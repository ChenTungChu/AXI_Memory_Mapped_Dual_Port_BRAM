`ifndef AXI_MM_DRIVER_SV
`define AXI_MM_DRIVER_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

// -------------------------------------------------------------------------
// AXI-MM Driver (MASTER) - Random-stress hardened
// - Drives ONLY via vif.cb_master outputs; samples ONLY via cb_master inputs
// - Counts same-cycle handshake via #1step after asserting VALID
// - Holds payload stable until handshake
// - Latches AW/AR/B/R(last) for stable logs
//
// Stress features (all knobbed; default OFF to preserve bring-up behavior):
//  1) Random backpressure on BREADY/RREADY (per-cycle ready probability)
//  2) Random stalls before AW/AR and between W beats
//  3) W burst mode: streaming (continuous wvalid) vs pulsed (1-beat valid)
//  4) Optional random gaps even inside a burst (beat gap cycles)
//
// NOTE:
//  - To avoid deadlock, during wait loops driver can "force ready" after some cycles.
// -------------------------------------------------------------------------
class axi_mm_driver #(
    int ADDR_WIDTH   = 32,
    int DATA_WIDTH   = 64,
    int ID_WIDTH     = 4,
    int WAIT_TIMEOUT = 1000   // cycles
) extends uvm_driver #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH));

    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_master vif;

    `uvm_component_param_utils(axi_mm_driver #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, WAIT_TIMEOUT))

    // ---------------------------------------------------------------------
    // Baseline knobs (existing)
    // ---------------------------------------------------------------------
    bit hold_bready_high = 1;
    bit hold_rready_high = 1;

    // ---------------------------------------------------------------------
    // Random stress knobs (defaults chosen to NOT change directed behavior)
    // Enable these in Random test via config_db
    // ---------------------------------------------------------------------
    bit stress_enable = 0;

    // Ready backpressure probabilities (0..100). If hold_*_high=1 these are ignored unless stress_enable=1
    int unsigned bready_prob = 100; // 100 => always ready
    int unsigned rready_prob = 100;

    // Random delays (cycles)
    int unsigned aw_pre_delay_max = 0; // insert [0..max] cycles before asserting AWVALID
    int unsigned ar_pre_delay_max = 0;

    // W behavior
    bit          w_streaming_mode = 0; // 0: pulsed (old behavior); 1: keep WVALID across beats (more realistic)
    int unsigned w_beat_gap_max   = 0; // insert [0..max] idle cycles between beats (even in streaming mode)

    // Safety: after this many cycles in a wait loop, temporarily force ready high to guarantee progress
    int unsigned force_ready_after = 64;

    // Random seed (optional)
    int unsigned stress_seed = 0;

    // ------------------------------------------------------------
    // AW latch (stable logs)
    // ------------------------------------------------------------
    logic [ADDR_WIDTH-1:0] aw_addr_lat;
    logic [7:0]            aw_len_lat;
    logic [2:0]            aw_size_lat;
    logic [1:0]            aw_burst_lat;
    logic [ID_WIDTH-1:0]   aw_id_lat;
    bit                    aw_lat_valid;

    // ------------------------------------------------------------
    // AR latch (stable logs)
    // ------------------------------------------------------------
    logic [ADDR_WIDTH-1:0] ar_addr_lat;
    logic [7:0]            ar_len_lat;
    logic [2:0]            ar_size_lat;
    logic [1:0]            ar_burst_lat;
    logic [ID_WIDTH-1:0]   ar_id_lat;
    bit                    ar_lat_valid;

    // ------------------------------------------------------------
    // B latch (stable logs)
    // ------------------------------------------------------------
    logic [ID_WIDTH-1:0]   b_id_lat;
    logic [1:0]            b_resp_lat;
    bit                    b_lat_valid;

    // ------------------------------------------------------------
    // R latch (stable logs for final beat)
    // ------------------------------------------------------------
    logic                  r_last_lat;
    logic [ID_WIDTH-1:0]   r_id_lat;
    bit                    r_lat_valid;

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

        // stress knobs (all optional)
        void'(uvm_config_db#(bit)::get(this, "", "stress_enable", stress_enable));
        void'(uvm_config_db#(int unsigned)::get(this, "", "bready_prob", bready_prob));
        void'(uvm_config_db#(int unsigned)::get(this, "", "rready_prob", rready_prob));
        void'(uvm_config_db#(int unsigned)::get(this, "", "aw_pre_delay_max", aw_pre_delay_max));
        void'(uvm_config_db#(int unsigned)::get(this, "", "ar_pre_delay_max", ar_pre_delay_max));
        void'(uvm_config_db#(bit)::get(this, "", "w_streaming_mode", w_streaming_mode));
        void'(uvm_config_db#(int unsigned)::get(this, "", "w_beat_gap_max", w_beat_gap_max));
        void'(uvm_config_db#(int unsigned)::get(this, "", "force_ready_after", force_ready_after));
        void'(uvm_config_db#(int unsigned)::get(this, "", "stress_seed", stress_seed));

        // clamp probs
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
        while (vif.rst_n !== 1'b1) begin
            @(vif.cb_master);
        end
        @(vif.cb_master);
    endtask

    task automatic abort_if_reset(input string where);
        if (vif.rst_n !== 1'b1) begin
            `uvm_fatal("HS_ABORT_RST", $sformatf("%s aborted by reset", where))
        end
    endtask

    // ---------------------------------------------------------------------
    // Stress helpers
    // ---------------------------------------------------------------------
    function automatic bit roll_prob(int unsigned prob_0_to_100);
        // Returns 1 with probability prob_0_to_100 (%)
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

    task automatic update_bready(input int unsigned wait_cyc);
        if (hold_bready_high && !stress_enable) begin
            vif.cb_master.bready <= 1'b1;
            return;
        end
        if (!stress_enable) begin
            // non-stress but not held-high
            vif.cb_master.bready <= vif.cb_master.bready;
            return;
        end
        // stress mode
        if (wait_cyc >= force_ready_after) begin
            vif.cb_master.bready <= 1'b1; // force progress
        end else begin
            vif.cb_master.bready <= roll_prob(bready_prob);
        end
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
        if (wait_cyc >= force_ready_after) begin
            vif.cb_master.rready <= 1'b1;
        end else begin
            vif.cb_master.rready <= roll_prob(rready_prob);
        end
    endtask

    // ------------------------------------------------------------
    // Init signals
    // ------------------------------------------------------------
    task automatic init_signals();
        @(vif.cb_master);
        vif.cb_master.awvalid <= 1'b0;
        vif.cb_master.arvalid <= 1'b0;

        vif.cb_master.wvalid  <= 1'b0;
        vif.cb_master.wlast   <= 1'b0;
        vif.cb_master.wdata   <= '0;
        vif.cb_master.wstrb   <= '0;

        // start READY defaults
        vif.cb_master.bready  <= (hold_bready_high) ? 1'b1 : 1'b0;
        vif.cb_master.rready  <= (hold_rready_high) ? 1'b1 : 1'b0;

        aw_addr_lat <= '0; aw_len_lat <= '0; aw_size_lat <= '0; aw_burst_lat <= '0; aw_id_lat <= '0; aw_lat_valid <= 0;
        ar_addr_lat <= '0; ar_len_lat <= '0; ar_size_lat <= '0; ar_burst_lat <= '0; ar_id_lat <= '0; ar_lat_valid <= 0;

        b_id_lat    <= '0; b_resp_lat <= '0; b_lat_valid <= 0;
        r_last_lat  <= 1'b0; r_id_lat  <= '0; r_lat_valid <= 0;

        if (stress_seed != 0) begin
            void'($urandom(stress_seed));
        end
    endtask

    function bit check_beats(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats = tr.len + 1;
        if (tr.rw == AXI_WRITE) begin
            if (tr.data_beats.size()  != beats) return 0;
            if (tr.wstrb_beats.size() != beats) return 0;
        end
        return 1;
    endfunction

    task run_phase(uvm_phase phase);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;

        init_signals();
        wait_reset_release();

        forever begin
            seq_item_port.get_next_item(tr);

            `uvm_info("DRV",
                $sformatf("Driving %s addr=0x%0h len=%0d id=%0d",
                          (tr.rw == AXI_WRITE) ? "WRITE" : " READ",
                          tr.addr, tr.len, tr.id),
                UVM_LOW)

            if (!check_beats(tr)) begin
                `uvm_error("DRV",
                    $sformatf("Bad beats payload sizes. rw=%0d addr=0x%0h len=%0d id=%0d",
                              tr.rw, tr.addr, tr.len, tr.id))
                seq_item_port.item_done();
                continue;
            end

            if (tr.rw == AXI_WRITE) drive_write(tr);
            else                   drive_read(tr);

            seq_item_port.item_done();
        end
    endtask

    // ------------------------------------------------------------
    // WRITE: AW then W then B
    // ------------------------------------------------------------
    task automatic drive_write(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats;
        bit aw_hs;
        bit b_hs;

        beats = tr.len + 1;
        aw_lat_valid = 0;
        b_lat_valid  = 0;

        // Random pre-delay before AW (stress only)
        maybe_wait_cycles(aw_pre_delay_max);

        // ---------------- AW ----------------
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
        if (!aw_hs) begin
            `uvm_fatal("HS_TIMEOUT",
                $sformatf("AW TIMEOUT (%0d cycles). addr=0x%0h id=%0d", WAIT_TIMEOUT, tr.addr, tr.id))
        end

        // drop awvalid next cycle
        @(vif.cb_master);
        vif.cb_master.awvalid <= 1'b0;

        // ---------------- W beats ----------------
        if (!w_streaming_mode) begin
            // pulsed mode (your old style) + optional random gaps
            for (int i = 0; i < beats; i++) begin
                bit w_hs;
                w_hs = 0;

                maybe_wait_cycles(w_beat_gap_max);

                @(vif.cb_master);
                abort_if_reset("W_BEAT_START");

                vif.cb_master.wvalid <= 1'b1;
                vif.cb_master.wdata  <= tr.data_beats[i];
                vif.cb_master.wstrb  <= tr.wstrb_beats[i];
                vif.cb_master.wlast  <= (i == beats-1);

                for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                    #1step;
                    abort_if_reset("W_WAIT");
                    if ((vif.cb_master.wvalid === 1'b1) && (vif.cb_master.wready === 1'b1)) begin
                        w_hs = 1;
                        break;
                    end
                    @(vif.cb_master);
                end

                if (!w_hs) begin
                    `uvm_fatal("HS_TIMEOUT",
                        $sformatf("W TIMEOUT (%0d cycles). addr=0x%0h id=%0d beat=%0d",
                                  WAIT_TIMEOUT, tr.addr, tr.id, i))
                end

                `uvm_info("DRV_DBG",
                    $sformatf("W HS beat=%0d data=0x%0h wstrb=0x%0h last=%0b",
                              i, tr.data_beats[i], tr.wstrb_beats[i], (i==beats-1)),
                    UVM_HIGH)

                @(vif.cb_master);
                abort_if_reset("W_BEAT_END");
                vif.cb_master.wvalid <= 1'b0;
                vif.cb_master.wlast  <= 1'b0;
            end
        end else begin
            // streaming mode: keep WVALID asserted across beats (more realistic)
            int i;
            i = 0;

            // optional gap before first beat
            maybe_wait_cycles(w_beat_gap_max);

            @(vif.cb_master);
            abort_if_reset("W_STREAM_START");

            vif.cb_master.wvalid <= 1'b1;
            vif.cb_master.wdata  <= tr.data_beats[0];
            vif.cb_master.wstrb  <= tr.wstrb_beats[0];
            vif.cb_master.wlast  <= (beats == 1);

            while (i < beats) begin
                bit hs_now;

                // Wait for handshake of current beat
                hs_now = 0;
                for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
                    #1step;
                    abort_if_reset("W_STREAM_WAIT");
                    if ((vif.cb_master.wvalid === 1'b1) && (vif.cb_master.wready === 1'b1)) begin
                        hs_now = 1;
                        break;
                    end
                    @(vif.cb_master);
                end
                if (!hs_now) begin
                    `uvm_fatal("HS_TIMEOUT",
                        $sformatf("W(stream) TIMEOUT (%0d cycles). addr=0x%0h id=%0d beat=%0d",
                                  WAIT_TIMEOUT, tr.addr, tr.id, i))
                end

                `uvm_info("DRV_DBG",
                    $sformatf("W HS(stream) beat=%0d data=0x%0h wstrb=0x%0h last=%0b",
                              i, tr.data_beats[i], tr.wstrb_beats[i], (i==beats-1)),
                    UVM_HIGH)

                // Advance to next beat on next cycle (or insert optional gap)
                i++;

                if (i >= beats) break;

                // Optionally insert idle cycles between beats:
                if (stress_enable && (w_beat_gap_max != 0)) begin
                    // Deassert wvalid during gap (harder corner)
                    vif.cb_master.wvalid <= 1'b0;
                    vif.cb_master.wlast  <= 1'b0;
                    maybe_wait_cycles(w_beat_gap_max);
                    @(vif.cb_master);
                    vif.cb_master.wvalid <= 1'b1;
                end else begin
                    @(vif.cb_master);
                end

                // Present next beat payload
                vif.cb_master.wdata <= tr.data_beats[i];
                vif.cb_master.wstrb <= tr.wstrb_beats[i];
                vif.cb_master.wlast <= (i == beats-1);
            end

            // drop wvalid after final beat
            @(vif.cb_master);
            abort_if_reset("W_STREAM_END");
            vif.cb_master.wvalid <= 1'b0;
            vif.cb_master.wlast  <= 1'b0;
        end

        // ---------------- B ----------------
        b_hs = 0;

        // If not held high, start from 0 then let update_bready drive it
        if (!hold_bready_high) begin
            @(vif.cb_master);
            vif.cb_master.bready <= 1'b0;
        end

        for (int unsigned cyc = 0; cyc < WAIT_TIMEOUT; cyc++) begin
            @(vif.cb_master);
            abort_if_reset("B_WAIT_TICK");

            // Update BREADY in stress mode
            update_bready(cyc);

            #1step;
            abort_if_reset("B_WAIT_SAMPLE");

            if ((vif.cb_master.bvalid === 1'b1) &&
                (vif.cb_master.bready === 1'b1)) begin
                b_hs = 1;
                b_id_lat    = vif.cb_master.bid;
                b_resp_lat  = vif.cb_master.bresp;
                b_lat_valid = 1;
                break;
            end
        end

        if (!b_hs) begin
            `uvm_fatal("HS_TIMEOUT",
                $sformatf("B TIMEOUT (%0d cycles). addr=0x%0h id=%0d", WAIT_TIMEOUT, tr.addr, tr.id))
        end

        tr.bresp = b_resp_lat;

        // Restore steady-state ready policy
        @(vif.cb_master);
        if (hold_bready_high) begin
            vif.cb_master.bready <= 1'b1;
        end else begin
            vif.cb_master.bready <= 1'b0;
        end

        `uvm_info("DRV",
            $sformatf("WRITE done: id=%0d BRESP=%0d | \n\n\
                                            AW(addr=0x%0h len=%0d size=%0d burst=%02b id=%0d) | \n\n\
                                            B(bid=%0d bresp=%0d)",
                      tr.id, tr.bresp,
                      (aw_lat_valid ? aw_addr_lat  : tr.addr),
                      (aw_lat_valid ? aw_len_lat   : tr.len),
                      (aw_lat_valid ? aw_size_lat  : tr.size),
                      (aw_lat_valid ? aw_burst_lat : tr.burst),
                      (aw_lat_valid ? aw_id_lat    : tr.id),
                      (b_lat_valid  ? b_id_lat     : 'x),
                      (b_lat_valid  ? b_resp_lat   : 'x)),
            UVM_LOW)
    endtask

    // ------------------------------------------------------------
    // READ: AR then capture R beats
    // ------------------------------------------------------------
    task automatic drive_read(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        int beats;
        bit ar_hs;

        beats = tr.len + 1;
        ar_lat_valid = 0;
        r_lat_valid  = 0;

        // Random pre-delay before AR (stress only)
        maybe_wait_cycles(ar_pre_delay_max);

        // ---------------- AR ----------------
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

        if (!ar_hs) begin
            `uvm_fatal("HS_TIMEOUT",
                $sformatf("AR TIMEOUT (%0d cycles). addr=0x%0h id=%0d", WAIT_TIMEOUT, tr.addr, tr.id))
        end

        // drop arvalid next cycle
        @(vif.cb_master);
        vif.cb_master.arvalid <= 1'b0;

        // ---------------- R beats ----------------
        // If not held high, start from 0 then let update_rready drive it
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

                if ((vif.cb_master.rvalid === 1'b1) &&
                    (vif.cb_master.rready === 1'b1)) begin
                    r_hs = 1;
                    break;
                end
            end

            if (!r_hs) begin
                `uvm_fatal("HS_TIMEOUT",
                    $sformatf("R TIMEOUT (%0d cycles). addr=0x%0h id=%0d beat=%0d",
                              WAIT_TIMEOUT, tr.addr, tr.id, i))
            end

            // Sample on handshake
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

        // Restore steady-state ready policy
        @(vif.cb_master);
        if (hold_rready_high) begin
            vif.cb_master.rready <= 1'b1;
        end else begin
            vif.cb_master.rready <= 1'b0;
        end

        `uvm_info("DRV",
            $sformatf("READ done: id=%0d beats=%0d first=0x%0h | \n\n\
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

endclass

`endif
