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
import signal

# Configuration
DEFAULT_HOST = "localhost"
DEFAULT_PORT = "5432"
DEFAULT_USER = "citus"
DEFAULT_DB = "citus"
DEFAULT_PASSWORD = "citus"
DEFAULT_CONTAINER = "citus_loadbalancer"
DEFAULT_SCHEMA = "public"

# Global data storage - removed maxlen to keep all historical data
timestamps = deque()
latencies = deque()
errors = deque()

# For throughput tracking - removed maxlen to keep all historical data
query_timestamps = deque()
throughput_timestamps = deque()
throughput_values = deque()
throughput_window = 10  # seconds

# Display window size (number of points to show)
display_window_size = 120

# Simulation parameters
current_load_factor = 1.0
load_pattern = "steady"
trend_counter = 0
spike_probability = 0.05
spike_magnitude = 3.0

table_exists = False
running = True

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

def check_table_exists(host, port, user, db, password, container):
    cmd = [
        "docker", "exec", "-i",
        "-e", f"PGPASSWORD={password}",
        container,
        "psql", "-h", host, "-p", port, "-U", user, "-d", db,
        "-t", "-c",
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'vehicle_locations');"
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        if result.returncode == 0 and 't' in result.stdout.strip().lower():
            print("✅ vehicle_locations table exists")
            global DEFAULT_SCHEMA
            DEFAULT_SCHEMA = 'citus'
            return True
        else:
            print("❌ vehicle_locations table not found")
            return False
    except Exception as e:
        print(f"Error checking table: {e}")
        return False

