#!/bin/bash
set -x

# Run the WAF vs. fill factor sweep (benchwafill.sh) on multiple SSDs in parallel.
#
#   ./benchwafillall.sh <prefix> /dev/nvme1n1 /dev/nvme2n1 ...
# or auto-detect devices from `nvme list` (asks for confirmation, DESTROYS all
# data; set ASSUME_YES=1 to skip the prompt for nohup/tmux runs). The default
# model filter matches AWS instance-store NVMe drives (never the EBS root
# volume); override it with VENDOR=<model substring>:
#   ./benchwafillall.sh <prefix>
#
# FILLS / OVERWRITE are passed through to benchwafill.sh.

PREFIX=$1
shift
DEVICES="$@"

if [ -z "$PREFIX" ]; then
	echo "usage: $0 <prefix> [device ...]"
	exit 1
fi

script_full_path=$(dirname "$0")
cd $script_full_path
pwd

sudo -v # cache sudo credentials before going to the background

if [ -z "$DEVICES" ]; then
	VENDOR=${VENDOR:-"Instance Storage"} # AWS instance-store NVMe model string, never matches the EBS root volume
	DEVICES=$(sudo nvme list | grep -i "$VENDOR" | awk '{print $1}')
	if [ -z "$DEVICES" ]; then
		echo "no devices matching '$VENDOR' found"
		exit 1
	fi
	echo "auto-detected devices matching '$VENDOR': $DEVICES"
	if [ "$ASSUME_YES" != "1" ]; then
		echo "ALL DATA on these devices will be DESTROYED. Type yes to continue:"
		read -r CONFIRM
		[ "$CONFIRM" == "yes" ] || exit 1
	fi
fi

# build once so the parallel children only do a no-op make
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j iob

# stop all children when script is terminated
trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT

for DEV in $DEVICES; do
	FILLS="$FILLS" OVERWRITE="$OVERWRITE" ./benchwafill.sh $DEV $(basename $DEV)-$PREFIX > benchwafill-$(basename $DEV)-$PREFIX.log 2>&1 &
	sleep 10s
done

wait $(jobs -p)
echo "all devices done"
