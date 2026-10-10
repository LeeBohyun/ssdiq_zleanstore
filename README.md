<div align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="logo/logo.svg">
    <source media="(prefers-color-scheme: dark)" srcset="logo/logo-dark.svg">
    <img alt="ZLeanStore logo" src="logo/logo.svg" height="80">
  </picture>
</div>

# SSD-iq for ZLeanStore

This repository contains benchmarking and simulation tools for **ZLeanStore**.

The ZNS-like write pattern, the **NOWA (No Write Amplification)** pattern, and an LSM-engine-like write pattern have been added.  
Furthermore, a naive wear-leveling algorithm has been added to the SSD simulator.

---

## Repository Contents

- `iob/` — I/O benchmarking tool with support for ZNS and zone-aware patterns  
- `sim/` — Simulator for zone-based GC and cleaning behavior  
- `shared/` — Shared utilities and workload generators  
  - `patterngen.hpp` — Implementation of access patterns (uniform, zipf, zones, NOWA, etc.)  
- `scripts/` — Automation for running experiments (both simulated and real SSDs)  
- `paper/` — Plotting and analysis scripts  

---

## Access Patterns

### Uniform

Random uniform access over the logical address space.  
Overwrites freely, used as a baseline.

```sh
PATTERN=uniform
```

---

### Zipf

Skewed random access following a Zipfian distribution.  
Models hot/cold separation, overwrite-heavy.

```sh
PATTERN=zipf
ZIPF=0.9
```

---

### Zones

Multiple logical zones with independent sequential write pointers.  
Zones can be interleaved and allow overwrites after resets.

```sh
PATTERN=zones
ZONES="s0.9 f0.1 s0.1 f0.9"
```
---

### ZNS-like pattern

Strictly ZNS-like workload:

- Sequential writes per zone  
- Models host-managed ZNS behavior

```sh
PATTERN=zns
```
#### Optional Parameters

| Variable | Description |
|----------|-------------|
| `ZNS_ACTIVE_ZONES` | Number of concurrently open zones |
| `ZNS_ZONE_SIZE` | Size of each zone |

Example:

```sh
PATTERN=zns ZNS_ACTIVE_ZONES=14 ZNS_ZONE_SIZE=1024M RATE=0
```

---

### NOWA (No Write Amplification write pattern)

For how ZLeanStore writes to the SSD using this pattern, see the [ZLeanStore repository](https://github.com/LeeBohyun/ZLeanStore).

Write pattern that guarantees SSD WAF ~= 1:

- Sequential writes per zone  
- Estimate multiplexing within concurrently open zones and issue compensation writes
- Targets WAF ≈ 1  

```sh
PATTERN=nowa
```

#### Optional Parameters

| Variable | Description |
|----------|-------------|
| `ZNS_ACTIVE_ZONES` | Number of concurrently open zones |
| `ZNS_ZONE_SIZE` | Size of each zone |

Example:

```sh
PATTERN=nowa ZNS_ACTIVE_ZONES=64 ZNS_ZONE_SIZE=128M RATE=0
```

---

## WAF vs. Write Intensity

`iob` can measure the SSD WAF (from the OCP smart log) while throttling writes to a fixed target rate. A run is split into two phases:

- **Load phase** — the first `LOAD_IO_SIZE` bytes (or `LOAD_PERCENT_FILE` × device size) are written at full speed to bring the SSD to steady state.
- **Measurement phase** — writes are throttled to `WRITE_RATE_MBS` MiB/s. `RUNTIME` counts from the start of this phase.

| Variable | Description |
|----------|-------------|
| `WRITE_RATE_MBS` | Target write rate in MiB/s during the measurement phase (overrides `RATE`, requires `RW` > 0) |
| `LOAD_IO_SIZE` | Amount written at full speed before throttling kicks in (e.g. `100G`) |
| `LOAD_PERCENT_FILE` | Alternative to `LOAD_IO_SIZE`: multiple of the device size (e.g. `2` = two full overwrites) |

Each per-second line in `iob-log-<prefix>.csv` is tagged with `phase` (`load`/`measure`) and `targetWriteMBs`; the `wa` column contains the WAF for that interval.

Example — two full-speed overwrites, then 30 minutes measured at 200 MiB/s:

```sh
sudo -E FILENAME=/dev/nvme1n1 PATTERN=uniform RW=1 THREADS=4 IO_DEPTH=128 BS=4K \
  LOAD_PERCENT_FILE=2 WRITE_RATE_MBS=200 RUNTIME=1800 iob/iob
```

`scripts/benchwarate.sh` automates this over a list of write intensities (sanitize + init before each rate):

```sh
WRITE_RATES="400 200 10" ./benchwarate.sh /dev/nvme1n1 myprefix uniform
```

---

## Building

### Dependencies

```sh
apt install cmake build-essential nvme-cli libaio-dev liburing-dev libnvme-dev
```

### Build

```sh
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make
```

---

## Running IOB

### Simple NOWA Example


```sh
PATTERN=nowa ZNS_ACTIVE_ZONES=64 ZNS_ZONE_SIZE=128M RATE=0 \
iob/iob --filename=/blk/w0 --rw=1
```

---

## Simulator

```sh
sim/sim --capacity=20G --erase=1M --page=4k --ssdfill=0.875 \
  --pattern=zones --zones="s0.9 f0.1 s0.1 f0.9" --gc=greedy --writes=10
```

---

## Benchmarks & Reproducibility

### Scripts

- `benchwa.sh` — Write amplification experiments  
- `benchwarate.sh` — Write amplification vs. write intensity (full-speed load, rate-limited measurement)  
- `benchopsrate.sh` — Ops/s vs. write intensity on a 100% full SSD (load once, then vary the rate; full-bw refresh before each rate)  
- `benchopsrateall.sh` — Run `benchopsrate.sh` on multiple SSDs in parallel (device list or `VENDOR=` filter)  
- `benchwafill.sh` — Write throughput (and WAF on OCP drives) vs. fill factor (20–100%), uniform overwrites per fill level  
- `benchwafillall.sh` — Run `benchwafill.sh` on multiple SSDs in parallel (device list or `VENDOR=` filter)  
- `benchseq.sh` — Sequential and ZNS/NOWA workloads  
- `benchlat.sh` — Latency under load  
- `benchbench.sh` — Summary table generation  

### Analysis

- `paper.R` — Throughput and WAF plots  
- `latency.R` — Latency plots  
- `plotsim.R` — Simulator plots  

---

## Citation
- For original SSD-iq paper:
```bibtex
@article{DBLP:journals/pvldb/HaasLBL25,
  author       = {Gabriel Haas and Bohyun Lee and Philippe Bonnet and Viktor Leis},
  title        = {SSD-iq: Uncovering the Hidden Side of SSD Performance},
  journal      = {Proc. VLDB Endow.},
  volume       = {18},
  number       = {11},
  pages        = {4295--4308},
  year         = {2025}
}
```

---

## License

This project is licensed under the MIT License.
