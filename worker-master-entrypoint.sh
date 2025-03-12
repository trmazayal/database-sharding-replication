#!/bin/bash
set -e

echo "Starting worker master initialization..."

# Check if PostgreSQL is already initialized
if [ ! -s "/var/lib/postgresql/data/PG_VERSION" ]; then
    echo "📥 Initializing worker master PostgreSQL data directory..."

    # Set environment variables
    POSTGRES_USER=${POSTGRES_USER:-citus}
    POSTGRES_DB=${POSTGRES_DB:-citus}
    POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-citus}

    # Clear out the data directory to avoid permission issues
    rm -rf /var/lib/postgresql/data/*

    # Initialize the database with initdb directly
    gosu postgres initdb -D /var/lib/postgresql/data

    # Configure PostgreSQL for replication
    echo "📝 Configuring PostgreSQL for replication..."
    cat >> /var/lib/postgresql/data/postgresql.conf << EOF

# Worker master configuration for replication
listen_addresses = '*'
wal_level = logical
max_wal_senders = 10
max_replication_slots = 10
max_connections = 200
EOF

    # Configure pg_hba.conf with trust authentication
    echo "📝 Configuring pg_hba.conf for replication..."
    cat > /var/lib/postgresql/data/pg_hba.conf << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# "local" is for Unix domain socket connections only
local   all             all                                     trust
# Allow all connections from Docker network
host    all             all             0.0.0.0/0               trust
# Allow replication connections
host    replication     all             0.0.0.0/0               trust
EOF

    # Fix permissions on data directory
    echo "🔧 Setting ownership of data directory to postgres..."
    chown -R postgres:postgres /var/lib/postgresql/data
    chmod 0700 /var/lib/postgresql/data

    # Start PostgreSQL temporarily to create users and databases
    echo "🔄 Starting PostgreSQL temporarily to create users and databases..."
    gosu postgres pg_ctl -D /var/lib/postgresql/data -w start

    # Create user and database
    echo "🔑 Creating user '$POSTGRES_USER' and database '$POSTGRES_DB'..."
    gosu postgres psql -v ON_ERROR_STOP=1 --username postgres <<-EOSQL
        CREATE USER "$POSTGRES_USER" WITH SUPERUSER PASSWORD '$POSTGRES_PASSWORD';
        CREATE DATABASE "$POSTGRES_DB" WITH OWNER "$POSTGRES_USER";
        GRANT ALL PRIVILEGES ON DATABASE "$POSTGRES_DB" TO "$POSTGRES_USER";

        -- Create a root user for compatibility with Docker-related health checks
        CREATE USER "root" WITH SUPERUSER PASSWORD 'rootpassword';

        -- Create a root database to fix "database root does not exist" error
        CREATE DATABASE "root" WITH OWNER "root";
        GRANT ALL PRIVILEGES ON DATABASE "root" TO "root";

        -- Set default database for root connections
        ALTER ROLE "root" SET search_path TO "$POSTGRES_DB";
EOSQL

    # Stop PostgreSQL after initialization
    echo "⏹️ Stopping PostgreSQL after initialization..."
    gosu postgres pg_ctl -D /var/lib/postgresql/data -m fast -w stop

    echo "✅ PostgreSQL initialization completed."
else
    echo "📝 PostgreSQL data directory already exists."
fi

echo "✅ Starting worker master PostgreSQL node..."
exec gosu postgres postgres
