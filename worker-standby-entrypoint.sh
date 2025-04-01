#!/bin/bash
set -e

echo "📥 Clearing old data from worker secondary node..."
rm -rf /var/lib/postgresql/data/*

# Install diagnostic tools if not already available
echo "Installing diagnostic tools..."
apt-get update -qq && apt-get install -y -qq netcat-openbsd iputils-ping 2>/dev/null || true

#############################################################
# MASTER-SLAVE ARCHITECTURE WITH STREAMING REPLICATION
#
# In this architecture:
# 1. PRIMARY (MASTER) - Accepts all write operations
#    - Generates Write-Ahead Log (WAL) records
#    - Serves as the authoritative copy of the database
#
# 2. SECONDARY (SLAVE) - Streaming replica of PRIMARY
#    - Continuously receives and applies WAL records
#    - Can serve read-only queries to distribute load
#    - Provides high availability with failover capability
#
# Streaming replication works by:
#   - The PRIMARY server streams WAL records to SECONDARY
#   - SECONDARY applies these records to maintain synchronization
#   - Recovery parameters in postgresql.conf control the process
#############################################################

# Get primary host from environment variable or use default
PRIMARY_HOST=${PRIMARY_HOST:-worker1_primary}
echo "🔄 Using primary host: ${PRIMARY_HOST}"

# Debug: Test network connectivity to primary
echo "🔍 Testing network connectivity to ${PRIMARY_HOST}..."
ping -c 3 ${PRIMARY_HOST} || echo "Warning: Ping to ${PRIMARY_HOST} failed, but this might be due to ping being disabled"
nc -zv ${PRIMARY_HOST} 5432 || echo "Warning: Cannot connect to ${PRIMARY_HOST}:5432, but will retry"

# Wait for the primary to be available with a timeout
echo "⏳ Waiting for primary node ${PRIMARY_HOST} to be ready..."
MAX_RETRIES=60  # increase timeout
RETRY_COUNT=0
until pg_isready -h ${PRIMARY_HOST} -U citus -d postgres -t 5 || [ $RETRY_COUNT -ge $MAX_RETRIES ]; do
    echo "Retry $((RETRY_COUNT+1))/$MAX_RETRIES: Waiting for primary ${PRIMARY_HOST}..."
    sleep 5
    RETRY_COUNT=$((RETRY_COUNT+1))

    # Every 5 retries, check connectivity again
    if (( $RETRY_COUNT % 5 == 0 )); then
        echo "Testing connectivity during retry..."
        nc -zv ${PRIMARY_HOST} 5432 || echo "Still cannot connect to ${PRIMARY_HOST}:5432"
    fi
done

if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    echo "❌ ERROR: Primary ${PRIMARY_HOST} not available after $MAX_RETRIES retries. Continuing anyway, will retry pg_basebackup..."
fi

# Try pg_basebackup with retries and verbose output
echo "🔄 Attempting to clone primary data using pg_basebackup..."
# pg_basebackup is the PostgreSQL utility that performs the initial snapshot
# of the PRIMARY database to initialize the SECONDARY replica
MAX_BASEBACKUP_RETRIES=5  # increase retries
BASEBACKUP_RETRY=0
BASEBACKUP_SUCCESS=false

# Check if postgres user exists on primary
echo "Checking if citus user exists on primary..."
PGPASSWORD=citus psql -h ${PRIMARY_HOST} -U postgres -d postgres -c "\du" || echo "Could not connect with postgres user"

while [ $BASEBACKUP_RETRY -lt $MAX_BASEBACKUP_RETRIES ] && [ "$BASEBACKUP_SUCCESS" = "false" ]; do
    echo "pg_basebackup attempt $((BASEBACKUP_RETRY+1))/$MAX_BASEBACKUP_RETRIES..."
    if PGPASSWORD=citus gosu postgres pg_basebackup -h ${PRIMARY_HOST} -D /var/lib/postgresql/data -U citus -R -P -X stream -v; then
        # -X stream: Use streaming replication mode to avoid WAL archiving
        # -R: Generate recovery configuration automatically
        # -P: Show progress information
        # -v: Verbose mode
        BASEBACKUP_SUCCESS=true
        echo "✅ pg_basebackup completed successfully!"
    else
        echo "❌ pg_basebackup failed (attempt $((BASEBACKUP_RETRY+1))/$MAX_BASEBACKUP_RETRIES)"
        BASEBACKUP_RETRY=$((BASEBACKUP_RETRY+1))
        sleep 10  # longer sleep between retries
    fi
done

if [ "$BASEBACKUP_SUCCESS" = "false" ]; then
    echo "❌ ERROR: Failed to complete pg_basebackup after $MAX_BASEBACKUP_RETRIES attempts"
    echo "Checking connectivity to primary ${PRIMARY_HOST}:"
    ping -c 3 ${PRIMARY_HOST} || echo "Ping failed to ${PRIMARY_HOST}"
    nc -zv ${PRIMARY_HOST} 5432 || echo "TCP connection test failed to ${PRIMARY_HOST}:5432"

    # Try with postgres user as fallback
    echo "Attempting pg_basebackup with postgres user as fallback..."
    if gosu postgres pg_basebackup -h ${PRIMARY_HOST} -D /var/lib/postgresql/data -U postgres -R -P -X stream -v; then
        echo "✅ pg_basebackup succeeded with postgres user!"
        BASEBACKUP_SUCCESS=true
    else
        echo "❌ Final attempt failed. Exiting."
        exit 1
    fi
fi

# Create standby.signal file if it doesn't exist yet
# This file indicates to PostgreSQL that this is a secondary (standby) server
if [ ! -f "/var/lib/postgresql/data/standby.signal" ]; then
    echo "📝 Creating standby.signal file..."
    touch /var/lib/postgresql/data/standby.signal
fi

echo "📝 Configuring PostgreSQL Standby settings..."

# Get PostgreSQL version to use the correct parameters
PG_VERSION=$(gosu postgres postgres --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
echo "Detected PostgreSQL version: $PG_VERSION"

# Update postgresql.conf with streaming replication parameters
cat >> /var/lib/postgresql/data/postgresql.conf << EOF
# Standby settings for streaming replication
primary_conninfo = 'host=${PRIMARY_HOST} port=5432 user=citus password=citus application_name=$(hostname)'
hot_standby = on                 # Allows read-only queries during recovery
max_standby_streaming_delay = 30s # Max delay before canceling queries if primary is receiving traffic
hot_standby_feedback = on        # Send info to PRIMARY about standby queries to prevent WAL removal

# Replication performance settings
wal_receiver_status_interval = 10s # Seconds between status packets sent to PRIMARY
wal_receiver_timeout = 60s      # Seconds to wait for WAL from primary
EOF

# In PostgreSQL 17+, recovery parameters are different
# Don't configure the promotion trigger file in postgresql.conf
# Instead, we'll use the pg_promote() function from worker-promotion.sh
echo "Note: For PostgreSQL 17+, will use pg_promote() function for standby promotion"

# Check if SSL certificate files exist and handle SSL configuration appropriately
if [ -f "/var/lib/postgresql/data/server.crt" ] && [ -f "/var/lib/postgresql/data/server.key" ]; then
    echo "📝 SSL certificate files found, enabling SSL..."
    echo "ssl = on" >> /var/lib/postgresql/data/postgresql.auto.conf
    echo "ssl_ciphers = 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384'" >> /var/lib/postgresql/data/postgresql.auto.conf
else
    echo "⚠️ SSL certificate files not found, disabling SSL..."
    echo "ssl = off" >> /var/lib/postgresql/data/postgresql.auto.conf
fi

# Explicitly configure pg_hba.conf for trust authentication method
echo "📝 Configuring pg_hba.conf..."
cat > /var/lib/postgresql/data/pg_hba.conf << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Allow all connections with trust authentication
local   all             all                                     trust
host    all             all             0.0.0.0/0               trust
host    replication     all             0.0.0.0/0               trust
EOF

# Fix permissions on data directory
echo "🔧 Fixing permissions on data directory..."
chown -R postgres:postgres /var/lib/postgresql/data
chmod 0700 /var/lib/postgresql/data

echo "✅ Starting PostgreSQL in standby mode with promotion capability..."
echo "    - Streaming replication has been configured"
echo "    - This instance will receive WAL records from ${PRIMARY_HOST}"
echo "    - Use worker-promotion.sh to promote this standby to primary if needed"
exec gosu postgres postgres
