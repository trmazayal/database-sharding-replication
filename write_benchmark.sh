#!/bin/bash
set -e

# Default parameters
USERS=${USERS:-50}  # Default to fewer users for write benchmarks
SPAWN_RATE=${SPAWN_RATE:-5}  # Slower spawn rate for writes
RUN_TIME=${RUN_TIME:-60}

# Create a descriptive results directory
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULTS_DIR="benchmark_results/write_benchmark_${TIMESTAMP}"
mkdir -p $RESULTS_DIR

echo "Starting WRITE-ONLY benchmark with $USERS users for $RUN_TIME seconds"
echo "Results will be saved to $RESULTS_DIR"

# Run the benchmark with write-only flag
USERS=$USERS SPAWN_RATE=$SPAWN_RATE RUN_TIME=$RUN_TIME ./run_locust_benchmark.sh --write-only

# Copy the results to the specific directory
cp benchmark_results/locust_write-only.log $RESULTS_DIR/
cp benchmark_results/locust_metrics_*.json $RESULTS_DIR/

echo "Benchmark complete! Results saved to $RESULTS_DIR"
echo "Summary of throughput and latency metrics:"
echo "----------------------------------------"

# Use a more targeted approach to extract and display metrics
METRICS_FILE=$(find $RESULTS_DIR -name "locust_metrics_*.json" | head -1)
if [ -f "$METRICS_FILE" ]; then
    echo "Write Latency (ms):"
    echo "  Average: $(grep -o '"avg": [0-9.]*' "$METRICS_FILE" | grep -m1 -o '[0-9.]*')"
    echo "  Min: $(grep -o '"min": [0-9.]*' "$METRICS_FILE" | grep -m1 -o '[0-9.]*')"
    echo "  Max: $(grep -o '"max": [0-9.]*' "$METRICS_FILE" | grep -m1 -o '[0-9.]*')"
    echo "  P95: $(grep -o '"p95": [0-9.]*' "$METRICS_FILE" | grep -m1 -o '[0-9.]*')"

    echo "Throughput:"
    echo "  Operations/sec: $(grep -o '"total": [0-9.]*' "$METRICS_FILE" | grep -m1 -o '[0-9.]*')"
    echo "  Write ops/sec: $(grep -o '"write": [0-9.]*' "$METRICS_FILE" | grep -o '[0-9.]*' | head -1)"

    echo "Success Rate: $(grep -o '"success_rate": [0-9.]*' "$METRICS_FILE" | grep -o '[0-9.]*')%"
else
    echo "No metrics file found in $RESULTS_DIR"
fi
