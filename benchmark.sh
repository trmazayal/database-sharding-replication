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

# CSV output files
RESULTS_DIR="benchmark_results"
SINGLE_QUERY_CSV="${RESULTS_DIR}/single_query_results.csv"
CONCURRENT_CSV="${RESULTS_DIR}/concurrent_results.csv"

# Create results directory and subdirectories
mkdir -p ${RESULTS_DIR}
mkdir -p ${RESULTS_DIR}/graphs

# Initialize CSV files with headers
echo "query_name,iteration,execution_time" > "${SINGLE_QUERY_CSV}"
echo "test_name,clients,threads,tps,latency_ms" > "${CONCURRENT_CSV}"

echo -e "${GREEN}Starting Citus Cluster Benchmark${NC}"
echo "================================================"

# Function to run psql commands inside Docker container
docker_psql() {
    # Fix: Ensure SQL commands are properly quoted when passed to bash
    docker exec -i -e PGPASSWORD="$PGPASSWORD" $CONTAINER psql -h localhost -p $PORT -U $USER -d $DB "$@"
}

# Install PostgreSQL client and pgbench in the container
echo -e "${YELLOW}Checking for PostgreSQL client in container...${NC}"
if ! docker exec $CONTAINER which psql &>/dev/null; then
    echo -e "${YELLOW}Installing PostgreSQL client...${NC}"
    docker exec $CONTAINER bash -c "apt-get update && apt-get install -y gnupg2 curl lsb-release"
    docker exec $CONTAINER bash -c "echo 'deb http://apt.postgresql.org/pub/repos/apt/ \$(lsb_release -cs)-pgdg main' > /etc/apt/sources.list.d/pgdg.list && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -"
    docker exec $CONTAINER bash -c "apt-get update && apt-get install -y postgresql-client-15 postgresql-client-14 postgresql-client-13 || apt-get install -y postgresql-client"

    # Verify installation
    if ! docker exec $CONTAINER which psql &>/dev/null; then
        echo -e "${RED}Failed to install PostgreSQL client. Benchmarks may not work correctly.${NC}"
    else
        echo -e "${GREEN}Successfully installed PostgreSQL client.${NC}"
    fi
fi

# Check for pgbench
echo -e "${YELLOW}Checking for pgbench in container...${NC}"
if ! docker exec $CONTAINER which pgbench &>/dev/null; then
    echo -e "${YELLOW}Installing pgbench...${NC}"

    # Try to install pgbench from postgresql-contrib
    docker exec $CONTAINER bash -c "apt-get update && apt-get install -y postgresql-contrib || apt-get install -y postgresql-15-contrib || apt-get install -y postgresql-14-contrib"

    # Look for pgbench binary
    PGBENCH_PATH=$(docker exec $CONTAINER find /usr/lib/postgresql -name pgbench -type f 2>/dev/null | head -n 1)

    if [ -n "$PGBENCH_PATH" ]; then
        # Create a symlink
        docker exec $CONTAINER ln -sf "$PGBENCH_PATH" /usr/bin/pgbench
        echo -e "${GREEN}Created symlink to pgbench at $PGBENCH_PATH${NC}"
    else
        echo -e "${RED}Could not find pgbench. Concurrent benchmarks will be skipped.${NC}"
    fi
else
    echo -e "${GREEN}pgbench is already installed.${NC}"
fi

# Test connection and cluster status
echo -e "${YELLOW}Testing cluster connectivity...${NC}"
docker_psql -c "SELECT version();"
echo "Cluster nodes:"
docker_psql -c "SELECT * FROM pg_dist_node;"

docker_psql -c "\dt"


