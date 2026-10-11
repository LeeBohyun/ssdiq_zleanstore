#!/bin/bash
set -x

# Read latency under a random 4K writer pinned to the SAME absolute IOPS at
# two fill factors (100% and 50%). The writer target is IOPS_FRACTION (default
# 25%) of the drive's measured clean-state max random-write IOPS, so the host
# write load is identical across fills and only the fill factor (and thus the
# WAF/GC pressure) differs. Reader: READ_THREADS x READ_RATE_MBS_PER_THREAD
# random 4K reads. Run as root from the build dir.
#
# Usage: [IOPS_FRACTION=0.25] [MEASURE_RUNTIME=300] ./benchreadlatiops.sh <device> <prefix>

DEV=$1
PREFIX=$2
if [ -z "$DEV" ] || [ -z "$PREFIX" ]; then
	echo "usage: $0 <device> <prefix>"
	exit 1
fi

IOPS_FRACTION=${IOPS_FRACTION:-0.25}
READ_RATE_MBS_PER_THREAD=${READ_RATE_MBS_PER_THREAD:-40}
READ_THREADS=${READ_THREADS:-4}
READ_BS=${READ_BS:-4K}
# 1200s at 10240 IOPS/thread = ~12M samples per thread, enough for 6-nines
# percentiles; the reader uses ONE stats window spanning the whole measurement
MEASURE_RUNTIME=${MEASURE_RUNTIME:-1230}
STATS_WINDOW=$((MEASURE_RUNTIME - 30)) # must complete within the runtime (no final flush)
WRITER_RUNTIME=$((MEASURE_RUNTIME + 120))

READ_IOPS=$((READ_RATE_MBS_PER_THREAD * READ_THREADS * 256)) # 256 = MiB / 4KiB

sanitize_nvme() {
	nvme sanitize --sanact=2 "$DEV" && sleep 120 && nvme sanitize-log "$DEV" && sleep 10
	blkdiscard -v "$DEV"
	sleep 60
}

# 1) clean state, full init, measure clean-state max random-write IOPS (60s)
sanitize_nvme
FILENAME=$DEV PREFIX=$PREFIX-init INIT=yes IO_SIZE=0 IO_DEPTH=128 BS=4K THREADS=1 RW=1 \
	iob/iob >> iob-output-$PREFIX.csv 2>&1
FILENAME=$DEV PREFIX=$PREFIX-maxiops INIT=false RUNTIME=60 IO_DEPTH=128 BS=4K THREADS=4 \
	PATTERN=uniform RW=1 iob/iob >> iob-output-$PREFIX.csv 2>&1
MAXIOPS=$(awk -F, '$1=="keep" && $5+0 > 10 { s+=$19; n++ } END { printf "%d", (n ? s/n : 0) }' iob-log-$PREFIX-maxiops.csv)
RATE_MBS=$(awk "BEGIN{printf \"%.0f\", $MAXIOPS * $IOPS_FRACTION / 256}")
echo "clean-state max: $MAXIOPS IOPS, writer target: $(awk "BEGIN{printf \"%.0f\", $MAXIOPS * $IOPS_FRACTION}") IOPS ($RATE_MBS MiB/s)"
if [ "$RATE_MBS" -le 0 ]; then echo "max IOPS measurement failed"; exit 1; fi

run_phase() {
	FILLV=$1
	TAG=$2
	# writer: fixed IOPS target (via WRITE_RATE_MBS at 4K), random 4K
	FILENAME=$DEV PREFIX=$PREFIX-$TAG-w FILL=$FILLV INIT=false RUNTIME=$WRITER_RUNTIME WRITE_RATE_MBS=$RATE_MBS \
		IO_DEPTH=128 BS=4K THREADS=4 PATTERN=uniform RW=1 iob/iob >> iob-output-$PREFIX.csv 2>&1 &
	WPID=$!
	sleep 60
	FILENAME=$DEV PREFIX=$PREFIX-$TAG-r FILL=$FILLV INIT=disable RUNTIME=$MEASURE_RUNTIME RATE=$READ_IOPS \
		THREAD_STATS_INTERVAL=$STATS_WINDOW \
		IO_DEPTH=64 BS=$READ_BS THREADS=$READ_THREADS PATTERN=uniform RW=0 iob/iob >> iob-output-$PREFIX.csv 2>&1
	wait $WPID
	sleep 30
}

# 2) fill=1.0: precondition 1x capacity random, then measure
FILENAME=$DEV PREFIX=$PREFIX-precond100 INIT=false IO_SIZE_PERCENT_FILE=1 \
	IO_DEPTH=128 BS=4K THREADS=4 PATTERN=uniform RW=1 iob/iob >> iob-output-$PREFIX.csv 2>&1
run_phase 1 f100

# 3) fill=0.5: re-init at 50%, precondition 2x the used region, then measure
sanitize_nvme
FILENAME=$DEV PREFIX=$PREFIX-init50 FILL=0.5 INIT=yes IO_SIZE=0 IO_DEPTH=128 BS=4K THREADS=1 RW=1 \
	iob/iob >> iob-output-$PREFIX.csv 2>&1
FILENAME=$DEV PREFIX=$PREFIX-precond50 FILL=0.5 INIT=false IO_SIZE_PERCENT_FILE=1 \
	IO_DEPTH=128 BS=4K THREADS=4 PATTERN=uniform RW=1 iob/iob >> iob-output-$PREFIX.csv 2>&1
run_phase 0.5 f50

set +x
for TAG in f100 f50; do
	echo "=== $TAG: writer achieved (IOPS, MiB/s, WAF) vs target $RATE_MBS MiB/s:"
	awk -F, '$1=="keep" && $5+0 > 30 { iops+=$19; mbs+=$21; n++; if ($(NF-2)+0>0) { wa+=$(NF-2); wn++ } }
		END { if (n) printf "  %.0f IOPS, %.0f MiB/s, WAF %.2f\n", iops/n, mbs/n, (wn ? wa/wn : 0) }' iob-log-$PREFIX-$TAG-w.csv
	echo "=== $TAG: read latency (us, one full-run window per thread, averaged over threads):"
	awk -F, '$1=="hash" { for (i=1;i<=NF;i++) h[$i]=i; next }
		{ n++; s50+=$h["r50p"]; s99+=$h["r99p"]; s999+=$h["r99p9"]; s9999+=$h["r99p99"];
		  s99999+=$h["r99p999"]; s999999+=$h["r99p9999"]; cnt+=$h["rcnt"];
		  if ($h["rmax"]+0 > mx) mx=$h["rmax"] }
		END { if (n) printf "  p50 %.0f  p99 %.0f  p99.9 %.0f  p99.99 %.0f  p99.999 %.0f  p99.9999 %.0f  max %.0f  (samples %d)\n",
			s50/n, s99/n, s999/n, s9999/n, s99999/n, s999999/n, mx, cnt }' iob-stats-id*-$PREFIX-$TAG-r.csv
done
echo "$PREFIX same-IOPS fill comparison done"
