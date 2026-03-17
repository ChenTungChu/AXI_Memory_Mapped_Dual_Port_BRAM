file mkdir logs

# --------------------------------------------------
# Keep newest N files matching pattern in logs
# --------------------------------------------------
proc keep_newest {pattern keep} {
    set files [glob -nocomplain -directory logs $pattern]
    if {[llength $files] <= $keep} { return }

    # Sort by mtime (oldest -> newest)
    set sorted [lsort -command {apply {{a b} {
        expr {[file mtime $a] - [file mtime $b]}
    }}} $files]

    set extra [expr {[llength $sorted] - $keep}]
    foreach f [lrange $sorted 0 [expr {$extra - 1}]] {
        catch {file delete -force -- $f}
    }
}

# --------------------------------------------------
# Keep only newest N logs and newest N wlf
# --------------------------------------------------
set KEEP_N 30
keep_newest "sim_*.log" $KEEP_N
keep_newest "sim_*.wlf" $KEEP_N

# Clean temporary wave fragments
catch {file delete -force -- {*}[glob -nocomplain -directory logs wlft*]}

# --------------------------------------------------
# Seed loop control 
# --------------------------------------------------
set BASE_SEED 20260128
set N_SEEDS   1
set SEED_STEP 1

for {set k 0} {$k < $N_SEEDS} {incr k} {

  set SEED [expr {$BASE_SEED + $k * $SEED_STEP}]

  # --------------------------------------------------
  # Create timestamped filenames
  # --------------------------------------------------
  set ts [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
  set LOGFILE "logs/sim_${ts}_seed${SEED}.log"
  set WLFNAME "logs/sim_${ts}_seed${SEED}.wlf"

  # --------------------------------------------------
  # Transcript log
  # --------------------------------------------------
  transcript file $LOGFILE
  transcript on
  puts "INFO: Seed       -> $SEED"
  puts "INFO: Transcript -> $LOGFILE"
  puts "INFO: WLF        -> $WLFNAME"

  # --------------------------------------------------
  # Run sim
  # - TESTNAME: axi_mm_smoke_test, axi_mm_random_test, axi_mm_corner_test, axi_mm_directed_test, axi_mm_coverage_test
  # --------------------------------------------------
  vsim -coverage -L uvm12 -wlf $WLFNAME -voptargs=+acc work.axi_mm_top \
    -uvmcontrol=all \
    +UVM_VERBOSITY=UVM_HIGH \
    +UVM_TESTNAME=axi_mm_directed_test \
    +GATE=1 \
    +BASE_SEED=$SEED \
    +GATE_TIMEOUT_NS=200000000 \
    +UVM_OBJECTION_TRACE \
    +UVM_FINISH_ON_COMPLETION=1 \
    +CASELIST=0

  add wave -r sim:/axi_mm_top/*
  run -all

  # --------------------------------------------------
  # Save functional coverage database + text summary
  # --------------------------------------------------
  set UCDB "logs/cov_${ts}_seed${SEED}.ucdb"
  coverage save $UCDB
  puts "INFO: UCDB       -> $UCDB"

  set COVRPT "logs/cov_${ts}_seed${SEED}_summary.txt"
  catch {exec vcover report -details $UCDB > $COVRPT}
  puts "INFO: COV_REPORT -> $COVRPT"

  transcript off
  transcript file ""
}
