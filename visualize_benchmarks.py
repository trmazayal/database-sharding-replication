#!/usr/bin/env python3
import matplotlib.pyplot as plt
import pandas as pd
import os
import numpy as np
from datetime import datetime
import seaborn as sns

# Set style for plots
plt.style.use('ggplot')
RESULTS_DIR = "benchmark_results"
OUTPUT_DIR = f"{RESULTS_DIR}/graphs"

# Create output directory if it doesn't exist
os.makedirs(OUTPUT_DIR, exist_ok=True)

def time_to_seconds(time_str):
    """Convert time string (e.g. '0m1.234s') to seconds"""
    if not time_str or pd.isna(time_str):
        return np.nan

    try:
        if 'm' in time_str:
            parts = time_str.replace('s', '').split('m')
            return float(parts[0]) * 60 + float(parts[1])
        else:
            return float(time_str.replace('s', ''))
    except:
        return np.nan

def plot_single_query_results():
    """Plot results from single query benchmarks"""
    csv_path = f"{RESULTS_DIR}/single_query_results.csv"
    if not os.path.exists(csv_path):
        print(f"File not found: {csv_path}")
        return False

    try:
        print(f"Visualizing single query results from {csv_path}")
        df = pd.read_csv(csv_path)

        if df.empty or 'query_name' not in df.columns or 'execution_time' not in df.columns:
            print(f"Warning: CSV format not as expected in {csv_path}")
            return False

        # Group by query_name and calculate statistics
        query_stats = df.groupby('query_name')['execution_time'].agg(['mean', 'std', 'min', 'max'])

        # Plot average execution time for each query
        plt.figure(figsize=(12, 6))
        ax = query_stats['mean'].plot(kind='bar', yerr=query_stats['std'], capsize=5)
        plt.title('Average Query Execution Time', fontsize=15)
        plt.ylabel('Execution Time (seconds)', fontsize=12)
        plt.xlabel('Query', fontsize=12)
        plt.xticks(rotation=45, ha='right')
        plt.tight_layout()

        # Add value labels on top of bars
        for i, v in enumerate(query_stats['mean']):
            ax.text(i, v + 0.1, f"{v:.3f}s", ha='center', fontweight='bold')

        plt.savefig(f"{OUTPUT_DIR}/single_query_performance.png", dpi=150)
        print(f"Saved to {OUTPUT_DIR}/single_query_performance.png")

        # Plot execution time for each iteration of each query
        plt.figure(figsize=(12, 6))
        for query in df['query_name'].unique():
            query_df = df[df['query_name'] == query]
            plt.plot(query_df['iteration'], query_df['execution_time'], marker='o', label=query)

        plt.title('Query Execution Time by Iteration', fontsize=15)
        plt.ylabel('Execution Time (seconds)', fontsize=12)
        plt.xlabel('Iteration', fontsize=12)
        plt.legend(loc='upper left', bbox_to_anchor=(1, 1))
        plt.tight_layout()
        plt.savefig(f"{OUTPUT_DIR}/query_performance_by_iteration.png", dpi=150)
        print(f"Saved to {OUTPUT_DIR}/query_performance_by_iteration.png")
        return True
    except Exception as e:
        print(f"Error plotting single query results: {e}")
        return False

def plot_concurrent_results():
    """Plot results from concurrent benchmark tests"""
    csv_path = f"{RESULTS_DIR}/concurrent_results.csv"
    if not os.path.exists(csv_path):
        print(f"File not found: {csv_path}")
        return False

    try:
        print(f"Visualizing concurrent benchmark results from {csv_path}")
        df = pd.read_csv(csv_path)

        if df.empty or 'test_name' not in df.columns or 'clients' not in df.columns:
            print(f"Warning: CSV format not as expected in {csv_path}")
            return False

        # Ensure tps and latency_ms are numeric
        for col in ['tps', 'latency_ms']:
            if col in df.columns:
                df[col] = pd.to_numeric(df[col], errors='coerce')

        # Plot TPS by number of clients for each test
        plt.figure(figsize=(12, 6))
        for test in df['test_name'].unique():
            test_df = df[df['test_name'] == test].sort_values('clients')
            if 'tps' in test_df.columns:
                plt.plot(test_df['clients'], test_df['tps'], marker='o', linewidth=2, label=test)

        plt.title('Transactions Per Second (TPS) by Client Count', fontsize=15)
        plt.ylabel('TPS', fontsize=12)
        plt.xlabel('Number of Clients', fontsize=12)
        plt.grid(True)
        plt.legend()
        plt.tight_layout()
        plt.savefig(f"{OUTPUT_DIR}/concurrent_tps.png", dpi=150)
        print(f"Saved to {OUTPUT_DIR}/concurrent_tps.png")

        # Plot Latency by number of clients
        plt.figure(figsize=(12, 6))
        for test in df['test_name'].unique():
            test_df = df[df['test_name'] == test].sort_values('clients')
            if 'latency_ms' in test_df.columns:
                plt.plot(test_df['clients'], test_df['latency_ms'], marker='o', linewidth=2, label=test)

        plt.title('Average Latency by Client Count', fontsize=15)
        plt.ylabel('Latency (ms)', fontsize=12)
        plt.xlabel('Number of Clients', fontsize=12)
        plt.grid(True)
        plt.legend()
        plt.tight_layout()
        plt.savefig(f"{OUTPUT_DIR}/concurrent_latency.png", dpi=150)
        print(f"Saved to {OUTPUT_DIR}/concurrent_latency.png")
        return True
    except Exception as e:
        print(f"Error plotting concurrent results: {e}")
        return False

