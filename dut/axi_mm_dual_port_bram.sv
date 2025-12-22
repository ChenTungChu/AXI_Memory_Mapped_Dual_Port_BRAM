// File: axi_mm_dual_port_bram.sv
// "Behavioral" Multi-clock Dual-port AXI4 Memory-Mapped BRAM with single-writer Memory Core
// Minimal-intrusion fixes per review:
// - Remove all read-forwarding (no cross-domain or same-domain forwarding)
// - Remove cross-domain conflict detection / cross-domain bresp writes
// - Fix WSTRB -> WDATA mapping and latch AW size in pending buffers
//
// Ports:
// - dma_clk / dma_rst_n : Port0 domain (axi0_if)
// - core_clk / core_rst_n : Port1 domain (axi1_if)
//
// Notes:
// - Memory Core (dma_clk) is the only writer to mem_byte[]
// - Port1 -> DMA uses toggle handshake (single-entry staging)
// - Port0 has priority over staged Port1 writes
//
// Endianness / byte mapping convention used in this module:
// - "lane 0" refers to the least-significant byte of WDATA (bits [7:0]).
// - mem_byte[mem_idx] stores byte lane 0 at the lowest address as usual.
// - pN_wr_wstrb[0] corresponds to the least-significant byte (lane 0).
//
// This file contains simulation-only assertions (inside `ifndef SYNTHESIS`) to
// catch invalid AW/W sequences during verification. These are omitted for synthesis.

