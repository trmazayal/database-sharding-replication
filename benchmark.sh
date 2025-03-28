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

echo -e "${GREEN}Starting Citus Cluster Benchmark${NC}"
echo "================================================"

# Function to run psql commands inside Docker container
docker_psql() {
    docker exec -i $CONTAINER psql -h $HOST -p $PORT -U $USER -d $DB "$@"
}

# Install pgbench in the container (using specific PostgreSQL version)
echo -e "${YELLOW}Installing pgbench in container...${NC}"
# First check PostgreSQL version to install matching client
PG_VERSION=$(docker exec $CONTAINER psql -t -c "SHOW server_version;" | cut -d '.' -f1)
echo "Detected PostgreSQL version: $PG_VERSION"
docker exec $CONTAINER apt-get update -qq
docker exec $CONTAINER apt-get install -y postgresql-client-$PG_VERSION || {
    echo -e "${RED}Failed to install postgresql-client-$PG_VERSION. Trying generic package...${NC}"
    docker exec $CONTAINER apt-get install -y postgresql-client || {
        echo -e "${RED}Failed to install PostgreSQL client tools. pgbench tests will not work.${NC}"
    }
}

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

    # Run pgbench inside the container
    docker exec -i $CONTAINER pgbench -h $HOST -p $PORT -U $USER -d $DB \
            -c $clients -j $threads -T $time \
            -f "/tmp/$(basename "$script")" \
            -P 5 || {
        echo -e "${RED}Error running concurrent benchmark.${NC}"
    }
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

    # Create and distribute a points table for spatial queries - WITHOUT PRIMARY KEY
    # Ensure proper schema qualification for table creation
    docker_psql << EOF || { echo -e "${RED}Error creating table${NC}"; exit 1; }
    -- First drop the table if it exists to avoid conflicts
    DROP TABLE IF EXISTS benchmark_points CASCADE;

    -- Create a sequence for the ID field
    DROP SEQUENCE IF EXISTS benchmark_points_id_seq CASCADE;
    CREATE SEQUENCE benchmark_points_id_seq;

    -- Create table without primary key constraint
    -- Using bigint with nextval instead of bigserial to avoid implicit PK
    CREATE TABLE benchmark_points (
        id bigint DEFAULT nextval('benchmark_points_id_seq'),
        region_id int NOT NULL,
        location geometry(Point, 4326) NOT NULL,
        value float NOT NULL,
        created_at timestamptz NOT NULL DEFAULT NOW()
    );
EOF

    # Distribute the table immediately after creation
    echo "Distributing table by region_id..."
    docker_psql -c "SELECT create_distributed_table('benchmark_points', 'region_id');" || {
        echo -e "${RED}Error distributing table${NC}";
        exit 1;
    }

    # Create indexes after the table is distributed
    echo "Creating spatial and other indexes..."
    docker_psql -c "CREATE INDEX idx_benchmark_points_id ON benchmark_points (id);" || echo -e "${RED}Warning: Could not create id index${NC}"
    docker_psql -c "CREATE INDEX idx_benchmark_points_location ON benchmark_points USING GIST (location);" || echo -e "${RED}Warning: Could not create spatial index${NC}"
    docker_psql -c "CREATE INDEX idx_benchmark_points_region ON benchmark_points (region_id);" || echo -e "${RED}Warning: Could not create region index${NC}"

    # Insert test data - 100k points across 100 regions
    echo "Inserting benchmark data (this may take a few minutes)..."
    docker_psql << EOF || { echo -e "${RED}Error inserting data${NC}"; exit 1; }
    INSERT INTO benchmark_points (region_id, location, value, created_at)
    SELECT
        (random() * 99 + 1)::int AS region_id,
        ST_SetSRID(ST_MakePoint(-180 + random() * 360, -90 + random() * 180), 4326) AS location,
        random() * 100 AS value,
        NOW() - (random() * interval '90 days') AS created_at
    FROM generate_series(1, 100000) s(i);
EOF

    # Verify the data was inserted
    echo "Verifying data insertion..."
    count_result=$(docker_psql -t -c "SELECT COUNT(*) FROM benchmark_points;" 2>/dev/null) || {
        echo -e "${RED}Error: Could not verify data insertion${NC}";
        exit 1;
    }
    row_count=$(echo "$count_result" | tr -d ' ')
    echo "Successfully created benchmark table with $row_count rows."
else
    echo "Using existing benchmark table with $row_count rows."
fi

# Create pgbench scripts for concurrent tests
TMP_DIR=$(mktemp -d)
cat > $TMP_DIR/spatial_query.sql << EOF
SELECT COUNT(*)
FROM benchmark_points
WHERE ST_DWithin(location::geography,
                ST_SetSRID(ST_MakePoint(-73.9 + random(), 40.7 + random()), 4326)::geography,
                10000);
EOF

cat > $TMP_DIR/region_query.sql << EOF
SELECT region_id, COUNT(*), AVG(value)
FROM benchmark_points
WHERE region_id = (random() * 99 + 1)::int
GROUP BY region_id;
EOF

cat > $TMP_DIR/mixed_workload.sql << EOF
\\set region_id random(1, 100)
SELECT COUNT(*) FROM benchmark_points WHERE region_id = :region_id;
EOF

echo -e "\n${YELLOW}Running single query benchmarks...${NC}"

# Run single query benchmarks with error checking
echo "Verifying table has data before running benchmarks..."
count_result=$(docker_psql -t -c "SELECT COUNT(*) FROM benchmark_points;" 2>/dev/null) || {
    echo -e "${RED}Error: Table does not exist or is not accessible${NC}";
    exit 1;
}
row_count=$(echo "$count_result" | tr -d ' ')

if [ "$row_count" -eq "0" ]; then
    echo -e "${RED}No data found in benchmark_points table. Skipping benchmarks.${NC}"
    exit 1
fi

echo "Table has $row_count rows. Running benchmarks..."

# Run single query benchmarks
run_query "Region Count Query" "SELECT region_id, COUNT(*) FROM benchmark_points GROUP BY region_id ORDER BY COUNT(*) DESC LIMIT 10;" 5 || true

run_query "Spatial Query" "SELECT COUNT(*) FROM benchmark_points WHERE ST_DWithin(location::geography, ST_SetSRID(ST_MakePoint(-73.9857, 40.7484), 4326)::geography, 10000);" 5 || true

run_query "Time Range Query" "SELECT COUNT(*) FROM benchmark_points WHERE created_at > NOW() - interval '30 days';" 5 || true

run_query "Complex Analytical Query" "
SELECT
    region_id,
    COUNT(*),
    AVG(value) as avg_value,
    MAX(ST_X(location)) - MIN(ST_X(location)) as lon_spread,
    MAX(ST_Y(location)) - MIN(ST_Y(location)) as lat_spread
FROM benchmark_points
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
WHERE s.logicalrelid::text LIKE 'benchmark_points%'
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
WHERE s.logicalrelid::text LIKE 'benchmark_points%'
ORDER BY s.shardid
LIMIT 10;
" || echo -e "${RED}Could not check shard statistics${NC}"

# Clean up temporary files
rm -rf $TMP_DIR

echo -e "\n${GREEN}Benchmark complete!${NC}"
echo "================================================"
