#!/bin/bash
set -e

# Set the PostgreSQL password for non-interactive psql commands
export PGPASSWORD=citus

# Function to wait for a host to be ready with a timeout
wait_for() {
  local host=$1
  local port=$2
  local max_attempts=$3
  local attempt=1

  echo "Waiting for $host to be ready on port $port (max $max_attempts attempts)..."

  while [ $attempt -le $max_attempts ]; do
    if pg_isready -h "$host" -p "$port" -t 3; then
      echo "$host is ready."
      return 0
    else
      echo "Attempt $attempt/$max_attempts: Retrying connection to $host..."
      sleep 5
      attempt=$((attempt+1))
    fi
  done

  echo "WARNING: $host was not ready after $max_attempts attempts. Continuing anyway."
  return 1
}

# Install additional diagnostic tools
echo "Installing diagnostic tools..."
apt-get update -qq && apt-get install -y -qq netcat-openbsd iputils-ping 2>/dev/null || true

echo "Starting Citus cluster setup..."

# Wait for coordinator nodes (required to continue)
wait_for coordinator_primary 5432 30 || { echo "ERROR: Primary coordinator not ready. Exiting."; exit 1; }
wait_for coordinator_secondary 5432 30 || { echo "ERROR: Secondary coordinator not ready. Exiting."; exit 1; }

# Wait for master worker nodes (required to continue)
wait_for worker1_master 5432 20 || { echo "ERROR: Worker1 master not ready. Exiting."; exit 1; }
wait_for worker2_master 5432 20 || { echo "ERROR: Worker2 master not ready. Exiting."; exit 1; }
wait_for worker3_master 5432 20 || { echo "ERROR: Worker3 master not ready. Exiting."; exit 1; }

# Try waiting for slave worker nodes but continue if not available
echo "Checking slave worker nodes (will continue even if not ready)..."
wait_for worker1_slave 5432 10 || echo "WARNING: Worker1 slave not ready, continuing without it."
wait_for worker2_slave 5432 10 || echo "WARNING: Worker2 slave not ready, continuing without it."
wait_for worker3_slave 5432 10 || echo "WARNING: Worker3 slave not ready, continuing without it."

echo "All required nodes are ready. Configuring Citus cluster..."

# Create the Citus extension on coordinators and master worker nodes only
echo "Creating Citus extension on coordinators and master worker nodes..."
for node in coordinator_primary coordinator_secondary worker1_master worker2_master worker3_master; do
  echo "Creating Citus extension on $node..."
  psql -h $node -U citus -d citus -c "CREATE EXTENSION IF NOT EXISTS citus;"
done

# Create the PostGIS extension on coordinators and master worker nodes only
echo "Creating PostGIS extension on coordinators and master worker nodes..."
for node in coordinator_primary coordinator_secondary worker1_master worker2_master worker3_master; do
  echo "Creating PostGIS extension on $node..."
  psql -h $node -U citus -d citus -c "CREATE EXTENSION IF NOT EXISTS postgis;"
done

# Add worker master nodes to both coordinators
echo "Adding worker master nodes to the coordinators..."
for coordinator in coordinator_primary coordinator_secondary; do
  echo "Adding worker master nodes to $coordinator..."

  # Configure Citus to handle node connectivity issues gracefully
  psql -h $coordinator -U citus -d citus -c "ALTER SYSTEM SET citus.node_connection_timeout = 10000;" # 10 seconds
  psql -h $coordinator -U citus -d citus -c "SELECT pg_reload_conf();"

  # Add master workers to the Citus cluster
  psql -h $coordinator -U citus -d citus -c "SELECT * FROM citus_add_node('worker1_master', 5432);"
  psql -h $coordinator -U citus -d citus -c "SELECT * FROM citus_add_node('worker2_master', 5432);"
  psql -h $coordinator -U citus -d citus -c "SELECT * FROM citus_add_node('worker3_master', 5432);"
done

# Verify replication setup
echo "Verifying replication setup on primary coordinator..."
psql -h coordinator_primary -U citus -d citus -c "SELECT nodename, nodeport, noderack FROM pg_dist_node;"

echo "Verifying replication setup on secondary coordinator..."
psql -h coordinator_secondary -U citus -d citus -c "SELECT nodename, nodeport, noderack FROM pg_dist_node;"

echo "Master-Slave Citus cluster setup complete."
echo "Worker slaves are configured as hot standby nodes for their respective masters."
echo "You can connect to the cluster through the load balancer at localhost:5432"