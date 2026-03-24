// File: tb/uvm/cov/cov/axi_mm_cov_subscriber.sv

class axi_mm_cov_subscriber #(
  int ADDR_WIDTH = 32,
  int DATA_WIDTH = 64,
  int ID_WIDTH   = 4
) extends uvm_subscriber #(axi_mm_seq_item#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH));

  `uvm_component_param_utils(axi_mm_cov_subscriber#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH))

  localparam int BYTES_PER_BEAT = (DATA_WIDTH/8);

  // Debug counters
  longint unsigned seen_total;
  longint unsigned seen_full;
  longint unsigned dropped_nonfull;

  // Shadow variables
  axi_rw_e                   rw;
  logic [1:0]                burst;
  logic [2:0]                size;
  logic [7:0]                len;
  logic [ID_WIDTH-1:0]       id;
  logic [BYTES_PER_BEAT-1:0] wstrb0;

  // Pattern constants
  localparam logic [BYTES_PER_BEAT-1:0] WSTRB_ALL0 = '0;
  localparam logic [BYTES_PER_BEAT-1:0] WSTRB_ALL1 = {BYTES_PER_BEAT{1'b1}};

  function automatic logic [BYTES_PER_BEAT-1:0] mk_pat(input byte v);
    logic [BYTES_PER_BEAT-1:0] tmp;
    tmp = '0;
    tmp[(BYTES_PER_BEAT<8) ? (BYTES_PER_BEAT-1) : 7 : 0] = v[(BYTES_PER_BEAT<8) ? (BYTES_PER_BEAT-1) : 7 : 0];
    return tmp;
  endfunction

  // Len set (beats-1)
  localparam logic [7:0] WRAP_LEGAL_LEN[] = '{8'd1,8'd3,8'd7,8'd15,8'd31,8'd63,8'd127,8'd255};

  // ------------------------------------------------------------
  // Covergroup
  // ------------------------------------------------------------
  covergroup cg;
    option.per_instance = 1;

    cp_rw    : coverpoint rw;

    cp_burst : coverpoint burst {
      bins FIXED = {2'b00};
      bins INCR  = {2'b01};
      bins WRAP  = {2'b10};
      illegal_bins RSV = {2'b11};
    }

    cp_size  : coverpoint size {
      bins B1 = {3'd0};
      bins B2 = {3'd1};
      bins B4 = {3'd2};
      bins B8 = {3'd3};
      bins OTHER = default;
    }

    cp_len : coverpoint len {
        bins LEN0 = {8'd0};
        bins WRAP_LEGAL = {8'd1, 8'd3, 8'd7, 8'd15};

        bins S[]  = {[1:3]};
        bins M[]  = {[4:15]};
        bins L[]  = {[16:63]};
        bins MAX  = {8'd255};
    }

    cp_wstrb0 : coverpoint wstrb0 iff (rw == AXI_WRITE) {
      bins ALL0 = {WSTRB_ALL0};
      bins ALL1 = {WSTRB_ALL1};

      bins _0F  = {mk_pat(8'h0F)};
      bins _F0  = {mk_pat(8'hF0)};
      bins _AA  = {mk_pat(8'hAA)};
      bins _55  = {mk_pat(8'h55)};
    }

    x_rw_burst  : cross cp_rw, cp_burst;

    x_burst_len : cross cp_burst, cp_len {
        ignore_bins WRAP_ILLEGAL = binsof(cp_burst.WRAP) && !binsof(cp_len.WRAP_LEGAL);
    }

    x_burst_sz  : cross cp_burst, cp_size;
  endgroup

  // ------------------------------------------------------------
  // Constructor
  // ------------------------------------------------------------
  function new(string name="axi_mm_cov_subscriber", uvm_component parent=null);
    super.new(name, parent);
    cg = new();
    seen_total      = 0;
    seen_full       = 0;
    dropped_nonfull = 0;
  endfunction

  virtual function void write(axi_mm_seq_item#(ADDR_WIDTH,DATA_WIDTH,ID_WIDTH) t);
    seen_total++;

    // Only count full transaction
    if (t.op_kind != OP_FULL) begin
      dropped_nonfull++;
      return;
    end

    seen_full++;

    rw    = t.rw;
    burst = t.burst;
    size  = t.size;
    len   = t.len;
    id    = t.id;

    if (rw == AXI_WRITE && t.wstrb_beats.size() > 0) wstrb0 = t.wstrb_beats[0];
    else wstrb0 = '0;

    cg.sample();
  endfunction

  // ------------------------------------------------------------
  // Report phase
  // ------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);

    `uvm_info("COV_SUB",
      $sformatf("[%s] seen_total=%0d, seen_full(OP_FULL)=%0d, dropped_nonfull=%0d", get_full_name(), seen_total, seen_full, dropped_nonfull), UVM_LOW)

    if (seen_total == 0) begin
      `uvm_warning("COV_SUB", $sformatf("[%s] No transactions received", get_full_name()))
    end else if (seen_full == 0) begin
      `uvm_warning("COV_SUB", $sformatf("[%s] Transactions received but none were OP_FULL", get_full_name()))
    end
  endfunction

endclass