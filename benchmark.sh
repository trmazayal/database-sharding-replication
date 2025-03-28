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
    docker exec -i $CONTAINER psql -h $HOST -p $PORT -U $USER -d $DB "$@"
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
    local pgbench_output=$(docker exec -i $CONTAINER pgbench -h $HOST -p $PORT -U $USER -d $DB \
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

# Create benchmark tables and data if they don't exist
echo -e "\n${YELLOW}Setting up benchmark tables...${NC}"

# Check if benchmark table exists and has data
table_exists=false
row_count=0

# Try to get the count - if it fails, the table doesn't exist or is inaccessible
if count_result=$(docker_psql -t -c "SELECT COUNT(*) FROM benchmark_points" 2>/dev/null); then
    row_count=$(echo "$count_result" | tr -d ' ')
    if [ "$row_count" -gt 0 ]; then
        table_exists=true
        echo "Benchmark table exists with $row_count rows."
    else
        echo "Benchmark table exists but has no data. Will recreate it."
    fi
else
    echo "Benchmark table does not exist or is not accessible."
fi

if [ "$table_exists" = false ]; then
    echo "Creating benchmark tables..."

    # Step 1: More aggressive cleanup of existing objects
    echo "Dropping any existing objects..."
    docker_psql -c "DROP TABLE IF EXISTS public.benchmark_points CASCADE;" || true
    docker_psql -c "DROP TABLE IF EXISTS citus.benchmark_points CASCADE;" || true
    docker_psql -c "DROP SEQUENCE IF EXISTS public.benchmark_points_id_seq CASCADE;" || true
    docker_psql -c "DROP SEQUENCE IF EXISTS citus.benchmark_points_id_seq CASCADE;" || true

    # Check if PostGIS extension is available and create it if needed
    echo "Checking for PostGIS extension..."
    if ! docker_psql -t -c "SELECT 1 FROM pg_extension WHERE extname = 'postgis';" | grep -q "1"; then
        echo "Creating PostGIS extension..."
        docker_psql -c "CREATE EXTENSION IF NOT EXISTS postgis CASCADE;"
    else
        echo "PostGIS extension is already available."
    fi

    # Show user information and schema information
    echo "Current database user and search path:"
    docker_psql -c "SELECT current_user, current_database();"
    docker_psql -c "SHOW search_path;"

    # List all schemas for debugging
    echo "Available schemas:"
    docker_psql -c "SELECT nspname FROM pg_namespace ORDER BY nspname;"

    # Step 2: Get the current schema and create table in that exact schema
    echo "Determining the default schema..."
    current_schema=$(docker_psql -t -c "SELECT current_schema();" | tr -d ' ')
    echo "Current schema is: $current_schema"

    # Create the table with compound primary key in a single operation
    echo "Creating benchmark_points table in $current_schema schema with compound primary key..."
    if ! docker_psql -c "
    CREATE TABLE ${current_schema}.benchmark_points (
        id SERIAL,
        region_id INT NOT NULL,
        value FLOAT NOT NULL,
        created_at TIMESTAMP NOT NULL DEFAULT NOW(),
        location GEOMETRY(POINT, 4326) NULL,
        PRIMARY KEY (region_id, id)
    );" ; then
        echo -e "${RED}Failed to create table${NC}"
        exit 1
    else
        echo -e "${GREEN}Table created successfully with compound primary key${NC}"
    fi

    # Use the determined schema for the full table name
    full_table_name="${current_schema}.benchmark_points"
    echo "Using full table name: $full_table_name"

    # View table definition to verify primary key
    echo "Verifying table structure:"
    docker_psql -c "\d ${full_table_name}"

    # Step 3: Verify table creation and schema
    echo "Verifying table access:"
    if ! docker_psql -c "SELECT * FROM $full_table_name LIMIT 0;" &>/dev/null; then
        echo -e "${RED}Failed to verify table access${NC}"
        exit 1
    else
        echo -e "${GREEN}Table verification successful${NC}"
    fi

    # Step 4: Add constraints
    echo "Setting up table constraints..."
    docker_psql -c "ALTER TABLE $full_table_name ADD CONSTRAINT region_check CHECK (region_id > 0 AND region_id <= 100);" || true

    # Step 5: Distribute the table
    echo "Distributing table by region_id..."

    # First, check existing colocation groups to avoid conflicts
    echo "Checking existing colocation groups:"
    docker_psql -c "SELECT colocationid, shardcount FROM pg_dist_colocation ORDER BY colocationid;"

    # Try a distribution approach that avoids colocation issues
    distribution_success=false

    # Attempt 1: Try with default colocation
    echo "Attempt 1: Default distribution..."
    if docker_psql -c "SELECT create_distributed_table('$full_table_name', 'region_id');" 2>/dev/null; then
        echo -e "${GREEN}Table distributed successfully${NC}"
        distribution_success=true
    else
        echo "Default distribution failed. Trying alternative approach..."

        # Attempt 2: Try with specific colocation settings
        echo "Attempt 2: Distribution with explicit shard count..."
        if docker_psql -c "SELECT create_distributed_table('$full_table_name', 'region_id', colocate_with => 'none', shard_count => 32);" 2>/dev/null; then
            echo -e "${GREEN}Table distributed successfully with explicit shard count${NC}"
            distribution_success=true
        else
            # Attempt 3: Try with no colocation
            echo "Attempt 3: Distribution without colocation..."
            if docker_psql -c "SELECT create_distributed_table('$full_table_name', 'region_id', colocate_with => 'none');" 2>/dev/null; then
                echo -e "${GREEN}Table distributed successfully without colocation${NC}"
                distribution_success=true
            else
                echo -e "${RED}Failed to distribute table after multiple attempts${NC}"
                # Show more diagnostic info
                echo "Checking all Citus functions:"
                docker_psql -c "SELECT proname FROM pg_proc WHERE proname LIKE '%distributed%' LIMIT 5;"
                echo "Checking if the table exists and is accessible:"
                docker_psql -c "\d+ $full_table_name"
                exit 1
            fi
        fi
    fi

    # Step 6: Wait for distribution to complete
    if [ "$distribution_success" = true ]; then
        echo "Waiting for distribution to complete..."
        sleep 10  # Increase wait time to ensure shards are created

        # Step 7: Verify distribution with multiple approaches
        echo "Verifying table distribution..."

        # First check: Look directly in pg_dist_table
        dist_result=$(docker_psql -t -c "SELECT logicalrelid FROM pg_dist_table WHERE logicalrelid='$full_table_name'::regclass;" | tr -d ' ')
        if [ -z "$dist_result" ]; then
            echo -e "${YELLOW}Table not found in pg_dist_table. Checking alternate views...${NC}"
        else
            echo -e "${GREEN}Table found in pg_dist_table${NC}"
        fi

        # Second check: Check shard count
        shard_count=$(docker_psql -t -c "SELECT count(*) FROM pg_dist_shard WHERE logicalrelid='$full_table_name'::regclass;" | tr -d ' ')

        # Third check: Check if Citus considers this distributed
        citus_table_check=$(docker_psql -t -c "SELECT citus_is_distributed_table('$full_table_name');" | tr -d ' ')
        echo "Citus distributed table check: $citus_table_check"

        # If all checks fail, try another approach
        if [ -z "$shard_count" ] || [ "$shard_count" -eq "0" ]; then
            echo -e "${YELLOW}No shards found in pg_dist_shard. Checking another approach...${NC}"

            # Check nodes - if we have nodes but no shards, distribution might be in progress
            node_count=$(docker_psql -t -c "SELECT count(*) FROM pg_dist_node;" | tr -d ' ')
            echo "Cluster has $node_count nodes"

            # Try to force distribution if needed
            echo "Attempting to ensure distribution is complete..."
            docker_psql -c "SELECT master_get_active_worker_nodes();"

            # Wait longer and check again
            echo "Waiting longer for distribution to complete..."
            sleep 10

            shard_count=$(docker_psql -t -c "SELECT count(*) FROM pg_dist_shard WHERE logicalrelid='$full_table_name'::regclass;" | tr -d ' ')
            if [ -z "$shard_count" ] || [ "$shard_count" -eq "0" ]; then
                echo -e "${RED}Still no shards found. Continuing with data insertion anyway...${NC}"
                # Continue despite the issue - maybe data insertion will trigger shard creation
            else
                echo -e "${GREEN}Table distributed with $shard_count shards after retry${NC}"
            fi
        else
            echo -e "${GREEN}Table distributed with $shard_count shards${NC}"
        fi
    else
        echo -e "${RED}Cannot continue without table distribution${NC}"
        exit 1
    fi

    # Step 8: Insert data in smaller batches to avoid timeout
    echo "Inserting benchmark data in batches (this may take a few minutes)..."
    for batch in {1..5}; do
        echo "Inserting batch $batch of 5..."
        if ! docker_psql -c "
        INSERT INTO $full_table_name (region_id, location, value, created_at)
        SELECT
            (random() * 99 + 1)::int AS region_id,
            ST_SetSRID(ST_MakePoint(-180 + random() * 360, -90 + random() * 180), 4326) AS location,
            random() * 100 AS value,
            NOW() - (random() * interval '90 days') AS created_at
        FROM generate_series(1, 20000) s(i);"; then
            echo -e "${RED}Warning: Error inserting batch $batch${NC}"
        fi
        # Give the system time to distribute data
        sleep 2
    done

    # Step 9: Create indexes after successful data insertion
    echo "Creating indexes..."
    docker_psql -c "CREATE INDEX idx_benchmark_points_id ON $full_table_name (id);" && \
    echo "Created ID index" || echo -e "${RED}Warning: Failed to create ID index${NC}"

    sleep 2

    docker_psql -c "CREATE INDEX idx_benchmark_points_region ON $full_table_name (region_id);" && \
    echo "Created region index" || echo -e "${RED}Warning: Failed to create region index${NC}"

    sleep 2

    docker_psql -c "CREATE INDEX idx_benchmark_points_location ON $full_table_name USING GIST (location);" && \
    echo "Created spatial index" || echo -e "${RED}Warning: Failed to create spatial index${NC}"

    # Step 10: Verify data insertion
    echo "Verifying data insertion..."
    max_attempts=5
    attempt=1
    while [ $attempt -le $max_attempts ]; do
        if count_result=$(docker_psql -t -c "SELECT COUNT(*) FROM $full_table_name;" 2>/dev/null); then
            row_count=$(echo "$count_result" | tr -d ' ')
            if [ "$row_count" -gt 0 ]; then
                echo -e "${GREEN}Successfully created benchmark table with $row_count rows.${NC}"
                break
            fi
        fi
        echo "Waiting for data to be fully inserted (attempt $attempt/$max_attempts)..."
        sleep 5
        attempt=$((attempt + 1))
    done

    if [ $attempt -gt $max_attempts ]; then
        echo -e "${RED}Failed to verify data insertion after $max_attempts attempts.${NC}"
        # Continue anyway - we'll report what happened
        row_count=0
    fi

    # Step 11: Detailed diagnostics if we're still failing
    if [ "$row_count" -eq "0" ]; then
        echo "Running diagnostics..."
        docker_psql -c "SELECT version();"
        docker_psql -c "SELECT * FROM pg_dist_node;"
        docker_psql -c "SELECT count(*) FROM pg_dist_shard WHERE logicalrelid='$full_table_name'::regclass;"
        docker_psql -c "SELECT count(*) FROM pg_dist_placement p JOIN pg_dist_shard s ON p.shardid = s.shardid WHERE s.logicalrelid='$full_table_name'::regclass;"
    fi
else
    echo "Using existing benchmark table with $row_count rows."
fi

# Create pgbench scripts for concurrent tests
TMP_DIR=$(mktemp -d)
cat > $TMP_DIR/spatial_query.sql << EOF
SELECT COUNT(*)
FROM $full_table_name
WHERE ST_DWithin(location::geography,
                ST_SetSRID(ST_MakePoint(-73.9 + random(), 40.7 + random()), 4326)::geography,
                10000);
EOF

cat > $TMP_DIR/region_query.sql << EOF
SELECT region_id, COUNT(*), AVG(value)
FROM $full_table_name
WHERE region_id = (random() * 99 + 1)::int
GROUP BY region_id;
EOF

cat > $TMP_DIR/mixed_workload.sql << EOF
\\set region_id random(1, 100)
SELECT COUNT(*) FROM $full_table_name WHERE region_id = :region_id;
EOF

echo -e "\n${YELLOW}Running single query benchmarks...${NC}"

# Run single query benchmarks with error checking
echo "Verifying table has data before running benchmarks..."
count_result=$(docker_psql -t -c "SELECT COUNT(*) FROM $full_table_name;" 2>/dev/null) || {
    echo -e "${RED}Error: Table does not exist or is not accessible${NC}";
    exit 1;
}
row_count=$(echo "$count_result" | tr -d ' ')

if [ "$row_count" -eq "0" ]; then
    echo -e "${RED}No data found in $full_table_name table. Skipping benchmarks.${NC}"
    exit 1
fi

echo "Table has $row_count rows. Running benchmarks..."

# Run single query benchmarks
run_query "Region Count Query" "SELECT region_id, COUNT(*) FROM $full_table_name GROUP BY region_id ORDER BY COUNT(*) DESC LIMIT 10;" 5 || true

run_query "Spatial Query" "SELECT COUNT(*) FROM $full_table_name WHERE ST_DWithin(location::geography, ST_SetSRID(ST_MakePoint(-73.9857, 40.7484), 4326)::geography, 10000);" 5 || true

run_query "Time Range Query" "SELECT COUNT(*) FROM $full_table_name WHERE created_at > NOW() - interval '30 days';" 5 || true

run_query "Complex Analytical Query" "
SELECT
    region_id,
    COUNT(*),
    AVG(value) as avg_value,
    MAX(ST_X(location)) - MIN(ST_X(location)) as lon_spread,
    MAX(ST_Y(location)) - MIN(ST_Y(location)) as lat_spread
FROM $full_table_name
GROUP BY region_id
ORDER BY avg_value DESC
LIMIT 10;" 3 || true

echo -e "\n${YELLOW}Running concurrent query benchmarks...${NC}"

# Run concurrent benchmarks with increasing concurrency
run_concurrent_test "Spatial Queries - Low Concurrency" 5 2 10 "$TMP_DIR/spatial_query.sql" || true
run_concurrent_test "Spatial Queries - Medium Concurrency" 10 4 10 "$TMP_DIR/spatial_query.sql" || true
run_concurrent_test "Spatial Queries - High Concurrency" 20 8 10 "$TMP_DIR/spatial_query.sql" || true

run_concurrent_test "Region Queries - Medium Concurrency" 10 4 10 "$TMP_DIR/region_query.sql" || true

# Check distribution of data
echo -e "\n${YELLOW}Checking data distribution across shards...${NC}"
docker_psql -c "
SELECT
    n.nodename,
    n.nodeport,
    COUNT(DISTINCT s.shardid) AS num_shards
FROM pg_dist_shard s
JOIN pg_dist_placement p ON s.shardid = p.shardid
JOIN pg_dist_node n ON p.groupid = n.groupid
WHERE s.logicalrelid::text LIKE '$full_table_name%'
GROUP BY n.nodename, n.nodeport
ORDER BY n.nodename;
" || echo -e "${RED}Could not check shard distribution${NC}"

# Show some shard statistics
echo -e "\n${YELLOW}Checking shard statistics...${NC}"
docker_psql -c "
SELECT
    s.shardid,
    n.nodename,
    n.nodeport,
    s.logicalrelid,
    s.shardminvalue,
    s.shardmaxvalue
FROM pg_dist_shard s
JOIN pg_dist_placement p ON s.shardid = p.shardid
JOIN pg_dist_node n ON p.groupid = n.groupid
WHERE s.logicalrelid::text LIKE '$full_table_name%'
ORDER BY s.shardid
LIMIT 10;
" || echo -e "${RED}Could not check shard statistics${NC}"

# Clean up temporary files
rm -rf $TMP_DIR

echo -e "\n${GREEN}Benchmark complete!${NC}"
echo "Results saved to $RESULTS_DIR directory for visualization"
echo "================================================"
