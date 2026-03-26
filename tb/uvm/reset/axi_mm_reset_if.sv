// File: tb/uvm/reset/axi_mm_reset_if.sv

// =========================================================================
// Reset Interface for UVM testbench
// - TB-owned reset
// - Designed to work with reset_agent + global uvm_event
// - Separate clocking blocks for driver/monitor to avoid direction issues
// =========================================================================

`ifndef AXI_MM_RESET_IF_SV
`define AXI_MM_RESET_IF_SV

`timescale 1ns/1ps

interface axi_mm_reset_if (
    input logic clk
);

    // Reset signal
    logic rst_n = 1'b0;

    // -------------------------------------------------------------------------
    // Clocking blocks
    //   - cb_drv: reset_driver drives rst_n
    //   - cb_mon: reset_monitor samples rst_n
    // -------------------------------------------------------------------------
    // Driver clocking block
    clocking cb_drv @(posedge clk);
        default input #1step output #0;
        output rst_n;
    endclocking

    // Monitor clocking block
    clocking cb_mon @(posedge clk);
        default input #1step output #0;
        input  rst_n;
    endclocking

    // -------------------------------------------------------------------------
    // Modports
    // -------------------------------------------------------------------------
    // Reset driver
    modport mp_driver (
        clocking cb_drv,
        input  clk
    );

    // Reset monitor
    modport mp_monitor (
        clocking cb_mon,
        input  clk
    );

endinterface : axi_mm_reset_if

`endif