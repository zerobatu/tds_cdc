defmodule TdsCdc.Example do
  @moduledoc """
  Example demonstrating TdsCdc usage with SQL Server CDC.

  This script:
  1. Connects to SQL Server with CDC enabled
  2. Checks CDC status and lists capture instances
  3. Starts a CDC client and subscribes to change events
  4. Performs INSERT, UPDATE, and DELETE operations to generate changes
  5. Prints captured changes to stdout

  ## Usage

      mix run examples/docker/app/example.exs

  Or with custom connection settings (environment variables):

      TDS_HOST=localhost TDS_PORT=1433 mix run examples/docker/app/example.exs
  """

  alias TdsCdc.Change

  @conn_opts [
    hostname: System.get_env("TDS_HOST") || "localhost",
    port: String.to_integer(System.get_env("TDS_PORT") || "1433"),
    username: System.get_env("TDS_USERNAME") || "sa",
    password: System.get_env("TDS_PASSWORD") || "YourStrong!Passw0rd",
    database: System.get_env("TDS_DATABASE") || "cdc_test"
  ]

  @poll_interval 500

  def run do
    IO.puts """
    =========================================
      TdsCdc Example - SQL Server CDC Demo
    =========================================
    """

    IO.puts("Connecting to SQL Server at #{@conn_opts[:hostname]}:#{@conn_opts[:port]}...")

    {:ok, conn} = Tds.start_link(@conn_opts)
    IO.puts("Connected!")

    IO.puts("\nChecking CDC status...")
    case TdsCdc.cdc_enabled?(conn) do
      {:ok, true} -> IO.puts("  [OK] CDC is ENABLED")
      {:ok, false} -> IO.puts("  [!!] CDC is NOT enabled")
      {:error, reason} -> IO.puts("  [ERROR] #{inspect(reason)}")
    end

    IO.puts("\nListing available capture instances...")
    case TdsCdc.list_capture_instances(conn) do
      {:ok, instances} ->
        Enum.each(instances, fn ci -> IO.puts("  - #{ci}") end)

      {:error, reason} ->
        IO.puts("  [ERROR] #{inspect(reason)}")
    end

    GenServer.stop(conn)

    IO.puts("\nStarting CDC client...")
    {:ok, pid} = TdsCdc.start_link(
      conn: @conn_opts,
      capture_instances: ["dbo_users", "dbo_orders"],
      poll_interval: @poll_interval
    )
    IO.puts("CDC client started (PID: #{inspect(pid)})")

    IO.puts("\nWaiting for client to connect and initialize LSN positions...")
    case TdsCdc.wait_for_ready(timeout: 10_000, capture_instance: "dbo_users") do
      :ok ->
        IO.puts("  Client ready (LSN positions initialized)")

      {:error, :timeout} ->
        IO.puts("  [WARNING] Client not ready after 10s, continuing anyway...")
    end

    IO.puts("\nSubscribing to changes...")
    :ok = TdsCdc.subscribe("dbo_users")
    :ok = TdsCdc.subscribe("dbo_orders")
    IO.puts("Subscribed to dbo_users and dbo_orders")

    IO.puts("\n--- Listening for changes (press Ctrl+C to stop) ---\n")

    {:ok, insert_conn} = Tds.start_link(@conn_opts)
    spawn_changes(insert_conn)

    listen_for_changes()
  end

  defp spawn_changes(conn) do
    spawn(fn ->
      :timer.sleep(2_000)
      do_insert(conn)
      :timer.sleep(3_000)
      do_update(conn)
      :timer.sleep(3_000)
      do_delete(conn)
      :timer.sleep(3_000)
      do_insert(conn)
    end)
  end

  defp do_insert(conn) do
    IO.puts("\n>>> INSERT: Adding new user 'Dave'")

    case Tds.query(conn, "INSERT INTO dbo.users (name, email, age) VALUES (@1, @2, @3)", [
      %Tds.Parameter{name: "@1", value: "Dave"},
      %Tds.Parameter{name: "@2", value: "dave@example.com"},
      %Tds.Parameter{name: "@3", value: 28}
    ]) do
      {:ok, _} -> IO.puts("    INSERT succeeded")
      {:error, e} -> IO.puts("    INSERT failed: #{inspect(e)}")
    end
  end

  defp do_update(conn) do
    IO.puts(">>> UPDATE: Changing Alice's email")

    case Tds.query(conn, "UPDATE dbo.users SET email = @1 WHERE name = @2", [
      %Tds.Parameter{name: "@1", value: "alice_new@example.com"},
      %Tds.Parameter{name: "@2", value: "Alice"}
    ]) do
      {:ok, _} -> IO.puts("    UPDATE succeeded")
      {:error, e} -> IO.puts("    UPDATE failed: #{inspect(e)}")
    end
  end

  defp do_delete(conn) do
    IO.puts(">>> DELETE: Removing Bob")

    case Tds.query(conn, "DELETE FROM dbo.users WHERE name = @1", [
      %Tds.Parameter{name: "@1", value: "Bob"}
    ]) do
      {:ok, _} -> IO.puts("    DELETE succeeded")
      {:error, e} -> IO.puts("    DELETE failed: #{inspect(e)}")
    end
  end

  defp listen_for_changes do
    receive do
      {:tds_cdc_change, capture_instance, %Change{} = change} ->
        IO.puts """

        ┌───────────────────────────────────────────────────────────────────┐
        │  CDC Change Detected!                                             │
        ├───────────────────────────────────────────────────────────────────┤
        │  Instance:  #{String.pad_trailing(capture_instance, 30)}          │
        │  Operation: #{String.pad_trailing(inspect(change.operation), 30)} │
        │  Data:      #{String.pad_trailing(inspect(change.data), 30)}      │
        │  LSN:       #{String.pad_trailing(inspect(change.lsn), 30)}       │
        └───────────────────────────────────────────────────────────────────┘\
        """

        listen_for_changes()

      {:tds_cdc_gap_detected, capture_instance, old_lsn, min_lsn} ->
        IO.puts """

        ┌───────────────────────────────────────────────────────────────────┐
        │  CDC GAP Detected!                                                │
        ├───────────────────────────────────────────────────────────────────┤
        │  Instance:  #{String.pad_trailing(capture_instance, 30)}          │
        │  Old LSN:   #{String.pad_trailing(TdsCdc.Lsn.to_hex(old_lsn), 30)} │
        │  Min LSN:   #{String.pad_trailing(TdsCdc.Lsn.to_hex(min_lsn), 30)} │
        └───────────────────────────────────────────────────────────────────┘\
        """

        listen_for_changes()

      msg ->
        IO.puts("  [DEBUG] Received unexpected message: #{inspect(msg)}")
        listen_for_changes()
    after
      60_000 ->
        IO.puts("\nNo changes received in 60 seconds. Exiting.")
    end
  end
end

TdsCdc.Example.run()