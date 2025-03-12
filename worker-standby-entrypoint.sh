#!/bin/bash
set -e

echo "📥 Clearing old data from worker slave node..."
rm -rf /var/lib/postgresql/data/*

# Install diagnostic tools if not already available
echo "Installing diagnostic tools..."
apt-get update -qq && apt-get install -y -qq netcat-openbsd iputils-ping 2>/dev/null || true

# Get master host from environment variable or use default
MASTER_HOST=${MASTER_HOST:-worker1_master}
echo "🔄 Using master host: ${MASTER_HOST}"

# Debug: Test network connectivity to master
echo "🔍 Testing network connectivity to ${MASTER_HOST}..."
ping -c 3 ${MASTER_HOST} || echo "Warning: Ping to ${MASTER_HOST} failed, but this might be due to ping being disabled"
nc -zv ${MASTER_HOST} 5432 || echo "Warning: Cannot connect to ${MASTER_HOST}:5432, but will retry"

# Wait for the master to be available with a timeout
echo "⏳ Waiting for master node ${MASTER_HOST} to be ready..."
MAX_RETRIES=60  # increase timeout
RETRY_COUNT=0
until pg_isready -h ${MASTER_HOST} -U citus -d postgres -t 5 || [ $RETRY_COUNT -ge $MAX_RETRIES ]; do
    echo "Retry $((RETRY_COUNT+1))/$MAX_RETRIES: Waiting for master ${MASTER_HOST}..."
    sleep 5
    RETRY_COUNT=$((RETRY_COUNT+1))

    # Every 5 retries, check connectivity again
    if (( $RETRY_COUNT % 5 == 0 )); then
        echo "Testing connectivity during retry..."
        nc -zv ${MASTER_HOST} 5432 || echo "Still cannot connect to ${MASTER_HOST}:5432"
    fi
done

if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    echo "❌ ERROR: Master ${MASTER_HOST} not available after $MAX_RETRIES retries. Continuing anyway, will retry pg_basebackup..."
fi

# Try pg_basebackup with retries and verbose output
echo "🔄 Attempting to clone master data using pg_basebackup..."
MAX_BASEBACKUP_RETRIES=5  # increase retries
BASEBACKUP_RETRY=0
BASEBACKUP_SUCCESS=false

# Check if postgres user exists on master
echo "Checking if citus user exists on master..."
PGPASSWORD=citus psql -h ${MASTER_HOST} -U postgres -d postgres -c "\du" || echo "Could not connect with postgres user"

while [ $BASEBACKUP_RETRY -lt $MAX_BASEBACKUP_RETRIES ] && [ "$BASEBACKUP_SUCCESS" = "false" ]; do
    echo "pg_basebackup attempt $((BASEBACKUP_RETRY+1))/$MAX_BASEBACKUP_RETRIES..."
    if PGPASSWORD=citus gosu postgres pg_basebackup -h ${MASTER_HOST} -D /var/lib/postgresql/data -U citus -R -P -X stream -v; then
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
    echo "Checking connectivity to master ${MASTER_HOST}:"
    ping -c 3 ${MASTER_HOST} || echo "Ping failed to ${MASTER_HOST}"
    nc -zv ${MASTER_HOST} 5432 || echo "TCP connection test failed to ${MASTER_HOST}:5432"

    # Try with postgres user as fallback
    echo "Attempting pg_basebackup with postgres user as fallback..."
    if gosu postgres pg_basebackup -h ${MASTER_HOST} -D /var/lib/postgresql/data -U postgres -R -P -X stream -v; then
        echo "✅ pg_basebackup succeeded with postgres user!"
        BASEBACKUP_SUCCESS=true
    else
        echo "❌ Final attempt failed. Exiting."
        exit 1
    fi
fi

# Create standby.signal file if it doesn't exist yet
if [ ! -f "/var/lib/postgresql/data/standby.signal" ]; then
    echo "📝 Creating standby.signal file..."
    touch /var/lib/postgresql/data/standby.signal
fi

echo "📝 Configuring PostgreSQL Standby settings..."

# Get PostgreSQL version to use the correct parameters
PG_VERSION=$(gosu postgres postgres --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
echo "Detected PostgreSQL version: $PG_VERSION"

cat >> /var/lib/postgresql/data/postgresql.conf << EOF
# Standby settings
primary_conninfo = 'host=${MASTER_HOST} port=5432 user=citus password=citus'
hot_standby = on
max_standby_streaming_delay = 30s
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
exec gosu postgres postgres
