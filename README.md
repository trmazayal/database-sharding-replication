# Distributed PostgreSQL Cluster with Citus and PostGIS

This project sets up a distributed PostgreSQL cluster using Citus and PostGIS with an active-active configuration, load balancing, and high availability.

## Architecture

The cluster is composed of multiple PostgreSQL nodes with Citus and PostGIS extensions configured in an active-active setup. Below is an example of the architecture:


## Prerequisites

- Docker and Docker Compose installed on your machine.

## Setup

1. Clone the repository:
   git clone https://github.com/trmazayal/database-sharding.git
   cd database-sharding

2. Set any required script permissions:
   chmod +x *.sh

3. Start the cluster:
   docker-compose up -d

4. Verify the cluster is running:
   docker-compose ps

## Testing the Cluster

1. Connect to the coordinator node uisng load balancer:
   psql -h localhost -p 5432 -U postgres

2. Create a distributed table:
   CREATE TABLE distributed_table (
       id serial PRIMARY KEY,
       data text
   );
   SELECT create_distributed_table('distributed_table', 'id');

3. Insert data into the distributed table:
   INSERT INTO distributed_table (data) VALUES ('sample data');

4. Query the distributed table:
   SELECT * FROM distributed_table;

## Component Breakdown

- Coordinator Nodes: Primary and secondary PostgreSQL servers running Citus.
- Worker Nodes: Nodes that store and process distributed data.
- Load Balancer: HAProxy configured to distribute incoming requests between coordinators.
- Manager: (Optional) A service to configure the cluster on startup.

### Key Files

- docker-compose.yml: Defines all services and their configurations.
- Dockerfile: Extends the Citus image with PostGIS.
- setup.sh: Initializes the cluster configuration.
- haproxy.cfg: Load balancer configuration.
- init.sql: Creates and populates a distributed table for testing.

## Troubleshooting

### Connection Issues

- Check running containers:
   docker-compose ps

- View load balancer logs:
   docker logs <load-balancer-container-name>

- View coordinator node logs:
   docker logs <coordinator-container-name>

### Data Distribution Issues

- Verify worker nodes registration:
   psql -h localhost -p 5432 -U postgres -c "SELECT * FROM pg_dist_node;"

- Check shard placement:
   psql -h localhost -p 5432 -U postgres -c "SELECT * FROM pg_dist_placement;"

- Verify shard count:
   psql -h localhost -p 5432 -U postgres -c "SELECT * FROM pg_dist_shard;"

## Cleanup

To stop and remove the cluster, run:
   docker-compose down

To completely remove all data volumes as well:
   docker-compose down -v

## Author

Tara Mazaya Lababan