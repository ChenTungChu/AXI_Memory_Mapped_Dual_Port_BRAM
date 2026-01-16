`ifndef AXI_MM_MONITOR_SV
`define AXI_MM_MONITOR_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

class axi_mm_monitor #(
    int ADDR_WIDTH = 32,
    int DATA_WIDTH = 64,
    int ID_WIDTH   = 4
) extends uvm_component;

    virtual axi_mm_if #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) vif;

    typedef struct {
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
        int unsigned beat_cnt;
    } aw_tr_t;

    // Read pending table
    axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) pending_reads[int unsigned];
    typedef struct {
        axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH) tr;
        int unsigned beat_cnt;
    } ar_tr_t;

    ar_tr_t pending_reads_s[int unsigned];
    aw_tr_t write_q[$];

    uvm_analysis_port #(axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)) ap;

    `uvm_component_param_utils(axi_mm_monitor #(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual axi_mm_if#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH))::get(this, "", "vif", vif)) begin
            `uvm_fatal("NOVIF", "axi_mm_monitor: virtual interface not set")
        end
    endfunction

    task run_phase(uvm_phase phase);
        `uvm_info("MON", "AXI-MM Monitor started", UVM_LOW)
        fork
            monitor_write();
            monitor_read();
        join_none
    endtask

    function automatic logic [ADDR_WIDTH-1:0] calc_beat_addr(
        input logic [ADDR_WIDTH-1:0] start_addr,
        input logic [2:0]            size,       // log2(bytes_per_beat)
        input logic [7:0]            len,        // AXI len (0-based)
        input logic [1:0]            burst,      // 00 FIXED, 01 INCR, 10 WRAP
        input int unsigned           beat_idx
    );
        int unsigned bytes_per_beat;
        int unsigned total_beats;
        int unsigned wrap_bytes;
        logic [ADDR_WIDTH-1:0] wrap_base;
        int unsigned offset;

        bytes_per_beat = (1 << size);
        total_beats    = len + 1;
        wrap_bytes     = total_beats * bytes_per_beat;

        unique case (burst)
            2'b00: begin // FIXED
                return start_addr;
            end
            2'b01: begin // INCR
                return start_addr + (beat_idx * bytes_per_beat);
            end
            2'b10: begin // WRAP
                // AXI WRAP: wrap_bytes is power-of-2 => use mask (robust, no division)
                wrap_base = start_addr & ~(wrap_bytes - 1);

                offset = (start_addr - wrap_base) + (beat_idx * bytes_per_beat);
                offset = offset % wrap_bytes;

                return wrap_base + offset;
            end
            default: return start_addr;
        endcase
    endfunction

    // ============================================================
    // Write monitor
    // ============================================================
    task monitor_write();
        aw_tr_t       tr_struct;
        aw_tr_t       done_tr;
        int unsigned  beat_idx;
        int unsigned  expected_beats;
        logic [ADDR_WIDTH-1:0] beat_addr;
 

        forever begin
            @(posedge vif.clk);
            #1; 

            if (vif.rst_n === 1'b0) begin
                write_q.delete();
                continue;
            end

            // ---------------- AW Channel ----------------
            if (vif.awvalid && vif.awready) begin
                tr_struct.tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create($sformatf("wr_tr_id_%0d", vif.awid), this);
                tr_struct.tr.rw    = AXI_WRITE;
                tr_struct.tr.addr  = vif.awaddr;
                tr_struct.tr.id    = vif.awid;
                tr_struct.tr.len   = vif.awlen;
                tr_struct.tr.size  = vif.awsize;
                tr_struct.tr.burst = vif.awburst;

                tr_struct.tr.set_beats_len(tr_struct.tr.len); 
                tr_struct.beat_cnt = 0;

                write_q.push_back(tr_struct);
                `uvm_info("AXI_MON", $sformatf("AW captured: ID=%0d addr=0x%0h len=%0d", 
                          tr_struct.tr.id, tr_struct.tr.addr, tr_struct.tr.len), UVM_HIGH)
            end

            // ---------------- W Channel ----------------
            if (write_q.size() > 0 && vif.wvalid && vif.wready) begin
                
                beat_idx       = write_q[0].beat_cnt;
                expected_beats = write_q[0].tr.len + 1;

                if (beat_idx >= expected_beats) begin
                    `uvm_error("AXI_MON", $sformatf("Extra W beat for ID %0d. Exp: %0d. WDATA=0x%h WLAST=%0b", 
                                                    write_q[0].tr.id, expected_beats, vif.wdata, vif.wlast))
                    
                end
                else begin
                    // Beat address calculation
                    beat_addr = calc_beat_addr(write_q[0].tr.addr,
                           write_q[0].tr.size,
                           write_q[0].tr.len,
                           write_q[0].tr.burst,
                           beat_idx);


                    write_q[0].tr.data_beats[beat_idx]  = vif.wdata;
                    write_q[0].tr.wstrb_beats[beat_idx] = vif.wstrb;
                    write_q[0].beat_cnt++;
                    
                    `uvm_info("AXI_MON",
                        $sformatf("W captured: ID=%0d Beat=%0d Addr=0x%0h Data=0x%h WLAST=%0b burst=%02b size=%0d",
                            write_q[0].tr.id, beat_idx, beat_addr, vif.wdata, vif.wlast, write_q[0].tr.burst, write_q[0].tr.size),
                        UVM_HIGH)
                end

                if (vif.wlast) begin
                    if (write_q[0].beat_cnt != expected_beats) begin
                         if (beat_idx < expected_beats)
                            `uvm_error("AXI_MON", $sformatf("WLAST mismatch ID %0d. Curr: %0d Exp: %0d", 
                                                            write_q[0].tr.id, write_q[0].beat_cnt, expected_beats))
                    end
                end
            end

            // ---------------- B Channel ----------------
            if (write_q.size() > 0 && vif.bvalid && vif.bready) begin
                
                done_tr = write_q[0];
                expected_beats = done_tr.tr.len + 1;

                if (done_tr.beat_cnt != expected_beats) begin
                    `uvm_error("AXI_MON", $sformatf("BVALID with incomplete write. ID=%0d Beats=%0d/%0d", 
                               done_tr.tr.id, done_tr.beat_cnt, expected_beats))
                end

                done_tr.tr.bresp = vif.bresp;
                
                if (done_tr.tr.data_beats.size() > 0) begin
                    `uvm_info("AXI_MON", $sformatf("WRITE completed: ID=%0d Addr=0x%h Data[0]=0x%h (Beats=%0d)", 
                              done_tr.tr.id, done_tr.tr.addr, done_tr.tr.data_beats[0], done_tr.tr.data_beats.size()), UVM_LOW)
                end else begin
                    `uvm_error("AXI_MON", "WRITE completed but Data Array is EMPTY!")
                end

                ap.write(done_tr.tr);
                write_q.pop_front();
            end
        end
    endtask

    // ============================================================
    // Read monitor
    // ============================================================
    task monitor_read();
        int unsigned id;
        int unsigned beat_idx;
        int unsigned expected_beats;
        logic [ADDR_WIDTH-1:0] beat_addr;

        forever begin
            @(posedge vif.clk);
            #1; // Read 通道也必須加 #1

            if (vif.rst_n === 1'b0) begin
                pending_reads_s.delete();
                continue;
            end

            // AR Phase
            if (vif.arvalid && vif.arready) begin
                id = vif.arid;
                if (pending_reads_s.exists(id)) begin
                    `uvm_error("AXI_MON", $sformatf("AR received while read pending ID=%0d", id))
                end else begin
                    pending_reads_s[id].tr = axi_mm_seq_item#(ADDR_WIDTH, DATA_WIDTH, ID_WIDTH)::type_id::create($sformatf("rd_tr_id_%0d", id), this);
                    pending_reads_s[id].tr.rw    = AXI_READ;
                    pending_reads_s[id].tr.addr  = vif.araddr;
                    pending_reads_s[id].tr.id    = id;
                    pending_reads_s[id].tr.len   = vif.arlen;
                    pending_reads_s[id].tr.size  = vif.arsize;
                    pending_reads_s[id].tr.burst = vif.arburst;
                    
                    pending_reads_s[id].tr.set_beats_len(pending_reads_s[id].tr.len);
                    pending_reads_s[id].beat_cnt = 0;
                end
            end

            // R Phase
            if (vif.rvalid && vif.rready) begin
                id = vif.rid;
                if (!pending_reads_s.exists(id)) begin
                    `uvm_error("AXI_MON", $sformatf("R for unknown ID %0d", id))
                end else begin
                    expected_beats = pending_reads_s[id].tr.len + 1;
                    beat_idx       = pending_reads_s[id].beat_cnt;
                    beat_addr = calc_beat_addr(pending_reads_s[id].tr.addr,
                           pending_reads_s[id].tr.size,
                           pending_reads_s[id].tr.len,
                           pending_reads_s[id].tr.burst,
                           beat_idx);

                    if (beat_idx < expected_beats) begin
                        pending_reads_s[id].tr.rdata_beats[beat_idx] = vif.rdata;
                        pending_reads_s[id].tr.rresp_beats[beat_idx] = vif.rresp;
                        pending_reads_s[id].beat_cnt++;

                        `uvm_info("AXI_MON", $sformatf("R captured: ID=%0d Beat=%0d Addr=0x%0h Data=0x%h RLAST=%0b", id, beat_idx, beat_addr, vif.rdata, vif.rlast), UVM_HIGH)
                    end else begin
                        `uvm_error("AXI_MON", $sformatf("Extra R beat detected: ID=%0d Beat=%0d Addr=0x%0h Data=0x%h RLAST=%0b", id, beat_idx, beat_addr, vif.rdata, vif.rlast))
                    end

                    if (vif.rlast) begin
                        if (pending_reads_s[id].beat_cnt != expected_beats) begin
                            `uvm_error("AXI_MON", $sformatf("RLAST early/late ID=%0d beats=%0d/%0d", id, pending_reads_s[id].beat_cnt, expected_beats))
                        end
                        
                        ap.write(pending_reads_s[id].tr);
                        pending_reads_s.delete(id);
                    end
                end
            end
        end
    endtask

endclass
`endif