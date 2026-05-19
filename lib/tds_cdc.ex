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
  """

  alias TdsCdc.Client

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
end