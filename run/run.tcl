# Test items: axi_mm_smoke_test, axi_mm_random_test, axi_mm_corner_test, axi_mm_directed_test, axi_mm_coverage_test

vsim -voptargs=+acc work.axi_mm_top -uvmcontrol=all +UVM_VERBOSITY=UVM_HIGH +UVM_TESTNAME=axi_mm_corner_test

add wave -r sim:/axi_mm_top/*

run -all

#quit -sim