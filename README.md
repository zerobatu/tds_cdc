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

For Ecto integration, also add:

```elixir
def deps do
  [
    {:tds_cdc, "~> 0.1.0"},
    {:ecto_sql, "~> 3.0"},
    {:tds_ecto, "~> 2.3"}
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

The capture instance name follows the pattern `<schema>_<table>` — so `dbo.users` becomes `dbo_users`. You use this name everywhere in TdsCdc: `capture_instances: ["dbo_users"]`, `TdsCdc.subscribe("dbo_users")`, etc. You can also specify a custom name via `@capture_instance` when enabling CDC.

## Connection adapters

TdsCdc supports two connection modes:

### Option A: Direct TDS connection (default)

Manages its own connection pool. No external dependencies beyond `tds`.

```elixir
{:ok, pid} = TdsCdc.start_link(
  conn: [
    hostname: "localhost",
    port: 1433,
    username: "sa",
    password: "YourStrong!Passw0rd",
    database: "my_database"
  ],
  capture_instances: ["dbo_users"],
  poll_interval: 1_000
)
```

The `:conn` options are forwarded to `Tds.start_link/1`. Additional pool options:

| Option | Default | Description |
|--------|---------|-------------|
| `:pool_size` | 5 | Number of connections in the pool |
| `:ownership_timeout` | 30000 | Max time (ms) a connection can be checked out |
| `:timeout` | 30000 | Query timeout (ms) |

### Option B: Ecto.Repo

Uses an existing Ecto.Repo for all queries. Shares the Repo's connection pool — no separate TDS connection needed.

```elixir
# In your application.ex supervision tree:
children = [
  MyApp.Repo,
  {TdsCdc.Client, repo: MyApp.Repo, capture_instances: ["dbo_users"]}
]

# Or at runtime:
{:ok, pid} = TdsCdc.start_link(
  repo: MyApp.Repo,
  capture_instances: ["dbo_users"]
)
```

**Requirements:** The Repo must use the TDS adapter (`tds_ecto`) and be started before TdsCdc.

## Usage

### Subscribe to changes

```elixir
:ok = TdsCdc.subscribe("dbo_users")

receive do
  {:tds_cdc_change, "dbo_users", %TdsCdc.Change{operation: :insert, data: %{id: 1, name: "Alice"}}} ->
    IO.puts("New user: #{change.data.name}")

  {:tds_cdc_change, "dbo_users", %TdsCdc.Change{operation: :update, data: %{id: 1, name: "Alice"}}} ->
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

The LSN (Log Sequence Number) position indicates how far the client has processed changes in the SQL Server transaction log. Use this to check which changes have already been delivered.

```elixir
{:ok, lsn} = TdsCdc.current_lsn("dbo_users")
```

### Stop the client

Gracefully stops the CDC client process, cancels its polling timer, and (if using `:conn`) closes the database connection. Subscribers will no longer receive change events.

```elixir
:ok = TdsCdc.stop()
```

### Check CDC status (utility functions)

These functions accept either a TDS connection pid or an Ecto.Repo module:

```elixir
# With TDS connection
{:ok, conn} = Tds.start_link(conn_opts)
{:ok, true} = TdsCdc.cdc_enabled?(conn)
{:ok, ["dbo_users", "dbo_orders"]} = TdsCdc.list_capture_instances(conn)
GenServer.stop(conn)

# With Ecto.Repo
{:ok, true} = TdsCdc.cdc_enabled?(MyApp.Repo)
{:ok, ["dbo_users"]} = TdsCdc.list_capture_instances(MyApp.Repo)
```

### Wait for client to be ready

```elixir
{:ok, pid} = TdsCdc.start_link(conn: conn_opts, capture_instances: ["dbo_users"])
:ok = TdsCdc.wait_for_ready(timeout: 10_000, capture_instance: "dbo_users")
TdsCdc.subscribe("dbo_users")
```

## LSN persistence

By default, TdsCdc persists LSN positions to disk so they survive application restarts. When the client starts, it loads saved positions and resumes from where it left off (provided the positions are still within the CDC retention window).

### Default: file-based persistence

Positions are saved as JSON files in `<system_tmp>/tds_cdc/<client_name>.json`:

```elixir
# Default (automatic)
TdsCdc.start_link(conn: [...], capture_instances: ["dbo_users"])

# Custom path
TdsCdc.start_link(
  conn: [...],
  capture_instances: ["dbo_users"],
  persistence: {TdsCdc.Persistence.File, path: "/var/lib/myapp/lsn"}
)
```

### Custom persistence module

Implement the `TdsCdc.Persistence` behaviour to store positions in a database, Redis, or any other backend:

```elixir
defmodule MyApp.DbPersistence do
  @behaviour TdsCdc.Persistence

  @impl true
  def save_positions(_name, positions) do
    # Write positions to your database
    :ok
  end

  @impl true
  def load_positions(name) do
    # Read positions from your database
    {:ok, %{}}  # or {:error, :not_found}
  end
end

TdsCdc.start_link(
  conn: [...],
  capture_instances: ["dbo_users"],
  persistence: {MyApp.DbPersistence, []}
)
```

