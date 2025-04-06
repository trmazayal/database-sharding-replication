#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if we're running in virtual environment
if [[ -z "$VIRTUAL_ENV" && ! -f "venv/bin/python" ]]; then
    echo -e "${YELLOW}Not running in a virtual environment. Creating one...${NC}"
    python3 -m venv venv
    source venv/bin/activate
    pip install --upgrade pip
    pip install flask psycopg2-binary locust geojson
else
    if [[ -z "$VIRTUAL_ENV" ]]; then
        # Activate virtual environment if not already activated
        echo -e "${YELLOW}Activating virtual environment...${NC}"
        source venv/bin/activate
    fi
fi

# Create necessary directories
mkdir -p templates
mkdir -p static
mkdir -p benchmark_results

# Check if Python and locust are installed
if ! python -c "import flask, locust" &> /dev/null; then
    echo -e "${YELLOW}Installing required packages...${NC}"
    pip install flask psycopg2-binary locust geojson
fi

# Make the benchmark scripts executable
chmod +x run_locust_benchmark.sh read_benchmark.sh write_benchmark.sh

echo -e "${GREEN}Starting the web UI on http://localhost:8080${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop the server${NC}"

# Start the web UI
python web_ui.py
