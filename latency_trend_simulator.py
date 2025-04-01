#!/usr/bin/env python3
import time
import random
import subprocess
import threading
import matplotlib.pyplot as plt
import matplotlib.animation as animation
import numpy as np
from collections import deque
from datetime import datetime, timedelta
import argparse
import os
from matplotlib.ticker import FuncFormatter

# Configuration
DEFAULT_HOST = "localhost"
DEFAULT_PORT = "5432"
DEFAULT_USER = "citus"
DEFAULT_DB = "citus"
DEFAULT_PASSWORD = "citus"
DEFAULT_CONTAINER = "citus_loadbalancer"

# Global variables for data storage
timestamps = deque(maxlen=120)  # Store last 2 minutes of data by default
latencies = deque(maxlen=120)   # Store latencies corresponding to timestamps
errors = deque(maxlen=120)      # Store any errors

# New variables for throughput tracking
query_timestamps = deque(maxlen=300)  # Store timestamps of each query for throughput calculation
throughput_timestamps = deque(maxlen=120)  # Timestamps for throughput measurements
throughput_values = deque(maxlen=120)      # Throughput values (queries per second)
throughput_window = 10  # Calculate throughput over 10 second sliding window

# Parameters for simulation
current_load_factor = 1.0
load_pattern = "steady"
trend_direction = "flat"
trend_counter = 0
spike_probability = 0.05
spike_magnitude = 3.0

# Flag for table existence
table_exists = False

# Query types
QUERIES = {
    "simple": "SELECT COUNT(*) FROM vehicle_locations;",
    "spatial": """
        SELECT COUNT(*) FROM vehicle_locations
        WHERE ST_DWithin(
            location::geography,
            ST_SetSRID(ST_MakePoint(-73.9857, 40.7484), 4326)::geography,
            5000
        );
    """,
    "complex": """
        SELECT region_code, COUNT(*), AVG(ST_X(location)), AVG(ST_Y(location))
        FROM vehicle_locations
        GROUP BY region_code
        ORDER BY region_code;
    """
}

# Flag to control the simulation
running = True

