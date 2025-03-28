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

    return $error_count
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

# Function to test queries when worker is down
test_worker_down_queries() {
    local worker=$1
    local duration=$2
    local end_time=$((SECONDS + duration))
    local query_count=0
    local error_count=0

    echo -e "${YELLOW}Running queries with worker $worker down for $duration seconds...${NC}"

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

    return $error_count
}

# Initial test to verify connectivity
echo -e "${YELLOW}Testing initial connectivity...${NC}"
docker_psql -c "SELECT nodename, nodeport FROM pg_dist_node;"

# Run baseline benchmark
echo -e "\n${YELLOW}Running baseline benchmark (30 seconds)...${NC}"
run_continuous_queries 30
baseline_errors=$?

# Testing with worker down from the start
echo -e "\n${RED}TESTING WITH WORKER NODE DOWN${NC}"
simulate_node_failure "citus_worker2"

echo -e "\n${YELLOW}Running queries with worker node down...${NC}"
test_worker_down_queries "citus_worker2" 30
worker_down_errors=$?

# Restore worker node
restore_node "citus_worker2"
echo -e "\n${YELLOW}Waiting for cluster to stabilize...${NC}"
sleep 10

# Simulate coordinator primary failure
echo -e "\n${RED}TESTING PRIMARY COORDINATOR FAILURE${NC}"
echo -e "${YELLOW}Starting continuous queries...${NC}"
run_continuous_queries 5 &
BG_PID=$!
sleep 2

simulate_node_failure "citus_coordinator_primary"

# Wait for background process to complete
wait $BG_PID
coordinator_primary_errors=$?

# Verify cluster is still operational
echo -e "\n${YELLOW}Verifying cluster operation after primary coordinator failure...${NC}"
run_continuous_queries 20
after_primary_errors=$?

# Restore primary coordinator
restore_node "citus_coordinator_primary"

# Simulate worker node failure
echo -e "\n${RED}TESTING WORKER NODE FAILURE${NC}"
echo -e "${YELLOW}Starting continuous queries...${NC}"
run_continuous_queries 5 &
BG_PID=$!
sleep 2

simulate_node_failure "citus_worker1"

# Wait for background process to complete
wait $BG_PID
worker_failure_errors=$?

# Verify cluster is still operational
echo -e "\n${YELLOW}Verifying cluster operation after worker failure...${NC}"
run_continuous_queries 20
after_worker_errors=$?

# Restore worker node
restore_node "citus_worker1"

# Final verification
echo -e "\n${YELLOW}Final verification of cluster...${NC}"
docker_psql -c "SELECT nodename, nodeport, noderole FROM pg_dist_node;"

echo -e "\n${GREEN}High Availability Benchmark Results:${NC}"
echo "================================================"
echo -e "Baseline errors: ${RED}$baseline_errors${NC}"
echo -e "Errors with worker node down: ${RED}$worker_down_errors${NC}"
echo -e "Errors during coordinator primary failure: ${RED}$coordinator_primary_errors${NC}"
echo -e "Errors after coordinator primary failure: ${RED}$after_primary_errors${NC}"
echo -e "Errors during worker failure: ${RED}$worker_failure_errors${NC}"
echo -e "Errors after worker failure: ${RED}$after_worker_errors${NC}"
echo "================================================"

# Calculate availability percentage
total_queries=$((baseline_errors + worker_down_errors + coordinator_primary_errors + after_primary_errors + worker_failure_errors + after_worker_errors))
if [ $total_queries -gt 0 ]; then
    availability=$(echo "scale=4; (1 - ($coordinator_primary_errors + $worker_failure_errors + $worker_down_errors) / $total_queries) * 100" | bc)
    echo -e "${GREEN}Estimated availability: $availability%${NC}"
fi
