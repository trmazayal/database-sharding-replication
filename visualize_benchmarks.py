#!/usr/bin/env python3
import matplotlib.pyplot as plt
import pandas as pd
import os
import numpy as np
from datetime import datetime

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
        return

    print(f"Visualizing single query results from {csv_path}")
    df = pd.read_csv(csv_path)

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

def plot_concurrent_results():
    """Plot results from concurrent benchmark tests"""
    csv_path = f"{RESULTS_DIR}/concurrent_results.csv"
    if not os.path.exists(csv_path):
        print(f"File not found: {csv_path}")
        return

    print(f"Visualizing concurrent benchmark results from {csv_path}")
    df = pd.read_csv(csv_path)

    # Plot TPS by number of clients for each test
    plt.figure(figsize=(12, 6))
    for test in df['test_name'].unique():
        test_df = df[df['test_name'] == test].sort_values('clients')
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
        plt.plot(test_df['clients'], test_df['latency_ms'], marker='o', linewidth=2, label=test)

    plt.title('Average Latency by Client Count', fontsize=15)
    plt.ylabel('Latency (ms)', fontsize=12)
    plt.xlabel('Number of Clients', fontsize=12)
    plt.grid(True)
    plt.legend()
    plt.tight_layout()
    plt.savefig(f"{OUTPUT_DIR}/concurrent_latency.png", dpi=150)
    print(f"Saved to {OUTPUT_DIR}/concurrent_latency.png")

def plot_worker_results():
    """Plot comparison between worker nodes"""
    csv_path = f"{RESULTS_DIR}/worker_benchmark_results.csv"
    if not os.path.exists(csv_path):
        print(f"File not found: {csv_path}")
        return

    print(f"Visualizing worker benchmark results from {csv_path}")
    df = pd.read_csv(csv_path)

    # Convert time strings to seconds
    df['real_seconds'] = df['real_time'].apply(time_to_seconds)

    # Plot real execution time by node for each query
    plt.figure(figsize=(12, 8))
    queries = df['query'].unique()
    nodes = df['node'].unique()

    x = np.arange(len(queries))  # the label locations
    width = 0.2  # the width of the bars
    multiplier = 0

    fig, ax = plt.subplots(figsize=(15, 8))

    for node in nodes:
        offset = width * multiplier
        node_data = []

        for query in queries:
            query_data = df[(df['query'] == query) & (df['node'] == node)]
            if not query_data.empty:
                node_data.append(query_data['real_seconds'].values[0])
            else:
                node_data.append(0)

        rects = ax.bar(x + offset, node_data, width, label=node)
        ax.bar_label(rects, padding=3, fmt='%.2f')
        multiplier += 1

    ax.set_title('Query Execution Time by Node', fontsize=15)
    ax.set_ylabel('Execution Time (seconds)', fontsize=12)
    ax.set_xticks(x + width, queries)
    ax.legend(loc='upper left', bbox_to_anchor=(1, 1))
    plt.xticks(rotation=45, ha='right')
    plt.tight_layout()

    plt.savefig(f"{OUTPUT_DIR}/worker_comparison.png", dpi=150)
    print(f"Saved to {OUTPUT_DIR}/worker_comparison.png")

def plot_ha_results():
    """Plot high availability benchmark results if available"""
    csv_path = f"{RESULTS_DIR}/ha_benchmark_results.csv"
    if not os.path.exists(csv_path):
        print(f"File not found: {csv_path}")
        return

    print(f"Visualizing high availability benchmark results from {csv_path}")
    df = pd.read_csv(csv_path)

    # Plot error rates during different failure scenarios
    plt.figure(figsize=(10, 6))

    # Assuming the CSV has columns: scenario, total_queries, error_count, success_rate
    scenarios = df['scenario'].values
    success_rates = df['success_rate'].values
    error_rates = 100 - df['success_rate']

    # Create bar chart
    x = np.arange(len(scenarios))
    width = 0.35

    fig, ax = plt.subplots(figsize=(12, 7))
    rects1 = ax.bar(x, success_rates, width, label='Success Rate (%)', color='green')
    rects2 = ax.bar(x + width, error_rates, width, label='Error Rate (%)', color='red')

    ax.set_title('Query Success/Error Rate During Failure Scenarios', fontsize=15)
    ax.set_ylabel('Percentage (%)', fontsize=12)
    ax.set_xticks(x + width / 2)
    ax.set_xticklabels(scenarios)
    plt.xticks(rotation=45, ha='right')
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
        "High Availability Success Rates": "ha_success_rates.png"
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

    # Create HTML report
    report_path = create_html_report()

    print(f"\nVisualization complete! View your report at: {report_path}")
