#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check for required Python packages
echo -e "${YELLOW}Checking for required Python packages...${NC}"
pip3 install --quiet matplotlib pandas numpy seaborn || {
    echo -e "${RED}Error installing required Python packages.${NC}"
    echo "Please run: pip3 install matplotlib pandas numpy seaborn"
    exit 1
}

# Create results directory and subdirectories
mkdir -p benchmark_results
mkdir -p benchmark_results/graphs

# Run pre-benchmark checks
echo -e "${YELLOW}Running pre-benchmark checks...${NC}"
./pre-benchmark.sh || {
    echo -e "${RED}Pre-benchmark checks failed. Please fix the issues and try again.${NC}"
    exit 1
}

# Fix pgbench installation issues
echo -e "${YELLOW}Fixing pgbench installation if needed...${NC}"
./fix-pgbench.sh || {
    echo -e "${RED}Failed to fix pgbench issues. Some benchmarks may not work correctly.${NC}"
}

# Run all benchmark scripts
echo -e "${GREEN}Starting benchmark suite...${NC}"
echo "================================================"

# Standard benchmarks
echo -e "${YELLOW}Running standard benchmarks...${NC}"
./benchmark.sh

# Worker benchmarks
echo -e "\n${YELLOW}Running worker node benchmarks...${NC}"
./worker-benchmark.sh

# Read/Write latency benchmarks
echo -e "\n${YELLOW}Running read/write latency benchmarks...${NC}"
./latency-benchmark.sh

# High availability benchmarks (if available)
if [ -f "./ha-benchmark.sh" ]; then
    echo -e "\n${YELLOW}Running high availability benchmarks...${NC}"
    ./ha-benchmark.sh
fi

echo -e "\n${GREEN}All benchmarks completed.${NC}"
echo "================================================"

# Generate visualizations
echo -e "${YELLOW}Generating benchmark visualizations...${NC}"
python3 visualize_benchmarks.py

# Open the HTML report (works on Mac)
REPORT_PATH="benchmark_results/benchmark_report.html"
if [ -f "$REPORT_PATH" ]; then
    echo -e "${GREEN}Opening benchmark report...${NC}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        open "$REPORT_PATH"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        xdg-open "$REPORT_PATH" 2>/dev/null || {
            echo -e "${YELLOW}View benchmark report at:${NC} $REPORT_PATH"
        }
    else
        echo -e "${YELLOW}View benchmark report at:${NC} $REPORT_PATH"
    fi
else
    echo -e "${RED}Benchmark report not found.${NC}"
fi

echo -e "${GREEN}Benchmark suite completed!${NC}"
echo "================================================"
