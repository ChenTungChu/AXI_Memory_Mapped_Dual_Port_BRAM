`timescale 1ns/1ps

`include "../interface/axi_mm_if.sv"

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

module axi_mm_top;

    //------------------------------------------------------------
    // Clock / Reset
    //------------------------------------------------------------
    logic dma_clk;
    logic core_clk;
    logic rst_n;

    //------------------------------------------------------------
    // AXI-MM interfaces
    //------------------------------------------------------------
    axi_mm_if #(32, 64, 4, 1) dma_if  (dma_clk,  rst_n);
    axi_mm_if #(32, 64, 4, 1) core_if (core_clk, rst_n);

    //------------------------------------------------------------
    // AXI Slave selection
    //------------------------------------------------------------
`ifdef USE_DUMMY_SLAVE

    // ---------------- Dummy slave ----------------
    axi_mm_dummy_slave #(
        .ADDR_WIDTH(32),
        .DATA_WIDTH(64),
        .ID_WIDTH(4)
    ) dummy_p0 (
        .clk   (dma_clk),
        .rst_n (rst_n),
        .axi_if(dma_if)
    );

    axi_mm_dummy_slave #(
        .ADDR_WIDTH(32),
        .DATA_WIDTH(64),
        .ID_WIDTH(4)
    ) dummy_p1 (
        .clk   (core_clk),
        .rst_n (rst_n),
        .axi_if(core_if)
    );

`else

    // ---------------- Real DUT ----------------
    axi_mm_dual_port_bram #(
        .ADDR_WIDTH (32),
        .DATA_WIDTH (64),
        .ID_WIDTH   (4),
        .DEPTH_WORDS(1024)
    ) dut (
        .dma_clk   (dma_clk),
        .dma_rst_n (rst_n),
        .axi0_if   (dma_if),

        .core_clk  (core_clk),
        .core_rst_n(rst_n),
        .axi1_if   (core_if)
    );

`endif

    //------------------------------------------------------------
    // Clock generation
    //------------------------------------------------------------
    initial begin
        dma_clk  = 0;
        core_clk = 0;
    end

    always #5  dma_clk  = ~dma_clk;
    always #8  core_clk = ~core_clk;

    //------------------------------------------------------------
    // Reset
    //------------------------------------------------------------
    initial begin
        rst_n = 0;
        #50;
        rst_n = 1;
    end

    //------------------------------------------------------------
    // UVM
    //------------------------------------------------------------
    initial begin
        $dumpfile("axi_mm_top.vcd");
        $dumpvars(0, axi_mm_top);

        // UVM master sees master modport
        uvm_config_db#(virtual axi_mm_if)::set(null, "*.p0_agent", "vif", dma_if.mp_master);
        uvm_config_db#(virtual axi_mm_if)::set(null, "*.p1_agent", "vif", core_if.mp_master);

        run_test();
    end

endmodule
