// File: tb/uvm/seq/axi_mm_seq.sv
`ifndef AXI_MM_SEQ_SV
`define AXI_MM_SEQ_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

// ------------------------------------------------------------
// AXI MM sequence: supports RANDOM and DIRECTED modes
// ------------------------------------------------------------
class axi_mm_seq #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4
) extends uvm_sequence #(
    axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)
);

    `uvm_object_param_utils(axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

    // ============================================================
    // RANDOM MODE knobs (existing behavior)
    // ============================================================
    rand int unsigned num_transactions;   // number of AXI transactions
    rand int unsigned max_beats;           // max beats per burst (>=1)
    rand int unsigned read_percent;        // percentage of READs (0..100)
    rand bit          addr_aligned;        // align address to beat size

    constraint c_defaults {
        num_transactions inside {[1:1000]};
        max_beats        inside {[1:16]};
        read_percent    inside {[0:100]};
    }

    // ============================================================
    // DIRECTED MODE knobs
    // ============================================================
    bit                     directed_mode = 0;
    axi_rw_e                dir_rw;
    logic [ADDR_WIDTH-1:0]  dir_addr;
    logic [DATA_WIDTH-1:0]  dir_wdata;
    int unsigned            dir_beats = 1;
    logic [ID_WIDTH-1:0]    dir_id;
    logic [1:0]             dir_burst = 2'b01; // INCR
    logic [2:0]             dir_size  = $clog2(BYTES_PER_BEAT);

    localparam int BYTES_PER_BEAT = DATA_WIDTH / 8;

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------
    function new(string name = "axi_mm_seq");
        super.new(name);

        // sensible defaults (random mode)
        num_transactions = 1;
        max_beats        = 8;
        read_percent     = 50;
        addr_aligned     = 1'b1;
    endfunction

    // ------------------------------------------------------------
    // Helper: random DATA_WIDTH word
    // ------------------------------------------------------------
    function automatic logic [DATA_WIDTH-1:0] rand_data_word();
        logic [DATA_WIDTH-1:0] w;
        int chunks;
        w = '0;
        chunks = (DATA_WIDTH + 31) / 32;
        for (int c = 0; c < chunks; c++) begin
            w[c*32 +: 32] = $urandom();
        end
        return w;
    endfunction

    // ------------------------------------------------------------
    // Body
    // ------------------------------------------------------------
    virtual task body();
        axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;

        int unsigned beats;
        logic [ADDR_WIDTH-1:0] addr;
        logic [ADDR_WIDTH-1:0] mask;

        // ========================================================
        // DIRECTED MODE
        // ========================================================
        if (directed_mode) begin
            tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("tr");

            // AXI fields
            tr.rw    = dir_rw;
            tr.addr  = dir_addr;
            tr.len   = dir_beats - 1;
            tr.id    = dir_id;

            // For Case 1
            // tr.size  = $clog2(BYTES_PER_BEAT);
            // tr.burst = 2'b01;

            // For Case 2
            tr.size  = dir_size;
            tr.burst = dir_burst; 

            // Allocate payload arrays
            tr.set_beats_len(tr.len);

            // `uvm_info("SEQ_DBG", $sformatf("dir_wdata = 0x%0h", dir_wdata), UVM_LOW)

            // Write payload
            if (dir_rw == AXI_WRITE) begin
                foreach (tr.data_beats[i]) begin
                    tr.data_beats[i]  = dir_wdata + i;   // Each beat must have unique deterministic data
                    tr.wstrb_beats[i] = {BYTES_PER_BEAT{1'b1}};
                end
            end

            start_item(tr);
            finish_item(tr);

            // `uvm_info(get_type_name(), $sformatf("DIRECTED %s addr=0x%0h beats=%0d id=0x%0h", (dir_rw == AXI_WRITE) ? "WRITE" : "READ", dir_addr, dir_beats, dir_id), UVM_MEDIUM)
            `uvm_info(get_type_name(), $sformatf("DIRECTED %s addr=0x%0h beats=%0d id=0x%0h burst=%0b size=%0d", (dir_rw == AXI_WRITE) ? "WRITE" : "READ", dir_addr, dir_beats, dir_id, dir_burst, dir_size), UVM_MEDIUM)

            return;
        end

        // ========================================================
        // RANDOM MODE (original behavior)
        // ========================================================

        // safety clamps
        if (max_beats == 0) max_beats = 1;
        if (max_beats > 256) max_beats = 256;
        if (read_percent > 100) read_percent = 100;

        `uvm_info(get_type_name(),
                  $sformatf("Starting AXI-MM RANDOM sequence: num=%0d max_beats=%0d read%%=%0d",
                            num_transactions, max_beats, read_percent),
                  UVM_LOW)

        repeat (num_transactions) begin
            tr = axi_mm_seq_item#(
                ADDR_WIDTH, DATA_WIDTH, ID_WIDTH
            )::type_id::create("tr");

            // READ or WRITE
            tr.rw = ($urandom_range(0,99) < read_percent)
                    ? AXI_READ : AXI_WRITE;

            beats  = max_beats;
            tr.len = beats - 1;

            tr.set_beats_len(tr.len);


            // Address
            addr = '0;
            if (ADDR_WIDTH <= 32) begin
                addr = $urandom();
            end else begin
                for (int c = 0; c < (ADDR_WIDTH+31)/32; c++)
                    addr[c*32 +: 32] = $urandom();
            end

            if (addr_aligned) begin
                mask = ~(BYTES_PER_BEAT-1);
                addr &= mask;
            end
            tr.addr = addr;

            tr.id    = $urandom();
            tr.size  = $clog2(BYTES_PER_BEAT);
            tr.burst = 2'b01;

            if (tr.rw == AXI_WRITE) begin
                foreach (tr.data_beats[i]) begin
                    tr.data_beats[i]  = rand_data_word();
                    tr.wstrb_beats[i] = {BYTES_PER_BEAT{1'b1}};
                end
            end

            start_item(tr);
            finish_item(tr);

            `uvm_info(get_type_name(),
                      $sformatf("Issued %s addr=0x%0h beats=%0d id=0x%0h",
                                (tr.rw == AXI_WRITE) ? "WRITE" : "READ",
                                tr.addr, beats, tr.id),
                      UVM_MEDIUM)
        end
    endtask

endclass

`endif
