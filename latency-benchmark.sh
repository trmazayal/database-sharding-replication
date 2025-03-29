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
LATENCY_CSV="${RESULTS_DIR}/latency_benchmark_results.csv"

# Create results directory
mkdir -p ${RESULTS_DIR}
mkdir -p ${RESULTS_DIR}/graphs

# Initialize CSV with header
echo "operation,operation_type,batch_size,latency_ms,throughput_per_sec" > "${LATENCY_CSV}"

echo -e "${GREEN}Starting Read/Write Latency Benchmark${NC}"
echo "================================================"

# Function to run psql commands inside Docker container
docker_psql() {
    docker exec -i -e PGPASSWORD="$PGPASSWORD" $CONTAINER psql -h $HOST -p $PORT -U $USER -d $DB "$@"
}

# Function to measure operation latency
measure_latency() {
    local operation="$1"
    local operation_type="$2"
    local batch_size="$3"
    local query="$4"
    local iterations="${5:-10}" # Default to 10 iterations

    echo -e "\n${YELLOW}Measuring latency for $operation ($operation_type, size: $batch_size)...${NC}"

    # Run once to warm cache if it's a read operation
    if [[ "$operation_type" == "read" ]]; then
        docker_psql -c "$query" > /dev/null 2>&1
    fi

    # Run the query multiple times and measure
    local total_time=0
    local start_time=$(date +%s.%N)

    for i in $(seq 1 $iterations); do
        docker_psql -c "$query" > /dev/null 2>&1
    done

    local end_time=$(date +%s.%N)
    local total_seconds=$(echo "$end_time - $start_time" | bc)
    local avg_latency_ms=$(echo "scale=2; ($total_seconds * 1000) / $iterations" | bc)
    local throughput=$(echo "scale=2; $iterations / $total_seconds" | bc)

    echo -e "${GREEN}Average latency: $avg_latency_ms ms${NC}"
    echo -e "${GREEN}Throughput: $throughput operations/second${NC}"

    # Write to CSV file
    echo "$operation,$operation_type,$batch_size,$avg_latency_ms,$throughput" >> "${LATENCY_CSV}"
}

# Check if vehicle_locations table exists and has data
echo -e "\n${YELLOW}Checking if benchmark data exists...${NC}"
table_exists=false
row_count=0

# Check if table exists
if docker_psql -c "SELECT 1 FROM pg_tables WHERE tablename = 'vehicle_locations';" | grep -q "1"; then
    table_exists=true

    # Check for rows - wait for the count to complete
    count_result=$(docker_psql -t -c "SELECT COUNT(*) FROM vehicle_locations;" 2>/dev/null | tr -d ' ')
    # Check if count_result is numeric
    if [[ $count_result =~ ^[0-9]+$ ]]; then
        row_count=$count_result
    else
        row_count=0
    fi
    echo -e "Found $row_count rows in vehicle_locations table"
else
    echo -e "${YELLOW}Table vehicle_locations does not exist${NC}"
fi

