defmodule TdsCdc do
  @moduledoc """
  Change Data Capture for SQL Server databases using the TDS protocol.

  TdsCdc allows you to capture row-level changes (INSERT, UPDATE, DELETE)
  from SQL Server tables that have CDC enabled. It polls the CDC change
  tables on a configurable interval and publishes changes to subscribers.

  ## Usage

      # Start a CDC client
      {:ok, pid} = TdsCdc.start_link(
        conn: [hostname: "localhost", username: "sa", password: "pass", database: "mydb"],
        capture_instances: ["dbo_Users"],
        poll_interval: 1_000
      )

      # Subscribe to changes
      TdsCdc.subscribe("dbo_Users")

      # Changes will be sent as messages:
      #   {:tds_cdc_change, "dbo_Users", %TdsCdc.Change{...}}

  ## Gap detection

  If a subscriber falls behind and SQL Server's CDC retention has purged
  old change data, TdsCdc will detect the gap and send a
  `{:tds_cdc_gap_detected, capture_instance, old_lsn, min_lsn}` message
  to all subscribers before resetting the LSN position to the current
  minimum. This allows applications to react to potential data loss.
  """

  alias TdsCdc.{Capture, Client}

  @type conn_opts :: keyword()
  @type start_opts :: [
          conn: conn_opts(),
          capture_instances: [String.t()],
          poll_interval: non_neg_integer()
        ]

  @doc """
  Starts a CDC client process linked to the calling process.

  ## Options

    * `:conn` - TDS connection options (required). See `Tds` module for details.
    * `:capture_instances` - List of CDC capture instance names to track (required).
    * `:poll_interval` - Interval in ms to poll for changes (default: 1000).

  ## Examples

      {:ok, pid} = TdsCdc.start_link(
        conn: [hostname: "localhost", username: "sa", password: "pass", database: "mydb"],
        capture_instances: ["dbo_Users", "dbo_Orders"]
      )
  """
  @spec start_link(start_opts()) :: GenServer.on_start()
  defdelegate start_link(opts), to: Client

  @doc """
  Starts a CDC client as part of a supervision tree.
  """
  @spec start_link(start_opts(), GenServer.server()) :: GenServer.on_start()
  defdelegate start_link(opts, name), to: Client

  @doc """
  Subscribes the calling process to change events for the given capture instance.

  The calling process will receive messages of the form:
      {:tds_cdc_change, capture_instance, %Change{}}

  ## Examples

      TdsCdc.subscribe("dbo_Users")
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  defdelegate subscribe(capture_instance), to: Client

  @doc """
  Unsubscribes the calling process from change events for the given capture instance.
  """
  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  defdelegate unsubscribe(capture_instance), to: Client

  @doc """
  Returns the current LSN position for the given capture instance.
  """
  @spec current_lsn(String.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate current_lsn(capture_instance), to: Client

  @doc """
  Returns the list of active capture instances being tracked.
  """
  @spec capture_instances() :: [String.t()]
  defdelegate capture_instances(), to: Client

  @doc """
  Stops the CDC client.
  """
  @spec stop(GenServer.server()) :: :ok
  defdelegate stop(server \\ __MODULE__), to: Client

  @doc """
  Checks if CDC is enabled on the database for the given connection.

  Returns `{:ok, true}` if CDC is enabled, `{:ok, false}` if not,
  or `{:error, reason}` if the query fails.

  ## Examples

      {:ok, conn} = Tds.start_link(conn_opts)
      {:ok, true} = TdsCdc.cdc_enabled?(conn)
  """
  @spec cdc_enabled?(GenServer.server()) :: {:ok, boolean()} | {:error, term()}
  def cdc_enabled?(conn) do
    query = Capture.cdc_enabled_query()

    case Tds.query(conn, query, []) do
      {:ok, %{rows: [_ | _]}} -> {:ok, true}
      {:ok, %{rows: []}} -> {:ok, false}
      {:ok, %{rows: nil}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists all CDC capture instances available in the database for the given connection.

  Returns `{:ok, list}` with the capture instance names, or `{:error, reason}`.

  ## Examples

      {:ok, conn} = Tds.start_link(conn_opts)
      {:ok, instances} = TdsCdc.list_capture_instances(conn)
      # => {:ok, ["dbo_users", "dbo_orders"]}
  """
  @spec list_capture_instances(GenServer.server()) :: {:ok, [String.t()]} | {:error, term()}
  def list_capture_instances(conn) do
    query = Capture.list_capture_instances_query()

    case Tds.query(conn, query, []) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        {:ok, Enum.map(rows, fn [ci] -> ci end)}

      {:ok, %{rows: nil}} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Waits until the CDC client has initialized its LSN positions and is ready
  to receive subscriptions, or until the timeout expires.

  Returns `:ok` if the client is ready, or `{:error, :timeout}` if the
  timeout expires before the client initializes.

  ## Options

    * `:timeout` - Maximum time to wait in ms (default: 5000).
    * `:capture_instance` - Which capture instance to check (default: checks the first one).

  ## Examples

      {:ok, pid} = TdsCdc.start_link(conn: conn_opts, capture_instances: ["dbo_users"])
      :ok = TdsCdc.wait_for_ready(timeout: 10_000)
      TdsCdc.subscribe("dbo_users")
  """
  @spec wait_for_ready(keyword()) :: :ok | {:error, :timeout}
  def wait_for_ready(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    ci = Keyword.get(opts, :capture_instance)
    wait_for_ready_loop(ci, timeout)
  end

  defp wait_for_ready_loop(_ci, remaining) when remaining <= 0 do
    {:error, :timeout}
  end

  defp wait_for_ready_loop(nil, remaining) do
    case Client.capture_instances() do
      [] ->
        Process.sleep(100)
        wait_for_ready_loop(nil, remaining - 100)

      [first | _] ->
        wait_for_ready_loop(first, remaining)
    end
  end

  defp wait_for_ready_loop(ci, remaining) do
    case Client.current_lsn(ci) do
      {:ok, _lsn} -> :ok
      {:error, :not_found} ->
        Process.sleep(100)
        wait_for_ready_loop(ci, remaining - 100)
    end
  end
end