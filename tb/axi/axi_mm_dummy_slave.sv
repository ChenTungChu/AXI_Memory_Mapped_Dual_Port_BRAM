module axi_mm_dummy_slave #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 64,
    parameter ID_WIDTH   = 4,
    parameter HAS_BURST  = 1
)(
    input  logic clk,
    input  logic rst_n,
    axi_mm_if axi_if
);

    // ----------------- Always ready -----------------
    assign axi_if.awready = 1'b1;
    assign axi_if.wready  = 1'b1;
    assign axi_if.arready = 1'b1;

    // ----------------- WRITE response -----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_if.bvalid <= 1'b0;
            axi_if.bid    <= '0;
            axi_if.bresp  <= 2'b00;
        end else begin
            if (axi_if.awvalid && axi_if.wvalid && !axi_if.bvalid) begin
                axi_if.bvalid <= 1'b1;
                axi_if.bid    <= axi_if.awid;
                axi_if.bresp  <= 2'b00; // OKAY
            end else if (axi_if.bvalid && axi_if.bready) begin
                axi_if.bvalid <= 1'b0;
            end
        end
    end

    // ----------------- READ response -----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_if.rvalid <= 1'b0;
            axi_if.rid    <= '0;
            axi_if.rdata  <= '0;
            axi_if.rresp  <= 2'b00;
            axi_if.rlast  <= 1'b0;
        end else begin
            if (axi_if.arvalid && !axi_if.rvalid) begin
                axi_if.rvalid <= 1'b1;
                axi_if.rid    <= axi_if.arid;
                axi_if.rdata  <= 'hDEADBEEF; // 固定值
                axi_if.rresp  <= 2'b00;
                axi_if.rlast  <= 1'b1;       // single beat
            end else if (axi_if.rvalid && axi_if.rready) begin
                axi_if.rvalid <= 1'b0;
                axi_if.rlast  <= 1'b0;
            end
        end
    end

endmodule
