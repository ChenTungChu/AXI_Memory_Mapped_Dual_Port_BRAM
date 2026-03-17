// File: tb/uvm/test/axi_mm_directed_test.sv
`ifndef AXI_MM_DIRECTED_TEST_SV
`define AXI_MM_DIRECTED_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

// ------------------------------------------------------------
// Directed Test
// ------------------------------------------------------------
class axi_mm_directed_test extends uvm_test;

    `uvm_component_utils(axi_mm_directed_test)

    // Local parameters
    localparam int ADDR_WIDTH = 32;
    localparam int DATA_WIDTH = 64;
    localparam int ID_WIDTH   = 4;

    // Environment handle
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
    // Helper function: Safet ID range check
    // ------------------------------------------------------------
    function automatic logic [ID_WIDTH-1:0] safe_id(int unsigned raw, string who="");
        if (raw >= (1<<ID_WIDTH)) begin
            `uvm_fatal("ID_RANGE", $sformatf("%s raw_id=%0d exceeds ID_WIDTH=%0d (max=%0d)", who, raw, ID_WIDTH, (1<<ID_WIDTH)-1))
        end
        return raw[ID_WIDTH-1:0];
    endfunction


    // Case selection
    localparam string DEFAULT_CASE = "1";   

    function automatic string get_plusarg_str(string key);
        string v;
        if ($value$plusargs({key, "=%s"}, v)) return v;
        return "";
    endfunction

    function automatic int str_find(input string hay, input string needle);
        int i, j;
        if (needle.len() == 0) return 0;
        if (hay.len() < needle.len()) return -1;

        for (i = 0; i <= hay.len()-needle.len(); i++) begin
            for (j = 0; j < needle.len(); j++) begin
                if (hay[i+j] != needle[j]) break;
            end
            if (j == needle.len()) return i;
        end
        return -1;
    endfunction

    function automatic bit case_enabled(string tag);
        string one, list;
        one  = get_plusarg_str("CASE");
        list = get_plusarg_str("CASELIST");

        // Run all
        if (one == "all") return 1;

        // Single selection
        if (one != "") return (one == tag);

        // List selection
        if (list != "") begin
            string tmp;
            tmp = {",", list, ","};
            return (str_find(tmp, {",", tag, ","}) != -1);
        end

        // Default
        return (tag == DEFAULT_CASE);
    endfunction

    task automatic banner_case(string cid, string title);
        `uvm_info("DIRECTED_TEST", $sformatf("========== RUN CASE %s : %s ==========", cid, title), UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Backpressure VIF handles
    // ------------------------------------------------------------
    virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_master  p0_m;
    virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_master  p1_m;
    virtual axi_mm_commit_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 8).mp_monitor commit_m;

    function automatic void get_bp_vifs();
        if (!uvm_config_db#(virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_master)::get(this, "env_h.p0_agent", "vif_m", p0_m))
            `uvm_fatal("VIF_GET", "Failed to get p0 master vif: key='vif_m' scope='env_h.p0_agent'")

        if (!uvm_config_db#(virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_master)::get(this, "env_h.p1_agent", "vif_m", p1_m))
            `uvm_fatal("VIF_GET", "Failed to get p1 master vif: key='vif_m' scope='env_h.p1_agent'")

        if (!uvm_config_db#(virtual axi_mm_commit_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 8).mp_monitor)::get(this, "env_h.commit_mon", "vif", commit_m))
            `uvm_fatal("VIF_GET", "Failed to get commit monitor vif: key='vif' scope='env_h.commit_mon'")
    endfunction

    task automatic wait_cycles(input logic clk, input int unsigned n);
        repeat (n) @(posedge clk);
    endtask


    // ------------------------------------------------------------
    // Case 0: Single beat write/read
    // ------------------------------------------------------------
    task automatic run_case_0();
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) wr_seq;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) rd_seq;

        banner_case("0", "Single beat write/read");

        // WRITE
        wr_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("wr_seq_case0");
        wr_seq.directed_mode = 1;
        wr_seq.dir_rw        = AXI_WRITE;
        wr_seq.dir_addr      = 32'h0000_0100;
        wr_seq.dir_wdata     = 64'hDEAD_BEEF_1234_5678;
        wr_seq.dir_beats     = 1;
        wr_seq.dir_id        = safe_id(0, "case0 wr");
        wr_seq.dir_wstrb     = 8'hFF;
        wr_seq.start(env_h.p0_agent.seqr);

        // READ
        rd_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("rd_seq_case0");
        rd_seq.directed_mode = 1;
        rd_seq.dir_rw        = AXI_READ;
        rd_seq.dir_addr      = 32'h0000_0100;
        rd_seq.dir_beats     = 1;
        rd_seq.dir_id        = safe_id(1, "case0 rd");
        rd_seq.start(env_h.p0_agent.seqr);

        `uvm_info("DIRECTED_TEST", "[CASE_0] Done", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Case 1: Multi-beat INCR burst write/read
    // ------------------------------------------------------------
    task automatic run_case_1();
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) wr_seq;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) rd_seq;

        banner_case("1", "Multi-beat INCR burst write/read");

        // Write burst
        wr_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("wr_seq_case1");
        wr_seq.directed_mode = 1;
        wr_seq.dir_rw        = AXI_WRITE;
        wr_seq.dir_addr      = 32'h0000_0200;
        wr_seq.dir_beats     = 4;
        wr_seq.dir_id        = safe_id(2, "case1 wr");
        wr_seq.dir_wdata     = 64'hDEAD_BEEF_0000_0000;
        wr_seq.dir_burst     = 2'b01;  // INCR
        wr_seq.dir_size      = 3;      // 8 bytes/beat
        wr_seq.dir_wstrb     = 8'hFF;
        wr_seq.start(env_h.p0_agent.seqr);

        // Read burst
        rd_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("rd_seq_case1");
        rd_seq.directed_mode = 1;
        rd_seq.dir_rw        = AXI_READ;
        rd_seq.dir_addr      = 32'h0000_0200;
        rd_seq.dir_beats     = 4;
        rd_seq.dir_id        = safe_id(3, "case1 rd");
        rd_seq.dir_burst     = 2'b01; // INCR
        rd_seq.dir_size      = 3;
        rd_seq.start(env_h.p0_agent.seqr);

        `uvm_info("DIRECTED_TEST", "[CASE_1] Done", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Case 2: WRAP burst write/read 
    // ------------------------------------------------------------
    task automatic run_case_2();
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) wr_seq;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) rd_seq;

        banner_case("2", "WRAP burst write/read");

        // WRITE
        wr_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("wr_seq_case2");
        wr_seq.directed_mode = 1;
        wr_seq.dir_rw        = AXI_WRITE;
        wr_seq.dir_addr      = 32'h0000_0318;     // wrap-start
        wr_seq.dir_beats     = 4;                 // len=3
        wr_seq.dir_id        = safe_id(4, "case2 wr");
        wr_seq.dir_wdata     = 64'hCAFE_BABE_0000_0000;
        wr_seq.dir_burst     = 2'b10;             // WRAP
        wr_seq.dir_size      = 3;                 // 8 bytes/beat for 64-bit data
        wr_seq.dir_wstrb     = 8'hFF;
        wr_seq.start(env_h.p0_agent.seqr);

        // READ
        rd_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("rd_seq_case2");
        rd_seq.directed_mode = 1;
        rd_seq.dir_rw        = AXI_READ;
        rd_seq.dir_addr      = 32'h0000_0318;
        rd_seq.dir_beats     = 4;
        rd_seq.dir_id        = safe_id(5, "case2 rd");
        rd_seq.dir_burst     = 2'b10;             // WRAP
        rd_seq.dir_size      = 3;
        rd_seq.start(env_h.p0_agent.seqr);

        `uvm_info("DIRECTED_TEST", "[CASE_2] Done", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Case 3A: Partial strobe write + readback
    // ------------------------------------------------------------
    task automatic run_case_3_1();
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) wr_seq;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) rd_seq;
        logic [ADDR_WIDTH-1:0] addr;

        banner_case("3.1", "Partial strobe write + readback");

        addr = 32'h0000_0400;

        // 1. Baseline full write
        wr_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("wr_seq_case3_1_full");
        wr_seq.directed_mode = 1;
        wr_seq.dir_rw        = AXI_WRITE;
        wr_seq.dir_addr      = addr;
        wr_seq.dir_beats     = 1;
        wr_seq.dir_id        = safe_id(6, "case3.1 full wr");
        wr_seq.dir_wdata     = 64'h1122_3344_5566_7788;
        wr_seq.dir_burst     = 2'b01;
        wr_seq.dir_size      = 3;
        wr_seq.dir_wstrb     = 8'hFF;
        wr_seq.start(env_h.p0_agent.seqr);

        // 2. Partial write (low 2 bytes)
        wr_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("wr_seq_case3_1_part");
        wr_seq.directed_mode = 1;
        wr_seq.dir_rw        = AXI_WRITE;
        wr_seq.dir_addr      = addr;
        wr_seq.dir_beats     = 1;
        wr_seq.dir_id        = safe_id(7, "case3.1 part wr");
        wr_seq.dir_wdata     = 64'h0000_0000_0000_AAAA;
        wr_seq.dir_burst     = 2'b01;
        wr_seq.dir_size      = 3;
        wr_seq.dir_wstrb     = 8'b0000_0011;
        wr_seq.start(env_h.p0_agent.seqr);

        // 3. Read back
        rd_seq = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("rd_seq_case3_1");
        rd_seq.directed_mode = 1;
        rd_seq.dir_rw        = AXI_READ;
        rd_seq.dir_addr      = addr;
        rd_seq.dir_beats     = 1;
        rd_seq.dir_id        = safe_id(8, "case3.1 rd");
        rd_seq.dir_burst     = 2'b01;
        rd_seq.dir_size      = 3;
        rd_seq.start(env_h.p0_agent.seqr);

        `uvm_info("DIRECTED_TEST", "[CASE_3A] Done", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Case 3B: Cross-port coherence + same-address partial collision
    // ------------------------------------------------------------
    task automatic run_case_3_2();
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_full;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_wr_part;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_rd;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_rd;

        logic [ADDR_WIDTH-1:0] addr;

        banner_case("3.2", "Cross-port coherence + same-address partial collision");

        addr = 32'h0000_0410;

        p0_wr_full = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case3_2_full");
        p0_wr_full.directed_mode = 1;
        p0_wr_full.dir_rw        = AXI_WRITE;
        p0_wr_full.dir_addr      = addr;
        p0_wr_full.dir_beats     = 1;
        p0_wr_full.dir_id        = safe_id(9, "case3.2 p0 wr");
        p0_wr_full.dir_burst     = 2'b01;
        p0_wr_full.dir_size      = 3;
        p0_wr_full.dir_wdata     = 64'h1122_3344_5566_7788;
        p0_wr_full.dir_wstrb     = 8'hFF;
        p0_wr_full.start(env_h.p0_agent.seqr);

        p1_wr_part = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_wr_case3_2_part");
        p1_wr_part.directed_mode = 1;
        p1_wr_part.dir_rw        = AXI_WRITE;
        p1_wr_part.dir_addr      = addr;
        p1_wr_part.dir_beats     = 1;
        p1_wr_part.dir_id        = safe_id(10, "case3.2 p1 part wr");
        p1_wr_part.dir_burst     = 2'b01;
        p1_wr_part.dir_size      = 3;
        p1_wr_part.dir_wdata     = 64'hAAAA_0000_0000_0000;
        p1_wr_part.dir_wstrb     = 8'b1100_0000;
        p1_wr_part.start(env_h.p1_agent.seqr);

        p0_rd = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case3_2");
        p0_rd.directed_mode = 1;
        p0_rd.dir_rw        = AXI_READ;
        p0_rd.dir_addr      = addr;
        p0_rd.dir_beats     = 1;
        p0_rd.dir_id        = safe_id(11, "case3.2 p0 rd");
        p0_rd.dir_burst     = 2'b01;
        p0_rd.dir_size      = 3;
        p0_rd.dir_wstrb     = 8'hFF;
        p0_rd.start(env_h.p0_agent.seqr);

        p1_rd = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_rd_case3_2");
        p1_rd.directed_mode = 1;
        p1_rd.dir_rw        = AXI_READ;
        p1_rd.dir_addr      = addr;
        p1_rd.dir_beats     = 1;
        p1_rd.dir_id        = safe_id(12, "case3.2 p1 rd");
        p1_rd.dir_burst     = 2'b01;
        p1_rd.dir_size      = 3;
        p1_rd.dir_wstrb     = 8'hFF;
        p1_rd.start(env_h.p1_agent.seqr);

        `uvm_info("DIRECTED_TEST", "[Case_3B] Done", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Case 3C: Same-address cross-port collision + byte-merge
    // ------------------------------------------------------------
    task automatic run_case_3_3();
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_lo;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_wr_hi;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_rd;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_rd;

        logic [ADDR_WIDTH-1:0] addr;

        banner_case("3.3", "Same-address cross-port collision + byte-merge");

        addr = 32'h0000_0420;

        p0_wr_lo = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_lo_case_3_3");
        p0_wr_lo.directed_mode = 1;
        p0_wr_lo.dir_rw        = AXI_WRITE;
        p0_wr_lo.dir_addr      = addr;
        p0_wr_lo.dir_beats     = 1;
        p0_wr_lo.dir_id        = safe_id(12, "case3.3 p0 wr");
        p0_wr_lo.dir_burst     = 2'b01;
        p0_wr_lo.dir_size      = 3;
        p0_wr_lo.dir_wdata     = 64'h0000_0000_1122_3344;
        p0_wr_lo.dir_wstrb     = 8'h0F;

        p1_wr_hi = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_wr_hi_case_3_3");
        p1_wr_hi.directed_mode = 1;
        p1_wr_hi.dir_rw        = AXI_WRITE;
        p1_wr_hi.dir_addr      = addr;
        p1_wr_hi.dir_beats     = 1;
        p1_wr_hi.dir_id        = safe_id(13, "case3.3 p1 wr");
        p1_wr_hi.dir_burst     = 2'b01;
        p1_wr_hi.dir_size      = 3;
        p1_wr_hi.dir_wdata     = 64'hAABB_CCDD_0000_0000;
        p1_wr_hi.dir_wstrb     = 8'hF0;

        fork
            begin
                p0_wr_lo.start(env_h.p0_agent.seqr);
            end
            begin
                #1ns;
                p1_wr_hi.start(env_h.p1_agent.seqr);
            end
        join

        p0_rd = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case_3_3");
        p0_rd.directed_mode = 1;
        p0_rd.dir_rw        = AXI_READ;
        p0_rd.dir_addr      = addr;
        p0_rd.dir_beats     = 1;
        p0_rd.dir_id        = safe_id(14, "case3.3 p0 rd");
        p0_rd.dir_burst     = 2'b01;
        p0_rd.dir_size      = 3;

        p1_rd = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_rd_case_3_3");
        p1_rd.directed_mode = 1;
        p1_rd.dir_rw        = AXI_READ;
        p1_rd.dir_addr      = addr;
        p1_rd.dir_beats     = 1;
        p1_rd.dir_id        = safe_id(15, "case3.3 p1 rd");
        p1_rd.dir_burst     = 2'b01;
        p1_rd.dir_size      = 3;

        p0_rd.start(env_h.p0_agent.seqr);
        p1_rd.start(env_h.p1_agent.seqr);

        `uvm_info("DIRECTED_TEST", "[Case_3C] Done", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Case 4: Burst integrity stress (INCR/WRAP/FIXED) + cross-port coherence
    // ------------------------------------------------------------
    task automatic run_case_4();
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_4_1, p0_rd_4_1;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_4_2, p0_rd_4_2;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_4_3, p0_rd_4_3;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_4_4, p0_rd_4_4, p1_rd_4_4;

        logic [ADDR_WIDTH-1:0] a1, a2, a3, a4;

        banner_case("4", "Burst integrity stress (INCR/WRAP/FIXED) + cross-port coherence");

        a1 = 32'h0000_0500;
        a2 = 32'h0000_0558; // wrap start
        a3 = 32'h0000_0580;
        a4 = 32'h0000_05C0;

        // 4.1 INCR 4 beats
        p0_wr_4_1 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case4_1");
        p0_wr_4_1.directed_mode = 1;
        p0_wr_4_1.dir_rw        = AXI_WRITE;
        p0_wr_4_1.dir_addr      = a1;
        p0_wr_4_1.dir_beats     = 4;
        p0_wr_4_1.dir_id        = safe_id(0, "case4.1 wr");
        p0_wr_4_1.dir_burst     = 2'b01;
        p0_wr_4_1.dir_size      = 3;
        p0_wr_4_1.dir_wdata     = 64'h1000_0000_0000_0000;
        p0_wr_4_1.dir_wstrb     = 8'hFF;

        p0_rd_4_1 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case4_1");
        p0_rd_4_1.directed_mode = 1;
        p0_rd_4_1.dir_rw        = AXI_READ;
        p0_rd_4_1.dir_addr      = a1;
        p0_rd_4_1.dir_beats     = 4;
        p0_rd_4_1.dir_id        = safe_id(1, "case4.1 rd");
        p0_rd_4_1.dir_burst     = 2'b01;
        p0_rd_4_1.dir_size      = 3;

        p0_wr_4_1.start(env_h.p0_agent.seqr);
        p0_rd_4_1.start(env_h.p0_agent.seqr);

        // 4.2 WRAP 4 beats
        p0_wr_4_2 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case4_2");
        p0_wr_4_2.directed_mode = 1;
        p0_wr_4_2.dir_rw        = AXI_WRITE;
        p0_wr_4_2.dir_addr      = a2;
        p0_wr_4_2.dir_beats     = 4;
        p0_wr_4_2.dir_id        = safe_id(2, "case4.2 wr");
        p0_wr_4_2.dir_burst     = 2'b10;
        p0_wr_4_2.dir_size      = 3;
        p0_wr_4_2.dir_wdata     = 64'h2000_0000_0000_0000;
        p0_wr_4_2.dir_wstrb     = 8'hFF;

        p0_rd_4_2 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case4_2");
        p0_rd_4_2.directed_mode = 1;
        p0_rd_4_2.dir_rw        = AXI_READ;
        p0_rd_4_2.dir_addr      = a2;
        p0_rd_4_2.dir_beats     = 4;
        p0_rd_4_2.dir_id        = safe_id(3, "case4.2 rd");
        p0_rd_4_2.dir_burst     = 2'b10;
        p0_rd_4_2.dir_size      = 3;

        p0_wr_4_2.start(env_h.p0_agent.seqr);
        p0_rd_4_2.start(env_h.p0_agent.seqr);

        // 4.3 FIXED burst overwrite, read 1 beat
        p0_wr_4_3 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case4_3");
        p0_wr_4_3.directed_mode = 1;
        p0_wr_4_3.dir_rw        = AXI_WRITE;
        p0_wr_4_3.dir_addr      = a3;
        p0_wr_4_3.dir_beats     = 4;
        p0_wr_4_3.dir_id        = safe_id(4, "case4.3 wr");
        p0_wr_4_3.dir_burst     = 2'b00;
        p0_wr_4_3.dir_size      = 3;
        p0_wr_4_3.dir_wdata     = 64'h3000_0000_0000_0000;
        p0_wr_4_3.dir_wstrb     = 8'hFF;

        p0_rd_4_3 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case4_3");
        p0_rd_4_3.directed_mode = 1;
        p0_rd_4_3.dir_rw        = AXI_READ;
        p0_rd_4_3.dir_addr      = a3;
        p0_rd_4_3.dir_beats     = 1;
        p0_rd_4_3.dir_id        = safe_id(5, "case4.3 rd");
        p0_rd_4_3.dir_burst     = 2'b01;
        p0_rd_4_3.dir_size      = 3;

        p0_wr_4_3.start(env_h.p0_agent.seqr);
        p0_rd_4_3.start(env_h.p0_agent.seqr);

        // 4.4 Cross-port coherence INCR burst
        p0_wr_4_4 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case4_4");
        p0_wr_4_4.directed_mode = 1;
        p0_wr_4_4.dir_rw        = AXI_WRITE;
        p0_wr_4_4.dir_addr      = a4;
        p0_wr_4_4.dir_beats     = 4;
        p0_wr_4_4.dir_id        = safe_id(6, "case4.4 wr");
        p0_wr_4_4.dir_burst     = 2'b01;
        p0_wr_4_4.dir_size      = 3;
        p0_wr_4_4.dir_wdata     = 64'h4000_0000_0000_0000;
        p0_wr_4_4.dir_wstrb     = 8'hFF;

        p0_rd_4_4 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case4_4");
        p0_rd_4_4.directed_mode = 1;
        p0_rd_4_4.dir_rw        = AXI_READ;
        p0_rd_4_4.dir_addr      = a4;
        p0_rd_4_4.dir_beats     = 4;
        p0_rd_4_4.dir_id        = safe_id(7, "case4.4 p0 rd");
        p0_rd_4_4.dir_burst     = 2'b01;
        p0_rd_4_4.dir_size      = 3;

        p1_rd_4_4 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_rd_case4_4");
        p1_rd_4_4.directed_mode = 1;
        p1_rd_4_4.dir_rw        = AXI_READ;
        p1_rd_4_4.dir_addr      = a4;
        p1_rd_4_4.dir_beats     = 4;
        p1_rd_4_4.dir_id        = safe_id(8, "case4.4 p1 rd");
        p1_rd_4_4.dir_burst     = 2'b01;
        p1_rd_4_4.dir_size      = 3;

        p0_wr_4_4.start(env_h.p0_agent.seqr);

        fork
            p0_rd_4_4.start(env_h.p0_agent.seqr);
            p1_rd_4_4.start(env_h.p1_agent.seqr);
        join

        `uvm_info("DIRECTED_TEST", "[CASE_4] Done", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Case 5A: Parallel same addr INCR 8 beats with complementary WSTRB
    // ------------------------------------------------------------
    task automatic run_case_5_1();
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_wr;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_rd;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_rd;

        logic [ADDR_WIDTH-1:0] addr;

        banner_case("5.1", "Parallel same addr INCR 8 beats with complementary WSTRB");

        addr = 32'h0000_0620; // 8 beats * 8B = 64B -> [0x620..0x65F]

        p0_wr = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case5_1");
        p0_wr.directed_mode = 1;
        p0_wr.dir_rw        = AXI_WRITE;
        p0_wr.dir_addr      = addr;
        p0_wr.dir_beats     = 8;
        p0_wr.dir_id        = safe_id(8, "case5.1 p0 wr");
        p0_wr.dir_burst     = 2'b01;
        p0_wr.dir_size      = 3;
        p0_wr.dir_wdata     = 64'h5000_0000_0000_0000;
        p0_wr.dir_wstrb     = 8'hF0;

        p1_wr = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_wr_case5_1");
        p1_wr.directed_mode = 1;
        p1_wr.dir_rw        = AXI_WRITE;
        p1_wr.dir_addr      = addr;
        p1_wr.dir_beats     = 8;
        p1_wr.dir_id        = safe_id(9, "case5.1 p1 wr");
        p1_wr.dir_burst     = 2'b01;
        p1_wr.dir_size      = 3;
        p1_wr.dir_wdata     = 64'h0000_0000_6000_0000;
        p1_wr.dir_wstrb     = 8'h0F;

        fork
            begin
                p0_wr.start(env_h.p0_agent.seqr);
            end
            begin
                #1ns;
                p1_wr.start(env_h.p1_agent.seqr);
            end
        join

        #50ns;

        p0_rd = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case5_1");
        p0_rd.directed_mode = 1;
        p0_rd.dir_rw        = AXI_READ;
        p0_rd.dir_addr      = addr;
        p0_rd.dir_beats     = 8;
        p0_rd.dir_id        = safe_id(10, "case5.1 p0 rd");
        p0_rd.dir_burst     = 2'b01;
        p0_rd.dir_size      = 3;

        p1_rd = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_rd_case5_1");
        p1_rd.directed_mode = 1;
        p1_rd.dir_rw        = AXI_READ;
        p1_rd.dir_addr      = addr;
        p1_rd.dir_beats     = 8;
        p1_rd.dir_id        = safe_id(11, "case5.1 p1 rd");
        p1_rd.dir_burst     = 2'b01;
        p1_rd.dir_size      = 3;

        fork
            p0_rd.start(env_h.p0_agent.seqr);
            p1_rd.start(env_h.p1_agent.seqr);
        join

        `uvm_info("DIRECTED_TEST", "[CASE_5A] Done", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Case 5B: Same addr multi-beat byte merge across ports
    // ------------------------------------------------------------
    task automatic run_case_5_2();
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr_full;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_wr_part;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_rd;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_rd;
        logic [ADDR_WIDTH-1:0] addr;

        banner_case("5.2", "Same addr multi-beat byte merge across ports");

        addr = 32'h0000_0700; // 4 beats * 8B = 32B (0x700 - 0x71F)

        p0_wr_full = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case5_2_full");
        p0_wr_full.directed_mode = 1;
        p0_wr_full.dir_rw        = AXI_WRITE;
        p0_wr_full.dir_addr      = addr;
        p0_wr_full.dir_beats     = 4;
        p0_wr_full.dir_id        = safe_id(4, "case5.2 p0 wr");
        p0_wr_full.dir_burst     = 2'b01;
        p0_wr_full.dir_size      = 3;
        p0_wr_full.dir_wdata     = 64'h7777_6666_5555_0000;
        p0_wr_full.dir_wstrb     = 8'hFF;
        p0_wr_full.start(env_h.p0_agent.seqr);

        p1_wr_part = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_wr_case5_2_part");
        p1_wr_part.directed_mode = 1;
        p1_wr_part.dir_rw        = AXI_WRITE;
        p1_wr_part.dir_addr      = addr;
        p1_wr_part.dir_beats     = 4;
        p1_wr_part.dir_id        = safe_id(5, "case5.2 p1 wr");
        p1_wr_part.dir_burst     = 2'b01;
        p1_wr_part.dir_size      = 3;
        p1_wr_part.dir_wdata     = 64'h0000_0000_ABCD_1000;
        p1_wr_part.dir_wstrb     = 8'h0F;
        p1_wr_part.start(env_h.p1_agent.seqr);

        p0_rd = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case5_2");
        p0_rd.directed_mode = 1;
        p0_rd.dir_rw        = AXI_READ;
        p0_rd.dir_addr      = addr;
        p0_rd.dir_beats     = 4;
        p0_rd.dir_id        = safe_id(6, "case5.2 p0 rd");
        p0_rd.dir_burst     = 2'b01;
        p0_rd.dir_size      = 3;

        p1_rd = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_rd_case5_2");
        p1_rd.directed_mode = 1;
        p1_rd.dir_rw        = AXI_READ;
        p1_rd.dir_addr      = addr;
        p1_rd.dir_beats     = 4;
        p1_rd.dir_id        = safe_id(7, "case5.2 p1 rd");
        p1_rd.dir_burst     = 2'b01;
        p1_rd.dir_size      = 3;

        fork
            p0_rd.start(env_h.p0_agent.seqr);
            p1_rd.start(env_h.p1_agent.seqr);
        join

        `uvm_info("DIRECTED_TEST", "[CASE_5B] Done", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Case 5C: Same addr parallel INCR 8 beats + interleaved WSTRB (P0=AA, P1=55)
    // ------------------------------------------------------------
    task automatic run_case_5_3();
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_wr;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_wr;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p0_rd;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) p1_rd;

        logic [ADDR_WIDTH-1:0] addr;

        banner_case("5.3", "Same addr parallel INCR 8 beats + interleaved WSTRB (P0=AA, P1=55)");

        addr = 32'h0000_0780; // 8 beats * 8B = 64B (0x780 - 0x7BF)

        // P0: write AA lanes (odd bytes)
        p0_wr = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case5_3");
        p0_wr.directed_mode = 1;
        p0_wr.dir_rw        = AXI_WRITE;
        p0_wr.dir_addr      = addr;
        p0_wr.dir_beats     = 8;
        p0_wr.dir_id        = safe_id(12, "case5.3 p0 wr");
        p0_wr.dir_burst     = 2'b01;
        p0_wr.dir_size      = 3;
        p0_wr.dir_wdata     = 64'hA7A6A5A4A3A2A1A0;
        p0_wr.dir_wstrb     = 8'hAA; // lanes 1,3,5,7

        // P1: write 55 lanes (even bytes)
        p1_wr = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_wr_case5_3");
        p1_wr.directed_mode = 1;
        p1_wr.dir_rw        = AXI_WRITE;
        p1_wr.dir_addr      = addr;
        p1_wr.dir_beats     = 8;
        p1_wr.dir_id        = safe_id(13, "case5.3 p1 wr");
        p1_wr.dir_burst     = 2'b01;
        p1_wr.dir_size      = 3;
        p1_wr.dir_wdata     = 64'hB7B6B5B4B3B2B1B0;
        p1_wr.dir_wstrb     = 8'h55; // lanes 0,2,4,6

        fork
            begin
                p0_wr.start(env_h.p0_agent.seqr);
            end
            begin
                #1ns;
                p1_wr.start(env_h.p1_agent.seqr);
            end
        join

        #50ns;

        // Read back concurrently
        p0_rd = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case5_3");
        p0_rd.directed_mode = 1;
        p0_rd.dir_rw        = AXI_READ;
        p0_rd.dir_addr      = addr;
        p0_rd.dir_beats     = 8;
        p0_rd.dir_id        = safe_id(14, "case5.3 p0 rd");
        p0_rd.dir_burst     = 2'b01;
        p0_rd.dir_size      = 3;

        p1_rd = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p1_rd_case5_3");
        p1_rd.directed_mode = 1;
        p1_rd.dir_rw        = AXI_READ;
        p1_rd.dir_addr      = addr;
        p1_rd.dir_beats     = 8;
        p1_rd.dir_id        = safe_id(15, "case5.3 p1 rd");
        p1_rd.dir_burst     = 2'b01;
        p1_rd.dir_size      = 3;

        fork
            p0_rd.start(env_h.p0_agent.seqr);
            p1_rd.start(env_h.p1_agent.seqr);
        join

        `uvm_info("DIRECTED_TEST", "[CASE_5C] Done", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Case 6A: Stall commit_if.ready while issuing a P1 write burst
    // ------------------------------------------------------------
    task automatic run_case_6_1();
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) wr0, wr1, wr2;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) rd;

        logic [ADDR_WIDTH-1:0] base;
        int unsigned stall_cycles;

        // save/restore commit_mon knobs
        bit          orig_drive_ready_always;
        bit          orig_stress_enable;
        int unsigned orig_ready_prob;
        int unsigned orig_force_ready_after;
        int unsigned orig_ready_holdoff_cycles;

        stall_cycles = 300;
        base         = 32'h0000_0B00;

        banner_case("6.1", "Stall commit_if.ready while issuing a P1 write burst");

        // Sanity
        if (env_h.commit_mon == null)
            `uvm_fatal("DIRECTED_TEST", "env_h.commit_mon is null")


        // 1. Program commit monitor to HOLD ready LOW (no hdl_force)
        orig_drive_ready_always  = env_h.commit_mon.drive_ready_always;
        orig_stress_enable       = env_h.commit_mon.stress_enable;
        orig_ready_prob          = env_h.commit_mon.ready_prob;
        orig_force_ready_after   = env_h.commit_mon.force_ready_after;
        orig_ready_holdoff_cycles= env_h.commit_mon.ready_holdoff_cycles;

        env_h.commit_mon.drive_ready_always   = 1'b0;           // enable controlled mode
        env_h.commit_mon.stress_enable        = 1'b1;
        env_h.commit_mon.ready_prob           = 0;              // always 0 -> stall
        env_h.commit_mon.force_ready_after    = stall_cycles + 1000; // prevent auto-1
        env_h.commit_mon.ready_holdoff_cycles = 0;

        // 2. Issue multiple writes that require commit to progress
        wr0 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case6_1_0");
        wr0.directed_mode = 1;
        wr0.dir_rw        = AXI_WRITE;
        wr0.dir_addr      = base + 32'h00;
        wr0.dir_beats     = 4;
        wr0.dir_id        = safe_id(1, "case6.1 wr0");
        wr0.dir_burst     = 2'b01;
        wr0.dir_size      = 3;
        wr0.dir_wdata     = 64'h6100_0000_0000_0000;
        wr0.dir_wstrb     = 8'hFF;

        wr1 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case6_1_1");
        wr1.directed_mode = 1;
        wr1.dir_rw        = AXI_WRITE;
        wr1.dir_addr      = base + 32'h40;
        wr1.dir_beats     = 4;
        wr1.dir_id        = safe_id(2, "case6.1 wr1");
        wr1.dir_burst     = 2'b01;
        wr1.dir_size      = 3;
        wr1.dir_wdata     = 64'h6200_0000_0000_0000;
        wr1.dir_wstrb     = 8'hFF;

        wr2 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case6_1_2");
        wr2.directed_mode = 1;
        wr2.dir_rw        = AXI_WRITE;
        wr2.dir_addr      = base + 32'h80;
        wr2.dir_beats     = 4;
        wr2.dir_id        = safe_id(3, "case6.1 wr2");
        wr2.dir_burst     = 2'b01;
        wr2.dir_size      = 3;
        wr2.dir_wdata     = 64'h6300_0000_0000_0000;
        wr2.dir_wstrb     = 8'hFF;

        // 3. Run writes + release thread in parallel
        fork
            begin
                wr0.start(env_h.p0_agent.seqr);
            end
            begin
                #20ns;
                wr1.start(env_h.p0_agent.seqr);
            end
            begin
                #40ns;
                wr2.start(env_h.p0_agent.seqr);
            end
            begin
                #(stall_cycles * 10ns);

                // release commit backpressure (restore)
                env_h.commit_mon.drive_ready_always   = orig_drive_ready_always;
                env_h.commit_mon.stress_enable        = orig_stress_enable;
                env_h.commit_mon.ready_prob           = orig_ready_prob;
                env_h.commit_mon.force_ready_after    = orig_force_ready_after;
                env_h.commit_mon.ready_holdoff_cycles = orig_ready_holdoff_cycles;

                `uvm_info("DIRECT_TEST", "Case 6.1: Released commit.ready stall (restored commit_mon knobs)", UVM_MEDIUM)
            end
        join

        // 4. Read back to confirm no deadlock + data is visible
        rd = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case6_1");
        rd.directed_mode = 1;
        rd.dir_rw        = AXI_READ;
        rd.dir_addr      = base;
        rd.dir_beats     = 12;
        rd.dir_id        = safe_id(4, "case6.1 rd");
        rd.dir_burst     = 2'b01;
        rd.dir_size      = 3;
        rd.start(env_h.p0_agent.seqr);

        `uvm_info("DIRECTED_TEST", "[CASE_6A] Done", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Case 6B: Stall P0 BREADY while issuing multiple write bursts
    // ------------------------------------------------------------
    task automatic run_case_6_2();
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) wr0, wr1, wr2;
        axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) rd;

        logic [ADDR_WIDTH-1:0] base;
        int unsigned stall_cycles;

        // Get P0 master vif so we can do cycle-accurate waits on dma_clk domain
        virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_master p0_vif;

        // save/restore knobs
        bit          orig_hold_bready_high;
        bit          orig_stress_enable;
        int unsigned orig_bready_prob;
        int unsigned orig_force_ready_after;

        stall_cycles = 300;
        base         = 32'h0000_0A00;

        banner_case("6.2", "Stall P0 BREADY while issuing multiple write bursts");

        // 0. Make sure driver exists + fetch vif for cycle wait
        if (env_h.p0_agent == null || env_h.p0_agent.drv == null)
            `uvm_fatal("DIRECT_TEST", "env_h.p0_agent.drv is null")

        if (!uvm_config_db#(virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, 1).mp_master)::
              get(null, "*.p0_agent", "vif_m", p0_vif)) begin
            `uvm_fatal("DIRECT_TEST", "Cannot get p0 mp_master vif from config_db")
        end

        // Align to a clean edge
        @(p0_vif.cb_master);

        // 1. Program driver to HOLD bready LOW
        orig_hold_bready_high  = env_h.p0_agent.drv.hold_bready_high;
        orig_stress_enable     = env_h.p0_agent.drv.stress_enable;
        orig_bready_prob       = env_h.p0_agent.drv.bready_prob;
        orig_force_ready_after = env_h.p0_agent.drv.force_ready_after;

        env_h.p0_agent.drv.hold_bready_high  = 1'b0;                // don't hold high
        env_h.p0_agent.drv.stress_enable     = 1'b1;                // enable prob mode
        env_h.p0_agent.drv.bready_prob       = 0;                   // always 0 (stall)
        env_h.p0_agent.drv.force_ready_after = stall_cycles + 1000; // prevent auto-1 escape during stall

        `uvm_info("DIRECT_TEST", $sformatf("Case 6.2: Applied bready stall knobs (prob=0) for %0d dma cycles", stall_cycles), UVM_MEDIUM)

        // 2. Prepare 3 contiguous 4-beat INCR bursts
        wr0 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case6_2_0");
        wr0.directed_mode = 1;
        wr0.dir_rw        = AXI_WRITE;
        wr0.dir_addr      = base + 32'h00;
        wr0.dir_beats     = 4;
        wr0.dir_id        = safe_id(3, "case6.2 wr0");
        wr0.dir_burst     = 2'b01;
        wr0.dir_size      = 3;
        wr0.dir_wdata     = 64'h8200_0000_0000_0000;
        wr0.dir_wstrb     = 8'hFF;

        wr1 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case6_2_1");
        wr1.directed_mode = 1;
        wr1.dir_rw        = AXI_WRITE;
        wr1.dir_addr      = base + 32'h20;
        wr1.dir_beats     = 4;
        wr1.dir_id        = safe_id(4, "case6.2 wr1");
        wr1.dir_burst     = 2'b01;
        wr1.dir_size      = 3;
        wr1.dir_wdata     = 64'h8300_0000_0000_0000;
        wr1.dir_wstrb     = 8'hFF;

        wr2 = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_wr_case6_2_2");
        wr2.directed_mode = 1;
        wr2.dir_rw        = AXI_WRITE;
        wr2.dir_addr      = base + 32'h40;
        wr2.dir_beats     = 4;
        wr2.dir_id        = safe_id(5, "case6.2 wr2");
        wr2.dir_burst     = 2'b01;
        wr2.dir_size      = 3;
        wr2.dir_wdata     = 64'h8400_0000_0000_0000;
        wr2.dir_wstrb     = 8'hFF;

        // 3. Launch writes while bready is stuck low
        fork
            begin
                wr0.start(env_h.p0_agent.seqr);
            end
            begin
                repeat (2) @(p0_vif.cb_master);
                wr1.start(env_h.p0_agent.seqr);
            end
            begin
                repeat (4) @(p0_vif.cb_master);
                wr2.start(env_h.p0_agent.seqr);
            end
            begin
                // Stall window in dma cycles
                repeat (stall_cycles) @(p0_vif.cb_master);

                // Release backpressure
                env_h.p0_agent.drv.hold_bready_high  = orig_hold_bready_high;
                env_h.p0_agent.drv.stress_enable     = orig_stress_enable;
                env_h.p0_agent.drv.bready_prob       = orig_bready_prob;
                env_h.p0_agent.drv.force_ready_after = orig_force_ready_after;

                `uvm_info("DIRECT_TEST", "Case 6.2: Released bready stall", UVM_MEDIUM)
            end
        join

        // 4. Read back exactly the written region (3 bursts * 4 beats = 12 beats)
        rd = axi_mm_seq#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("p0_rd_case6_2");
        rd.directed_mode = 1;
        rd.dir_rw        = AXI_READ;
        rd.dir_addr      = base;
        rd.dir_beats     = 12;
        rd.dir_id        = safe_id(6, "case6.2 rd");
        rd.dir_burst     = 2'b01;
        rd.dir_size      = 3;
        rd.start(env_h.p0_agent.seqr);

        `uvm_info("DIRECTED_TEST", "[CASE_6B] Done", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Run phase: deterministic directed stimulus with selection
    // ------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        `uvm_info("DIRECTED_TEST", "Starting AXI-MM Directed Test", UVM_MEDIUM)

        if (case_enabled("0"))   run_case_0();
        if (case_enabled("1"))   run_case_1();
        if (case_enabled("2"))   run_case_2();
        if (case_enabled("3.1")) run_case_3_1();
        if (case_enabled("3.2")) run_case_3_2();
        if (case_enabled("3.3")) run_case_3_3();
        if (case_enabled("4"))   run_case_4();
        if (case_enabled("5.1")) run_case_5_1();
        if (case_enabled("5.2")) run_case_5_2();
        if (case_enabled("5.3")) run_case_5_3();
        if (case_enabled("6.1")) run_case_6_1();
        if (case_enabled("6.2")) run_case_6_2();

        `uvm_info("DIRECTED_TEST", "Directed Test completed", UVM_MEDIUM)
        phase.drop_objection(this);
    endtask

endclass : axi_mm_directed_test

`endif