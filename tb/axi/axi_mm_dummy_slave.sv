// File: tb/axi/axi_mm_dummy_slave.sv
module axi_mm_dummy_slave #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 64,
    parameter int ID_WIDTH   = 4,
    parameter bit HAS_BURST  = 1
)(
    input  logic clk,
    input  logic rst_n,
    axi_mm_if axi_if
);

    localparam int IDW = (ID_WIDTH > 0) ? ID_WIDTH : 1;

    // Always ready on address/data channels
    assign axi_if.awready = 1'b1;
    assign axi_if.wready  = 1'b1;
    assign axi_if.arready = 1'b1;

    // --------------------------------------------------------
    // WRITE tracking
    // --------------------------------------------------------
    logic           wr_inflight;
    logic [IDW-1:0] wr_id;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_inflight  <= 1'b0;
            wr_id        <= '0;

            axi_if.bvalid <= 1'b0;
            axi_if.bid    <= '0;
            axi_if.bresp  <= 2'b00;
        end else begin
            // Capture AW once per transaction
            if (!wr_inflight && axi_if.awvalid && axi_if.awready) begin
                wr_inflight <= 1'b1;
                wr_id       <= axi_if.awid;
            end

            // When last W beat handshakes -> generate BVALID
            if (wr_inflight &&
                axi_if.wvalid && axi_if.wready && axi_if.wlast &&
                !axi_if.bvalid) begin
                axi_if.bvalid <= 1'b1;
                axi_if.bid    <= wr_id;
                axi_if.bresp  <= 2'b00;
            end

            // Complete response
            if (axi_if.bvalid && axi_if.bready) begin
                axi_if.bvalid <= 1'b0;
                wr_inflight   <= 1'b0; // allow next write
            end
        end
    end

    // --------------------------------------------------------
    // READ response
    // --------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_if.rvalid <= 1'b0;
            axi_if.rid    <= '0;
            axi_if.rdata  <= '0;
            axi_if.rresp  <= 2'b00;
            axi_if.rlast  <= 1'b0;
        end else begin
            if (axi_if.arvalid && axi_if.arready && !axi_if.rvalid) begin
                axi_if.rvalid <= 1'b1;
                axi_if.rid    <= axi_if.arid;
                axi_if.rdata  <= 'hDEADBEEF;
                axi_if.rresp  <= 2'b00;
                axi_if.rlast  <= 1'b1;
            end else if (axi_if.rvalid && axi_if.rready) begin
                axi_if.rvalid <= 1'b0;
                axi_if.rlast  <= 1'b0;
            end
        end
    end

endmodule