def check_table_exists(host, port, user, db, password, container):
    """Check if the vehicle_locations table exists in the database"""
    cmd = [
        "docker", "exec", "-i",
        "-e", f"PGPASSWORD={password}",
        container,
        "psql", "-h", host, "-p", port, "-U", user, "-d", db,
        "-t", "-c", "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'vehicle_locations');"
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        if result.returncode == 0 and 't' in result.stdout.strip().lower():
            print("✅ vehicle_locations table exists in the database")
            return True
        else:
            print("❌ vehicle_locations table does not exist in the database")
            return False
    except Exception as e:
        print(f"Error checking table existence: {str(e)}")
        return False

def initialize_table(host, port, user, db, password, container):
    """Create the vehicle_locations table if it doesn't exist"""
    print("🔧 Attempting to create vehicle_locations table...")

    # First create PostGIS extension
    ext_cmd = [
        "docker", "exec", "-i",
        "-e", f"PGPASSWORD={password}",
        container,
        "psql", "-h", host, "-p", port, "-U", user, "-d", db,
        "-c", "CREATE EXTENSION IF NOT EXISTS postgis CASCADE;"
    ]

    # Then create table
    table_cmd = [
        "docker", "exec", "-i",
        "-e", f"PGPASSWORD={password}",
        container,
        "psql", "-h", host, "-p", port, "-U", user, "-d", db,
        "-c", """
        CREATE TABLE vehicle_locations (
          id bigserial,
          vehicle_id int NOT NULL,
          location geometry(Point, 4326) NOT NULL,
          recorded_at timestamptz NOT NULL,
          region_code text NOT NULL
        );
        """
    ]

    # Insert sample data
    data_cmd = [
        "docker", "exec", "-i",
        "-e", f"PGPASSWORD={password}",
        container,
        "psql", "-h", host, "-p", port, "-U", user, "-d", db,
        "-c", """
        INSERT INTO vehicle_locations (vehicle_id, location, recorded_at, region_code)
        SELECT
            (floor(random() * 10000) + 1)::int AS vehicle_id,
            ST_SetSRID(
                ST_MakePoint(
                -74.0 + random() * 0.5,
                40.7 + random() * 0.5
                ),
                4326
            ) AS location,
            NOW() - (random() * interval '30 days') AS recorded_at,
            CASE
                WHEN random() < 0.33 THEN 'region_north'
                WHEN random() < 0.66 THEN 'region_south'
                ELSE 'region_central'
            END AS region_code
        FROM generate_series(1, 1000) s(i);
        """
    ]

    try:
        # Create extension
        subprocess.run(ext_cmd, capture_output=True, text=True, timeout=10)
        # Create table
        result = subprocess.run(table_cmd, capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            # Insert data
            data_result = subprocess.run(data_cmd, capture_output=True, text=True, timeout=30)
            if data_result.returncode == 0:
                print("✅ Successfully created table and inserted sample data")
                return True
            else:
                print(f"⚠️ Created table but failed to insert data: {data_result.stderr.strip()}")
                return True
        else:
            print(f"❌ Failed to create table: {result.stderr.strip()}")
            return False
    except Exception as e:
        print(f"❌ Error initializing table: {str(e)}")
        return False

def execute_query(host, port, user, db, password, container, query_type="simple"):
    """Execute a query and measure its latency"""
    query = QUERIES.get(query_type, QUERIES["simple"])

    # Construct the command to run inside the container
    cmd = [
        "docker", "exec", "-i",
        "-e", f"PGPASSWORD={password}",
        container,
        "psql", "-h", host, "-p", port, "-U", user, "-d", db,
        "-c", query
    ]

    try:
        start_time = time.time()
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        end_time = time.time()

        if result.returncode != 0:
            print(f"Error executing query: {result.stderr.strip()}")
            return None, result.stderr

        # Calculate latency in milliseconds
        latency = (end_time - start_time) * 1000
        return latency, None

    except subprocess.TimeoutExpired:
        print("Query timed out after 10 seconds")
        return None, "Query timeout"
    except Exception as e:
        print(f"Error: {str(e)}")
        return None, str(e)

def apply_load_pattern(base_latency):
    """Apply the current load pattern to modify the base latency"""
    global current_load_factor, trend_direction, trend_counter

    # Apply random noise (±10%)
    noise = random.uniform(0.9, 1.1)

    # Apply the current load factor
    adjusted_latency = base_latency * current_load_factor * noise

    # Check for random spikes
    if random.random() < spike_probability:
        print("⚠️ Simulating latency spike!")
        adjusted_latency *= spike_magnitude

    # Update load factor based on pattern
    if load_pattern == "cyclic":
        # Sinusoidal pattern
        current_load_factor = 1.0 + 0.5 * np.sin(trend_counter / 10)
        trend_counter += 1
    elif load_pattern == "increasing":
        # Gradually increasing load
        current_load_factor += 0.01
        if current_load_factor > 3.0:
            current_load_factor = 3.0
    elif load_pattern == "decreasing":
        # Gradually decreasing load
        current_load_factor -= 0.01
        if current_load_factor < 0.5:
            current_load_factor = 0.5
    elif load_pattern == "step":
        # Step function (alternate between high and low load)
        if trend_counter % 30 == 0:  # Change every 30 seconds
            current_load_factor = 2.0 if current_load_factor == 1.0 else 1.0
        trend_counter += 1

    return adjusted_latency

def calculate_throughput():
    """Calculate the current throughput based on query timestamps"""
    global query_timestamps, throughput_timestamps, throughput_values

    now = datetime.now()
    window_start = now - timedelta(seconds=throughput_window)

    # Count queries in the last window period
    queries_in_window = sum(1 for ts in query_timestamps if ts > window_start)

    # Calculate queries per second
    qps = queries_in_window / throughput_window if queries_in_window > 0 else 0

    # Store the calculation
    throughput_timestamps.append(now)
    throughput_values.append(qps)

    return qps

def query_thread(args):
    """Thread function to continuously run queries"""
    global running, timestamps, latencies, errors, table_exists, query_timestamps

    base_latencies = {
        "simple": 50.0,    # base latency for simple query in ms
        "spatial": 150.0,  # base latency for spatial query in ms
        "complex": 300.0   # base latency for complex query in ms
    }

    # Check if table exists before starting
    if not args.simulate:
        table_exists = check_table_exists(args.host, args.port, args.user, args.db, args.password, args.container)

        if not table_exists and args.create_table:
            # Try to create the table
            table_exists = initialize_table(args.host, args.port, args.user, args.db, args.password, args.container)

        if not table_exists:
            print("🔄 Table doesn't exist. Switching to simulation mode.")
            args.simulate = True

    print(f"Starting latency and throughput simulation with {args.pattern} load pattern")
    print(f"Mode: {'Simulation' if args.simulate else 'Real database queries'}")

    # Add throughput calculation on a separate thread
    def throughput_calculator():
        while running:
            calculate_throughput()
            time.sleep(1)  # Update throughput every second

    throughput_thread = threading.Thread(target=throughput_calculator)
    throughput_thread.daemon = True
    throughput_thread.start()

    while running:
        try:
            # Choose query type based on distribution
            query_type = random.choices(
                ["simple", "spatial", "complex"],
                weights=[0.6, 0.3, 0.1]
            )[0]

            # Record query start time for throughput calculations
            query_start = datetime.now()
            query_timestamps.append(query_start)

            # Check if we should use real database or simulate
            if args.simulate:
                # Simulate a latency based on query type
                base_latency = base_latencies[query_type]
                latency = apply_load_pattern(base_latency)
                error = None
                time.sleep(0.5)  # Simulate query execution time
            else:
                # Run a real query against the database
                latency, error = execute_query(
                    args.host, args.port, args.user, args.db, args.password,
                    args.container, query_type
                )

                # If we get an error that the table doesn't exist, switch to simulation mode
                if error and "relation \"vehicle_locations\" does not exist" in error:
                    print("⚠️ Table not found error. Switching to simulation mode.")
                    args.simulate = True
                    table_exists = False
                    continue

            # Record timestamp and latency
            now = datetime.now()
            timestamps.append(now)

            if latency is not None:
                latencies.append(latency)
                # Calculate current throughput
                qps = calculate_throughput()
                print(f"{now.strftime('%H:%M:%S')} | {query_type:8} | Latency: {latency:.2f} ms | Load: {current_load_factor:.2f} | Throughput: {qps:.2f} qps")
            else:
                latencies.append(None)
                errors.append((now, error))
                print(f"{now.strftime('%H:%M:%S')} | {query_type:8} | ERROR: {error}")

            # Wait before next query
            time.sleep(args.interval)

        except Exception as e:
            print(f"Error in query thread: {str(e)}")
            time.sleep(args.interval)

def update_plot(i, ax, args):
    """Update function for matplotlib animation"""
    ax.clear()

    # Create a second y-axis for throughput
    ax2 = ax.twinx()

    # Convert deques to lists for plotting
    times = list(timestamps)
    lats = list(latencies)
    tp_times = list(throughput_timestamps)
    tp_values = list(throughput_values)

    # Filter out None values
    valid_data = [(t, l) for t, l in zip(times, lats) if l is not None]
    if not valid_data:
        ax.text(0.5, 0.5, "No valid data yet", ha='center', va='center', transform=ax.transAxes)
        return

    # Unpack data
    valid_times, valid_lats = zip(*valid_data)

    # Plot latency trend
    latency_line = ax.plot(valid_times, valid_lats, 'b-', label='Latency (ms)')

    # Plot throughput if we have data
    if tp_times and tp_values:
        throughput_line = ax2.plot(tp_times, tp_values, 'g-', label='Throughput (qps)')
        ax2.set_ylabel('Throughput (queries/sec)', color='g')
        ax2.tick_params(axis='y', labelcolor='g')

    # Add markers for errors
    for err_time, _ in errors:
        if err_time in valid_times:
            idx = valid_times.index(err_time)
            ax.plot(err_time, valid_lats[idx], 'ro', markersize=8)

    # Configure the plot
    title = f"Real-time Performance - {args.pattern.capitalize()} Pattern"
    if args.simulate:
        title += " (SIMULATION MODE)"
    ax.set_title(title)
    ax.set_xlabel("Time")
    ax.set_ylabel("Latency (ms)", color='b')
    ax.tick_params(axis='y', labelcolor='b')
    ax.grid(True)

    # Format y-axis to show milliseconds
    ax.yaxis.set_major_formatter(FuncFormatter(lambda x, _: f"{x:.0f} ms"))

    # Set reasonable y limits
    if valid_lats:
        max_lat = max(valid_lats)
        ax.set_ylim(0, max(max_lat * 1.1, 100))

    # Set y-axis for throughput
    if tp_values:
        max_tp = max(tp_values)
        ax2.set_ylim(0, max(max_tp * 1.1, 5))

    # Combine legends
    lines = []
    labels = []
    if 'latency_line' in locals():
        lines.extend(latency_line)
        labels.append('Latency (ms)')
    if 'throughput_line' in locals():
        lines.extend(throughput_line)
        labels.append('Throughput (qps)')

    if lines and labels:
        ax.legend(lines, labels, loc='upper left')

    # Add a legend for the current load factor
    stats_text = (
        f"Load Factor: {current_load_factor:.2f}x\n"
        f"Avg Latency: {np.mean(list(latencies)[-10:]):.1f} ms\n"
        f"Throughput: {throughput_values[-1] if throughput_values else 0:.2f} qps"
    )
    ax.text(0.02, 0.95, stats_text, transform=ax.transAxes,
            fontsize=9, verticalalignment='top',
            bbox=dict(boxstyle='round', facecolor='white', alpha=0.5))

    # Rotate x-axis labels for better readability
    plt.xticks(rotation=45)
    plt.tight_layout()

def main():
    parser = argparse.ArgumentParser(description='Simulate and visualize real-time database query latency and throughput')

    parser.add_argument('--host', default=DEFAULT_HOST, help='PostgreSQL host')
    parser.add_argument('--port', default=DEFAULT_PORT, help='PostgreSQL port')
    parser.add_argument('--user', default=DEFAULT_USER, help='PostgreSQL user')
    parser.add_argument('--db', default=DEFAULT_DB, help='PostgreSQL database')
    parser.add_argument('--password', default=DEFAULT_PASSWORD, help='PostgreSQL password')
    parser.add_argument('--container', default=DEFAULT_CONTAINER, help='Docker container name')
    parser.add_argument('--interval', type=float, default=1.0, help='Query interval in seconds')
    parser.add_argument('--duration', type=int, default=300, help='Simulation duration in seconds (0 for infinite)')
    parser.add_argument('--pattern', choices=['steady', 'cyclic', 'increasing', 'decreasing', 'step'],
                        default='steady', help='Load pattern to simulate')
    parser.add_argument('--spike-prob', type=float, default=0.05, help='Probability of latency spikes (0-1)')
    parser.add_argument('--simulate', action='store_true', help='Simulate queries instead of running real ones')
    parser.add_argument('--create-table', action='store_true', help='Create vehicle_locations table if it doesn\'t exist')
    parser.add_argument('--throughput-window', type=int, default=10,
                        help='Time window in seconds for throughput calculation')

    args = parser.parse_args()

    global load_pattern, spike_probability, throughput_window
    load_pattern = args.pattern
    spike_probability = args.spike_prob
    if hasattr(args, 'throughput_window'):
        throughput_window = args.throughput_window

    # Create output directory for screenshots if it doesn't exist
    os.makedirs("latency_trends", exist_ok=True)

    # Set up the figure
    fig, ax = plt.subplots(figsize=(12, 6))

    # Start the query thread
    query_t = threading.Thread(target=query_thread, args=(args,))
    query_t.daemon = True
    query_t.start()

    # Set up the animation
    ani = animation.FuncAnimation(fig, update_plot, fargs=(ax, args), interval=1000)

    # Set up a timer to end the simulation if duration is specified
    if args.duration > 0:
        def stop_simulation():
            global running
            time.sleep(args.duration)
            running = False
            plt.close()

        stop_t = threading.Thread(target=stop_simulation)
        stop_t.daemon = True
        stop_t.start()

    # Show the plot (blocks until closed)
    plt.tight_layout()
    try:
        plt.show()
    except KeyboardInterrupt:
        pass
    finally:
        # Clean shutdown
        global running
        running = False
        print("Shutting down simulation...")
        if query_t.is_alive():
            query_t.join(2)
        print("Simulation complete.")

        # Save the final plot as an image
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        plt.savefig(f"latency_trends/latency_trend_{args.pattern}_{timestamp}.png")
        print(f"Saved final plot to latency_trends/latency_trend_{args.pattern}_{timestamp}.png")

if __name__ == "__main__":
    main()
