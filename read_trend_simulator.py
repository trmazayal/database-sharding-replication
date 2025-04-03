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
import psutil
import statistics
import json
import platform
from concurrent.futures import ThreadPoolExecutor
from queue import Queue
import itertools

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
system_metrics = deque()

# For concurrency tracking
active_queries = 0
concurrency_lock = threading.Lock()
concurrency_timestamps = deque()
concurrency_values = deque()

# For throughput tracking - removed maxlen to keep all historical data
query_timestamps = deque()
throughput_timestamps = deque()
throughput_values = deque()
throughput_window = 10  # seconds
query_types_executed = {
    "simple": 0,
    "spatial": 0,
    "complex": 0
}

# Display window size (number of points to show)
display_window_size = 120

table_exists = False
running = True
in_warmup = False
benchmark_results = []
current_run = 0

# System info for reporting
system_info = {
    "platform": platform.platform(),
    "architecture": platform.machine(),
    "processor": platform.processor(),
    "python_version": platform.python_version(),
    "cores": os.cpu_count()
}

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

# Add a flag to track run transitions
run_just_started = False

def collect_system_metrics():
    """Collect CPU, memory and other system metrics"""
    metrics = {
        "cpu_percent": psutil.cpu_percent(interval=1),
        "memory_percent": psutil.virtual_memory().percent,
        "timestamp": datetime.now()
    }
    system_metrics.append(metrics)
    return metrics

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
        FROM generate_series(1, 1000000);
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

def execute_query_concurrent(args, query_type="simple"):
    """Execute a query and track concurrency metrics"""
    global active_queries, concurrency_timestamps, concurrency_values

    # Track active queries count
    with concurrency_lock:
        active_queries += 1
        concurrency_timestamps.append(datetime.now())
        concurrency_values.append(active_queries)

    try:
        query_start = datetime.now()
        latency, error = execute_query(
            args.host, args.port, args.user, args.db,
            args.password, args.container, query_type
        )
        now = datetime.now()

        with concurrency_lock:
            if not in_warmup:
                timestamps.append(now)
                query_timestamps.append(query_start)
                if latency is not None:
                    latencies.append(latency)
                    qps = calculate_throughput()
                    print(f"{now.strftime('%H:%M:%S')} | {query_type:8} | Lat: {latency:.1f} ms | QPS: {qps:.2f} | Active: {active_queries}")
                else:
                    latencies.append(None)
                    errors.append((now, error))
                    print(f"{now.strftime('%H:%M:%S')} | {query_type:8} | ERROR: {error} | Active: {active_queries}")

        return latency, error, query_type
    finally:
        # Always decrement active queries count
        with concurrency_lock:
            active_queries -= 1
            concurrency_timestamps.append(datetime.now())
            concurrency_values.append(active_queries)

def calculate_throughput():
    """Compute current queries/sec over the last `throughput_window` seconds."""
    now = datetime.now()
    window_start = now - timedelta(seconds=throughput_window)
    q_in_window = sum(1 for t in query_timestamps if t > window_start)
    qps = q_in_window / float(throughput_window) if q_in_window else 0
    throughput_timestamps.append(now)
    throughput_values.append(qps)
    return qps

def query_worker(args, task_queue):
    """Worker thread that processes queries from the queue"""
    while running:
        try:
            query_type = task_queue.get(timeout=1.0)
            if query_type == "STOP":
                break

            query_types_executed[query_type] += 1
            execute_query_concurrent(args, query_type)

            # Slow down if needed
            if args.think_time > 0:
                time.sleep(args.think_time)
        except Exception as e:
            if running:  # Only log errors if we're still running
                print(f"Worker error: {e}")
        finally:
            task_queue.task_done()

