if { [file exists work] } {
    vdel -all
}
vlib work
vmap work work

# ======================================================
#  Include directories
# ======================================================
set INC_DIRS "+incdir+../tb/interface \
              +incdir+../tb/axi \
              +incdir+../tb/uvm/pkg \
              +incdir+../tb/uvm/seq_item \
              +incdir+../tb/uvm/sequencer \
              +incdir+../tb/uvm/seq \
              +incdir+../tb/uvm/agent \
              +incdir+../tb/uvm/cov \
              +incdir+../tb/uvm/env \
              +incdir+../tb/uvm/test \
              +incdir+../tb/uvm/scoreboard"

# ======================================================
#  Compile DUT interface
# ======================================================
vlog -sv ../tb/interface/axi_mm_if.sv


# ======================================================
#  Compile DUT
# ======================================================
vlog -sv ../dut/axi_mm_dual_port_bram.sv
# vlog -sv ../tb/axi/axi_mm_dummy_slave.sv


# ======================================================
#  Compile pkg
# ======================================================
vlog -sv -timescale 1ns/1ps +acc $INC_DIRS +define+UVM_NO_DPI ../tb/uvm/pkg/axi_mm_pkg.sv


# ======================================================
#  Compile top
# ======================================================
vlog -sv -timescale 1ns/1ps +acc $INC_DIRS ../tb/axi_mm_top.sv
# vlog -sv -timescale 1ns/1ps +acc $INC_DIRS +define+USE_DUMMY_SLAVE ../tb/axi_mm_top.sv


puts "\n==============================="
puts "Compilation Completed!"
puts "===============================\n"