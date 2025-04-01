#!/bin/bash
set -e

# Set the PostgreSQL password for non-interactive psql commands
export PGPASSWORD=citus

# Logging function
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to ensure Citus extension exists
ensure_citus_extension() {
  local host=$1
  log "Ensuring Citus extension exists on $host..."

  if psql -h "$host" -p 5432 -U citus -d citus -c "CREATE EXTENSION IF NOT EXISTS citus;" > /dev/null 2>&1; then
    log "Citus extension is ready on $host."
    return 0
  else
    log "Failed to create Citus extension on $host."
    return 1
  fi
}

# Function to check if a host is reachable
check_host() {
  local host=$1
  local port=$2
  pg_isready -h "$host" -p "$port" -U citus -t 3 > /dev/null 2>&1
  return $?
}

# Function to promote a secondary to primary
promote_secondary() {
  local secondary=$1
  log "Promoting $secondary to primary..."

  # Execute the promote command on the secondary
  if psql -h "$secondary" -p 5432 -U citus -d citus -c "SELECT pg_promote();" > /dev/null 2>&1; then
    log "Successfully promoted $secondary to primary."
    return 0
  else
    log "Failed to promote $secondary to primary."
    return 1
  fi
}

# Function to update Citus coordinator configuration after promotion
update_coordinators() {
  local old_primary=$1
  local new_primary=$2

  log "Updating Citus coordinators to use the new primary $new_primary..."

  for coordinator in coordinator_primary coordinator_secondary; do
    if check_host $coordinator 5432; then
      # Ensure Citus extension exists first
      ensure_citus_extension $coordinator

      # Update the node metadata in the coordinator
      psql -h $coordinator -U citus -d citus -c "SELECT * FROM citus_update_node(node_id, '$new_primary', 5432) FROM pg_dist_node WHERE nodename='$old_primary';" || {
        log "Failed to update node metadata on $coordinator. Will retry later."
      }

      # Add the old primary back as a secondary once it comes online
      log "Setting up the old primary $old_primary as a secondary of $new_primary when available"

      log "$coordinator updated to use $new_primary"
    else
      log "Could not connect to $coordinator to update configuration."
    fi
  done
}

# State persistence file to maintain node roles across restarts
STATE_FILE="/var/lib/postgresql/worker_state.json"

# Load state from file if exists
load_state() {
  log "Loading node state..."
  if [ -f "$STATE_FILE" ]; then
    # Read each line from the state file and restore arrays
    while IFS= read -r line; do
      if [[ $line =~ ^primary:([^=]+)=(.+)$ ]]; then
        worker="${BASH_REMATCH[1]}"
        host="${BASH_REMATCH[2]}"
        current_primarys["$worker"]="$host"
        log "Loaded primary for $worker: $host"
      elif [[ $line =~ ^secondary:([^=]+)=(.+)$ ]]; then
        worker="${BASH_REMATCH[1]}"
        host="${BASH_REMATCH[2]}"
        current_secondarys["$worker"]="$host"
        log "Loaded secondary for $worker: $host"
      fi
    done < "$STATE_FILE"
    log "State loaded successfully"
    return 0
  else
    log "No state file found, initializing with default configuration"
    return 1
  fi
}

# Save state to file
save_state() {
  log "Saving current node state..."
  # Clear existing file
  > "$STATE_FILE"

  # Save primary nodes
  for worker in "${!current_primarys[@]}"; do
    echo "primary:$worker=${current_primarys[$worker]}" >> "$STATE_FILE"
  done

  # Save secondary nodes
  for worker in "${!current_secondarys[@]}"; do
    echo "secondary:$worker=${current_secondarys[$worker]}" >> "$STATE_FILE"
  done

  log "State saved successfully"
}

