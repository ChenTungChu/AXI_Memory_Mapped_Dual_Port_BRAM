`ifndef AXI_MM_SCOREBOARD_SV
`define AXI_MM_SCOREBOARD_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

// ----------------------------------------------------------------------------
// Declare distinct analysis_imp callbacks for p0/p1
// ----------------------------------------------------------------------------
`uvm_analysis_imp_decl(_p0)
`uvm_analysis_imp_decl(_p1)

class axi_mm_scoreboard #(
    int ADDR_WIDTH      = 32,
    int DATA_WIDTH      = 64,
    int ID_WIDTH        = 4,
    int DEPTH_WORDS     = 1024,
    bit STRICT_RANGE    = 0   // 0: modulo wrap (方便 bring-up) / 1: out-of-range => error+ignore
) extends uvm_component;

    `uvm_component_utils(axi_mm_scoreboard #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, DEPTH_WORDS, STRICT_RANGE))

    // -------------------------------------------------------------------------
    // Derived params
    // -------------------------------------------------------------------------
    localparam int BYTES_PER_BEAT = DATA_WIDTH / 8;
    localparam int MEM_BYTES      = DEPTH_WORDS * BYTES_PER_BEAT;

    localparam int unsigned MAX_SIZE_BYTES = BYTES_PER_BEAT;
    localparam int unsigned MAX_SIZE_LOG2  = $clog2(BYTES_PER_BEAT);

    // -------------------------------------------------------------------------
    // Analysis IMPs (monitors connect here)
    // -------------------------------------------------------------------------
    uvm_analysis_imp_p0 #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH), axi_mm_scoreboard) ap_imp_p0;
    uvm_analysis_imp_p1 #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH), axi_mm_scoreboard) ap_imp_p1;

    // -------------------------------------------------------------------------
    // Robust processing: FIFOs per port (avoid fork in function)
    // -------------------------------------------------------------------------
    uvm_tlm_analysis_fifo #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)) fifo_p0;
    uvm_tlm_analysis_fifo #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)) fifo_p1;

    // -------------------------------------------------------------------------
    // Memory model (byte-addressed)
    // -------------------------------------------------------------------------
    bit [7:0] mem_model    [0:MEM_BYTES-1];
    bit       written_model[0:MEM_BYTES-1];

    // statistics
    int unsigned writes_seen_p0;
    int unsigned writes_seen_p1;
    int unsigned reads_seen_p0;
    int unsigned reads_seen_p1;
    int unsigned mismatches;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    function new(string name = "axi_mm_scoreboard", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // -------------------------------------------------------------------------
    // Build
    // -------------------------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        ap_imp_p0 = new("ap_imp_p0", this);
        ap_imp_p1 = new("ap_imp_p1", this);

        fifo_p0 = new("fifo_p0", this);
        fifo_p1 = new("fifo_p1", this);

        for (int i = 0; i < MEM_BYTES; i++) begin
            mem_model[i]     = '0;
            written_model[i] = 1'b0;
        end

        mismatches     = 0;
        writes_seen_p0 = 0;
        writes_seen_p1 = 0;
        reads_seen_p0  = 0;
        reads_seen_p1  = 0;
    endfunction

    // -------------------------------------------------------------------------
    // Analysis callbacks (function => must not block)
    // -------------------------------------------------------------------------
    function void write_p0(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) c;
        $cast(c, tr.clone()); // 依賴你的 do_copy() deep copy dynamic arrays
        fifo_p0.write(c);
    endfunction

    function void write_p1(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) c;
        $cast(c, tr.clone());
        fifo_p1.write(c);
    endfunction

    // -------------------------------------------------------------------------
    // Helper: size field -> bytes (with sanity)
    // -------------------------------------------------------------------------
    function automatic int unsigned size_to_bytes(logic [2:0] size_field);
        int unsigned bytes;
        if (size_field > MAX_SIZE_LOG2) begin
            bytes = MAX_SIZE_BYTES;
        end else begin
            bytes = (1 << size_field);
        end
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
    // Helper: compute beat address for FIXED/INCR/WRAP
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

                // AXI requirement: wrap_bytes must be power-of-2
                if ((wrap_bytes & (wrap_bytes - 1)) != 0) begin
                    `uvm_error("SCB", $sformatf(
                        "Illegal WRAP: wrap_bytes=%0d not power-of-2 (start=0x%0h len=%0d size=%0d)",
                        wrap_bytes, start_addr, len, size_field))
                    return start_addr; // fallback
                end

                // base = floor(start / wrap_bytes) * wrap_bytes
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

        // 若 addr 對 bytes 對齊且 BYTES_PER_BEAT 是 bytes 的倍數，就不會跨 beat boundary
        for (int b = 0; b < bytes; b++) begin
            m[(off + b) % BYTES_PER_BEAT] = 1'b1;
        end
        return m;
    endfunction

    // -------------------------------------------------------------------------
    // WRITE: apply one beat into byte-model with WSTRB merge
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
            lane    = (off + b) % BYTES_PER_BEAT;

            if (STRICT_RANGE) begin
                if (!addr_in_range(beat_addr + b)) begin
                    `uvm_error("SCB", $sformatf("WRITE out-of-range: addr=0x%0h (MEM_BYTES=%0d)", beat_addr + b, MEM_BYTES))
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
    // READ: check whether all bytes covered by this beat transfer are initialized
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

    // -------------------------------------------------------------------------
    // READ: build expected rdata for this beat transfer (only valid lanes filled)
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Compare got vs expected only on valid lanes (mask)
    // -------------------------------------------------------------------------
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
    // Handle a full WRITE transaction
    // -------------------------------------------------------------------------
    task automatic handle_write(
        input axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr,
        input int src_port
    );
        int unsigned beats;
        logic [ADDR_WIDTH-1:0] beat_addr;

        // size legality
        if (!size_is_legal(tr.size)) begin
            `uvm_error("SCB", $sformatf("Illegal size=%0d (>log2(%0d)) port=%0d id=0x%0h",
                                        tr.size, BYTES_PER_BEAT, src_port, tr.id))
        end

        beats = tr.len + 1;

        for (int i = 0; i < beats; i++) begin
            beat_addr = compute_beat_addr(tr.addr, tr.size, tr.len, tr.burst, i);
            apply_beat_write(beat_addr, tr.size, tr.data_beats[i], tr.wstrb_beats[i]);
        end

        if (src_port == 0) writes_seen_p0++;
        else               writes_seen_p1++;
    endtask

    // -------------------------------------------------------------------------
    // Handle a full READ transaction
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
                    $sformatf("Skip read compare: unwritten beat_addr=0x%0h beat=%0d port=%0d id=0x%0h",
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
    // Run phase: consume FIFOs and process deterministically
    // -------------------------------------------------------------------------
    task run_phase(uvm_phase phase);
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr0;
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr1;

        `uvm_info("SCB", $sformatf("Scoreboard started (STRICT_RANGE=%0d)", STRICT_RANGE), UVM_LOW)

        fork
            forever begin
                fifo_p0.get(tr0);
                if (tr0.rw == AXI_WRITE) handle_write(tr0, 0);
                else                     handle_read (tr0, 0);
            end

            forever begin
                fifo_p1.get(tr1);
                if (tr1.rw == AXI_WRITE) handle_write(tr1, 1);
                else                     handle_read (tr1, 1);
            end

            forever begin
                #10000ns;
                `uvm_info("SCB", $sformatf("stats: writes_p0=%0d writes_p1=%0d reads_p0=%0d reads_p1=%0d mismatches=%0d",
                                          writes_seen_p0, writes_seen_p1, reads_seen_p0, reads_seen_p1, mismatches),
                          UVM_LOW);
            end
        join
    endtask

    // -------------------------------------------------------------------------
    // Report phase
    // -------------------------------------------------------------------------
    function void report_phase(uvm_phase phase);
        super.report_phase(phase);

        `uvm_info("SCB", $sformatf("FINAL stats: writes_p0=%0d writes_p1=%0d reads_p0=%0d reads_p1=%0d mismatches=%0d", writes_seen_p0, writes_seen_p1, reads_seen_p0, reads_seen_p1, mismatches), UVM_LOW)

        if (mismatches == 0)
            `uvm_info("SCB", "FINAL RESULT: PASS (no mismatches)", UVM_NONE)
        else
            `uvm_error("SCB", $sformatf("FINAL RESULT: FAIL (mismatches=%0d)", mismatches))
    endfunction

endclass : axi_mm_scoreboard

`endif