# Run analytical queries with timing
run_query() {
    local query_name="$1"
    local query="$2"
    local repetitions="$3"

    echo -e "\n${YELLOW}Running $query_name ($repetitions iterations)...${NC}"

    # Run once to warm up cache
    docker_psql -c "EXPLAIN ANALYZE $query" > /dev/null 2>&1 || {
        echo -e "${RED}Error executing query. Skipping benchmark.${NC}"
        return 1
    }

    # Run benchmark iterations
    local total_time=0
    for i in $(seq 1 $repetitions); do
        local start_time=$(date +%s.%N)
        docker_psql -c "$query" > /dev/null
        local end_time=$(date +%s.%N)
        local query_time=$(echo "$end_time - $start_time" | bc)
        total_time=$(echo "$total_time + $query_time" | bc)
        echo "Iteration $i: $query_time seconds"

        # Write to CSV file
        echo "$query_name,$i,$query_time" >> "${SINGLE_QUERY_CSV}"
    done

    local avg_time=$(echo "scale=3; $total_time / $repetitions" | bc)
    echo -e "${GREEN}Average execution time: $avg_time seconds${NC}"
}

# Run concurrent queries using pgbench
run_concurrent_test() {
    local test_name="$1"
    local clients="$2"
    local threads="$3"
    local time="$4"
    local script="$5"

    echo -e "\n${YELLOW}Running $test_name benchmark...${NC}"
    echo "Clients: $clients, Threads: $threads, Duration: $time seconds"

    # Copy the script to the container
    docker cp "$script" $CONTAINER:/tmp/$(basename "$script")

    # Run pgbench inside the container and capture output
    local pgbench_output=$(docker exec -i $CONTAINER pgbench -h localhost -p $PORT -U $USER -d $DB \
            -c $clients -j $threads -T $time \
            -f "/tmp/$(basename "$script")" \
            -P 5 2>&1) || {
        echo -e "${RED}Error running concurrent benchmark.${NC}"
        return 1
    }

    echo "$pgbench_output"

    # Extract TPS and latency from the output
    local tps=$(echo "$pgbench_output" | grep "tps =" | tail -n 1 | awk '{print $3}')
    local latency=$(echo "$pgbench_output" | grep "latency average" | tail -n 1 | awk '{print $4}')

    # Write to CSV file
    if [[ ! -z "$tps" && ! -z "$latency" ]]; then
        echo "$test_name,$clients,$threads,$tps,$latency" >> "${CONCURRENT_CSV}"
    fi
}

# Create vehicle_locations table if it doesn't exist
echo -e "\n${YELLOW}Setting up vehicle_locations table...${NC}"

# Check if vehicle_locations table exists and has data
table_exists=false
row_count=0

# Try to get the count - if it fails, the table doesn't exist or is inaccessible
if count_result=$(docker_psql -t -c "SELECT COUNT(*) FROM vehicle_locations" 2>/dev/null); then
    row_count=$(echo "$count_result" | tr -d ' ')
    if [ "$row_count" -gt 0 ]; then
        table_exists=true
        echo "vehicle_locations table exists with $row_count rows."
    else
        echo "vehicle_locations table exists but has no data. Will recreate it."
    fi
else
    echo "vehicle_locations table does not exist. Will create it."
fi

