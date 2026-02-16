`ifndef AXI_MM_SCOREBOARD_SV
`define AXI_MM_SCOREBOARD_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

// Create 3 different analysis_imp types: p0 / p1 / commit
`uvm_analysis_imp_decl(_p0)
`uvm_analysis_imp_decl(_p1)
`uvm_analysis_imp_decl(_commit)

class axi_mm_scoreboard #(
    int ADDR_WIDTH      = 32,
    int DATA_WIDTH      = 64,
    int ID_WIDTH        = 4,
    int DEPTH_WORDS     = 1024,
    bit STRICT_RANGE    = 0   // 0: modulo wrap / 1: out-of-range => error+ignore
) extends uvm_component;

    `uvm_component_param_utils(
        axi_mm_scoreboard #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS, STRICT_RANGE)
    )

    // -------------------------------------------------------------------------
    // Derived params
    // -------------------------------------------------------------------------
    localparam int BYTES_PER_BEAT = DATA_WIDTH / 8;
    localparam int MEM_BYTES      = DEPTH_WORDS * BYTES_PER_BEAT;

    localparam int unsigned MAX_SIZE_BYTES = BYTES_PER_BEAT;
    localparam int unsigned MAX_SIZE_LOG2  = $clog2(BYTES_PER_BEAT);

    localparam int COMMIT_BEAT_IDX_W = 8; // match your commit_if/item default

    // -------------------------------------------------------------------------
    // IMPORTANT: Use fully-parameterized scoreboard type as 2nd template param
    // -------------------------------------------------------------------------
    typedef axi_mm_scoreboard#(
        ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS, STRICT_RANGE
    ) this_t;

    // -------------------------------------------------------------------------
    // Analysis IMPs
    // - ap_imp_p0 / ap_imp_p1 keep env compatibility
    // - ap_imp_commit: receives committed beats (ground truth for mem update)
    // -------------------------------------------------------------------------
    uvm_analysis_imp_p0     #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH), this_t) ap_imp_p0;
    uvm_analysis_imp_p1     #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH), this_t) ap_imp_p1;
    uvm_analysis_imp_commit #(axi_mm_commit_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, COMMIT_BEAT_IDX_W), this_t) ap_imp_commit;

    // -------------------------------------------------------------------------
    // Robust processing: FIFOs per port + commit fifo
    // -------------------------------------------------------------------------
    uvm_tlm_analysis_fifo #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)) fifo_p0;
    uvm_tlm_analysis_fifo #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)) fifo_p1;
    uvm_tlm_analysis_fifo #(axi_mm_commit_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, COMMIT_BEAT_IDX_W)) fifo_commit;

    // -------------------------------------------------------------------------
    // Memory model (byte-addressed)
    // IMPORTANT: updated ONLY by commit stream
    // -------------------------------------------------------------------------
    bit [7:0] mem_model     [0:MEM_BYTES-1];
    bit       written_model [0:MEM_BYTES-1];

    // statistics
    int unsigned writes_seen_p0;
    int unsigned writes_seen_p1;
    int unsigned reads_seen_p0;
    int unsigned reads_seen_p1;
    int unsigned commits_seen_p0;
    int unsigned commits_seen_p1;
    int unsigned mismatches;

    // -------------------------------------------------------------------------
    // Reset/flush control (event-driven)
    // -------------------------------------------------------------------------
    bit          reset_pending;     // gate processing + drop incoming
    int unsigned reset_epoch;

    // Global events
    uvm_event ev_reset_assert;
    uvm_event ev_reset_deassert;
    uvm_event ev_flush;
    uvm_event ev_flush_done;

    // One-shot request flags for non-blocking flush() function override
    bit    req_clear_mem;
    bit    req_clear_stats;
    string req_reason;

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

        for (int i = 0; i < MEM_BYTES; i++) begin
            mem_model[i]     = '0;
            written_model[i] = 1'b0;
        end

        mismatches      = 0;
        writes_seen_p0  = 0;
        writes_seen_p1  = 0;
        reads_seen_p0   = 0;
        reads_seen_p1   = 0;
        commits_seen_p0 = 0;
        commits_seen_p1 = 0;

        reset_pending = 0;
        reset_epoch   = 0;

        ev_reset_assert   = uvm_event_pool::get_global("axi_mm_reset_assert");
        ev_reset_deassert = uvm_event_pool::get_global("axi_mm_reset_deassert");
        ev_flush          = uvm_event_pool::get_global("axi_mm_flush");
        ev_flush_done     = uvm_event_pool::get_global("axi_mm_flush_done");

        req_clear_mem   = 0;
        req_clear_stats = 0;
        req_reason      = "";
    endfunction

    // -------------------------------------------------------------------------
    // uvm_component has function void flush(); override as non-blocking request
    // -------------------------------------------------------------------------
    function void flush();
        req_reason      = "uvm_component::flush()";
        req_clear_mem   = 0;
        req_clear_stats = 0;

        reset_pending   = 1;
        reset_epoch++;
    endfunction

    // -------------------------------------------------------------------------
    // Internal task: do the actual clearing work (blocking allowed)
    // -------------------------------------------------------------------------
    task automatic scb_clear_state(
        input string reason,
        input bit clear_mem,
        input bit clear_stats
    );
        `uvm_info("SCB", $sformatf("SCB_CLEAR: %s (clear_mem=%0d clear_stats=%0d) epoch->%0d",
                                      reason, clear_mem, clear_stats, reset_epoch), UVM_LOW)

        reset_pending = 1;
        reset_epoch++;

        fifo_p0.flush();
        fifo_p1.flush();
        fifo_commit.flush();

        if (clear_mem) begin
            for (int i = 0; i < MEM_BYTES; i++) begin
                mem_model[i]     = '0;
                written_model[i] = 1'b0;
            end
        end else begin
            for (int i = 0; i < MEM_BYTES; i++) begin
                written_model[i] = 1'b0;
            end
        end

        if (clear_stats) begin
            mismatches      = 0;
            writes_seen_p0  = 0;
            writes_seen_p1  = 0;
            reads_seen_p0   = 0;
            reads_seen_p1   = 0;
            commits_seen_p0 = 0;
            commits_seen_p1 = 0;
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
    // Analysis callbacks (function => must not block)
    // -------------------------------------------------------------------------
    function void write_p0(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) c;
        if (reset_pending) return;
        $cast(c, tr.clone());
        fifo_p0.write(c);
    endfunction

    function void write_p1(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) c;
        if (reset_pending) return;
        $cast(c, tr.clone());
        fifo_p1.write(c);
    endfunction

    function void write_commit(axi_mm_commit_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, COMMIT_BEAT_IDX_W) tr);
        axi_mm_commit_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, COMMIT_BEAT_IDX_W) c;
        if (reset_pending) return;
        $cast(c, tr.clone());
        fifo_commit.write(c);
    endfunction

    // -------------------------------------------------------------------------
    // Helper: size field -> bytes (with sanity)
    // -------------------------------------------------------------------------
    function automatic int unsigned size_to_bytes(logic [2:0] size_field);
        int unsigned bytes;
        if (size_field > MAX_SIZE_LOG2) bytes = MAX_SIZE_BYTES;
        else                            bytes = (1 << size_field);
        return bytes;
    endfunction

    function automatic bit size_is_legal(logic [2:0] size_field);
        return (size_field <= MAX_SIZE_LOG2);
    endfunction

    // -------------------------------------------------------------------------
    // Helper: address mapping into mem_model index
    // -------------------------------------------------------------------------
    function automatic int unsigned byte_index(logic [ADDR_WIDTH-1:0] addr);
        longint unsigned a;
        a = addr;
        return int'(a % MEM_BYTES);
    endfunction

    function automatic bit addr_in_range(logic [ADDR_WIDTH-1:0] addr);
        longint unsigned a;
        a = addr;
        return (a < MEM_BYTES);
    endfunction

    // -------------------------------------------------------------------------
    // Helper: compute beat address for FIXED/INCR/WRAP (used by READ compare)
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
        off   = addr % BYTES_PER_BEAT;

        for (int b = 0; b < bytes; b++) begin
            m[(off + b) % BYTES_PER_BEAT] = 1'b1;
        end
        return m;
    endfunction

    // -------------------------------------------------------------------------
    // WRITE: apply one beat into byte-model with WSTRB merge
    // (called ONLY from commit stream)
    // -------------------------------------------------------------------------
    task automatic apply_beat_write(
        input logic [ADDR_WIDTH-1:0]      beat_addr,
        input logic [2:0]                 size_field,
        input logic [DATA_WIDTH-1:0]      wdata,
        input logic [BYTES_PER_BEAT-1:0]  wstrb
    );
        int unsigned bytes;
        int unsigned off;
        int unsigned mem_idx;
        int unsigned lane;

        bytes = size_to_bytes(size_field);
        off   = beat_addr % BYTES_PER_BEAT;

        for (int b = 0; b < bytes; b++) begin
            lane = (off + b) % BYTES_PER_BEAT;

            if (STRICT_RANGE) begin
                if (!addr_in_range(beat_addr + b)) begin
                    `uvm_error("SCB", $sformatf("COMMIT-WRITE out-of-range: addr=0x%0h (MEM_BYTES=%0d)",
                                                beat_addr + b, MEM_BYTES))
                    continue;
                end
            end

            mem_idx = byte_index(beat_addr + b);

            if (wstrb[lane]) begin
                mem_model[mem_idx]     = wdata[8*lane +: 8];
                written_model[mem_idx] = 1'b1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // READ helpers
    // -------------------------------------------------------------------------
    function automatic bit beat_is_fully_written(
        input logic [ADDR_WIDTH-1:0] beat_addr,
        input logic [2:0]            size_field
    );
        int unsigned bytes;
        int unsigned mem_idx;

        bytes = size_to_bytes(size_field);

        for (int b = 0; b < bytes; b++) begin
            if (STRICT_RANGE && !addr_in_range(beat_addr + b))
                return 0;

            mem_idx = byte_index(beat_addr + b);
            if (!written_model[mem_idx])
                return 0;
        end
        return 1;
    endfunction

    task automatic compute_expected_beat_read(
        input  logic [ADDR_WIDTH-1:0] beat_addr,
        input  logic [2:0]            size_field,
        output logic [DATA_WIDTH-1:0] rdata
    );
        int unsigned bytes;
        int unsigned off;
        int unsigned mem_idx;
        int unsigned lane;

        rdata = '0;

        bytes = size_to_bytes(size_field);
        off   = beat_addr % BYTES_PER_BEAT;

        for (int b = 0; b < bytes; b++) begin
            lane = (off + b) % BYTES_PER_BEAT;

            if (STRICT_RANGE && !addr_in_range(beat_addr + b)) begin
                rdata[8*lane +: 8] = '0;
                continue;
            end

            mem_idx = byte_index(beat_addr + b);
            rdata[8*lane +: 8] = mem_model[mem_idx];
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
    // Handle READ transaction (compare against committed model)
    // -------------------------------------------------------------------------
    task automatic handle_read(
        input axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr,
        input int src_port
    );
        int unsigned beats;
        logic [ADDR_WIDTH-1:0] beat_addr;
        logic [DATA_WIDTH-1:0] expected, got;

        if (!size_is_legal(tr.size)) begin
            `uvm_error("SCB", $sformatf("Illegal size=%0d (>log2(%0d)) port=%0d id=0x%0h",
                                        tr.size, BYTES_PER_BEAT, src_port, tr.id))
        end

        beats = tr.len + 1;

        for (int i = 0; i < beats; i++) begin
            beat_addr = compute_beat_addr(tr.addr, tr.size, tr.len, tr.burst, i);

            if (!beat_is_fully_written(beat_addr, tr.size)) begin
                `uvm_info("SCB",
                    $sformatf("Skip read compare: not-committed/unwritten beat_addr=0x%0h beat=%0d port=%0d id=0x%0h",
                              beat_addr, i, src_port, tr.id),
                    UVM_HIGH)
                continue;
            end

            compute_expected_beat_read(beat_addr, tr.size, expected);
            got = tr.rdata_beats[i];

            if (!beat_compare_ok(beat_addr, tr.size, expected, got)) begin
                mismatches++;
                `uvm_error("SCB",
                    $sformatf("READ MISMATCH port=%0d beat_addr=0x%0h beat=%0d exp=0x%0h got=0x%0h id=0x%0h burst=%02b size=%0d",
                              src_port, beat_addr, i, expected, got, tr.id, tr.burst, tr.size))
            end
        end

        if (src_port == 0) reads_seen_p0++;
        else               reads_seen_p1++;
    endtask

    // -------------------------------------------------------------------------
    // Handle COMMIT beat (ground truth for write visibility)
    // -------------------------------------------------------------------------
    task automatic handle_commit(
        input axi_mm_commit_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, COMMIT_BEAT_IDX_W) it
    );
        if (!size_is_legal(it.size)) begin
            `uvm_error("SCB", $sformatf("Illegal commit size=%0d (>log2(%0d)) port=%0d id=0x%0h addr=0x%0h",
                                        it.size, BYTES_PER_BEAT, it.port, it.id, it.byte_addr))
        end

        apply_beat_write(it.byte_addr, it.size, it.wdata, it.wstrb);

        if (it.port == 0) commits_seen_p0++;
        else              commits_seen_p1++;
    endtask

    // -------------------------------------------------------------------------
    // Apply pending flush request from function flush()
    // -------------------------------------------------------------------------
    task automatic apply_flush_request_if_any();
        if (!reset_pending) return;

        if (req_reason != "") begin
            `uvm_warning("SCB", $sformatf("APPLY_FLUSH_REQUEST: %s (clear_mem=%0d clear_stats=%0d)",
                                          req_reason, req_clear_mem, req_clear_stats))

            fifo_p0.flush();
            fifo_p1.flush();
            fifo_commit.flush();

            if (req_clear_mem) begin
                for (int i = 0; i < MEM_BYTES; i++) begin
                    mem_model[i]     = '0;
                    written_model[i] = 1'b0;
                end
            end else begin
                for (int i = 0; i < MEM_BYTES; i++) begin
                    written_model[i] = 1'b0;
                end
            end

            if (req_clear_stats) begin
                mismatches      = 0;
                writes_seen_p0  = 0;
                writes_seen_p1  = 0;
                reads_seen_p0   = 0;
                reads_seen_p1   = 0;
                commits_seen_p0 = 0;
                commits_seen_p1 = 0;
            end

            req_reason      = "";
            req_clear_mem   = 0;
            req_clear_stats = 0;
        end
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
        end
    endtask

    // -------------------------------------------------------------------------
    // Run phase: consume FIFOs
    // - commit consumer updates mem_model
    // - read consumers compare against committed mem_model
    // - write transactions are counted but NOT applied to mem_model
    // -------------------------------------------------------------------------
    task run_phase(uvm_phase phase);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr0;
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr1;
        axi_mm_commit_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, COMMIT_BEAT_IDX_W) cit;

        `uvm_info("SCB", $sformatf("Scoreboard started (STRICT_RANGE=%0d) [mem updates from COMMIT]", STRICT_RANGE), UVM_LOW)

        fork : scb_threads
            reset_watchdog();
            reset_deassert_watchdog();
            flush_watchdog();

            // commit consumer (highest priority)
            forever begin
                if (reset_pending) begin
                    apply_flush_request_if_any();
                    #100ns;
                    continue;
                end

                if (fifo_commit.try_get(cit)) begin
                    handle_commit(cit);
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
                    if (tr0.rw == AXI_WRITE) writes_seen_p0++; // DO NOT update mem_model here
                    else                     handle_read(tr0, 0);
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
                    if (tr1.rw == AXI_WRITE) writes_seen_p1++; // DO NOT update mem_model here
                    else                     handle_read(tr1, 1);
                end else begin
                    #10ns;
                end
            end

            // periodic stats
            forever begin
                #10000ns;
                `uvm_info("SCB", $sformatf(
                    "stats: writes(p0=%0d p1=%0d) commits(p0=%0d p1=%0d) reads(p0=%0d p1=%0d) mismatches=%0d (epoch=%0d reset_pending=%0d)",
                    writes_seen_p0, writes_seen_p1,
                    commits_seen_p0, commits_seen_p1,
                    reads_seen_p0, reads_seen_p1,
                    mismatches, reset_epoch, reset_pending
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
                  $sformatf("FINAL stats: writes(p0=%0d p1=%0d) commits(p0=%0d p1=%0d) reads(p0=%0d p1=%0d) mismatches=%0d",
                            writes_seen_p0, writes_seen_p1,
                            commits_seen_p0, commits_seen_p1,
                            reads_seen_p0, reads_seen_p1,
                            mismatches),
                  UVM_LOW)

        if (mismatches == 0)
            `uvm_info("SCB", "FINAL RESULT: PASS (no mismatches)", UVM_NONE)
        else
            `uvm_error("SCB", $sformatf("FINAL RESULT: FAIL (mismatches=%0d)", mismatches))
    endfunction

endclass : axi_mm_scoreboard

`endif
