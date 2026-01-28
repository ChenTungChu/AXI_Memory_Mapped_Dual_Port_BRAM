// File: tb/uvm/test/axi_mm_directed_test.sv
`ifndef AXI_MM_DIRECTED_TEST_SV
`define AXI_MM_DIRECTED_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

// ------------------------------------------------------------
// Directed AXI-MM test (factory-safe, non-parameterized)
// ------------------------------------------------------------
class axi_mm_directed_test extends uvm_test;

    `uvm_component_utils(axi_mm_directed_test)

    // ------------------------------------------------------------
    // Local parameters (fixed for factory)
// ------------------------------------------------------------
    localparam int ADDR_WIDTH = 32;
    localparam int DATA_WIDTH = 64;
    localparam int ID_WIDTH   = 4;

    // ------------------------------------------------------------
    // Environment handle
    // ------------------------------------------------------------
    axi_mm_env #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) env_h;

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------
    function new(string name = "axi_mm_directed_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // ------------------------------------------------------------
    // Build phase
    // ------------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env_h = axi_mm_env#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("env_h", this);
    endfunction

    // ------------------------------------------------------------
    // Helper function for ID guard
    // ------------------------------------------------------------
    function automatic logic [ID_WIDTH-1:0] safe_id(int unsigned raw, string who="");
        if (raw >= (1<<ID_WIDTH)) begin
            `uvm_fatal("ID_RANGE", $sformatf("%s raw_id=%0d exceeds ID_WIDTH=%0d (max=%0d)", who, raw, ID_WIDTH, (1<<ID_WIDTH)-1))
        end
        return raw[ID_WIDTH-1:0];
    endfunction

    // ------------------------------------------------------------
    // Run phase: deterministic directed stimulus
    // ------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);

        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) wr_seq;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) rd_seq;

        // Addresses
        logic [ADDR_WIDTH-1:0] case3_1_addr;
        logic [ADDR_WIDTH-1:0] case3_2_addr;
        logic [ADDR_WIDTH-1:0] case3_3_addr;
        logic [ADDR_WIDTH-1:0] case4_1_addr;
        logic [ADDR_WIDTH-1:0] case4_2_addr;
        logic [ADDR_WIDTH-1:0] case4_3_addr;
        logic [ADDR_WIDTH-1:0] case4_4_addr;
        logic [ADDR_WIDTH-1:0] case5_1_p0_addr;
        logic [ADDR_WIDTH-1:0] case5_1_p1_addr;
        logic [ADDR_WIDTH-1:0] case5_2_addr;
        logic [ADDR_WIDTH-1:0] case5_3_addr;        
        

        // Case 3.2
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_full;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_wr_part;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_rd;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_rd;

        // Case 3.3
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_lo_case_3_3;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_wr_hi_case_3_3;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_rd_case_3_3;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_rd_case_3_3;

        // Case 4.1
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_case4_1;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_rd_case4_1;

        // Case 4.2
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_case4_2;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_rd_case4_2;

        // Case 4.3
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_case4_3;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_rd_case4_3;

        // Case 4.4
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_case4_4;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_rd_case4_4;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_rd_case4_4;

        // Case 5.1
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_case5_1;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_wr_case5_1;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_rd_case5_1;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_rd_case5_1;

        // Case 5.2
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_case5_2_full;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_wr_case5_2_part;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_rd_case5_2;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_rd_case5_2;

        // Case 5.3
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_case5_3;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_wr_case5_3;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_rd_case5_3;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_rd_case5_3;


        phase.raise_objection(this);
        // --------------------------------------------------------
        // Case 0: Single-beat write/read
        // --------------------------------------------------------
        // `uvm_info("DIRECT_TEST", "Starting AXI-MM directed RAM test (case 0: single-beat RAW)", UVM_MEDIUM)

        // Write
        // wr_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("wr_seq_case0");

        // wr_seq.directed_mode = 1;
        // wr_seq.dir_rw        = AXI_WRITE;
        // wr_seq.dir_addr      = 32'h0000_0100;
        // wr_seq.dir_wdata     = 64'hDEAD_BEEF_1234_5678;
        // wr_seq.dir_beats     = 1;
        // wr_seq.dir_id        = 0;
        // wr_seq.dir_wstrb     = 8'hFF;

        // wr_seq.start(env_h.p0_agent.seqr);

        // // Read
        // rd_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("rd_seq_case0");

        // rd_seq.directed_mode = 1;
        // rd_seq.dir_rw        = AXI_READ;
        // rd_seq.dir_addr      = 32'h0000_0100;
        // rd_seq.dir_beats     = 1;
        // rd_seq.dir_id        = 1;

        // rd_seq.start(env_h.p0_agent.seqr);

        // `uvm_info("DIRECT_TEST", "Directed RAM test case 0 completed", UVM_MEDIUM)

        // ========================================================
        // Case 1: Multi-beat INCR burst write/read
        // ========================================================
    //     `uvm_info("DIRECT_TEST", "Case 1: INCR burst write/read", UVM_MEDIUM)

    //     // Write burst (4 beats)
    //     wr_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("wr_seq_case1");

    //     wr_seq.directed_mode = 1;
    //     wr_seq.dir_rw        = AXI_WRITE;
    //     wr_seq.dir_addr      = 32'h0000_0200;
    //     wr_seq.dir_beats     = 4;
    //     wr_seq.dir_id        = 2;
    //     wr_seq.dir_wdata     = 64'hDEAD_BEEF_0000_0000;
    //     wr_seq.dir_burst     = 2'b01;  // INCR (explicit)
    //     wr_seq.dir_size      = 3;      // 8 bytes/beat (explicit)
    //     wr_seq.dir_wstrb     = 8'hFF;

    //     wr_seq.start(env_h.p0_agent.seqr);

    //     // Read burst (2 beats)
    //     rd_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("rd_seq_case1");

    //     rd_seq.directed_mode = 1;
    //     rd_seq.dir_rw        = AXI_READ;
    //     rd_seq.dir_addr      = 32'h0000_0200;
    //     rd_seq.dir_beats     = 4;
    //     rd_seq.dir_id        = 3;
    //     rd_seq.dir_burst     = 2'b01; // INCR
    //     rd_seq.dir_size      = 3;

    //     rd_seq.start(env_h.p0_agent.seqr);    

    //    `uvm_info("DIRECT_TEST", "Directed RAM test case 1 completed", UVM_MEDIUM)


        // ========================================================
        // Case 2: WRAP burst write/read
        // - 4 beats (len=3), size=8B (AWSIZE=3), wrap boundary=32B
        // - Start at 0x318 so it will wrap inside 0x300..0x31F
        // ========================================================
        // `uvm_info("DIRECT_TEST", "Case 2: WRAP burst write/read", UVM_LOW)

        // // WRITE
        // wr_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("wr_seq_case2");
        // wr_seq.directed_mode = 1;
        // wr_seq.dir_rw        = AXI_WRITE;
        // wr_seq.dir_addr      = 32'h0000_0318;     // wrap-start
        // wr_seq.dir_beats     = 4;                 // len=3
        // wr_seq.dir_id        = 4;
        // wr_seq.dir_wdata     = 64'hCAFE_BABE_0000_0000;
        // wr_seq.dir_burst     = 2'b10;             // WRAP
        // wr_seq.dir_size      = 3;                 // 8 bytes/beat for 64-bit data
        // wr_seq.dir_wstrb     = 8'hFF;

        // wr_seq.start(env_h.p0_agent.seqr);

        // // READ (same addr/len/burst/size)
        // rd_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("rd_seq_case2");
        // rd_seq.directed_mode = 1;
        // rd_seq.dir_rw        = AXI_READ;
        // rd_seq.dir_addr      = 32'h0000_0318;
        // rd_seq.dir_beats     = 4;
        // rd_seq.dir_id        = 5;
        // rd_seq.dir_burst     = 2'b10;             // WRAP
        // rd_seq.dir_size      = 3;

        // rd_seq.start(env_h.p0_agent.seqr);

        // `uvm_info("DIRECT_TEST", "Directed RAM test case 2 completed", UVM_LOW)

        // ========================================================
        // Case 3.1: Partial strobe write + readback (byte-enable test)
        // - 1. full write baseline
        // - 2. partial write same addr with WSTRB mask
        // - 3. read back and expect merged data
        // ========================================================
        // `uvm_info("DIRECT_TEST", "Case 3.1: Partial strobe write/read", UVM_MEDIUM)

        // // Choose a clean aligned address
        // case3_1_addr = 32'h0000_0400;

        // // 1. baseline full write (1 beat)
        // wr_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("wr_seq_case3_1_full");

        // wr_seq.directed_mode = 1;
        // wr_seq.dir_rw        = AXI_WRITE;
        // wr_seq.dir_addr      = case3_1_addr;
        // wr_seq.dir_beats     = 1;
        // wr_seq.dir_id        = 6;
        // wr_seq.dir_wdata     = 64'h1122_3344_5566_7788;

        // wr_seq.dir_burst     = 2'b01; // INCR
        // wr_seq.dir_size      = 3;     // 8B/beat
        // wr_seq.dir_wstrb     = 8'hFF; // full bytes

        // wr_seq.start(env_h.p0_agent.seqr);

        // // 2. partial write same addr (only low 2 bytes enabled)
        // wr_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("wr_seq_case3_1_part");

        // wr_seq.directed_mode = 1;
        // wr_seq.dir_rw        = AXI_WRITE;
        // wr_seq.dir_addr      = case3_1_addr;
        // wr_seq.dir_beats     = 1;
        // wr_seq.dir_id        = 7;
        // wr_seq.dir_wdata     = 64'h0000_0000_0000_AAAA;

        // wr_seq.dir_burst     = 2'b01;
        // wr_seq.dir_size      = 3;
        // wr_seq.dir_wstrb     = 8'b0000_0011; // only byte[1:0]

        // wr_seq.start(env_h.p0_agent.seqr);

        // // 3. read back (1 beat)
        // rd_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("rd_seq_case3_1");

        // rd_seq.directed_mode = 1;
        // rd_seq.dir_rw        = AXI_READ;
        // rd_seq.dir_addr      = case3_1_addr;
        // rd_seq.dir_beats     = 1;
        // rd_seq.dir_id        = 8;

        // rd_seq.dir_burst     = 2'b01;
        // rd_seq.dir_size      = 3;

        // rd_seq.start(env_h.p0_agent.seqr);

        // `uvm_info("DIRECT_TEST", "Directed RAM test case 3.1 completed (partial strobe)", UVM_MEDIUM)

        // ========================================================
        // Case 3.2: Cross-port coherence + same-address partial collision
        // - P0 full write baseline
        // - P1 partial write same address (different byte lanes)
        // - Readback from BOTH ports to ensure coherence
        // ========================================================
        // `uvm_info("DIRECT_TEST", "Case 3.2: Cross-port coherence (P0 full -> P1 partial -> read both)", UVM_MEDIUM)

        // begin : case3_2
        //     // ---- choose an aligned address ----
        //     case3_2_addr = 32'h0000_0410; // avoid clobbering Case 3A @0x400, keep 8B aligned

        //     // ----------------------------------------------------
        //     // 1. Port0 baseline full write (1 beat)
        //     // ----------------------------------------------------
        //     p0_wr_full = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case3_2_full");
        //     p0_wr_full.directed_mode = 1;
        //     p0_wr_full.dir_rw        = AXI_WRITE;
        //     p0_wr_full.dir_addr      = case3_2_addr;
        //     p0_wr_full.dir_beats     = 1;
        //     p0_wr_full.dir_id        = 9;

        //     p0_wr_full.dir_burst     = 2'b01; // INCR
        //     p0_wr_full.dir_size      = 3;     // 8B/beat (DATA_WIDTH=64)
        //     p0_wr_full.dir_wdata     = 64'h1122_3344_5566_7788;
        //     p0_wr_full.dir_wstrb     = 8'hFF; // full strobe

        //     p0_wr_full.start(env_h.p0_agent.seqr);

        //     // ----------------------------------------------------
        //     // 2. Port1 partial write SAME address (1 beat)
        //     // - overwrite high 2 bytes: byte[7:6]
        //     // ----------------------------------------------------
        //     p1_wr_part = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_wr_case3_2_part");
        //     p1_wr_part.directed_mode = 1;
        //     p1_wr_part.dir_rw        = AXI_WRITE;
        //     p1_wr_part.dir_addr      = case3_2_addr;
        //     p1_wr_part.dir_beats     = 1;
        //     p1_wr_part.dir_id        = 10;

        //     p1_wr_part.dir_burst     = 2'b01;
        //     p1_wr_part.dir_size      = 3;

        //     // Put data on the lanes you enable. For byte[7:6], place at [63:48]
        //     p1_wr_part.dir_wdata     = 64'hAAAA_0000_0000_0000;
        //     p1_wr_part.dir_wstrb     = 8'b1100_0000; // enable byte lanes 7 and 6 only

        //     p1_wr_part.start(env_h.p1_agent.seqr);

        //     // ----------------------------------------------------
        //     // 3. Readback from Port0
        //     // Expect: 0xAAAA_3344_5566_7788
        //     // ----------------------------------------------------
        //     p0_rd = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case3_2");
        //     p0_rd.directed_mode = 1;
        //     p0_rd.dir_rw        = AXI_READ;
        //     p0_rd.dir_addr      = case3_2_addr;
        //     p0_rd.dir_beats     = 1;
        //     p0_rd.dir_id        = 11;

        //     p0_rd.dir_burst     = 2'b01;
        //     p0_rd.dir_size      = 3;

        //     // For read sequences, still set full wstrb to keep everything deterministic/log-friendly
        //     p0_rd.dir_wstrb     = 8'hFF;

        //     p0_rd.start(env_h.p0_agent.seqr);

        //     // ----------------------------------------------------
        //     // 4. Readback from Port1 (same expectation)
        //     // ----------------------------------------------------
        //     p1_rd = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_rd_case3_2");
        //     p1_rd.directed_mode = 1;
        //     p1_rd.dir_rw        = AXI_READ;
        //     p1_rd.dir_addr      = case3_2_addr;
        //     p1_rd.dir_beats     = 1;
        //     p1_rd.dir_id        = 12;

        //     p1_rd.dir_burst     = 2'b01;
        //     p1_rd.dir_size      = 3;
        //     p1_rd.dir_wstrb     = 8'hFF;

        //     p1_rd.start(env_h.p1_agent.seqr);

        //     `uvm_info("DIRECT_TEST", $sformatf("Directed RAM test Case 3.2 completed @addr=0x%0h (P0 full -> P1 partial -> read both)", case3_2_addr), UVM_MEDIUM)
        // end

        // ========================================================
        // Case 3.3: Same-address cross-port collision + byte-merge
        // - P0 writes low lanes, P1 writes high lanes to SAME addr
        // - Start them close together (fork) to stress arbitration/CDC
        // - Read back from both ports, expect merged data
        // ========================================================
        // `uvm_info("DIRECT_TEST", "Case 3.3: Same-address cross-port collision + byte-merge", UVM_MEDIUM)

        // // Choose aligned address (8B aligned for size=3)
        // case3_3_addr = 32'h0000_0420;

        // // ------------------------------
        // // Prepare P0 write (low 4 bytes)
        // // ------------------------------
        // p0_wr_lo_case_3_3 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_lo_case_3_3");
        // p0_wr_lo_case_3_3.directed_mode = 1;
        // p0_wr_lo_case_3_3.dir_rw        = AXI_WRITE;
        // p0_wr_lo_case_3_3.dir_addr      = case3_3_addr;
        // p0_wr_lo_case_3_3.dir_beats     = 1;
        // p0_wr_lo_case_3_3.dir_id        = 12;
        // p0_wr_lo_case_3_3.dir_burst     = 2'b01;
        // p0_wr_lo_case_3_3.dir_size      = 3;           // 8B/beat
        // p0_wr_lo_case_3_3.dir_wdata     = 64'h0000_0000_1122_3344;
        // p0_wr_lo_case_3_3.dir_wstrb     = 8'h0F;       // byte[3:0]

        // // ------------------------------
        // // Prepare P1 write (high 4 bytes)
        // // ------------------------------
        // p1_wr_hi_case_3_3 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_wr_hi_case_3_3");
        // p1_wr_hi_case_3_3.directed_mode = 1;
        // p1_wr_hi_case_3_3.dir_rw        = AXI_WRITE;
        // p1_wr_hi_case_3_3.dir_addr      = case3_3_addr;
        // p1_wr_hi_case_3_3.dir_beats     = 1;
        // p1_wr_hi_case_3_3.dir_id        = 13;
        // p1_wr_hi_case_3_3.dir_burst     = 2'b01;
        // p1_wr_hi_case_3_3.dir_size      = 3;
        // p1_wr_hi_case_3_3.dir_wdata     = 64'hAABB_CCDD_0000_0000;
        // p1_wr_hi_case_3_3.dir_wstrb     = 8'hF0;       // byte[7:4]

        // // ------------------------------
        // // Fire both writes (near-simultaneous)
        // // ------------------------------
        // fork
        //     begin
        //         p0_wr_lo_case_3_3.start(env_h.p0_agent.seqr);
        //     end
        //     begin
        //         // tiny skew to avoid “Same delta-cycle” causing testbench abnormal arrangment
        //         #1ns;
        //         p1_wr_hi_case_3_3.start(env_h.p1_agent.seqr);
        //     end
        // join

        // // ------------------------------
        // // Read back from both ports
        // // ------------------------------
        // p0_rd_case_3_3 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case_3_3");
        // p0_rd_case_3_3.directed_mode = 1;
        // p0_rd_case_3_3.dir_rw        = AXI_READ;
        // p0_rd_case_3_3.dir_addr      = case3_3_addr;
        // p0_rd_case_3_3.dir_beats     = 1;
        // p0_rd_case_3_3.dir_id        = 14;
        // p0_rd_case_3_3.dir_burst     = 2'b01;
        // p0_rd_case_3_3.dir_size      = 3;

        // p1_rd_case_3_3 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_rd_case_3_3");
        // p1_rd_case_3_3.directed_mode = 1;
        // p1_rd_case_3_3.dir_rw        = AXI_READ;
        // p1_rd_case_3_3.dir_addr      = case3_3_addr;
        // p1_rd_case_3_3.dir_beats     = 1;
        // p1_rd_case_3_3.dir_id        = 15;
        // p1_rd_case_3_3.dir_burst     = 2'b01;
        // p1_rd_case_3_3.dir_size      = 3;

        // p0_rd_case_3_3.start(env_h.p0_agent.seqr);
        // p1_rd_case_3_3.start(env_h.p1_agent.seqr);

        // // Expected merged data: high 4 bytes from P1 + low 4 bytes from P0
        // // => 0xAABBCCDD11223344
        // `uvm_info("DIRECT_TEST",
        //     $sformatf("Case 3.3 expected merged @0x%0h = 0x%016h", case3_3_addr, 64'hAABB_CCDD_1122_3344),
        //     UVM_MEDIUM)

        // `uvm_info("DIRECT_TEST", $sformatf("Directed RAM test Case 3.3 completed @addr=0x%0h", case3_3_addr), UVM_MEDIUM)


        // ========================================================
        // Case 4: Burst integrity stress (INCR / WRAP / FIXED) + cross-port coherence
        // ========================================================
        // `uvm_info("DIRECT_TEST", "Case 4: Burst integrity (INCR/WRAP/FIXED) + cross-port coherence", UVM_MEDIUM)

        // begin : CASE4
        //     // ------------------------------------------------------------
        //     // Address plan (all aligned to 8B)
        //     // ------------------------------------------------------------
        //     case4_1_addr = 32'h0000_0500; // INCR burst
        //     // WRAP: 4 beats * 8B = 32B wrap region => base must be multiple of 32
        //     // Choose base = 0x0540, start at base + 24 => beat0 at last slot, beat1 wraps to base
        //     case4_2_addr = 32'h0000_0558;
        //     case4_3_addr = 32'h0000_0580; // FIXED burst
        //     case4_4_addr = 32'h0000_05C0; // cross-port burst

        //     // ============================================================
        //     // Case 4.1: P0 INCR burst write 4 beats + readback 4 beats
        //     // ============================================================
        //     `uvm_info("DIRECT_TEST", $sformatf("Case 4.1: P0 INCR burst 4 beats @0x%0h", case4_1_addr), UVM_MEDIUM)

        //     p0_wr_case4_1 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case4_1");
        //     p0_wr_case4_1.directed_mode = 1;
        //     p0_wr_case4_1.dir_rw        = AXI_WRITE;
        //     p0_wr_case4_1.dir_addr      = case4_1_addr;
        //     p0_wr_case4_1.dir_beats     = 4;
        //     p0_wr_case4_1.dir_id        = safe_id(0, "case4_1 p0_wr");;
        //     p0_wr_case4_1.dir_burst     = 2'b01; // INCR
        //     p0_wr_case4_1.dir_size      = 3;     // 8B/beat
        //     p0_wr_case4_1.dir_wdata     = 64'h1000_0000_0000_0000;
        //     p0_wr_case4_1.dir_wstrb     = 8'hFF;

        //     p0_rd_case4_1 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case4_1");
        //     p0_rd_case4_1.directed_mode = 1;
        //     p0_rd_case4_1.dir_rw        = AXI_READ;
        //     p0_rd_case4_1.dir_addr      = case4_1_addr;
        //     p0_rd_case4_1.dir_beats     = 4;
        //     p0_rd_case4_1.dir_id        = safe_id(1, "case4_1 p0_rd");;
        //     p0_rd_case4_1.dir_burst     = 2'b01;
        //     p0_rd_case4_1.dir_size      = 3;

        //     p0_wr_case4_1.start(env_h.p0_agent.seqr);
        //     p0_rd_case4_1.start(env_h.p0_agent.seqr);

        //     // ============================================================
        //     // Case 4.2: P0 WRAP burst write 4 beats + readback 4 beats
        //     // ============================================================
        //     `uvm_info("DIRECT_TEST", $sformatf("Case 4.2: P0 WRAP burst 4 beats start @0x%0h", case4_2_addr), UVM_MEDIUM)

        //     p0_wr_case4_2 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case4_2");
        //     p0_wr_case4_2.directed_mode = 1;
        //     p0_wr_case4_2.dir_rw        = AXI_WRITE;
        //     p0_wr_case4_2.dir_addr      = case4_2_addr;
        //     p0_wr_case4_2.dir_beats     = 4;
        //     p0_wr_case4_2.dir_id        = safe_id(2, "case4_2 p0_wr");;
        //     p0_wr_case4_2.dir_burst     = 2'b10; // WRAP
        //     p0_wr_case4_2.dir_size      = 3;
        //     p0_wr_case4_2.dir_wdata     = 64'h2000_0000_0000_0000;
        //     p0_wr_case4_2.dir_wstrb     = 8'hFF;

        //     p0_rd_case4_2 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case4_2");
        //     p0_rd_case4_2.directed_mode = 1;
        //     p0_rd_case4_2.dir_rw        = AXI_READ;
        //     p0_rd_case4_2.dir_addr      = case4_2_addr;
        //     p0_rd_case4_2.dir_beats     = 4;
        //     p0_rd_case4_2.dir_id        = safe_id(3, "case4_2 p0_rd");;
        //     p0_rd_case4_2.dir_burst     = 2'b10;
        //     p0_rd_case4_2.dir_size      = 3;

        //     p0_wr_case4_2.start(env_h.p0_agent.seqr);
        //     p0_rd_case4_2.start(env_h.p0_agent.seqr);

        //     // ============================================================
        //     // Case 4.3: P0 FIXED burst write 4 beats (same addr) + readback 1 beat
        //     // Expect last beat wins (dir_wdata + 3)
        //     // ============================================================
        //     `uvm_info("DIRECT_TEST", $sformatf("Case 4.3: P0 FIXED burst overwrite @0x%0h", case4_3_addr), UVM_MEDIUM)

        //     p0_wr_case4_3 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case4_3");
        //     p0_wr_case4_3.directed_mode = 1;
        //     p0_wr_case4_3.dir_rw        = AXI_WRITE;
        //     p0_wr_case4_3.dir_addr      = case4_3_addr;
        //     p0_wr_case4_3.dir_beats     = 4;
        //     p0_wr_case4_3.dir_id        = safe_id(4, "case4_3 p0_wr");;
        //     p0_wr_case4_3.dir_burst     = 2'b00; // FIXED
        //     p0_wr_case4_3.dir_size      = 3;
        //     p0_wr_case4_3.dir_wdata     = 64'h3000_0000_0000_0000;
        //     p0_wr_case4_3.dir_wstrb     = 8'hFF;

        //     p0_rd_case4_3 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case4_3");
        //     p0_rd_case4_3.directed_mode = 1;
        //     p0_rd_case4_3.dir_rw        = AXI_READ;
        //     p0_rd_case4_3.dir_addr      = case4_3_addr;
        //     p0_rd_case4_3.dir_beats     = 1;
        //     p0_rd_case4_3.dir_id        = safe_id(5, "case4_3 p0_rd");;
        //     p0_rd_case4_3.dir_burst     = 2'b01; // read just 1 beat INCR OK
        //     p0_rd_case4_3.dir_size      = 3;

        //     p0_wr_case4_3.start(env_h.p0_agent.seqr);
        //     p0_rd_case4_3.start(env_h.p0_agent.seqr);

        //     // ============================================================
        //     // Case 4.4: Cross-port coherence with INCR burst
        //     // P0 write 4 beats -> P0 read 4 beats and P1 read 4 beats (can be parallel)
        //     // ============================================================
        //     `uvm_info("DIRECT_TEST", $sformatf("Case 4.4: Cross-port INCR burst coherence @0x%0h", case4_4_addr), UVM_MEDIUM)

        //     p0_wr_case4_4 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case4_4");
        //     p0_wr_case4_4.directed_mode = 1;
        //     p0_wr_case4_4.dir_rw        = AXI_WRITE;
        //     p0_wr_case4_4.dir_addr      = case4_4_addr;
        //     p0_wr_case4_4.dir_beats     = 4;
        //     p0_wr_case4_4.dir_id        = safe_id(6, "case4_4 p0_wr");;
        //     p0_wr_case4_4.dir_burst     = 2'b01;
        //     p0_wr_case4_4.dir_size      = 3;
        //     p0_wr_case4_4.dir_wdata     = 64'h4000_0000_0000_0000;
        //     p0_wr_case4_4.dir_wstrb     = 8'hFF;

        //     p0_rd_case4_4 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case4_4");
        //     p0_rd_case4_4.directed_mode = 1;
        //     p0_rd_case4_4.dir_rw        = AXI_READ;
        //     p0_rd_case4_4.dir_addr      = case4_4_addr;
        //     p0_rd_case4_4.dir_beats     = 4;
        //     p0_rd_case4_4.dir_id        = safe_id(7, "case4_4 p0_rd");;
        //     p0_rd_case4_4.dir_burst     = 2'b01;
        //     p0_rd_case4_4.dir_size      = 3;

        //     p1_rd_case4_4 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_rd_case4_4");
        //     p1_rd_case4_4.directed_mode = 1;
        //     p1_rd_case4_4.dir_rw        = AXI_READ;
        //     p1_rd_case4_4.dir_addr      = case4_4_addr;
        //     p1_rd_case4_4.dir_beats     = 4;
        //     p1_rd_case4_4.dir_id        = safe_id(8, "case4_4 p1_rd");; // Prevent overlapping with p0
        //     p1_rd_case4_4.dir_burst     = 2'b01;
        //     p1_rd_case4_4.dir_size      = 3;

        //     p0_wr_case4_4.start(env_h.p0_agent.seqr);

        //     fork
        //         p0_rd_case4_4.start(env_h.p0_agent.seqr);
        //         p1_rd_case4_4.start(env_h.p1_agent.seqr);
        //     join

        //     `uvm_info("DIRECT_TEST", "Directed RAM test Case 4 completed (INCR/WRAP/FIXED + cross-port burst)", UVM_MEDIUM)
        // end

        // ========================================================
        // Case 5: Cross-port concurrency stress + multi-beat byte-merge
        // ========================================================
        `uvm_info("DIRECT_TEST", "Case 5: Cross-port concurrency stress + multi-beat byte-merge", UVM_MEDIUM)

        begin : CASE5
            // ------------------------------------------------------------
            // Address plan (8B aligned, and non-overlap with Case4 0x500~0x5FF)
            // ------------------------------------------------------------
            case5_1_p0_addr = 32'h0000_0620; // 8 beats * 8B = 64B -> [0x600..0x63F]
            case5_1_p1_addr = 32'h0000_0620; // 64B -> [0x680..0x6BF]
            case5_2_addr    = 32'h0000_0700; // 4 beats * 8B = 32B -> [0x700..0x71F]
            case5_3_addr    = 32'h0000_0780; // [0x780..0x7BF] 

            // ============================================================
            // Case 5.1: SAME-address parallel INCR bursts (8 beats) with
            //           complementary WSTRB merge
            //   P0 writes upper 4 bytes (WSTRB=0xF0)
            //   P1 writes lower 4 bytes (WSTRB=0x0F)
            //   Expected final per beat:
            //     [63:32] from P0 pattern, [31:0] from P1 pattern
            // ============================================================
            // `uvm_info("DIRECT_TEST",
            //     $sformatf("Case 5.1: P0/P1 parallel SAME-ADDR INCR burst 8 beats w/ complementary WSTRB @0x%0h",
            //             case5_1_p0_addr),
            //     UVM_MEDIUM)

            // // ---------------- P0 write: upper 4 bytes only ----------------
            // p0_wr_case5_1 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case5_1");
            // p0_wr_case5_1.directed_mode = 1;
            // p0_wr_case5_1.dir_rw        = AXI_WRITE;
            // p0_wr_case5_1.dir_addr      = case5_1_p0_addr;
            // p0_wr_case5_1.dir_beats     = 8;
            // p0_wr_case5_1.dir_id        = safe_id(8, "case5_1_p0_wr");
            // p0_wr_case5_1.dir_burst     = 2'b01; // INCR
            // p0_wr_case5_1.dir_size      = 3;     // 8B/beat

            // // Put deterministic pattern in upper 32b, lower 32b zero.
            // // NOTE: axi_mm_seq will do (dir_wdata + i), so per beat increments by +1.
            // // This keeps lower 32b at 0 for i<2^32, and upper pattern increments nicely.
            // p0_wr_case5_1.dir_wdata     = 64'h5000_0000_0000_0000;
            // p0_wr_case5_1.dir_wstrb     = 8'hF0; // lanes[7:4] valid => upper 4 bytes

            // // ---------------- P1 write: lower 4 bytes only ----------------
            // p1_wr_case5_1 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_wr_case5_1");
            // p1_wr_case5_1.directed_mode = 1;
            // p1_wr_case5_1.dir_rw        = AXI_WRITE;
            // p1_wr_case5_1.dir_addr      = case5_1_p1_addr;
            // p1_wr_case5_1.dir_beats     = 8;
            // p1_wr_case5_1.dir_id        = safe_id(9, "case5_1_p1_wr");
            // p1_wr_case5_1.dir_burst     = 2'b01;
            // p1_wr_case5_1.dir_size      = 3;

            // // Put deterministic pattern in lower 32b, upper 32b zero.
            // // (dir_wdata + i) increments low 32b as desired.
            // p1_wr_case5_1.dir_wdata     = 64'h0000_0000_6000_0000;
            // p1_wr_case5_1.dir_wstrb     = 8'h0F; // lanes[3:0] valid => lower 4 bytes

            // // Fire both writes concurrently (tiny skew to avoid TB delta artifacts)
            // fork
            //     begin
            //         p0_wr_case5_1.start(env_h.p0_agent.seqr);
            //     end
            //     begin
            //         #1ns;
            //         p1_wr_case5_1.start(env_h.p1_agent.seqr);
            //     end
            // join

            // // optional drain time for CDC/staging to fully settle
            // #50ns;

            // // ---------------- Read back concurrently too ----------------
            // p0_rd_case5_1 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case5_1");
            // p0_rd_case5_1.directed_mode = 1;
            // p0_rd_case5_1.dir_rw        = AXI_READ;
            // p0_rd_case5_1.dir_addr      = case5_1_p0_addr;
            // p0_rd_case5_1.dir_beats     = 8;
            // p0_rd_case5_1.dir_id        = safe_id(10, "case5_1_p0_rd");
            // p0_rd_case5_1.dir_burst     = 2'b01;
            // p0_rd_case5_1.dir_size      = 3;

            // p1_rd_case5_1 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_rd_case5_1");
            // p1_rd_case5_1.directed_mode = 1;
            // p1_rd_case5_1.dir_rw        = AXI_READ;
            // p1_rd_case5_1.dir_addr      = case5_1_p1_addr;
            // p1_rd_case5_1.dir_beats     = 8;
            // p1_rd_case5_1.dir_id        = safe_id(11, "case5_1_p1_rd");
            // p1_rd_case5_1.dir_burst     = 2'b01;
            // p1_rd_case5_1.dir_size      = 3;

            // fork
            //     p0_rd_case5_1.start(env_h.p0_agent.seqr);
            //     p1_rd_case5_1.start(env_h.p1_agent.seqr);
            // join

            // ============================================================
            // Case 5.2: Same-address multi-beat byte-merge across ports
            // P0: full burst 4 beats
            // P1: partial burst 4 beats (WSTRB=0x0F) overwriting low lanes
            // then read back from both ports (4 beats)
            // ============================================================
            // `uvm_info("DIRECT_TEST",
            //     $sformatf("Case 5.2: Same-address multi-beat merge (P0 full -> P1 partial) @0x%0h", case5_2_addr),
            //     UVM_MEDIUM)

            // // P0 baseline full write burst
            // p0_wr_case5_2_full = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case5_2_full");
            // p0_wr_case5_2_full.directed_mode = 1;
            // p0_wr_case5_2_full.dir_rw        = AXI_WRITE;
            // p0_wr_case5_2_full.dir_addr      = case5_2_addr;
            // p0_wr_case5_2_full.dir_beats     = 4;
            // p0_wr_case5_2_full.dir_id        = safe_id(4, "case5_2_p0_wr_full");
            // p0_wr_case5_2_full.dir_burst     = 2'b01;
            // p0_wr_case5_2_full.dir_size      = 3;
            // p0_wr_case5_2_full.dir_wdata     = 64'h7777_6666_5555_0000; // per beat will be +i
            // p0_wr_case5_2_full.dir_wstrb     = 8'hFF;

            // p0_wr_case5_2_full.start(env_h.p0_agent.seqr);

            // // P1 partial overwrite on SAME address burst (low 4 bytes only)
            // p1_wr_case5_2_part = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_wr_case5_2_part");
            // p1_wr_case5_2_part.directed_mode = 1;
            // p1_wr_case5_2_part.dir_rw        = AXI_WRITE;
            // p1_wr_case5_2_part.dir_addr      = case5_2_addr;
            // p1_wr_case5_2_part.dir_beats     = 4;
            // p1_wr_case5_2_part.dir_id        = safe_id(5, "case5_2_p1_wr_part");
            // p1_wr_case5_2_part.dir_burst     = 2'b01;
            // p1_wr_case5_2_part.dir_size      = 3;
            // p1_wr_case5_2_part.dir_wdata     = 64'h0000_0000_ABCD_1000; // only low lanes matter w/0x0F
            // p1_wr_case5_2_part.dir_wstrb     = 8'h0F;

            // p1_wr_case5_2_part.start(env_h.p1_agent.seqr);

            // // Read back from both ports (4 beats)
            // p0_rd_case5_2 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case5_2");
            // p0_rd_case5_2.directed_mode = 1;
            // p0_rd_case5_2.dir_rw        = AXI_READ;
            // p0_rd_case5_2.dir_addr      = case5_2_addr;
            // p0_rd_case5_2.dir_beats     = 4;
            // p0_rd_case5_2.dir_id        = safe_id(6, "case5_2_p0_rd");
            // p0_rd_case5_2.dir_burst     = 2'b01;
            // p0_rd_case5_2.dir_size      = 3;

            // p1_rd_case5_2 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_rd_case5_2");
            // p1_rd_case5_2.directed_mode = 1;
            // p1_rd_case5_2.dir_rw        = AXI_READ;
            // p1_rd_case5_2.dir_addr      = case5_2_addr;
            // p1_rd_case5_2.dir_beats     = 4;
            // p1_rd_case5_2.dir_id        = safe_id(7, "case5_2_p1_rd");
            // p1_rd_case5_2.dir_burst     = 2'b01;
            // p1_rd_case5_2.dir_size      = 3;

            // fork
            //     p0_rd_case5_2.start(env_h.p0_agent.seqr);
            //     p1_rd_case5_2.start(env_h.p1_agent.seqr);
            // join

            // ============================================================
            // Case 5.3 address plan: 8 beats * 8B = 64B
            // Choose a clean region not overlapping 5.1/5.2
            // ============================================================
            `uvm_info("DIRECT_TEST",
                $sformatf("Case 5.3: Same-addr parallel INCR 8 beats + interleaved WSTRB (P0=AA, P1=55) @0x%0h",
                        case5_3_addr),
                UVM_MEDIUM)

            // ---------------- P0: write AA lanes (odd bytes) ----------------
            p0_wr_case5_3 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case5_3");
            p0_wr_case5_3.directed_mode = 1;
            p0_wr_case5_3.dir_rw        = AXI_WRITE;
            p0_wr_case5_3.dir_addr      = case5_3_addr;
            p0_wr_case5_3.dir_beats     = 8;
            p0_wr_case5_3.dir_id        = safe_id(12, "case5_3_p0_wr");
            p0_wr_case5_3.dir_burst     = 2'b01;
            p0_wr_case5_3.dir_size      = 3;
            p0_wr_case5_3.dir_wdata     = 64'hA7A6A5A4A3A2A1A0; // +i per beat
            p0_wr_case5_3.dir_wstrb     = 8'hAA;                // lanes 1,3,5,7

            // ---------------- P1: write 55 lanes (even bytes) ----------------
            p1_wr_case5_3 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_wr_case5_3");
            p1_wr_case5_3.directed_mode = 1;
            p1_wr_case5_3.dir_rw        = AXI_WRITE;
            p1_wr_case5_3.dir_addr      = case5_3_addr;
            p1_wr_case5_3.dir_beats     = 8;
            p1_wr_case5_3.dir_id        = safe_id(13, "case5_3_p1_wr");
            p1_wr_case5_3.dir_burst     = 2'b01;
            p1_wr_case5_3.dir_size      = 3;
            p1_wr_case5_3.dir_wdata     = 64'hB7B6B5B4B3B2B1B0; // +i per beat
            p1_wr_case5_3.dir_wstrb     = 8'h55;                // lanes 0,2,4,6

            // Fire both writes concurrently
            fork
                begin
                    p0_wr_case5_3.start(env_h.p0_agent.seqr);
                end
                begin
                    #1ns; // small skew; keep it
                    p1_wr_case5_3.start(env_h.p1_agent.seqr);
                end
            join

            #50ns; // settle

            // Read back concurrently
            p0_rd_case5_3 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case5_3");
            p0_rd_case5_3.directed_mode = 1;
            p0_rd_case5_3.dir_rw        = AXI_READ;
            p0_rd_case5_3.dir_addr      = case5_3_addr;
            p0_rd_case5_3.dir_beats     = 8;
            p0_rd_case5_3.dir_id        = safe_id(14, "case5_3_p0_rd");
            p0_rd_case5_3.dir_burst     = 2'b01;
            p0_rd_case5_3.dir_size      = 3;

            p1_rd_case5_3 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_rd_case5_3");
            p1_rd_case5_3.directed_mode = 1;
            p1_rd_case5_3.dir_rw        = AXI_READ;
            p1_rd_case5_3.dir_addr      = case5_3_addr;
            p1_rd_case5_3.dir_beats     = 8;
            p1_rd_case5_3.dir_id        = safe_id(15, "case5_3_p1_rd");
            p1_rd_case5_3.dir_burst     = 2'b01;
            p1_rd_case5_3.dir_size      = 3;

            fork
                p0_rd_case5_3.start(env_h.p0_agent.seqr);
                p1_rd_case5_3.start(env_h.p1_agent.seqr);
            join

            `uvm_info("DIRECT_TEST", "Directed RAM test Case 5 completed", UVM_MEDIUM)
        end : CASE5


        phase.drop_objection(this);
    endtask

endclass : axi_mm_directed_test

`endif
