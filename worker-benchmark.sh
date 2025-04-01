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
    local table_check=$(docker exec -i $CONTAINER psql -h $COORDINATOR_HOST -p $PORT -U $USER -d $DB -t -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'vehicle_locations');" 2>/dev/null | tr -d ' ')

    if [ "$table_check" != "t" ]; then
        echo -e "${RED}Table vehicle_locations does not exist. Please run the main benchmark script first.${NC}"
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

# Check if vehicle_locations table exists before running queries
table_exists=$(docker exec -i $CONTAINER psql -h $COORDINATOR_HOST -p $PORT -U $USER -d $DB -t -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'vehicle_locations');" 2>/dev/null | tr -d ' ')

if [ "$table_exists" != "t" ]; then
    echo -e "${RED}Table vehicle_locations does not exist. Please run the main benchmark script first.${NC}"
    exit 1
fi

# Compare query execution across nodes
compare_hosts "SELECT COUNT(*) FROM vehicle_locations WHERE region_code = 'region_north';" "Simple count query for single region" || true

compare_hosts "EXPLAIN ANALYZE SELECT COUNT(*) FROM vehicle_locations WHERE region_code = 'region_north';" "Explain analyze for single region" || true

# Add spatial queries
compare_hosts "SELECT COUNT(*) FROM vehicle_locations
WHERE ST_DWithin(
        location::geography,
        ST_SetSRID(ST_MakePoint(-73.9857, 40.7484), 4326)::geography,
        5000
    );" "Spatial query - vehicles within 5km" || true

compare_hosts "SELECT COUNT(*) FROM vehicle_locations
WHERE ST_Within(
    location,
    ST_MakeEnvelope(-74.0, 40.7, -73.9, 40.8, 4326)
);" "Bounding box query" || true

# Additional benchmark queries for comprehensive testing
# Complex aggregation query
compare_hosts "SELECT region_code, vehicle_type, COUNT(*), AVG(ST_X(location)), AVG(ST_Y(location))
FROM vehicle_locations
GROUP BY region_code, vehicle_type
ORDER BY region_code, vehicle_type;" "Complex aggregation by region and vehicle type" || true

# Window function query
compare_hosts "SELECT id, region_code, vehicle_type,
       ROW_NUMBER() OVER (PARTITION BY region_code ORDER BY updated_at DESC) as recency_rank
FROM vehicle_locations
WHERE updated_at > NOW() - INTERVAL '1 hour'
LIMIT 1000;" "Window function for recency ranking" || true

# Join query (assuming we have a vehicle_types table; if not, this will fail gracefully)
compare_hosts "SELECT vl.region_code, COUNT(*)
FROM vehicle_locations vl
JOIN pg_catalog.pg_tables t ON TRUE
GROUP BY vl.region_code
ORDER BY COUNT(*) DESC
LIMIT 10;" "Join query with aggregation" || true

# More complex spatial query
compare_hosts "SELECT region_code,
       COUNT(*),
       ST_Extent(location) as bounding_box
FROM vehicle_locations
GROUP BY region_code;" "Spatial aggregation with bounding box" || true

# Query with subquery
compare_hosts "SELECT COUNT(*) FROM vehicle_locations
WHERE region_code IN (
    SELECT region_code
    FROM vehicle_locations
    GROUP BY region_code
    HAVING COUNT(*) > 1000
);" "Query with subquery" || true

# Compute-intensive spatial query
compare_hosts "SELECT COUNT(*)
FROM vehicle_locations v1
WHERE EXISTS (
    SELECT 1
    FROM vehicle_locations v2
    WHERE v1.id <> v2.id
    AND ST_DWithin(v1.location::geography, v2.location::geography, 100)
    LIMIT 1
)
LIMIT 5000;" "Proximity detection query (limited)" || true

echo -e "\n${GREEN}Worker benchmark complete!${NC}"
echo "Results saved to ${WORKER_CSV} for visualization"
echo "================================================"