def plot_worker_results():
    """Plot comparison between worker nodes"""
    csv_path = f"{RESULTS_DIR}/worker_benchmark_results.csv"
    if not os.path.exists(csv_path):
        print(f"File not found: {csv_path}")
        return False

    try:
        print(f"Visualizing worker benchmark results from {csv_path}")
        df = pd.read_csv(csv_path)

        if df.empty or 'node' not in df.columns:
            print(f"Warning: CSV format not as expected in {csv_path}")
            return False

        # Check if real_time column exists or we need to create it
        if 'real_time' in df.columns:
            # Convert time strings to seconds
            df['real_seconds'] = df['real_time'].apply(time_to_seconds)
        elif 'real_seconds' not in df.columns:
            print(f"Warning: No timing information found in {csv_path}")
            return False

        # Make sure query column exists
        query_col = 'query'
        if query_col not in df.columns:
            # Try to find an alternative column
            possible_query_cols = ['operation', 'test', 'benchmark']
            for col in possible_query_cols:
                if col in df.columns:
                    query_col = col
                    break
            else:
                print(f"Warning: Could not find query/operation column in {csv_path}")
                return False

        # Plot real execution time by node for each query
        queries = df[query_col].unique()
        nodes = df['node'].unique()

        x = np.arange(len(queries))  # the label locations
        width = 0.8 / len(nodes)  # the width of the bars
        multiplier = 0

        fig, ax = plt.subplots(figsize=(15, 8))

        for node in nodes:
            offset = width * (multiplier - len(nodes)/2 + 0.5)
            node_data = []

            for query in queries:
                query_data = df[(df[query_col] == query) & (df['node'] == node)]
                if not query_data.empty and 'real_seconds' in query_data.columns:
                    node_data.append(query_data['real_seconds'].values[0])
                else:
                    node_data.append(0)

            rects = ax.bar(x + offset, node_data, width, label=node)
            ax.bar_label(rects, padding=3, fmt='%.2f')
            multiplier += 1

        ax.set_title('Query Execution Time by Node', fontsize=15)
        ax.set_ylabel('Execution Time (seconds)', fontsize=12)
        ax.set_xticks(x)
        ax.set_xticklabels(queries, rotation=45, ha='right')
        ax.legend(loc='upper left', bbox_to_anchor=(1, 1))
        plt.tight_layout()

        plt.savefig(f"{OUTPUT_DIR}/worker_comparison.png", dpi=150)
        print(f"Saved to {OUTPUT_DIR}/worker_comparison.png")
        return True
    except Exception as e:
        print(f"Error plotting worker results: {e}")
        return False

