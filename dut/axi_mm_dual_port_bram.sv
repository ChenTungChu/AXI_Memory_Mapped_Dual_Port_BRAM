// File: axi_mm_dual_port_bram.sv
// Clean "IP-like" Behavioral Multi-clock Dual-port AXI4-MM BRAM (READ_FIRST)
// - True dual-clock ports: Port0 on dma_clk, Port1 on core_clk
// - Single writer memory core in dma_clk domain (P0 writes + staged P1 writes)
// - READ path modeled as synchronous BRAM read with 2-cycle latency + no-bubble AXI R via FIFO
// - 3-stage meta pipeline (v1/v2/v3) aligns with 2-cycle data_q2 for both P0/P1
// - Read FIFOs are parameterized (default depth=16)
//
// UPDATED (WRITE OUTSTANDING SUPPORT + AXI-FRIENDLY B):
// - AW FIFO per port (WR_AW_DEPTH) so multiple AW can be accepted
// - B FIFO per port (WR_B_DEPTH) for multiple completions
// - W always binds to AW FIFO head (AXI compliant: W has no ID)
// - B channel is driven as a registered output (no combinational bvalid/bid/bresp from FIFO head)
// - AWREADY is additionally gated by "B FIFO credit reservation" to prevent B FIFO overflow
//
// Assumptions / scope:
// - Supports AXI INCR and WRAP addressing (FIXED treated as constant addr)
// - B response is OKAY
// - Write data channel is in-order w.r.t AW FIFO head (AXI compliant)
// - No read forwarding; READ_FIRST behavior (read returns old data if same-cycle write to same word)
//
// Endianness / lane mapping:
// - lane 0 = WDATA[7:0], corresponds to lowest byte address in the word
// - WSTRB[0] controls lane 0, etc.

