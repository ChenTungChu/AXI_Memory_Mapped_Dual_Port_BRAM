`ifndef AXI_MM_RESET_AGENT_SV
`define AXI_MM_RESET_AGENT_SV

import uvm_pkg::*;
`include "uvm_macros.svh"

// -----------------------------------------------------------------------------
// File: tb/uvm/axi_mm_reset_agent.sv
//
// TB-owned reset driver + reset monitor
// - Monitor is the SINGLE source of truth for broadcasting reset edges.
// - Broadcast reset edges via global uvm_event:
//     "axi_mm_reset_assert"    (rst_n: 1 -> 0)
//     "axi_mm_reset_deassert"  (rst_n: 0 -> 1)
//
// Built-in Power-On Reset (POR)
// - reset_agent will automatically start axi_mm_reset_seq once at start of run
// - POR can be disabled or configured via uvm_config_db.
//
// Interface requirements (axi_mm_reset_if):
// - logic rst_n;
// - clocking cb_drv @(posedge clk) with output rst_n
// - clocking cb_mon @(posedge clk) with input  rst_n
// - modport mp_driver  (clocking cb_drv, input clk);
// - modport mp_monitor (clocking cb_mon, input clk);
// -----------------------------------------------------------------------------

// ============================
// Reset sequence item
// ============================
class reset_seq_item extends uvm_sequence_item;
  `uvm_object_utils(reset_seq_item)

  rand bit          rst_n;
  rand int unsigned hold_cycles;

  constraint c_hold { hold_cycles inside {[1:1000000]}; }

  function new(string name="reset_seq_item");
    super.new(name);
    rst_n       = 1'b1;
    hold_cycles = 1;
  endfunction

  virtual function string convert2string();
    return $sformatf("reset_seq_item: rst_n=%0b hold_cycles=%0d", rst_n, hold_cycles);
  endfunction
endclass


// ============================
// A simple reusable reset sequence
// (assert then deassert)
// ============================
class axi_mm_reset_seq extends uvm_sequence #(reset_seq_item);
  `uvm_object_utils(axi_mm_reset_seq)

  int unsigned assert_cycles   = 50;
  int unsigned deassert_cycles = 10;

  function new(string name="axi_mm_reset_seq");
    super.new(name);
  endfunction

  virtual task body();
    reset_seq_item tr;

    // ASSERT
    tr = reset_seq_item::type_id::create("rst_assert_tr");
    start_item(tr);
      tr.rst_n       = 1'b0;
      tr.hold_cycles = assert_cycles;
    finish_item(tr);

    // DEASSERT
    tr = reset_seq_item::type_id::create("rst_deassert_tr");
    start_item(tr);
      tr.rst_n       = 1'b1;
      tr.hold_cycles = deassert_cycles;
    finish_item(tr);
  endtask
endclass


// ============================
// Reset sequencer
// ============================
class reset_sequencer extends uvm_sequencer#(reset_seq_item);
  `uvm_component_utils(reset_sequencer)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass


