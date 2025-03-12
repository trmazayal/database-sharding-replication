#!/bin/bash
set -e

# Set the PostgreSQL password for non-interactive psql commands
export PGPASSWORD=citus

# Logging function
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to check if a host is reachable
check_host() {
  local host=$1
  local port=$2
  pg_isready -h "$host" -p "$port" -U citus -t 3 > /dev/null 2>&1
  return $?
}

# Function to promote a slave to master
promote_slave() {
  local slave=$1
  log "Promoting $slave to master..."

  # Execute the promote command on the slave
  if psql -h "$slave" -p 5432 -U citus -d citus -c "SELECT pg_promote();" > /dev/null 2>&1; then
    log "Successfully promoted $slave to master."
    return 0
  else
    log "Failed to promote $slave to master."
    return 1
  fi
}

# Function to update Citus coordinator configuration after promotion
update_coordinators() {
  local old_master=$1
  local new_master=$2

  log "Updating Citus coordinators to use the new master $new_master..."

  for coordinator in coordinator_primary coordinator_secondary; do
    if check_host $coordinator 5432; then
      log "Updating $coordinator configuration..."

      # Update node metadata in coordinator
      psql -h $coordinator -U citus -d citus -c "
        BEGIN;
        UPDATE pg_dist_node
        SET nodename = '$new_master'
        WHERE nodename = '$old_master';
        COMMIT;
      " > /dev/null 2>&1 || log "Failed to update node metadata in $coordinator"

      # Force metadata sync
      psql -h $coordinator -U citus -d citus -c "SELECT citus_internal.refresh_database_metadata();" > /dev/null 2>&1 || log "Failed to refresh metadata in $coordinator"

      log "$coordinator updated to use $new_master"
    else
      log "Could not connect to $coordinator to update configuration."
    fi
  done
}

# Main monitoring loop
while true; do
  log "Starting health check..."

  # Check master-slave pairs
  for i in 1 2 3; do
    master="worker${i}_master"
    slave="worker${i}_slave"

    # Check if master is down but slave is up
    if ! check_host $master 5432 && check_host $slave 5432; then
      log "⚠️ $master is down but $slave is up. Initiating promotion..."

      # Promote the slave to become a master
      if promote_slave $slave; then
        # Update coordinators to use the promoted slave
        update_coordinators $master $slave

        log "✅ Failover complete: $slave is now the new master for worker$i"
      else
        log "❌ Failed to promote $slave"
      fi
    elif ! check_host $master 5432 && ! check_host $slave 5432; then
      log "❌ Both $master and $slave are down! Worker $i is completely unavailable."
    else
      log "✓ Worker $i health check passed."
    fi
  done

  log "Health check complete. Sleeping for 30 seconds..."
  sleep 30
done
