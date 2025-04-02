#!/bin/bash

set -e  # Exit on error

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration (can be overridden with command line arguments)
HOST="localhost"
PORT=5432
USER="citus"
DB="citus"
PASSWORD="citus"
CONTAINER="citus_loadbalancer"
PATTERN="steady"
DURATION=300  # 5 minutes
INTERVAL=1.0  # 1 second between queries
CREATE_TABLE=false
SIMULATE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --host)
      HOST="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --user)
      USER="$2"
      shift 2
      ;;
    --db)
      DB="$2"
      shift 2
      ;;
    --password)
      PASSWORD="$2"
      shift 2
      ;;
    --container)
      CONTAINER="$2"
      shift 2
      ;;
    --pattern)
      PATTERN="$2"
      shift 2
      ;;
    --duration)
      DURATION="$2"
      shift 2
      ;;
    --interval)
      INTERVAL="$2"
      shift 2
      ;;
    --create-table)
      CREATE_TABLE=true
      shift
      ;;
    --simulate)
      SIMULATE=true
      shift
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  --host HOST          Database host (default: localhost)"
      echo "  --port PORT          Database port (default: 5432)"
      echo "  --user USER          Database user (default: citus)"
      echo "  --db DB              Database name (default: citus)"
      echo "  --password PASS      Database password (default: citus)"
      echo "  --container CONT     Docker container name (default: citus_loadbalancer)"
      echo "  --pattern PATTERN    Load pattern: steady,cyclic,increasing,decreasing,step (default: steady)"
      echo "  --duration SECONDS   Simulation duration in seconds (default: 300)"
      echo "  --interval SECONDS   Interval between queries in seconds (default: 1.0)"
      echo "  --create-table       Create table if it doesn't exist"
      echo "  --simulate           Run in simulation mode without connecting to a database"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

echo -e "${GREEN}=== Starting Database Benchmarking and Simulation ===${NC}"

# Only run pre-simulator if not in simulation mode
if [ "$SIMULATE" = false ]; then
  echo -e "${YELLOW}Running pre-simulation setup...${NC}"

  # Check if pre-simulator.sh exists and is executable
  if [ -f "$(dirname "$0")/pre-simulator.sh" ]; then
    bash "$(dirname "$0")/pre-simulator.sh"
    if [ $? -ne 0 ]; then
      echo -e "${RED}Pre-simulation setup failed!${NC}"
      echo -e "${YELLOW}Continuing in simulation mode...${NC}"
      SIMULATE=true
    else
      echo -e "${GREEN}Pre-simulation setup completed successfully.${NC}"
    fi
  else
    echo -e "${RED}Warning: pre-simulator.sh not found or not executable.${NC}"
    echo -e "${YELLOW}Continuing in simulation mode...${NC}"
    SIMULATE=true
  fi
fi

# Build command line arguments for the Python script
PYTHON_ARGS=()
PYTHON_ARGS+=(--host "$HOST")
PYTHON_ARGS+=(--port "$PORT")
PYTHON_ARGS+=(--user "$USER")
PYTHON_ARGS+=(--db "$DB")
PYTHON_ARGS+=(--password "$PASSWORD")
PYTHON_ARGS+=(--container "$CONTAINER")
PYTHON_ARGS+=(--pattern "$PATTERN")
PYTHON_ARGS+=(--duration "$DURATION")
PYTHON_ARGS+=(--interval "$INTERVAL")

if [ "$CREATE_TABLE" = true ]; then
  PYTHON_ARGS+=(--create-table)
fi

if [ "$SIMULATE" = true ]; then
  PYTHON_ARGS+=(--simulate)
fi

# Run the Python simulation script
echo -e "${GREEN}Starting Python simulation with pattern: $PATTERN${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop or wait $DURATION seconds for automatic termination${NC}"

python3 "$(dirname "$0")/read_trend_simulator.py" "${PYTHON_ARGS[@]}"

# Check if Python script succeeded
if [ $? -ne 0 ]; then
  echo -e "${RED}Simulation failed!${NC}"
  exit 1
else
  echo -e "${GREEN}Simulation completed.${NC}"
fi

echo -e "${GREEN}=== Benchmarking and Simulation Completed ===${NC}"
exit 0
