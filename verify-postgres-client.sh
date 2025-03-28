#!/bin/bash
set -e

echo "Verifying PostgreSQL client installation in the loadbalancer container..."

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

CONTAINER="citus_loadbalancer"

# Check if container is running
if ! docker ps | grep -q $CONTAINER; then
    echo -e "${RED}Container $CONTAINER is not running!${NC}"
    exit 1
fi

# Check for psql
echo -e "${YELLOW}Checking for psql...${NC}"
if docker exec $CONTAINER which psql &>/dev/null; then
    PSQL_PATH=$(docker exec $CONTAINER which psql)
    echo -e "${GREEN}psql found at: $PSQL_PATH${NC}"
else
    echo -e "${RED}psql not found. Installing...${NC}"

    # Try to install PostgreSQL client
    docker exec $CONTAINER bash -c "apt-get update && \
        apt-get install -y gnupg2 curl lsb-release && \
        echo 'deb http://apt.postgresql.org/pub/repos/apt/ \$(lsb_release -cs)-pgdg main' > /etc/apt/sources.list.d/pgdg.list && \
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - && \
        apt-get update && \
        apt-get install -y postgresql-client"

    # Check again
    if docker exec $CONTAINER which psql &>/dev/null; then
        PSQL_PATH=$(docker exec $CONTAINER which psql)
        echo -e "${GREEN}psql installed at: $PSQL_PATH${NC}"
    else
        echo -e "${RED}Failed to install psql!${NC}"
        exit 1
    fi
fi

# Check for pgbench
echo -e "${YELLOW}Checking for pgbench...${NC}"
if docker exec $CONTAINER which pgbench &>/dev/null; then
    PGBENCH_PATH=$(docker exec $CONTAINER which pgbench)
    echo -e "${GREEN}pgbench found at: $PGBENCH_PATH${NC}"
else
    echo -e "${RED}pgbench not found. Looking for it...${NC}"

    # Find pgbench in PostgreSQL lib directory
    PGBENCH_PATH=$(docker exec $CONTAINER find /usr/lib/postgresql -name pgbench -type f 2>/dev/null | head -n 1)

    if [ -n "$PGBENCH_PATH" ]; then
        echo -e "${GREEN}pgbench found at: $PGBENCH_PATH${NC}"
        echo -e "${YELLOW}Creating symlink to /usr/bin/pgbench...${NC}"
        docker exec $CONTAINER ln -sf "$PGBENCH_PATH" /usr/bin/pgbench
        echo -e "${GREEN}Symlink created!${NC}"
    else
        echo -e "${RED}pgbench not found! Trying to install...${NC}"

        # Try to install pgbench separately
        docker exec $CONTAINER bash -c "apt-get update && \
            apt-get install -y postgresql-contrib"

        # Check again
        PGBENCH_PATH=$(docker exec $CONTAINER find /usr/lib/postgresql -name pgbench -type f 2>/dev/null | head -n 1)

        if [ -n "$PGBENCH_PATH" ]; then
            echo -e "${GREEN}pgbench found at: $PGBENCH_PATH${NC}"
            echo -e "${YELLOW}Creating symlink to /usr/bin/pgbench...${NC}"
            docker exec $CONTAINER ln -sf "$PGBENCH_PATH" /usr/bin/pgbench
            echo -e "${GREEN}Symlink created!${NC}"
        else
            echo -e "${RED}Failed to install pgbench!${NC}"
            exit 1
        fi
    fi
fi

# Verify psql can connect
echo -e "${YELLOW}Testing PostgreSQL connection...${NC}"
if docker exec -i $CONTAINER psql -h localhost -p 5432 -U citus -d citus -c "SELECT 1;" &>/dev/null; then
    echo -e "${GREEN}Connection successful!${NC}"
else
    echo -e "${RED}Connection failed!${NC}"
    exit 1
fi

echo -e "${GREEN}PostgreSQL client verification complete!${NC}"
