# Clean & create work
if { [file exists work] } {
    vdel -lib work -all
}
vlib work
vmap work work

# --------------------------------------------------
# Local override
# --------------------------------------------------
if {[file exists "compile_local.tcl"]} {
    puts "INFO: Loading compile_local.tcl"
    do compile_local.tcl
} else {
    puts "ERROR: compile_local.tcl not found."
    puts "Please create compile_local.tcl with your UVM path settings."
    quit -f
}

# --------------------------------------
# Build UVM 1.2 into its own library
# --------------------------------------
if { [file exists uvm12] } {
    vdel -lib uvm12 -all
}
vlib uvm12
vmap uvm12 uvm12

set UVM12_INCS [list "+incdir+$UVM12_SRC"]

vlog -sv -work uvm12 +define+UVM_NO_DPI {*}$UVM12_INCS $UVM12_PKG

# ======================================================
# Include directories
# ======================================================
set INC_LIST [list \
  "+incdir+$UVM12_SRC" \
  "+incdir+../tb/interface" \
  "+incdir+../tb/axi" \
  "+incdir+../tb/uvm/pkg" \
  "+incdir+../tb/uvm/seq_item" \
  "+incdir+../tb/uvm/sequencer" \
  "+incdir+../tb/uvm/seq" \
  "+incdir+../tb/uvm/agent" \
  "+incdir+../tb/reset" \
  "+incdir+../tb/commit" \
  "+incdir+../tb/uvm/cov" \
  "+incdir+../tb/uvm/env" \
  "+incdir+../tb/uvm/test" \
  "+incdir+../tb/uvm/scoreboard" \
]

# ======================================================
# Compile DUT interface
# ======================================================
vlog -sv -L uvm12 {*}$INC_LIST ../tb/interface/axi_mm_if.sv

# ======================================================
# Compile DUT
# ======================================================
vlog -sv -timescale 1ns/1ps +acc -L uvm12 {*}$INC_LIST ../dut/axi_mm_dual_port_bram.sv

# ======================================================
# Compile pkg
# ======================================================
vlog -sv -timescale 1ns/1ps +acc -L uvm12 {*}$INC_LIST +define+UVM_NO_DPI ../tb/uvm/pkg/axi_mm_pkg.sv

# ======================================================
# Compile top
# ======================================================
vlog -sv -timescale 1ns/1ps +acc -L uvm12 {*}$INC_LIST ../tb/axi_mm_top.sv

puts "\n==============================="
puts "Compilation Completed!"
puts "===============================\n"