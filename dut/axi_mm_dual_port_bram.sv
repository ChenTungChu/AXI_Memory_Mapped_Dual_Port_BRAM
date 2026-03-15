// File: axi_mm_dual_port_bram.sv
// Behavioral Multi-clock Dual-port AXI4-MM scratchpad (READ_FIRST)
//
// Intent / positioning:
// - This is a verification-oriented behavioral memory model (not a vendor BRAM macro).
// - Two independent AXI4-MM slave ports share one behavioral storage array.
// - The design emphasizes deterministic, burst-level "commit" semantics suitable for scoreboards.
//
// IMPORTANT BEHAVIOR (aligned with atomic-at-B / atomic-at-commit scoreboards):
// - W beats are buffered per burst (writes are NOT applied beat-by-beat into mem_word[]).
// - A single commit engine (dma_clk domain) commits ONE burst at a time.
//   * Memory update is atomic per burst (the mem_word[] image changes at burst commit boundary).
//   * Commits from Port0/Port1 are serialized by the commit engine (no partial interleaving in memory update).
// - Apply / commit observation:
//   * After mem_word[] is updated, apply_if emits the applied beats (handshaked).
//   * Then commit_if emits the committed beats (handshaked).
// - Write response timing:
//   * Port0: B is enqueued only after commit_if emission completes.
//   * Port1: the last-beat ACK back to core_clk is deferred until commit+emit completes; core-side B is then generated.
//
// Clocking / domains:
// - Port0 runs on dma_clk (AXI slave interface axi0_if).
// - Port1 runs on core_clk (AXI slave interface axi1_if).
// - Port1 W beats cross into dma_clk via a simple toggle-based request/ack bridge (beat-level transfer).
// - The shared storage is a single behavioral array updated only by the dma_clk commit engine.
//
// Verification note (scoreboard stabilization window):
// - This model is multi-clock (Port0: dma_clk, Port1: core_clk). To avoid race-condition
//   false failures in cross-domain checking, the UVM scoreboard uses a conservative
//   stabilization delay after a burst is considered committed.
// - Recommended scoreboard setting:
//     COMMIT_STABLE_DELAY = 30ns
// - This is a TESTBENCH constraint (verification convenience), not a hardware guarantee
//   and not a DUT parameter.
//
// Read path model:
// - Synchronous read model with 2-cycle latency (q1/q2 pipeline) and per-port read FIFO.
// - No read forwarding/bypass. Reads observe committed mem_word[] state only (READ_FIRST philosophy).
//
// Assumptions / scope (kept intentionally narrow for verification use):
// - Burst types:
//   * INCR and WRAP are supported.
//   * FIXED is supported as constant-address accesses (AW/AR burst != INCR/WRAP => addr held constant).
// - Responses:
//   * BRESP/RRESP are OKAY (2'b00) only.
// - Write ordering:
//   * W channel is assumed in-order with respect to the active AW (no W reordering across different AW).
// - No vendor-specific collision modes are modeled; this is not intended to infer a true dual-port BRAM macro.
//
// Endianness / lane mapping:
// - lane 0 = WDATA[7:0], lowest byte address in word.
// - WSTRB[0] controls lane 0, etc.

