// File: tb/axi_mm_top.sv
`timescale 1ns/1ps

`include "../interface/axi_mm_if.sv"
`include "../reset/axi_mm_reset_if.sv"
`include "../commit/axi_mm_commit_if.sv"
`include "../commit/axi_mm_apply_if.sv"

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

module axi_mm_top;

    // ------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------
    logic dma_clk;
    logic core_clk;

    // ------------------------------------------------------------
    // Reset
    // ------------------------------------------------------------
    logic rst_n;

    //-------------------------------------------------------------
    // Internal
    //-------------------------------------------------------------
    logic ce_idle;

    //-------------------------------------------------------------
    // Interfaces
    //-------------------------------------------------------------
    // Reset interface
    axi_mm_reset_if reset_if_i (
        .clk (dma_clk)
    );

    // Export reset_if's rst_n as top-level rst_n
    assign rst_n = reset_if_i.rst_n;

    // AXI-MM interfaces
    axi_mm_if  #(32, 64, 4, 1) dma_if  (dma_clk,  rst_n);
    axi_mm_if  #(32, 64, 4, 1) core_if (core_clk, rst_n);

    // Apply interface (dma_clk domain)
    axi_mm_apply_if #(32, 64, 4, 8) apply_if_i (
        .clk   (dma_clk),
        .rst_n (rst_n)
    );

    // Commit interface (dma_clk domain)
    axi_mm_commit_if #(32, 64, 4, 8) commit_if_i (
        .clk   (dma_clk),
        .rst_n (rst_n)
    );

    //-------------------------------------------------------------
    // AXI Slave selection
    //-------------------------------------------------------------
`ifdef USE_DUMMY_SLAVE

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

    axi_mm_dual_port_bram #(
        .ADDR_WIDTH       (32),
        .DATA_WIDTH       (64),
        .ID_WIDTH         (4),
        .DEPTH_WORDS      (1024),

        .RD_FIFO_DEPTH    (16),

        .WR_AW_DEPTH      (4),
        .WR_B_DEPTH       (8),

        .STARVE_THRESHOLD (2000),
        .ASSERT_ON_STARVE (1)
    ) dut (
        .dma_clk    (dma_clk),
        .dma_rst_n  (rst_n),
        .core_clk   (core_clk),
        .core_rst_n (rst_n),

        .axi0_if    (dma_if),
        .axi1_if    (core_if),

        .apply_if   (apply_if_i.mp_producer),
        .commit_if  (commit_if_i.mp_producer),
        .ce_idle    (ce_idle)
    );

`endif

    // ------------------------------------------------------------
    // Clock generation
    //-------------------------------------------------------------
    initial begin
        dma_clk  = 1'b0;
        core_clk = 1'b0;
    end

    always #5  dma_clk  = ~dma_clk;   // 100 MHz
    always #8  core_clk = ~core_clk;  // 62.5 MHz

    //-------------------------------------------------------------
    // UVM
    //-------------------------------------------------------------
    initial begin
        $dumpfile("axi_mm_top.vcd");
        $dumpvars(0, axi_mm_top);

        // ---------------------------------------------------------
        // AXI agents
        // ---------------------------------------------------------
        uvm_config_db#(virtual axi_mm_if#(32,64,4,1).mp_master )::set(null, "*.p0_agent", "vif_m",   dma_if.mp_master);
        uvm_config_db#(virtual axi_mm_if#(32,64,4,1).mp_monitor)::set(null, "*.p0_agent", "vif_mon", dma_if.mp_monitor);

        uvm_config_db#(virtual axi_mm_if#(32,64,4,1).mp_master )::set(null, "*.p1_agent", "vif_m",   core_if.mp_master);
        uvm_config_db#(virtual axi_mm_if#(32,64,4,1).mp_monitor)::set(null, "*.p1_agent", "vif_mon", core_if.mp_monitor);

        // ---------------------------------------------------------
        // Reset agent
        // ---------------------------------------------------------
        uvm_config_db#(virtual axi_mm_reset_if.mp_driver )::set(null, "*.rst_agent", "vif_drv", reset_if_i.mp_driver);
        uvm_config_db#(virtual axi_mm_reset_if.mp_monitor)::set(null, "*.rst_agent", "vif_mon", reset_if_i.mp_monitor);

        uvm_config_db#(virtual axi_mm_reset_if.mp_driver )::set(null, "*.rst_agent.drv", "vif", reset_if_i.mp_driver);
        uvm_config_db#(virtual axi_mm_reset_if.mp_monitor)::set(null, "*.rst_agent.mon", "vif", reset_if_i.mp_monitor);

        // ---------------------------------------------------------
        // Commit monitor
        // ---------------------------------------------------------
        uvm_config_db#(virtual axi_mm_commit_if#(32,64,4,8).mp_monitor)::set(null, "*.commit_mon", "vif", commit_if_i.mp_monitor);

        // ---------------------------------------------------------
        // Apply monitor
        // ---------------------------------------------------------
        uvm_config_db#(virtual axi_mm_apply_if#(32,64,4,8).mp_monitor)::set(null, "*.apply_mon", "vif", apply_if_i.mp_monitor);

        // ---------------------------------------------------------
        // Run test
        // - axi_mm_smoke_test, axi_mm_directed_test, axi_mm_random_test, axi_mm_corner_test, axi_mm_coverage_test
        // ---------------------------------------------------------
        run_test("axi_mm_coverage_test");
    end

endmodule