if [ "$table_exists" = false ]; then
    echo "Creating vehicle_locations table..."

    # Step 1: More aggressive cleanup of existing objects
    echo "Dropping any existing objects..."
    docker_psql -c "DROP TABLE IF EXISTS vehicle_locations CASCADE;" || true

    # Check if PostGIS extension is available and create it if needed
    echo "Checking for PostGIS extension..."
    if ! docker_psql -t -c "SELECT 1 FROM pg_extension WHERE extname = 'postgis';" | grep -q "1"; then
        echo "Creating PostGIS extension..."
        docker_psql -c "CREATE EXTENSION IF NOT EXISTS postgis CASCADE;"
    else
        echo "PostGIS extension is already available."
    fi

    # Create the vehicle_locations table as specified
    echo "Creating vehicle_locations table..."
    if ! docker_psql -c "
    CREATE TABLE vehicle_locations (
      id bigserial,
      vehicle_id int NOT NULL,
      location geometry(Point, 4326) NOT NULL,
      recorded_at timestamptz NOT NULL,
      region_code text NOT NULL
    );" ; then
        echo -e "${RED}Failed to create table${NC}"
        exit 1
    else
        echo -e "${GREEN}Table created successfully${NC}"
    fi

    # Distribute the table by region_code BEFORE creating indexes
    echo "Distributing table by region_code..."
    if docker_psql -c "SELECT create_distributed_table('vehicle_locations', 'region_code');" 2>/dev/null; then
        echo -e "${GREEN}Table distributed successfully${NC}"
    else
        echo -e "${RED}Failed to distribute table${NC}"
        exit 1
    fi

    # Create indexes AFTER distributing the table
    echo "Creating indexes..."
    docker_psql -c "CREATE INDEX idx_vehicle_locations_location ON vehicle_locations USING GIST (location);" && \
    echo "Created spatial index" || echo -e "${RED}Warning: Failed to create spatial index${NC}"

    docker_psql -c "CREATE INDEX idx_vehicle_locations_region_code ON vehicle_locations (region_code);" && \
    echo "Created region_code index" || echo -e "${RED}Warning: Failed to create region_code index${NC}"

    # Insert data in one batch as specified
    echo "Inserting 1,000,000 rows of benchmark data (this may take a few minutes)..."
    if ! docker_psql -c "
    INSERT INTO vehicle_locations (vehicle_id, location, recorded_at, region_code)
    SELECT
        -- Generate a random vehicle_id between 1 and 10,000
        (floor(random() * 10000) + 1)::int AS vehicle_id,

        -- Generate a random point near New York City
        ST_SetSRID(
            ST_MakePoint(
            -74.0 + random() * 0.5,  -- longitude between -74.0 and -73.5
            40.7 + random() * 0.5    -- latitude between 40.7 and 41.2
            ),
            4326
        ) AS location,

        -- Generate a random timestamp within the last 30 days
        NOW() - (random() * interval '30 days') AS recorded_at,

        -- Randomly assign one of three region codes
        CASE
            WHEN random() < 0.33 THEN 'region_north'
            WHEN random() < 0.66 THEN 'region_south'
            ELSE 'region_central'
        END AS region_code
    FROM generate_series(1, 1000000) s(i);" ; then
        echo -e "${RED}Warning: Error inserting data${NC}"
    fi

    # Verify data insertion
    echo "Verifying data insertion..."
    max_attempts=5
    attempt=1
    while [ $attempt -le $max_attempts ]; do
        if count_result=$(docker_psql -t -c "SELECT COUNT(*) FROM vehicle_locations;" 2>/dev/null); then
            row_count=$(echo "$count_result" | tr -d ' ')
            if [ "$row_count" -gt 0 ]; then
                echo -e "${GREEN}Successfully created vehicle_locations table with $row_count rows.${NC}"
                break
            fi
        fi
        echo "Waiting for data to be fully inserted (attempt $attempt/$max_attempts)..."
        sleep 5
        attempt=$((attempt + 1))
    done

    if [ $attempt -gt $max_attempts ]; then
        echo -e "${RED}Failed to verify data insertion after $max_attempts attempts.${NC}"
        row_count=0
    fi
else
    echo "Using existing vehicle_locations table with $row_count rows."
fi

# Create pgbench scripts for concurrent tests
TMP_DIR=$(mktemp -d)
cat > $TMP_DIR/spatial_query.sql << EOF
-- Query all vehicles within 5km of a specific point
SELECT id, vehicle_id, recorded_at, region_code
FROM vehicle_locations
WHERE ST_DWithin(
        location::geography,
        ST_SetSRID(ST_MakePoint(-73.9857, 40.7484), 4326)::geography,
        5000
    );
EOF

cat > $TMP_DIR/bounding_box_query.sql << EOF
-- Query all vehicles within a bounding box
SELECT *
FROM vehicle_locations
WHERE ST_Within(
    location,
    ST_MakeEnvelope(-74.0, 40.7, -73.9, 40.8, 4326)
);
EOF

