#!/bin/bash
set -e

SQL_HOST="${SQL_HOST:-sqlserver}"
SQL_PORT="${SQL_PORT:-1433}"
SQL_USER="${SQL_USER:-sa}"
SQL_PASSWORD="${SA_PASSWORD}"

echo "Waiting for SQL Server at ${SQL_HOST}:${SQL_PORT} to be ready..."

for i in $(seq 1 60); do
  if /opt/mssql-tools18/bin/sqlcmd \
    -S "${SQL_HOST},${SQL_PORT}" -U "${SQL_USER}" -P "${SQL_PASSWORD}" \
    -C -No \
    -Q "SELECT 1" > /dev/null 2>&1; then
    echo "SQL Server is ready."
    break
  fi

  if [ "$i" -eq 60 ]; then
    echo "ERROR: SQL Server did not become ready in time."
    exit 1
  fi

  echo "Attempt $i/60 - SQL Server not ready yet..."
  sleep 2
done

echo "Running initialization scripts..."

/opt/mssql-tools18/bin/sqlcmd \
  -S "${SQL_HOST},${SQL_PORT}" -U "${SQL_USER}" -P "${SQL_PASSWORD}" \
  -C -No \
  -i /docker-entrypoint-initdb.d/init.sql

echo "Initialization completed successfully."