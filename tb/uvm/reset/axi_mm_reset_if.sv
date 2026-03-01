//------------------------------------------------------------------------------
// File: tb/interface/reset_if.sv
// Reset Interface for UVM Testbench
// - TB-owned reset (not DUT-generated)
// - Designed to work with reset_agent + global uvm_event
// - Robust: separate clocking blocks for driver/monitor to avoid direction issues
//------------------------------------------------------------------------------

`ifndef AXI_MM_RESET_IF_SV
`define AXI_MM_RESET_IF_SV

`timescale 1ns/1ps

interface axi_mm_reset_if (
    input logic clk
);

    // -------------------------------------------------------------------------
    // Reset signal (active-low)
    // Default asserted at time 0 for safety.
    // -------------------------------------------------------------------------
    logic rst_n = 1'b0;

    // -------------------------------------------------------------------------
    // Clocking blocks
    //   - cb_drv: reset_driver drives rst_n
    //   - cb_mon: reset_monitor samples rst_n
    //
    // IMPORTANT:
    //   Do NOT share a single clocking block with rst_n declared as "output"
    //   for both driver and monitor. That can make monitor able to drive rst_n
    //   and can trigger subtle race/permission issues.
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

    // Reset driver (TB control)
    modport mp_driver (
        clocking cb_drv,
        input  clk
    );

    // Reset monitor (observe only)
    modport mp_monitor (
        clocking cb_mon,
        input  clk
    );

endinterface : axi_mm_reset_if

`endif