# TdsCdc

Change Data Capture for SQL Server in Elixir.

TdsCdc captures row-level changes (INSERT, UPDATE, DELETE) from SQL Server tables with CDC enabled. It periodically polls CDC change tables and publishes events to subscribed processes.

## Requirements

- Elixir ~> 1.18
- SQL Server 2016+ with CDC enabled
- SQL Server Agent (sqlagent) running (required by CDC)

## Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:tds_cdc, "~> 0.1.0"}
  ]
end
```

## SQL Server Setup

### Enable CDC on the database

```sql
USE my_database;
GO
EXEC sys.sp_cdc_enable_db;
GO
```

### Enable CDC on a table

```sql
EXEC sys.sp_cdc_enable_table
    @source_schema = N'dbo',
    @source_name   = N'users',
    @role_name     = NULL;  -- NULL = unrestricted access
GO
```

This creates a **capture instance** named `dbo_users` and a table `cdc.dbo_users_CT` where SQL Server stores the changes.

## Usage

### Basic startup

```elixir
{:ok, pid} = TdsCdc.start_link(
  conn: [
    hostname: "localhost",
    port: 1433,
    username: "sa",
    password: "YourStrong!Passw0rd",
    database: "my_database"
  ],
  capture_instances: ["dbo_users", "dbo_orders"],
  poll_interval: 1_000  # ms, default: 1000
)
```

### Subscribe to changes

```elixir
:ok = TdsCdc.subscribe("dbo_users")

receive do
  {:tds_cdc_change, "dbo_users", %TdsCdc.Change{operation: :insert, data: %{id: 1, name: "Alice"}}} ->
    IO.puts("New user: #{change.data.name}")

  {:tds_cdc_change, "dbo_users", %TdsCdc.Change{operation: :update, data: %{id: 1, name: "Alice", email: "new@example.com"}}} ->
    IO.puts("User updated")

  {:tds_cdc_change, "dbo_users", %TdsCdc.Change{operation: :delete, data: %{id: 2, name: "Bob"}}} ->
    IO.puts("User deleted")
end
```

### Unsubscribe

```elixir
:ok = TdsCdc.unsubscribe("dbo_users")
```

### Query current LSN position

```elixir
{:ok, lsn} = TdsCdc.current_lsn("dbo_users")
```

### Stop the client

```elixir
:ok = TdsCdc.stop()
```

## Multiple instances

You can run multiple clients with different configurations:

```elixir
{:ok, pid_fast} = TdsCdc.start_link(
  name: TdsCdc.Fast,
  conn: [hostname: "localhost", ...],
  capture_instances: ["dbo_users"],
  poll_interval: 100
)

{:ok, pid_slow} = TdsCdc.start_link(
  name: TdsCdc.Slow,
  conn: [hostname: "localhost", ...],
  capture_instances: ["dbo_orders"],
  poll_interval: 5_000
)

TdsCdc.subscribe(TdsCdc.Fast, "dbo_users")
TdsCdc.subscribe(TdsCdc.Slow, "dbo_orders")
```

Each instance tracks its own LSN position independently.

## Gap detection

SQL Server purges old CDC data based on the configured retention period (default: 3 days). If a client falls behind the oldest available change data, TdsCdc detects the gap and:

1. Sends `{:tds_cdc_gap_detected, capture_instance, old_lsn, min_lsn}` to all subscribers
2. Logs a warning
3. Resets the position to the current `min_lsn` and continues from there

```elixir
receive do
  {:tds_cdc_gap_detected, ci, old_lsn, min_lsn} ->
    Logger.warning("Data lost in #{ci} between #{inspect(old_lsn)} and #{inspect(min_lsn)}")
end
```

## Change struct

```elixir
%TdsCdc.Change{
  capture_instance: "dbo_users",
  operation: :insert,          # :insert | :update | :delete
  data: %{id: 1, name: "Alice", email: "alice@example.com"},
  lsn: <<0, 0, 0, 42, 0, 0, 11, 128, 0, 82>>,
  lsn_prev: nil,
  seqval: <<0, 0, 0, 42, 0, 0, 11, 128, 0, 83>>,
  commit_lsn: nil,
  transaction_order: nil
}
```

> **Note on UPDATE operations:** CDC records operation=3 (before image) and operation=4 (after image). Both are mapped to `:update`.

## Architecture

```
SQL Server                          Elixir - TdsCdc
┌────────────┐    ┌─────────────┐    ┌───────────────────────────┐
│ dbo.users. │───►│ Transaction │    │ TdsCdc.Client (GenServer) │
│ dbo.orders │    │    Log      │    │                           │
└────────────┘    └────┬────────┘    │  :connect ─► Tds link     │
                       │             │  :poll ───► fetch_changes │
                       ▼             │       ───► %Change{}      │
                 ┌────────────┐      │       ───► send to subs   │
                 │ CDC Agent  │      │                           │
                 │ (sqlagent) │      │  lsn_positions tracker    │
                 └─────┬──────┘      │  subscribers registry     │
                       │             └─────────────┬─────────────┘
                       ▼                           │ send/2
                 ┌───────────────────┐             ▼
                 │ cdc.dbo_users_CT  │        ┌──────────┐
                 │ cdc.dbo_orders_CT │        │ App      │
                 └───────────────────┘        │ Consumer │
                                              └──────────┘
```

## Docker test environment

```bash
cd examples/docker
docker compose up --build
```

This spins up SQL Server 2022 with CDC enabled, `users` and `orders` tables with sample data, and an Elixir app demonstrating the full CDC capture flow.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TDS_HOST` | localhost | SQL Server host |
| `TDS_PORT` | 1433 | SQL Server port |
| `TDS_USERNAME` | sa | Username |
| `TDS_PASSWORD` | YourStrong!Passw0rd | Password |
| `TDS_DATABASE` | cdc_test | Database name |

## Modules

| Module | Description |
|--------|-------------|
| `TdsCdc` | Public API (start_link, subscribe, unsubscribe) |
| `TdsCdc.Client` | GenServer that manages connection and polling |
| `TdsCdc.Capture` | SQL queries against CDC tables |
| `TdsCdc.Change` | Struct representing a change event |
| `TdsCdc.Lsn` | Utilities for Log Sequence Numbers |

## License

MIT