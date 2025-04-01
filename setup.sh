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

# Wait for primary worker nodes (required to continue)
wait_for worker1_primary 5432 20 || { echo "ERROR: Worker1 primary not ready. Exiting."; exit 1; }
wait_for worker2_primary 5432 20 || { echo "ERROR: Worker2 primary not ready. Exiting."; exit 1; }
wait_for worker3_primary 5432 20 || { echo "ERROR: Worker3 primary not ready. Exiting."; exit 1; }

# Try waiting for secondary worker nodes but continue if not available
echo "Checking secondary worker nodes (will continue even if not ready)..."
wait_for worker1_secondary 5432 10 || echo "WARNING: Worker1 secondary not ready, continuing without it."
wait_for worker2_secondary 5432 10 || echo "WARNING: Worker2 secondary not ready, continuing without it."
wait_for worker3_secondary 5432 10 || echo "WARNING: Worker3 secondary not ready, continuing without it."

echo "All required nodes are ready. Configuring Citus cluster..."

# Create the Citus extension on coordinators and primary worker nodes
echo "Creating Citus extension on coordinators and primary worker nodes..."
for node in coordinator_primary coordinator_secondary worker1_primary worker2_primary worker3_primary; do
  echo "Creating Citus extension on $node..."
  psql -h $node -U citus -d citus -c "CREATE EXTENSION IF NOT EXISTS citus;"
done

# Create the PostGIS extension on coordinators and primary worker nodes only
echo "Creating PostGIS extension on coordinators and primary worker nodes..."
for node in coordinator_primary coordinator_secondary worker1_primary worker2_primary worker3_primary; do
  echo "Creating PostGIS extension on $node..."
  psql -h $node -U citus -d citus -c "CREATE EXTENSION IF NOT EXISTS postgis;"
done

# Set Citus configurations for coordinator nodes
echo "Configuring Citus settings on coordinator nodes..."
for coordinator in coordinator_primary coordinator_secondary; do
  echo "Configuring settings on $coordinator..."

  # Configure SSL mode for node connections
  psql -h $coordinator -U citus -d citus -c "ALTER SYSTEM SET citus.node_conninfo TO 'sslmode=prefer';"

  # Configure longer connection timeouts
  psql -h $coordinator -U citus -d citus -c "ALTER SYSTEM SET citus.node_connection_timeout = 10000;"

  # Reload configuration
  psql -h $coordinator -U citus -d citus -c "SELECT pg_reload_conf();"

  # Add primary workers to the Citus cluster
  psql -h $coordinator -U citus -d citus -c "SELECT * FROM citus_add_node('worker1_primary', 5432);"
  psql -h $coordinator -U citus -d citus -c "SELECT * FROM citus_add_node('worker2_primary', 5432);"
  psql -h $coordinator -U citus -d citus -c "SELECT * FROM citus_add_node('worker3_primary', 5432);"
done

echo "Adding primary and secondary workers to the cluster..."
for coordinator in coordinator_primary coordinator_secondary; do
  echo "Configuring nodes on $coordinator..."

  # Add primary workers as regular nodes
  psql -h $coordinator -U citus -d citus -c "SELECT * FROM citus_add_node('worker1_primary', 5432);"
  psql -h $coordinator -U citus -d citus -c "SELECT * FROM citus_add_node('worker2_primary', 5432);"
  psql -h $coordinator -U citus -d citus -c "SELECT * FROM citus_add_node('worker3_primary', 5432);"

  # Add secondary workers as secondary nodes
  psql -h $coordinator -U citus -d citus -c "SELECT * FROM citus_add_secondary_node('worker1_secondary', 5432, 'worker1_primary', 5432);"
  psql -h $coordinator -U citus -d citus -c "SELECT * FROM citus_add_secondary_node('worker2_secondary', 5432, 'worker2_primary', 5432);"
  psql -h $coordinator -U citus -d citus -c "SELECT * FROM citus_add_secondary_node('worker3_secondary', 5432, 'worker3_primary', 5432);"

  # Replace the ALTER SYSTEM statement with:
  psql -h $coordinator -U citus -d citus -c "ALTER SYSTEM SET citus.use_secondary_nodes = 'never';"
  psql -h $coordinator -U citus -d citus -c "SELECT pg_reload_conf();"
done

echo "Creating read balancing function..."
for coordinator in coordinator_primary coordinator_secondary; do
  psql -h $coordinator -U citus -d citus << EOF
-- Create helper function for read operations
CREATE OR REPLACE FUNCTION use_secondary_if_available() RETURNS void AS \$\$
BEGIN
  IF current_setting('citus.use_secondary_nodes') = 'never' THEN
    SET LOCAL citus.use_secondary_nodes TO 'always';
  END IF;
END;
\$\$ LANGUAGE plpgsql;

-- Example of usage
COMMENT ON FUNCTION use_secondary_if_available() IS
  'Call this function at the start of read-heavy transactions to use secondary nodes';
EOF
done

# Verify replication setup
echo "Verifying replication setup on primary coordinator..."
psql -h coordinator_primary -U citus -d citus -c "SELECT nodename, nodeport, noderack FROM pg_dist_node;"

echo "Verifying replication setup on secondary coordinator..."
psql -h coordinator_secondary -U citus -d citus -c "SELECT nodename, nodeport, noderack FROM pg_dist_node;"

echo "Verifying node configuration including secondaries..."
psql -h coordinator_primary -U citus -d citus -c "SELECT nodeid, nodename, nodeport, noderole FROM pg_dist_node;"

echo "Primary-Secondary Citus cluster setup complete."
echo "Worker secondarys are configured as hot standby nodes for their respective primarys."
echo "You can connect to the cluster through the load balancer at localhost:5432"