def query_thread(args):
    """Continuously execute different types of read queries."""
    global running, table_exists, DEFAULT_SCHEMA, query_types_executed, in_warmup, current_run, run_just_started

    # Set random seed if specified
    if args.seed is not None:
        random.seed(args.seed)
        print(f"🔒 Using fixed random seed: {args.seed}")

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

    # Check table
    table_exists = check_table_exists(args.host, args.port, args.user, args.db, args.password, args.container)
    if table_exists:
        update_queries_with_schema(DEFAULT_SCHEMA)
    elif args.create_table:
        table_exists = initialize_table(args.host, args.port, args.user, args.db, args.password, args.container)
        if table_exists:
            update_queries_with_schema(DEFAULT_SCHEMA)

    if not table_exists:
        print("❌ Table not found and cannot be created. Exiting...")
        running = False
        return

    # Multiple benchmark runs support
    total_runs = max(1, args.runs)
    current_run = 1
    run_just_started = True  # Mark the first run as just started

    # Set up concurrency level
    concurrency = max(1, args.concurrency)
    print(f"Starting Advanced Read Load Testing with {concurrency} concurrent clients - Run 1 of {total_runs}")

    # Warmup phase
    if args.warmup > 0:
        print(f"🔥 Warmup phase: {args.warmup} seconds")
        warmup_end = time.time() + args.warmup
        in_warmup = True

        # Create a task queue and worker pool for the warmup
        task_queue = Queue()
        workers = []
        for _ in range(concurrency):
            worker = threading.Thread(
                target=query_worker,
                args=(args, task_queue),
                daemon=True
            )
            worker.start()
            workers.append(worker)

        # Feed tasks during warmup
        while running and time.time() < warmup_end:
            qtype = random.choices(["simple", "spatial", "complex"], weights=[0.6, 0.3, 0.1])[0]
            task_queue.put(qtype)
            time.sleep(args.interval / concurrency)  # Distribute requests across interval

        # Wait for warmup to complete
        for _ in range(concurrency):
            task_queue.put("STOP")
        for worker in workers:
            worker.join(timeout=5)

        # Clear any data collected during warmup
        with concurrency_lock:
            timestamps.clear()
            latencies.clear()
            errors.clear()
            query_timestamps.clear()
            throughput_timestamps.clear()
            throughput_values.clear()
            concurrency_timestamps.clear()
            concurrency_values.clear()
            query_types_executed = {"simple": 0, "spatial": 0, "complex": 0}
        in_warmup = False
        print("✅ Warmup complete, starting measurements")

    # Throughput calc thread
    def throughput_calculator():
        while running:
            calculate_throughput()
            time.sleep(1)

    t_thr = threading.Thread(target=throughput_calculator, daemon=True)
    t_thr.start()

    # System metrics collection thread
    def system_metrics_collector():
        while running:
            if not in_warmup:
                collect_system_metrics()
            time.sleep(5)  # Collect every 5 seconds

    t_sys = threading.Thread(target=system_metrics_collector, daemon=True)
    t_sys.start()

    run_duration = args.duration

    while current_run <= total_runs and running:
        run_start_time = time.time()
        run_end_time = run_start_time + run_duration

        # Reset counters for this run
        if current_run > 1:
            with concurrency_lock:
                timestamps.clear()
                latencies.clear()
                errors.clear()
                query_timestamps.clear()
                throughput_timestamps.clear()
                throughput_values.clear()
                concurrency_timestamps.clear()
                concurrency_values.clear()
                query_types_executed = {"simple": 0, "spatial": 0, "complex": 0}
                run_just_started = True  # Mark that we just started a new run
            print(f"\nStarting Run {current_run} of {total_runs}")

        # After a short delay, clear the run_just_started flag
        def clear_run_started_flag():
            global run_just_started
            time.sleep(5)  # Increased from 2 to 5 seconds to ensure clean transition
            run_just_started = False

        threading.Thread(target=clear_run_started_flag, daemon=True).start()

        # Create a task queue and worker pool for this run
        task_queue = Queue()
        workers = []
        for _ in range(concurrency):
            worker = threading.Thread(
                target=query_worker,
                args=(args, task_queue),
                daemon=True
            )
            worker.start()
            workers.append(worker)

        # Generate and queue tasks based on the workload pattern
        try:
            while running and time.time() < run_end_time:
                # Weight query types to simulate real-world distributions
                qtype = random.choices(["simple", "spatial", "complex"], weights=[0.6, 0.3, 0.1])[0]
                task_queue.put(qtype)

                # Control rate of task generation based on interval and concurrency
                sleep_time = max(0.01, args.interval / max(1, concurrency/2))
                time.sleep(sleep_time)
        except Exception as e:
            print(f"Task generation error: {e}")
        finally:
            # Stop all workers
            for _ in range(concurrency):
                task_queue.put("STOP")

            # Wait for workers to finish
            for worker in workers:
                worker.join(timeout=5)

        # Collect statistics for this run
        valid_latencies = [lat for lat in latencies if lat is not None]
        if valid_latencies:
            run_results = {
                "run": current_run,
                "concurrency": concurrency,
                "avg_latency_ms": statistics.mean(valid_latencies),
                "p50_latency_ms": statistics.median(valid_latencies),
                "p95_latency_ms": np.percentile(valid_latencies, 95),
                "p99_latency_ms": np.percentile(valid_latencies, 99),
                "min_latency_ms": min(valid_latencies),
                "max_latency_ms": max(valid_latencies),
                "stdev_latency_ms": statistics.stdev(valid_latencies) if len(valid_latencies) > 1 else 0,
                "throughput_qps": len(valid_latencies) / run_duration,
                "error_count": len(errors),
                "query_distribution": query_types_executed.copy(),
                "duration": run_duration  # Store the actual run duration
            }
            benchmark_results.append(run_results)

        current_run += 1