def plot_ha_results():
    """Plot high availability benchmark results if available"""
    csv_path = f"{RESULTS_DIR}/ha_benchmark_results.csv"
    if not os.path.exists(csv_path):
        print(f"File not found: {csv_path}")
        return False

    try:
        print(f"Visualizing high availability benchmark results from {csv_path}")
        df = pd.read_csv(csv_path)

        if df.empty or 'scenario' not in df.columns:
            print(f"Warning: CSV format not as expected in {csv_path}")
            return False

        # Ensure success_rate is numeric
        if 'success_rate' in df.columns:
            df['success_rate'] = pd.to_numeric(df['success_rate'], errors='coerce')
        else:
            # If success_rate is not available, try to calculate it
            if 'total_queries' in df.columns and 'error_count' in df.columns:
                df['success_rate'] = 100 * (1 - df['error_count'] / df['total_queries'])
            else:
                print(f"Warning: Cannot determine success rate from {csv_path}")
                return False

        # Plot error rates during different failure scenarios
        plt.figure(figsize=(12, 7))

        scenarios = df['scenario'].values
        success_rates = df['success_rate'].values
        error_rates = 100 - df['success_rate']

        # Create bar chart
        x = np.arange(len(scenarios))
        width = 0.35

        fig, ax = plt.subplots(figsize=(12, 7))
        rects1 = ax.bar(x - width/2, success_rates, width, label='Success Rate (%)', color='green')
        rects2 = ax.bar(x + width/2, error_rates, width, label='Error Rate (%)', color='red')

        ax.set_title('Query Success/Error Rate During Failure Scenarios', fontsize=15)
        ax.set_ylabel('Percentage (%)', fontsize=12)
        ax.set_xticks(x)
        ax.set_xticklabels(scenarios, rotation=45, ha='right')
        ax.legend()

        # Add value labels
        for rect in rects1:
            height = rect.get_height()
            ax.annotate(f'{height:.1f}%',
                        xy=(rect.get_x() + rect.get_width() / 2, height),
                        xytext=(0, 3),
                        textcoords="offset points",
                        ha='center', va='bottom')

        for rect in rects2:
            height = rect.get_height()
            ax.annotate(f'{height:.1f}%',
                        xy=(rect.get_x() + rect.get_width() / 2, height),
                        xytext=(0, 3),
                        textcoords="offset points",
                        ha='center', va='bottom')

        plt.tight_layout()
        plt.savefig(f"{OUTPUT_DIR}/ha_success_rates.png", dpi=150)
        print(f"Saved to {OUTPUT_DIR}/ha_success_rates.png")
        return True
    except Exception as e:
        print(f"Error plotting HA results: {e}")
        return False

def plot_latency_results():
    """Plot read/write latency benchmark results"""
    csv_path = f"{RESULTS_DIR}/latency_benchmark_results.csv"
    if not os.path.exists(csv_path):
        print(f"File not found: {csv_path}")
        return False

    try:
        print(f"Visualizing read/write latency benchmark results from {csv_path}")
        df = pd.read_csv(csv_path)

        if df.empty or 'operation_type' not in df.columns:
            print(f"Warning: CSV format not as expected in {csv_path}")
            return False

        # Ensure latency_ms and throughput_per_sec are numeric
        for col in ['latency_ms', 'throughput_per_sec']:
            if col in df.columns:
                df[col] = pd.to_numeric(df[col], errors='coerce')

        # Separate read and write operations
        read_df = df[df['operation_type'] == 'read']
        write_df = df[df['operation_type'] == 'write']

        if not read_df.empty:
            # Plot read operations by batch size
            plt.figure(figsize=(12, 7))
            operations = read_df['operation'].unique()

            # Check if we have batch_size column
            if 'batch_size' in read_df.columns:
                # Create a grouped bar chart for read latencies
                batch_sizes = sorted(read_df['batch_size'].unique())
                x = np.arange(len(operations))
                width = 0.8 / len(batch_sizes)

                for i, size in enumerate(batch_sizes):
                    latencies = []
                    for op in operations:
                        op_data = read_df[(read_df['operation'] == op) & (read_df['batch_size'] == size)]
                        if len(op_data) > 0 and 'latency_ms' in op_data.columns:
                            latencies.append(op_data['latency_ms'].values[0])
                        else:
                            latencies.append(0)

                    offset = width * (i - len(batch_sizes)/2 + 0.5)
                    plt.bar(x + offset, latencies, width, label=f'Size: {size}')

                plt.title('Read Operation Latency by Type and Size', fontsize=15)
                plt.ylabel('Latency (ms)', fontsize=12)
                plt.xticks(x, operations, rotation=45, ha='right')
                plt.legend()
                plt.tight_layout()
                plt.savefig(f"{OUTPUT_DIR}/read_latency.png", dpi=150)
                print(f"Saved to {OUTPUT_DIR}/read_latency.png")

        if not write_df.empty:
            # Plot write operations by batch size
            plt.figure(figsize=(12, 7))
            operations = write_df['operation'].unique()

            # Check if we have batch_size column
            if 'batch_size' in write_df.columns:
                # Create a grouped bar chart for write latencies
                batch_sizes = sorted(write_df['batch_size'].unique())
                x = np.arange(len(operations))
                width = 0.8 / len(batch_sizes)

                for i, size in enumerate(batch_sizes):
                    latencies = []
                    for op in operations:
                        op_data = write_df[(write_df['operation'] == op) & (write_df['batch_size'] == size)]
                        if len(op_data) > 0 and 'latency_ms' in op_data.columns:
                            latencies.append(op_data['latency_ms'].values[0])
                        else:
                            latencies.append(0)

                    offset = width * (i - len(batch_sizes)/2 + 0.5)
                    plt.bar(x + offset, latencies, width, label=f'Size: {size}')

                plt.title('Write Operation Latency by Type and Size', fontsize=15)
                plt.ylabel('Latency (ms)', fontsize=12)
                plt.xticks(x, operations, rotation=45, ha='right')
                plt.legend()
                plt.tight_layout()
                plt.savefig(f"{OUTPUT_DIR}/write_latency.png", dpi=150)
                print(f"Saved to {OUTPUT_DIR}/write_latency.png")

        # Plot throughput comparison if we have that data
        if 'throughput_per_sec' in df.columns:
            plt.figure(figsize=(14, 7))

            # Group by operation and batch size
            if 'batch_size' in df.columns:
                op_groups = df.groupby(['operation', 'batch_size', 'operation_type'])['throughput_per_sec'].mean().reset_index()

                # Sort for better visualization
                op_groups = op_groups.sort_values(['operation_type', 'operation', 'batch_size'])

                try:
                    # Create a categorical plot
                    sns_plot = sns.catplot(
                        data=op_groups,
                        kind="bar",
                        x="operation",
                        y="throughput_per_sec",
                        hue="batch_size",
                        col="operation_type",
                        height=5,
                        aspect=1.2,
                        palette="viridis",
                        legend_out=False
                    )

                    sns_plot.set_xticklabels(rotation=45, ha="right")
                    sns_plot.set_titles("{col_name} Operations")
                    sns_plot.set_axis_labels("Operation", "Throughput (ops/sec)")
                    sns_plot.fig.suptitle('Operation Throughput Comparison', fontsize=16)
                    sns_plot.fig.subplots_adjust(top=0.85)

                    plt.savefig(f"{OUTPUT_DIR}/operation_throughput.png", dpi=150)
                    print(f"Saved to {OUTPUT_DIR}/operation_throughput.png")
                except Exception as e:
                    print(f"Error creating catplot: {e}")

        return True
    except Exception as e:
        print(f"Error plotting latency results: {e}")
        return False

