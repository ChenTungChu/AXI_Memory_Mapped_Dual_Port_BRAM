// File: tb/axi_mm_top.sv
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
    // NOTE:
    // - To use this, you MUST compile the dummy slave file in compile.tcl:
    //   vlog -sv ../tb/axi/axi_mm_dummy_slave.sv
    //
    axi_mm_dummy_slave #(
        .ADDR_WIDTH(32),
        .DATA_WIDTH(64),
        .ID_WIDTH  (4)
    ) dummy_p0 (
        .clk   (dma_clk),
        .rst_n (rst_n),
        .axi_if(dma_if)
    );

    axi_mm_dummy_slave #(
        .ADDR_WIDTH(32),
        .DATA_WIDTH(64),
        .ID_WIDTH  (4)
    ) dummy_p1 (
        .clk   (core_clk),
        .rst_n (rst_n),
        .axi_if(core_if)
    );

`else

    // ---------------- DUT ----------------
    // IMPORTANT:
    // - RD_FIFO_DEPTH must be >= max burst beats you want to accept.
    // - Case 5.1 uses 8 beats, so set at least 8 (use 16 for margin).
    //
    axi_mm_dual_port_bram #(
        .ADDR_WIDTH    (32),
        .DATA_WIDTH    (64),
        .ID_WIDTH      (4),
        .DEPTH_WORDS   (1024),
        .RD_FIFO_DEPTH (16)
        // .STARVE_THRESHOLD(...), .ASSERT_ON_STARVE(...)  // optional
    ) dut (
        .dma_clk    (dma_clk),
        .dma_rst_n  (rst_n),
        .core_clk   (core_clk),
        .core_rst_n (rst_n),

        .axi0_if(dma_if),
        .axi1_if(core_if)
    );

`endif

    //------------------------------------------------------------
    // Clock generation
    //------------------------------------------------------------
    initial begin
        dma_clk  = 1'b0;
        core_clk = 1'b0;
    end

    always #5  dma_clk  = ~dma_clk;   // 100 MHz
    always #8  core_clk = ~core_clk;  // 62.5 MHz

    //------------------------------------------------------------
    // Reset
    //------------------------------------------------------------
    initial begin
        rst_n = 1'b0;
        #50;
        rst_n = 1'b1;
    end

    //------------------------------------------------------------
    // UVM
    //------------------------------------------------------------
    initial begin
        $dumpfile("axi_mm_top.vcd");
        $dumpvars(0, axi_mm_top);

        // p0 (dma_if)
        uvm_config_db#(virtual axi_mm_if#(32,64,4,1).mp_master )::set(null, "*.p0_agent", "vif_m",   dma_if.mp_master);
        uvm_config_db#(virtual axi_mm_if#(32,64,4,1).mp_monitor)::set(null, "*.p0_agent", "vif_mon", dma_if.mp_monitor);

        // p1 (core_if)
        uvm_config_db#(virtual axi_mm_if#(32,64,4,1).mp_master )::set(null, "*.p1_agent", "vif_m",   core_if.mp_master);
        uvm_config_db#(virtual axi_mm_if#(32,64,4,1).mp_monitor)::set(null, "*.p1_agent", "vif_mon", core_if.mp_monitor);

        run_test();
    end

endmodule
