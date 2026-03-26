// File: tb/uvm/scoreboard/axi_mm_scoreboard.sv

`ifndef AXI_MM_SCOREBOARD_SV
`define AXI_MM_SCOREBOARD_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

// Create 4 different analysis_imp types
`uvm_analysis_imp_decl(_p0)
`uvm_analysis_imp_decl(_p1)
`uvm_analysis_imp_decl(_commit)
`uvm_analysis_imp_decl(_apply)

class axi_mm_scoreboard #(
    int  ADDR_WIDTH          = 32,
    int  DATA_WIDTH          = 64,
    int  ID_WIDTH            = 4,
    int  DEPTH_WORDS         = 1024,
    bit  STRICT_RANGE        = 0,      // 0: modulo wrap / 1: out-of-range -> error and ignore
    time COMMIT_STABLE_DELAY = 30ns    // Bytes committed within this window are treated unstable for read compare
) extends uvm_component;

    `uvm_component_param_utils(
        axi_mm_scoreboard #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS, STRICT_RANGE, COMMIT_STABLE_DELAY)
    )

    // Derived params
    localparam int BYTES_PER_BEAT = (DATA_WIDTH / 8);
    localparam int MEM_BYTES      = (DEPTH_WORDS * BYTES_PER_BEAT);

    localparam int unsigned MAX_SIZE_BYTES = BYTES_PER_BEAT;
    localparam int unsigned MAX_SIZE_LOG2  = $clog2(BYTES_PER_BEAT);

    localparam int COMMIT_BEAT_IDX_W = 8;
    localparam int APPLY_BEAT_IDX_W  = 8;

    typedef axi_mm_scoreboard#(
        ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS, STRICT_RANGE, COMMIT_STABLE_DELAY
    ) this_t;

    typedef axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) seq_t;
    typedef axi_mm_commit_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, COMMIT_BEAT_IDX_W) commit_t;
    typedef axi_mm_apply_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, APPLY_BEAT_IDX_W)   apply_t;

    // Analysis IMPs
    uvm_analysis_imp_p0     #(seq_t,    this_t) ap_imp_p0;
    uvm_analysis_imp_p1     #(seq_t,    this_t) ap_imp_p1;
    uvm_analysis_imp_commit #(commit_t, this_t) ap_imp_commit;
    uvm_analysis_imp_apply  #(apply_t,  this_t) ap_imp_apply;

    // FIFOs per port + commit/apply fifo
    uvm_tlm_analysis_fifo #(seq_t)    fifo_p0;
    uvm_tlm_analysis_fifo #(seq_t)    fifo_p1;
    uvm_tlm_analysis_fifo #(commit_t) fifo_commit;
    uvm_tlm_analysis_fifo #(apply_t)  fifo_apply;

    // Memory model
    bit  [7:0] mem_model        [0:MEM_BYTES-1];
    bit        written_model    [0:MEM_BYTES-1];
    time       last_commit_time [0:MEM_BYTES-1];

    typedef struct {
        time      t_commit;
        bit [7:0] data;
    } byte_hist_t;

    // Per-byte history, sorted by t_commit ascending
    byte_hist_t mem_hist [0:MEM_BYTES-1][$];

    // ------------------------------------------------------------
    // APPLY burst state
    // - DUT updates whole burst atomically before apply_if emission.
    // - All beats in the same apply burst must share the first-beat visibility time.
    // - While apply emission is still in progress, reads that touch the not-emitted tail of this burst must be deferred.
    // ------------------------------------------------------------
    typedef struct {
        bit                    valid;
        logic [ID_WIDTH-1:0]   id;
        time                   vis_time;
        int unsigned           next_beat_idx;

        logic [ADDR_WIDTH-1:0] first_addr;
        logic [ADDR_WIDTH-1:0] last_addr;
        int unsigned           beat_bytes;
        bit                    linear_incr_like;
    } apply_burst_state_t;

    apply_burst_state_t inflight_apply_burst[2];

    // ------------------------------------------------------------
    // Window base
    // ------------------------------------------------------------
    logic [ADDR_WIDTH-1:0] win_base [2];

    // Statistics
    int unsigned     writes_seen_p0;
    int unsigned     writes_seen_p1;
    int unsigned     reads_seen_p0;
    int unsigned     reads_seen_p1;
    int unsigned     commit_beats_seen_p0;
    int unsigned     commit_beats_seen_p1;
    int unsigned     mismatches;

    // Deferred read statistics
    int unsigned     reads_deferred;
    int unsigned     reads_retried_ok;
    int unsigned     reads_still_pending_final;

    int unsigned     pending_read_p0_final;
    int unsigned     pending_read_p1_final;

    int unsigned     pending_read_zero_retry_final;
    int unsigned     pending_read_nonzero_retry_final;

    int unsigned     pending_read_retry_hist_0;
    int unsigned     pending_read_retry_hist_1;
    int unsigned     pending_read_retry_hist_2_3;
    int unsigned     pending_read_retry_hist_4_7;
    int unsigned     pending_read_retry_hist_8_plus;

    int unsigned     pending_read_age_lt_100ns;
    int unsigned     pending_read_age_100ns_1us;
    int unsigned     pending_read_age_1us_10us;
    int unsigned     pending_read_age_ge_10us;

    int unsigned     pending_reason_no_written_byte;
    int unsigned     pending_reason_only_unstable_byte;
    int unsigned     pending_reason_mixed_no_written_and_unstable;
    int unsigned     pending_reason_other;

    int unsigned     pending_first_blocked_beat_min;
    int unsigned     pending_first_blocked_beat_max;
    longint unsigned pending_first_blocked_beat_sum;
    int unsigned     pending_first_blocked_beat_samples;

    // Reset/flush control
    bit              reset_pending;
    int unsigned     reset_epoch;

    // Global events
    uvm_event        ev_reset_assert;
    uvm_event        ev_reset_deassert;
    uvm_event        ev_flush;
    uvm_event        ev_flush_done;

    // One-shot request flags for flush() override
    bit              req_flush_pending;
    bit              req_clear_mem;
    bit              req_clear_stats;
    string           req_reason;

    // ------------------------------------------------------------
    // Commit apply scheduler
    // ------------------------------------------------------------
    typedef struct {
        time                          t_apply;
        int unsigned                  port;      // 0 / 1
        logic [ID_WIDTH-1:0]          id;
        logic [COMMIT_BEAT_IDX_W-1:0] beat_idx;
        logic [ADDR_WIDTH-1:0]        byte_addr; 
        logic [DATA_WIDTH-1:0]        wdata;
        logic [BYTES_PER_BEAT-1:0]    wstrb;
        logic [2:0]                   size;
        bit                           last;
    } commit_ev_t;

    commit_ev_t pending_commit_q[$];

    // ------------------------------------------------------------
    // Deferred read compare queue
    // ------------------------------------------------------------
    typedef struct {
        seq_t         tr;
        int unsigned  src_port;
        int unsigned  retry_count;
        time          enqueue_time;
    } pending_read_t;

    pending_read_t pending_read_q[$];

    typedef struct {
        bit          ready;
        int unsigned first_bad_beat;
        bit          saw_unwritten;
        bit          saw_unstable;
    } read_ready_info_t;

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------
    function new(string name = "axi_mm_scoreboard", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // ------------------------------------------------------------
    // Build phase
    // ------------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        ap_imp_p0     = new("ap_imp_p0", this);
        ap_imp_p1     = new("ap_imp_p1", this);
        ap_imp_commit = new("ap_imp_commit", this);
        ap_imp_apply  = new("ap_imp_apply", this);

        fifo_p0     = new("fifo_p0", this);
        fifo_p1     = new("fifo_p1", this);
        fifo_commit = new("fifo_commit", this);
        fifo_apply  = new("fifo_apply", this);

        win_base[0] = '0;
        win_base[1] = '0;

        void'(uvm_config_db#(logic [ADDR_WIDTH-1:0])::get(this, "", "WIN0_BASE", win_base[0]));
        void'(uvm_config_db#(logic [ADDR_WIDTH-1:0])::get(this, "", "WIN1_BASE", win_base[1]));

        `uvm_info("SCB", $sformatf("WIN base: port0 WIN0_BASE=0x%0h, port1 WIN1_BASE=0x%0h, MEM_BYTES=%0d STRICT_RANGE=%0d COMMIT_STABLE_DELAY=%0t", win_base[0], win_base[1], MEM_BYTES, STRICT_RANGE, COMMIT_STABLE_DELAY), UVM_LOW)

        for (int i = 0; i < MEM_BYTES; i++) begin
            mem_model[i]        = '0;
            written_model[i]    = 1'b0;
            last_commit_time[i] = 0;
            mem_hist[i].delete();
        end

        for (int p = 0; p < 2; p++) begin
            inflight_apply_burst[p].valid            = 1'b0;
            inflight_apply_burst[p].id               = '0;
            inflight_apply_burst[p].vis_time         = 0;
            inflight_apply_burst[p].next_beat_idx    = 0;
            inflight_apply_burst[p].first_addr       = '0;
            inflight_apply_burst[p].last_addr        = '0;
            inflight_apply_burst[p].beat_bytes       = 0;
            inflight_apply_burst[p].linear_incr_like = 1'b0;
        end

        mismatches                                   = 0;
        writes_seen_p0                               = 0;
        writes_seen_p1                               = 0;
        reads_seen_p0                                = 0;
        reads_seen_p1                                = 0;
        commit_beats_seen_p0                         = 0;
        commit_beats_seen_p1                         = 0;
        reads_deferred                               = 0;
        reads_retried_ok                             = 0;
        reads_still_pending_final                    = 0;

        pending_read_p0_final                        = 0;
        pending_read_p1_final                        = 0;
        pending_read_zero_retry_final                = 0;
        pending_read_nonzero_retry_final             = 0;
        pending_read_retry_hist_0                    = 0;
        pending_read_retry_hist_1                    = 0;
        pending_read_retry_hist_2_3                  = 0;
        pending_read_retry_hist_4_7                  = 0;
        pending_read_retry_hist_8_plus               = 0;
        pending_read_age_lt_100ns                    = 0;
        pending_read_age_100ns_1us                   = 0;
        pending_read_age_1us_10us                    = 0;
        pending_read_age_ge_10us                     = 0;
        pending_reason_no_written_byte               = 0;
        pending_reason_only_unstable_byte            = 0;
        pending_reason_mixed_no_written_and_unstable = 0;
        pending_reason_other                         = 0;
        pending_first_blocked_beat_min               = '1;
        pending_first_blocked_beat_max               = 0;
        pending_first_blocked_beat_sum               = 0;
        pending_first_blocked_beat_samples           = 0;

        reset_pending                                = 0;
        reset_epoch                                  = 0;

        ev_reset_assert                              = uvm_event_pool::get_global("axi_mm_reset_assert");
        ev_reset_deassert                            = uvm_event_pool::get_global("axi_mm_reset_deassert");
        ev_flush                                     = uvm_event_pool::get_global("axi_mm_flush");
        ev_flush_done                                = uvm_event_pool::get_global("axi_mm_flush_done");

        req_flush_pending                            = 0;
        req_clear_mem                                = 0;
        req_clear_stats                              = 0;
        req_reason                                   = "";

        pending_commit_q.delete();
        pending_read_q.delete();
    endfunction

    // ------------------------------------------------------------
    // Overrivde uvm_component built-in flush() function as non-blocking
    // ------------------------------------------------------------
    function void flush();
        req_flush_pending = 1;
        req_reason        = "uvm_component::flush()";
        req_clear_mem     = 0;
        req_clear_stats   = 0;
        reset_pending     = 1;
    endfunction

    // ------------------------------------------------------------
    // Hepler task: Central clear
    // ------------------------------------------------------------
    task automatic scb_clear_state(
        input string reason,
        input bit clear_mem,
        input bit clear_stats
    );
        `uvm_info("SCB", $sformatf("SCB_CLEAR: %s (clear_mem=%0d clear_stats=%0d) epoch->%0d", reason, clear_mem, clear_stats, reset_epoch+1), UVM_LOW)

        reset_pending = 1;
        reset_epoch++;

        fifo_p0.flush();
        fifo_p1.flush();
        fifo_commit.flush();
        fifo_apply.flush();

        pending_commit_q.delete();
        pending_read_q.delete();

        for (int i = 0; i < MEM_BYTES; i++) begin
            mem_model[i]        = '0;
            written_model[i]    = 1'b0;
            last_commit_time[i] = 0;
            mem_hist[i].delete();
        end

        for (int p = 0; p < 2; p++) begin
            inflight_apply_burst[p].valid            = 1'b0;
            inflight_apply_burst[p].id               = '0;
            inflight_apply_burst[p].vis_time         = 0;
            inflight_apply_burst[p].next_beat_idx    = 0;
            inflight_apply_burst[p].first_addr       = '0;
            inflight_apply_burst[p].last_addr        = '0;
            inflight_apply_burst[p].beat_bytes       = 0;
            inflight_apply_burst[p].linear_incr_like = 1'b0;
        end

        if (clear_stats) begin
            mismatches                                   = 0;
            writes_seen_p0                               = 0;
            writes_seen_p1                               = 0;
            reads_seen_p0                                = 0;
            reads_seen_p1                                = 0;
            commit_beats_seen_p0                         = 0;
            commit_beats_seen_p1                         = 0;
            reads_deferred                               = 0;
            reads_retried_ok                             = 0;
            reads_still_pending_final                    = 0;

            pending_read_p0_final                        = 0;
            pending_read_p1_final                        = 0;
            pending_read_zero_retry_final                = 0;
            pending_read_nonzero_retry_final             = 0;
            pending_read_retry_hist_0                    = 0;
            pending_read_retry_hist_1                    = 0;
            pending_read_retry_hist_2_3                  = 0;
            pending_read_retry_hist_4_7                  = 0;
            pending_read_retry_hist_8_plus               = 0;
            pending_read_age_lt_100ns                    = 0;
            pending_read_age_100ns_1us                   = 0;
            pending_read_age_1us_10us                    = 0;
            pending_read_age_ge_10us                     = 0;
            pending_reason_no_written_byte               = 0;
            pending_reason_only_unstable_byte            = 0;
            pending_reason_mixed_no_written_and_unstable = 0;
            pending_reason_other                         = 0;
            pending_first_blocked_beat_min               = '1;
            pending_first_blocked_beat_max               = 0;
            pending_first_blocked_beat_sum               = 0;
            pending_first_blocked_beat_samples           = 0;
        end
    endtask

    task scb_flush(string reason = "scb_flush", bit clear_mem = 0, bit clear_stats = 0);
        scb_clear_state(reason, clear_mem, clear_stats);
    endtask

    task resume_after_reset(string reason = "resume");
        `uvm_info("SCB", $sformatf("RESUME: %s (epoch=%0d)", reason, reset_epoch), UVM_LOW)
        reset_pending = 0;
    endtask

    // ------------------------------------------------------------
    // Helper functions: Deep copy
    // ------------------------------------------------------------
    function automatic seq_t deep_copy_seq_item(input seq_t tr);
        seq_t c;
        c = seq_t::type_id::create("scb_seq_copy");

        c.rw         = tr.rw;
        c.addr       = tr.addr;
        c.len        = tr.len;
        c.burst      = tr.burst;
        c.size       = tr.size;
        c.id         = tr.id;
        c.done_time  = tr.done_time;
        c.start_time = tr.start_time;
        c.op_kind    = tr.op_kind;
        c.bresp      = tr.bresp;

        c.rdata_beats = new[tr.rdata_beats.size()];
        foreach (c.rdata_beats[i]) c.rdata_beats[i] = tr.rdata_beats[i];

        c.rresp_beats = new[tr.rresp_beats.size()];
        foreach (c.rresp_beats[i]) c.rresp_beats[i] = tr.rresp_beats[i];

        c.rtime_beats = new[tr.rtime_beats.size()];
        foreach (c.rtime_beats[i]) c.rtime_beats[i] = tr.rtime_beats[i];

        c.wdata_beats = new[tr.wdata_beats.size()];
        foreach (c.wdata_beats[i]) c.wdata_beats[i] = tr.wdata_beats[i];

        c.wstrb_beats = new[tr.wstrb_beats.size()];
        foreach (c.wstrb_beats[i]) c.wstrb_beats[i] = tr.wstrb_beats[i];

        return c;
    endfunction

    function automatic commit_t deep_copy_commit_item(input commit_t tr);
        commit_t c;
        c = commit_t::type_id::create("scb_commit_copy");

        c.port        = tr.port;
        c.id          = tr.id;
        c.beat_idx    = tr.beat_idx;
        c.byte_addr   = tr.byte_addr;
        c.wdata       = tr.wdata;
        c.wstrb       = tr.wstrb;
        c.size        = tr.size;
        c.last        = tr.last;
        c.commit_time = tr.commit_time;

        return c;
    endfunction

    function automatic apply_t deep_copy_apply_item(input apply_t tr);
        apply_t c;
        c = apply_t::type_id::create("scb_apply_copy");

        c.port       = tr.port;
        c.id         = tr.id;
        c.beat_idx   = tr.beat_idx;
        c.byte_addr  = tr.byte_addr;
        c.wdata      = tr.wdata;
        c.wstrb      = tr.wstrb;
        c.size       = tr.size;
        c.last       = tr.last;
        c.apply_time = tr.apply_time;

        return c;
    endfunction

    // ------------------------------------------------------------
    // Analysis callbacks
    // ------------------------------------------------------------
    function void write_p0(seq_t tr);
        if (reset_pending) return;
        fifo_p0.write(deep_copy_seq_item(tr));
    endfunction

    function void write_p1(seq_t tr);
        if (reset_pending) return;
        fifo_p1.write(deep_copy_seq_item(tr));
    endfunction

    function void write_commit(commit_t tr);
        if (reset_pending) return;
        fifo_commit.write(deep_copy_commit_item(tr));
    endfunction

    function void write_apply(apply_t tr);
        if (reset_pending) return;
        fifo_apply.write(deep_copy_apply_item(tr));
    endfunction

    // ------------------------------------------------------------
    // Helper function: Size to bytes
    // ------------------------------------------------------------
    function automatic int unsigned size_to_bytes(logic [2:0] size_field);
        int unsigned bytes;
        if (size_field > MAX_SIZE_LOG2) bytes = MAX_SIZE_BYTES;
        else                            bytes = (1 << size_field);
        if (bytes == 0) bytes = 1;
        return bytes;
    endfunction

    function automatic bit size_is_legal(logic [2:0] size_field);
        return (size_field <= MAX_SIZE_LOG2);
    endfunction

    // ------------------------------------------------------------
    // Helper functions: Window mapping
    // ------------------------------------------------------------
    function automatic bit addr_in_window(int unsigned port, logic [ADDR_WIDTH-1:0] addr);
        longint unsigned a, b;
        a = addr;
        b = win_base[port & 1];
        return (a >= b) && (a < (b + MEM_BYTES));
    endfunction

    function automatic int unsigned window_byte_offset(int unsigned port, logic [ADDR_WIDTH-1:0] addr);
        longint unsigned a, b;
        a = addr;
        b = win_base[port & 1];

        if (addr_in_window(port, addr)) begin
            return int'(a - b);
        end

        if (STRICT_RANGE) begin
            return '1;
        end
        else begin
            return int'(a % MEM_BYTES);
        end
    endfunction

    function automatic bit addr_in_range(int unsigned port, logic [ADDR_WIDTH-1:0] addr);
        if (STRICT_RANGE) return addr_in_window(port, addr);
        else              return 1'b1;
    endfunction

    // ------------------------------------------------------------
    // Helper function: Compute beat address
    // ------------------------------------------------------------
    function automatic logic [ADDR_WIDTH-1:0] compute_beat_addr(
        input logic [ADDR_WIDTH-1:0] start_addr,
        input logic [2:0]            size_field,
        input logic [7:0]            len,
        input logic [1:0]            burst,
        input int unsigned           beat_index
    );
        int unsigned beat_bytes;
        int unsigned wrap_bytes;
        logic [ADDR_WIDTH-1:0] base;
        logic [ADDR_WIDTH-1:0] off;

        beat_bytes = size_to_bytes(size_field);

        unique case (burst)
            2'b00: return start_addr;                             // FIXED
            2'b01: return start_addr + (beat_index * beat_bytes); // INCR
            2'b10: begin                                          // WRAP
                wrap_bytes = (len + 1) * beat_bytes;

                if ((wrap_bytes & (wrap_bytes - 1)) != 0) begin
                    `uvm_error("SCB", $sformatf("Illegal WRAP: wrap_bytes=%0d not power-of-2 (start=0x%0h len=%0d size=%0d)", wrap_bytes, start_addr, len, size_field))
                    return start_addr;
                end

                base = (start_addr / wrap_bytes) * wrap_bytes;
                off  = (start_addr - base) + (beat_index * beat_bytes);
                off  = off % wrap_bytes;
                return base + off;
            end
            default: return start_addr;
        endcase
    endfunction

    // ------------------------------------------------------------
    // Helper function: Lane mask
    // ------------------------------------------------------------
    function automatic logic [BYTES_PER_BEAT-1:0] lane_mask(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [2:0]            size_field
    );
        logic [BYTES_PER_BEAT-1:0] m;
        int unsigned bytes;
        int unsigned off;

        m     = '0;
        bytes = size_to_bytes(size_field);
        off   = int'(addr % BYTES_PER_BEAT);

        for (int b = 0; b < bytes; b++) begin
            m[(off + b) % BYTES_PER_BEAT] = 1'b1;
        end
        return m;
    endfunction

    // ------------------------------------------------------------
    // History helpers
    // ------------------------------------------------------------
    function automatic void hist_insert_byte(
        input int unsigned mem_idx,
        input time         t_commit,
        input bit [7:0]    data
    );
        byte_hist_t ev;
        int pos;

        ev.t_commit = t_commit;
        ev.data     = data;

        pos = mem_hist[mem_idx].size();
        while (pos > 0) begin
            if (mem_hist[mem_idx][pos-1].t_commit <= t_commit)
                break;
            pos--;
        end

        mem_hist[mem_idx].insert(pos, ev);
    endfunction

    function automatic bit hist_byte_written_as_of(
        input int unsigned mem_idx,
        input time         t_query
    );
        for (int i = mem_hist[mem_idx].size()-1; i >= 0; i--) begin
            if (mem_hist[mem_idx][i].t_commit <= t_query)
                return 1'b1;
        end
        return 1'b0;
    endfunction

    function automatic time hist_last_commit_as_of(
        input int unsigned mem_idx,
        input time         t_query
    );
        for (int i = mem_hist[mem_idx].size()-1; i >= 0; i--) begin
            if (mem_hist[mem_idx][i].t_commit <= t_query)
                return mem_hist[mem_idx][i].t_commit;
        end
        return 0;
    endfunction

    function automatic bit [7:0] hist_byte_value_as_of(
        input int unsigned mem_idx,
        input time         t_query
    );
        for (int i = mem_hist[mem_idx].size()-1; i >= 0; i--) begin
            if (mem_hist[mem_idx][i].t_commit <= t_query)
                return mem_hist[mem_idx][i].data;
        end
        return '0;
    endfunction

    // ------------------------------------------------------------
    // Byte stability check
    // ------------------------------------------------------------
    function automatic bit byte_is_stable(input int unsigned mem_idx, input time now_t);
        time last_t;

        if (!hist_byte_written_as_of(mem_idx, now_t))
            return 1'b0;

        if (COMMIT_STABLE_DELAY == 0)
            return 1'b1;

        last_t = hist_last_commit_as_of(mem_idx, now_t);

        if (now_t <= last_t)
            return 1'b0;

        return ((now_t - last_t) >= COMMIT_STABLE_DELAY);
    endfunction

    // ------------------------------------------------------------
    // Apply beat write
    // ------------------------------------------------------------
    task automatic apply_beat_write(
        input int unsigned               port,
        input logic [ADDR_WIDTH-1:0]     beat_addr,
        input logic [2:0]                size_field,
        input logic [DATA_WIDTH-1:0]     wdata,
        input logic [BYTES_PER_BEAT-1:0] wstrb,
        input time                       apply_t
    );
        int unsigned bytes;
        int unsigned off;
        int unsigned lane;
        int unsigned base_off;
        int unsigned mem_idx;

        bytes = size_to_bytes(size_field);
        off   = int'(beat_addr % BYTES_PER_BEAT);

        for (int b = 0; b < bytes; b++) begin
            lane = (off + b) % BYTES_PER_BEAT;

            if (STRICT_RANGE && !addr_in_range(port, beat_addr + b)) begin
                `uvm_error("SCB", $sformatf("WRITE out-of-window: port=%0d addr=0x%0h (WIN_BASE=0x%0h MEM_BYTES=%0d)", port, beat_addr + b, win_base[port & 1], MEM_BYTES))
                continue;
            end

            base_off = window_byte_offset(port, beat_addr + b);
            if (STRICT_RANGE && (base_off === '1)) begin
                continue;
            end

            mem_idx = base_off;

            if (wstrb[lane]) begin
                bit [7:0] new_byte;

                new_byte = wdata[8*lane +: 8];

                mem_model[mem_idx]        = new_byte;
                written_model[mem_idx]    = 1'b1;
                last_commit_time[mem_idx] = apply_t;

                hist_insert_byte(mem_idx, apply_t, new_byte);
            end
        end
    endtask

    // ------------------------------------------------------------
    // Commit queue sorted insert
    // ------------------------------------------------------------
    task automatic push_commit_event_sorted(input commit_ev_t ev);
        int pos;
        pos = pending_commit_q.size();
        while (pos > 0) begin
            if (pending_commit_q[pos-1].t_apply <= ev.t_apply) break;
            pos--;
        end
        pending_commit_q.insert(pos, ev);
    endtask

    task automatic drain_commit_fifo();
        commit_t cit;
        int unsigned p;

        while (fifo_commit.try_get(cit)) begin
            p = int'(cit.port) & 1;

            if (!size_is_legal(cit.size)) begin
                `uvm_error("SCB", $sformatf(
                    "Illegal commit size=%0d (>log2(%0d)) port=%0d id=0x%0h beat_idx=%0d addr=0x%0h",
                    cit.size, BYTES_PER_BEAT, p, cit.id, cit.beat_idx, cit.byte_addr))
            end

            if (p == 0) commit_beats_seen_p0++;
            else        commit_beats_seen_p1++;
        end
    endtask

    // DUT visibility is burst-atomic, so all beats in the same apply burst share the first apply beat time as common visibility time
    task automatic drain_apply_fifo();
        apply_t ait;
        int unsigned p;
        time vis_t;
        int unsigned cur_bytes;

        while (fifo_apply.try_get(ait)) begin
            p = int'(ait.port) & 1;

            if (!size_is_legal(ait.size)) begin
                `uvm_error("SCB", $sformatf("Illegal apply size=%0d (>log2(%0d)) port=%0d id=0x%0h beat_idx=%0d addr=0x%0h", ait.size, BYTES_PER_BEAT, p, ait.id, ait.beat_idx, ait.byte_addr))
            end

            cur_bytes = size_to_bytes(ait.size);

            if ((ait.beat_idx == '0) ||
                (!inflight_apply_burst[p].valid) ||
                (inflight_apply_burst[p].id !== ait.id) ||
                (int'(ait.beat_idx) != inflight_apply_burst[p].next_beat_idx)) begin

                inflight_apply_burst[p].valid            = 1'b1;
                inflight_apply_burst[p].id               = ait.id;
                inflight_apply_burst[p].vis_time         = ait.apply_time;
                inflight_apply_burst[p].next_beat_idx    = int'(ait.beat_idx) + 1;
                inflight_apply_burst[p].first_addr       = ait.byte_addr;
                inflight_apply_burst[p].last_addr        = ait.byte_addr;
                inflight_apply_burst[p].beat_bytes       = cur_bytes;
                inflight_apply_burst[p].linear_incr_like = 1'b1;

                vis_t = ait.apply_time;
            end
            else begin
                vis_t = inflight_apply_burst[p].vis_time;

                if (inflight_apply_burst[p].linear_incr_like) begin
                    if ((cur_bytes != inflight_apply_burst[p].beat_bytes) || (ait.byte_addr != (inflight_apply_burst[p].last_addr + inflight_apply_burst[p].beat_bytes))) begin
                        inflight_apply_burst[p].linear_incr_like = 1'b0;
                    end
                end

                inflight_apply_burst[p].last_addr     = ait.byte_addr;
                inflight_apply_burst[p].next_beat_idx++;
            end

            apply_beat_write(p, ait.byte_addr, ait.size, ait.wdata, ait.wstrb, vis_t);

            if (ait.last) begin
                inflight_apply_burst[p].valid            = 1'b0;
                inflight_apply_burst[p].id               = '0;
                inflight_apply_burst[p].vis_time         = 0;
                inflight_apply_burst[p].next_beat_idx    = 0;
                inflight_apply_burst[p].first_addr       = '0;
                inflight_apply_burst[p].last_addr        = '0;
                inflight_apply_burst[p].beat_bytes       = 0;
                inflight_apply_burst[p].linear_incr_like = 1'b0;
            end
        end
    endtask

    task automatic apply_commits_up_to(input time t_limit);
        // no-op 
    endtask

    // ------------------------------------------------------------
    // READ helpers
    // ------------------------------------------------------------
    function automatic bit read_hits_any_inflight_apply_future_tail(
        input logic [ADDR_WIDTH-1:0] beat_addr,
        input logic [2:0]            size_field,
        input time                   beat_t
    );
        apply_burst_state_t st;
        logic [ADDR_WIDTH-1:0] emitted_end_addr;
        logic [ADDR_WIDTH-1:0] read_end_addr;
        int unsigned read_bytes;

        read_bytes   = size_to_bytes(size_field);
        read_end_addr = beat_addr + read_bytes - 1;

        for (int p = 0; p < 2; p++) begin
            st = inflight_apply_burst[p];

            if (!st.valid)
                continue;

            if (beat_t < st.vis_time)
                continue;

            if (!st.linear_incr_like)
                return 1'b1; 

            emitted_end_addr = st.last_addr + st.beat_bytes - 1;

            // Overlap with the not emitted tail of the current atomic apply burst
            if ((read_end_addr >= st.first_addr) &&
                (beat_addr <= st.last_addr + (st.beat_bytes * 256)) && // loose upper bound, safe
                (read_end_addr > emitted_end_addr)) begin
                return 1'b1;
            end
        end

        return 1'b0;
    endfunction

    function automatic bit beat_is_fully_stable_written(
        input int unsigned           port,
        input logic [ADDR_WIDTH-1:0] beat_addr,
        input logic [2:0]            size_field,
        input time                   now_t
    );
        int unsigned bytes;
        int unsigned base_off;

        bytes = size_to_bytes(size_field);

        for (int b = 0; b < bytes; b++) begin
            if (STRICT_RANGE && !addr_in_range(port, beat_addr + b))
                return 0;

            base_off = window_byte_offset(port, beat_addr + b);
            if (STRICT_RANGE && (base_off === '1))
                return 0;

            if (!byte_is_stable(base_off, now_t))
                return 0;
        end
        return 1;
    endfunction

    task automatic compute_expected_beat_read(
        input  int unsigned           port,
        input  logic [ADDR_WIDTH-1:0] beat_addr,
        input  logic [2:0]            size_field,
        input  time                   beat_t,
        output logic [DATA_WIDTH-1:0] rdata
    );
        int unsigned bytes;
        int unsigned off;
        int unsigned lane;
        int unsigned base_off;

        rdata = '0;

        bytes = size_to_bytes(size_field);
        off   = int'(beat_addr % BYTES_PER_BEAT);

        for (int b = 0; b < bytes; b++) begin
            lane = (off + b) % BYTES_PER_BEAT;

            if (STRICT_RANGE && !addr_in_range(port, beat_addr + b)) begin
                rdata[8*lane +: 8] = '0;
                continue;
            end

            base_off = window_byte_offset(port, beat_addr + b);
            if (STRICT_RANGE && (base_off === '1)) begin
                rdata[8*lane +: 8] = '0;
                continue;
            end

            rdata[8*lane +: 8] = hist_byte_value_as_of(base_off, beat_t);
        end
    endtask

    function automatic bit beat_compare_ok(
        input logic [ADDR_WIDTH-1:0] beat_addr,
        input logic [2:0]            size_field,
        input logic [DATA_WIDTH-1:0] exp,
        input logic [DATA_WIDTH-1:0] got
    );
        logic [BYTES_PER_BEAT-1:0] m;
        m = lane_mask(beat_addr, size_field);

        for (int lane = 0; lane < BYTES_PER_BEAT; lane++) begin
            if (m[lane]) begin
                if (got[8*lane +: 8] !== exp[8*lane +: 8])
                    return 0;
            end
        end
        return 1;
    endfunction

    function automatic bit read_fully_ready_to_compare(
        input seq_t tr,
        input int unsigned src_port
    );
        int unsigned beats;
        logic [ADDR_WIDTH-1:0] beat_addr;
        time beat_t;

        if (tr.rtime_beats.size() != (tr.len + 1) || tr.rdata_beats.size() != (tr.len + 1))
            return 0;

        beats = tr.len + 1;

        for (int i = 0; i < beats; i++) begin
            beat_addr = compute_beat_addr(tr.addr, tr.size, tr.len, tr.burst, i);
            beat_t    = tr.rtime_beats[i];

            drain_apply_fifo();
            drain_commit_fifo();
            apply_commits_up_to(beat_t);

            if (read_hits_any_inflight_apply_future_tail(beat_addr, tr.size, beat_t))
                return 0;

            if (!beat_is_fully_stable_written(src_port, beat_addr, tr.size, beat_t))
                return 0;
        end

        return 1;
    endfunction

    function automatic read_ready_info_t analyze_read_readiness(
        input seq_t tr,
        input int unsigned src_port
    );
        read_ready_info_t info;
        int unsigned beats;
        logic [ADDR_WIDTH-1:0] beat_addr;
        time beat_t;

        info.ready          = 1'b1;
        info.first_bad_beat = '1;
        info.saw_unwritten  = 1'b0;
        info.saw_unstable   = 1'b0;

        if (tr.rtime_beats.size() != (tr.len + 1) || tr.rdata_beats.size() != (tr.len + 1)) begin
            info.ready          = 1'b0;
            info.first_bad_beat = 0;
            return info;
        end

        beats = tr.len + 1;

        for (int i = 0; i < beats; i++) begin
            int unsigned bytes;
            logic [ADDR_WIDTH-1:0] cur_addr;
            int unsigned base_off;

            beat_addr = compute_beat_addr(tr.addr, tr.size, tr.len, tr.burst, i);
            beat_t    = tr.rtime_beats[i];

            drain_apply_fifo();
            drain_commit_fifo();
            apply_commits_up_to(beat_t);

            if (read_hits_any_inflight_apply_future_tail(beat_addr, tr.size, beat_t)) begin
                info.ready        = 1'b0;
                info.saw_unstable = 1'b1;
                if (info.first_bad_beat === '1) info.first_bad_beat = i;
                break;
            end

            bytes = size_to_bytes(tr.size);

            for (int b = 0; b < bytes; b++) begin
                cur_addr = beat_addr + b;

                if (STRICT_RANGE && !addr_in_range(src_port, cur_addr)) begin
                    info.ready = 1'b0;
                    if (info.first_bad_beat === '1) info.first_bad_beat = i;
                    return info;
                end

                base_off = window_byte_offset(src_port, cur_addr);
                if (STRICT_RANGE && (base_off === '1)) begin
                    info.ready = 1'b0;
                    if (info.first_bad_beat === '1) info.first_bad_beat = i;
                    return info;
                end

                if (!hist_byte_written_as_of(base_off, beat_t)) begin
                    info.ready         = 1'b0;
                    info.saw_unwritten = 1'b1;
                    if (info.first_bad_beat === '1) info.first_bad_beat = i;
                    break;
                end

                if (!byte_is_stable(base_off, beat_t)) begin
                    info.ready         = 1'b0;
                    info.saw_unstable  = 1'b1;
                    if (info.first_bad_beat === '1) info.first_bad_beat = i;
                    break;
                end
            end

            if (!info.ready)
                break;
        end

        return info;
    endfunction

    task automatic compute_pending_read_final_stats();
        pending_read_t      cur;
        read_ready_info_t   info;
        time                age_t;

        pending_read_p0_final                        = 0;
        pending_read_p1_final                        = 0;
        pending_read_zero_retry_final                = 0;
        pending_read_nonzero_retry_final             = 0;
        pending_read_retry_hist_0                    = 0;
        pending_read_retry_hist_1                    = 0;
        pending_read_retry_hist_2_3                  = 0;
        pending_read_retry_hist_4_7                  = 0;
        pending_read_retry_hist_8_plus               = 0;
        pending_read_age_lt_100ns                    = 0;
        pending_read_age_100ns_1us                   = 0;
        pending_read_age_1us_10us                    = 0;
        pending_read_age_ge_10us                     = 0;
        pending_reason_no_written_byte               = 0;
        pending_reason_only_unstable_byte            = 0;
        pending_reason_mixed_no_written_and_unstable = 0;
        pending_reason_other                         = 0;
        pending_first_blocked_beat_min               = '1;
        pending_first_blocked_beat_max               = 0;
        pending_first_blocked_beat_sum               = 0;
        pending_first_blocked_beat_samples           = 0;

        for (int i = 0; i < pending_read_q.size(); i++) begin
            cur = pending_read_q[i];

            if (cur.src_port == 0) pending_read_p0_final++;
            else                   pending_read_p1_final++;

            if (cur.retry_count == 0) pending_read_zero_retry_final++;
            else                      pending_read_nonzero_retry_final++;

            if (cur.retry_count == 0)      pending_read_retry_hist_0++;
            else if (cur.retry_count == 1) pending_read_retry_hist_1++;
            else if (cur.retry_count <= 3) pending_read_retry_hist_2_3++;
            else if (cur.retry_count <= 7) pending_read_retry_hist_4_7++;
            else                           pending_read_retry_hist_8_plus++;

            age_t = $time - cur.enqueue_time;
            if (age_t < 100ns)        pending_read_age_lt_100ns++;
            else if (age_t < 1us)     pending_read_age_100ns_1us++;
            else if (age_t < 10us)    pending_read_age_1us_10us++;
            else                      pending_read_age_ge_10us++;

            info = analyze_read_readiness(cur.tr, cur.src_port);

            if (info.first_bad_beat !== '1) begin
                if (info.first_bad_beat < pending_first_blocked_beat_min)
                    pending_first_blocked_beat_min = info.first_bad_beat;
                if (info.first_bad_beat > pending_first_blocked_beat_max)
                    pending_first_blocked_beat_max = info.first_bad_beat;
                pending_first_blocked_beat_sum += info.first_bad_beat;
                pending_first_blocked_beat_samples++;
            end

            if (info.saw_unwritten && !info.saw_unstable)
                pending_reason_no_written_byte++;
            else if (!info.saw_unwritten && info.saw_unstable)
                pending_reason_only_unstable_byte++;
            else if (info.saw_unwritten && info.saw_unstable)
                pending_reason_mixed_no_written_and_unstable++;
            else
                pending_reason_other++;
        end
    endtask

    task automatic compare_read_fully(
        input seq_t tr,
        input int unsigned src_port
    );
        int unsigned beats;
        logic [ADDR_WIDTH-1:0] beat_addr;
        logic [DATA_WIDTH-1:0] expected, got;
        time beat_t;

        beats = tr.len + 1;

        for (int i = 0; i < beats; i++) begin
            beat_addr = compute_beat_addr(tr.addr, tr.size, tr.len, tr.burst, i);
            beat_t    = tr.rtime_beats[i];

            drain_apply_fifo();
            drain_commit_fifo();
            apply_commits_up_to(beat_t);

            compute_expected_beat_read(src_port, beat_addr, tr.size, beat_t, expected);
            got = tr.rdata_beats[i];

            if (!beat_compare_ok(beat_addr, tr.size, expected, got)) begin
                int unsigned bytes;
                int unsigned off;

                mismatches++;

                `uvm_error("SCB", $sformatf("READ MISMATCH: port=%0d beat_addr=0x%0h beat=%0d exp=0x%0h got=0x%0h id=0x%0h burst=%02b size=%0d beat_t=%0t", src_port, beat_addr, i, expected, got, tr.id, tr.burst, tr.size, beat_t))

                bytes = size_to_bytes(tr.size);
                off   = int'(beat_addr % BYTES_PER_BEAT);

                for (int b = 0; b < bytes; b++) begin
                    int unsigned lane;
                    int unsigned cur_addr;
                    int unsigned base_off;
                    bit [7:0] hist_val;
                    time hist_t;

                    lane     = (off + b) % BYTES_PER_BEAT;
                    cur_addr = beat_addr + b;
                    base_off = window_byte_offset(src_port, cur_addr);

                    hist_val = hist_byte_value_as_of(base_off, beat_t);
                    hist_t   = hist_last_commit_as_of(base_off, beat_t);

                    `uvm_info("SCB_DBG", $sformatf("byte[%0d] lane=%0d cur_addr=0x%0h mem_idx=%0d exp_byte=0x%02h got_byte=0x%02h written_as_of=%0b last_commit_as_of=%0t hist_val=0x%02h", b, lane, cur_addr, base_off, expected[8*lane +: 8], got[8*lane +: 8], hist_byte_written_as_of(base_off, beat_t), hist_t, hist_val), UVM_NONE)
                end
            end
        end
    endtask

    task automatic enqueue_read_for_retry(
        input seq_t tr,
        input int unsigned src_port
    );
        pending_read_t e;
        e.tr           = deep_copy_seq_item(tr);
        e.src_port     = src_port;
        e.retry_count  = 0;
        e.enqueue_time = $time;
        pending_read_q.push_back(e);
        reads_deferred++;

        `uvm_info("SCB", $sformatf("Defer read compare: port=%0d id=0x%0h addr=0x%0h beats=%0d pending_read_q=%0d", src_port, tr.id, tr.addr, tr.len+1, pending_read_q.size()), UVM_HIGH)
    endtask

    // ------------------------------------------------------------
    // Handle read transaction
    // ------------------------------------------------------------
    task automatic handle_read(
        input seq_t tr,
        input int unsigned src_port
    );
        if (!size_is_legal(tr.size)) begin
            `uvm_error("SCB", $sformatf("Illegal size=%0d (>log2(%0d)) port=%0d id=0x%0h", tr.size, BYTES_PER_BEAT, src_port, tr.id))
        end

        if (tr.rtime_beats.size() != (tr.len + 1) || tr.rdata_beats.size() != (tr.len + 1)) begin
            `uvm_warning("SCB", $sformatf("READ compare skipped: missing/invalid beat arrays (id=0x%0h port=%0d beats=%0d rtime=%0d rdata=%0d).", tr.id, src_port, (tr.len+1), tr.rtime_beats.size(), tr.rdata_beats.size()))
            if (src_port == 0) reads_seen_p0++;
            else               reads_seen_p1++;
            return;
        end

        if (read_fully_ready_to_compare(tr, src_port)) begin
            compare_read_fully(tr, src_port);
        end
        else begin
            int unsigned beats;
            logic [ADDR_WIDTH-1:0] beat_addr;
            time beat_t;
            beats = tr.len + 1;

            for (int i = 0; i < beats; i++) begin
                beat_addr = compute_beat_addr(tr.addr, tr.size, tr.len, tr.burst, i);
                beat_t    = tr.rtime_beats[i];

                drain_apply_fifo();
                drain_commit_fifo();
                apply_commits_up_to(beat_t);

                if (read_hits_any_inflight_apply_future_tail(beat_addr, tr.size, beat_t)) begin
                    `uvm_info("SCB",
                        $sformatf("Skip read compare: apply future tail beat_addr=0x%0h beat=%0d port=%0d id=0x%0h beat_t=%0t", beat_addr, i, src_port, tr.id, beat_t), UVM_HIGH)
                    break;
                end

                if (!beat_is_fully_stable_written(src_port, beat_addr, tr.size, beat_t)) begin
                    `uvm_info("SCB",
                        $sformatf("Skip read compare: notapplied/unstable beat_addr=0x%0h beat=%0d port=%0d id=0x%0h (stable_delay=%0t beat_t=%0t)", beat_addr, i, src_port, tr.id, COMMIT_STABLE_DELAY, beat_t), UVM_HIGH)
                    break;
                end
            end

            enqueue_read_for_retry(tr, src_port);
        end

        if (src_port == 0) reads_seen_p0++;
        else               reads_seen_p1++;
    endtask

    task automatic retry_pending_reads();
        pending_read_t cur;
        pending_read_t keep_q[$];

        if (reset_pending) return;

        drain_apply_fifo();
        drain_commit_fifo();

        while (pending_read_q.size() > 0) begin
            cur = pending_read_q.pop_front();

            if (read_fully_ready_to_compare(cur.tr, cur.src_port)) begin
                compare_read_fully(cur.tr, cur.src_port);
                reads_retried_ok++;
                `uvm_info("SCB", $sformatf("Deferred read compare completed: port=%0d id=0x%0h addr=0x%0h retries=%0d", cur.src_port, cur.tr.id, cur.tr.addr, cur.retry_count), UVM_HIGH)
            end
            else begin
                cur.retry_count++;
                keep_q.push_back(cur);
            end
        end

        pending_read_q = keep_q;
    endtask

    // ------------------------------------------------------------
    // Apply pending flush request from flush()
    // ------------------------------------------------------------
    task automatic apply_flush_request_if_any();
        if (!req_flush_pending) return;

        scb_clear_state(req_reason, req_clear_mem, req_clear_stats);

        req_flush_pending = 0;
        req_reason        = "";
        req_clear_mem     = 0;
        req_clear_stats   = 0;
    endtask

    // ------------------------------------------------------------
    // Watchdogs for subscribe global events
    // ------------------------------------------------------------
    task automatic reset_watchdog();
        forever begin
            ev_reset_assert.wait_trigger();
            scb_clear_state("axi_mm_reset_assert", /*clear_mem*/ 0, /*clear_stats*/ 0);
            `uvm_info("SCB_RST", $sformatf("Got axi_mm_reset_assert (epoch=%0d)", reset_epoch), UVM_LOW)
        end
    endtask

    task automatic reset_deassert_watchdog();
        forever begin
            ev_reset_deassert.wait_trigger();
            resume_after_reset("axi_mm_reset_deassert");
        end
    endtask

    task automatic flush_watchdog();
        forever begin
            ev_flush.wait_trigger();
            scb_clear_state("axi_mm_flush", /*clear_mem*/ 0, /*clear_stats*/ 0);
            `uvm_info("SCB_FLUSH", $sformatf("Got axi_mm_flush (epoch=%0d)", reset_epoch), UVM_LOW)
            ev_flush_done.trigger();
        end
    endtask

    // ------------------------------------------------------------
    // Run phase
    // ------------------------------------------------------------
    task run_phase(uvm_phase phase);
        seq_t tr0;
        seq_t tr1;

        `uvm_info("SCB", $sformatf("Scoreboard started (STRICT_RANGE=%0d) [APPLY-driven visibility + deferred read compare] stable_delay=%0t", STRICT_RANGE, COMMIT_STABLE_DELAY), UVM_LOW)

        fork : scb_threads
            reset_watchdog();
            reset_deassert_watchdog();
            flush_watchdog();

            // Apply consumer
            forever begin
                if (reset_pending) begin
                    apply_flush_request_if_any();
                    #100ns;
                    continue;
                end
                drain_apply_fifo();
                #1ns;
            end

            // Commit consumer
            forever begin
                if (reset_pending) begin
                    apply_flush_request_if_any();
                    #100ns;
                    continue;
                end
                drain_commit_fifo();
                #1ns;
            end

            // Deferred read retry
            forever begin
                if (reset_pending) begin
                    apply_flush_request_if_any();
                    #100ns;
                    continue;
                end
                retry_pending_reads();
                #20ns;
            end

            // P0 consumer
            forever begin
                if (reset_pending) begin
                    apply_flush_request_if_any();
                    #100ns;
                    continue;
                end

                if (fifo_p0.try_get(tr0)) begin
                    if (tr0.rw == AXI_WRITE) begin
                        writes_seen_p0++;
                    end
                    else begin
                        handle_read(tr0, 0);
                    end
                end
                else begin
                    #10ns;
                end
            end

            // P1 consumer
            forever begin
                if (reset_pending) begin
                    apply_flush_request_if_any();
                    #100ns;
                    continue;
                end

                if (fifo_p1.try_get(tr1)) begin
                    if (tr1.rw == AXI_WRITE) begin
                        writes_seen_p1++;
                    end
                    else begin
                        handle_read(tr1, 1);
                    end
                end
                else begin
                    #10ns;
                end
            end

            // Periodic stats
            forever begin
                #10000ns;
                `uvm_info("SCB", $sformatf(
                    "Stats: writes(p0=%0d p1=%0d) commit_beats(p0=%0d p1=%0d) reads(p0=%0d p1=%0d) mismatches=%0d deferred=%0d retried_ok=%0d pending_read=%0d pending_commit=%0d (epoch=%0d reset_pending=%0d)",
                    writes_seen_p0, writes_seen_p1,
                    commit_beats_seen_p0, commit_beats_seen_p1,
                    reads_seen_p0, reads_seen_p1,
                    mismatches,
                    reads_deferred, reads_retried_ok,
                    pending_read_q.size(),
                    pending_commit_q.size(), reset_epoch, reset_pending), UVM_LOW);
            end
        join_none

        if (phase.get_objection() != null) begin
            phase.get_objection().wait_for(UVM_ALL_DROPPED);
        end

        // Retry path
        repeat (20) begin
            drain_apply_fifo();
            drain_commit_fifo();
            retry_pending_reads();
            #20ns;
        end

        #100ns;
        disable scb_threads;
    endtask

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);

        reads_still_pending_final = pending_read_q.size();

        // Final categorization of remaining pending reads
        compute_pending_read_final_stats();

        `uvm_info("SCB", $sformatf("Final stats: writes(p0=%0d p1=%0d) commit_beats(p0=%0d p1=%0d) reads(p0=%0d p1=%0d) mismatches=%0d deferred=%0d retried_ok=%0d pending_read=%0d pending_commit=%0d",
                            writes_seen_p0, writes_seen_p1,
                            commit_beats_seen_p0, commit_beats_seen_p1,
                            reads_seen_p0, reads_seen_p1,
                            mismatches,
                            reads_deferred, reads_retried_ok,
                            pending_read_q.size(), pending_commit_q.size()), UVM_LOW)

        if (pending_read_q.size() != 0) begin
            `uvm_warning("SCB", $sformatf("Final: %0d deferred read(s) still pending compare at end of test", pending_read_q.size()))

            `uvm_info("SCB", $sformatf("Final deferred breakdown: p0=%0d p1=%0d | retry_count: 0=%0d 1=%0d 2_3=%0d 4_7=%0d 8_plus=%0d | age: <100ns=%0d 100ns_1us=%0d 1us_10us=%0d >=10us=%0d",
                    pending_read_p0_final, pending_read_p1_final,
                    pending_read_retry_hist_0, pending_read_retry_hist_1,
                    pending_read_retry_hist_2_3, pending_read_retry_hist_4_7,
                    pending_read_retry_hist_8_plus,
                    pending_read_age_lt_100ns, pending_read_age_100ns_1us,
                    pending_read_age_1us_10us, pending_read_age_ge_10us), UVM_LOW)

            `uvm_info("SCB", $sformatf("Final deferred reason: no_written=%0d unstable_only=%0d mixed=%0d other=%0d",
                    pending_reason_no_written_byte,
                    pending_reason_only_unstable_byte,
                    pending_reason_mixed_no_written_and_unstable,
                    pending_reason_other), UVM_LOW)

            if (pending_first_blocked_beat_samples != 0) begin
                `uvm_info("SCB", $sformatf("Final deferred first_bad_beat: min=%0d max=%0d avg=%0f samples=%0d",
                    pending_first_blocked_beat_min,
                    pending_first_blocked_beat_max,
                    real'(pending_first_blocked_beat_sum) / pending_first_blocked_beat_samples,
                    pending_first_blocked_beat_samples), UVM_LOW)
            end
        end

        if (mismatches == 0)
            `uvm_info("SCB", "FINAL RESULT: PASS (no mismatches)", UVM_NONE)
        else
            `uvm_error("SCB", $sformatf("FINAL RESULT: FAIL (mismatches=%0d)", mismatches))
    endfunction

endclass : axi_mm_scoreboard

`endif
