# ============================================================
# AXI-MM Dual-Port BRAM full regression
#
# Run from the repo run/ directory:
#     do run_full_regression.tcl
#
# This script intentionally mirrors the existing run.tcl style,
# but runs the full representative BRAM regression list in one
# invocation and prints a final summary.
# ============================================================

file mkdir logs

# ------------------------------------------------------------
# User knobs
# ------------------------------------------------------------
set DO_COMPILE 1
set ENABLE_COVERAGE 1
set ENABLE_WAVES 0
set KEEP_N 50

set BASE_SEED 20260128
set N_SEEDS 1
set SEED_STEP 1

set UVM_VERBOSITY UVM_HIGH
set GATE 1
set GATE_TIMEOUT_NS 200000000
set CASELIST 0
set UVM_FINISH_ON_COMPLETION 1

# Treat the original interface multiple-driver warnings as a
# regression failure.  Other vopt / UVM warnings are reported,
# but are not failed here unless they become UVM_ERROR/UVM_FATAL
# or the scoreboard final PASS marker is missing.
set FAIL_ON_VSIM3838_3839 1

# ------------------------------------------------------------
# Regression list
#
# Matches the tests documented in run.tcl / README:
#   - axi_mm_smoke_test
#   - axi_mm_directed_test
#   - axi_mm_random_test
#   - axi_mm_corner_test
#   - axi_mm_coverage_test
# ------------------------------------------------------------
set REGRESSION_TESTS [list \
    axi_mm_smoke_test \
    axi_mm_directed_test \
    axi_mm_random_test \
    axi_mm_corner_test \
    axi_mm_coverage_test \
]

# ------------------------------------------------------------
# Keep newest N files matching pattern in logs
# ------------------------------------------------------------
proc keep_newest {pattern keep} {
    set files [glob -nocomplain -directory logs $pattern]
    if {[llength $files] <= $keep} {
        return
    }

    # Sort by mtime (oldest -> newest)
    set sorted [lsort -command {apply {{a b} {
        expr {[file mtime $a] - [file mtime $b]}
    }}} $files]

    set extra [expr {[llength $sorted] - $keep}]
    foreach f [lrange $sorted 0 [expr {$extra - 1}]] {
        catch {file delete -force -- $f}
    }
}

# ------------------------------------------------------------
# Count regex matches in a string
# ------------------------------------------------------------
proc count_matches {pattern text} {
    return [regexp -all -- $pattern $text]
}

# ------------------------------------------------------------
# Extract integer after a UVM report summary severity line
# ------------------------------------------------------------
proc extract_uvm_count {severity text} {
    set pattern [format {%s[ \t]*:[ \t]*([0-9]+)} $severity]
    if {[regexp -- $pattern $text -> value]} {
        return $value
    }
    return -1
}

# ------------------------------------------------------------
# Scan a completed transcript and return pass/fail fields.
# Return list fields:
#   item_pass uvm_warning uvm_error uvm_fatal pass_marker
#   vsim3838 vsim3839 multiply_driven
# ------------------------------------------------------------
proc scan_regression_log {logfile fail_on_3838_3839} {
    set item_pass 1
    set uvm_warning -1
    set uvm_error -1
    set uvm_fatal -1
    set pass_marker 0
    set vsim3838 0
    set vsim3839 0
    set multiply_driven 0

    if {![file exists $logfile]} {
        return [list 0 -1 -1 -1 0 0 0 0]
    }

    set fh [open $logfile r]
    set text [read $fh]
    close $fh

    set uvm_warning [extract_uvm_count {UVM_WARNING} $text]
    set uvm_error   [extract_uvm_count {UVM_ERROR}   $text]
    set uvm_fatal   [extract_uvm_count {UVM_FATAL}   $text]

    if {[regexp -- {FINAL RESULT:[ \t]*PASS} $text]} {
        set pass_marker 1
    }

    set vsim3838 [count_matches {vsim-3838} $text]
    set vsim3839 [count_matches {vsim-3839} $text]
    set multiply_driven [count_matches {multiply driven} $text]

    if {!$pass_marker} {
        set item_pass 0
    }
    if {($uvm_error > 0) || ($uvm_fatal > 0)} {
        set item_pass 0
    }
    if {[regexp -- {FINAL RESULT:[ \t]*FAIL} $text]} {
        set item_pass 0
    }
    if {$fail_on_3838_3839 && (($vsim3838 > 0) || ($vsim3839 > 0) || ($multiply_driven > 0))} {
        set item_pass 0
    }

    return [list $item_pass $uvm_warning $uvm_error $uvm_fatal $pass_marker $vsim3838 $vsim3839 $multiply_driven]
}

# ------------------------------------------------------------
# Housekeeping
# ------------------------------------------------------------
keep_newest "sim_*.log" $KEEP_N
keep_newest "sim_*.wlf" $KEEP_N
keep_newest "cov_*.ucdb" $KEEP_N
keep_newest "cov_*_summary.txt" $KEEP_N

# Clean temporary wave fragments
catch {file delete -force -- {*}[glob -nocomplain -directory logs wlft*]}

