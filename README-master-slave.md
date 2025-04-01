# Master-Slave Architecture with Streaming Replication in Citus

This document explains how the Master-Slave (Primary-Secondary) architecture with streaming replication works in our Citus cluster.

## Overview

The Citus cluster implements a Master-Slave architecture for each worker node where:

- **Primary (Master)** - The main database instance that accepts read and write operations
- **Secondary (Slave)** - A replica that maintains a copy of the primary's data through streaming replication

## How Streaming Replication Works

1. **Write-Ahead Logging (WAL)**
   - PostgreSQL records all changes in WAL files before applying them to the database
   - These WAL records contain all information needed to reproduce the changes on another server

2. **WAL Sender Process**
   - A process on the primary that sends WAL records to connected replicas
   - Runs on the primary server and communicates with the WAL receiver

3. **WAL Receiver Process**
   - A process on the secondary that receives WAL records from the primary
   - Writes the WAL records to the secondary's own WAL files

4. **Startup Process**
   - A process on the secondary that replays the WAL records
   - Applies the changes to the secondary's data files

## Configuration Components

### Primary Server

The primary server is configured in `worker-primary-entrypoint.sh` with these key settings:

```
listen_addresses = '*'
wal_level = logical
max_wal_senders = 10
max_replication_slots = 10
```

These settings enable the primary to:
- Accept connections from any IP address
- Generate WAL records with sufficient detail for replication
- Support up to 10 concurrent replication connections

### Secondary Server

The secondary server is configured in `worker-standby-entrypoint.sh` with these key settings:

```
primary_conninfo = 'host=primary_host port=5432 user=citus password=citus'
hot_standby = on
max_standby_streaming_delay = 30s
```

These settings enable the secondary to:
- Connect to the primary server for streaming replication
- Serve read-only queries while applying WAL records
- Wait up to 30 seconds before canceling queries if applying WAL would cause conflicts

## Initial Synchronization

Initial synchronization is performed using `pg_basebackup`, which:
1. Creates a consistent snapshot of the primary database
2. Transfers all data files to the secondary
3. Creates the necessary configuration for streaming replication

## Failover Process

If the primary fails, the `worker-promotion.sh` script handles failover by:
1. Detecting that the primary is down
2. Promoting a secondary to become the new primary using `pg_promote()`
3. Updating the Citus coordinator to recognize the new primary
4. Tracking the previous primary as a future secondary when it comes back online

## Monitoring Replication

You can monitor replication status on the primary with:

```sql
SELECT * FROM pg_stat_replication;
```

And on the secondary with:

```sql
SELECT * FROM pg_stat_wal_receiver;
```
