#!/bin/bash
set -x

# Read latency under a random 4K writer at reduced fill factor (default 50%).
# Companion to benchreadlat.sh: same reader (READ_THREADS x
# READ_RATE_MBS_PER_THREAD random 4K reads) and the same writer rate (half the
# measured sequential bandwidth), but the write pattern is random 4K in a
# FILL x capacity region - so compared to the 100%-fill random phase, only the
# fill factor (and thus the WAF) changes. Run as root from the build dir.
#
# Usage: [FILL=0.5] [MEASURE_RUNTIME=300] ./benchreadlatfill.sh <device> <prefix>

DEV=$1
PREFIX=$2
if [ -z "$DEV" ] || [ -z "$PREFIX" ]; then
	echo "usage: $0 <device> <prefix>"
	exit 1
fi

FILL=${FILL:-0.5}
READ_RATE_MBS_PER_THREAD=${READ_RATE_MBS_PER_THREAD:-40}
READ_THREADS=${READ_THREADS:-4}
READ_BS=${READ_BS:-4K}
MEASURE_RUNTIME=${MEASURE_RUNTIME:-300}
WRITER_RUNTIME=$((MEASURE_RUNTIME + 120))

READ_IOPS=$((READ_RATE_MBS_PER_THREAD * READ_THREADS * 256)) # 256 = MiB / 4KiB

# 1) clean state, init the first FILL x capacity
nvme sanitize --sanact=2 "$DEV" && sleep 120 && nvme sanitize-log "$DEV" && sleep 10
blkdiscard -v "$DEV"
sleep 60
FILENAME=$DEV PREFIX=$PREFIX-init FILL=$FILL INIT=yes IO_SIZE=0 IO_DEPTH=128 BS=4K THREADS=1 RW=1 \
	iob/iob >> iob-output-$PREFIX.csv 2>&1

# 2) measure achievable sequential write bandwidth (60s full speed)
FILENAME=$DEV PREFIX=$PREFIX-seqbw FILL=$FILL INIT=false RUNTIME=60 IO_DEPTH=128 BS=512K THREADS=1 \
	PATTERN=sequential-noshuffle RW=1 iob/iob >> iob-output-$PREFIX.csv 2>&1
SEQBW=$(awk -F, '$1=="keep" && $5+0 > 10 { s+=$21; n++ } END { printf "%d", (n ? s/n : 0) }' iob-log-$PREFIX-seqbw.csv)
HALFBW=$((SEQBW / 2))
echo "measured seq bw: $SEQBW MiB/s, writer rate: $HALFBW MiB/s"
if [ "$HALFBW" -le 0 ]; then echo "seq bw measurement failed"; exit 1; fi

# 3) precondition: 2x the used region of uniform random 4K at full speed
IOPF=$(awk "BEGIN{print 2 * $FILL}")
FILENAME=$DEV PREFIX=$PREFIX-precond FILL=$FILL INIT=false IO_SIZE_PERCENT_FILE=$IOPF \
	IO_DEPTH=128 BS=4K THREADS=4 PATTERN=uniform RW=1 iob/iob >> iob-output-$PREFIX.csv 2>&1

# 4) measurement: random 4K writer at half seq bw + rate-limited reader
FILENAME=$DEV PREFIX=$PREFIX-w FILL=$FILL INIT=false RUNTIME=$WRITER_RUNTIME WRITE_RATE_MBS=$HALFBW \
	IO_DEPTH=128 BS=4K THREADS=4 PATTERN=uniform RW=1 iob/iob >> iob-output-$PREFIX.csv 2>&1 &
WPID=$!
sleep 60
FILENAME=$DEV PREFIX=$PREFIX-r FILL=$FILL INIT=disable RUNTIME=$MEASURE_RUNTIME RATE=$READ_IOPS \
	IO_DEPTH=64 BS=$READ_BS THREADS=$READ_THREADS PATTERN=uniform RW=0 iob/iob >> iob-output-$PREFIX.csv 2>&1
wait $WPID

set +x
echo "=== fill=$FILL: writer achieved (MiB/s, WAF):"
awk -F, '$1=="keep" && $5+0 > 30 { mbs+=$21; n++; if ($(NF-2)+0>0) { wa+=$(NF-2); wn++ } }
	END { if (n) printf "  %.0f MiB/s, WAF %.2f\n", mbs/n, (wn ? wa/wn : 0) }' iob-log-$PREFIX-w.csv
echo "=== fill=$FILL: read latency (us, averaged over 60s windows and threads):"
awk -F, '$1=="hash" { for (i=1;i<=NF;i++) h[$i]=i; next }
	{ n++; s50+=$h["r50p"]; s99+=$h["r99p"]; s999+=$h["r99p9"]; s9999+=$h["r99p99"];
	  if ($h["rmax"]+0 > mx) mx=$h["rmax"] }
	END { if (n) printf "  p50 %.0f  p99 %.0f  p99.9 %.0f  p99.99 %.0f  max %.0f\n",
		s50/n, s99/n, s999/n, s9999/n, mx }' iob-stats-id*-$PREFIX-r.csv
echo "$PREFIX read latency (fill=$FILL) experiment done"