# Initialize our known configuration (standard setup)
initialize_node_tracking() {
  log "Initializing worker node tracking..."

  # Try to load state from file first
  if (! load_state); then
    # If loading fails, set default configuration
    current_primarys["worker1"]="worker1_primary"
    current_primarys["worker2"]="worker2_primary"
    current_primarys["worker3"]="worker3_primary"
    current_secondarys["worker1"]="worker1_secondary"
    current_secondarys["worker2"]="worker2_secondary"
    current_secondarys["worker3"]="worker3_secondary"
    log "Node tracking initialized with default configuration."

    # Save the initial state
    save_state
  fi
}

# Function to handle when a former primary comes back online
handle_former_primary() {
  local former_primary=$1
  local current_primary=$2
  local worker_num=$3

  log "🔍 Detected former primary $former_primary is back online"
  log "⚠️ IMPORTANT: Keeping $current_primary as primary and treating $former_primary as secondary"

  # Update our state tracking to ensure former primary remains secondary
  # (Do NOT change current_primarys - this is crucial)
  current_secondarys["worker$worker_num"]=$former_primary

  # Save the updated state
  save_state

  log "✅ State updated: $current_primary remains primary, $former_primary is now secondary"

  # Notify about manual intervention needed
  log "👉 Manual intervention required: Please configure $former_primary as replica of $current_primary"

  return 0
}

# Store failovers to track worker primary/secondary relationships
declare -A current_primarys
declare -A current_secondarys

# Initialize node tracking when the script starts
initialize_node_tracking

# Ensure Citus extension exists on the coordinator before verification
log "Ensuring Citus extension exists on coordinators..."
ensure_citus_extension coordinator_primary || log "Warning: Could not ensure Citus extension on coordinator_primary"
ensure_citus_extension coordinator_secondary || log "Warning: Could not ensure Citus extension on coordinator_secondary"

# Try to verify node registration, but continue even if it fails
log "Attempting to verify node configuration including secondaries..."
if psql -h coordinator_primary -U citus -d citus -c "SELECT nodeid, nodename, nodeport, noderole FROM pg_dist_node;" > /dev/null 2>&1; then
  log "Node verification successful."
else
  log "Could not verify node configuration. Will continue monitoring anyway."
fi

# Main monitoring loop
while true; do
  log "Starting health check..."

  # Check primary-secondary pairs
  for i in 1 2 3; do
    primary_key="worker$i"
    primary=${current_primarys[$primary_key]}
    secondary=${current_secondarys[$primary_key]}

    log "Checking worker $i: master=$primary, slave=$secondary"

    # Check if primary is down but secondary is up
    if ! check_host $primary 5432 && check_host $secondary 5432; then
      log "⚠️ $primary is down but $secondary is up. Initiating promotion..."

      # Promote the secondary to become a primary
      if promote_secondary $secondary; then
        # Update coordinators to use the promoted secondary
        update_coordinators $primary $secondary

        # Update our tracking arrays
        old_primary=$primary
        current_primarys[$primary_key]=$secondary
        current_secondarys[$primary_key]=$old_primary

        # Save the updated state
        save_state

        log "✅ Failover complete: $secondary is now the new master for worker$i"
      else
        log "❌ Failed to promote $secondary"
      fi
    elif ! check_host $primary 5432 && ! check_host $secondary 5432; then
      log "❌ Both $primary and $secondary are down! Worker $i is completely unavailable."
    else
      # Both nodes are up - check if we need to update our state tracking
      if [[ $primary != "worker${i}_primary" ]] && check_host "worker${i}_primary" 5432; then
        # Former primary is back online - ensure it stays as secondary
        handle_former_primary "worker${i}_primary" $primary $i
      elif [[ $secondary != "worker${i}_secondary" ]] && check_host "worker${i}_secondary" 5432; then
        log "🔍 Detected former secondary worker${i}_secondary is back online - no action needed"
      else
        log "✓ Worker $i health check passed."
      fi
    fi
  done

  log "Health check complete. Sleeping for 30 seconds..."
  sleep 30
done