`timescale 1ns/1ps

module axi_mm_dual_port_bram #(
    parameter int ADDR_WIDTH         = 32,
    parameter int DATA_WIDTH         = 64,
    parameter int ID_WIDTH           = 4,
    parameter int DEPTH_WORDS        = 1024,
    parameter int STARVE_THRESHOLD   = 2000,
    parameter bit ASSERT_ON_STARVE   = 1
) (
    // clocks / resets per domain
    input  logic dma_clk,
    input  logic dma_rst_n,
    input  logic core_clk,
    input  logic core_rst_n,

    // connect interface instances using mp_slave modport from axi_mm_if
    axi_mm_if  axi0_if,
    axi_mm_if  axi1_if
);

    // -------------------------
    // local params / helpers
    // -------------------------
    localparam int IDW           = (ID_WIDTH > 0) ? ID_WIDTH : 1;
    localparam int BYTE_PER_WORD = DATA_WIDTH / 8;
    localparam int MEM_BYTES     = DEPTH_WORDS * BYTE_PER_WORD;
    localparam int ADDR_IDX_W    = $clog2(MEM_BYTES);

    // sanity checks
    // synthesis translate_off
    initial begin
        if ((DATA_WIDTH % 8) != 0)   $error("DATA_WIDTH must be multiple of 8");
        if (DEPTH_WORDS <= 0)        $error("DEPTH_WORDS must be > 0");
        if (ADDR_IDX_W > ADDR_WIDTH) $warning("ADDR_WIDTH may be too small to address entire mem");
    end
    // synthesis translate_on

    // byte-addressable memory
    logic [7:0] mem_byte [0:MEM_BYTES-1];

    function automatic logic [ADDR_IDX_W-1:0] byte_index(input logic [ADDR_WIDTH-1:0] addr);
        byte_index = addr[ADDR_IDX_W-1:0];
    endfunction

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

    // -------------------------
    // Port0 (dma domain) state
    // -------------------------
    logic [IDW-1:0]           p0_awid;
    logic [ADDR_WIDTH-1:0]    p0_awaddr;
    logic [7:0]               p0_awlen;
    logic [2:0]               p0_awsize;
    logic [1:0]               p0_awburst;
    logic                     p0_aw_active;

    // local pending write beat (dma domain)
    logic                     p0_wr_req;          // pending write beat (dma domain)
    logic [ADDR_WIDTH-1:0]    p0_wr_byte_addr;
    logic [DATA_WIDTH-1:0]    p0_wr_wdata;
    logic [BYTE_PER_WORD-1:0] p0_wr_wstrb;
    logic [2:0]               p0_wr_size;         // latched AW size for this beat
    logic                     p0_wr_is_last;
    int                       p0_wbeat_cnt;
    logic [IDW-1:0]           p0_bid;
    logic [1:0]               p0_bresp;
    logic                     p0_bvalid;

    // read side
    logic [IDW-1:0]           p0_arid;
    logic [ADDR_WIDTH-1:0]    p0_araddr;
    logic [7:0]               p0_arlen;
    logic [2:0]               p0_arsize;
    logic [1:0]               p0_arburst;
    logic                     p0_ar_active;
    int                       p0_rbeat_cnt;
    logic                     p0_rvalid;
    logic [DATA_WIDTH-1:0]    p0_rdata;
    logic [IDW-1:0]           p0_rid;
    logic                     p0_rlast;

    // -------------------------
    // Port1 (core domain) state
    // -------------------------
    logic [IDW-1:0]           p1_awid;
    logic [ADDR_WIDTH-1:0]    p1_awaddr;
    logic [7:0]               p1_awlen;
    logic [2:0]               p1_awsize;
    logic [1:0]               p1_awburst;
    logic                     p1_aw_active;

    // local pending write beat on core side (before handshake)
    logic                     p1_local_wr_req;    // core domain local pending beat captured
    logic [ADDR_WIDTH-1:0]    p1_local_wr_byte_addr;
    logic [DATA_WIDTH-1:0]    p1_local_wr_wdata;
    logic [BYTE_PER_WORD-1:0] p1_local_wr_wstrb;
    logic [2:0]               p1_local_wr_size;
    logic                     p1_local_wr_is_last;
    int                       p1_wbeat_cnt;
    logic [IDW-1:0]           p1_bid;
    logic [1:0]               p1_bresp;
    logic                     p1_bvalid;

    // read side
    logic [IDW-1:0]           p1_arid;
    logic [ADDR_WIDTH-1:0]    p1_araddr;
    logic [7:0]               p1_arlen;
    logic [2:0]               p1_arsize;
    logic [1:0]               p1_arburst;
    logic                     p1_ar_active;
    int                       p1_rbeat_cnt;
    logic                     p1_rvalid;
    logic [DATA_WIDTH-1:0]    p1_rdata;
    logic [IDW-1:0]           p1_rid;
    logic                     p1_rlast;

    // -------------------------
    // Port1 -> DMA handshake bridge (core -> dma)
    // -------------------------
    // Core-side bridge registers (written in core_clk)
    logic [ADDR_WIDTH-1:0]    bridge_p1_addr_core;
    logic [DATA_WIDTH-1:0]    bridge_p1_wdata_core;
    logic [BYTE_PER_WORD-1:0] bridge_p1_wstrb_core;
    logic [2:0]               bridge_p1_size_core;
    logic                     bridge_p1_is_last_core;
    logic                     p1_req_toggle_core; // toggles each time new bridge data is available

    // Sync into dma domain (double-flop)
    logic p1_req_toggle_sync1_dma, p1_req_toggle_sync2_dma;
    logic p1_req_toggle_last_seen_dma;

    // Staged copy in dma domain (captured when toggle edge detected)
    logic [ADDR_WIDTH-1:0]    staged_p1_addr_dma;
    logic [DATA_WIDTH-1:0]    staged_p1_wdata_dma;
    logic [BYTE_PER_WORD-1:0] staged_p1_wstrb_dma;
    logic [2:0]               staged_p1_size_dma;
    logic                     staged_p1_is_last_dma;
    logic                     staged_p1_valid_dma; // indicates dma has a staged p1 beat to service

    // Ack toggle from dma back to core
    logic p1_ack_toggle_dma;
    logic p1_ack_toggle_sync1_core, p1_ack_toggle_sync2_core;
    logic p1_ack_toggle_last_seen_core;

    // core-side local flag that sees ack
    logic p1_bridge_accepted_core;

    // -------------------------
    // Starvation detector state (dma domain)
    // -------------------------
    // placed here so visible module-wide (but used/updated only in dma always_ff)
    logic [31:0] staged_p1_starve_cnt;
    logic        staged_p1_starve_asserted;

    // -------------------------
    // Core-side FSM + bridge (core_clk domain)
    // -------------------------
    always_ff @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            // reset core-side interface outputs/state
            axi1_if.awready <= 1'b1;
            axi1_if.wready  <= 1'b0;
            axi1_if.bvalid  <= 1'b0;
            axi1_if.bresp   <= 2'b00;
            axi1_if.bid     <= '0;
            axi1_if.arready <= 1'b1;
            axi1_if.rvalid  <= 1'b0;
            axi1_if.rdata   <= '0;
            axi1_if.rresp   <= 2'b00;
            axi1_if.rid     <= '0;
            axi1_if.rlast   <= 1'b0;

            p1_aw_active    <= 1'b0;
            p1_wbeat_cnt    <= 0;
            p1_local_wr_req <= 1'b0;
            p1_bvalid       <= 1'b0;

            p1_ar_active    <= 1'b0;
            p1_rbeat_cnt    <= 0;
            p1_rvalid       <= 1'b0;
            p1_rlast        <= 1'b0;

            // bridge
            bridge_p1_addr_core          <= '0;
            bridge_p1_wdata_core         <= '0;
            bridge_p1_wstrb_core         <= '0;
            bridge_p1_is_last_core       <= 1'b0;
            bridge_p1_size_core          <= '0;
            p1_req_toggle_core           <= 1'b0;
            p1_ack_toggle_sync1_core     <= 1'b0;
            p1_ack_toggle_sync2_core     <= 1'b0;
            p1_ack_toggle_last_seen_core <= 1'b0;
            p1_bridge_accepted_core      <= 1'b0;
        end else begin
            // ---- AW capture (Port1) ----
            if (axi1_if.awready && axi1_if.awvalid) begin
                p1_awid         <= axi1_if.awid;
                p1_awaddr       <= axi1_if.awaddr;
                p1_awlen        <= axi1_if.awlen;
                p1_awsize       <= axi1_if.awsize;
                p1_awburst      <= axi1_if.awburst;
                p1_aw_active    <= 1'b1;
                p1_wbeat_cnt    <= 0;
                axi1_if.wready  <= 1'b1;
                axi1_if.awready <= 1'b0;

                // sim-time check: AW size must be within lane width (i.e. <= BYTE_PER_WORD)
                `ifndef SYNTHESIS
                    // max allowed size_field is clog2(BYTE_PER_WORD)
                    if (p1_awsize > $clog2(BYTE_PER_WORD)) begin
                        $error("%0t: [axi_mm_dual_port_bram] p1 AW size (%0d) > max (%0d).", $time, p1_awsize, $clog2(BYTE_PER_WORD));
                    end
                `endif
            end

            // ---- W beat capture (Port1) into local pending buffer ----
            if (p1_aw_active) begin
                if (axi1_if.wvalid && axi1_if.wready) begin
                    logic is_last_now;
                    logic [ADDR_WIDTH-1:0] beat_addr;
                    is_last_now = axi1_if.wlast || (p1_wbeat_cnt == p1_awlen);

                    if (p1_awburst == 2'b10) beat_addr = compute_wrap_addr(p1_awaddr, p1_awsize, p1_awlen, p1_wbeat_cnt);
                    else if (p1_awburst == 2'b01) beat_addr = compute_incr_addr(p1_awaddr, p1_awsize, p1_wbeat_cnt);
                    else beat_addr = p1_awaddr;

                    // latch locally in core domain and mark local pending
                    p1_local_wr_byte_addr <= beat_addr;
                    p1_local_wr_wdata     <= axi1_if.wdata;
                    p1_local_wr_wstrb     <= axi1_if.wstrb;
                    p1_local_wr_size      <= p1_awsize;  // latch awsize here
                    p1_local_wr_is_last   <= is_last_now;
                    p1_local_wr_req       <= 1'b1;
                    p1_wbeat_cnt          <= p1_wbeat_cnt + 1;

                    if (is_last_now) begin
                        p1_bid    <= p1_awid;
                        p1_bresp  <= 2'b00;
                        p1_bvalid <= 1'b1;
                        p1_aw_active <= 1'b0;
                    end

                    `ifndef SYNTHESIS
                        // sim checks: wstrb shouldn't be all zero for a valid write beat
                        if (axi1_if.wstrb == '0) begin
                            $error("%0t: [axi_mm_dual_port_bram] p1 write beat with zero WSTRB at addr 0x%0h", $time, beat_addr);
                        end
                    `endif
                end

                axi1_if.wready <= 1'b1;
            end
            else begin
                axi1_if.wready <= 1'b0;
            end

            // B channel drive (core domain only)
            if (p1_bvalid) begin
                axi1_if.bvalid <= 1'b1;
                axi1_if.bresp  <= p1_bresp;
                axi1_if.bid    <= p1_bid;
                if (axi1_if.bready) begin
                    p1_bvalid       <= 1'b0;
                    axi1_if.bvalid  <= 1'b0;
                    axi1_if.awready <= 1'b1;
                end
            end else axi1_if.bvalid <= 1'b0;

            if (!p1_aw_active) axi1_if.wready <= 1'b0;

            // AR / read capture (core domain)
            if (axi1_if.arready && axi1_if.arvalid) begin
                p1_arid         <= axi1_if.arid;
                p1_araddr       <= axi1_if.araddr;
                p1_arlen        <= axi1_if.arlen;
                p1_arsize       <= axi1_if.arsize;
                p1_arburst      <= axi1_if.arburst;
                p1_ar_active    <= 1'b1;
                p1_rbeat_cnt    <= 0;
                axi1_if.arready <= 1'b0;
            end

            if (p1_ar_active && !p1_rvalid) begin
                automatic logic [ADDR_WIDTH-1:0] beat_addr;
                automatic logic [ADDR_IDX_W-1:0] aligned_byte;

                p1_rid    <= p1_arid;
                p1_rvalid <= 1'b1;
                p1_rlast  <= (p1_rbeat_cnt == p1_arlen);

                // Calculate beat addrress
                if      (p1_arburst == 2'b10) beat_addr = compute_wrap_addr(p1_araddr,p1_arsize,p1_arlen,p1_rbeat_cnt);
                else if (p1_arburst == 2'b01) beat_addr = compute_incr_addr(p1_araddr,p1_arsize,p1_rbeat_cnt);
                else                          beat_addr = p1_araddr;

                aligned_byte = byte_index( beat_addr - (beat_addr % BYTE_PER_WORD) );

                for (int i=0;i<BYTE_PER_WORD;i++) begin
                    p1_rdata[8*i +:8] <= mem_byte[ aligned_byte + i ];
                end
            end
            
            // Output R channel
            axi1_if.rvalid <= p1_rvalid;
            axi1_if.rdata  <= p1_rdata;
            axi1_if.rresp  <= 2'b00;
            axi1_if.rid    <= p1_rid;
            axi1_if.rlast  <= p1_rlast;

            // RREADY handshake
            if (p1_rvalid && axi1_if.rready) begin
                p1_rvalid <= 1'b0;
                if (p1_rlast) begin
                    p1_ar_active <= 1'b0;
                    axi1_if.arready <= 1'b1;
                end
                else begin
                    p1_rbeat_cnt <= p1_rbeat_cnt + 1;
                end
            end

            // -------------------------
            // Bridge handshake logic (core side)
            // - prepare bridge when local pending and previous request accepted
            // - use toggles for handshake
            // -------------------------
            // synchronize ack toggle back into core domain
            p1_ack_toggle_sync1_core <= p1_ack_toggle_dma;
            p1_ack_toggle_sync2_core <= p1_ack_toggle_sync1_core;

            // detect ack edge in core domain
            if (p1_ack_toggle_sync2_core != p1_ack_toggle_last_seen_core) begin
                p1_ack_toggle_last_seen_core <= p1_ack_toggle_sync2_core;
                p1_bridge_accepted_core      <= 1'b1;
            end else begin
                p1_bridge_accepted_core      <= 1'b0;
            end

            // if we have a local pending beat and bridge is free, present data on bridge and toggle req.
            // require that previous request was accepted (i.e., last_seen matches ack_sync)
            if (p1_local_wr_req && !p1_bridge_accepted_core && (p1_req_toggle_core == p1_ack_toggle_sync2_core)) begin
                bridge_p1_addr_core    <= p1_local_wr_byte_addr;
                bridge_p1_wdata_core   <= p1_local_wr_wdata;
                bridge_p1_wstrb_core   <= p1_local_wr_wstrb;
                bridge_p1_is_last_core <= p1_local_wr_is_last;
                bridge_p1_size_core    <= p1_local_wr_size;
                // toggle request to indicate new data
                p1_req_toggle_core     <= ~p1_req_toggle_core;
            end

            // when ack observed, clear local pending (core can accept next beat)
            if (p1_bridge_accepted_core) begin
                p1_local_wr_req <= 1'b0;
                if (p1_aw_active) axi1_if.wready <= 1'b1;
            end
        end
    end // always_ff core-side FSM + bridge

    // -------------------------
    // Synchronize p1_req_toggle into dma domain and capture bridge into staged registers
    // -------------------------
    always_ff @(posedge dma_clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin
            p1_req_toggle_sync1_dma     <= 1'b0;
            p1_req_toggle_sync2_dma     <= 1'b0;
            p1_req_toggle_last_seen_dma <= 1'b0;
            staged_p1_valid_dma         <= 1'b0;
            staged_p1_addr_dma          <= '0;
            staged_p1_wdata_dma         <= '0;
            staged_p1_wstrb_dma         <= '0;
            staged_p1_is_last_dma       <= 1'b0;
            staged_p1_size_dma          <= '0;
            p1_ack_toggle_dma           <= 1'b0;

            // starvation init
            staged_p1_starve_cnt        <= 32'd0;
            staged_p1_starve_asserted   <= 1'b0;
        end else begin
            // sync the toggle (double flop)
            p1_req_toggle_sync1_dma     <= p1_req_toggle_core;
            p1_req_toggle_sync2_dma     <= p1_req_toggle_sync1_dma;

            // detect edge (new request)
            if ((p1_req_toggle_sync2_dma != p1_req_toggle_last_seen_dma) && !staged_p1_valid_dma) begin
                // capture bridge data (bridge_p1_* are stable until ack)
                staged_p1_addr_dma    <= bridge_p1_addr_core;
                staged_p1_wdata_dma   <= bridge_p1_wdata_core;
                staged_p1_wstrb_dma   <= bridge_p1_wstrb_core;
                staged_p1_is_last_dma <= bridge_p1_is_last_core;
                staged_p1_size_dma    <= bridge_p1_size_core;
                staged_p1_valid_dma   <= 1'b1;
                // remember we've seen this toggle
                p1_req_toggle_last_seen_dma <= p1_req_toggle_sync2_dma;
                // issue ack toggle back to core
                p1_ack_toggle_dma <= ~p1_ack_toggle_dma;

                `ifndef SYNTHESIS
                    // sanity check for captured staged fields
                    if (staged_p1_wstrb_dma == '0) begin
                        $warning("%0t: [axi_mm_dual_port_bram] captured staged p1 with zero WSTRB at addr 0x%0h", $time, bridge_p1_addr_core);
                    end
                `endif
            end
            // staged_p1_valid_dma will be cleared by Memory Core when consumed

            // initialize starvation detector counters (if they weren't initialized above)
            // (note: primary starvation logic lives in Memory Core always_ff below)
        end
    end

    // -------------------------
    // Port0 FSM (dma domain) - AW/W/AR/R capture and staging
    // -------------------------
    always_ff @(posedge dma_clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin
            // reset dma-side outputs / state
            axi0_if.awready <= 1'b1;
            axi0_if.wready  <= 1'b0;
            axi0_if.bvalid  <= 1'b0;
            axi0_if.bresp   <= 2'b00;
            axi0_if.bid     <= '0;
            axi0_if.arready <= 1'b1;
            axi0_if.rvalid  <= 1'b0;
            axi0_if.rdata   <= '0;
            axi0_if.rresp   <= 2'b00;
            axi0_if.rid     <= '0;
            axi0_if.rlast   <= 1'b0;

            p0_aw_active    <= 1'b0;
            p0_wbeat_cnt    <= 0;
            p0_wr_req       <= 1'b0;
            p0_bvalid       <= 1'b0;

            p0_ar_active    <= 1'b0;
            p0_rbeat_cnt    <= 0;
            p0_rvalid       <= 1'b0;
            p0_rlast        <= 1'b0;
            p0_wr_size      <= '0;
        end else begin
            // AW capture
            if (axi0_if.awready && axi0_if.awvalid) begin
                p0_awid         <= axi0_if.awid;
                p0_awaddr       <= axi0_if.awaddr;
                p0_awlen        <= axi0_if.awlen;
                p0_awsize       <= axi0_if.awsize;
                p0_awburst      <= axi0_if.awburst;
                p0_aw_active    <= 1'b1;
                p0_wbeat_cnt    <= 0;

                axi0_if.awready <= 1'b0;
                axi0_if.wready  <= 1'b1;

                `ifndef SYNTHESIS
                    if (p0_awsize > $clog2(BYTE_PER_WORD)) begin
                        $error("%0t: [axi_mm_dual_port_bram] p0 AW size (%0d) > max (%0d).", $time, p0_awsize, $clog2(BYTE_PER_WORD));
                    end
                `endif
            end

            // W beat accept (dma domain)
            if (p0_aw_active) begin
                if (axi0_if.wvalid && axi0_if.wready) begin
                    logic is_last_now;
                    logic [ADDR_WIDTH-1:0] beat_addr;
                    is_last_now = axi0_if.wlast || (p0_wbeat_cnt == p0_awlen);

                    if      (p0_awburst == 2'b10) beat_addr = compute_wrap_addr(p0_awaddr, p0_awsize, p0_awlen, p0_wbeat_cnt);
                    else if (p0_awburst == 2'b01) beat_addr = compute_incr_addr(p0_awaddr, p0_awsize, p0_wbeat_cnt);
                    else                          beat_addr = p0_awaddr;

                    // latch write beat into dma-side pending buffer (visible to Memory Core)
                    p0_wr_byte_addr <= beat_addr;
                    p0_wr_wdata     <= axi0_if.wdata;
                    p0_wr_wstrb     <= axi0_if.wstrb;
                    p0_wr_size      <= p0_awsize;   // latch awsize into pending buffer
                    p0_wr_is_last   <= is_last_now;
                    p0_wr_req       <= 1'b1;
                    p0_wbeat_cnt    <= p0_wbeat_cnt + 1;

                    // B channel
                    if (is_last_now) begin
                        p0_bid       <= p0_awid;
                        p0_bresp     <= 2'b00;
                        p0_bvalid    <= 1'b1;
                        p0_aw_active <= 1'b0;
                    end

                    `ifndef SYNTHESIS
                        if (axi0_if.wstrb == '0) begin
                            $error("%0t: [axi_mm_dual_port_bram] p0 write beat with zero WSTRB at addr 0x%0h", $time, beat_addr);
                        end
                    `endif
                end

                // take W ready low until Memory Core consumes p0_wr_req
                axi0_if.wready <= 1'b1;
            end
            else begin
                axi0_if.wready <= 1'b0;
            end

            // B channel drive (dma domain)
            if (p0_bvalid) begin
                axi0_if.bvalid <= 1'b1;
                axi0_if.bresp  <= p0_bresp;
                axi0_if.bid    <= p0_bid;
                if (axi0_if.bready) begin
                    p0_bvalid       <= 1'b0;
                    axi0_if.bvalid  <= 1'b0;
                    axi0_if.awready <= 1'b1;  // Next AW can start
                end
            end else axi0_if.bvalid <= 1'b0;

            // AR / read capture (dma domain)
            if (axi0_if.arready && axi0_if.arvalid) begin
                p0_arid         <= axi0_if.arid;
                p0_araddr       <= axi0_if.araddr;
                p0_arlen        <= axi0_if.arlen;
                p0_arsize       <= axi0_if.arsize;
                p0_arburst      <= axi0_if.arburst;
                p0_ar_active    <= 1'b1;
                p0_rbeat_cnt    <= 0;
                axi0_if.arready <= 1'b0;
            end

            // prepare rdata (assembly handled separately)
            if (p0_ar_active && !p0_rvalid) begin
                automatic logic [ADDR_WIDTH-1:0] beat_addr;

                p0_rid    <= p0_arid;
                p0_rvalid <= 1'b1;
                p0_rlast  <= (p0_rbeat_cnt == p0_arlen);

                // Calculate beat address
                if      (p0_arburst == 2'b10) beat_addr = compute_wrap_addr(p0_araddr, p0_arsize, p0_arlen, p0_rbeat_cnt);
                else if (p0_arburst == 2'b01) beat_addr = compute_incr_addr(p0_araddr, p0_arsize, p0_rbeat_cnt);
                else                          beat_addr = p0_araddr;

                // latch memory content
                for (int i=0; i<BYTE_PER_WORD; i++) begin
                    p0_rdata[8*i +:8] <= mem_byte[ beat_addr + i ];
                end
            end

            // Output R channel
            axi0_if.rvalid <= p0_rvalid;
            axi0_if.rdata  <= p0_rdata;
            axi0_if.rresp  <= 2'b00;
            axi0_if.rid    <= p0_rid;
            axi0_if.rlast  <= p0_rlast;

            // RREADY handshake
            if (p0_rvalid && axi0_if.rready) begin
                p0_rvalid <= 1'b0;
                if (p0_rlast) begin
                    p0_ar_active <= 1'b0;
                    axi0_if.arready <= 1'b1;
                end 
                else begin
                    p0_rbeat_cnt <= p0_rbeat_cnt + 1;
                end
            end
        end
    end // always_ff p0 FSM

    // -------------------------
    // Read data assembly (NO forwarding)
    // - p0 read assembly in dma_clk domain
    // - p1 read assembly in core_clk domain
    // Both simply read mem_byte[] (aligned to beat word)
    // -------------------------
    // dma domain read assembly (p0)
    always_ff @(posedge dma_clk or negedge dma_rst_n) begin

        automatic logic [ADDR_WIDTH-1:0] beat_addr;
        automatic logic [ADDR_IDX_W-1:0] aligned_byte;

        if (!dma_rst_n) begin
            p0_rdata <= '0;
        end else begin
            if (p0_ar_active) begin
                if      (p0_arburst == 2'b10) beat_addr = compute_wrap_addr(p0_araddr, p0_arsize, p0_arlen, p0_rbeat_cnt);
                else if (p0_arburst == 2'b01) beat_addr = compute_incr_addr(p0_araddr, p0_arsize, p0_rbeat_cnt);
                else                          beat_addr = p0_araddr;

                aligned_byte = byte_index( beat_addr - (beat_addr % BYTE_PER_WORD) );

                for (int i = 0; i < BYTE_PER_WORD; i++) begin
                    p0_rdata[8*i +: 8] <= mem_byte[ aligned_byte + i ];
                end
            end
        end
    end

    // core domain read assembly (p1)
    always_ff @(posedge core_clk or negedge core_rst_n) begin

        automatic logic [ADDR_WIDTH-1:0] beat_addr;
        automatic logic [ADDR_IDX_W-1:0] aligned_byte;

        if (!core_rst_n) begin
            p1_rdata <= '0;
        end else begin
            if (p1_ar_active) begin
                if      (p1_arburst == 2'b10) beat_addr = compute_wrap_addr(p1_araddr, p1_arsize, p1_arlen, p1_rbeat_cnt);
                else if (p1_arburst == 2'b01) beat_addr = compute_incr_addr(p1_araddr, p1_arsize, p1_rbeat_cnt);
                else                          beat_addr = p1_araddr;

                aligned_byte = byte_index( beat_addr - (beat_addr % BYTE_PER_WORD) );

                for (int i = 0; i < BYTE_PER_WORD; i++) begin
                    p1_rdata[8*i +: 8] <= mem_byte[ aligned_byte + i ];
                end
            end
        end
    end

    // -------------------------
    // Memory Core (single writer) - runs in dma_clk domain
    // - Arbitrates staged p1 request (staged_p1_valid_dma) vs local p0_wr_req
    // - Port0 has priority; if both present, p0 is serviced. If only p1 staged, service it.
    // - Only this always_ff writes mem_byte[].
    // - Starvation detector integrated here (dma domain only) to avoid CDC
    // -------------------------
    always_ff @(posedge dma_clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin
            staged_p1_valid_dma <= 1'b0;
            p0_wr_req           <= 1'b0;
            p1_ack_toggle_dma   <= 1'b0;
            staged_p1_size_dma  <= '0;

            // starve
            staged_p1_starve_cnt      <= 32'd0;
            staged_p1_starve_asserted <= 1'b0;
        end else begin
            // Default: clear starve assertion only via reset (or keep latched)
            // Commit logic
            if (p0_wr_req) begin
                // commit p0 write
                automatic int                    off0;
                automatic logic [ADDR_IDX_W-1:0] base0;
                automatic int                    bytes;


                off0  = p0_wr_byte_addr % BYTE_PER_WORD;
                base0 = byte_index(p0_wr_byte_addr - off0);
                bytes = size_to_bytes(p0_wr_size);

                `ifndef SYNTHESIS
                    // sanity check: ensure base0 is in range (if master uses addresses within range)
                    if (base0 >= MEM_BYTES) begin
                        $error("%0t: [axi_mm_dual_port_bram] p0 base write index out of range: base0=%0d MEM_BYTES=%0d", $time, base0, MEM_BYTES);
                    end
                `endif

                // write lanes: iterate bytes in beat and map to WDATA/WSTRB lanes using strobe_lane
                for (int b = 0; b < bytes; b++) begin
                    automatic logic [ADDR_IDX_W-1:0] mem_idx;
                    automatic int                    strobe_lane;

                    mem_idx     = byte_index(p0_wr_byte_addr + b);
                    strobe_lane = (off0 + b) % BYTE_PER_WORD; 

                    if (mem_idx < MEM_BYTES) begin
                        if (p0_wr_wstrb[strobe_lane]) begin
                            // lane strobe_lane maps to bits [8*strobe_lane +:8] per little-endian convention
                            mem_byte[mem_idx] <= p0_wr_wdata[8*strobe_lane +: 8];
                        end
                    end
                end

                // consume p0 request and re-enable its WREADY
                p0_wr_req <= 1'b0;
                if (p0_aw_active) axi0_if.wready <= 1'b1;
                if (p0_wr_is_last) begin
                    p0_aw_active    <= 1'b0;
                    axi0_if.awready <= 1'b1;
                end

                // starvation handling: p0 took this cycle -> if staged exists, this counts as one starve tick
                if (staged_p1_valid_dma) begin
                    if (staged_p1_starve_cnt < 32'hFFFFFFFF) staged_p1_starve_cnt <= staged_p1_starve_cnt + 1;
                end else begin
                    // no staged -> reset starve counter
                    staged_p1_starve_cnt <= 32'd0;
                end

            end else if (staged_p1_valid_dma) begin
                // commit staged p1 write (no p0 request)
                automatic int                    off1;
                automatic logic [ADDR_IDX_W-1:0] base1;
                automatic int                    bytes1;


                off1   = staged_p1_addr_dma % BYTE_PER_WORD;
                base1  = byte_index(staged_p1_addr_dma - off1);
                bytes1 = size_to_bytes(staged_p1_size_dma);

                `ifndef SYNTHESIS
                    if (base1 >= MEM_BYTES) begin
                        $error("%0t: [axi_mm_dual_port_bram] staged p1 base write index out of range: base1=%0d MEM_BYTES=%0d", $time, base1, MEM_BYTES);
                    end
                `endif

                for (int b = 0; b < bytes1; b++) begin
                    automatic logic [ADDR_IDX_W-1:0] mem_idx;
                    automatic int                    strobe_lane;

                    mem_idx     = byte_index(staged_p1_addr_dma + b);
                    strobe_lane = (off1 + b) % BYTE_PER_WORD;
                    
                    if (mem_idx < MEM_BYTES) begin
                        if (staged_p1_wstrb_dma[strobe_lane]) begin
                            mem_byte[mem_idx] <= staged_p1_wdata_dma[8*strobe_lane +: 8];
                        end
                    end
                end

                // clear staged flag (consumed)
                staged_p1_valid_dma <= 1'b0;

                // consuming staged -> reset starvation counter
                staged_p1_starve_cnt <= 32'd0;
            end else begin
                // nothing to write this cycle -> clear starve counter
                staged_p1_starve_cnt <= 32'd0;
            end

            // Starvation detector: assert/warn if threshold crossed
            if (ASSERT_ON_STARVE && (staged_p1_starve_cnt >= STARVE_THRESHOLD)) begin
                if (!staged_p1_starve_asserted) begin
                    staged_p1_starve_asserted <= 1'b1;
                    `ifndef SYNTHESIS
                        $warning("%0t: [axi_mm_dual_port_bram] staged_p1 starvation detected: cnt=%0d threshold=%0d",
                                 $time, staged_p1_starve_cnt, STARVE_THRESHOLD);
                    `endif
                end
                // Note: we keep asserted latched; could optionally force other status outputs here
            end
        end
    end // always_ff memory core

    // -------------------------
    // (End of module)
    // -------------------------
endmodule
