#!/bin/bash
set -e

# Set the PostgreSQL password for non-interactive psql commands
export PGPASSWORD=citus

# Function to wait for a host to be ready
wait_for() {
  local host=$1
  local port=$2
  echo "Waiting for $host to be ready on port $port..."
  until pg_isready -h "$host" -p "$port"; do
    sleep 1
  done
  echo "$host is ready."
}

# Wait for all nodes to be ready
wait_for coordinator 5432
wait_for worker1 5432
wait_for worker2 5432

echo "All nodes are ready."

# Create the Citus extension on the coordinator and workers
echo "Creating Citus extension on coordinator..."
psql -h coordinator -U citus -d citus -c "CREATE EXTENSION IF NOT EXISTS citus;"

echo "Creating Citus extension on worker1..."
psql -h worker1 -U citus -d citus -c "CREATE EXTENSION IF NOT EXISTS citus;"

echo "Creating Citus extension on worker2..."
psql -h worker2 -U citus -d citus -c "CREATE EXTENSION IF NOT EXISTS citus;"

# Create the PostGIS extension on the coordinator and workers
echo "Creating PostGIS extension on coordinator..."
psql -h coordinator -U citus -d citus -c "CREATE EXTENSION IF NOT EXISTS postgis;"

echo "Creating PostGIS extension on worker1..."
psql -h worker1 -U citus -d citus -c "CREATE EXTENSION IF NOT EXISTS postgis;"

echo "Creating PostGIS extension on worker2..."
psql -h worker2 -U citus -d citus -c "CREATE EXTENSION IF NOT EXISTS postgis;"

# Add worker nodes to the coordinator with full connection URIs including credentials
echo "Adding worker nodes to the coordinator..."
psql -h coordinator -U citus -d citus -c "SELECT citus_add_node('worker1', 5432);"
psql -h coordinator -U citus -d citus -c "SELECT citus_add_node('worker2', 5432);"

echo "Citus cluster with PostGIS support setup complete."