def create_html_report():
    """Create an HTML report with all generated graphs"""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # Check which visualizations were generated
    graphs = []
    graph_files = {
        "Single Query Performance": "single_query_performance.png",
        "Query Performance by Iteration": "query_performance_by_iteration.png",
        "Concurrent TPS": "concurrent_tps.png",
        "Concurrent Latency": "concurrent_latency.png",
        "Worker Node Comparison": "worker_comparison.png",
        "High Availability Success Rates": "ha_success_rates.png",
        "Read Latency": "read_latency.png",
        "Write Latency": "write_latency.png",
        "Operation Throughput": "operation_throughput.png"
    }

    for title, filename in graph_files.items():
        if os.path.exists(f"{OUTPUT_DIR}/{filename}"):
            graphs.append((title, filename))

    # Create the HTML content
    html_content = f"""
    <!DOCTYPE html>
    <html>
    <head>
        <title>Citus Cluster Benchmark Results - {timestamp}</title>
        <style>
            body {{ font-family: Arial, sans-serif; margin: 40px; line-height: 1.6; }}
            h1, h2 {{ color: #333366; }}
            .graph-container {{ margin: 40px 0; }}
            img {{ max-width: 100%; border: 1px solid #ddd; border-radius: 5px; }}
            .summary {{ background-color: #f8f8f8; padding: 15px; border-left: 5px solid #333366; }}
            footer {{ margin-top: 50px; font-size: 0.8em; color: #666; text-align: center; }}
        </style>
    </head>
    <body>
        <h1>Citus Cluster Benchmark Results</h1>
        <div class="summary">
            <p><strong>Generated:</strong> {timestamp}</p>
            <p><strong>Visualizations:</strong> {len(graphs)}</p>
        </div>
    """

    # Add each graph to the report
    for title, filename in graphs:
        html_content += f"""
        <div class="graph-container">
            <h2>{title}</h2>
            <img src="graphs/{filename}" alt="{title}">
        </div>
        """

    # Close HTML
    html_content += """
        <footer>
            <p>Generated by Citus Cluster Benchmark Visualization Tool</p>
        </footer>
    </body>
    </html>
    """

    # Write the HTML file
    report_path = f"{RESULTS_DIR}/benchmark_report.html"
    with open(report_path, "w") as f:
        f.write(html_content)

    print(f"HTML report generated: {report_path}")
    return report_path

if __name__ == "__main__":
    # Generate timestamp for report
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"Generating benchmark visualization report at {timestamp}")

    # Run all visualizations
    plot_single_query_results()
    plot_concurrent_results()
    plot_worker_results()
    plot_ha_results()
    plot_latency_results()

    # Create HTML report
    report_path = create_html_report()

    print(f"\nVisualization complete! View your report at: {report_path}")
