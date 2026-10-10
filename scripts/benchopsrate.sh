#!/bin/bash
set -x

# Measure write throughput (ops/s) vs. write intensity on a 100% full SSD.
# The device is sanitized, initialized and loaded ONCE (full-speed overwrites to
# reach steady state); there is no sanitize/init between rates. Before each rate
# change, 1x the capacity (REFRESH_OVERWRITES) is written at full bandwidth so
# every rate starts from the same full-bw steady state, then the rate-limited
# measurement runs for RUNTIME seconds. Per-second ops/s is in
# iob-log-$PREFIX.csv (writeIOPS column, grouped by targetWriteMBs); a summary
# is printed at the end.
#
# Usage: [WRITE_RATES="50 100 200 400 800"] [RUNTIME=600] ./benchopsrate.sh <device> <prefix> [pattern] [bs]
# Pattern parameters (ZIPF, ZONES, ZNS_*) can be exported by the caller.

FILENAME=$1
export FILESIZE= # let iob figure it out
export PREFIX=$2
PATTERN_ARG=${3:-uniform}
UNI_BS=${4:-4K}

WRITE_RATES=${WRITE_RATES:-"50 100 200 400 800 1600 3200 6400"}  # MiB/s write intensity per measurement run
RUNTIME=${RUNTIME:-600}                           # measurement seconds per rate
LOAD_OVERWRITES=${LOAD_OVERWRITES:-2}             # full-speed overwrites of the device, once, before measuring
REFRESH_OVERWRITES=${REFRESH_OVERWRITES:-1}       # full-speed overwrites (x capacity) before each rate change
SLEEP_BETWEEN=${SLEEP_BETWEEN:-1m}                # settle time between rates (no reload)

export IOENGINE=io_uring
export FILL=1 # SSD 100% full

# newer sudo ignores -E ("preserving the entire environment is not supported"),
# so preserve the needed variables explicitly
SUDO="sudo --preserve-env=FILESIZE,PREFIX,IOENGINE,FILL,ZIPF,ZONES,ZNS_ACTIVE_ZONES,ZNS_ZONE_SIZE"

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
sanitize_nvme_and_init() {
	sanitize_nvme
	$SUDO FILENAME=$FILENAME INIT=yes IO_SIZE_PERCENT_FILE=0.01 IO_DEPTH=1 BS=4K THREADS=1 PATTERN=sequential RW=1 iob/iob >> iob-output-$PREFIX.csv
}
load_full_speed() {
	# overwrite the device $1 times (x capacity) with the measurement pattern at full speed
	OVERWRITES=$1
	$SUDO FILENAME=$FILENAME INIT=false IO_SIZE_PERCENT_FILE=$OVERWRITES IO_DEPTH=128 BS=$UNI_BS THREADS=4 \
		PATTERN=$PATTERN_ARG RW=1 iob/iob >> iob-output-$PREFIX.csv
}
run_ops_exp_rate() {
	RATE_MBS=$1
	$SUDO FILENAME=$FILENAME INIT=false RUNTIME=$RUNTIME WRITE_RATE_MBS=$RATE_MBS IO_DEPTH=128 BS=$UNI_BS THREADS=4 \
		PATTERN=$PATTERN_ARG RW=1 iob/iob >> iob-output-$PREFIX.csv
}

# load once
sanitize_nvme_and_init
load_full_speed $LOAD_OVERWRITES

# vary write intensity, no reload in between; before each rate, write 1x the
# capacity at full bandwidth so every rate starts from the same full-bw state
for RATE in $WRITE_RATES; do
	sleep $SLEEP_BETWEEN
	load_full_speed $REFRESH_OVERWRITES
	run_ops_exp_rate $RATE
done

# summary: average achieved write IOPS / MiB/s per target rate (measurement rows only, skip 10s warmup)
awk -F, '$(NF-1)=="measure" && $NF > 0 && $5+0 > 10 { sum[$NF]+=$19; mbs[$NF]+=$21; cnt[$NF]++ }
	END { for (r in sum) printf "target %s MiB/s: avg %.0f write IOPS (%.0f MiB/s)\n", r, sum[r]/cnt[r], mbs[r]/cnt[r] }' \
	iob-log-$PREFIX.csv | sort -n -t' ' -k2
