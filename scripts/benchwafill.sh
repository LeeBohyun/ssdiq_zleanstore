#!/bin/bash
set -x

# Measure steady-state write throughput vs. fill factor on a single SSD
# (plus WAF, on drives that expose the OCP smart log - cloud instance storage
# usually does not, there the wa column stays 0).
# For each FILL: sanitize/discard, sequentially initialize the first FILL x
# capacity (the trimmed remainder acts as extra spare), then uniform random
# overwrites of OVERWRITE x the used region at full speed. Per-second
# throughput (writeIOPS/writesMBs) and WAF go to iob-log-$PREFIX.csv; averages
# per fill are printed at the end.
#
# Usage: [FILLS="0.2 0.4 0.6 0.8 1"] [OVERWRITE=5] ./benchwafill.sh <device> <prefix> [bs]

FILENAME=$1
export FILESIZE= # let iob figure it out
export PREFIX=$2
UNI_BS=${3:-4K}

FILLS=${FILLS:-"0.2 0.4 0.6 0.8 1"}
OVERWRITE=${OVERWRITE:-5} # overwrites of the used (fill) region per measurement

export IOENGINE=io_uring

cmake -DCMAKE_BUILD_TYPE=Release ..
make -j iob

sanitize_nvme() {
    echo "sanitize"
    if sudo nvme sanitize --sanact=2 "$FILENAME"; then
        sleep 2m
        sudo nvme sanitize-log "$FILENAME"
        sleep 10s
    else
        echo "sanitize not supported on $FILENAME (e.g. cloud instance storage), using blkdiscard only"
    fi
    sudo blkdiscard  -v "$FILENAME"
    sleep 1m
}
init_fill() {
	# sequentially write the first FILL x capacity once, then exit (IO_SIZE=0)
	sudo -E FILENAME=$FILENAME FILL=$FILL INIT=yes IO_SIZE=0 IO_DEPTH=128 BS=4K THREADS=1 RW=1 iob/iob >> iob-output-$PREFIX.csv
}
run_wa_exp_uniform() {
	# IO_SIZE_PERCENT_FILE is relative to the whole device, scale by FILL so
	# every fill level overwrites its used region OVERWRITE times
	IOPF=$(awk "BEGIN{print $OVERWRITE * $FILL}")
	sudo -E FILENAME=$FILENAME FILL=$FILL INIT=false IO_SIZE_PERCENT_FILE=$IOPF IO_DEPTH=128 BS=$UNI_BS THREADS=4 PATTERN=uniform RW=1 iob/iob >> iob-output-$PREFIX.csv
}

for FILL in $FILLS; do
	export FILL
	sanitize_nvme
	init_fill
	run_wa_exp_uniform
	sleep 2m
done

# summary: average write throughput per fill, plus WAF where the drive exposes
# the OCP smart log (skip first 60s warmup; WAF rows only when OCP updated)
awk -F, '$1=="keep" && $5+0 > 60 {
		iops[$9]+=$19; mbs[$9]+=$21; cnt[$9]++;
		if ($(NF-2)+0 > 0) { wa[$9]+=$(NF-2); wacnt[$9]++ }
	}
	END { for (f in cnt) printf "fill %s: avg %.0f write IOPS (%.0f MiB/s), avg WAF %s\n",
		f, iops[f]/cnt[f], mbs[f]/cnt[f], (wacnt[f] ? sprintf("%.2f", wa[f]/wacnt[f]) : "n/a") }' \
	iob-log-$PREFIX.csv | sort -t' ' -k2 -n
