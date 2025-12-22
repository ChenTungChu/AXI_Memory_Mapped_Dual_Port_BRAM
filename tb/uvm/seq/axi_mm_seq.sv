// File: tb/uvm/seq/axi_mm_seq.sv
`ifndef AXI_MM_SEQ_SV
`define AXI_MM_SEQ_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import axi_mm_pkg::*;

// ------------------------------------------------------------
// AXI MM basic random traffic sequence
// ------------------------------------------------------------
class axi_mm_seq #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4
) extends uvm_sequence #(axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH));

    `uvm_object_param_utils(axi_mm_seq #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

    // --------------------------------------------------------
    // User configurable knobs
    // --------------------------------------------------------
    rand int unsigned num_transactions;   // number of AXI transactions
    rand int unsigned max_beats;           // max beats per burst (>=1)
    rand int unsigned read_percent;        // percentage of READs (0..100)
    rand bit          addr_aligned;        // align address to beat size

    constraint c_defaults {
        num_transactions inside {[1:1000]};
        max_beats        inside {[1:16]};
        read_percent    inside {[0:100]};
    }

    localparam int BYTES_PER_BEAT = DATA_WIDTH / 8;

    // --------------------------------------------------------
    // Constructor
    // --------------------------------------------------------
    function new(string name = "axi_mm_seq");
        super.new(name);

        // sensible defaults
        num_transactions = 1;
        max_beats        = 8;
        read_percent     = 50;
        addr_aligned     = 1'b1;
    endfunction

    // --------------------------------------------------------
    // Helper: random DATA_WIDTH word
    // --------------------------------------------------------
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

    // --------------------------------------------------------
    // Body
    // --------------------------------------------------------
    virtual task body();
        axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;

        int unsigned beats;
        logic [ADDR_WIDTH-1:0] addr;
        logic [ADDR_WIDTH-1:0] mask;

        // safety clamps
        if (max_beats == 0) max_beats = 1;
        if (max_beats > 256) max_beats = 256; // AXI spec limit
        if (read_percent > 100) read_percent = 100;

        `uvm_info(get_type_name(),
                  $sformatf("Starting AXI-MM sequence: num=%0d max_beats=%0d read%%=%0d",
                            num_transactions, max_beats, read_percent),
                  UVM_LOW)

        repeat (num_transactions) begin
            tr = axi_mm_seq_item #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create("tr");

            // READ or WRITE
            tr.rw = ($urandom_range(0,99) < read_percent) ? AXI_READ : AXI_WRITE;

            // Burst length (AXI: len = beats-1)
            // beats  = $urandom_range(1, max_beats);
            beats = max_beats;   // temporary for smoke test
            tr.len = beats - 1;

            // Allocate payload arrays
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

            // ID
            tr.id = $urandom();

            // Burst attributes
            tr.size  = $clog2(BYTES_PER_BEAT);
            tr.burst = 2'b01; // INCR

            // Write data
            if (tr.rw == AXI_WRITE) begin
                foreach (tr.data_beats[i]) begin
                    tr.data_beats[i]  = rand_data_word();
                    tr.wstrb_beats[i] = {BYTES_PER_BEAT{1'b1}};
                end
            end

            // Send to driver
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
