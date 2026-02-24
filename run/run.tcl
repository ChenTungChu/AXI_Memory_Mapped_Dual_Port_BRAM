# Test items: axi_mm_smoke_test, axi_mm_random_test, axi_mm_corner_test, axi_mm_directed_test, axi_mm_coverage_test

vsim -voptargs=+acc work.axi_mm_top \
  -uvmcontrol=all \
  +UVM_VERBOSITY=UVM_HIGH \
  +UVM_TESTNAME=axi_mm_corner_test \
  +GATE=1 \
  +BASE_SEED=20260128 \
  +GATE_TIMEOUT_NS=200000000 \
  +UVM_OBJECTION_TRACE \
  +UVM_FINISH_ON_COMPLETION=1 \
  +CASELIST=14 \

# ===========For directed test=============
  # +CASELIST=10 \
# =========================================  

# ===========For random test=============
  # +GATE=1 \                       
  # +BASE_SEED=20260128 \           
  # +GATE_TIMEOUT_NS=200000000 \ 
# =======================================

add wave -r sim:/axi_mm_top/*
run -all

#quit -sim