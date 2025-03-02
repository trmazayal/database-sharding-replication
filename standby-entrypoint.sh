#!/bin/bash
set -e

echo "📥 Clearing old data from standby node..."
rm -rf /var/lib/postgresql/data/*

# Wait for the primary to be available
echo "⏳ Waiting for primary coordinator to be ready..."
until pg_isready -h citus_coordinator_primary -U citus; do
    sleep 2
done

echo "🔄 Cloning primary data using pg_basebackup..."
gosu postgres pg_basebackup -h citus_coordinator_primary -D /var/lib/postgresql/data -U citus -R -P -X stream

# Create standby.signal file instead of setting standby_mode in postgresql.conf
touch /var/lib/postgresql/data/standby.signal

echo "📝 Configuring PostgreSQL Standby settings..."
echo "primary_conninfo = 'host=citus_coordinator_primary port=5432 user=citus password=citus'" >> /var/lib/postgresql/data/postgresql.conf

# Fix permissions on data directory
echo "🔧 Fixing permissions on data directory..."
chown -R postgres:postgres /var/lib/postgresql/data
chmod 0700 /var/lib/postgresql/data

echo "✅ Starting PostgreSQL in standby mode..."
exec gosu postgres postgres
