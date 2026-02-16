//------------------------------------------------------------------------------
// File: tb/interface/reset_if.sv
// Reset Interface for UVM Testbench
// - TB-owned reset (not DUT-generated)
// - Designed to work with reset_agent + uvm_event
// - Safe for synchronous or async-assert reset styles
//------------------------------------------------------------------------------

`timescale 1ns/1ps

interface axi_mm_reset_if (
    input logic clk
);

    // -------------------------------------------------------------------------
    // Reset signal
    // -------------------------------------------------------------------------
    logic rst_n = 1'b0;

    // -------------------------------------------------------------------------
    // Clocking block
    // - reset_agent / reset_driver drives rst_n
    // - monitor samples rst_n via this clocking block
    // -------------------------------------------------------------------------
    clocking cb @(posedge clk);
        default input #1step output #0;
        output rst_n;
    endclocking

    // -------------------------------------------------------------------------
    // Modports
    // -------------------------------------------------------------------------

    // Reset driver (TB control)
    modport mp_driver (
        clocking cb,
        input  clk
    );

    // Reset monitor
    modport mp_monitor (
        clocking cb,
        input  clk
    );

endinterface : axi_mm_reset_if
