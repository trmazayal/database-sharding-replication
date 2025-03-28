#!/bin/bash
set -e

# Configuration
COORDINATOR_HOST="coordinator_primary"
WORKER1_HOST="worker1"
WORKER2_HOST="worker2"
WORKER3_HOST="worker3"
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
WORKER_CSV="${RESULTS_DIR}/worker_benchmark_results.csv"

# Create results directory
mkdir -p ${RESULTS_DIR}
mkdir -p ${RESULTS_DIR}/graphs

# Initialize CSV with header
echo "query,node,real_time,user_time,sys_time" > "${WORKER_CSV}"

echo -e "${GREEN}Starting Worker Node Benchmark${NC}"
echo "================================================"

# Function to run psql commands inside Docker container
docker_psql() {
    local host="$1"
    shift
    docker exec -i $CONTAINER psql -h $host -p $PORT -U $USER -d $DB "$@" 2>&1 || {
        echo -e "${RED}Error executing query on $host${NC}"
        return 1
    }
}

# Function to run the same query on multiple hosts and compare
compare_hosts() {
    local query="$1"
    local description="$2"

    echo -e "\n${YELLOW}$description${NC}"
    echo "Query: $query"

    # First check if the benchmark table exists
    local table_check=$(docker exec -i $CONTAINER psql -h $COORDINATOR_HOST -p $PORT -U $USER -d $DB -t -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'benchmark_points');" 2>/dev/null | tr -d ' ')

    if [ "$table_check" != "t" ]; then
        echo -e "${RED}Table benchmark_points does not exist. Please run the main benchmark script first.${NC}"
        return 1
    fi

    # Run on coordinator
    echo -e "\n${YELLOW}Running on coordinator...${NC}"
    local cmd_output=$( { time docker_psql $COORDINATOR_HOST -c "$query" > /dev/null; } 2>&1 )
    local real_time=$(echo "$cmd_output" | grep "real" | awk '{print $2}')
    local user_time=$(echo "$cmd_output" | grep "user" | awk '{print $2}')
    local sys_time=$(echo "$cmd_output" | grep "sys" | awk '{print $2}')
    echo "$description,coordinator,$real_time,$user_time,$sys_time" >> "${WORKER_CSV}"

    # Run on each worker
    echo -e "\n${YELLOW}Running on worker1...${NC}"
    cmd_output=$( { time docker_psql $WORKER1_HOST -c "$query" > /dev/null; } 2>&1 )
    real_time=$(echo "$cmd_output" | grep "real" | awk '{print $2}')
    user_time=$(echo "$cmd_output" | grep "user" | awk '{print $2}')
    sys_time=$(echo "$cmd_output" | grep "sys" | awk '{print $2}')
    echo "$description,worker1,$real_time,$user_time,$sys_time" >> "${WORKER_CSV}"

    echo -e "\n${YELLOW}Running on worker2...${NC}"
    cmd_output=$( { time docker_psql $WORKER2_HOST -c "$query" > /dev/null; } 2>&1 )
    real_time=$(echo "$cmd_output" | grep "real" | awk '{print $2}')
    user_time=$(echo "$cmd_output" | grep "user" | awk '{print $2}')
    sys_time=$(echo "$cmd_output" | grep "sys" | awk '{print $2}')
    echo "$description,worker2,$real_time,$user_time,$sys_time" >> "${WORKER_CSV}"

    echo -e "\n${YELLOW}Running on worker3...${NC}"
    cmd_output=$( { time docker_psql $WORKER3_HOST -c "$query" > /dev/null; } 2>&1 )
    real_time=$(echo "$cmd_output" | grep "real" | awk '{print $2}')
    user_time=$(echo "$cmd_output" | grep "user" | awk '{print $2}')
    sys_time=$(echo "$cmd_output" | grep "sys" | awk '{print $2}')
    echo "$description,worker3,$real_time,$user_time,$sys_time" >> "${WORKER_CSV}"
}

# Get info about the cluster
echo -e "${YELLOW}Cluster information:${NC}"
docker_psql $COORDINATOR_HOST -c "SELECT * FROM pg_dist_node;"
docker_psql $COORDINATOR_HOST -c "SELECT count(*) FROM pg_dist_shard;"

# Check if benchmark table exists before running queries
table_exists=$(docker exec -i $CONTAINER psql -h $COORDINATOR_HOST -p $PORT -U $USER -d $DB -t -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'benchmark_points');" 2>/dev/null | tr -d ' ')

if [ "$table_exists" != "t" ]; then
    echo -e "${RED}Table benchmark_points does not exist. Please run the main benchmark script first.${NC}"
    exit 1
fi

# Compare query execution across nodes
compare_hosts "SELECT COUNT(*) FROM benchmark_points WHERE region_id = 1;" "Simple count query for single region" || true

compare_hosts "EXPLAIN ANALYZE SELECT COUNT(*) FROM benchmark_points WHERE region_id = 1;" "Explain analyze for single region" || true

echo -e "\n${GREEN}Worker benchmark complete!${NC}"
echo "Results saved to ${WORKER_CSV} for visualization"
echo "================================================"