`timescale 1ns/1ps

module axi_mm_dual_port_bram #(
    parameter int ADDR_WIDTH       = 32,
    parameter int DATA_WIDTH       = 64,
    parameter int ID_WIDTH         = 4,
    parameter int DEPTH_WORDS      = 1024,

    // Read FIFO depth (per port)
    parameter int RD_FIFO_DEPTH    = 16,

    // Write outstanding depths
    parameter int WR_AW_DEPTH      = 2,   // >=2 to pass Case 8A style
    parameter int WR_B_DEPTH       = 4,   // response queue depth

    // Optional: starvation detector for staged P1 writes (dma domain)
    parameter int STARVE_THRESHOLD = 2000,
    parameter bit ASSERT_ON_STARVE = 1
) (
    input  logic dma_clk,
    input  logic dma_rst_n,
    input  logic core_clk,
    input  logic core_rst_n,

    // AXI-MM slave interfaces (mp_slave modport expected)
    axi_mm_if axi0_if,
    axi_mm_if axi1_if
);

    // ------------------------------------------------------------
    // Local params / helpers
    // ------------------------------------------------------------
    localparam int IDW           = (ID_WIDTH > 0) ? ID_WIDTH : 1;
    localparam int BYTE_PER_WORD = DATA_WIDTH / 8;
    localparam int WORD_SHIFT    = $clog2(BYTE_PER_WORD);

    localparam int RD_PTR_W      = (RD_FIFO_DEPTH <= 1) ? 1 : $clog2(RD_FIFO_DEPTH);
    localparam int RD_CNT_W      = $clog2(RD_FIFO_DEPTH+1);

    localparam int WR_AW_PTR_W   = (WR_AW_DEPTH <= 1) ? 1 : $clog2(WR_AW_DEPTH);
    localparam int WR_AW_CNT_W   = $clog2(WR_AW_DEPTH+1);

    localparam int WR_B_PTR_W    = (WR_B_DEPTH <= 1) ? 1 : $clog2(WR_B_DEPTH);
    localparam int WR_B_CNT_W    = $clog2(WR_B_DEPTH+1);

    // synthesis translate_off
    initial begin
        if ((DATA_WIDTH % 8) != 0) $error("DATA_WIDTH must be a multiple of 8");
        if (DEPTH_WORDS <= 0)      $error("DEPTH_WORDS must be > 0");
        if (RD_FIFO_DEPTH <= 0)    $error("RD_FIFO_DEPTH must be > 0");
        if (WR_AW_DEPTH <= 0)      $error("WR_AW_DEPTH must be > 0");
        if (WR_B_DEPTH  <= 0)      $error("WR_B_DEPTH must be > 0");
    end
    // synthesis translate_on

    function automatic int size_to_bytes(input logic [2:0] size_field);
        size_to_bytes = 1 << size_field;
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] compute_incr_addr(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [2:0]            size_field,
        input int                    beat_index
    );
        compute_incr_addr = addr + (beat_index * size_to_bytes(size_field));
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] compute_wrap_addr(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [2:0]            size_field,
        input int                    len,
        input int                    beat_index
    );
        int beat_bytes;
        int wrap_bytes;
        logic [ADDR_WIDTH-1:0] base;
        beat_bytes        = size_to_bytes(size_field);
        wrap_bytes        = (len + 1) * beat_bytes;
        base              = (addr / wrap_bytes) * wrap_bytes;
        compute_wrap_addr = base + ((addr - base + beat_index * beat_bytes) % wrap_bytes);
    endfunction

    function automatic int unsigned word_index(input logic [ADDR_WIDTH-1:0] byte_addr);
        // map byte address to word index (truncate to depth)
        word_index = (byte_addr >> WORD_SHIFT) % DEPTH_WORDS;
    endfunction

    // ------------------------------------------------------------
    // Memory array (behavioral BRAM)
    // ------------------------------------------------------------
    logic [DATA_WIDTH-1:0] mem_word [0:DEPTH_WORDS-1];

    // ------------------------------------------------------------
    // Read FIFO item type
    // ------------------------------------------------------------
    typedef struct packed {
        logic [IDW-1:0]         rid;
        logic                  last;
        logic [DATA_WIDTH-1:0]  data;
    } rd_item_t;

    // ------------------------------------------------------------
    // Write AW FIFO entry type
    // ------------------------------------------------------------
    typedef struct packed {
        logic [IDW-1:0]        id;
        logic [ADDR_WIDTH-1:0] addr;
        logic [7:0]            len;
        logic [2:0]            size;
        logic [1:0]            burst;
    } aw_item_t;

    typedef struct packed {
        logic [IDW-1:0]        bid;
        logic [1:0]            bresp;
    } b_item_t;

    // ============================================================
    // PORT0 (dma_clk) : WRITE path
    // ============================================================
    logic [IDW-1:0]        p0_awid;
    logic [ADDR_WIDTH-1:0] p0_awaddr;
    logic [7:0]            p0_awlen;
    logic [2:0]            p0_awsize;
    logic [1:0]            p0_awburst;
    logic                  p0_aw_active;
    int unsigned           p0_wbeat_cnt;

    // P0 AW FIFO
    aw_item_t               p0_aw_fifo [0:WR_AW_DEPTH-1];
    logic [WR_AW_PTR_W-1:0] p0_aw_wptr, p0_aw_rptr;
    logic [WR_AW_CNT_W-1:0] p0_aw_count;
    logic                   p0_aw_full, p0_aw_empty;

    assign p0_aw_full  = (p0_aw_count == WR_AW_DEPTH[WR_AW_CNT_W-1:0]);
    assign p0_aw_empty = (p0_aw_count == '0);

    // P0 B FIFO
    b_item_t                p0_b_fifo  [0:WR_B_DEPTH-1];
    logic [WR_B_PTR_W-1:0]  p0_b_wptr, p0_b_rptr;
    logic [WR_B_CNT_W-1:0]  p0_b_count;
    logic                   p0_b_full, p0_b_empty;

    assign p0_b_full  = (p0_b_count == WR_B_DEPTH[WR_B_CNT_W-1:0]);
    assign p0_b_empty = (p0_b_count == '0);

    // B output register state (AXI-friendly)
    logic                   p0_b_out_valid;
    b_item_t                p0_b_out;

    // mem_core request interface
    logic                     p0_wr_req;
    logic                     p0_wr_consumed;  // pulse from mem_core
    logic [ADDR_WIDTH-1:0]    p0_wr_byte_addr;
    logic [DATA_WIDTH-1:0]    p0_wr_wdata;
    logic [BYTE_PER_WORD-1:0] p0_wr_wstrb;
    logic [2:0]               p0_wr_size;
    logic                     p0_wr_is_last;

    logic                     p0_w_hs;

    // WREADY only when we have an active burst and no pending req to mem_core
    assign axi0_if.wready = dma_rst_n && p0_aw_active && !p0_wr_req;
    assign p0_w_hs        = axi0_if.wvalid && axi0_if.wready;

    // ============================================================
    // PORT1 (core_clk) : WRITE path (staged to dma)
    // ============================================================
    logic [IDW-1:0]        p1_awid;
    logic [ADDR_WIDTH-1:0] p1_awaddr;
    logic [7:0]            p1_awlen;
    logic [2:0]            p1_awsize;
    logic [1:0]            p1_awburst;
    logic                  p1_aw_active;
    int unsigned           p1_wbeat_cnt;

    // P1 AW FIFO
    aw_item_t               p1_aw_fifo [0:WR_AW_DEPTH-1];
    logic [WR_AW_PTR_W-1:0] p1_aw_wptr, p1_aw_rptr;
    logic [WR_AW_CNT_W-1:0] p1_aw_count;
    logic                   p1_aw_full, p1_aw_empty;

    assign p1_aw_full  = (p1_aw_count == WR_AW_DEPTH[WR_AW_CNT_W-1:0]);
    assign p1_aw_empty = (p1_aw_count == '0);

    // P1 B FIFO
    b_item_t                p1_b_fifo  [0:WR_B_DEPTH-1];
    logic [WR_B_PTR_W-1:0]  p1_b_wptr, p1_b_rptr;
    logic [WR_B_CNT_W-1:0]  p1_b_count;
    logic                   p1_b_full, p1_b_empty;

    assign p1_b_full  = (p1_b_count == WR_B_DEPTH[WR_B_CNT_W-1:0]);
    assign p1_b_empty = (p1_b_count == '0);

    // B output register state (AXI-friendly)
    logic                   p1_b_out_valid;
    b_item_t                p1_b_out;

    // P1 local beat buffer (one beat) + bridge toggles
    logic                     p1_local_wr_valid;
    logic [ADDR_WIDTH-1:0]    p1_local_wr_byte_addr;
    logic [DATA_WIDTH-1:0]    p1_local_wr_wdata;
    logic [BYTE_PER_WORD-1:0] p1_local_wr_wstrb;
    logic [2:0]               p1_local_wr_size;
    logic                     p1_local_wr_is_last;

    logic                     p1_w_hs;
    assign axi1_if.wready = core_rst_n && p1_aw_active && !p1_local_wr_valid;
    assign p1_w_hs        = axi1_if.wvalid && axi1_if.wready;

    logic                  p1_req_outstanding;
    logic                  p1_sent_is_last;
    logic [IDW-1:0]        p1_sent_awid;

    // Core->DMA bridge regs
    logic [ADDR_WIDTH-1:0]    bridge_p1_addr_core;
    logic [DATA_WIDTH-1:0]    bridge_p1_wdata_core;
    logic [BYTE_PER_WORD-1:0] bridge_p1_wstrb_core;
    logic [2:0]               bridge_p1_size_core;
    logic                     bridge_p1_is_last_core;
    logic                     p1_req_toggle_core;

    // DMA-side sync and staging
    logic p1_req_toggle_sync1_dma, p1_req_toggle_sync2_dma;
    logic p1_req_toggle_last_seen_dma;

    logic [ADDR_WIDTH-1:0]    staged_p1_addr_dma;
    logic [DATA_WIDTH-1:0]    staged_p1_wdata_dma;
    logic [BYTE_PER_WORD-1:0] staged_p1_wstrb_dma;
    logic [2:0]               staged_p1_size_dma;
    logic                     staged_p1_is_last_dma;
    logic                     staged_p1_valid_dma;
    logic                     staged_p1_consumed; // pulse from mem_core

    // DMA->Core ack toggle
    logic p1_ack_toggle_dma;
    logic p1_ack_toggle_sync1_core, p1_ack_toggle_sync2_core;
    logic p1_ack_toggle_last_seen_core;

    // ============================================================
    // PORT0 (dma_clk) : READ path (unchanged)
    // ============================================================
    logic [IDW-1:0]        p0_arid;
    logic [ADDR_WIDTH-1:0] p0_araddr;
    logic [7:0]            p0_arlen;
    logic [2:0]            p0_arsize;
    logic [1:0]            p0_arburst;
    logic                  p0_ar_active;

    int unsigned           p0_issue_idx;
    int unsigned           p0_total_beats;   // arlen+1

    logic                  p0_rd_issue;
    logic [ADDR_WIDTH-1:0] p0_rd_addr;

    logic [DATA_WIDTH-1:0] p0_rd_q1, p0_rd_q2;

    logic            p0_meta_v1, p0_meta_v2, p0_meta_v3;
    logic [IDW-1:0]   p0_meta_rid1, p0_meta_rid2, p0_meta_rid3;
    logic            p0_meta_last1, p0_meta_last2, p0_meta_last3;

    rd_item_t                 p0_rd_fifo [0:RD_FIFO_DEPTH-1];
    logic [RD_PTR_W-1:0]      p0_rd_wptr, p0_rd_rptr;
    logic [RD_CNT_W-1:0]      p0_rd_count;

    logic                     p0_rd_fifo_full, p0_rd_fifo_empty;
    logic [RD_CNT_W-1:0]      p0_rd_fifo_free;

    assign p0_rd_fifo_full  = (p0_rd_count == RD_FIFO_DEPTH[RD_CNT_W-1:0]);
    assign p0_rd_fifo_empty = (p0_rd_count == '0);
    assign p0_rd_fifo_free  = RD_FIFO_DEPTH[RD_CNT_W-1:0] - p0_rd_count;

    logic [DATA_WIDTH-1:0] p0_rdata;
    assign axi0_if.rdata  = p0_rdata;
    assign axi0_if.rvalid = !p0_rd_fifo_empty;
    assign axi0_if.rresp  = 2'b00;
    assign axi0_if.rid    = p0_rd_fifo[p0_rd_rptr].rid;
    assign axi0_if.rlast  = p0_rd_fifo[p0_rd_rptr].last;

    always_comb begin
        p0_rdata = p0_rd_fifo[p0_rd_rptr].data;
    end

    // ============================================================
    // PORT1 (core_clk) : READ path (unchanged)
    // ============================================================
    logic [IDW-1:0]        p1_arid;
    logic [ADDR_WIDTH-1:0] p1_araddr;
    logic [7:0]            p1_arlen;
    logic [2:0]            p1_arsize;
    logic [1:0]            p1_arburst;
    logic                  p1_ar_active;

    int unsigned           p1_issue_idx;
    int unsigned           p1_total_beats;

    logic                  p1_rd_issue;
    logic [ADDR_WIDTH-1:0] p1_rd_addr;

    logic [DATA_WIDTH-1:0] p1_rd_q1, p1_rd_q2;

    logic            p1_meta_v1, p1_meta_v2, p1_meta_v3;
    logic [IDW-1:0]   p1_meta_rid1, p1_meta_rid2, p1_meta_rid3;
    logic            p1_meta_last1, p1_meta_last2, p1_meta_last3;

    rd_item_t                 p1_rd_fifo [0:RD_FIFO_DEPTH-1];
    logic [RD_PTR_W-1:0]      p1_rd_wptr, p1_rd_rptr;
    logic [RD_CNT_W-1:0]      p1_rd_count;

    logic                     p1_rd_fifo_full, p1_rd_fifo_empty;
    logic [RD_CNT_W-1:0]      p1_rd_fifo_free;

    assign p1_rd_fifo_full  = (p1_rd_count == RD_FIFO_DEPTH[RD_CNT_W-1:0]);
    assign p1_rd_fifo_empty = (p1_rd_count == '0);
    assign p1_rd_fifo_free  = RD_FIFO_DEPTH[RD_CNT_W-1:0] - p1_rd_count;

    logic [DATA_WIDTH-1:0] p1_rdata;
    assign axi1_if.rdata  = p1_rdata;
    assign axi1_if.rvalid = !p1_rd_fifo_empty;
    assign axi1_if.rresp  = 2'b00;
    assign axi1_if.rid    = p1_rd_fifo[p1_rd_rptr].rid;
    assign axi1_if.rlast  = p1_rd_fifo[p1_rd_rptr].last;

    always_comb begin
        p1_rdata = p1_rd_fifo[p1_rd_rptr].data;
    end

    // ============================================================
    // Port0 FSM (dma_clk): AW FIFO + active burst + W + B FIFO + AR/read issue
    // ============================================================
    always_ff @(posedge dma_clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin
            // AW/B defaults
            axi0_if.awready <= 1'b0;

            // B output regs
            p0_b_out_valid  <= 1'b0;
            p0_b_out        <= '0;
            axi0_if.bvalid  <= 1'b0;
            axi0_if.bresp   <= 2'b00;
            axi0_if.bid     <= '0;

            axi0_if.arready <= 1'b1;

            // write state
            p0_aw_active <= 1'b0;
            p0_wbeat_cnt <= 0;

            // aw fifo
            p0_aw_wptr  <= '0;
            p0_aw_rptr  <= '0;
            p0_aw_count <= '0;

            // b fifo
            p0_b_wptr   <= '0;
            p0_b_rptr   <= '0;
            p0_b_count  <= '0;

            // mem req
            p0_wr_req       <= 1'b0;
            p0_wr_byte_addr <= '0;
            p0_wr_wdata     <= '0;
            p0_wr_wstrb     <= '0;
            p0_wr_size      <= '0;
            p0_wr_is_last   <= 1'b0;

            // read state
            p0_ar_active   <= 1'b0;
            p0_issue_idx   <= 0;
            p0_total_beats <= 0;

            p0_rd_issue <= 1'b0;
            p0_rd_addr  <= '0;

            p0_meta_v1    <= 1'b0; p0_meta_v2    <= 1'b0; p0_meta_v3    <= 1'b0;
            p0_meta_rid1  <= '0;   p0_meta_rid2  <= '0;   p0_meta_rid3  <= '0;
            p0_meta_last1 <= 1'b0; p0_meta_last2 <= 1'b0; p0_meta_last3 <= 1'b0;

            p0_rd_wptr  <= '0;
            p0_rd_rptr  <= '0;
            p0_rd_count <= '0;

        end else begin
            // ------------------------------------------------------------
            // WRITE: AWREADY from AW FIFO space + B FIFO "credit reservation"
            //
            // Each accepted AW will eventually generate exactly one B.
            // To prevent B FIFO overflow at completion time, reserve a slot
            // per outstanding/queued/in-flight write burst:
            //   reserved = aw_count + (aw_active ? 1 : 0)
            // and ensure:
            //   b_count + reserved < WR_B_DEPTH
            // ------------------------------------------------------------
            begin
                int unsigned reserved;
                reserved = int'(p0_aw_count)
                        + (p0_aw_active ? 1 : 0)
                        + (p0_b_out_valid ? 1 : 0);

                axi0_if.awready <= (!p0_aw_full) &&
                                ((int'(p0_b_count) + reserved) < WR_B_DEPTH);
            end

            // ------------------------------------------------------------
            // WRITE: AW push into FIFO
            // ------------------------------------------------------------
            if (axi0_if.awvalid && axi0_if.awready) begin
                // (awready already guarantees !p0_aw_full and B credit)
                p0_aw_fifo[p0_aw_wptr].id    <= axi0_if.awid;
                p0_aw_fifo[p0_aw_wptr].addr  <= axi0_if.awaddr;
                p0_aw_fifo[p0_aw_wptr].len   <= axi0_if.awlen;
                p0_aw_fifo[p0_aw_wptr].size  <= axi0_if.awsize;
                p0_aw_fifo[p0_aw_wptr].burst <= axi0_if.awburst;

                p0_aw_wptr  <= p0_aw_wptr + 1'b1;
                p0_aw_count <= p0_aw_count + 1'b1;

                `ifndef SYNTHESIS
                    if (axi0_if.awsize > $clog2(BYTE_PER_WORD)) begin
                        $error("%0t: [axi_mm_dual_port_bram] p0 AW size (%0d) > max (%0d).",
                               $time, axi0_if.awsize, $clog2(BYTE_PER_WORD));
                    end
                `endif
            end

            // ------------------------------------------------------------
            // WRITE: load next active burst from FIFO head
            // ------------------------------------------------------------
            if (!p0_aw_active && !p0_aw_empty) begin
                p0_awid    <= p0_aw_fifo[p0_aw_rptr].id;
                p0_awaddr  <= p0_aw_fifo[p0_aw_rptr].addr;
                p0_awlen   <= p0_aw_fifo[p0_aw_rptr].len;
                p0_awsize  <= p0_aw_fifo[p0_aw_rptr].size;
                p0_awburst <= p0_aw_fifo[p0_aw_rptr].burst;

                p0_aw_active <= 1'b1;
                p0_wbeat_cnt <= 0;

                // pop AW
                p0_aw_rptr  <= p0_aw_rptr + 1'b1;
                p0_aw_count <= p0_aw_count - 1'b1;
            end

            // ------------------------------------------------------------
            // WRITE: enqueue one beat to mem_core
            // ------------------------------------------------------------
            if (p0_aw_active && p0_w_hs) begin
                logic [ADDR_WIDTH-1:0] beat_addr;
                logic                  is_last_calc;

                is_last_calc = (p0_wbeat_cnt == p0_awlen);

                if      (p0_awburst == 2'b10) beat_addr = compute_wrap_addr(p0_awaddr, p0_awsize, p0_awlen, p0_wbeat_cnt);
                else if (p0_awburst == 2'b01) beat_addr = compute_incr_addr(p0_awaddr, p0_awsize, p0_wbeat_cnt);
                else                          beat_addr = p0_awaddr;

                p0_wr_req       <= 1'b1;
                p0_wr_byte_addr <= beat_addr;
                p0_wr_wdata     <= axi0_if.wdata;
                p0_wr_wstrb     <= axi0_if.wstrb;
                p0_wr_size      <= p0_awsize;
                p0_wr_is_last   <= is_last_calc;

                p0_wbeat_cnt <= p0_wbeat_cnt + 1;

                // On last beat, push a B response into B FIFO
                if (is_last_calc) begin
                    // This must not overflow due to AWREADY credit gating.
                    if (!p0_b_full) begin
                        p0_b_fifo[p0_b_wptr].bid   <= p0_awid;
                        p0_b_fifo[p0_b_wptr].bresp <= 2'b00;

                        p0_b_wptr  <= p0_b_wptr + 1'b1;
                        p0_b_count <= p0_b_count + 1'b1;
                    end else begin
                        `ifndef SYNTHESIS
                            $error("%0t: [axi_mm_dual_port_bram] p0 B fifo overflow (should be prevented by AWREADY gating)", $time);
                        `endif
                    end
                    p0_aw_active <= 1'b0;
                end

                `ifndef SYNTHESIS
                    if (axi0_if.wlast !== is_last_calc) begin
                        $warning("%0t: [axi_mm_dual_port_bram] p0 WLAST inconsistent: wlast=%0b exp=%0b (beat=%0d awlen=%0d addr=0x%0h)",
                                 $time, axi0_if.wlast, is_last_calc, p0_wbeat_cnt, p0_awlen, beat_addr);
                    end
                `endif
            end

            if (p0_wr_req && p0_wr_consumed) begin
                p0_wr_req <= 1'b0;
            end

            // ------------------------------------------------------------
            // WRITE: B channel (registered, AXI-friendly)  [FIXED]
            // Invariant: p0_b_out_valid implies p0_b_count > 0 and
            //            p0_b_out mirrors p0_b_fifo[p0_b_rptr].
            // We only pop FIFO on B handshake.
            // ------------------------------------------------------------
            begin
                logic hs;
                hs = p0_b_out_valid && axi0_if.bready;

                // If output is not valid, try to load current head (if any)
                if (!p0_b_out_valid) begin
                    if (!p0_b_empty) begin
                        p0_b_out       <= p0_b_fifo[p0_b_rptr];
                        p0_b_out_valid <= 1'b1;
                    end else begin
                        p0_b_out       <= '0;
                        p0_b_out_valid <= 1'b0;
                    end
                end
                // If handshake, consume current head and advance
                else if (hs) begin
                    // pop current head
                    p0_b_rptr  <= p0_b_rptr + 1'b1;
                    p0_b_count <= p0_b_count - 1'b1;

                    // If there will still be an entry after pop, load next head now
                    if (p0_b_count > 1) begin
                        p0_b_out       <= p0_b_fifo[p0_b_rptr + 1'b1];
                        p0_b_out_valid <= 1'b1;
                    end else begin
                        // p0_b_count == 1 -> becomes empty after pop
                        p0_b_out       <= '0;
                        p0_b_out_valid <= 1'b0;
                    end
                end

                // Drive interface outputs from output regs
                axi0_if.bvalid <= p0_b_out_valid;
                axi0_if.bid    <= p0_b_out.bid;
                axi0_if.bresp  <= p0_b_out.bresp;

            `ifndef SYNTHESIS
                // Helpful invariant check
                if (p0_b_out_valid && (p0_b_count == 0)) begin
                    $error("%0t: [axi_mm_dual_port_bram] p0 invariant violated: b_out_valid=1 but b_count=0", $time);
                end
            `endif
            end

            // -------------------------
            // READ: AR accept gating (avoid fifo overflow) (unchanged)
            // -------------------------
            if (!p0_ar_active) begin
                if (axi0_if.arvalid) begin
                    int unsigned need;
                    need = int'(axi0_if.arlen) + 1;
                    if (p0_rd_fifo_free >= need[RD_CNT_W-1:0]) begin
                        axi0_if.arready <= 1'b1;
                    end else begin
                        axi0_if.arready <= 1'b0;
                    end
                end else begin
                    axi0_if.arready <= 1'b1;
                end
            end else begin
                axi0_if.arready <= 1'b0;
            end

            if (axi0_if.arready && axi0_if.arvalid) begin
                p0_arid    <= axi0_if.arid;
                p0_araddr  <= axi0_if.araddr;
                p0_arlen   <= axi0_if.arlen;
                p0_arsize  <= axi0_if.arsize;
                p0_arburst <= axi0_if.arburst;

                p0_ar_active   <= 1'b1;
                p0_issue_idx   <= 0;
                p0_total_beats <= int'(axi0_if.arlen) + 1;

                p0_meta_v1 <= 1'b0;
                p0_meta_v2 <= 1'b0;
                p0_meta_v3 <= 1'b0;
            end

            // -------------------------
            // READ: issue one beat per cycle (unchanged)
            // -------------------------
            p0_rd_issue <= 1'b0;

            if (p0_ar_active) begin
                if (p0_issue_idx < p0_total_beats) begin
                    logic [ADDR_WIDTH-1:0] beat_addr;

                    if      (p0_arburst == 2'b10) beat_addr = compute_wrap_addr(p0_araddr, p0_arsize, p0_arlen, p0_issue_idx);
                    else if (p0_arburst == 2'b01) beat_addr = compute_incr_addr(p0_araddr, p0_arsize, p0_issue_idx);
                    else                          beat_addr = p0_araddr;

                    p0_rd_issue <= 1'b1;
                    p0_rd_addr  <= beat_addr;

                    p0_meta_v1    <= 1'b1;
                    p0_meta_rid1  <= p0_arid;
                    p0_meta_last1 <= (p0_issue_idx == (p0_total_beats-1));

                    p0_issue_idx <= p0_issue_idx + 1;
                end else begin
                    p0_meta_v1 <= 1'b0;
                end
            end else begin
                p0_meta_v1 <= 1'b0;
            end

            p0_meta_v3    <= p0_meta_v2;
            p0_meta_rid3  <= p0_meta_rid2;
            p0_meta_last3 <= p0_meta_last2;

            p0_meta_v2    <= p0_meta_v1;
            p0_meta_rid2  <= p0_meta_rid1;
            p0_meta_last2 <= p0_meta_last1;

            // FIFO push/pop count fix (unchanged)
            begin
                logic p0_push, p0_pop;

                p0_push = p0_meta_v3 && !p0_rd_fifo_full;
                p0_pop  = (axi0_if.rvalid && axi0_if.rready);

                if (p0_push) begin
                    p0_rd_fifo[p0_rd_wptr].rid  <= p0_meta_rid3;
                    p0_rd_fifo[p0_rd_wptr].last <= p0_meta_last3;
                    p0_rd_fifo[p0_rd_wptr].data <= p0_rd_q2;
                    p0_rd_wptr <= p0_rd_wptr + 1'b1;
                end else if (p0_meta_v3 && p0_rd_fifo_full) begin
                    `ifndef SYNTHESIS
                        $error("%0t: [axi_mm_dual_port_bram] p0 read fifo overflow", $time);
                    `endif
                end

                if (p0_pop) begin
                    if (p0_rd_fifo[p0_rd_rptr].last) begin
                        p0_ar_active <= 1'b0;
                    end
                    p0_rd_rptr <= p0_rd_rptr + 1'b1;
                end

                unique case ({p0_push, p0_pop})
                    2'b10: p0_rd_count <= p0_rd_count + 1'b1;
                    2'b01: p0_rd_count <= p0_rd_count - 1'b1;
                    default: p0_rd_count <= p0_rd_count;
                endcase
            end
        end
    end

    // ============================================================
    // Port1 FSM (core_clk): AW FIFO + active burst + W staging + B FIFO + AR/read issue
    // ============================================================
    always_ff @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            axi1_if.awready <= 1'b0;

            // B output regs
            p1_b_out_valid  <= 1'b0;
            p1_b_out        <= '0;
            axi1_if.bvalid  <= 1'b0;
            axi1_if.bresp   <= 2'b00;
            axi1_if.bid     <= '0;

            axi1_if.arready <= 1'b1;

            // write state
            p1_aw_active      <= 1'b0;
            p1_wbeat_cnt      <= 0;
            p1_local_wr_valid <= 1'b0;

            // aw fifo
            p1_aw_wptr  <= '0;
            p1_aw_rptr  <= '0;
            p1_aw_count <= '0;

            // b fifo
            p1_b_wptr   <= '0;
            p1_b_rptr   <= '0;
            p1_b_count  <= '0;

            p1_req_toggle_core <= 1'b0;
            p1_req_outstanding <= 1'b0;

            bridge_p1_addr_core    <= '0;
            bridge_p1_wdata_core   <= '0;
            bridge_p1_wstrb_core   <= '0;
            bridge_p1_size_core    <= '0;
            bridge_p1_is_last_core <= 1'b0;

            p1_ack_toggle_sync1_core     <= 1'b0;
            p1_ack_toggle_sync2_core     <= 1'b0;
            p1_ack_toggle_last_seen_core <= 1'b0;

            p1_sent_is_last <= 1'b0;
            p1_sent_awid    <= '0;

            // read state
            p1_ar_active   <= 1'b0;
            p1_issue_idx   <= 0;
            p1_total_beats <= 0;

            p1_rd_issue <= 1'b0;
            p1_rd_addr  <= '0;

            p1_meta_v1    <= 1'b0; p1_meta_v2    <= 1'b0; p1_meta_v3    <= 1'b0;
            p1_meta_rid1  <= '0;   p1_meta_rid2  <= '0;   p1_meta_rid3  <= '0;
            p1_meta_last1 <= 1'b0; p1_meta_last2 <= 1'b0; p1_meta_last3 <= 1'b0;

            p1_rd_wptr  <= '0;
            p1_rd_rptr  <= '0;
            p1_rd_count <= '0;

        end else begin
            // -------------------------
            // Sync ACK toggle from DMA domain (double flop)
            // -------------------------
            p1_ack_toggle_sync1_core <= p1_ack_toggle_dma;
            p1_ack_toggle_sync2_core <= p1_ack_toggle_sync1_core;

            // ------------------------------------------------------------
            // WRITE: AWREADY from AW FIFO space + B FIFO credit reservation
            // ------------------------------------------------------------
            begin
                int unsigned reserved;
                reserved = int'(p1_aw_count)
                        + (p1_aw_active ? 1 : 0)
                        + (p1_b_out_valid ? 1 : 0);

                axi1_if.awready <= (!p1_aw_full) &&
                                ((int'(p1_b_count) + reserved) < WR_B_DEPTH);
            end

            // -------------------------
            // WRITE: AW push into FIFO
            // -------------------------
            if (axi1_if.awvalid && axi1_if.awready) begin
                p1_aw_fifo[p1_aw_wptr].id    <= axi1_if.awid;
                p1_aw_fifo[p1_aw_wptr].addr  <= axi1_if.awaddr;
                p1_aw_fifo[p1_aw_wptr].len   <= axi1_if.awlen;
                p1_aw_fifo[p1_aw_wptr].size  <= axi1_if.awsize;
                p1_aw_fifo[p1_aw_wptr].burst <= axi1_if.awburst;

                p1_aw_wptr  <= p1_aw_wptr + 1'b1;
                p1_aw_count <= p1_aw_count + 1'b1;

                `ifndef SYNTHESIS
                    if (axi1_if.awsize > $clog2(BYTE_PER_WORD)) begin
                        $error("%0t: [axi_mm_dual_port_bram] p1 AW size (%0d) > max (%0d).",
                               $time, axi1_if.awsize, $clog2(BYTE_PER_WORD));
                    end
                `endif
            end

            // -------------------------
            // WRITE: load next active burst from FIFO head
            // -------------------------
            if (!p1_aw_active && !p1_aw_empty) begin
                p1_awid    <= p1_aw_fifo[p1_aw_rptr].id;
                p1_awaddr  <= p1_aw_fifo[p1_aw_rptr].addr;
                p1_awlen   <= p1_aw_fifo[p1_aw_rptr].len;
                p1_awsize  <= p1_aw_fifo[p1_aw_rptr].size;
                p1_awburst <= p1_aw_fifo[p1_aw_rptr].burst;

                p1_aw_active <= 1'b1;
                p1_wbeat_cnt <= 0;

                // pop AW
                p1_aw_rptr  <= p1_aw_rptr + 1'b1;
                p1_aw_count <= p1_aw_count - 1'b1;
            end

            // -------------------------
            // WRITE: capture one W beat into local buffer
            // -------------------------
            if (p1_aw_active && p1_w_hs) begin
                logic [ADDR_WIDTH-1:0] beat_addr;
                logic                  is_last_calc;

                is_last_calc = (p1_wbeat_cnt == p1_awlen);

                if      (p1_awburst == 2'b10) beat_addr = compute_wrap_addr(p1_awaddr, p1_awsize, p1_awlen, p1_wbeat_cnt);
                else if (p1_awburst == 2'b01) beat_addr = compute_incr_addr(p1_awaddr, p1_awsize, p1_wbeat_cnt);
                else                          beat_addr = p1_awaddr;

                p1_local_wr_byte_addr <= beat_addr;
                p1_local_wr_wdata     <= axi1_if.wdata;
                p1_local_wr_wstrb     <= axi1_if.wstrb;
                p1_local_wr_size      <= p1_awsize;
                p1_local_wr_is_last   <= is_last_calc;
                p1_local_wr_valid     <= 1'b1;

                p1_wbeat_cnt <= p1_wbeat_cnt + 1;

                `ifndef SYNTHESIS
                    if (axi1_if.wlast !== is_last_calc) begin
                        $warning("%0t: [axi_mm_dual_port_bram] p1 WLAST inconsistent: wlast=%0b exp=%0b (beat=%0d awlen=%0d addr=0x%0h)",
                                 $time, axi1_if.wlast, is_last_calc, p1_wbeat_cnt, p1_awlen, beat_addr);
                    end
                `endif
            end

            // -------------------------
            // WRITE: launch bridge transfer (one-shot)
            // -------------------------
            if (p1_local_wr_valid &&
                !p1_req_outstanding &&
                (p1_req_toggle_core == p1_ack_toggle_sync2_core)) begin

                bridge_p1_addr_core    <= p1_local_wr_byte_addr;
                bridge_p1_wdata_core   <= p1_local_wr_wdata;
                bridge_p1_wstrb_core   <= p1_local_wr_wstrb;
                bridge_p1_is_last_core <= p1_local_wr_is_last;
                bridge_p1_size_core    <= p1_local_wr_size;

                p1_sent_is_last <= p1_local_wr_is_last;
                p1_sent_awid    <= p1_awid;

                p1_req_toggle_core <= ~p1_req_toggle_core;
                p1_req_outstanding <= 1'b1;
            end

            // -------------------------
            // WRITE: ACK edge => DMA latched payload
            // -------------------------
            if (p1_ack_toggle_sync2_core != p1_ack_toggle_last_seen_core) begin
                p1_ack_toggle_last_seen_core <= p1_ack_toggle_sync2_core;

                p1_req_outstanding <= 1'b0;
                p1_local_wr_valid  <= 1'b0;

                if (p1_sent_is_last) begin
                    // Push B response into B FIFO
                    // This must not overflow due to AWREADY credit gating.
                    if (!p1_b_full) begin
                        p1_b_fifo[p1_b_wptr].bid   <= p1_sent_awid;
                        p1_b_fifo[p1_b_wptr].bresp <= 2'b00;

                        p1_b_wptr  <= p1_b_wptr + 1'b1;
                        p1_b_count <= p1_b_count + 1'b1;
                    end else begin
                        `ifndef SYNTHESIS
                            $error("%0t: [axi_mm_dual_port_bram] p1 B fifo overflow (should be prevented by AWREADY gating)", $time);
                        `endif
                    end
                    p1_aw_active <= 1'b0;
                end
            end

            // ------------------------------------------------------------
            // WRITE: B channel (registered, AXI-friendly)  [FIXED]
            // Invariant: p1_b_out_valid implies p1_b_count > 0 and
            //            p1_b_out mirrors p1_b_fifo[p1_b_rptr].
            // ------------------------------------------------------------
            begin
                logic hs;
                hs = p1_b_out_valid && axi1_if.bready;

                if (!p1_b_out_valid) begin
                    if (!p1_b_empty) begin
                        p1_b_out       <= p1_b_fifo[p1_b_rptr];
                        p1_b_out_valid <= 1'b1;
                    end else begin
                        p1_b_out       <= '0;
                        p1_b_out_valid <= 1'b0;
                    end
                end
                else if (hs) begin
                    p1_b_rptr  <= p1_b_rptr + 1'b1;
                    p1_b_count <= p1_b_count - 1'b1;

                    if (p1_b_count > 1) begin
                        p1_b_out       <= p1_b_fifo[p1_b_rptr + 1'b1];
                        p1_b_out_valid <= 1'b1;
                    end else begin
                        p1_b_out       <= '0;
                        p1_b_out_valid <= 1'b0;
                    end
                end

                axi1_if.bvalid <= p1_b_out_valid;
                axi1_if.bid    <= p1_b_out.bid;
                axi1_if.bresp  <= p1_b_out.bresp;

            `ifndef SYNTHESIS
                if (p1_b_out_valid && (p1_b_count == 0)) begin
                    $error("%0t: [axi_mm_dual_port_bram] p1 invariant violated: b_out_valid=1 but b_count=0", $time);
                end
            `endif
            end


            // -------------------------
            // READ: AR accept gating (unchanged)
            // -------------------------
            if (!p1_ar_active) begin
                if (axi1_if.arvalid) begin
                    int unsigned need;
                    need = int'(axi1_if.arlen) + 1;
                    if (p1_rd_fifo_free >= need[RD_CNT_W-1:0]) begin
                        axi1_if.arready <= 1'b1;
                    end else begin
                        axi1_if.arready <= 1'b0;
                    end
                end else begin
                    axi1_if.arready <= 1'b1;
                end
            end else begin
                axi1_if.arready <= 1'b0;
            end

            if (axi1_if.arready && axi1_if.arvalid) begin
                p1_arid    <= axi1_if.arid;
                p1_araddr  <= axi1_if.araddr;
                p1_arlen   <= axi1_if.arlen;
                p1_arsize  <= axi1_if.arsize;
                p1_arburst <= axi1_if.arburst;

                p1_ar_active   <= 1'b1;
                p1_issue_idx   <= 0;
                p1_total_beats <= int'(axi1_if.arlen) + 1;

                p1_meta_v1 <= 1'b0;
                p1_meta_v2 <= 1'b0;
                p1_meta_v3 <= 1'b0;
            end

            // -------------------------
            // READ: issue one beat per cycle (unchanged)
            // -------------------------
            p1_rd_issue <= 1'b0;

            if (p1_ar_active) begin
                if (p1_issue_idx < p1_total_beats) begin
                    logic [ADDR_WIDTH-1:0] beat_addr;

                    if      (p1_arburst == 2'b10) beat_addr = compute_wrap_addr(p1_araddr, p1_arsize, p1_arlen, p1_issue_idx);
                    else if (p1_arburst == 2'b01) beat_addr = compute_incr_addr(p1_araddr, p1_arsize, p1_issue_idx);
                    else                          beat_addr = p1_araddr;

                    p1_rd_issue <= 1'b1;
                    p1_rd_addr  <= beat_addr;

                    p1_meta_v1    <= 1'b1;
                    p1_meta_rid1  <= p1_arid;
                    p1_meta_last1 <= (p1_issue_idx == (p1_total_beats-1));

                    p1_issue_idx <= p1_issue_idx + 1;
                end else begin
                    p1_meta_v1 <= 1'b0;
                end
            end else begin
                p1_meta_v1 <= 1'b0;
            end

            p1_meta_v3    <= p1_meta_v2;
            p1_meta_rid3  <= p1_meta_rid2;
            p1_meta_last3 <= p1_meta_last2;

            p1_meta_v2    <= p1_meta_v1;
            p1_meta_rid2  <= p1_meta_rid1;
            p1_meta_last2 <= p1_meta_last1;

            begin
                logic p1_push, p1_pop;

                p1_push = p1_meta_v3 && !p1_rd_fifo_full;
                p1_pop  = (axi1_if.rvalid && axi1_if.rready);

                if (p1_push) begin
                    p1_rd_fifo[p1_rd_wptr].rid  <= p1_meta_rid3;
                    p1_rd_fifo[p1_rd_wptr].last <= p1_meta_last3;
                    p1_rd_fifo[p1_rd_wptr].data <= p1_rd_q2;

                    p1_rd_wptr <= p1_rd_wptr + 1'b1;
                end else if (p1_meta_v3 && p1_rd_fifo_full) begin
                    `ifndef SYNTHESIS
                        $error("%0t: [axi_mm_dual_port_bram] p1 read fifo overflow", $time);
                    `endif
                end

                if (p1_pop) begin
                    if (p1_rd_fifo[p1_rd_rptr].last) begin
                        p1_ar_active <= 1'b0;
                    end
                    p1_rd_rptr <= p1_rd_rptr + 1'b1;
                end

                unique case ({p1_push, p1_pop})
                    2'b10: p1_rd_count <= p1_rd_count + 1'b1;
                    2'b01: p1_rd_count <= p1_rd_count - 1'b1;
                    default: p1_rd_count <= p1_rd_count;
                endcase
            end
        end
    end

    // ============================================================
    // Sync: p1_req_toggle into dma_clk + stage payload + ack toggle (unchanged)
    // ============================================================
    always_ff @(posedge dma_clk or negedge dma_rst_n) begin
        logic stage_free;
        if (!dma_rst_n) begin
            p1_req_toggle_sync1_dma     <= 1'b0;
            p1_req_toggle_sync2_dma     <= 1'b0;
            p1_req_toggle_last_seen_dma <= 1'b0;

            staged_p1_valid_dma   <= 1'b0;
            staged_p1_addr_dma    <= '0;
            staged_p1_wdata_dma   <= '0;
            staged_p1_wstrb_dma   <= '0;
            staged_p1_size_dma    <= '0;
            staged_p1_is_last_dma <= 1'b0;

            p1_ack_toggle_dma <= 1'b0;
        end else begin
            p1_req_toggle_sync1_dma <= p1_req_toggle_core;
            p1_req_toggle_sync2_dma <= p1_req_toggle_sync1_dma;

            stage_free = (!staged_p1_valid_dma) || (staged_p1_valid_dma && staged_p1_consumed);

            if (staged_p1_valid_dma && staged_p1_consumed) begin
                staged_p1_valid_dma <= 1'b0;
            end

            if (stage_free &&
                (p1_req_toggle_sync2_dma != p1_req_toggle_last_seen_dma)) begin

                staged_p1_addr_dma    <= bridge_p1_addr_core;
                staged_p1_wdata_dma   <= bridge_p1_wdata_core;
                staged_p1_wstrb_dma   <= bridge_p1_wstrb_core;
                staged_p1_size_dma    <= bridge_p1_size_core;
                staged_p1_is_last_dma <= bridge_p1_is_last_core;

                staged_p1_valid_dma <= 1'b1;

                p1_req_toggle_last_seen_dma <= p1_req_toggle_sync2_dma;
                p1_ack_toggle_dma <= ~p1_ack_toggle_dma;
            end
        end
    end

    // ============================================================
    // BRAM READ pipelines (READ_FIRST) - 2-cycle latency (unchanged)
    // ============================================================
    always_ff @(posedge dma_clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin
            p0_rd_q1 <= '0;
            p0_rd_q2 <= '0;
        end else begin
            if (p0_rd_issue) begin
                p0_rd_q1 <= mem_word[word_index(p0_rd_addr)];
            end
            p0_rd_q2 <= p0_rd_q1;
        end
    end

    always_ff @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            p1_rd_q1 <= '0;
            p1_rd_q2 <= '0;
        end else begin
            if (p1_rd_issue) begin
                p1_rd_q1 <= mem_word[word_index(p1_rd_addr)];
            end
            p1_rd_q2 <= p1_rd_q1;
        end
    end

    // ============================================================
    // Memory Core (dma_clk): single writer to mem_word[]
    // ============================================================
    logic p0_block_until_deassert;
    logic p1_block_until_deassert;

    logic [31:0] staged_p1_starve_cnt;
    logic        staged_p1_starve_asserted;

    always_ff @(posedge dma_clk or negedge dma_rst_n) begin : mem_core
        if (!dma_rst_n) begin
            p0_wr_consumed     <= 1'b0;
            staged_p1_consumed <= 1'b0;

            p0_block_until_deassert <= 1'b0;
            p1_block_until_deassert <= 1'b0;

            staged_p1_starve_cnt      <= 32'd0;
            staged_p1_starve_asserted <= 1'b0;

        end else begin
            p0_wr_consumed     <= 1'b0;
            staged_p1_consumed <= 1'b0;

            if (!p0_wr_req)           p0_block_until_deassert <= 1'b0;
            if (!staged_p1_valid_dma) p1_block_until_deassert <= 1'b0;

            if (p0_wr_req && !p0_block_until_deassert) begin
                int unsigned wi;
                int unsigned off;
                int unsigned bytes;
                logic [DATA_WIDTH-1:0] cur;
                int unsigned b;
                int unsigned lane;

                p0_wr_consumed          <= 1'b1;
                p0_block_until_deassert <= 1'b1;

                wi    = word_index(p0_wr_byte_addr);
                off   = (p0_wr_byte_addr % BYTE_PER_WORD);
                bytes = size_to_bytes(p0_wr_size);

                cur = mem_word[wi];

                for (b = 0; b < bytes; b++) begin
                    lane = (off + b) % BYTE_PER_WORD;
                    if (p0_wr_wstrb[lane]) begin
                        cur[8*lane +: 8] = p0_wr_wdata[8*lane +: 8];
                    end
                end

                mem_word[wi] <= cur;

                if (staged_p1_valid_dma) begin
                    if (staged_p1_starve_cnt < 32'hFFFF_FFFF)
                        staged_p1_starve_cnt <= staged_p1_starve_cnt + 1;
                end else begin
                    staged_p1_starve_cnt <= 32'd0;
                end

            end else if (staged_p1_valid_dma && !p1_block_until_deassert) begin
                int unsigned wi;
                int unsigned off;
                int unsigned bytes;
                logic [DATA_WIDTH-1:0] cur;
                int unsigned b;
                int unsigned lane;

                staged_p1_consumed      <= 1'b1;
                p1_block_until_deassert <= 1'b1;

                wi    = word_index(staged_p1_addr_dma);
                off   = (staged_p1_addr_dma % BYTE_PER_WORD);
                bytes = size_to_bytes(staged_p1_size_dma);

                cur = mem_word[wi];

                for (b = 0; b < bytes; b++) begin
                    lane = (off + b) % BYTE_PER_WORD;
                    if (staged_p1_wstrb_dma[lane]) begin
                        cur[8*lane +: 8] = staged_p1_wdata_dma[8*lane +: 8];
                    end
                end

                mem_word[wi] <= cur;

                staged_p1_starve_cnt <= 32'd0;

            end else begin
                staged_p1_starve_cnt <= 32'd0;
            end

            if (ASSERT_ON_STARVE && (staged_p1_starve_cnt >= STARVE_THRESHOLD)) begin
                if (!staged_p1_starve_asserted) begin
                    staged_p1_starve_asserted <= 1'b1;
                    `ifndef SYNTHESIS
                        $warning("%0t: [axi_mm_dual_port_bram] staged_p1 starvation detected: cnt=%0d threshold=%0d",
                                 $time, staged_p1_starve_cnt, STARVE_THRESHOLD);
                    `endif
                end
            end
        end
    end

endmodule
