// File: tb/uvm/scoreboard/axi_mm_scoreboard.sv
`ifndef AXI_MM_SCOREBOARD_SV
`define AXI_MM_SCOREBOARD_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

// Create 3 different analysis_imp types: p0 / p1 / commit
`uvm_analysis_imp_decl(_p0)
`uvm_analysis_imp_decl(_p1)
`uvm_analysis_imp_decl(_commit)

class axi_mm_scoreboard #(
    int  ADDR_WIDTH          = 32,
    int  DATA_WIDTH          = 64,
    int  ID_WIDTH            = 4,
    int  DEPTH_WORDS         = 1024,
    bit  STRICT_RANGE        = 0,      // 0: modulo wrap / 1: out-of-range => error+ignore
    time COMMIT_STABLE_DELAY = 50ns    // bytes committed within this window are treated "unstable" for read-compare
) extends uvm_component;

    `uvm_component_param_utils(
        axi_mm_scoreboard #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS, STRICT_RANGE, COMMIT_STABLE_DELAY)
    )

    // -------------------------------------------------------------------------
    // Derived params
    // -------------------------------------------------------------------------
    localparam int BYTES_PER_BEAT = (DATA_WIDTH / 8);
    localparam int MEM_BYTES      = (DEPTH_WORDS * BYTES_PER_BEAT);

    localparam int unsigned MAX_SIZE_BYTES = BYTES_PER_BEAT;
    localparam int unsigned MAX_SIZE_LOG2  = $clog2(BYTES_PER_BEAT);

    localparam int COMMIT_BEAT_IDX_W = 8; // match your commit_if/item default

    typedef axi_mm_scoreboard#(
        ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS, STRICT_RANGE, COMMIT_STABLE_DELAY
    ) this_t;

    typedef axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)                 seq_t;
    typedef axi_mm_commit_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, COMMIT_BEAT_IDX_W) commit_t;

    // -------------------------------------------------------------------------
    // Analysis IMPs
    // -------------------------------------------------------------------------
    uvm_analysis_imp_p0     #(seq_t,    this_t) ap_imp_p0;
    uvm_analysis_imp_p1     #(seq_t,    this_t) ap_imp_p1;
    uvm_analysis_imp_commit #(commit_t, this_t) ap_imp_commit;

    // -------------------------------------------------------------------------
    // Robust processing: FIFOs per port + commit fifo
    // -------------------------------------------------------------------------
    uvm_tlm_analysis_fifo #(seq_t)    fifo_p0;
    uvm_tlm_analysis_fifo #(seq_t)    fifo_p1;
    uvm_tlm_analysis_fifo #(commit_t) fifo_commit;

    // -------------------------------------------------------------------------
    // Memory model (byte-addressed) driven by COMMIT beats
    // -------------------------------------------------------------------------
    bit  [7:0] mem_model        [0:MEM_BYTES-1];
    bit        written_model    [0:MEM_BYTES-1];
    time       last_commit_time [0:MEM_BYTES-1];

    // -------------------------------------------------------------------------
    // Window base (from env config_db)
    // -------------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0] win_base [2];

    // statistics
    int unsigned writes_seen_p0;
    int unsigned writes_seen_p1;
    int unsigned reads_seen_p0;
    int unsigned reads_seen_p1;
    int unsigned commit_beats_seen_p0;
    int unsigned commit_beats_seen_p1;
    int unsigned mismatches;

    // Reset/flush control (event-driven)
    bit          reset_pending;
    int unsigned reset_epoch;

    // Global events
    uvm_event ev_reset_assert;
    uvm_event ev_reset_deassert;
    uvm_event ev_flush;
    uvm_event ev_flush_done;

    // One-shot request flags for non-blocking flush() function override
    bit    req_flush_pending;
    bit    req_clear_mem;
    bit    req_clear_stats;
    string req_reason;

    // -------------------------------------------------------------------------
    // COMMIT apply scheduler (beat-level)
    // -------------------------------------------------------------------------
    typedef struct {
        time                          t_apply;
        int unsigned                  port;      // 0/1
        logic [ID_WIDTH-1:0]          id;
        logic [COMMIT_BEAT_IDX_W-1:0] beat_idx;
        logic [ADDR_WIDTH-1:0]        byte_addr;  // beat base address (byte address)
        logic [DATA_WIDTH-1:0]        wdata;
        logic [BYTES_PER_BEAT-1:0]    wstrb;
        logic [2:0]                   size;
        bit                           last;
    } commit_ev_t;

    commit_ev_t pending_commit_q[$];
    time        applied_commit_watermark;

    // -------------------------------------------------------------------------
    // ctor/build
    // -------------------------------------------------------------------------
    function new(string name = "axi_mm_scoreboard", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        ap_imp_p0     = new("ap_imp_p0", this);
        ap_imp_p1     = new("ap_imp_p1", this);
        ap_imp_commit = new("ap_imp_commit", this);

        fifo_p0     = new("fifo_p0", this);
        fifo_p1     = new("fifo_p1", this);
        fifo_commit = new("fifo_commit", this);

        win_base[0] = '0;
        win_base[1] = '0;

        void'(uvm_config_db#(logic [ADDR_WIDTH-1:0])::get(this, "", "WIN0_BASE", win_base[0]));
        void'(uvm_config_db#(logic [ADDR_WIDTH-1:0])::get(this, "", "WIN1_BASE", win_base[1]));

        `uvm_info("SCB",
                  $sformatf("WIN base: port0 WIN0_BASE=0x%0h, port1 WIN1_BASE=0x%0h, MEM_BYTES=%0d STRICT_RANGE=%0d COMMIT_STABLE_DELAY=%0t",
                            win_base[0], win_base[1], MEM_BYTES, STRICT_RANGE, COMMIT_STABLE_DELAY),
                  UVM_LOW)

        for (int i = 0; i < MEM_BYTES; i++) begin
            mem_model[i]        = '0;
            written_model[i]    = 1'b0;
            last_commit_time[i] = 0;
        end

        mismatches           = 0;
        writes_seen_p0       = 0;
        writes_seen_p1       = 0;
        reads_seen_p0        = 0;
        reads_seen_p1        = 0;
        commit_beats_seen_p0 = 0;
        commit_beats_seen_p1 = 0;

        reset_pending = 0;
        reset_epoch   = 0;

        ev_reset_assert   = uvm_event_pool::get_global("axi_mm_reset_assert");
        ev_reset_deassert = uvm_event_pool::get_global("axi_mm_reset_deassert");
        ev_flush          = uvm_event_pool::get_global("axi_mm_flush");
        ev_flush_done     = uvm_event_pool::get_global("axi_mm_flush_done");

        req_flush_pending = 0;
        req_clear_mem     = 0;
        req_clear_stats   = 0;
        req_reason        = "";

        pending_commit_q.delete();
        applied_commit_watermark = 0;
    endfunction

    // -------------------------------------------------------------------------
    // uvm_component has function void flush(); override as non-blocking request
    // IMPORTANT: flush() is a FUNCTION (must not block).
    // We only set a one-shot request, run thread will execute it safely.
    // -------------------------------------------------------------------------
    function void flush();
        req_flush_pending = 1;
        req_reason        = "uvm_component::flush()";
        req_clear_mem     = 0;
        req_clear_stats   = 0;

        // gate processing until run thread applies the request
        reset_pending     = 1;
    endfunction

    // -------------------------------------------------------------------------
    // Central clear helper (task)
    // -------------------------------------------------------------------------
    task automatic scb_clear_state(
        input string reason,
        input bit clear_mem,
        input bit clear_stats
    );
        `uvm_info("SCB", $sformatf("SCB_CLEAR: %s (clear_mem=%0d clear_stats=%0d) epoch->%0d",
                                  reason, clear_mem, clear_stats, reset_epoch+1), UVM_LOW)

        reset_pending = 1;
        reset_epoch++;

        fifo_p0.flush();
        fifo_p1.flush();
        fifo_commit.flush();

        pending_commit_q.delete();
        applied_commit_watermark = 0;

        if (clear_mem) begin
            for (int i = 0; i < MEM_BYTES; i++) begin
                mem_model[i]        = '0;
                written_model[i]    = 1'b0;
                last_commit_time[i] = 0;
            end
        end else begin
            // keep mem_model, but invalidate "written/stable" knowledge
            for (int i = 0; i < MEM_BYTES; i++) begin
                written_model[i] = 1'b0;
            end
        end

        if (clear_stats) begin
            mismatches           = 0;
            writes_seen_p0       = 0;
            writes_seen_p1       = 0;
            reads_seen_p0        = 0;
            reads_seen_p1        = 0;
            commit_beats_seen_p0 = 0;
            commit_beats_seen_p1 = 0;
        end
    endtask

    task scb_flush(string reason = "scb_flush", bit clear_mem = 0, bit clear_stats = 0);
        scb_clear_state(reason, clear_mem, clear_stats);
    endtask

    task resume_after_reset(string reason = "resume");
        `uvm_info("SCB", $sformatf("RESUME: %s (epoch=%0d)", reason, reset_epoch), UVM_LOW)
        reset_pending = 0;
    endtask

    // -------------------------------------------------------------------------
    // Manual deep-copy helpers (REAL deep copy, avoid dyn-array aliasing)
    // -------------------------------------------------------------------------
    function automatic seq_t deep_copy_seq_item(input seq_t tr);
        seq_t c;
        c = seq_t::type_id::create("scb_seq_copy");

        c.rw        = tr.rw;
        c.addr      = tr.addr;
        c.len       = tr.len;
        c.burst     = tr.burst;
        c.size      = tr.size;
        c.id        = tr.id;
        c.done_time = tr.done_time;
        c.start_time = tr.start_time;

        // READ arrays
        c.rdata_beats = new[tr.rdata_beats.size()];
        foreach (c.rdata_beats[i]) c.rdata_beats[i] = tr.rdata_beats[i];

        c.rresp_beats = new[tr.rresp_beats.size()];
        foreach (c.rresp_beats[i]) c.rresp_beats[i] = tr.rresp_beats[i];

        c.rtime_beats = new[tr.rtime_beats.size()];
        foreach (c.rtime_beats[i]) c.rtime_beats[i] = tr.rtime_beats[i];

        // WRITE arrays
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

    // -------------------------------------------------------------------------
    // Analysis callbacks (function => must not block)
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Helper: size field -> bytes (with sanity)
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Window mapping helpers (per-port)
    // -------------------------------------------------------------------------
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
        end else begin
            return int'(a % MEM_BYTES);
        end
    endfunction

    function automatic bit addr_in_range(int unsigned port, logic [ADDR_WIDTH-1:0] addr);
        if (STRICT_RANGE) return addr_in_window(port, addr);
        else              return 1'b1;
    endfunction

    // -------------------------------------------------------------------------
    // Helper: compute beat address for FIXED/INCR/WRAP (READ side)
    // -------------------------------------------------------------------------
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
            2'b00: return start_addr; // FIXED
            2'b01: return start_addr + (beat_index * beat_bytes); // INCR
            2'b10: begin // WRAP
                wrap_bytes = (len + 1) * beat_bytes;

                if ((wrap_bytes & (wrap_bytes - 1)) != 0) begin
                    `uvm_error("SCB", $sformatf(
                        "Illegal WRAP: wrap_bytes=%0d not power-of-2 (start=0x%0h len=%0d size=%0d)",
                        wrap_bytes, start_addr, len, size_field))
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

    // -------------------------------------------------------------------------
    // Helper: lane mask (valid lanes covered by this transfer)
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Byte stability check
    // -------------------------------------------------------------------------
    function automatic bit byte_is_stable(input int unsigned mem_idx, input time now_t);
        if (COMMIT_STABLE_DELAY == 0) return 1'b1;
        if (!written_model[mem_idx])  return 1'b0;
        if (now_t <= last_commit_time[mem_idx]) return 1'b0;
        return ((now_t - last_commit_time[mem_idx]) >= COMMIT_STABLE_DELAY);
    endfunction

    // -------------------------------------------------------------------------
    // WRITE: apply one beat into byte-model with WSTRB merge
    // -------------------------------------------------------------------------
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
                `uvm_error("SCB", $sformatf("WRITE out-of-window: port=%0d addr=0x%0h (WIN_BASE=0x%0h MEM_BYTES=%0d)",
                                            port, beat_addr + b, win_base[port & 1], MEM_BYTES))
                continue;
            end

            base_off = window_byte_offset(port, beat_addr + b);
            if (STRICT_RANGE && (base_off === '1)) begin
                continue;
            end

            mem_idx = base_off;

            if (wstrb[lane]) begin
                mem_model[mem_idx]        = wdata[8*lane +: 8];
                written_model[mem_idx]    = 1'b1;
                last_commit_time[mem_idx] = apply_t;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Commit queue sorted insert + apply up to time
    // -------------------------------------------------------------------------
    task automatic push_commit_event_sorted(input commit_ev_t ev);
        int pos;
        pos = pending_commit_q.size();
        while (pos > 0) begin
            if (pending_commit_q[pos-1].t_apply <= ev.t_apply) break;
            pos--;
        end
        pending_commit_q.insert(pos, ev);
    endtask

    task automatic apply_commits_up_to(input time t_limit);
        commit_ev_t ev;

        if (reset_pending) return;
        if (t_limit === 1'bx) return;

        if (t_limit < applied_commit_watermark)
            return;

        while (pending_commit_q.size() > 0) begin
            if (pending_commit_q[0].t_apply > t_limit) break;

            ev = pending_commit_q.pop_front();

            if (!size_is_legal(ev.size)) begin
                `uvm_error("SCB", $sformatf("Illegal commit size=%0d (>log2(%0d)) port=%0d id=0x%0h beat_idx=%0d addr=0x%0h",
                                            ev.size, BYTES_PER_BEAT, ev.port, ev.id, ev.beat_idx, ev.byte_addr))
            end

            // commit beat is the ground-truth visibility moment
            apply_beat_write(ev.port, ev.byte_addr, ev.size, ev.wdata, ev.wstrb, ev.t_apply);

            if (ev.port == 0) commit_beats_seen_p0++;
            else              commit_beats_seen_p1++;
        end

        applied_commit_watermark = t_limit;
    endtask

    // -------------------------------------------------------------------------
    // READ helpers
    // -------------------------------------------------------------------------
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

            rdata[8*lane +: 8] = mem_model[base_off];
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

    // -------------------------------------------------------------------------
    // Handle READ transaction
    // -------------------------------------------------------------------------
    task automatic handle_read(
        input seq_t tr,
        input int unsigned src_port
    );
        int unsigned beats;
        logic [ADDR_WIDTH-1:0] beat_addr;
        logic [DATA_WIDTH-1:0] expected, got;
        time beat_t;

        if (!size_is_legal(tr.size)) begin
            `uvm_error("SCB", $sformatf("Illegal size=%0d (>log2(%0d)) port=%0d id=0x%0h",
                                        tr.size, BYTES_PER_BEAT, src_port, tr.id))
        end

        beats = tr.len + 1;

        if (tr.rtime_beats.size() != beats || tr.rdata_beats.size() != beats) begin
            `uvm_warning("SCB",
                $sformatf("READ compare SKIPPED: missing/invalid beat arrays (id=0x%0h port=%0d beats=%0d rtime=%0d rdata=%0d).",
                          tr.id, src_port, beats, tr.rtime_beats.size(), tr.rdata_beats.size()))
            if (src_port == 0) reads_seen_p0++;
            else               reads_seen_p1++;
            return;
        end

        for (int i = 0; i < beats; i++) begin
            beat_addr = compute_beat_addr(tr.addr, tr.size, tr.len, tr.burst, i);
            beat_t    = tr.rtime_beats[i];

            // Make mem_model reflect all commits visible up to this beat time
            apply_commits_up_to(beat_t);

            if (!beat_is_fully_stable_written(src_port, beat_addr, tr.size, beat_t)) begin
                `uvm_info("SCB",
                    $sformatf("Skip read compare: not-committed/unstable beat_addr=0x%0h beat=%0d port=%0d id=0x%0h (stable_delay=%0t beat_t=%0t)",
                              beat_addr, i, src_port, tr.id, COMMIT_STABLE_DELAY, beat_t),
                    UVM_HIGH)
                continue;
            end

            compute_expected_beat_read(src_port, beat_addr, tr.size, expected);
            got = tr.rdata_beats[i];

            if (!beat_compare_ok(beat_addr, tr.size, expected, got)) begin
                mismatches++;
                `uvm_error("SCB",
                    $sformatf("READ MISMATCH port=%0d beat_addr=0x%0h beat=%0d exp=0x%0h got=0x%0h id=0x%0h burst=%02b size=%0d beat_t=%0t",
                              src_port, beat_addr, i, expected, got, tr.id, tr.burst, tr.size, beat_t))
            end
        end

        if (src_port == 0) reads_seen_p0++;
        else               reads_seen_p1++;
    endtask

    // -------------------------------------------------------------------------
    // Apply pending flush request from function flush()
    // -------------------------------------------------------------------------
    task automatic apply_flush_request_if_any();
        if (!req_flush_pending) return;

        scb_clear_state(req_reason, req_clear_mem, req_clear_stats);

        req_flush_pending = 0;
        req_reason        = "";
        req_clear_mem     = 0;
        req_clear_stats   = 0;
    endtask

    // -------------------------------------------------------------------------
    // Watchdogs: subscribe global events
    // -------------------------------------------------------------------------
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
            // Optional symmetry: if someone waits for flush_done, we can trigger it here too
            // (Your monitor triggers flush_done; double-trigger is harmless for uvm_event)
            ev_flush_done.trigger();
        end
    endtask

    // -------------------------------------------------------------------------
    // Run phase: consume FIFOs
    // -------------------------------------------------------------------------
    task run_phase(uvm_phase phase);
        seq_t    tr0;
        seq_t    tr1;
        commit_t cit;

        `uvm_info("SCB", $sformatf("Scoreboard started (STRICT_RANGE=%0d) [COMMIT-beat-driven visibility] stable_delay=%0t",
                                  STRICT_RANGE, COMMIT_STABLE_DELAY), UVM_LOW)

        fork : scb_threads
            reset_watchdog();
            reset_deassert_watchdog();
            flush_watchdog();

            // commit consumer
            forever begin
                if (reset_pending) begin
                    apply_flush_request_if_any();
                    #100ns;
                    continue;
                end

                if (fifo_commit.try_get(cit)) begin
                    commit_ev_t ev;
                    int unsigned p;

                    p = int'(cit.port) & 1;

                    ev.t_apply   = cit.commit_time;
                    ev.port      = p;
                    ev.id        = cit.id;
                    ev.beat_idx  = cit.beat_idx;
                    ev.byte_addr = cit.byte_addr;
                    ev.wdata     = cit.wdata;
                    ev.wstrb     = cit.wstrb;
                    ev.size      = cit.size;
                    ev.last      = cit.last;

                    push_commit_event_sorted(ev);
                end else begin
                    #1ns;
                end
            end

            // p0 consumer
            forever begin
                if (reset_pending) begin
                    apply_flush_request_if_any();
                    #100ns;
                    continue;
                end

                if (fifo_p0.try_get(tr0)) begin
                    if (tr0.rw == AXI_WRITE) begin
                        writes_seen_p0++;
                        // write items are not used for mem_model update (commit is truth)
                    end else begin
                        handle_read(tr0, 0);
                    end
                end else begin
                    #10ns;
                end
            end

            // p1 consumer
            forever begin
                if (reset_pending) begin
                    apply_flush_request_if_any();
                    #100ns;
                    continue;
                end

                if (fifo_p1.try_get(tr1)) begin
                    if (tr1.rw == AXI_WRITE) begin
                        writes_seen_p1++;
                    end else begin
                        handle_read(tr1, 1);
                    end
                end else begin
                    #10ns;
                end
            end

            // periodic stats
            forever begin
                #10000ns;
                `uvm_info("SCB", $sformatf(
                    "stats: writes(p0=%0d p1=%0d) commit_beats(p0=%0d p1=%0d) reads(p0=%0d p1=%0d) mismatches=%0d (epoch=%0d reset_pending=%0d) pending_commit=%0d",
                    writes_seen_p0, writes_seen_p1,
                    commit_beats_seen_p0, commit_beats_seen_p1,
                    reads_seen_p0, reads_seen_p1,
                    mismatches, reset_epoch, reset_pending,
                    pending_commit_q.size()
                ), UVM_LOW);
            end
        join_none

        if (phase.get_objection() != null) begin
            phase.get_objection().wait_for(UVM_ALL_DROPPED);
        end

        #100ns;
        disable scb_threads;
    endtask

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);

        `uvm_info("SCB",
                  $sformatf("FINAL stats: writes(p0=%0d p1=%0d) commit_beats(p0=%0d p1=%0d) reads(p0=%0d p1=%0d) mismatches=%0d pending_commit=%0d",
                            writes_seen_p0, writes_seen_p1,
                            commit_beats_seen_p0, commit_beats_seen_p1,
                            reads_seen_p0, reads_seen_p1,
                            mismatches, pending_commit_q.size()),
                  UVM_LOW)

        if (mismatches == 0)
            `uvm_info("SCB", "FINAL RESULT: PASS (no mismatches)", UVM_NONE)
        else
            `uvm_error("SCB", $sformatf("FINAL RESULT: FAIL (mismatches=%0d)", mismatches))
    endfunction

endclass : axi_mm_scoreboard

`endif