def initialize_table(host, port, user, db, password, container):
    """Create vehicle_locations if it doesn't exist."""
    print("🔧 Attempting to create vehicle_locations...")
    ext_cmd = [
        "docker", "exec", "-i",
        "-e", f"PGPASSWORD={password}",
        container,
        "psql", "-h", host, "-p", port, "-U", user, "-d", db,
        "-c", "CREATE EXTENSION IF NOT EXISTS postgis CASCADE;"
    ]
    table_cmd = [
        "docker", "exec", "-i",
        "-e", f"PGPASSWORD={password}",
        container,
        "psql", "-h", host, "-p", port, "-U", user, "-d", db,
        "-c", """
        BEGIN;
        CREATE TABLE IF NOT EXISTS citus.vehicle_locations (
          id bigserial,
          vehicle_id int NOT NULL,
          location geometry(Point, 4326) NOT NULL,
          recorded_at timestamptz NOT NULL,
          region_code text NOT NULL
        );
        COMMIT;
        """
    ]
    verify_cmd = [
        "docker", "exec", "-i",
        "-e", f"PGPASSWORD={password}",
        container,
        "psql", "-h", host, "-p", port, "-U", user, "-d", db,
        "-t", "-c",
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'vehicle_locations');"
    ]
    data_cmd = [
        "docker", "exec", "-i",
        "-e", f"PGPASSWORD={password}",
        container,
        "psql", "-h", host, "-p", port, "-U", user, "-d", db,
        "-c", """
        BEGIN;
        INSERT INTO vehicle_locations (vehicle_id, location, recorded_at, region_code)
        SELECT
            (floor(random() * 10000) + 1)::int,
            ST_SetSRID(
                ST_MakePoint(-74.0 + random() * 0.5, 40.7 + random() * 0.5),
                4326
            ) AS location,
            NOW() - (random() * interval '30 days') AS recorded_at,
            CASE
                WHEN random() < 0.33 THEN 'region_north'
                WHEN random() < 0.66 THEN 'region_south'
                ELSE 'region_central'
            END
        FROM generate_series(1, 1000);
        COMMIT;
        """
    ]
    global table_exists
    try:
        subprocess.run(ext_cmd, capture_output=True, text=True, timeout=10)
        result = subprocess.run(table_cmd, capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            print(f"❌ Failed to create table: {result.stderr.strip()}")
            return False
        time.sleep(2)

        verify_result = subprocess.run(verify_cmd, capture_output=True, text=True, timeout=5)
        if verify_result.returncode != 0 or 't' not in verify_result.stdout.strip().lower():
            print("❌ Table verification failed")
            return False

        # Insert sample data
        data_result = subprocess.run(data_cmd, capture_output=True, text=True, timeout=30)
        if data_result.returncode == 0:
            print("✅ Created table + inserted sample data")
            table_exists = True
            global DEFAULT_SCHEMA
            DEFAULT_SCHEMA = 'citus'
        else:
            print(f"⚠️ Insert data failed: {data_result.stderr.strip()}")
            table_exists = True

        return table_exists
    except Exception as e:
        print(f"❌ Error initializing table: {e}")
        return False

def execute_query(host, port, user, db, password, container, query_type="simple"):
    """Run a query in Docker container; return (latency_ms, error)."""
    query = QUERIES.get(query_type, QUERIES["simple"])
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
            return None, result.stderr
        return (end_time - start_time) * 1000, None
    except subprocess.TimeoutExpired:
        return None, "Query timeout"
    except Exception as e:
        return None, str(e)

def apply_load_pattern(base_latency):
    """Apply chosen pattern (cyclic, steady, etc.), add random noise/spikes."""
    global current_load_factor, trend_counter

    # ~±10% random noise
    noise = random.uniform(0.9, 1.1)
    adjusted_latency = base_latency * current_load_factor * noise

    # Occasional spike
    if random.random() < spike_probability:
        print("⚠️ Simulating latency spike!")
        adjusted_latency *= spike_magnitude

    if load_pattern == "cyclic":
        current_load_factor = 1.0 + 0.5 * np.sin(trend_counter / 10.0)
        trend_counter += 1
    elif load_pattern == "increasing":
        current_load_factor += 0.01
        current_load_factor = min(current_load_factor, 3.0)
    elif load_pattern == "decreasing":
        current_load_factor -= 0.01
        current_load_factor = max(current_load_factor, 0.5)
    elif load_pattern == "step":
        if trend_counter % 30 == 0:
            current_load_factor = 2.0 if current_load_factor == 1.0 else 1.0
        trend_counter += 1

    return adjusted_latency

def calculate_throughput():
    """Compute current queries/sec over the last `throughput_window` seconds."""
    now = datetime.now()
    window_start = now - timedelta(seconds=throughput_window)
    q_in_window = sum(1 for t in query_timestamps if t > window_start)
    qps = q_in_window / float(throughput_window) if q_in_window else 0
    throughput_timestamps.append(now)
    throughput_values.append(qps)
    return qps

def query_thread(args):
    """Continuously query (real or simulated)."""
    global running, table_exists, DEFAULT_SCHEMA

    # Update queries to correct schema
    def update_queries_with_schema(schema):
        QUERIES["simple"] = f"SELECT COUNT(*) FROM {schema}.vehicle_locations;"
        QUERIES["spatial"] = f"""
            SELECT COUNT(*) FROM {schema}.vehicle_locations
            WHERE ST_DWithin(
                location::geography,
                ST_SetSRID(ST_MakePoint(-73.9857, 40.7484), 4326)::geography,
                5000
            );
        """
        QUERIES["complex"] = f"""
            SELECT region_code, COUNT(*), AVG(ST_X(location)), AVG(ST_Y(location))
            FROM {schema}.vehicle_locations
            GROUP BY region_code
            ORDER BY region_code;
        """

    # Check table if not simulating
    if not args.simulate:
        table_exists = check_table_exists(args.host, args.port, args.user, args.db, args.password, args.container)
        if table_exists:
            update_queries_with_schema(DEFAULT_SCHEMA)
        elif args.create_table:
            table_exists = initialize_table(args.host, args.port, args.user, args.db, args.password, args.container)
            if table_exists:
                update_queries_with_schema(DEFAULT_SCHEMA)
        if not table_exists:
            print("🔄 Table not found; switching to simulation mode.")
            args.simulate = True

    print(f"Load pattern: {args.pattern}, Mode: {'simulate' if args.simulate else 'real DB'}")

    # Throughput calc thread
    def throughput_calculator():
        while running:
            calculate_throughput()
            time.sleep(1)

    t_thr = threading.Thread(target=throughput_calculator, daemon=True)
    t_thr.start()

    while running:
        try:
            qtype = random.choices(["simple", "spatial", "complex"], weights=[0.6,0.3,0.1])[0]
            query_start = datetime.now()
            query_timestamps.append(query_start)

            if args.simulate:
                # random base + pattern
                base_latency = random.uniform(30, 60)  # ms
                latency = apply_load_pattern(base_latency)
                error = None
            else:
                latency, error = execute_query(
                    args.host, args.port, args.user, args.db,
                    args.password, args.container, qtype
                )
            now = datetime.now()
            timestamps.append(now)

            if latency is not None:
                latencies.append(latency)
                qps = calculate_throughput()
                print(f"{now.strftime('%H:%M:%S')} | {qtype:8} | Lat: {latency:.1f} ms | "
                      f"Load: {current_load_factor:.2f} | QPS: {qps:.2f}")
            else:
                latencies.append(None)
                errors.append((now, error))
                print(f"{now.strftime('%H:%M:%S')} | {qtype:8} | ERROR: {error}")

            time.sleep(args.interval)
        except Exception as e:
            print(f"Query thread error: {e}")
            time.sleep(args.interval)

def save_image(fig, args, label=""):
    if fig is None or not plt.fignum_exists(fig.number):
        return False
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"latency_trends/latency_trend_{args.pattern}_{timestamp}{label}.png"
    try:
        fig.savefig(filename, dpi=100)
        print(f"✅ Saved plot to {filename}")
        return True
    except Exception as e:
        print(f"❌ Error saving image: {e}")
        return False

def update_plot(i, axs, args):
    """
    Animation callback: redraw lines for latency and throughput
    """
    ax_lat, ax_thr = axs
    ax_lat.clear()
    ax_thr.clear()

    # Get all data
    times = list(timestamps)
    lats = list(latencies)
    tp_times = list(throughput_timestamps)
    tp_vals = list(throughput_values)

    # Apply sliding window - only show the most recent display_window_size points
    if len(times) > display_window_size:
        times = times[-display_window_size:]
        lats = lats[-display_window_size:]

    # Instead of trimming throughput data by count, filter it by time range
    # This ensures we show all throughput data for the visible time period
    if times:  # Only filter if we have latency data points
        min_time = min(times) if times else None
        max_time = max(times) if times else None

        if min_time and max_time:
            # Keep all throughput data points that are in the visible time range
            visible_tp_data = [(t, v) for t, v in zip(tp_times, tp_vals) if min_time <= t <= max_time]

            if visible_tp_data:
                tp_times, tp_vals = zip(*visible_tp_data)
            else:
                tp_times, tp_vals = [], []

    valid_data = [(t, l) for t, l in zip(times, lats) if l is not None]
    if not valid_data:
        ax_lat.text(0.5, 0.5, "No data yet", ha='center', va='center', transform=ax_lat.transAxes)
        return

    valid_times, valid_lats = zip(*valid_data)

    # --- Latency plot (top) ---
    ax_lat.plot(
        valid_times,
        valid_lats,
        color='blue',
        linestyle='-',
        marker='o',
        linewidth=1.5,
        label='Latency (ms)'
    )
    avg_latency = np.mean(valid_lats)
    ax_lat.axhline(
        y=avg_latency,
        color='blue',
        linestyle='--',
        linewidth=1.5,
        label='Avg Latency'
    )

    # Mark any errors (only those within the current window)
    recent_errors = [(err_t, err) for err_t, err in errors if err_t in valid_times]
    for err_t, _ in recent_errors:
        if err_t in valid_times:
            idx = valid_times.index(err_t)
            ax_lat.plot(err_t, valid_lats[idx], 'rx', markersize=8, label='Error')

    # Title for the entire figure
    title = f"Real-time Performance - {args.pattern.capitalize()} Pattern"
    if args.simulate:
        title += " (SIMULATION)"
    plt.suptitle(title)

    # Latency plot labels and formatting
    ax_lat.set_ylabel("Latency (ms)", color='blue')
    ax_lat.yaxis.set_major_formatter(FuncFormatter(lambda x, _: f"{x:.0f} ms"))
    ax_lat.tick_params(axis='y', labelcolor='blue')
    ax_lat.grid(True, linestyle=':', color='gray', alpha=0.7)
    ax_lat.set_axisbelow(True)
    max_lat = max(valid_lats) if valid_lats else 100
    ax_lat.set_ylim(0, max(max_lat * 1.1, 50))
    ax_lat.legend(loc='upper right')

    # Extra info box on latency plot
    throughput = calculate_throughput()
    stats_text = (
        f"Load Factor: {current_load_factor:.2f}x\n"
        f"Avg Latency: {avg_latency:.2f} ms\n"
        f"Avg Throughput: {throughput:.2f} queries/sec\n"
    )
    ax_lat.text(
        0.02, 0.95, stats_text,
        transform=ax_lat.transAxes,
        fontsize=10,
        va='top',
        bbox=dict(boxstyle='round', facecolor='white', alpha=0.6)
    )

    # --- Throughput plot (bottom) ---
    if tp_times and tp_vals:
        ax_thr.plot(
            tp_times,
            tp_vals,
            color='green',
            linestyle='-',
            marker='s',
            linewidth=1.5,
            markersize=4,
            label='Queries/sec'
        )
        avg_thr = np.mean(tp_vals)
        ax_thr.axhline(
            y=avg_thr,
            color='green',
            linestyle='--',
            linewidth=1.5,
            label='Avg Throughput'
        )

    # Throughput plot labels and formatting
    ax_thr.set_xlabel("Time")
    ax_thr.set_ylabel("Queries/sec", color='green')
    ax_thr.tick_params(axis='y', labelcolor='green')
    ax_thr.yaxis.set_major_formatter(FuncFormatter(lambda x, _: f"{x:.1f}"))
    ax_thr.grid(True, linestyle=':', color='gray', alpha=0.7)
    ax_thr.set_axisbelow(True)

    if tp_vals:
        max_thr = max(tp_vals) if tp_vals else 1
        ax_thr.set_ylim(0, max(max_thr * 1.1, 1))

    ax_thr.legend(loc='upper right')

    # Format x-axis labels (time)
    plt.xticks(rotation=45)

def on_key_press(event, fig, args):
    if event.key == 's':
        save_image(fig, args, "_manual")

def periodic_save_thread(fig, args):
    """Periodically save the figure every N minutes."""
    interval_s = args.save_interval * 60
    if interval_s <= 0:
        return
    last_save = time.time()
    while running:
        if time.time() - last_save >= interval_s:
            save_image(fig, args, "_periodic")
            last_save = time.time()
        time.sleep(5)

def main():
    parser = argparse.ArgumentParser(description='Simulate & plot DB query latency & throughput.')
    parser.add_argument('--host', default=DEFAULT_HOST)
    parser.add_argument('--port', default=DEFAULT_PORT)
    parser.add_argument('--user', default=DEFAULT_USER)
    parser.add_argument('--db', default=DEFAULT_DB)
    parser.add_argument('--password', default=DEFAULT_PASSWORD)
    parser.add_argument('--container', default=DEFAULT_CONTAINER)
    parser.add_argument('--interval', type=float, default=1.0)
    parser.add_argument('--duration', type=int, default=300)
    parser.add_argument('--pattern', choices=['steady','cyclic','increasing','decreasing','step'],
                        default='steady')
    parser.add_argument('--spike-prob', type=float, default=0.05)
    parser.add_argument('--simulate', action='store_true')
    parser.add_argument('--create-table', action='store_true')
    parser.add_argument('--throughput-window', type=int, default=10)
    parser.add_argument('--save-interval', type=int, default=0,
                        help='Periodic plot save in minutes (0=off)')
    parser.add_argument('--no-final-save', action='store_true')
    parser.add_argument('--display-window', type=int, default=120,
                        help='Number of data points to display in the sliding window')
    args = parser.parse_args()

    global load_pattern, spike_probability, throughput_window, display_window_size
    load_pattern = args.pattern
    spike_probability = args.spike_prob
    throughput_window = args.throughput_window
    display_window_size = args.display_window

    plt.rcParams.update({
        'font.size': 12,
        'axes.titlesize': 14,
        'axes.labelsize': 12,
        'xtick.labelsize': 10,
        'ytick.labelsize': 10
    })

    os.makedirs("latency_trends", exist_ok=True)

    # Create figure with two subplots (vertical stack)
    fig, axs = plt.subplots(2, 1, figsize=(12, 9), sharex=True)

    # Adjust subplot positions for better spacing
    fig.subplots_adjust(left=0.1, right=0.95, top=0.92, bottom=0.1, hspace=0.3)

    fig.canvas.mpl_connect('key_press_event', lambda e: on_key_press(e, fig, args))

    qt = threading.Thread(target=query_thread, args=(args,))
    qt.daemon = True
    qt.start()

    save_t = threading.Thread(target=periodic_save_thread, args=(fig, args))
    save_t.daemon = True
    save_t.start()

    ani = animation.FuncAnimation(fig, update_plot, fargs=(axs, args), interval=1000)

    def signal_handler(sig, frame):
        global running
        print("\n🛑 Interrupt received, stopping...")
        running = False
        if not args.no_final_save:
            save_image(fig, args, "_final")
        plt.close('all')

    signal.signal(signal.SIGINT, signal_handler)

    if args.duration > 0:
        def stop_sim():
            global running
            time.sleep(args.duration)
            running = False
            plt.close()
        tstop = threading.Thread(target=stop_sim, daemon=True)
        tstop.start()

    try:
        plt.show()
    except KeyboardInterrupt:
        pass
    finally:
        global running
        running = False
        if qt.is_alive():
            qt.join(2)

        if not args.no_final_save:
            save_image(fig, args, "_final")

        print("Done.")

if __name__ == "__main__":
    main()