# ------------------------------------------------------------
# Optional compile
# ------------------------------------------------------------
if {$DO_COMPILE} {
    puts ""
    puts "============================================================"
    puts "\[REGRESSION\] Compile"
    puts "============================================================"
    do compile.tcl
}

# ------------------------------------------------------------
# Run regression
# ------------------------------------------------------------
set TOTAL 0
set PASS 0
set FAIL 0
set FAIL_ITEMS [list]

set reg_ts [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]

puts ""
puts "============================================================"
puts "\[REGRESSION\] AXI-MM Dual-Port BRAM full regression"
puts "============================================================"
puts "Tests       : $REGRESSION_TESTS"
puts "Base seed   : $BASE_SEED"
puts "N seeds     : $N_SEEDS"
puts "Coverage    : $ENABLE_COVERAGE"
puts "Fail 3838/9 : $FAIL_ON_VSIM3838_3839"
puts "============================================================"

foreach test $REGRESSION_TESTS {
    for {set k 0} {$k < $N_SEEDS} {incr k} {
        set SEED [expr {$BASE_SEED + $k * $SEED_STEP}]
        incr TOTAL

        # ----------------------------------------------------
        # Create timestamped filenames
        # ----------------------------------------------------
        set ts [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
        set item_name "${test}_seed${SEED}"
        set LOGFILE "logs/sim_${ts}_${test}_seed${SEED}.log"
        set WLFNAME "logs/sim_${ts}_${test}_seed${SEED}.wlf"

        puts ""
        puts "------------------------------------------------------------"
        puts "\[REGRESSION\] START $item_name"
        puts "------------------------------------------------------------"

        # ----------------------------------------------------
        # Transcript log
        # ----------------------------------------------------
        transcript file $LOGFILE
        transcript on

        puts "INFO: Regression item -> $item_name"
        puts "INFO: Test            -> $test"
        puts "INFO: Seed            -> $SEED"
        puts "INFO: Transcript      -> $LOGFILE"
        puts "INFO: WLF             -> $WLFNAME"

        # ----------------------------------------------------
        # Run sim
        # ----------------------------------------------------
        set vsim_cmd [list vsim]
        if {$ENABLE_COVERAGE} {
            lappend vsim_cmd -coverage
        }
        lappend vsim_cmd \
            -L uvm12 \
            -wlf $WLFNAME \
            -voptargs=+acc \
            work.axi_mm_top \
            -uvmcontrol=all \
            +UVM_VERBOSITY=$UVM_VERBOSITY \
            +UVM_TESTNAME=$test \
            +GATE=$GATE \
            +BASE_SEED=$SEED \
            +GATE_TIMEOUT_NS=$GATE_TIMEOUT_NS \
            +UVM_OBJECTION_TRACE \
            +UVM_FINISH_ON_COMPLETION=$UVM_FINISH_ON_COMPLETION \
            +CASELIST=$CASELIST

        eval $vsim_cmd
        onfinish stop

        if {$ENABLE_WAVES} {
            add wave -r sim:/axi_mm_top/*
        }

        run -all

        # ----------------------------------------------------
        # Save functional/code coverage database + text summary
        # ----------------------------------------------------
        if {$ENABLE_COVERAGE} {
            set UCDB "logs/cov_${ts}_${test}_seed${SEED}.ucdb"
            catch {coverage save $UCDB}
            puts "INFO: UCDB       -> $UCDB"

            set COVRPT "logs/cov_${ts}_${test}_seed${SEED}_summary.txt"
            catch {exec vcover report -details $UCDB > $COVRPT}
            puts "INFO: COV_REPORT -> $COVRPT"
        }

        transcript off
        transcript file ""

        # Leave the simulator loaded only for this item.
        catch {quit -sim}

        # ----------------------------------------------------
        # Scan result
        # ----------------------------------------------------
        set scan [scan_regression_log $LOGFILE $FAIL_ON_VSIM3838_3839]
        lassign $scan item_pass uvm_warning uvm_error uvm_fatal pass_marker vsim3838 vsim3839 multiply_driven

        puts "\[REGRESSION\] RESULT $item_name: pass_marker=$pass_marker UVM_WARNING=$uvm_warning UVM_ERROR=$uvm_error UVM_FATAL=$uvm_fatal vsim3838=$vsim3838 vsim3839=$vsim3839 multiply_driven=$multiply_driven"

        if {$item_pass} {
            incr PASS
            puts "\[REGRESSION\]\[PASS\] $item_name"
        } else {
            incr FAIL
            lappend FAIL_ITEMS $item_name
            puts "\[REGRESSION\]\[FAIL\] $item_name"
        }
    }
}

# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------
puts ""
puts "============================================================"
puts "\[REGRESSION\] FINAL SUMMARY"
puts "============================================================"
puts "TOTAL : $TOTAL"
puts "PASS  : $PASS"
puts "FAIL  : $FAIL"
if {$FAIL > 0} {
    puts "FAILED_ITEMS: $FAIL_ITEMS"
}
puts "============================================================"

if {$FAIL == 0} {
    puts "\[REGRESSION\] ALL TESTS PASSED"
} else {
    puts "\[REGRESSION\] REGRESSION FAILED"
}
