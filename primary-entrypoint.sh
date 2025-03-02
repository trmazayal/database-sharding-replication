#!/bin/bash
set -e

# Ensure the archive directory exists
mkdir -p /var/lib/postgresql/data/archive

# Start PostgreSQL first to generate the default config
docker-entrypoint.sh postgres &

# Wait for PostgreSQL to start
sleep 5

# Allow replication connections from standby
echo "host replication citus 0.0.0.0/0 trust" >> /var/lib/postgresql/data/pg_hba.conf
echo "host all all 0.0.0.0/0 trust" >> /var/lib/postgresql/data/pg_hba.conf

# Reload configuration instead of restarting to avoid shutdown
gosu postgres pg_ctl -D /var/lib/postgresql/data reload

# Keep container running
wait
