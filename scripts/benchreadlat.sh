#!/bin/bash
set -x

# Read latency distribution under concurrent writes, at 100% fill, in two SSD
# states: WAF~1 (sequential steady state, sequential writer) and WAF~high
# (random steady state, random 4K writer). The writer is rate-limited to half
# the measured sequential bandwidth; a second iob process issues rate-limited
# random 4K reads (READ_THREADS x READ_RATE_MBS_PER_THREAD) and records the
# read latency histograms in iob-stats-id*-<prefix>-waf{1,4}-r.csv (us).
# Run as root from the build directory (uses two concurrent iob processes).
#
# Usage: [MEASURE_RUNTIME=300] [PRECOND_OVERWRITES=1] ./benchreadlat.sh <device> <prefix>

DEV=$1
PREFIX=$2
if [ -z "$DEV" ] || [ -z "$PREFIX" ]; then
	echo "usage: $0 <device> <prefix>"
	exit 1
fi

READ_RATE_MBS_PER_THREAD=${READ_RATE_MBS_PER_THREAD:-40}
READ_THREADS=${READ_THREADS:-4}
READ_BS=${READ_BS:-4K}
MEASURE_RUNTIME=${MEASURE_RUNTIME:-300}
PRECOND_OVERWRITES=${PRECOND_OVERWRITES:-1} # full-speed random overwrites (x capacity) before the WAF-high phase
WRITER_RUNTIME=$((MEASURE_RUNTIME + 120))   # writer spans reader warmup + measurement

READ_IOPS=$((READ_RATE_MBS_PER_THREAD * READ_THREADS * 256)) # 256 = MiB / 4KiB

sanitize_nvme() {
	nvme sanitize --sanact=2 "$DEV" && sleep 120 && nvme sanitize-log "$DEV" && sleep 10
	blkdiscard -v "$DEV"
	sleep 60
}

# 1) clean state: sanitize + full sequential init
sanitize_nvme
FILENAME=$DEV PREFIX=$PREFIX-init INIT=yes IO_SIZE=0 IO_DEPTH=128 BS=4K THREADS=1 RW=1 \
	iob/iob >> iob-output-$PREFIX.csv 2>&1

# 2) measure achievable sequential write bandwidth (60s full speed)
FILENAME=$DEV PREFIX=$PREFIX-seqbw INIT=false RUNTIME=60 IO_DEPTH=128 BS=512K THREADS=1 \
	PATTERN=sequential-noshuffle RW=1 iob/iob >> iob-output-$PREFIX.csv 2>&1
SEQBW=$(awk -F, '$1=="keep" && $5+0 > 10 { s+=$21; n++ } END { printf "%d", (n ? s/n : 0) }' iob-log-$PREFIX-seqbw.csv)
HALFBW=$((SEQBW / 2))
echo "measured seq bw: $SEQBW MiB/s, writer rate: $HALFBW MiB/s"
if [ "$HALFBW" -le 0 ]; then echo "seq bw measurement failed"; exit 1; fi

run_phase() {
	PHASE=$1        # waf1 | waf4
	WPATTERN=$2     # sequential-noshuffle | uniform
	WBS=$3          # 512K | 4K
	WTHREADS=$4     # 1 | 4
	# writer: half of seq bw in the background
	FILENAME=$DEV PREFIX=$PREFIX-$PHASE-w INIT=false RUNTIME=$WRITER_RUNTIME WRITE_RATE_MBS=$HALFBW \
		IO_DEPTH=128 BS=$WBS THREADS=$WTHREADS PATTERN=$WPATTERN RW=1 iob/iob >> iob-output-$PREFIX.csv 2>&1 &
	WPID=$!
	sleep 60 # let the writer reach its steady rate
	# reader: rate-limited random reads, latency tracked
	FILENAME=$DEV PREFIX=$PREFIX-$PHASE-r INIT=disable RUNTIME=$MEASURE_RUNTIME RATE=$READ_IOPS \
		IO_DEPTH=64 BS=$READ_BS THREADS=$READ_THREADS PATTERN=uniform RW=0 iob/iob >> iob-output-$PREFIX.csv 2>&1
	wait $WPID
	sleep 30
}

# 3) WAF~1: sequential steady state, sequential writer
run_phase waf1 sequential-noshuffle 512K 1

# 4) precondition to random steady state (WAF rises to the drive's full-capacity value)
FILENAME=$DEV PREFIX=$PREFIX-precond INIT=false IO_SIZE_PERCENT_FILE=$PRECOND_OVERWRITES \
	IO_DEPTH=128 BS=4K THREADS=4 PATTERN=uniform RW=1 iob/iob >> iob-output-$PREFIX.csv 2>&1

# 5) WAF~high: random steady state, random 4K writer
run_phase waf4 uniform 4K 4

set +x
for PHASE in waf1 waf4; do
	echo "=== $PHASE: writer achieved (MiB/s, WAF):"
	awk -F, '$1=="keep" && $5+0 > 30 { mbs+=$21; n++; if ($(NF-2)+0>0) { wa+=$(NF-2); wn++ } }
		END { if (n) printf "  %.0f MiB/s, WAF %.2f\n", mbs/n, (wn ? wa/wn : 0) }' iob-log-$PREFIX-$PHASE-w.csv
	echo "=== $PHASE: read latency (us, averaged over 60s windows and threads):"
	awk -F, '$1=="hash" { for (i=1;i<=NF;i++) h[$i]=i; next }
		{ n++; s50+=$h["r50p"]; s99+=$h["r99p"]; s999+=$h["r99p9"]; s9999+=$h["r99p99"];
		  if ($h["rmax"]+0 > mx) mx=$h["rmax"] }
		END { if (n) printf "  p50 %.0f  p99 %.0f  p99.9 %.0f  p99.99 %.0f  max %.0f\n",
			s50/n, s99/n, s999/n, s9999/n, mx }' iob-stats-id*-$PREFIX-$PHASE-r.csv
done
echo "$PREFIX read latency experiment done"
