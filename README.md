# Distributed PostgreSQL Cluster with Citus and PostGIS

This project sets up a distributed PostgreSQL cluster using Citus and PostGIS with an active-active configuration, load balancing, and high availability.

## Architecture

The cluster is composed of multiple PostgreSQL nodes with Citus and PostGIS extensions configured in an active-active setup. Below is an example of the architecture:


## Prerequisites

- Docker and Docker Compose installed on your machine.

## Setup

1. Clone the repository:
   git clone https://github.com/trmazayal/database-sharding.git
   cd database-sharding

2. Set any required script permissions:
   chmod +x *.sh

3. Start the cluster:
   docker-compose up -d

4. Verify the cluster is running:
   docker-compose ps

## Testing the Cluster

1. Connect to the coordinator node via load balancer:
   docker exec -it citus_loadbalancer sh -c 'PGPASSWORD=citus psql -h localhost -p 5432 -U citus -d citus'

2. Create a distributed table:
    -- Create a distributed table
    CREATE TABLE vehicle_locations (
    id bigserial,
    vehicle_id int NOT NULL,
    location geometry(Point, 4326) NOT NULL,
    recorded_at timestamptz NOT NULL,
    region_code text NOT NULL  -- Make sure it's NOT NULL if it's the distribution column
    );

    -- Create necessary indexes
    CREATE INDEX idx_vehicle_locations_location ON vehicle_locations USING GIST (location);
    CREATE INDEX idx_vehicle_locations_region_code ON vehicle_locations (region_code);

    -- Distribute the table by region_code
    SELECT create_distributed_table('vehicle_locations', 'region_code');


3. Insert data into the distributed table:
    -- Insert 1,000,000 dummy rows into vehicle_locations
    INSERT INTO vehicle_locations (vehicle_id, location, recorded_at, region_code)
        SELECT
        -- Generate a random vehicle_id between 1 and 10,000
        (floor(random() * 10000) + 1)::int AS vehicle_id,

        -- Generate a random point near New York City, for example.
        -- Adjust the longitude and latitude ranges as needed.
        ST_SetSRID(
            ST_MakePoint(
            -74.0 + random() * 0.5,  -- longitude between -74.0 and -73.5
            40.7 + random() * 0.5    -- latitude between 40.7 and 41.2
            ),
            4326
        ) AS location,

        -- Generate a random timestamp within the last 30 days
        NOW() - (random() * interval '30 days') AS recorded_at,

        -- Randomly assign one of three region codes. Adjust or add more as needed.
        CASE
            WHEN random() < 0.33 THEN 'region_north'
            WHEN random() < 0.66 THEN 'region_south'
            ELSE 'region_central'
        END AS region_code
        FROM generate_series(1, 1000000) s(i);

4. Query to the table:
    -- Query all vehicles within 5km of a specific point
    SELECT id, vehicle_id, recorded_at, region_code
    FROM vehicle_locations
    WHERE ST_DWithin(
            location::geography,
            ST_SetSRID(ST_MakePoint(-73.9857, 40.7484), 4326)::geography,
            5000
        );

    -- Query all vehicles within a bounding box
    SELECT *
    FROM vehicle_locations
    WHERE ST_Within(
        location,
        ST_MakeEnvelope(-74.0, 40.7, -73.9, 40.8, 4326)
    );

## Benchmarking

The project includes several benchmark scripts to evaluate performance and high availability:

### Running Benchmarks

1. Standard benchmark (tests query performance and concurrency):
   ```bash
   ./benchmark.sh
   ```

2. Worker node benchmark (compares performance across different nodes):
   ```bash
   ./worker-benchmark.sh
   ```

3. High availability benchmark (tests failure recovery):
   ```bash
   ./ha-benchmark.sh
   ```

Make sure the permissions are set correctly:
   ```bash
   chmod +x benchmark.sh worker-benchmark.sh ha-benchmark.sh
   ```

### What's Being Tested

- Single query performance for various query types
- Concurrent query performance with different levels of concurrency
- Data distribution across the cluster
- Spatial query performance
- High availability during node failures
- Recovery times

## Component Breakdown

- Coordinator Nodes: Primary and secondary PostgreSQL servers running Citus.
- Worker Nodes: Nodes that store and process distributed data.
- Load Balancer: HAProxy configured to distribute incoming requests between coordinators.
- Manager: (Optional) A service to configure the cluster on startup.

### Key Files

- docker-compose.yml: Defines all services and their configurations.
- Dockerfile: Extends the Citus image with PostGIS.
- setup.sh: Initializes the cluster configuration.
- haproxy.cfg: Load balancer configuration.
- init.sql: Creates and populates a distributed table for testing.

## Troubleshooting

### Connection Issues

- Check running containers:
   docker-compose ps

- View load balancer logs:
   docker logs <load-balancer-container-name>

- View coordinator node logs:
   docker logs <coordinator-container-name>

### Data Distribution Issues

- Verify worker nodes registration:
   psql -h localhost -p 5432 -U postgres -c "SELECT * FROM pg_dist_node;"

- Check shard placement:
   psql -h localhost -p 5432 -U postgres -c "SELECT * FROM pg_dist_placement;"

- Verify shard count:
   psql -h localhost -p 5432 -U postgres -c "SELECT * FROM pg_dist_shard;"

## Cleanup

To stop and remove the cluster, run:
   docker-compose down

To completely remove all data volumes as well:
   docker-compose down -v

## Author

Tara Mazaya Lababan