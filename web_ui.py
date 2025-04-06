import os
import json
import subprocess
import glob
import flask
from flask import Flask, render_template, request, redirect, url_for, jsonify, send_file
import threading
import time
from datetime import datetime
import re

app = Flask(__name__, template_folder="templates", static_folder="static")

# Global variables to track benchmark state
current_benchmark = {
    "running": False,
    "type": None,
    "users": 0,
    "spawn_rate": 0,
    "run_time": 0,
    "read_weight": 0,
    "write_weight": 0,
    "start_time": None,
    "end_time": None,
    "output": [],
    "results_dir": None
}

@app.route('/')
def index():
    """Main page of the benchmark UI"""
    return render_template('index.html', benchmark=current_benchmark)

@app.route('/start_benchmark', methods=['POST'])
def start_benchmark():
    """Start a new benchmark with user-defined parameters"""
    global current_benchmark

    if current_benchmark["running"]:
        return jsonify({"status": "error", "message": "A benchmark is already running"})

    # Get parameters from form
    benchmark_type = request.form.get('benchmark_type', 'mixed')
    users = int(request.form.get('users', 100))
    spawn_rate = int(request.form.get('spawn_rate', 10))
    run_time = int(request.form.get('run_time', 60))

    read_weight = 0
    write_weight = 0

    if benchmark_type == 'read':
        read_weight = 100
        write_weight = 0
        script = "./read_benchmark.sh"
    elif benchmark_type == 'write':
        read_weight = 0
        write_weight = 100
        script = "./write_benchmark.sh"
    else:  # mixed
        read_weight = int(request.form.get('read_weight', 80))
        write_weight = int(request.form.get('write_weight', 20))
        script = "./run_locust_benchmark.sh"

    # Update benchmark state
    current_benchmark = {
        "running": True,
        "type": benchmark_type,
        "users": users,
        "spawn_rate": spawn_rate,
        "run_time": run_time,
        "read_weight": read_weight,
        "write_weight": write_weight,
        "start_time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "output": [],
        "results_dir": None,
        "end_time": None
    }

    # Run benchmark in a separate thread
    threading.Thread(target=run_benchmark, args=(
        script, users, spawn_rate, run_time, read_weight, write_weight, benchmark_type
    )).start()

    return redirect(url_for('index'))

def run_benchmark(script, users, spawn_rate, run_time, read_weight, write_weight, benchmark_type):
    """Run the benchmark script in a subprocess"""
    global current_benchmark

    env = os.environ.copy()
    env["USERS"] = str(users)
    env["SPAWN_RATE"] = str(spawn_rate)
    env["RUN_TIME"] = str(run_time)
    env["READ_WEIGHT"] = str(read_weight)
    env["WRITE_WEIGHT"] = str(write_weight)

    cmd = [script]

    # Add arguments for mixed mode
    if benchmark_type == 'mixed':
        cmd.append(f"--read-write-ratio={read_weight}:{write_weight}")

    try:
        # Run the benchmark process
        process = subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )

        # Process output line by line
        for line in iter(process.stdout.readline, ''):
            current_benchmark["output"].append(line.rstrip())

            # Try to identify results directory from output
            if "Results will be saved to" in line:
                match = re.search(r'Results will be saved to (.+)', line)
                if match:
                    current_benchmark["results_dir"] = match.group(1)

        process.stdout.close()
        return_code = process.wait()

        if return_code != 0:
            current_benchmark["output"].append(f"Benchmark process exited with code {return_code}")

    except Exception as e:
        current_benchmark["output"].append(f"Error running benchmark: {str(e)}")

    finally:
        current_benchmark["running"] = False
        current_benchmark["end_time"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

@app.route('/benchmark_status')
def benchmark_status():
    """Return the current status of the benchmark as JSON"""
    return jsonify(current_benchmark)

@app.route('/benchmark_output')
def benchmark_output():
    """Return the current benchmark output"""
    since = int(request.args.get('since', 0))
    return jsonify({
        "running": current_benchmark["running"],
        "output": current_benchmark["output"][since:],
        "count": len(current_benchmark["output"])
    })

@app.route('/results')
def results():
    """Show a list of all benchmark results"""
    # Find all JSON result files
    result_files = glob.glob("benchmark_results/locust_metrics_*.json")
    results = []

    for file_path in result_files:
        try:
            with open(file_path, 'r') as f:
                data = json.load(f)

            # Extract timestamp and basic metrics from filename and data
            timestamp = data.get("timestamp", os.path.basename(file_path).replace("locust_metrics_", "").replace(".json", ""))

            results.append({
                "file": os.path.basename(file_path),
                "timestamp": timestamp,
                "throughput": data.get("throughput_ops_sec", {}).get("total", 0),
                "read_latency": data.get("read_latency_ms", {}).get("avg", 0),
                "write_latency": data.get("write_latency_ms", {}).get("avg", 0),
                "success_rate": data.get("success_rate", 0)
            })
        except Exception as e:
            print(f"Error processing {file_path}: {e}")

    # Sort by timestamp (latest first)
    results.sort(key=lambda x: x["timestamp"], reverse=True)

    return render_template('results.html', results=results)

@app.route('/result_details/<filename>')
def result_details(filename):
    """Show details for a specific benchmark result"""
    file_path = os.path.join("benchmark_results", filename)

    if not os.path.exists(file_path):
        return "Result file not found", 404

    try:
        with open(file_path, 'r') as f:
            data = json.load(f)

        return render_template('result_details.html', data=data, filename=filename)

    except Exception as e:
        return f"Error reading result file: {str(e)}", 500

@app.route('/download_result/<filename>')
def download_result(filename):
    """Download a benchmark result file"""
    file_path = os.path.join("benchmark_results", filename)

    if not os.path.exists(file_path):
        return "Result file not found", 404

    return send_file(file_path, as_attachment=True)

@app.route('/compare_results', methods=['GET', 'POST'])
def compare_results():
    """Compare multiple benchmark results"""
    if request.method == 'POST':
        selected_files = request.form.getlist('selected_files')
        results = []

        for filename in selected_files:
            file_path = os.path.join("benchmark_results", filename)
            try:
                with open(file_path, 'r') as f:
                    data = json.load(f)

                results.append({
                    "filename": filename,
                    "data": data
                })
            except Exception as e:
                print(f"Error processing {file_path}: {e}")

        return render_template('compare_results.html', results=results)

    # GET - Show all available result files
    result_files = glob.glob("benchmark_results/locust_metrics_*.json")
    filenames = [os.path.basename(f) for f in result_files]
    filenames.sort(reverse=True)

    return render_template('select_results.html', files=filenames)

@app.route('/clear_output', methods=['POST'])
def clear_output():
    """Clear the current output buffer"""
    global current_benchmark

    if not current_benchmark["running"]:
        current_benchmark["output"] = []
        return jsonify({"status": "success", "message": "Output cleared"})
    else:
        return jsonify({"status": "error", "message": "Cannot clear output while benchmark is running"})

if __name__ == '__main__':
    # Create necessary directories
    os.makedirs("benchmark_results", exist_ok=True)
    os.makedirs("templates", exist_ok=True)
    os.makedirs("static", exist_ok=True)

    print("Starting benchmark web UI...")
    app.run(host='0.0.0.0', port=8080, debug=True)