# If table doesn't exist or is empty, create and populate it
if [ "$table_exists" = false ] || [ "$row_count" -lt 1000 ]; then
    echo -e "${YELLOW}Not enough data for benchmark. Creating sample data...${NC}"

    if [ "$table_exists" = false ]; then
        echo -e "${YELLOW}Creating vehicle_locations table...${NC}"

        # Check if PostGIS extension is available and create it if needed
        if ! docker_psql -t -c "SELECT 1 FROM pg_extension WHERE extname = 'postgis';" | grep -q "1"; then
            echo "Creating PostGIS extension..."
            docker_psql -c "CREATE EXTENSION IF NOT EXISTS postgis CASCADE;"
        fi

        # Create the table with a clean state
        docker_psql -c "DROP TABLE IF EXISTS vehicle_locations CASCADE;"
        docker_psql -c "
        CREATE TABLE vehicle_locations (
          id bigserial,
          vehicle_id int NOT NULL,
          location geometry(Point, 4326) NOT NULL,
          recorded_at timestamptz NOT NULL,
          region_code text NOT NULL
        );"

        # Distribute the table
        echo -e "${YELLOW}Distributing table by region_code...${NC}"
        docker_psql -c "SELECT create_distributed_table('vehicle_locations', 'region_code');"

        # Create indexes
        echo -e "${YELLOW}Creating indexes...${NC}"
        docker_psql -c "CREATE INDEX idx_vehicle_locations_location ON vehicle_locations USING GIST (location);"
        docker_psql -c "CREATE INDEX idx_vehicle_locations_region_code ON vehicle_locations (region_code);"
    else
        echo -e "${YELLOW}Truncating existing table...${NC}"
        docker_psql -c "TRUNCATE vehicle_locations;"
    fi

    # Insert sample data (10,000 rows instead of 1,000,000 to speed up the process)
    echo -e "${YELLOW}Inserting 10,000 sample rows (this will take a moment)...${NC}"
    docker_psql -c "
    INSERT INTO vehicle_locations (vehicle_id, location, recorded_at, region_code)
    SELECT
        (floor(random() * 10000) + 1)::int AS vehicle_id,
        ST_SetSRID(
            ST_MakePoint(
                -74.0 + random() * 0.5,  -- longitude between -74.0 and -73.5
                40.7 + random() * 0.5    -- latitude between 40.7 and 41.2
            ),
            4326
        ) AS location,
        NOW() - (random() * interval '30 days') AS recorded_at,
        CASE
            WHEN random() < 0.33 THEN 'region_north'
            WHEN random() < 0.66 THEN 'region_south'
            ELSE 'region_central'
        END AS region_code
    FROM generate_series(1, 10000) s(i);"

    # Verify data with more robust error checking
    echo -e "${YELLOW}Verifying data was inserted correctly...${NC}"

    # Wait up to 30 seconds for the data to be visible (distributed tables can have delays)
    max_attempts=6
    for attempt in $(seq 1 $max_attempts); do
        echo "Checking data (attempt $attempt of $max_attempts)..."
        sleep 5
        count_result=$(docker_psql -t -c "SELECT COUNT(*) FROM vehicle_locations;" 2>/dev/null | tr -d ' ')

        # Check if count_result is numeric
        if [[ $count_result =~ ^[0-9]+$ ]] && [ "$count_result" -gt 0 ]; then
            row_count=$count_result
            echo -e "${GREEN}Successfully inserted data. Now have $row_count rows in vehicle_locations table${NC}"
            break
        fi
    done

    if [ "$row_count" -eq 0 ]; then
        echo -e "${RED}Warning: Could not verify data was inserted. Continuing anyway...${NC}"
    fi
else
    echo -e "${GREEN}Found sufficient data for benchmark${NC}"
fi

# Create temp table for write tests to avoid affecting the main data
echo -e "\n${YELLOW}Creating temporary table for write tests...${NC}"

# Force drop the write_test table if it exists (in the public schema)
echo -e "${YELLOW}Dropping write_test table if it exists...${NC}"
docker_psql -c "DROP TABLE IF EXISTS public.write_test CASCADE;" || true

# Wait briefly to ensure the drop is processed
sleep 2

# Create the table as public.write_test
echo -e "${YELLOW}Creating new write_test table...${NC}"
docker_psql -c "CREATE TABLE public.write_test (
    id SERIAL,
    vehicle_id INT NOT NULL,
    location geometry(Point, 4326) NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL,
    region_code TEXT NOT NULL
);"

# Verify table was created
if docker_psql -t -c "SELECT to_regclass('public.write_test');" | grep -q "public.write_test"; then
    echo -e "${GREEN}Table created successfully${NC}"

    # Small delay to ensure table is fully created in the catalog
    sleep 2

    # Distribute the table
    echo -e "${YELLOW}Distributing write_test table...${NC}"
    if docker_psql -c "SELECT create_distributed_table('public.write_test', 'region_code');" > /dev/null 2>&1; then
        echo -e "${GREEN}Table distributed successfully${NC}"
    else
        echo -e "${YELLOW}Note: Could not distribute table, continuing with local table${NC}"
    fi
else
    echo -e "${RED}Table creation failed, using local table${NC}"
fi

# Clean any existing data
docker_psql -c "TRUNCATE write_test;" > /dev/null 2>&1

# ----- READ LATENCY BENCHMARKS -----

echo -e "\n${YELLOW}Running READ latency benchmarks...${NC}"

# Simple point queries
measure_latency "Point Query" "read" "single" "
SELECT * FROM vehicle_locations
WHERE id = (SELECT id FROM vehicle_locations LIMIT 1);"

# Range queries
measure_latency "Range Query" "read" "small" "
SELECT * FROM vehicle_locations
WHERE recorded_at > NOW() - interval '1 day'
LIMIT 10;"

measure_latency "Range Query" "read" "medium" "
SELECT * FROM vehicle_locations
WHERE recorded_at > NOW() - interval '1 day'
LIMIT 100;"

measure_latency "Range Query" "read" "large" "
SELECT * FROM vehicle_locations
WHERE recorded_at > NOW() - interval '1 day'
LIMIT 1000;"

# Spatial queries
measure_latency "Spatial Query" "read" "small" "
SELECT * FROM vehicle_locations
WHERE ST_DWithin(
    location::geography,
    ST_SetSRID(ST_MakePoint(-73.9857, 40.7484), 4326)::geography,
    1000
)
LIMIT 10;"

