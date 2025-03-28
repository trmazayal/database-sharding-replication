#!/bin/bash
set -e

# Configuration
HOST="localhost"
PORT=5432
USER="citus"
DB="citus"
PASSWORD="citus"
PGPASSWORD="$PASSWORD"
export PGPASSWORD

# Docker container for running commands
CONTAINER="citus_loadbalancer"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# CSV output file
RESULTS_DIR="benchmark_results"
HA_CSV="${RESULTS_DIR}/ha_benchmark_results.csv"

# Create results directory
mkdir -p ${RESULTS_DIR}
mkdir -p ${RESULTS_DIR}/graphs

# Initialize CSV with header
echo "scenario,total_queries,error_count,success_rate" > "${HA_CSV}"

echo -e "${GREEN}Starting High Availability Benchmark${NC}"
echo "================================================"

# Function to run psql commands inside Docker container
docker_psql() {
    docker exec -i $CONTAINER psql -h $HOST -p $PORT -U $USER -d $DB "$@"
}

# Function to run continuous queries
run_continuous_queries() {
    local duration=$1
    local end_time=$((SECONDS + duration))
    local query_count=0
    local error_count=0

    echo -e "${YELLOW}Running continuous queries for $duration seconds...${NC}"

    while [ $SECONDS -lt $end_time ]; do
        if docker exec -i $CONTAINER psql -h $HOST -p $PORT -U $USER -d $DB -c "SELECT COUNT(*) FROM benchmark_points LIMIT 1;" &> /dev/null; then
            query_count=$((query_count + 1))
        else
            error_count=$((error_count + 1))
            echo -e "${RED}Query error occurred${NC}"
        fi
        sleep 0.2
    done

    echo -e "${GREEN}Total successful queries: $query_count${NC}"
    echo -e "${RED}Total failed queries: $error_count${NC}"

    local total=$((query_count + error_count))
    local success_rate=0
    if [ $total -gt 0 ]; then
        success_rate=$(echo "scale=2; ($query_count * 100) / $total" | bc)
    fi

    echo "$query_count $error_count $success_rate"
}

# Function to simulate a node failure
simulate_node_failure() {
    local node=$1
    echo -e "\n${YELLOW}Simulating failure on $node...${NC}"
    docker stop $node
    sleep 5
    echo -e "${YELLOW}Node $node stopped${NC}"
}

# Function to restore a node
restore_node() {
    local node=$1
    echo -e "\n${YELLOW}Restoring node $node...${NC}"
    docker start $node
    sleep 10  # Allow time for node to recover
    echo -e "${YELLOW}Node $node restarted${NC}"
}

# Initial test to verify connectivity
echo -e "${YELLOW}Testing initial connectivity...${NC}"
docker_psql -c "SELECT nodename, nodeport FROM pg_dist_node;"

# Run baseline benchmark
echo -e "\n${YELLOW}Running baseline benchmark (30 seconds)...${NC}"
baseline_results=$(run_continuous_queries 30)
read baseline_queries baseline_errors baseline_success <<< "$baseline_results"
echo "Baseline,$(($baseline_queries + $baseline_errors)),$baseline_errors,$baseline_success" >> "${HA_CSV}"

# Testing with worker down from the start
echo -e "\n${RED}TESTING WITH WORKER NODE DOWN${NC}"
simulate_node_failure "citus_worker2"

echo -e "\n${YELLOW}Running queries with worker node down...${NC}"
worker_down_results=$(run_continuous_queries 30)
read worker_down_queries worker_down_errors worker_down_success <<< "$worker_down_results"
echo "Worker Down,$(($worker_down_queries + $worker_down_errors)),$worker_down_errors,$worker_down_success" >> "${HA_CSV}"

# Restore worker node
restore_node "citus_worker2"
echo -e "\n${YELLOW}Waiting for cluster to stabilize...${NC}"
sleep 10

# Simulate coordinator primary failure
echo -e "\n${RED}TESTING PRIMARY COORDINATOR FAILURE${NC}"
echo -e "${YELLOW}Starting continuous queries...${NC}"
coordinator_failure_results=$(run_continuous_queries 5)
read coordinator_failure_queries coordinator_failure_errors coordinator_failure_success <<< "$coordinator_failure_results"
echo "Coordinator Failure Start,$((coordinator_failure_queries + coordinator_failure_errors)),$coordinator_failure_errors,$coordinator_failure_success" >> "${HA_CSV}"

simulate_node_failure "citus_coordinator_primary"

# Verify cluster is still operational
echo -e "\n${YELLOW}Verifying cluster operation after primary coordinator failure...${NC}"
after_primary_results=$(run_continuous_queries 20)
read after_primary_queries after_primary_errors after_primary_success <<< "$after_primary_results"
echo "After Coordinator Failure,$((after_primary_queries + after_primary_errors)),$after_primary_errors,$after_primary_success" >> "${HA_CSV}"

# Restore primary coordinator
restore_node "citus_coordinator_primary"

# Simulate worker node failure
echo -e "\n${RED}TESTING WORKER NODE FAILURE${NC}"
echo -e "${YELLOW}Starting continuous queries...${NC}"
worker_failure_results=$(run_continuous_queries 5)
read worker_failure_queries worker_failure_errors worker_failure_success <<< "$worker_failure_results"
echo "Worker Failure Start,$((worker_failure_queries + worker_failure_errors)),$worker_failure_errors,$worker_failure_success" >> "${HA_CSV}"

simulate_node_failure "citus_worker1"

# Verify cluster is still operational
echo -e "\n${YELLOW}Verifying cluster operation after worker failure...${NC}"
after_worker_results=$(run_continuous_queries 20)
read after_worker_queries after_worker_errors after_worker_success <<< "$after_worker_results"
echo "After Worker Failure,$((after_worker_queries + after_worker_errors)),$after_worker_errors,$after_worker_success" >> "${HA_CSV}"

# Restore worker node
restore_node "citus_worker1"

# Final verification
echo -e "\n${YELLOW}Final verification of cluster...${NC}"
docker_psql -c "SELECT nodename, nodeport, noderole FROM pg_dist_node;"

echo -e "\n${GREEN}High Availability Benchmark Results:${NC}"
echo "================================================"
echo -e "Results saved to $HA_CSV for visualization"
echo "================================================"

# Calculate availability percentage
total_queries=$((baseline_queries + worker_down_queries + coordinator_failure_queries + after_primary_queries + worker_failure_queries + after_worker_queries))
total_errors=$((baseline_errors + worker_down_errors + coordinator_failure_errors + after_primary_errors + worker_failure_errors + after_worker_errors))

if [ $((total_queries + total_errors)) -gt 0 ]; then
    availability=$(echo "scale=4; (1 - ($total_errors / ($total_queries + $total_errors))) * 100" | bc)
    echo -e "${GREEN}Estimated availability: $availability%${NC}"
fi
