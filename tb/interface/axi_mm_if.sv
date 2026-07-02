// File: tb/interface/axi_mm_if.sv
`ifndef AXI_MM_IF_SV
`define AXI_MM_IF_SV
`timescale 1ns/1ps

interface axi_mm_if #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 64,
    parameter int ID_WIDTH   = 4,
    parameter bit HAS_BURST  = 1
)(
    input  logic clk,
    input  logic rst_n
);

    // ------------------------------------------------------------
    // Local parameters
    // ------------------------------------------------------------
    localparam int IDW   = (ID_WIDTH > 0) ? ID_WIDTH : 1;
    localparam int BYTES = DATA_WIDTH / 8;

    // ------------------------------------------------------------
    // AXI signals
    // ------------------------------------------------------------
    // Write address
    logic [IDW-1:0]        awid;
    logic [ADDR_WIDTH-1:0] awaddr;
    logic [7:0]            awlen;
    logic [2:0]            awsize;
    logic [1:0]            awburst;
    logic                  awvalid;
    logic                  awready;

    // Write data
    logic [DATA_WIDTH-1:0]   wdata;
    logic [DATA_WIDTH/8-1:0] wstrb;
    logic                    wlast;
    logic                    wvalid;
    logic                    wready;

    // Write response
    logic [IDW-1:0] bid;
    logic [1:0]     bresp;
    logic           bvalid;
    logic           bready;

    // Read address
    logic [IDW-1:0]        arid;
    logic [ADDR_WIDTH-1:0] araddr;
    logic [7:0]            arlen;
    logic [2:0]            arsize;
    logic [1:0]            arburst;
    logic                  arvalid;
    logic                  arready;

    // Read data
    logic [IDW-1:0]        rid;
    logic [DATA_WIDTH-1:0] rdata;
    logic [1:0]            rresp;
    logic                  rlast;
    logic                  rvalid;
    logic                  rready;

    // ------------------------------------------------------------
    // Driver clocking block (MASTER)
    // - Samples request / response channels + rst_n
    // - Does not declare clocking outputs.
    //   Questa treats clocking outputs as implicit drivers even when the
    //   interface instance is used as an internal RTL link.  The UVM
    //   master driver therefore drives raw modport outputs and uses this
    //   clocking block only for synchronization / sampling.
    // ------------------------------------------------------------
    clocking cb_master @(posedge clk);
        default input #1step output #0;

        // Sample reset
        input rst_n;

        // Sample request channels driven by the UVM master raw modport
        // outputs.  Keeping these as inputs avoids an implicit clocking
        // block driver on every axi_mm_if instance.
        input awid, awaddr, awlen, awsize, awburst, awvalid;
        input wdata, wstrb, wlast, wvalid;
        input arid, araddr, arlen, arsize, arburst, arvalid;
        input bready, rready;

        // Sample slave response channels.
        input awready, wready;
        input bvalid, bresp, bid;
        input arready;
        input rvalid, rdata, rresp, rid, rlast;
    endclocking

    // ------------------------------------------------------------
    // Monitor clocking block
    // ------------------------------------------------------------
    clocking cb_monitor @(posedge clk);
        default input #1step;

        input rst_n;

        input awid, awaddr, awlen, awsize, awburst, awvalid, awready;
        input wdata, wstrb, wlast, wvalid, wready;
        input bvalid, bready, bresp, bid;

        input arid, araddr, arlen, arsize, arburst, arvalid, arready;
        input rvalid, rready, rdata, rresp, rid, rlast;
    endclocking

    // ------------------------------------------------------------
    // TB Driver (MASTER)
    // - Expose cb_master for synchronization / sampling
    // - Expose raw request signals as the only UVM master drivers
    // ------------------------------------------------------------
    modport mp_master (
        input  clk, rst_n,
        clocking cb_master,

        // raw signals (read/write) for driver convenience
        output awid, awaddr, awlen, awsize, awburst, awvalid,
        input  awready,

        output wdata, wstrb, wlast, wvalid,
        input  wready,

        input  bid, bresp, bvalid,
        output bready,

        output arid, araddr, arlen, arsize, arburst, arvalid,
        input  arready,

        input  rid, rdata, rresp, rlast, rvalid,
        output rready
    );

    // ------------------------------------------------------------
    // TB Monitor
    // - Expose cb_monitor for sampling
    // - Expose raw signals if monitor wants direct access
    // ------------------------------------------------------------
    modport mp_monitor (
        input  clk, rst_n,
        clocking cb_monitor,

        input awid, awaddr, awlen, awsize, awburst, awvalid, awready,
        input wdata, wstrb, wlast, wvalid, wready,
        input bvalid, bready, bresp, bid,
        input arid, araddr, arlen, arsize, arburst, arvalid, arready,
        input rvalid, rready, rdata, rresp, rid, rlast
    );

    // ------------------------------------------------------------
    // DUT (Slave)
    // ------------------------------------------------------------
    modport mp_slave (
        input  clk, rst_n,

        input  awid, awaddr, awlen, awsize, awburst, awvalid,
        input  wdata, wstrb, wlast, wvalid,
        input  arid, araddr, arlen, arsize, arburst, arvalid,
        input  bready, rready,

        output awready, wready,
        output bvalid, bresp, bid,
        output arready,
        output rvalid, rdata, rresp, rid, rlast
    );

endinterface : axi_mm_if

`endif