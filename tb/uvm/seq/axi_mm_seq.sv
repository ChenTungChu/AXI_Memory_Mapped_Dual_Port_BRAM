// File: tb/uvm/seq/axi_mm_seq.sv
`ifndef AXI_MM_SEQ_SV
`define AXI_MM_SEQ_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

class axi_mm_seq #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4
) extends uvm_sequence #(
    axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)
);

    `uvm_object_param_utils(axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

    // ------------------------------------------------------------
    // Random mode knobs
    // ------------------------------------------------------------
    rand int unsigned           num_transactions;          // Number of transactions
    rand int unsigned           max_beats;                 // Max beats per burst (>=1)
    rand int unsigned           read_percent;              // Read percentage (0-100)
    rand bit                    addr_aligned;              // Align address to transfer size

    // Stress knobs
    rand bit                    enable_wrap;               // Allow WRAP burst
    rand bit                    enable_fixed;              // Allow FIXED burst
    rand bit                    enable_size_rand;          // Allow size randomization
    rand bit                    enable_partial_wstrb;

    rand int unsigned           partial_prob;              // 0-100 chance to use partial WSTRB on a WRITE
    rand int unsigned           wrap_prob;                 // 0-100 chance to pick WRAP (if enabled)
    rand int unsigned           fixed_prob;                // 0-100 chance to pick FIXED (if enabled)

    // Address windowing
    rand bit                    restrict_addr_window;
    rand logic [ADDR_WIDTH-1:0] window_base;
    rand int unsigned           window_bytes;              // 64/128/256/...

    // Locality (RAW/WAR hazards)
    rand bit                    enable_locality;
    rand int unsigned           locality_prob;             // 0-100 chance next transaction reuses recent address

    // Keep traffic inside memory map
    rand bit                    restrict_to_mem;           // if 1, constrain addresses to [0..mem_bytes-1]
    rand int unsigned           mem_bytes;                 // Total mapped bytes (ex: 8192 = 1024*64b)

    // WRAP foldback bias knobs
    rand bit                    enable_wrap_foldback_bias; // Bias WRAP start_addr to trigger foldback
    rand int unsigned           wrap_foldback_prob;        // 0-100 chance to bias to tail
    rand int unsigned           wrap_tail_beats;           // How many tail beats are considered tail

    // ------------------------------------------------------------
    // Directed mode knobs 
    // ------------------------------------------------------------
    localparam int BYTES_PER_BEAT = DATA_WIDTH / 8;

    bit                        directed_mode = 0;
    axi_rw_e                   dir_rw;
    logic [ADDR_WIDTH-1:0]     dir_addr;
    logic [DATA_WIDTH-1:0]     dir_wdata;
    int unsigned               dir_beats = 1;
    logic [ID_WIDTH-1:0]       dir_id;

    logic [1:0]                dir_burst = 2'b01; // INCR
    logic [2:0]                dir_size  = $clog2(BYTES_PER_BEAT);

    logic [(DATA_WIDTH/8)-1:0] dir_wstrb = { BYTES_PER_BEAT{1'b1} };

    // ------------------------------------------------------------
    // Constraints
    // ------------------------------------------------------------
    constraint c_defaults {
        num_transactions     inside {[1:100000]};
        max_beats            inside {[1:16]};
        read_percent         inside {[0:100]};

        enable_wrap          inside {0,1};
        enable_fixed         inside {0,1};
        enable_size_rand     inside {0,1};
        enable_partial_wstrb inside {0,1};

        partial_prob         inside {[0:100]};
        wrap_prob            inside {[0:100]};
        fixed_prob           inside {[0:100]};

        restrict_addr_window inside {0,1};
        window_bytes         inside {64,128,256,512,1024,2048,4096};

        enable_locality      inside {0,1};
        locality_prob        inside {[0:100]};

        restrict_to_mem      inside {0,1};
        mem_bytes            inside {[1:1_000_000]};
    }

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------
    function new(string name = "axi_mm_seq");
        super.new(name);

        // Baseline defaults
        num_transactions     = 1000;
        max_beats            = 8;
        read_percent         = 50;
        addr_aligned         = 1'b1;

        enable_wrap          = 1'b0;
        enable_fixed         = 1'b0;  
        enable_size_rand     = 1'b0;
        enable_partial_wstrb = 1'b0;

        partial_prob         = 20;
        wrap_prob            = 10;
        fixed_prob           = 20;

        restrict_addr_window = 1'b0;
        window_base          = '0;
        window_bytes         = 512;

        enable_locality      = 1'b1;
        locality_prob        = 30;

        restrict_to_mem      = 1'b1;
        mem_bytes            = 8192; // BRAM: DEPTH_WORDS=1024, DATA_WIDTH=64 -> 1024*8 = 8192

        // Lock config knobs to prevent overwrite
        restrict_addr_window.rand_mode(0);
        window_base.rand_mode(0);
        window_bytes.rand_mode(0);

        restrict_to_mem.rand_mode(0);
        mem_bytes.rand_mode(0);
    endfunction

    // ------------------------------------------------------------
    // Helper function: Random DATA_WIDTH word
    // ------------------------------------------------------------
    function automatic logic [DATA_WIDTH-1:0] rand_data_word();
        logic [DATA_WIDTH-1:0] w;
        int chunks;
        w = '0;
        chunks = (DATA_WIDTH + 31) / 32;
        for (int c = 0; c < chunks; c++) begin
            w[c*32 +: 32] = $urandom();
        end
        return w;
    endfunction

    // ------------------------------------------------------------
    // Helper function: Pick random size
    // ------------------------------------------------------------
    function automatic logic [2:0] pick_size();
        int unsigned max_log2;
        int unsigned s;
        max_log2 = $clog2(BYTES_PER_BEAT);

        if (!enable_size_rand) begin
            return max_log2[2:0];
        end

        s = $urandom_range(0, max_log2);
        return s[2:0];
    endfunction

    // ------------------------------------------------------------
    // Helper function: Compute bytes from size
    // ------------------------------------------------------------
    function automatic int unsigned size_to_bytes(input logic [2:0] size_field);
        int unsigned b;
        b = 1 << size_field;
        if (b == 0) b = 1;
        if (b > BYTES_PER_BEAT) b = BYTES_PER_BEAT;
        return b;
    endfunction

    function automatic logic [1:0] pick_burst();
        int unsigned r;
        int unsigned w_wrap, w_fixed, w_incr;
        int unsigned sum;

        // Weights only count when feature enabled
        w_wrap  = (enable_wrap ) ? wrap_prob  : 0;
        w_fixed = (enable_fixed) ? fixed_prob : 0;

        // Clamp
        if (w_wrap  > 100) w_wrap  = 100;
        if (w_fixed > 100) w_fixed = 100;

        // Remainder goes to INCR
        sum = w_wrap + w_fixed;
        if (sum >= 100) begin
            w_incr = 0;
        end else begin
            w_incr = 100 - sum;
        end

        r = $urandom_range(0,99);

        if (w_wrap != 0) begin
            if (r < w_wrap) return 2'b10; // WRAP
            r -= w_wrap;
        end

        if (w_fixed != 0) begin
            if (r < w_fixed) return 2'b00; // FIXED
            r -= w_fixed;
        end

        return 2'b01; // INCR
    endfunction

    // ------------------------------------------------------------
    // Helper function: Random WSTRB
    // ------------------------------------------------------------
    function automatic logic [BYTES_PER_BEAT-1:0] rand_wstrb_mask(input logic [2:0] size_field);
        logic [BYTES_PER_BEAT-1:0] m;
        int unsigned bytes;

        bytes = size_to_bytes(size_field);

        // Default
        m = {BYTES_PER_BEAT{1'b1}};

        if (!enable_partial_wstrb) return m;

        if ($urandom_range(0,99) >= partial_prob) return m;

        // Partial: Random subset over full beat lanes 
        for (int i = 0; i < BYTES_PER_BEAT; i++) begin
            m[i] = $urandom_range(0,1);
        end
        if (m == '0) m[0] = 1'b1;
        return m;
    endfunction

    // ------------------------------------------------------------
    // Helper function: Pick wrap beats
    // ------------------------------------------------------------
    function automatic int unsigned pick_wrap_beats(input int unsigned mb);
        int unsigned choices[$] = '{2,4,8,16};
        int unsigned legal[$];

        // Collect choices that <= max_beats
        foreach (choices[i]) begin
            if (choices[i] <= mb) legal.push_back(choices[i]);
        end

        // If max_beats < 2 -> Illegal WRAP -> Back to 1 beat
        if (legal.size() == 0) return 1;

        return legal[$urandom_range(0, legal.size()-1)];
    endfunction

    // ------------------------------------------------------------
    // Helper function: Random address generator
    // - Guarantees burst does not cross window/mem boundary for INCR/WRAP
    // - Locality is allowed but wrapped back into legal [start_min...start_max]
    // - Avoids $urandom_range() overflow by requiring window/mem restriction
    // ------------------------------------------------------------
    function automatic logic [ADDR_WIDTH-1:0] rand_addr(
        input logic [2:0]            size_field,
        input int unsigned           beats,
        input logic [1:0]            burst,
        input bit                    use_locality,
        input logic [ADDR_WIDTH-1:0] last_addr
    );

        longint signed base;
        longint signed region_bytes;

        longint signed bytes;
        longint signed span_bytes;

        longint signed start_min;
        longint signed start_max;
        longint signed range;

        longint signed cand;
        longint signed off;
        longint signed delta;

        logic [ADDR_WIDTH-1:0] ret_addr;

        // Region selection: window > mem
        if (restrict_addr_window) begin
            base         = longint'(window_base);
            region_bytes = longint'(window_bytes);
        end
        else if (restrict_to_mem) begin
            base         = 0;
            region_bytes = longint'(mem_bytes);
        end
        else begin
            // Avoid huge ranges that overflow
            `uvm_fatal("SEQ_ADDR", "rand_addr(): Must enable restrict_to_mem or restrict_addr_window")
            base         = 0;
            region_bytes = 1;
        end

        if (region_bytes <= 0) region_bytes = 1;

        // Bytes per beat for this transfer
        bytes = longint'(size_to_bytes(size_field));
        if (bytes <= 0) bytes = 1;

        if (beats == 0) beats = 1;

        // Span rules by burst
        if (burst == 2'b00) begin
            span_bytes = bytes;
        end
        else begin
            span_bytes = longint'(beats) * bytes;
            if (span_bytes <= 0) span_bytes = bytes;
        end

        // Legal start range: [base ... base + region_bytes - span_bytes]
        start_min = base;
        start_max = base + region_bytes - span_bytes;
        if (start_max < start_min) start_max = start_min;

        range = start_max - start_min + 1;
        if (range <= 0) range = 1;

        // Candidate (uniform within legal start range)
        cand = start_min + longint'($urandom_range(0, int'(range-1)));


        // Locality perturbation
        if (enable_locality && use_locality) begin
            delta = longint'($urandom_range(0, (BYTES_PER_BEAT * max_beats)));
            if ($urandom_range(0,1)) cand = longint'(last_addr) + delta;
            else                     cand = longint'(last_addr) - delta;

            off = (cand - start_min) % range;
            if (off < 0) off = off + range;
            cand = start_min + off;
        end

        // Alignment to transfer size
        if (addr_aligned) begin
            cand = cand & ~(bytes - 1);
        end

        // After alignment, keep within range
        if (cand < start_min) cand = start_min;

        if (cand > start_max) begin
            cand = start_max;
            if (addr_aligned) cand = cand & ~(bytes - 1); 
            if (cand < start_min) cand = start_min;
        end

        // WRAP handling (only if burst==WRAP)
        if (burst == 2'b10) begin
            longint signed wrap_bytes;
            longint signed wrap_base_min;
            longint signed wrap_base_max;
            longint signed first_base;
            longint signed last_base;
            longint signed nbase;

            longint signed offset_max;
            longint signed offset;
            longint signed off_steps;

            longint signed abs_max;

            wrap_bytes = span_bytes; // beats * bytes (must be power-of-2)

            // wrap_base + wrap_bytes <= base + region_bytes
            wrap_base_min = start_min;                       
            wrap_base_max = (base + region_bytes) - wrap_bytes; 

            if (wrap_base_max < wrap_base_min) begin
                cand = (addr_aligned) ? (start_min & ~(bytes - 1)) : start_min;
            end
            else begin
                first_base = (wrap_base_min + wrap_bytes - 1) & ~(wrap_bytes - 1); // Ceiling 
                last_base  = wrap_base_max & ~(wrap_bytes - 1);                    // Floor

                if (last_base < first_base) begin
                    cand = (addr_aligned) ? (start_min & ~(bytes - 1)) : start_min;
                end
                else begin
                    nbase = ((last_base - first_base) / wrap_bytes) + 1;
                    cand  = first_base + wrap_bytes * longint'($urandom_range(0, int'(nbase-1)));

                    offset_max = wrap_bytes - bytes;
                    if (offset_max < 0) offset_max = 0;

                    if (addr_aligned) begin
                    off_steps = (offset_max / bytes) + 1;

                    if (enable_wrap_foldback_bias &&
                        ($urandom_range(0,99) < wrap_foldback_prob)) begin

                        longint signed tail_start_step;
                        tail_start_step = longint'(off_steps) - longint'(wrap_tail_beats);
                        if (tail_start_step < 0) tail_start_step = 0;

                        offset = longint'(bytes) * longint'($urandom_range(int'(tail_start_step), int'(off_steps-1)));
                    end
                    else begin
                        offset = longint'(bytes) * longint'($urandom_range(0, int'(off_steps-1)));
                    end
                    end
                    else begin
                    offset = longint'($urandom_range(0, int'(offset_max)));
                    end

                    cand = cand + offset;

                    abs_max = base + region_bytes - bytes;
                    if (cand < start_min) cand = start_min;
                    if (cand > abs_max) begin
                    cand = abs_max;
                    if (addr_aligned) cand = cand & ~(bytes - 1);
                    end
                end
            end
        end

        // Return sliced address
        ret_addr = cand[ADDR_WIDTH-1:0];
        return ret_addr;
    endfunction

    // ------------------------------------------------------------
    // Main body
    // ------------------------------------------------------------
    virtual task body();
        axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;

        int unsigned beats;
        logic [ADDR_WIDTH-1:0] last_addr;
        bit use_locality;

        // ------------------------------------------------------------
        // Directed Mode
        // ------------------------------------------------------------
        if (directed_mode) begin
            tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("tr");

            tr.rw    = dir_rw;
            tr.addr  = dir_addr;
            tr.len   = dir_beats - 1;
            tr.id    = dir_id;

            tr.size  = dir_size;
            tr.burst = dir_burst;

            if (^dir_id === 1'bX) begin
                `uvm_fatal("SEQ_ID", "Directed mode: dir_id not set or unknown")
            end
            if (int'(dir_id) < 0 || int'(dir_id) >= (1 << ID_WIDTH)) begin
                `uvm_fatal("SEQ_ID", $sformatf("Directed mode: dir_id=%0d out of range for ID_WIDTH=%0d (valid 0-%0d)", int'(dir_id), ID_WIDTH, (1<<ID_WIDTH)-1))
            end

            tr.set_beats_len(tr.len);

            if (dir_rw == AXI_WRITE) begin
                foreach (tr.wdata_beats[i]) begin
                    tr.wdata_beats[i]  = dir_wdata + i;
                    tr.wstrb_beats[i] = dir_wstrb;
                end
            end

            start_item(tr);
            finish_item(tr);

            `uvm_info(get_type_name(), $sformatf("DIRECTED %s addr=0x%0h beats=%0d id=0x%0h burst=%0b size=%0d", (dir_rw == AXI_WRITE) ? "WRITE" : "READ", dir_addr, dir_beats, dir_id, dir_burst, dir_size), UVM_MEDIUM)
            return;
        end

        // ------------------------------------------------------------
        // Random Mode
        // ------------------------------------------------------------
        // Safety clamps
        if (max_beats == 0)     max_beats = 1;
        if (max_beats > 256)    max_beats = 256;
        if (read_percent > 100) read_percent = 100;
        if (partial_prob > 100) partial_prob = 100;
        if (wrap_prob > 100)    wrap_prob = 100;
        if (fixed_prob > 100)   fixed_prob = 100;

        // If restrict_to_mem but mem_bytes unset -> default
        if (restrict_to_mem && (mem_bytes == 0)) mem_bytes = 8192;

        last_addr = '0;

        `uvm_info(get_type_name(), $sformatf("Starting random seq: num=%0d max_beats=%0d read%%=%0d aligned=%0d size_rand=%0d partial=%0d fixed=%0d wrap=%0d | win_en=%0d win_base=0x%0h win_bytes=%0d | mem_restrict=%0d mem_bytes=%0d",
                        num_transactions, max_beats, read_percent, addr_aligned,
                        enable_size_rand, enable_partial_wstrb, enable_fixed, enable_wrap,
                        restrict_addr_window, window_base, window_bytes,
                        restrict_to_mem, mem_bytes), UVM_LOW)

        repeat (num_transactions) begin
            tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("tr");

            // Read or Write
            tr.rw = ($urandom_range(0,99) < read_percent) ? AXI_READ : AXI_WRITE;

            // Size & burst
            tr.size  = pick_size();
            tr.burst = pick_burst();

            // Beats
            if (tr.burst == 2'b10) begin
                if (max_beats < 2) tr.burst = 2'b01; // Degrade to INCR
                beats = pick_wrap_beats(max_beats);
            end else begin
                beats = $urandom_range(1, max_beats);
            end
            tr.len = beats - 1;

            // Address (consider locality + mem restriction + alignment + wrap boundary)
            use_locality = (enable_locality && ($urandom_range(0,99) < locality_prob));
            tr.addr = rand_addr(tr.size, beats, tr.burst, use_locality, last_addr);
            last_addr = tr.addr;

            // ID
            tr.id = $urandom(); 
            tr.id &= {ID_WIDTH{1'b1}}; // mask

            // Allocate arrays
            tr.set_beats_len(tr.len);

            // Payload
            if (tr.rw == AXI_WRITE) begin
                foreach (tr.wdata_beats[i]) begin
                    tr.wdata_beats[i]  = rand_data_word();
                    tr.wstrb_beats[i] = rand_wstrb_mask(tr.size);
                end
            end

            start_item(tr);
            finish_item(tr);

            `uvm_info(get_type_name(), $sformatf("Issued %s addr=0x%0h beats=%0d id=0x%0h burst=%02b size=%0d", (tr.rw == AXI_WRITE) ? "WRITE" : "READ", tr.addr, beats, tr.id, tr.burst, tr.size), UVM_HIGH)
        end
    endtask

endclass

`endif