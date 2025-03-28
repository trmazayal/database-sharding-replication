#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

CONTAINER="citus_loadbalancer"

echo -e "${YELLOW}Checking benchmark prerequisites...${NC}"

# Ensure directories exist
echo -e "${YELLOW}Ensuring benchmark directories exist...${NC}"
mkdir -p benchmark_results
mkdir -p benchmark_results/graphs

# Check if container is running
echo -e "${YELLOW}Checking if container $CONTAINER is running...${NC}"
if ! docker ps | grep -q $CONTAINER; then
    echo -e "${RED}Container $CONTAINER is not running.${NC}"
    echo -e "${YELLOW}Trying to start the container...${NC}"
    docker-compose up -d $CONTAINER || {
        echo -e "${RED}Failed to start the container. Please run Docker Compose manually:${NC}"
        echo "docker-compose up -d"
        exit 1
    }
    sleep 5
    if ! docker ps | grep -q $CONTAINER; then
        echo -e "${RED}Container $CONTAINER failed to start.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Container started successfully.${NC}"
fi

# Check PostgreSQL client in loadbalancer
echo -e "${YELLOW}Checking PostgreSQL client in loadbalancer...${NC}"
if ! docker exec $CONTAINER which psql &>/dev/null; then
    echo -e "${YELLOW}Installing PostgreSQL client...${NC}"
    docker exec $CONTAINER bash -c "apt-get update && apt-get install -y gnupg2 curl lsb-release"
    docker exec $CONTAINER bash -c "echo 'deb http://apt.postgresql.org/pub/repos/apt/ \$(lsb_release -cs)-pgdg main' > /etc/apt/sources.list.d/pgdg.list && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -"
    docker exec $CONTAINER bash -c "apt-get update && apt-get install -y postgresql-client-15 || apt-get install -y postgresql-client"

    if ! docker exec $CONTAINER which psql &>/dev/null; then
        echo -e "${RED}Failed to install PostgreSQL client.${NC}"
        exit 1
    fi
    echo -e "${GREEN}PostgreSQL client installed successfully.${NC}"
else
    echo -e "${GREEN}PostgreSQL client already installed.${NC}"
fi

# Check for pgbench
echo -e "${YELLOW}Checking for pgbench...${NC}"
if ! docker exec $CONTAINER which pgbench &>/dev/null; then
    echo -e "${YELLOW}Looking for pgbench in PostgreSQL directories...${NC}"
    PGBENCH_PATH=$(docker exec $CONTAINER find /usr/lib/postgresql -name pgbench -type f 2>/dev/null | head -n 1)

    if [ -n "$PGBENCH_PATH" ]; then
        echo -e "${GREEN}Found pgbench at $PGBENCH_PATH${NC}"
        echo -e "${YELLOW}Creating symlink...${NC}"
        docker exec $CONTAINER ln -sf "$PGBENCH_PATH" /usr/bin/pgbench
    else
        echo -e "${YELLOW}Installing pgbench...${NC}"
        docker exec $CONTAINER apt-get update
        docker exec $CONTAINER apt-get install -y postgresql-contrib || docker exec $CONTAINER apt-get install -y postgresql-15-contrib

        # Check again
        PGBENCH_PATH=$(docker exec $CONTAINER find /usr/lib/postgresql -name pgbench -type f 2>/dev/null | head -n 1)
        if [ -n "$PGBENCH_PATH" ]; then
            echo -e "${GREEN}Found pgbench at $PGBENCH_PATH${NC}"
            docker exec $CONTAINER ln -sf "$PGBENCH_PATH" /usr/bin/pgbench
        else
            echo -e "${RED}Could not install pgbench. Concurrent benchmarks will not work.${NC}"
        fi
    fi
else
    echo -e "${GREEN}pgbench is already installed.${NC}"
fi

# Check if PostgreSQL is running and accessible
echo -e "${YELLOW}Testing PostgreSQL connectivity...${NC}"
if ! docker exec $CONTAINER psql -h localhost -p 5432 -U citus -d citus -c "SELECT 1" &>/dev/null; then
    echo -e "${RED}Could not connect to PostgreSQL. Make sure the cluster is running and accessible.${NC}"
    exit 1
fi
echo -e "${GREEN}Successfully connected to PostgreSQL.${NC}"

# Make sure all benchmark scripts are executable
echo -e "${YELLOW}Setting execute permissions on benchmark scripts...${NC}"
chmod +x benchmark.sh
chmod +x worker-benchmark.sh
chmod +x ha-benchmark.sh
echo -e "${GREEN}Execute permissions set.${NC}"

echo -e "${GREEN}Prerequisites check completed.${NC}"
echo -e "${GREEN}The environment is ready for benchmarks.${NC}"
