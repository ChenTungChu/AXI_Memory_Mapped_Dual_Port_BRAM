# Test items: axi_mm_smoke_test, axi_mm_random_test, axi_mm_corner_test, axi_mm_directed_test, axi_mm_coverage_test

file mkdir logs

# --------------------------------------------------
# Helpers: keep newest N files matching pattern in logs/
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
# Keep only newest 2 logs and newest 2 wlf
# --------------------------------------------------
keep_newest "sim_*.log" 1
keep_newest "sim_*.wlf" 1

# Clean temporary wave fragments (optional)
catch {file delete -force -- {*}[glob -nocomplain -directory logs wlft*]}

# --------------------------------------------------
# Create timestamped filenames
# --------------------------------------------------
set ts [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set LOGFILE "logs/sim_${ts}.log"
set WLFNAME "logs/sim_${ts}.wlf"

# --------------------------------------------------
# Transcript log
# --------------------------------------------------
transcript file $LOGFILE
transcript on
puts "INFO: Transcript -> $LOGFILE"
puts "INFO: WLF        -> $WLFNAME"

# --------------------------------------------------
# Run sim
# --------------------------------------------------
vsim -L uvm12 -wlf $WLFNAME -voptargs=+acc work.axi_mm_top \
  -uvmcontrol=all \
  +UVM_VERBOSITY=UVM_HIGH \
  +UVM_TESTNAME=axi_mm_coverage_test \
  +GATE=1 \
  +BASE_SEED=20260128 \
  +GATE_TIMEOUT_NS=200000000 \
  +UVM_OBJECTION_TRACE \
  +UVM_FINISH_ON_COMPLETION=1 \
  +CASELIST=8

add wave -r sim:/axi_mm_top/*
run -all

transcript off
transcript file ""