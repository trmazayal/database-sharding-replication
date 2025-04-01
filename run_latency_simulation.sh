#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if Python and required modules are installed
echo -e "${YELLOW}Checking for required Python packages...${NC}"
python3 -c "import matplotlib, numpy" || {
    echo -e "${RED}Missing required Python packages.${NC}"
    echo "Installing matplotlib and numpy..."
    pip3 install matplotlib numpy || {
        echo -e "${RED}Failed to install packages. Please run: pip3 install matplotlib numpy${NC}"
        exit 1
    }
}

# Create directory for output
mkdir -p latency_trends

# Ensure the simulator script is executable
chmod +x latency_trend_simulator.py

# Parse command line arguments
PATTERN="cyclic"
DURATION=300
SIMULATE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --pattern)
            PATTERN="$2"
            shift 2
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --simulate)
            SIMULATE=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            echo "Usage: ./run_latency_simulation.sh [--pattern steady|cyclic|increasing|decreasing|step] [--duration seconds] [--simulate]"
            exit 1
            ;;
    esac
done

# Validate pattern
if [[ ! "$PATTERN" =~ ^(steady|cyclic|increasing|decreasing|step)$ ]]; then
    echo -e "${RED}Invalid pattern: $PATTERN${NC}"
    echo "Valid patterns: steady, cyclic, increasing, decreasing, step"
    exit 1
fi

# Build the command
CMD="./latency_trend_simulator.py --pattern $PATTERN --duration $DURATION"

if [ "$SIMULATE" = true ]; then
    CMD="$CMD --simulate"
    echo -e "${YELLOW}Running in simulation mode (no actual database queries)${NC}"
fi

echo -e "${GREEN}Starting latency trend simulation with $PATTERN pattern...${NC}"
echo "Duration: $DURATION seconds"
echo "Press Ctrl+C to stop early"
echo

# Run the simulator
eval $CMD

echo -e "${GREEN}Simulation complete.${NC}"
echo "Check the latency_trends directory for saved visualizations."