`timescale 1ns/1ps

module axi_mm_dual_port_bram #(
    parameter int ADDR_WIDTH       = 32,
    parameter int DATA_WIDTH       = 64,
    parameter int ID_WIDTH         = 4,
    parameter int DEPTH_WORDS      = 1024,

    // Read FIFO depth (per port)
    parameter int RD_FIFO_DEPTH    = 16,

    // Write outstanding depths (AW/B)
    parameter int WR_AW_DEPTH      = 2,
    parameter int WR_B_DEPTH       = 4,

    // Burst buffering / commit
    parameter int MAX_BURST_BEATS  = 256, // AWLEN is 8-bit => up to 256 beats

    // Burst-level weighted RR in commit engine (when both ports have a READY burst)
    parameter int P0_WEIGHT        = 4,
    parameter int STARVE_THRESHOLD = 2000,
    parameter bit ASSERT_ON_STARVE = 1,

    // Perf log (sim-only)
    parameter bit LOG_ENABLE           = 1,
    parameter int LOG_INTERVAL_CYCLES  = 10000
) (
    input  logic dma_clk,
    input  logic dma_rst_n,
    input  logic core_clk,
    input  logic core_rst_n,

    axi_mm_if axi0_if,
    axi_mm_if axi1_if,

    // Apply observation interface (dma_clk domain, 1 event per applied beat)
    axi_mm_apply_if.mp_producer  apply_if,

    // Commit observation interface (dma_clk domain, 1 event per committed beat)
    axi_mm_commit_if.mp_producer commit_if,

    output logic ce_idle
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

    localparam int BEAT_PTR_W    = (MAX_BURST_BEATS <= 1) ? 1 : $clog2(MAX_BURST_BEATS);

    longint unsigned perf_total_cycles;
    longint unsigned perf_busy_cycles;
    longint unsigned perf_bytes_written;
    longint unsigned perf_p0_bursts;
    longint unsigned perf_p1_bursts;

    // synthesis translate_off
    initial begin
        if ((DATA_WIDTH % 8) != 0) $error("DATA_WIDTH must be a multiple of 8");
        if (DEPTH_WORDS <= 0)      $error("DEPTH_WORDS must be > 0");
        if (RD_FIFO_DEPTH <= 0)    $error("RD_FIFO_DEPTH must be > 0");
        if (WR_AW_DEPTH <= 0)      $error("WR_AW_DEPTH must be > 0");
        if (WR_B_DEPTH  <= 0)      $error("WR_B_DEPTH must be > 0");
        if (P0_WEIGHT   <= 0)      $error("P0_WEIGHT must be > 0");
        if (MAX_BURST_BEATS <= 0)  $error("MAX_BURST_BEATS must be > 0");
        if (LOG_INTERVAL_CYCLES <= 0) $error("LOG_INTERVAL_CYCLES must be > 0");
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
        word_index = (byte_addr >> WORD_SHIFT) % DEPTH_WORDS;
    endfunction

    function automatic int unsigned count_written_bytes(
        input logic [ADDR_WIDTH-1:0]    byte_addr,
        input logic [2:0]               size,
        input logic [BYTE_PER_WORD-1:0] wstrb
    );
        int unsigned off;
        int unsigned bytes;
        int unsigned b;
        int unsigned lane;
        int unsigned cnt;
        begin
            off   = (byte_addr % BYTE_PER_WORD);
            bytes = size_to_bytes(size);
            cnt   = 0;
            for (b = 0; b < bytes; b++) begin
                lane = (off + b) % BYTE_PER_WORD;
                if (wstrb[lane]) cnt++;
            end
            return cnt;
        end
    endfunction

    task automatic perf_log_snapshot(string tag);
        longint unsigned util_pct;
        longint unsigned avg_bpc_x1000;
        begin
            util_pct = (perf_total_cycles == 0) ? 0 : ((perf_busy_cycles * 100) / perf_total_cycles);
            avg_bpc_x1000 = (perf_total_cycles == 0) ? 0 : ((perf_bytes_written * 1000) / perf_total_cycles);

            $display("%0t [axi_mm_dual_port_bram][%s] cycles=%0d busy=%0d util=%0d%% bytes=%0d avg=%0d.%03d B/cyc bursts(p0=%0d,p1=%0d) ready(p0=%0b,p1=%0b) state=%0d",
                    $time, tag,
                    perf_total_cycles, perf_busy_cycles, util_pct,
                    perf_bytes_written,
                    (avg_bpc_x1000/1000), (avg_bpc_x1000%1000),
                    perf_p0_bursts, perf_p1_bursts,
                    p0_burst_ready, p1_burst_ready, ce_state);
        end
    endtask

    // ------------------------------------------------------------
    // Memory array (behavioral BRAM)
    // ------------------------------------------------------------
    logic [DATA_WIDTH-1:0] mem_word [0:DEPTH_WORDS-1];

    // ------------------------------------------------------------
    // Types
    // ------------------------------------------------------------
    typedef struct packed {
        logic [IDW-1:0]         rid;
        logic                   last;
        logic [DATA_WIDTH-1:0]  data;
    } rd_item_t;

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

    typedef struct packed {
        logic [ADDR_WIDTH-1:0]    byte_addr;
        logic [DATA_WIDTH-1:0]    wdata;
        logic [BYTE_PER_WORD-1:0] wstrb;
        logic [2:0]               size;
    } wr_beat_t;

    // ============================================================
    // PORT0 (dma_clk) : WRITE path (AW FIFO + burst buffering + B FIFO)
    // ============================================================
    aw_item_t               p0_aw_fifo [0:WR_AW_DEPTH-1];
    logic [WR_AW_PTR_W-1:0] p0_aw_wptr, p0_aw_rptr;
    logic [WR_AW_CNT_W-1:0] p0_aw_count;
    logic                   p0_aw_full, p0_aw_empty;
    assign p0_aw_full  = (p0_aw_count == WR_AW_DEPTH[WR_AW_CNT_W-1:0]);
    assign p0_aw_empty = (p0_aw_count == '0);

    b_item_t                p0_b_fifo  [0:WR_B_DEPTH-1];
    logic [WR_B_PTR_W-1:0]  p0_b_wptr, p0_b_rptr;
    logic [WR_B_CNT_W-1:0]  p0_b_count;
    logic                   p0_b_full, p0_b_empty;
    assign p0_b_full  = (p0_b_count == WR_B_DEPTH[WR_B_CNT_W-1:0]);
    assign p0_b_empty = (p0_b_count == '0);

    logic     p0_b_out_valid;
    b_item_t  p0_b_out;

    // active AW (head)
    logic [IDW-1:0]        p0_awid;
    logic [ADDR_WIDTH-1:0] p0_awaddr;
    logic [7:0]            p0_awlen;
    logic [2:0]            p0_awsize;
    logic [1:0]            p0_awburst;
    logic                  p0_aw_active;
    int unsigned           p0_wbeat_cnt;

    // burst buffer (single in-flight burst per port)
    wr_beat_t              p0_buf [0:MAX_BURST_BEATS-1];
    int unsigned           p0_buf_beats_total;   // = awlen+1
    int unsigned           p0_buf_beats_written; // beats buffered so far
    logic                  p0_burst_ready;       // burst fully buffered, waiting to commit
    logic [IDW-1:0]        p0_burst_id;

    // W handshake
    logic p0_w_hs;

    // WREADY: only when aw_active and we are buffering current burst and not already "ready"
    assign axi0_if.wready = dma_rst_n
                         && p0_aw_active
                         && !p0_burst_ready
                         && (p0_buf_beats_written < p0_buf_beats_total)
                         && (p0_buf_beats_written < MAX_BURST_BEATS);
    assign p0_w_hs = axi0_if.wvalid && axi0_if.wready;

    // ============================================================
    // PORT1 (core_clk) : WRITE path (AW FIFO + local beat + bridge)
    // ============================================================
    aw_item_t               p1_aw_fifo [0:WR_AW_DEPTH-1];
    logic [WR_AW_PTR_W-1:0] p1_aw_wptr, p1_aw_rptr;
    logic [WR_AW_CNT_W-1:0] p1_aw_count;
    logic                   p1_aw_full, p1_aw_empty;
    assign p1_aw_full  = (p1_aw_count == WR_AW_DEPTH[WR_AW_CNT_W-1:0]);
    assign p1_aw_empty = (p1_aw_count == '0);

    b_item_t                p1_b_fifo  [0:WR_B_DEPTH-1];
    logic [WR_B_PTR_W-1:0]  p1_b_wptr, p1_b_rptr;
    logic [WR_B_CNT_W-1:0]  p1_b_count;
    logic                   p1_b_full, p1_b_empty;
    assign p1_b_full  = (p1_b_count == WR_B_DEPTH[WR_B_CNT_W-1:0]);
    assign p1_b_empty = (p1_b_count == '0);

    logic     p1_b_out_valid;
    b_item_t  p1_b_out;

    // active AW (head) in core domain
    logic [IDW-1:0]        p1_awid;
    logic [ADDR_WIDTH-1:0] p1_awaddr;
    logic [7:0]            p1_awlen;
    logic [2:0]            p1_awsize;
    logic [1:0]            p1_awburst;
    logic                  p1_aw_active;
    int unsigned           p1_wbeat_cnt;

    // local one-beat buffer in core domain
    logic                     p1_local_wr_valid;
    logic [ADDR_WIDTH-1:0]    p1_local_wr_byte_addr;
    logic [DATA_WIDTH-1:0]    p1_local_wr_wdata;
    logic [BYTE_PER_WORD-1:0] p1_local_wr_wstrb;
    logic [2:0]               p1_local_wr_size;
    logic                     p1_local_wr_is_last;

    logic p1_w_hs;
    assign axi1_if.wready = core_rst_n
                         && p1_aw_active
                         && !p1_local_wr_valid;
    assign p1_w_hs = axi1_if.wvalid && axi1_if.wready;

    // core->dma bridge payload (registered in core domain)
    logic [ADDR_WIDTH-1:0]    bridge_p1_addr_core;
    logic [DATA_WIDTH-1:0]    bridge_p1_wdata_core;
    logic [BYTE_PER_WORD-1:0] bridge_p1_wstrb_core;
    logic [2:0]               bridge_p1_size_core;
    logic                     bridge_p1_is_last_core;
    logic [IDW-1:0]           bridge_p1_awid_core;
    logic                     p1_req_toggle_core;

    // core-side flow control
    logic p1_req_outstanding;
    logic p1_sent_is_last;
    logic [IDW-1:0] p1_sent_awid;

    // dma-side sync and staging (single beat stage)
    logic p1_req_toggle_sync1_dma, p1_req_toggle_sync2_dma;
    logic p1_req_toggle_last_seen_dma;

    logic                     staged_p1_valid_dma;
    logic [ADDR_WIDTH-1:0]    staged_p1_addr_dma;
    logic [DATA_WIDTH-1:0]    staged_p1_wdata_dma;
    logic [BYTE_PER_WORD-1:0] staged_p1_wstrb_dma;
    logic [2:0]               staged_p1_size_dma;
    logic                     staged_p1_is_last_dma;
    logic [IDW-1:0]           staged_p1_awid_dma;

    // dma->core ack toggle
    logic p1_ack_toggle_dma;
    logic p1_ack_toggle_sync1_core, p1_ack_toggle_sync2_core;
    logic p1_ack_toggle_last_seen_core;

    // dma-side burst buffer for P1
    wr_beat_t              p1_buf [0:MAX_BURST_BEATS-1];
    int unsigned           p1_buf_beats_written;
    logic                  p1_burst_ready;
    logic [IDW-1:0]        p1_burst_id;
    logic                  p1_lastbeat_ack_deferred;

    // ============================================================
    // READ path : Port0
    // ============================================================
    logic [IDW-1:0]        p0_arid;
    logic [ADDR_WIDTH-1:0] p0_araddr;
    logic [7:0]            p0_arlen;
    logic [2:0]            p0_arsize;
    logic [1:0]            p0_arburst;
    logic                  p0_ar_active;

    int unsigned           p0_issue_idx;
    int unsigned           p0_total_beats;

    logic                  p0_rd_issue;
    logic [ADDR_WIDTH-1:0] p0_rd_addr;

    logic [DATA_WIDTH-1:0] p0_rd_q1, p0_rd_q2;

    logic                  p0_meta_v1, p0_meta_v2, p0_meta_v3;
    logic [IDW-1:0]        p0_meta_rid1, p0_meta_rid2, p0_meta_rid3;
    logic                  p0_meta_last1, p0_meta_last2, p0_meta_last3;

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

    always_comb p0_rdata = p0_rd_fifo[p0_rd_rptr].data;

    // ============================================================
    // READ path : Port1
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

    logic                  p1_meta_v1, p1_meta_v2, p1_meta_v3;
    logic [IDW-1:0]        p1_meta_rid1, p1_meta_rid2, p1_meta_rid3;
    logic                  p1_meta_last1, p1_meta_last2, p1_meta_last3;

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

    always_comb p1_rdata = p1_rd_fifo[p1_rd_rptr].data;

    // ============================================================
    // Port0 FSM (dma_clk)
    // ============================================================
    always_ff @(posedge dma_clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin
            axi0_if.awready <= 1'b0;

            p0_aw_wptr  <= '0;
            p0_aw_rptr  <= '0;
            p0_aw_count <= '0;

            p0_b_wptr   <= '0;
            p0_b_rptr   <= '0;
            p0_b_count  <= '0;

            p0_b_out_valid <= 1'b0;
            p0_b_out       <= '0;
            axi0_if.bvalid <= 1'b0;
            axi0_if.bresp  <= 2'b00;
            axi0_if.bid    <= '0;

            p0_aw_active <= 1'b0;
            p0_wbeat_cnt <= 0;

            p0_buf_beats_total   <= 0;
            p0_buf_beats_written <= 0;
            p0_burst_ready       <= 1'b0;
            p0_burst_id          <= '0;

            axi0_if.arready <= 1'b1;

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
            begin
                logic awready_next;
                int unsigned reserved;
                reserved = int'(p0_aw_count)
                        + (p0_aw_active ? 1 : 0)
                        + (p0_burst_ready ? 1 : 0)
                        + (p0_b_out_valid ? 1 : 0);
                awready_next = (!p0_aw_full) && ((int'(p0_b_count) + reserved) < WR_B_DEPTH);
                axi0_if.awready <= awready_next;
            end

            if (axi0_if.awvalid && axi0_if.awready) begin
                p0_aw_fifo[p0_aw_wptr].id    <= axi0_if.awid;
                p0_aw_fifo[p0_aw_wptr].addr  <= axi0_if.awaddr;
                p0_aw_fifo[p0_aw_wptr].len   <= axi0_if.awlen;
                p0_aw_fifo[p0_aw_wptr].size  <= axi0_if.awsize;
                p0_aw_fifo[p0_aw_wptr].burst <= axi0_if.awburst;
                p0_aw_wptr  <= p0_aw_wptr + 1'b1;
                p0_aw_count <= p0_aw_count + 1'b1;
            end

            if (!p0_aw_active && !p0_burst_ready && !p0_aw_empty) begin
                p0_awid    <= p0_aw_fifo[p0_aw_rptr].id;
                p0_awaddr  <= p0_aw_fifo[p0_aw_rptr].addr;
                p0_awlen   <= p0_aw_fifo[p0_aw_rptr].len;
                p0_awsize  <= p0_aw_fifo[p0_aw_rptr].size;
                p0_awburst <= p0_aw_fifo[p0_aw_rptr].burst;

                p0_aw_active <= 1'b1;
                p0_wbeat_cnt <= 0;

                p0_buf_beats_total   <= (int'(p0_aw_fifo[p0_aw_rptr].len) + 1);
                p0_buf_beats_written <= 0;

                p0_aw_rptr  <= p0_aw_rptr + 1'b1;
                p0_aw_count <= p0_aw_count - 1'b1;
            end

            if (p0_aw_active && p0_w_hs) begin
                logic [ADDR_WIDTH-1:0] beat_addr;
                logic is_last_calc;

                is_last_calc = (p0_wbeat_cnt == p0_awlen);

                if      (p0_awburst == 2'b10) beat_addr = compute_wrap_addr(p0_awaddr, p0_awsize, p0_awlen, p0_wbeat_cnt);
                else if (p0_awburst == 2'b01) beat_addr = compute_incr_addr(p0_awaddr, p0_awsize, p0_wbeat_cnt);
                else                          beat_addr = p0_awaddr;

                if (p0_buf_beats_written < MAX_BURST_BEATS) begin
                    p0_buf[p0_buf_beats_written].byte_addr <= beat_addr;
                    p0_buf[p0_buf_beats_written].wdata     <= axi0_if.wdata;
                    p0_buf[p0_buf_beats_written].wstrb     <= axi0_if.wstrb;
                    p0_buf[p0_buf_beats_written].size      <= p0_awsize;
                    p0_buf_beats_written <= p0_buf_beats_written + 1;
                end

                p0_wbeat_cnt <= p0_wbeat_cnt + 1;

                if (is_last_calc) begin
                    p0_burst_ready <= 1'b1;
                    p0_burst_id    <= p0_awid;
                    p0_aw_active   <= 1'b0;
                end
            end

            begin
                logic hs;
                hs = p0_b_out_valid && axi0_if.bready;

                if (!p0_b_out_valid) begin
                    if (!p0_b_empty) begin
                        p0_b_out       <= p0_b_fifo[p0_b_rptr];
                        p0_b_out_valid <= 1'b1;
                    end else begin
                        p0_b_out       <= '0;
                        p0_b_out_valid <= 1'b0;
                    end
                end else if (hs) begin
                    p0_b_rptr  <= p0_b_rptr + 1'b1;
                    p0_b_count <= p0_b_count - 1'b1;

                    if (p0_b_count > 1) begin
                        p0_b_out       <= p0_b_fifo[p0_b_rptr + 1'b1];
                        p0_b_out_valid <= 1'b1;
                    end else begin
                        p0_b_out       <= '0;
                        p0_b_out_valid <= 1'b0;
                    end
                end

                axi0_if.bvalid <= p0_b_out_valid;
                axi0_if.bid    <= p0_b_out.bid;
                axi0_if.bresp  <= p0_b_out.bresp;
            end

            if (!p0_ar_active) begin
                if (axi0_if.arvalid) begin
                    int unsigned need;
                    need = int'(axi0_if.arlen) + 1;
                    axi0_if.arready <= (p0_rd_fifo_free >= need[RD_CNT_W-1:0]);
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

            begin
                logic p0_push, p0_pop;

                p0_push = p0_meta_v3 && !p0_rd_fifo_full;
                p0_pop  = (axi0_if.rvalid && axi0_if.rready);

                if (p0_push) begin
                    p0_rd_fifo[p0_rd_wptr].rid  <= p0_meta_rid3;
                    p0_rd_fifo[p0_rd_wptr].last <= p0_meta_last3;
                    p0_rd_fifo[p0_rd_wptr].data <= p0_rd_q2;
                    p0_rd_wptr <= p0_rd_wptr + 1'b1;
                end

                if (p0_pop) begin
                    if (p0_rd_fifo[p0_rd_rptr].last) p0_ar_active <= 1'b0;
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
    // Port1 FSM (core_clk)
    // ============================================================
    always_ff @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            axi1_if.awready <= 1'b0;

            p1_aw_wptr  <= '0;
            p1_aw_rptr  <= '0;
            p1_aw_count <= '0;

            p1_b_wptr   <= '0;
            p1_b_rptr   <= '0;
            p1_b_count  <= '0;

            p1_b_out_valid <= 1'b0;
            p1_b_out       <= '0;
            axi1_if.bvalid <= 1'b0;
            axi1_if.bresp  <= 2'b00;
            axi1_if.bid    <= '0;

            axi1_if.arready <= 1'b1;

            p1_aw_active      <= 1'b0;
            p1_wbeat_cnt      <= 0;
            p1_local_wr_valid <= 1'b0;

            p1_req_toggle_core <= 1'b0;
            p1_req_outstanding <= 1'b0;

            bridge_p1_addr_core    <= '0;
            bridge_p1_wdata_core   <= '0;
            bridge_p1_wstrb_core   <= '0;
            bridge_p1_size_core    <= '0;
            bridge_p1_is_last_core <= 1'b0;
            bridge_p1_awid_core    <= '0;

            p1_ack_toggle_sync1_core     <= 1'b0;
            p1_ack_toggle_sync2_core     <= 1'b0;
            p1_ack_toggle_last_seen_core <= 1'b0;

            p1_sent_is_last <= 1'b0;
            p1_sent_awid    <= '0;

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
            p1_ack_toggle_sync1_core <= p1_ack_toggle_dma;
            p1_ack_toggle_sync2_core <= p1_ack_toggle_sync1_core;

            begin
                logic awready_next;
                int unsigned reserved;
                reserved = int'(p1_aw_count)
                        + (p1_aw_active ? 1 : 0)
                        + (p1_b_out_valid ? 1 : 0);
                awready_next = (!p1_aw_full) && ((int'(p1_b_count) + reserved) < WR_B_DEPTH);
                axi1_if.awready <= awready_next;
            end

            if (axi1_if.awvalid && axi1_if.awready) begin
                p1_aw_fifo[p1_aw_wptr].id    <= axi1_if.awid;
                p1_aw_fifo[p1_aw_wptr].addr  <= axi1_if.awaddr;
                p1_aw_fifo[p1_aw_wptr].len   <= axi1_if.awlen;
                p1_aw_fifo[p1_aw_wptr].size  <= axi1_if.awsize;
                p1_aw_fifo[p1_aw_wptr].burst <= axi1_if.awburst;

                p1_aw_wptr  <= p1_aw_wptr + 1'b1;
                p1_aw_count <= p1_aw_count + 1'b1;
            end

            if (!p1_aw_active && !p1_aw_empty) begin
                p1_awid    <= p1_aw_fifo[p1_aw_rptr].id;
                p1_awaddr  <= p1_aw_fifo[p1_aw_rptr].addr;
                p1_awlen   <= p1_aw_fifo[p1_aw_rptr].len;
                p1_awsize  <= p1_aw_fifo[p1_aw_rptr].size;
                p1_awburst <= p1_aw_fifo[p1_aw_rptr].burst;

                p1_aw_active <= 1'b1;
                p1_wbeat_cnt <= 0;

                p1_aw_rptr  <= p1_aw_rptr + 1'b1;
                p1_aw_count <= p1_aw_count - 1'b1;
            end

            if (p1_aw_active && p1_w_hs) begin
                logic [ADDR_WIDTH-1:0] beat_addr;
                logic is_last_calc;

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
            end

            if (p1_local_wr_valid &&
                !p1_req_outstanding &&
                (p1_req_toggle_core == p1_ack_toggle_sync2_core)) begin

                bridge_p1_addr_core    <= p1_local_wr_byte_addr;
                bridge_p1_wdata_core   <= p1_local_wr_wdata;
                bridge_p1_wstrb_core   <= p1_local_wr_wstrb;
                bridge_p1_is_last_core <= p1_local_wr_is_last;
                bridge_p1_size_core    <= p1_local_wr_size;
                bridge_p1_awid_core    <= p1_awid;

                p1_sent_is_last <= p1_local_wr_is_last;
                p1_sent_awid    <= p1_awid;

                p1_req_toggle_core <= ~p1_req_toggle_core;
                p1_req_outstanding <= 1'b1;
            end

            if (p1_ack_toggle_sync2_core != p1_ack_toggle_last_seen_core) begin
                p1_ack_toggle_last_seen_core <= p1_ack_toggle_sync2_core;

                p1_req_outstanding <= 1'b0;
                p1_local_wr_valid  <= 1'b0;

                if (p1_sent_is_last) begin
                    if (!p1_b_full) begin
                        p1_b_fifo[p1_b_wptr].bid   <= p1_sent_awid;
                        p1_b_fifo[p1_b_wptr].bresp <= 2'b00;
                        p1_b_wptr  <= p1_b_wptr + 1'b1;
                        p1_b_count <= p1_b_count + 1'b1;
                    end
                    p1_aw_active <= 1'b0;
                end
            end

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
                end else if (hs) begin
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
            end

            if (!p1_ar_active) begin
                if (axi1_if.arvalid) begin
                    int unsigned need;
                    need = int'(axi1_if.arlen) + 1;
                    axi1_if.arready <= (p1_rd_fifo_free >= need[RD_CNT_W-1:0]);
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
                end

                if (p1_pop) begin
                    if (p1_rd_fifo[p1_rd_rptr].last) p1_ar_active <= 1'b0;
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
    // Sync + stage beats from core->dma, then dma buffers into p1 burst buffer
    // ============================================================
    always_ff @(posedge dma_clk or negedge dma_rst_n) begin
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
            staged_p1_awid_dma    <= '0;

            p1_ack_toggle_dma <= 1'b0;

            p1_buf_beats_written     <= 0;
            p1_burst_ready           <= 1'b0;
            p1_burst_id              <= '0;
            p1_lastbeat_ack_deferred <= 1'b0;

        end else begin
            p1_req_toggle_sync1_dma <= p1_req_toggle_core;
            p1_req_toggle_sync2_dma <= p1_req_toggle_sync1_dma;

            if (!staged_p1_valid_dma &&
                (p1_req_toggle_sync2_dma != p1_req_toggle_last_seen_dma)) begin

                staged_p1_addr_dma    <= bridge_p1_addr_core;
                staged_p1_wdata_dma   <= bridge_p1_wdata_core;
                staged_p1_wstrb_dma   <= bridge_p1_wstrb_core;
                staged_p1_size_dma    <= bridge_p1_size_core;
                staged_p1_is_last_dma <= bridge_p1_is_last_core;
                staged_p1_awid_dma    <= bridge_p1_awid_core;

                staged_p1_valid_dma <= 1'b1;
                p1_req_toggle_last_seen_dma <= p1_req_toggle_sync2_dma;
            end

            if (staged_p1_valid_dma && !p1_burst_ready) begin
                if (p1_buf_beats_written < MAX_BURST_BEATS) begin
                    p1_buf[p1_buf_beats_written].byte_addr <= staged_p1_addr_dma;
                    p1_buf[p1_buf_beats_written].wdata     <= staged_p1_wdata_dma;
                    p1_buf[p1_buf_beats_written].wstrb     <= staged_p1_wstrb_dma;
                    p1_buf[p1_buf_beats_written].size      <= staged_p1_size_dma;
                    p1_buf_beats_written <= p1_buf_beats_written + 1;
                end

                if (p1_buf_beats_written == 0) p1_burst_id <= staged_p1_awid_dma;

                staged_p1_valid_dma <= 1'b0;

                if (!staged_p1_is_last_dma) begin
                    p1_ack_toggle_dma <= ~p1_ack_toggle_dma;
                end else begin
                    p1_burst_ready           <= 1'b1;
                    p1_lastbeat_ack_deferred <= 1'b1;
                end
            end
        end
    end

    // ============================================================
    // Read-data formatting helper
    // Keep only the requested byte lanes for this beat; other lanes are zeroed.
    // ============================================================
    function automatic logic [DATA_WIDTH-1:0] format_read_data(
        input logic [DATA_WIDTH-1:0] raw_word,
        input logic [ADDR_WIDTH-1:0] byte_addr,
        input logic [2:0]            size
    );
        logic [DATA_WIDTH-1:0] out;
        int unsigned off;
        int unsigned bytes;
        int unsigned b;
        int unsigned lane;
        begin
            out   = '0;
            off   = (byte_addr % BYTE_PER_WORD);
            bytes = size_to_bytes(size);

            if (bytes > BYTE_PER_WORD)
                bytes = BYTE_PER_WORD;

            for (b = 0; b < bytes; b++) begin
                lane = (off + b) % BYTE_PER_WORD;
                out[8*lane +: 8] = raw_word[8*lane +: 8];
            end

            format_read_data = out;
        end
    endfunction

    // ============================================================
    // BRAM READ pipelines (READ_FIRST) - 2-cycle latency
    // ============================================================
    always_ff @(posedge dma_clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin
            p0_rd_q1 <= '0;
            p0_rd_q2 <= '0;
        end else begin
            if (p0_rd_issue)
                p0_rd_q1 <= format_read_data(
                    mem_word[word_index(p0_rd_addr)],
                    p0_rd_addr,
                    p0_arsize
                );
            p0_rd_q2 <= p0_rd_q1;
        end
    end

    always_ff @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            p1_rd_q1 <= '0;
            p1_rd_q2 <= '0;
        end else begin
            if (p1_rd_issue)
                p1_rd_q1 <= format_read_data(
                    mem_word[word_index(p1_rd_addr)],
                    p1_rd_addr,
                    p1_arsize
                );
            p1_rd_q2 <= p1_rd_q1;
        end
    end

    // ============================================================
    // Commit Engine (dma_clk): burst-end atomic mem update
    // ============================================================
    typedef enum logic [2:0] {
        CE_IDLE,
        CE_APPLY_P0,
        CE_APPLY_P1,
        CE_EMIT_P0,
        CE_EMIT_P1
    } ce_state_e;

    ce_state_e ce_state;

    assign ce_idle = (ce_state == CE_IDLE);

    int unsigned ce_idx;
    int unsigned ce_total;
    logic [IDW-1:0] ce_bid;
    logic           ce_apply_sent;

    int unsigned           ce_uniq_cnt;
    int unsigned           ce_find_j;
    logic                  ce_found;
    int unsigned           ce_upd_wi   [0:MAX_BURST_BEATS-1];
    logic [DATA_WIDTH-1:0] ce_upd_word [0:MAX_BURST_BEATS-1];

    int unsigned p0_quota_left;

    logic [31:0] p1_starve_cnt;
    logic        p1_starve_asserted;

    function automatic logic [DATA_WIDTH-1:0] apply_one_beat_to_word(
        input logic [DATA_WIDTH-1:0]    cur_word,
        input logic [ADDR_WIDTH-1:0]    byte_addr,
        input logic [DATA_WIDTH-1:0]    wdata,
        input logic [BYTE_PER_WORD-1:0] wstrb,
        input logic [2:0]               size
    );
        logic [DATA_WIDTH-1:0] nxt;
        int unsigned off;
        int unsigned bytes;
        int unsigned b;
        int unsigned lane;
        begin
            nxt   = cur_word;
            off   = (byte_addr % BYTE_PER_WORD);
            bytes = size_to_bytes(size);
            for (b = 0; b < bytes; b++) begin
                lane = (off + b) % BYTE_PER_WORD;
                if (wstrb[lane]) nxt[8*lane +: 8] = wdata[8*lane +: 8];
            end
            apply_one_beat_to_word = nxt;
        end
    endfunction

    always_ff @(posedge dma_clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin
            ce_state <= CE_IDLE;
            ce_idx   <= 0;
            ce_total <= 0;
            ce_bid   <= '0;
            ce_apply_sent <= 1'b0;

            ce_uniq_cnt <= 0;

            p0_quota_left <= P0_WEIGHT;

            p1_starve_cnt      <= 0;
            p1_starve_asserted <= 1'b0;

            perf_total_cycles  <= 0;
            perf_busy_cycles   <= 0;
            perf_bytes_written <= 0;
            perf_p0_bursts     <= 0;
            perf_p1_bursts     <= 0;

            apply_if.cb_producer.valid     <= 1'b0;
            apply_if.cb_producer.port      <= 1'b0;
            apply_if.cb_producer.id        <= '0;
            apply_if.cb_producer.beat_idx  <= '0;
            apply_if.cb_producer.byte_addr <= '0;
            apply_if.cb_producer.wdata     <= '0;
            apply_if.cb_producer.wstrb     <= '0;
            apply_if.cb_producer.size      <= '0;
            apply_if.cb_producer.last      <= 1'b0;

            commit_if.cb_producer.valid     <= 1'b0;
            commit_if.cb_producer.port      <= 1'b0;
            commit_if.cb_producer.id        <= '0;
            commit_if.cb_producer.beat_idx  <= '0;
            commit_if.cb_producer.byte_addr <= '0;
            commit_if.cb_producer.wdata     <= '0;
            commit_if.cb_producer.wstrb     <= '0;
            commit_if.cb_producer.size      <= '0;
            commit_if.cb_producer.last      <= 1'b0;

        end else begin
            perf_total_cycles <= perf_total_cycles + 1;

            apply_if.cb_producer.valid  <= 1'b0;
            commit_if.cb_producer.valid <= 1'b0;

            if (p1_burst_ready && (ce_state == CE_IDLE)) begin
                if (!p0_burst_ready) begin
                    p1_starve_cnt <= 0;
                end else begin
                    if (p1_starve_cnt != 32'hFFFF_FFFF) p1_starve_cnt <= p1_starve_cnt + 1;
                end
            end else if (!p1_burst_ready) begin
                p1_starve_cnt <= 0;
            end

            if (ASSERT_ON_STARVE && (p1_starve_cnt >= STARVE_THRESHOLD) && !p1_starve_asserted) begin
                p1_starve_asserted <= 1'b1;
                `ifndef SYNTHESIS
                    $warning("%0t: [axi_mm_dual_port_bram] P1 burst starvation detected: cnt=%0d threshold=%0d",
                             $time, p1_starve_cnt, STARVE_THRESHOLD);
                `endif
            end

            unique case (ce_state)
                CE_IDLE: begin
                    ce_idx        <= 0;
                    ce_apply_sent <= 1'b0;

                    if (p0_burst_ready || p1_burst_ready) begin
                        logic grant_p0, grant_p1;
                        grant_p0 = 1'b0;
                        grant_p1 = 1'b0;

                        if (p0_burst_ready && p1_burst_ready) begin
                            if (p0_quota_left != 0) grant_p0 = 1'b1;
                            else                    grant_p1 = 1'b1;
                        end else if (p0_burst_ready) begin
                            grant_p0 = 1'b1;
                        end else begin
                            grant_p1 = 1'b1;
                        end

                        if (grant_p0) begin
                            ce_total <= p0_buf_beats_written;
                            ce_bid   <= p0_burst_id;
                            ce_state <= CE_APPLY_P0;

                            if (p1_burst_ready) begin
                                if (p0_quota_left != 0) p0_quota_left <= p0_quota_left - 1;
                            end else begin
                                if (p0_quota_left == 0) p0_quota_left <= P0_WEIGHT;
                            end
                        end else begin
                            ce_total <= p1_buf_beats_written;
                            ce_bid   <= p1_burst_id;
                            ce_state <= CE_APPLY_P1;

                            p0_quota_left <= P0_WEIGHT;
                        end
                    end
                end

                CE_APPLY_P0: begin
                    int unsigned i;
                    int unsigned j;
                    int unsigned wi;
                    logic [DATA_WIDTH-1:0] cur;
                    int unsigned wr_bytes;

                    ce_uniq_cnt = 0;

                    for (i = 0; i < ce_total; i++) begin
                        wi = word_index(p0_buf[i].byte_addr);

                        ce_found = 1'b0;
                        ce_find_j = 0;
                        for (j = 0; j < ce_uniq_cnt; j++) begin
                            if (ce_upd_wi[j] == wi) begin
                                ce_found  = 1'b1;
                                ce_find_j = j;
                            end
                        end

                        if (ce_found) begin
                            cur = ce_upd_word[ce_find_j];
                            cur = apply_one_beat_to_word(cur,
                                                         p0_buf[i].byte_addr,
                                                         p0_buf[i].wdata,
                                                         p0_buf[i].wstrb,
                                                         p0_buf[i].size);
                            ce_upd_word[ce_find_j] = cur;
                        end else begin
                            cur = mem_word[wi];
                            cur = apply_one_beat_to_word(cur,
                                                         p0_buf[i].byte_addr,
                                                         p0_buf[i].wdata,
                                                         p0_buf[i].wstrb,
                                                         p0_buf[i].size);
                            ce_upd_wi[ce_uniq_cnt]   = wi;
                            ce_upd_word[ce_uniq_cnt] = cur;
                            ce_uniq_cnt++;
                        end

                        wr_bytes = count_written_bytes(p0_buf[i].byte_addr, p0_buf[i].size, p0_buf[i].wstrb);
                        perf_bytes_written <= perf_bytes_written + wr_bytes;
                    end

                    for (j = 0; j < ce_uniq_cnt; j++) begin
                        mem_word[ce_upd_wi[j]] <= ce_upd_word[j];
                    end

                    perf_busy_cycles <= perf_busy_cycles + 1;

                    ce_idx        <= 0;
                    ce_apply_sent <= 1'b0;
                    ce_state      <= CE_EMIT_P0;
                end

                CE_APPLY_P1: begin
                    int unsigned i;
                    int unsigned j;
                    int unsigned wi;
                    logic [DATA_WIDTH-1:0] cur;
                    int unsigned wr_bytes;

                    ce_uniq_cnt = 0;

                    for (i = 0; i < ce_total; i++) begin
                        wi = word_index(p1_buf[i].byte_addr);

                        ce_found = 1'b0;
                        ce_find_j = 0;
                        for (j = 0; j < ce_uniq_cnt; j++) begin
                            if (ce_upd_wi[j] == wi) begin
                                ce_found  = 1'b1;
                                ce_find_j = j;
                            end
                        end

                        if (ce_found) begin
                            cur = ce_upd_word[ce_find_j];
                            cur = apply_one_beat_to_word(cur,
                                                         p1_buf[i].byte_addr,
                                                         p1_buf[i].wdata,
                                                         p1_buf[i].wstrb,
                                                         p1_buf[i].size);
                            ce_upd_word[ce_find_j] = cur;
                        end else begin
                            cur = mem_word[wi];
                            cur = apply_one_beat_to_word(cur,
                                                         p1_buf[i].byte_addr,
                                                         p1_buf[i].wdata,
                                                         p1_buf[i].wstrb,
                                                         p1_buf[i].size);
                            ce_upd_wi[ce_uniq_cnt]   = wi;
                            ce_upd_word[ce_uniq_cnt] = cur;
                            ce_uniq_cnt++;
                        end

                        wr_bytes = count_written_bytes(p1_buf[i].byte_addr, p1_buf[i].size, p1_buf[i].wstrb);
                        perf_bytes_written <= perf_bytes_written + wr_bytes;
                    end

                    for (j = 0; j < ce_uniq_cnt; j++) begin
                        mem_word[ce_upd_wi[j]] <= ce_upd_word[j];
                    end

                    perf_busy_cycles <= perf_busy_cycles + 1;

                    ce_idx        <= 0;
                    ce_apply_sent <= 1'b0;
                    ce_state      <= CE_EMIT_P1;
                end

                CE_EMIT_P0: begin
                    // Phase 1: emit APPLY beats (visibility already established in CE_APPLY_P0)
                    if (!ce_apply_sent) begin
                        if (ce_idx < ce_total) begin
                            if (apply_if.cb_producer.ready) begin
                                apply_if.cb_producer.valid     <= 1'b1;
                                apply_if.cb_producer.port      <= 1'b0;
                                apply_if.cb_producer.id        <= ce_bid;
                                apply_if.cb_producer.beat_idx  <= ce_idx[7:0];
                                apply_if.cb_producer.byte_addr <= p0_buf[ce_idx].byte_addr;
                                apply_if.cb_producer.wdata     <= p0_buf[ce_idx].wdata;
                                apply_if.cb_producer.wstrb     <= p0_buf[ce_idx].wstrb;
                                apply_if.cb_producer.size      <= p0_buf[ce_idx].size;
                                apply_if.cb_producer.last      <= (ce_idx == (ce_total-1));

                                ce_idx <= ce_idx + 1;
                            end
                        end else begin
                            ce_idx        <= 0;
                            ce_apply_sent <= 1'b1;
                        end
                    end
                    // Phase 2: emit COMMIT beats
                    else if (ce_idx < ce_total) begin
                        if (commit_if.cb_producer.ready) begin
                            commit_if.cb_producer.valid     <= 1'b1;
                            commit_if.cb_producer.port      <= 1'b0;
                            commit_if.cb_producer.id        <= ce_bid;
                            commit_if.cb_producer.beat_idx  <= ce_idx[7:0];
                            commit_if.cb_producer.byte_addr <= p0_buf[ce_idx].byte_addr;
                            commit_if.cb_producer.wdata     <= p0_buf[ce_idx].wdata;
                            commit_if.cb_producer.wstrb     <= p0_buf[ce_idx].wstrb;
                            commit_if.cb_producer.size      <= p0_buf[ce_idx].size;
                            commit_if.cb_producer.last      <= (ce_idx == (ce_total-1));

                            ce_idx <= ce_idx + 1;
                        end
                    end else begin
                        if (!p0_b_full) begin
                            p0_b_fifo[p0_b_wptr].bid   <= ce_bid;
                            p0_b_fifo[p0_b_wptr].bresp <= 2'b00;
                            p0_b_wptr  <= p0_b_wptr + 1'b1;
                            p0_b_count <= p0_b_count + 1'b1;
                        end

                        p0_burst_ready       <= 1'b0;
                        p0_buf_beats_written <= 0;
                        p0_buf_beats_total   <= 0;
                        ce_apply_sent        <= 1'b0;
                        ce_idx               <= 0;

                        perf_p0_bursts <= perf_p0_bursts + 1;
                        ce_state <= CE_IDLE;
                    end
                end

                CE_EMIT_P1: begin
                    // Phase 1: emit APPLY beats (visibility already established in CE_APPLY_P1)
                    if (!ce_apply_sent) begin
                        if (ce_idx < ce_total) begin
                            if (apply_if.cb_producer.ready) begin
                                apply_if.cb_producer.valid     <= 1'b1;
                                apply_if.cb_producer.port      <= 1'b1;
                                apply_if.cb_producer.id        <= ce_bid;
                                apply_if.cb_producer.beat_idx  <= ce_idx[7:0];
                                apply_if.cb_producer.byte_addr <= p1_buf[ce_idx].byte_addr;
                                apply_if.cb_producer.wdata     <= p1_buf[ce_idx].wdata;
                                apply_if.cb_producer.wstrb     <= p1_buf[ce_idx].wstrb;
                                apply_if.cb_producer.size      <= p1_buf[ce_idx].size;
                                apply_if.cb_producer.last      <= (ce_idx == (ce_total-1));

                                ce_idx <= ce_idx + 1;
                            end
                        end else begin
                            ce_idx        <= 0;
                            ce_apply_sent <= 1'b1;
                        end
                    end
                    // Phase 2: emit COMMIT beats
                    else if (ce_idx < ce_total) begin
                        if (commit_if.cb_producer.ready) begin
                            commit_if.cb_producer.valid     <= 1'b1;
                            commit_if.cb_producer.port      <= 1'b1;
                            commit_if.cb_producer.id        <= ce_bid;
                            commit_if.cb_producer.beat_idx  <= ce_idx[7:0];
                            commit_if.cb_producer.byte_addr <= p1_buf[ce_idx].byte_addr;
                            commit_if.cb_producer.wdata     <= p1_buf[ce_idx].wdata;
                            commit_if.cb_producer.wstrb     <= p1_buf[ce_idx].wstrb;
                            commit_if.cb_producer.size      <= p1_buf[ce_idx].size;
                            commit_if.cb_producer.last      <= (ce_idx == (ce_total-1));

                            ce_idx <= ce_idx + 1;
                        end
                    end else begin
                        if (p1_lastbeat_ack_deferred) begin
                            p1_ack_toggle_dma <= ~p1_ack_toggle_dma;
                            p1_lastbeat_ack_deferred <= 1'b0;
                        end

                        p1_burst_ready       <= 1'b0;
                        p1_buf_beats_written <= 0;
                        ce_apply_sent        <= 1'b0;
                        ce_idx               <= 0;

                        perf_p1_bursts <= perf_p1_bursts + 1;
                        ce_state <= CE_IDLE;
                    end
                end

                default: ce_state <= CE_IDLE;
            endcase

            `ifndef SYNTHESIS
            if (LOG_ENABLE) begin
                if ((perf_total_cycles % LOG_INTERVAL_CYCLES) == 0 && perf_total_cycles != 0)
                    perf_log_snapshot("snap");
            end
            `endif
        end
    end

    // ============================================================
    // Final summary (sim-only)
    // ============================================================
    `ifndef SYNTHESIS
    final begin
        if (LOG_ENABLE) perf_log_snapshot("final");
    end
    `endif

endmodule