def save_image(fig, args, label=""):
    if fig is None or not plt.fignum_exists(fig.number):
        return False
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"latency_trends/latency_trend_{timestamp}{label}.png"
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
    global run_just_started
    ax_lat, ax_thr, ax_conc = axs  # Now unpacking three axes
    ax_lat.clear()
    ax_thr.clear()
    ax_conc.clear()

    # Get all data
    times = list(timestamps)
    lats = list(latencies)
    tp_times = list(throughput_timestamps)
    tp_vals = list(throughput_values)
    conc_times = list(concurrency_timestamps)
    conc_vals = list(concurrency_values)

    # First determine the time window we should display
    if times:
        if len(times) > display_window_size:
            # Use most recent points for time window calculation
            window_times = times[-display_window_size:]
            # Ensure we're using the actual min and max from the window data
            time_min = min(window_times)
            time_max = max(window_times)
        else:
            # Use all points if fewer than display window
            time_min = min(times)
            time_max = max(times)

        # Add a small buffer to ensure we capture all relevant points
        time_buffer = timedelta(seconds=2)
        time_min -= time_buffer
        time_max += time_buffer

        # Filter all datasets based on this consistent time window
        visible_times = []
        visible_lats = []
        for t, l in zip(times, lats):
            if time_min <= t <= time_max:
                visible_times.append(t)
                visible_lats.append(l)

        # Filter throughput data using the same time window
        visible_tp_data = [(t, v) for t, v in zip(tp_times, tp_vals) if time_min <= t <= time_max]

        # Handle empty data case
        if visible_tp_data:
            tp_times, tp_vals = zip(*visible_tp_data)
        else:
            tp_times, tp_vals = [], []

        # Filter concurrency data using the same time window
        visible_conc_data = [(t, v) for t, v in zip(conc_times, conc_vals) if time_min <= t <= time_max]

        # If we have too many concurrency points, downsample while preserving transitions
        MAX_CONC_POINTS = 200  # Increased to have better resolution
        if visible_conc_data and len(visible_conc_data) > MAX_CONC_POINTS:
            # First, always keep the first and last points
            sampled_conc_data = [visible_conc_data[0]]

            # Find transition points (where concurrency value changes)
            transitions = []
            for i in range(1, len(visible_conc_data)):
                if visible_conc_data[i][1] != visible_conc_data[i-1][1]:
                    transitions.append(visible_conc_data[i])

            # Keep all transition points plus evenly spaced points
            if len(transitions) < MAX_CONC_POINTS - 2:
                # If we have fewer transitions than our limit, keep all transitions
                sampled_conc_data.extend(transitions)

                # Add additional points evenly spaced
                remaining_points = MAX_CONC_POINTS - 2 - len(transitions)
                if remaining_points > 0 and len(visible_conc_data) > 2:
                    step = max(1, (len(visible_conc_data) - 2) // (remaining_points + 1))
                    for i in range(1, len(visible_conc_data) - 1, step):
                        if visible_conc_data[i] not in sampled_conc_data:
                            sampled_conc_data.append(visible_conc_data[i])
            else:
                # If we have too many transitions, sample them
                transition_step = max(1, len(transitions) // (MAX_CONC_POINTS - 2))
                for i in range(0, len(transitions), transition_step):
                    sampled_conc_data.append(transitions[i])

            # Add the last point
            if visible_conc_data[-1] not in sampled_conc_data:
                sampled_conc_data.append(visible_conc_data[-1])

            # Sort by time
            sampled_conc_data.sort(key=lambda x: x[0])

            # Replace original data with sampled data
            visible_conc_data = sampled_conc_data

        # Handle empty data case
        if visible_conc_data:
            conc_times, conc_vals = zip(*visible_conc_data)
        else:
            conc_times, conc_vals = [], []
    else:
        visible_times = []
        visible_lats = []

    valid_data = [(t, l) for t, l in zip(visible_times, visible_lats) if l is not None]
    if not valid_data:
        if in_warmup:
            message = "Warmup phase in progress..."
            ax_lat.text(0.5, 0.5, message, ha='center', va='center', transform=ax_lat.transAxes)
            ax_thr.text(0.5, 0.5, message, ha='center', va='center', transform=ax_thr.transAxes)
            ax_conc.text(0.5, 0.5, message, ha='center', va='center', transform=ax_conc.transAxes)
        else:
            message = "No data yet"
            ax_lat.text(0.5, 0.5, message, ha='center', va='center', transform=ax_lat.transAxes)
            ax_thr.text(0.5, 0.5, message, ha='center', va='center', transform=ax_thr.transAxes)
            ax_conc.text(0.5, 0.5, message, ha='center', va='center', transform=ax_conc.transAxes)
        return

    valid_times, valid_lats = zip(*valid_data)

    # Calculate common time limits for x-axis synchronization
    time_limits = [min(valid_times), max(valid_times)]

    # --- Latency plot (top) ---
    # Main latency line
    ax_lat.plot(
        valid_times,
        valid_lats,
        color='blue',
        linestyle='-',
        marker='o',
        linewidth=1.5,
        markersize=3,
        alpha=0.7,
        label='Latency (ms)'
    )

    # Calculate and plot percentile bands if we have enough data
    if len(valid_lats) > 10:
        window_size = min(20, len(valid_lats) // 5)
        if window_size > 0:
            p50_vals = []
            p95_vals = []
            p99_vals = []
            rolling_windows = []

            # Create rolling windows for percentile calculations
            for i in range(len(valid_lats) - window_size + 1):
                rolling_windows.append(valid_lats[i:i+window_size])

            # Calculate percentiles for each window
            for window in rolling_windows:
                p50_vals.append(np.percentile(window, 50))
                p95_vals.append(np.percentile(window, 95))
                p99_vals.append(np.percentile(window, 99))

            # Plot p95 and p99 as semi-transparent bands
            window_times = valid_times[window_size-1:]
            if len(window_times) == len(p95_vals):
                ax_lat.fill_between(
                    window_times, p50_vals, p95_vals,
                    color='blue', alpha=0.2, label='p50-p95'
                )
                ax_lat.fill_between(
                    window_times, p95_vals, p99_vals,
                    color='red', alpha=0.2, label='p95-p99'
                )

    # Average latency line
    avg_latency = np.mean(valid_lats)
    ax_lat.axhline(
        y=avg_latency,
        color='blue',
        linestyle='--',
        linewidth=1.5,
        label=f'Avg: {avg_latency:.1f} ms'
    )

    # Plot p95 and p99 reference lines
    if len(valid_lats) > 1:
        p95 = np.percentile(valid_lats, 95)
        p99 = np.percentile(valid_lats, 99)
        ax_lat.axhline(y=p95, color='orange', linestyle='-.', linewidth=1.2,
                      label=f'p95: {p95:.1f} ms')
        ax_lat.axhline(y=p99, color='red', linestyle='-.', linewidth=1.2,
                      label=f'p99: {p99:.1f} ms')

    # Mark any errors (only those within the current window)
    recent_errors = [(err_t, err) for err_t, err in errors if err_t in valid_times]
    for err_t, _ in recent_errors:
        if err_t in valid_times:
            idx = valid_times.index(err_t)
            ax_lat.plot(err_t, valid_lats[idx], 'rx', markersize=8, label='Error')

    # Title for the entire figure
    run_info = f"Run {current_run}" if args.runs > 1 else ""
    concurrency_info = f"with {args.concurrency} concurrent clients"
    title = f"Advanced Read Load Testing {run_info} {concurrency_info} on {system_info['architecture']}"
    plt.suptitle(title)

    # Latency plot labels and formatting
    ax_lat.set_title("Latency Metrics", fontsize=12)
    ax_lat.set_ylabel("Latency (ms)", color='blue')
    ax_lat.yaxis.set_major_formatter(FuncFormatter(lambda x, _: f"{x:.0f} ms"))
    ax_lat.tick_params(axis='y', labelcolor='blue')
    ax_lat.grid(True, linestyle=':', color='gray', alpha=0.7)
    ax_lat.set_axisbelow(True)
    max_lat = max(valid_lats) if valid_lats else 100
    ax_lat.set_ylim(0, max(max_lat * 1.1, 50))
    ax_lat.set_xlim(time_limits)
    ax_lat.legend(loc='upper right', fontsize=9)

    # Extra info box on latency plot
    throughput = calculate_throughput()
    total_queries = sum(query_types_executed.values())

    # Add query distribution stats
    dist_simple = query_types_executed["simple"] / total_queries * 100 if total_queries else 0
    dist_spatial = query_types_executed["spatial"] / total_queries * 100 if total_queries else 0
    dist_complex = query_types_executed["complex"] / total_queries * 100 if total_queries else 0

    # Calculate detailed latency stats
    if len(valid_lats) > 1:
        min_lat = min(valid_lats)
        max_lat = max(valid_lats)
        median_lat = np.median(valid_lats)
        stdev_lat = np.std(valid_lats)
        cv_lat = (stdev_lat / avg_latency * 100) if avg_latency > 0 else 0
    else:
        min_lat = max_lat = median_lat = stdev_lat = cv_lat = 0

    # Get recent system metrics if available
    sys_info = ""
    if system_metrics:
        latest = system_metrics[-1]
        sys_info = f"CPU: {latest['cpu_percent']:.1f}%, Mem: {latest['memory_percent']:.1f}%\n"

    # Calculate average concurrency
    avg_concurrency = sum(conc_vals) / len(conc_vals) if conc_vals else 0
    max_concurrency = max(conc_vals) if conc_vals else 0

    latency_stats = (
        f"Min: {min_lat:.1f} ms, Max: {max_lat:.1f} ms\n"
        f"Avg: {avg_latency:.1f} ms, Median: {median_lat:.1f} ms\n"
        f"p95: {p95:.1f} ms, p99: {p99:.1f} ms\n"
        f"Stdev: {stdev_lat:.1f} ms, CV: {cv_lat:.1f}%"
    )

    stats_text = (
        f"{sys_info}"
        f"Queries executed: {total_queries}\n"
        f"Concurrency: Avg {avg_concurrency:.1f}, Max {max_concurrency}\n"
        f"Distribution: Simple {dist_simple:.1f}%, Spatial {dist_spatial:.1f}%, Complex {dist_complex:.1f}%\n"
        f"{latency_stats}\n"
        f"Avg Throughput: {throughput:.2f} queries/sec\n"
    )
    ax_lat.text(
        0.02, 0.98, stats_text,
        transform=ax_lat.transAxes,
        fontsize=9,
        va='top',
        bbox=dict(boxstyle='round', facecolor='white', alpha=0.6)
    )

    # --- Throughput plot (middle) ---
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
            label=f'Avg: {avg_thr:.2f} qps'
        )

        # Calculate throughput statistics
        if len(tp_vals) > 1:
            median_thr = np.median(tp_vals)
            min_thr = min(tp_vals)
            max_thr = max(tp_vals)
            stdev_thr = np.std(tp_vals)
            cv_thr = (stdev_thr / avg_thr * 100) if avg_thr > 0 else 0

            # Add throughput stats box
            tput_stats = (
                f"Min: {min_thr:.2f}, Max: {max_thr:.2f} qps\n"
                f"Avg: {avg_thr:.2f}, Median: {median_thr:.2f} qps\n"
                f"Stdev: {stdev_thr:.2f}, CV: {cv_thr:.1f}%"
            )
            ax_thr.text(
                0.02, 0.02, tput_stats,
                transform=ax_thr.transAxes,
                fontsize=9,
                va='bottom',
                bbox=dict(boxstyle='round', facecolor='white', alpha=0.6)
            )

    # Throughput plot labels and formatting
    ax_thr.set_title("Throughput", fontsize=12)
    ax_thr.set_ylabel("Queries/sec", color='green')
    ax_thr.tick_params(axis='y', labelcolor='green')
    ax_thr.yaxis.set_major_formatter(FuncFormatter(lambda x, _: f"{x:.1f}"))
    ax_thr.grid(True, linestyle=':', color='gray', alpha=0.7)
    ax_thr.set_axisbelow(True)
    ax_thr.set_xlim(time_limits)

    if tp_vals:
        max_thr = max(tp_vals) if tp_vals else 1
        ax_thr.set_ylim(0, max(max_thr * 1.1, 1))

    ax_thr.legend(loc='upper right', fontsize=9)

    # --- Concurrency plot (bottom) ---
    if conc_times and conc_vals and not run_just_started:
        ax_conc.plot(
            conc_times,
            conc_vals,
            color='red',
            linestyle='-',
            marker=None,
            linewidth=2,
            drawstyle='steps-post',  # Shows exact transitions in concurrency
            alpha=0.7,
            label='Active Queries'
        )

        # Add filled region under the concurrency line
        ax_conc.fill_between(
            conc_times,
            0,
            conc_vals,
            color='red',
            alpha=0.1,
            step='post'  # Fill should match the step drawing style
        )

        # Draw horizontal line at average concurrency
        if avg_concurrency > 0:
            ax_conc.axhline(
                y=avg_concurrency,
                color='red',
                linestyle='--',
                linewidth=1.5,
                label=f'Avg: {avg_concurrency:.1f}'
            )

    # Concurrency plot labels and formatting
    ax_conc.set_title("Active Concurrent Queries", fontsize=12)
    ax_conc.set_xlabel("Time")
    ax_conc.set_ylabel("Active Queries", color='red', fontweight='bold')
    ax_conc.tick_params(axis='y', labelcolor='red')
    ax_conc.grid(True, linestyle=':', color='gray', alpha=0.7)
    ax_conc.set_axisbelow(True)

    # Set y-axis limits for concurrency with a bit of headroom
    max_conc = max(conc_vals) if conc_vals else args.concurrency
    ax_conc.set_ylim(0, max(max_conc * 1.2, args.concurrency * 1.2, 2))
    ax_conc.set_xlim(time_limits)

    ax_conc.legend(loc='upper right', fontsize=9)

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

def save_benchmark_results(args):
    """Save benchmark results to JSON file"""
    if not benchmark_results:
        return

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"latency_trends/benchmark_results_{timestamp}.json"

    # Add system information to results
    result_data = {
        "system_info": system_info,
        "benchmark_config": vars(args),
        "run_results": benchmark_results,
        "summary_metrics": calculate_summary_metrics() if len(benchmark_results) > 1 else {}
    }

    try:
        with open(filename, 'w') as f:
            json.dump(result_data, f, indent=2, default=str)
        print(f"✅ Saved benchmark results to {filename}")
        return filename
    except Exception as e:
        print(f"❌ Error saving benchmark results: {e}")
        return None

def calculate_summary_metrics():
    """Calculate summary metrics across all benchmark runs"""
    # Extract metrics from all runs
    all_latencies = [run["avg_latency_ms"] for run in benchmark_results]
    all_throughputs = [run["throughput_qps"] for run in benchmark_results]
    all_p95_latencies = [run["p95_latency_ms"] for run in benchmark_results]

    # Calculate throughput stability metrics
    throughput_cv = statistics.stdev(all_throughputs) / statistics.mean(all_throughputs) * 100 if len(all_throughputs) > 1 else 0

    # Calculate per-query type throughput if available
    query_type_counts = {}
    for run in benchmark_results:
        for qtype, count in run["query_distribution"].items():
            query_type_counts.setdefault(qtype, []).append(count / run.get("duration", 300))

    query_type_throughputs = {}
    for qtype, counts in query_type_counts.items():
        query_type_throughputs[qtype] = {
            "mean": statistics.mean(counts),
            "stdev": statistics.stdev(counts) if len(counts) > 1 else 0
        }

    return {
        "throughput_summary": {
            "mean": statistics.mean(all_throughputs),
            "median": statistics.median(all_throughputs),
            "min": min(all_throughputs),
            "max": max(all_throughputs),
            "stdev": statistics.stdev(all_throughputs) if len(all_throughputs) > 1 else 0,
            "cv_percent": throughput_cv  # Coefficient of variation as percentage
        },
        "latency_summary": {
            "mean": statistics.mean(all_latencies),
            "median": statistics.median(all_latencies),
            "min": min(all_latencies),
            "max": max(all_latencies),
            "stdev": statistics.stdev(all_latencies) if len(all_latencies) > 1 else 0
        },
        "p95_latency_summary": {
            "mean": statistics.mean(all_p95_latencies),
            "median": statistics.median(all_p95_latencies),
            "min": min(all_p95_latencies),
            "max": max(all_p95_latencies),
            "stdev": statistics.stdev(all_p95_latencies) if len(all_p95_latencies) > 1 else 0
        },
        "per_query_type_throughput": query_type_throughputs
    }

def print_detailed_summary():
    """Print detailed summary statistics including throughput metrics"""
    if len(benchmark_results) <= 1:
        return

    summary_metrics = calculate_summary_metrics()
    tput_summary = summary_metrics["throughput_summary"]
    lat_summary = summary_metrics["latency_summary"]
    p95_summary = summary_metrics["p95_latency_summary"]
    query_tputs = summary_metrics["per_query_type_throughput"]

    print("\n===== DETAILED BENCHMARK SUMMARY =====")
    print(f"System: {system_info['platform']} ({system_info['architecture']})")
    print(f"Concurrency: {benchmark_results[0]['concurrency']} clients")
    print(f"Total runs: {len(benchmark_results)}")

    print("\n--- Throughput Statistics (queries/sec) ---")
    print(f"Average throughput:      {tput_summary['mean']:.2f} qps (±{tput_summary['stdev']:.2f})")
    print(f"Median throughput:       {tput_summary['median']:.2f} qps")
    print(f"Min/Max throughput:      {tput_summary['min']:.2f} / {tput_summary['max']:.2f} qps")
    print(f"Throughput stability:    {tput_summary['cv_percent']:.1f}% CV (lower is more stable)")

    print("\n--- Latency Statistics (milliseconds) ---")
    print(f"Average latency:         {lat_summary['mean']:.2f} ms (±{lat_summary['stdev']:.2f})")
    print(f"95th percentile:         {p95_summary['mean']:.2f} ms (±{p95_summary['stdev']:.2f})")
    print(f"Min/Max latency:         {lat_summary['min']:.2f} / {lat_summary['max']:.2f} ms")

    print("\n--- Per-Query Type Throughput ---")
    for qtype, stats in query_tputs.items():
        print(f"{qtype.capitalize():8} queries: {stats['mean']:.2f} qps (±{stats['stdev']:.2f})")

    # Generate a simple ASCII chart of throughput across runs
    print("\n--- Throughput Across Runs ---")
    max_width = 40  # Maximum width of the ASCII chart
    max_tput = max(run["throughput_qps"] for run in benchmark_results)

    for i, run in enumerate(benchmark_results):
        tput = run["throughput_qps"]
        bar_width = int((tput / max_tput) * max_width)
        bar = "█" * bar_width
        print(f"Run {i+1:2d}: {tput:6.2f} qps |{bar}")

def main():
    parser = argparse.ArgumentParser(description='Advanced Read Load Testing for PostgreSQL/Citus DB.')
    parser.add_argument('--host', default=DEFAULT_HOST)
    parser.add_argument('--port', default=DEFAULT_PORT)
    parser.add_argument('--user', default=DEFAULT_USER)
    parser.add_argument('--db', default=DEFAULT_DB)
    parser.add_argument('--password', default=DEFAULT_PASSWORD)
    parser.add_argument('--container', default=DEFAULT_CONTAINER)
    parser.add_argument('--interval', type=float, default=1.0)
    parser.add_argument('--duration', type=int, default=300)
    parser.add_argument('--create-table', action='store_true')
    parser.add_argument('--throughput-window', type=int, default=10)
    parser.add_argument('--save-interval', type=int, default=0,
                        help='Periodic plot save in minutes (0=off)')
    parser.add_argument('--no-final-save', action='store_true')
    parser.add_argument('--display-window', type=int, default=120,
                        help='Number of data points to display in the sliding window')
    parser.add_argument('--warmup', type=int, default=0,
                        help='Warmup period in seconds before collecting measurements')
    parser.add_argument('--runs', type=int, default=1,
                        help='Number of benchmark runs to perform')
    parser.add_argument('--seed', type=int, default=None,
                        help='Fixed random seed for reproducible workloads')
    parser.add_argument('--nice', type=int, default=0,
                        help='Process nice value for better isolation (0-19, higher=lower priority)')
    parser.add_argument('--headless', action='store_true',
                        help='Run without displaying graphs (results saved to file)')
    parser.add_argument('--concurrency', type=int, default=1,
                        help='Number of concurrent query clients')
    parser.add_argument('--think-time', type=float, default=0,
                        help='Think time between queries per client (seconds)')
    parser.add_argument('--mode', choices=['constant', 'ramp', 'step'], default='constant',
                        help='Concurrency mode: constant, ramp, or step')
    args = parser.parse_args()

    global throughput_window, display_window_size
    throughput_window = args.throughput_window
    display_window_size = args.display_window

    # Set process priority if requested
    if args.nice > 0:
        try:
            os.nice(min(19, args.nice))
            print(f"✅ Process priority set to nice {args.nice}")
        except Exception as e:
            print(f"⚠️ Couldn't set process priority: {e}")

    plt.rcParams.update({
        'font.size': 12,
        'axes.titlesize': 14,
        'axes.labelsize': 12,
        'xtick.labelsize': 10,
        'ytick.labelsize': 10
    })

    os.makedirs("latency_trends", exist_ok=True)

    # Create figure with three subplots (vertical stack)
    if not args.headless:
        fig, axs = plt.subplots(3, 1, figsize=(12, 12), sharex=True)
        fig.subplots_adjust(left=0.1, right=0.95, top=0.92, bottom=0.08, hspace=0.3)
        fig.canvas.mpl_connect('key_press_event', lambda e: on_key_press(e, fig, args))
    else:
        fig, axs = None, None

    qt = threading.Thread(target=query_thread, args=(args,))
    qt.daemon = True
    qt.start()

    if not args.headless and fig is not None:
        save_t = threading.Thread(target=periodic_save_thread, args=(fig, args))
        save_t.daemon = True
        save_t.start()

    def signal_handler(sig, frame):
        global running
        print("\n🛑 Interrupt received, stopping...")
        running = False
        if not args.headless and fig is not None and not args.no_final_save:
            save_image(fig, args, "_final")
        save_benchmark_results(args)
        if not args.headless:
            plt.close('all')

    signal.signal(signal.SIGINT, signal_handler)

    if not args.headless:
        ani = animation.FuncAnimation(fig, update_plot, fargs=(axs, args), interval=1000)

    try:
        if args.headless:
            # In headless mode, just wait for the query thread to finish
            qt.join()
        else:
            plt.show()
    except KeyboardInterrupt:
        pass
    finally:
        global running
        running = False
        if qt.is_alive():
            qt.join(2)

        if not args.headless and fig is not None and not args.no_final_save:
            save_image(fig, args, "_final")

        results_file = save_benchmark_results(args)

        # Print detailed summary if multiple runs were performed
        if len(benchmark_results) > 1:
            print_detailed_summary()

        print("Done.")

if __name__ == "__main__":
    main()