cat > $TMP_DIR/mixed_workload.sql << EOF
\\set rand_lon (-74.0 + random() * 0.5)
\\set rand_lat (40.7 + random() * 0.5)
SELECT COUNT(*)
FROM vehicle_locations
WHERE ST_DWithin(
    location::geography,
    ST_SetSRID(ST_MakePoint(:rand_lon, :rand_lat), 4326)::geography,
    5000
);
EOF

echo -e "\n${YELLOW}Running single query benchmarks...${NC}"

docker_psql -c "\dt"

# Verify table has data before running benchmarks
echo "Verifying table has data before running benchmarks..."
count_result=$(docker_psql -t -c "SELECT COUNT(*) FROM vehicle_locations;" 2>/dev/null) || {
    echo -e "${RED}Error: Table does not exist or is not accessible${NC}";
    exit 1;
}
row_count=$(echo "$count_result" | tr -d ' ')

if [ "$row_count" -eq "0" ]; then
    echo -e "${RED}No data found in vehicle_locations table. Skipping benchmarks.${NC}"
    exit 1
fi

echo "Table has $row_count rows. Running benchmarks..."

# Run single query benchmarks with the specified queries
run_query "Spatial Query - 5km Radius" "
SELECT id, vehicle_id, recorded_at, region_code
FROM vehicle_locations
WHERE ST_DWithin(
        location::geography,
        ST_SetSRID(ST_MakePoint(-73.9857, 40.7484), 4326)::geography,
        5000
    );" 5 || true

run_query "Bounding Box Query" "
SELECT *
FROM vehicle_locations
WHERE ST_Within(
    location,
    ST_MakeEnvelope(-74.0, 40.7, -73.9, 40.8, 4326)
);" 5 || true

run_query "Region Count Query" "
SELECT region_code, COUNT(*)
FROM vehicle_locations
GROUP BY region_code
ORDER BY COUNT(*) DESC;" 5 || true

run_query "Recent Vehicles Query" "
SELECT vehicle_id, location, recorded_at, region_code
FROM vehicle_locations
WHERE recorded_at > NOW() - interval '7 days'
ORDER BY recorded_at DESC
LIMIT 100;" 5 || true

echo -e "\n${YELLOW}Running concurrent query benchmarks...${NC}"

# Run concurrent benchmarks with increasing concurrency
run_concurrent_test "Spatial Queries - Low Concurrency" 5 2 10 "$TMP_DIR/spatial_query.sql" || true
run_concurrent_test "Spatial Queries - Medium Concurrency" 10 4 10 "$TMP_DIR/spatial_query.sql" || true
run_concurrent_test "Spatial Queries - High Concurrency" 20 8 10 "$TMP_DIR/spatial_query.sql" || true

run_concurrent_test "Bounding Box Queries - Medium Concurrency" 10 4 10 "$TMP_DIR/bounding_box_query.sql" || true

# Check distribution of data
echo -e "\n${YELLOW}Checking data distribution across regions...${NC}"
docker_psql -c "SELECT region_code, COUNT(*) FROM vehicle_locations GROUP BY region_code ORDER BY COUNT(*) DESC;" || echo -e "${RED}Could not check region distribution${NC}"

# Check distribution of data across shards
echo -e "\n${YELLOW}Checking data distribution across shards...${NC}"
docker_psql -c "
SELECT
    n.nodename,
    n.nodeport,
    COUNT(DISTINCT s.shardid) AS num_shards
FROM pg_dist_shard s
JOIN pg_dist_placement p ON s.shardid = p.shardid
JOIN pg_dist_node n ON p.groupid = n.groupid
WHERE s.logicalrelid::text LIKE 'vehicle_locations%'
GROUP BY n.nodename, n.nodeport
ORDER BY n.nodename;
" || echo -e "${RED}Could not check shard distribution${NC}"

# Clean up temporary files
rm -rf $TMP_DIR

echo -e "\n${GREEN}Benchmark complete!${NC}"
echo "Results saved to $RESULTS_DIR directory for visualization"
echo "================================================"
