#!/bin/bash
set -e

# Default parameters
USERS=${USERS:-100}
SPAWN_RATE=${SPAWN_RATE:-10}
RUN_TIME=${RUN_TIME:-60}
READ_RATIO=${READ_RATIO:-80}
WRITE_RATIO=${WRITE_RATIO:-20}

# Create a descriptive results directory
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULTS_DIR="benchmark_results/mixed_benchmark_${READ_RATIO}_${WRITE_RATIO}_${TIMESTAMP}"
mkdir -p $RESULTS_DIR

echo "Starting MIXED benchmark (${READ_RATIO}% read, ${WRITE_RATIO}% write) with $USERS users for $RUN_TIME seconds"
echo "Results will be saved to $RESULTS_DIR"

# Run the benchmark with mixed read/write ratio
USERS=$USERS SPAWN_RATE=$SPAWN_RATE RUN_TIME=$RUN_TIME READ_WEIGHT=$READ_RATIO WRITE_WEIGHT=$WRITE_RATIO ./run_locust_benchmark.sh --read-write-ratio=$READ_RATIO:$WRITE_RATIO

# Copy the results to the specific directory
cp benchmark_results/locust_mixed_*.log $RESULTS_DIR/ 2>/dev/null || true
cp benchmark_results/locust_metrics_*.json $RESULTS_DIR/

echo "Benchmark complete! Results saved to $RESULTS_DIR"
echo "Summary of throughput and latency metrics:"
echo "----------------------------------------"
cat $RESULTS_DIR/locust_metrics_*.json | grep -E '"throughput_ops_sec"|"read_latency_ms"|"write_latency_ms"|"success_rate"'
