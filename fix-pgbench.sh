#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

CONTAINER="citus_loadbalancer"

echo -e "${YELLOW}Fixing pgbench and PostgreSQL client in loadbalancer container...${NC}"

# Check if container is running
if ! docker ps | grep -q "$CONTAINER"; then
    echo -e "${RED}Container $CONTAINER is not running!${NC}"
    exit 1
fi

# Install PostgreSQL client packages using in-container variable expansion
echo -e "${YELLOW}Installing PostgreSQL client packages...${NC}"
if docker exec -i "$CONTAINER" bash -c 'apt-get update && \
    apt-get install -y gnupg2 curl lsb-release ca-certificates && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --batch --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg && \
    CODENAME=$(lsb_release -cs) && \
    echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt/ ${CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y postgresql-client-15 postgresql-client-common && \
    apt-get clean && rm -rf /var/lib/apt/lists/*'; then
    echo -e "${GREEN}Main installation method succeeded.${NC}"
else
    echo -e "${RED}Failed to install using main method. Trying alternative approach...${NC}"
    docker exec -i "$CONTAINER" bash -c 'CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2) && \
    echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt/ ${CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y postgresql-client-15 postgresql-client-common && \
    apt-get clean && rm -rf /var/lib/apt/lists/*'
fi

# Find pgbench and create a symlink
echo -e "${YELLOW}Creating symlink to pgbench...${NC}"
pgbench_path=$(docker exec -i "$CONTAINER" bash -c 'find /usr/lib/postgresql -name pgbench -type f 2>/dev/null | head -n 1')
if [ -n "$pgbench_path" ]; then
    docker exec -i "$CONTAINER" ln -sf "$pgbench_path" /usr/bin/pgbench
    echo -e "${GREEN}Created symlink to pgbench at $pgbench_path${NC}"
else
    echo -e "${RED}Could not find pgbench. Installation may have failed.${NC}"
    echo -e "${YELLOW}Trying alternative installation method...${NC}"
    docker exec -i "$CONTAINER" bash -c 'apt-get update && \
        apt-get install -y postgresql-client postgresql-contrib && \
        apt-get clean && rm -rf /var/lib/apt/lists/*'
    pgbench_path=$(docker exec -i "$CONTAINER" bash -c 'find /usr/lib/postgresql -name pgbench -type f 2>/dev/null | head -n 1')
    if [ -n "$pgbench_path" ]; then
        docker exec -i "$CONTAINER" ln -sf "$pgbench_path" /usr/bin/pgbench
        echo -e "${GREEN}Created symlink to pgbench at $pgbench_path${NC}"
    else
        echo -e "${RED}All attempts to install pgbench failed.${NC}"
        exit 1
    fi
fi

# Verify installation
echo -e "${YELLOW}Verifying installation...${NC}"
if docker exec -i "$CONTAINER" pgbench --version &>/dev/null; then
    echo -e "${GREEN}pgbench successfully installed and accessible.${NC}"
else
    echo -e "${RED}pgbench installation verification failed.${NC}"
    exit 1
fi

echo -e "${GREEN}PostgreSQL client and pgbench installation complete!${NC}"