### Disable persistence

If you don't need positions to survive restarts:

```elixir
TdsCdc.start_link(
  conn: [...],
  capture_instances: ["dbo_users"],
  persistence: nil
)
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
  repo: MyApp.Repo,
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

When you enable CDC on a table (e.g. `dbo.users`), SQL Server creates a **change table** named `cdc.<schema>_<table>_CT` (e.g. `cdc.dbo_users_CT`). The SQL Server Agent (CDC capture job) reads the transaction log and populates these `_CT` tables with every INSERT, UPDATE, and DELETE as they occur. Each `_CT` row includes metadata columns (`__$operation`, `__$start_lsn`, `__$seqval`) plus all the tracked table's columns.

TdsCdc periodically queries these `_CT` tables using the `sys.fn_cdc_get_all_changes_*` function, starting from the last LSN it processed. It advances the LSN position after each poll so no change is delivered twice.

```
SQL Server                          Elixir - TdsCdc
┌────────────┐    ┌─────────────┐      ┌───────────────────────────┐
│ dbo.users. │───►│ Transaction │      │ TdsCdc.Client (GenServer) │
│ dbo.orders │    │    Log      │      │                           │
└────────────┘    └────┬────────┘      │  Connection Adapter       │
                       │               │  ┌──────────────────────┐ │
                       ▼               │  │ TdsCdc.Connection.Tds│ │
                 ┌────────────┐        │  │ -or-                 │ │
                 │ CDC Agent  │        │  │ TdsCdc.Connection.   │ │
                 │ (sqlagent) │        │  │   Ecto               │ │
                 └─────┬──────┘        │  └──────────────────────┘ │
                       │               │                           │
                       ▼               │  :poll ───► fetch_changes │
                 ┌───────────────────┐ │       ───► %Change{}      │
                 │ cdc.dbo_users_CT  │ │       ───► send to subs   │
                 │ cdc.dbo_orders_CT │ │                           │
                 └───────────────────┘ │  lsn_positions tracker    │
                                       │  subscribers registry     │
                                       └─────────────┬─────────────┘
                                                     │ send/2
                                                     ▼
                                               ┌──────────┐
                                               │ App      │
                                               │ Consumer │
                                               └──────────┘
```

## Structured listener with `use TdsCdc.Listener`

For a more structured approach, use the `TdsCdc.Listener` behaviour. It auto-starts a CDC client, subscribes, and dispatches changes to your callbacks:

```elixir
defmodule MyApp.CdcListener do
  use TdsCdc.Listener

  @impl true
  def on_init(_opts) do
    {:ok, %{inserts: 0, updates: 0, deletes: 0}}
  end

  @impl true
  def on_insert(change, state) do
    IO.puts("New record: #{inspect(change.data)}")
    {:ok, %{state | inserts: state.inserts + 1}}
  end

  @impl true
  def on_update(change, state) do
    IO.puts("Updated: #{inspect(change.data)}")
    {:ok, %{state | updates: state.updates + 1}}
  end

  @impl true
  def on_delete(change, state) do
    IO.puts("Deleted: #{inspect(change.data)}")
    {:ok, %{state | deletes: state.deletes + 1}}
  end

  @impl true
  def on_gap(ci, old_lsn, min_lsn, state) do
    Logger.warning("Gap detected in #{ci}")
    {:ok, state}
  end
end
```

Add to your supervision tree:

```elixir
children = [
  {MyApp.CdcListener, conn: [hostname: "localhost", ...], capture_instances: ["dbo_users"]}
]
```

All callbacks are optional and have default implementations. Return `{:ok, state}` to continue or `{:stop, reason}` to stop the listener.

## Docker example

```bash
cd example
docker compose up --build
```

Spins up SQL Server 2022 with CDC enabled, a web app with CRUD for users on port 4000, and a listener that prints CDC changes in real time.

- **Web app**: http://localhost:4000 — create, edit, and delete users
- **Listener** — prints INSERT/UPDATE/DELETE events captured via CDC

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TDS_HOST` | localhost | SQL Server host |
| `TDS_PORT` | 1433 | SQL Server port |
| `TDS_USERNAME` | sa | Username |
| `TDS_PASSWORD` | YourStrong!Passw0rd | Password |
| `TDS_DATABASE` | cdc_example | Database name |

## Modules

| Module | Description |
|--------|-------------|
| `TdsCdc` | Public API (start_link, subscribe, unsubscribe, cdc_enabled?, list_capture_instances) |
| `TdsCdc.Client` | GenServer that manages connection and polling |
| `TdsCdc.Listener` | Behaviour for structured CDC event listeners |
| `TdsCdc.Connection` | Behaviour for database connection adapters |
| `TdsCdc.Connection.Tds` | Direct TDS connection adapter (default) |
| `TdsCdc.Connection.Ecto` | Ecto.Repo connection adapter |
| `TdsCdc.Change` | Struct representing a change event |
| `TdsCdc.Lsn` | Utilities for Log Sequence Numbers |
| `TdsCdc.Persistence` | Behaviour for LSN position persistence |
| `TdsCdc.Persistence.File` | Default file-based LSN persistence |

## License

MIT