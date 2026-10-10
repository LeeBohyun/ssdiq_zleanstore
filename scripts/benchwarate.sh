#!/bin/bash
set -x

# Measure SSD WAF under different write intensities.
# For each rate: sanitize + sequential init, then one iob run that first writes
# LOAD_PERCENT_FILE x the device at full speed (load phase) and then measures
# for RUNTIME seconds with writes throttled to WRITE_RATE_MBS MiB/s.
# The iob-log-$PREFIX.csv has per-second WAF with phase (load/measure) and
# targetWriteMBs columns.
#
# Usage: [WRITE_RATES="400 200 10"] ./benchwarate.sh <device> <prefix> [pattern] [bs]
# Pattern parameters (ZIPF, ZONES, ZNS_*) can be exported by the caller.

FILENAME=$1
export FILESIZE= # let iob figure it out
export PREFIX=$2
PATTERN_ARG=${3:-uniform}
UNI_BS=${4:-4K}

WRITE_RATES=${WRITE_RATES:-"400 200 10"}          # MiB/s write intensity during measurement
LOAD_PERCENT_FILE=${LOAD_PERCENT_FILE:-2}         # full-speed overwrites of the device before measuring
RUNTIME=${RUNTIME:-1800}                          # measurement seconds per rate (starts after load phase)

export IOENGINE=io_uring
export FILL=${FILL:-1}

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
	sudo -E FILENAME=$FILENAME INIT=yes IO_SIZE_PERCENT_FILE=0.01 IO_DEPTH=1 BS=4K THREADS=1 PATTERN=sequential RW=1 iob/iob >> iob-output-$PREFIX.csv
}
run_wa_exp_rate() {
	RATE_MBS=$1
	sudo -E FILENAME=$FILENAME INIT=false RUNTIME=$RUNTIME LOAD_PERCENT_FILE=$LOAD_PERCENT_FILE WRITE_RATE_MBS=$RATE_MBS \
		IO_DEPTH=128 BS=$UNI_BS THREADS=4 PATTERN=$PATTERN_ARG RW=1 iob/iob >> iob-output-$PREFIX.csv
	sleep 2m
}

for RATE in $WRITE_RATES; do
	sanitize_nvme_and_init
	run_wa_exp_rate $RATE
done