measure_latency "Spatial Query" "read" "medium" "
SELECT * FROM vehicle_locations
WHERE ST_DWithin(
    location::geography,
    ST_SetSRID(ST_MakePoint(-73.9857, 40.7484), 4326)::geography,
    5000
)
LIMIT 100;"

# Aggregate queries
measure_latency "Aggregate Query" "read" "full" "
SELECT region_code, COUNT(*), AVG(vehicle_id)
FROM vehicle_locations
GROUP BY region_code;"

# ----- WRITE LATENCY BENCHMARKS -----

echo -e "\n${YELLOW}Running WRITE latency benchmarks...${NC}"

# Single row insert
measure_latency "Insert" "write" "single" "
INSERT INTO write_test (vehicle_id, location, recorded_at, region_code)
VALUES (
    floor(random() * 10000) + 1,
    ST_SetSRID(ST_MakePoint(-74.0 + random() * 0.5, 40.7 + random() * 0.5), 4326),
    NOW(),
    CASE WHEN random() < 0.33 THEN 'region_north'
         WHEN random() < 0.66 THEN 'region_south'
         ELSE 'region_central' END
);"

# Batch insert - small (10 rows)
measure_latency "Insert" "write" "small" "
INSERT INTO write_test (vehicle_id, location, recorded_at, region_code)
SELECT
    (floor(random() * 10000) + 1)::int AS vehicle_id,
    ST_SetSRID(
        ST_MakePoint(
        -74.0 + random() * 0.5,
        40.7 + random() * 0.5
        ),
        4326
    ) AS location,
    NOW() - (random() * interval '30 days') AS recorded_at,
    CASE
        WHEN random() < 0.33 THEN 'region_north'
        WHEN random() < 0.66 THEN 'region_south'
        ELSE 'region_central'
    END AS region_code
FROM generate_series(1, 10) s(i);"

# Batch insert - medium (100 rows)
measure_latency "Insert" "write" "medium" "
INSERT INTO write_test (vehicle_id, location, recorded_at, region_code)
SELECT
    (floor(random() * 10000) + 1)::int AS vehicle_id,
    ST_SetSRID(
        ST_MakePoint(
        -74.0 + random() * 0.5,
        40.7 + random() * 0.5
        ),
        4326
    ) AS location,
    NOW() - (random() * interval '30 days') AS recorded_at,
    CASE
        WHEN random() < 0.33 THEN 'region_north'
        WHEN random() < 0.66 THEN 'region_south'
        ELSE 'region_central'
    END AS region_code
FROM generate_series(1, 100) s(i);"

# Batch insert - large (1000 rows)
measure_latency "Insert" "write" "large" "
INSERT INTO write_test (vehicle_id, location, recorded_at, region_code)
SELECT
    (floor(random() * 10000) + 1)::int AS vehicle_id,
    ST_SetSRID(
        ST_MakePoint(
        -74.0 + random() * 0.5,
        40.7 + random() * 0.5
        ),
        4326
    ) AS location,
    NOW() - (random() * interval '30 days') AS recorded_at,
    CASE
        WHEN random() < 0.33 THEN 'region_north'
        WHEN random() < 0.66 THEN 'region_south'
        ELSE 'region_central'
    END AS region_code
FROM generate_series(1, 1000) s(i);"

# Update operations
measure_latency "Update" "write" "single" "
UPDATE write_test
SET vehicle_id = floor(random() * 10000) + 1
WHERE id = (SELECT id FROM write_test LIMIT 1);"

measure_latency "Update" "write" "small" "
UPDATE write_test
SET vehicle_id = floor(random() * 10000) + 1
WHERE id IN (SELECT id FROM write_test LIMIT 10);"

measure_latency "Update" "write" "medium" "
UPDATE write_test
SET vehicle_id = floor(random() * 10000) + 1
WHERE id IN (SELECT id FROM write_test LIMIT 100);"

# Delete operations
measure_latency "Delete" "write" "single" "
DELETE FROM write_test
WHERE id = (SELECT id FROM write_test LIMIT 1);"

measure_latency "Delete" "write" "small" "
DELETE FROM write_test
WHERE id IN (SELECT id FROM write_test ORDER BY random() LIMIT 10);"

# Clean up
echo -e "\n${YELLOW}Cleaning up test table...${NC}"
docker_psql -c "DROP TABLE IF EXISTS write_test;"

echo -e "\n${GREEN}Latency benchmark complete!${NC}"
echo "Results saved to ${LATENCY_CSV} for visualization"
echo "================================================"