// ============================
// Reset driver
// ============================
// Drives reset via clocking block (mp_driver.cb_drv.rst_n).
class reset_driver extends uvm_driver#(reset_seq_item);
  `uvm_component_utils(reset_driver)

  virtual axi_mm_reset_if.mp_driver vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi_mm_reset_if.mp_driver)::get(this, "", "vif", vif)) begin
      `uvm_fatal("NOVIF", "reset_driver: axi_mm_reset_if.mp_driver not set (key=vif)")
    end
  endfunction

  task automatic drive_value(bit rst_n_val, int unsigned cycles);
    // Drive on clocking block edge
    @(vif.cb_drv);
    vif.cb_drv.rst_n <= rst_n_val;

    if (cycles > 1) begin
      repeat (cycles-1) begin
        @(vif.cb_drv);
        vif.cb_drv.rst_n <= rst_n_val;
      end
    end
  endtask

  task run_phase(uvm_phase phase);
    reset_seq_item tr;

    // Safe default at time 0: ASSERT reset (on first cb tick)
    @(vif.cb_drv);
    vif.cb_drv.rst_n <= 1'b0;

    forever begin
      seq_item_port.get_next_item(tr);

      `uvm_info("RST_DRV", $sformatf("Drive %s", tr.convert2string()), UVM_LOW)
      drive_value(tr.rst_n, tr.hold_cycles);

      seq_item_port.item_done();
    end
  endtask
endclass


// ============================
// Reset monitor (edge detect + global events)
// ============================
class reset_monitor extends uvm_component;
  `uvm_component_utils(reset_monitor)

  virtual axi_mm_reset_if.mp_monitor vif;

  uvm_event ev_reset_assert;
  uvm_event ev_reset_deassert;

  bit rst_prev;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(virtual axi_mm_reset_if.mp_monitor)::get(this, "", "vif", vif)) begin
      `uvm_fatal("NOVIF", "reset_monitor: axi_mm_reset_if.mp_monitor not set (key=vif)")
    end

    ev_reset_assert   = uvm_event_pool::get_global("axi_mm_reset_assert");
    ev_reset_deassert = uvm_event_pool::get_global("axi_mm_reset_deassert");

    rst_prev = 1'b1;
  endfunction

  task run_phase(uvm_phase phase);
    @(vif.cb_mon);
    rst_prev = vif.cb_mon.rst_n;

    forever begin
      @(vif.cb_mon);

      // 1 -> 0 : assert
      if ((rst_prev === 1'b1) && (vif.cb_mon.rst_n === 1'b0)) begin
        #0;
        ev_reset_assert.trigger();
        `uvm_info("RST_MON", "Reset ASSERT -> trigger axi_mm_reset_assert", UVM_LOW)
      end

      // 0 -> 1 : deassert
      if ((rst_prev === 1'b0) && (vif.cb_mon.rst_n === 1'b1)) begin
        #0;
        ev_reset_deassert.trigger();
        `uvm_info("RST_MON", "Reset DEASSERT -> trigger axi_mm_reset_deassert", UVM_LOW)
      end

      rst_prev = vif.cb_mon.rst_n;
    end
  endtask
endclass


// ============================
// Reset agent
// ============================
class reset_agent extends uvm_agent;
  `uvm_component_utils(reset_agent)

  uvm_active_passive_enum is_active = UVM_ACTIVE;

  reset_sequencer seqr;
  reset_driver    drv;
  reset_monitor   mon;

  virtual axi_mm_reset_if.mp_driver  vif_drv;
  virtual axi_mm_reset_if.mp_monitor vif_mon;

  // ----------------------------
  // POR knobs
  // ----------------------------
  bit por_enable = 1'b1;
  int unsigned por_assert_cycles   = 50;
  int unsigned por_deassert_cycles = 10;

  function new(string name="reset_agent", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    void'(uvm_config_db#(uvm_active_passive_enum)::get(this, "", "is_active", is_active));

    // POR config (optional)
    void'(uvm_config_db#(bit)::get(this, "", "por_enable", por_enable));
    void'(uvm_config_db#(int unsigned)::get(this, "", "por_assert_cycles", por_assert_cycles));
    void'(uvm_config_db#(int unsigned)::get(this, "", "por_deassert_cycles", por_deassert_cycles));

    // ---- monitor vif (required) ----
    if (!uvm_config_db#(virtual axi_mm_reset_if.mp_monitor)::get(this, "", "vif_mon", vif_mon)) begin
      if (!uvm_config_db#(virtual axi_mm_reset_if.mp_monitor)::get(this, "", "vif", vif_mon)) begin
        `uvm_fatal("NOVIF",
          $sformatf("reset_agent: mp_monitor vif not set (keys tried: vif_mon, vif). agent=%s",
                    get_full_name()))
      end
    end

    // ---- driver vif (required if ACTIVE) ----
    if (is_active == UVM_ACTIVE) begin
      if (!uvm_config_db#(virtual axi_mm_reset_if.mp_driver)::get(this, "", "vif_drv", vif_drv)) begin
        if (!uvm_config_db#(virtual axi_mm_reset_if.mp_driver)::get(this, "", "vif", vif_drv)) begin
          `uvm_fatal("NOVIF",
            $sformatf("reset_agent: mp_driver vif not set (keys tried: vif_drv, vif). agent=%s",
                      get_full_name()))
        end
      end
    end

    // ---- monitor ----
    mon = reset_monitor::type_id::create("mon", this);
    uvm_config_db#(virtual axi_mm_reset_if.mp_monitor)::set(this, "mon", "vif",     vif_mon);
    uvm_config_db#(virtual axi_mm_reset_if.mp_monitor)::set(this, "mon", "vif_mon", vif_mon);

    // ---- driver + sequencer (ACTIVE only) ----
    if (is_active == UVM_ACTIVE) begin
      seqr = reset_sequencer::type_id::create("seqr", this);
      drv  = reset_driver   ::type_id::create("drv",  this);

      uvm_config_db#(virtual axi_mm_reset_if.mp_driver)::set(this, "drv", "vif",     vif_drv);
      uvm_config_db#(virtual axi_mm_reset_if.mp_driver)::set(this, "drv", "vif_drv", vif_drv);
    end
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (is_active == UVM_ACTIVE) begin
      drv.seq_item_port.connect(seqr.seq_item_export);
    end
  endfunction

  // ----------------------------
  // automatic POR
  // ----------------------------
  task run_phase(uvm_phase phase);
    axi_mm_reset_seq por_seq;

    if (is_active != UVM_ACTIVE) return;
    if (!por_enable) begin
      `uvm_info("RST_POR", "POR disabled by config (por_enable=0)", UVM_LOW)
      return;
    end

    // Start POR once at beginning of run
    por_seq = axi_mm_reset_seq::type_id::create("por_seq");
    por_seq.assert_cycles   = por_assert_cycles;
    por_seq.deassert_cycles = por_deassert_cycles;

    `uvm_info("RST_POR",
      $sformatf("Starting POR: assert=%0d cycles, deassert_hold=%0d cycles",
                por_assert_cycles, por_deassert_cycles),
      UVM_LOW)

    por_seq.start(seqr);
  endtask

endclass : reset_agent

`endif