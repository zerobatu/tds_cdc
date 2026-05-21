defmodule TdsCdc.Client do
  @moduledoc """
  GenServer that manages the connection to SQL Server and polls for CDC changes.

  The client maintains a database connection (either via TDS directly or through
  an Ecto.Repo), tracks LSN positions for each capture instance, and publishes
  changes to subscribers via message passing.

  ## Connection options

  You can use either:

    * `:conn` - Direct TDS connection options (see `Tds.start_link/1`)
    * `:repo` - An existing Ecto.Repo module to use for queries

  When using `:repo`, the Repo must already be started as part of your
  application's supervision tree. TdsCdc will not start or stop the Repo.
  """

  use GenServer

  require Logger

  alias TdsCdc.{Change, Connection, Lsn}

  @default_poll_interval 1_000
  @connect_retry_interval 2_000

  defstruct [
    :conn,
    :adapter,
    conn_opts: nil,
    repo: nil,
    capture_instances: [],
    poll_interval: @default_poll_interval,
    lsn_positions: %{},
    subscribers: %{},
    timer_ref: nil,
    owns_conn?: false
  ]

  @type state :: %__MODULE__{}

  @doc """
  Starts a CDC client linked to the calling process.

  ## Options

    * `:conn` - TDS connection options. Mutually exclusive with `:repo`.
    * `:repo` - An Ecto.Repo module. Mutually exclusive with `:conn`.
    * `:capture_instances` - List of CDC capture instance names to track (required).
    * `:poll_interval` - Interval in ms to poll for changes (default: 1000).
    * `:name` - GenServer name registration (default: `TdsCdc.Client`).

  ## Examples

      # With TDS connection
      {:ok, pid} = TdsCdc.start_link(
        conn: [hostname: "localhost", username: "sa", password: "pass", database: "mydb"],
        capture_instances: ["dbo_users"]
      )

      # With Ecto.Repo
      {:ok, pid} = TdsCdc.start_link(
        repo: MyApp.Repo,
        capture_instances: ["dbo_users"]
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @spec start_link(keyword(), GenServer.server()) :: GenServer.on_start()
  def start_link(opts, name) do
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  Subscribes the calling process to changes for a capture instance.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(capture_instance) do
    GenServer.call(__MODULE__, {:subscribe, capture_instance, self()})
  end

  @spec subscribe(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def subscribe(server, capture_instance) do
    GenServer.call(server, {:subscribe, capture_instance, self()})
  end

  @doc """
  Unsubscribes the calling process from changes for a capture instance.
  """
  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(capture_instance) do
    GenServer.call(__MODULE__, {:unsubscribe, capture_instance, self()})
  end

  @spec unsubscribe(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(server, capture_instance) do
    GenServer.call(server, {:unsubscribe, capture_instance, self()})
  end

  @doc """
  Returns the current LSN position for a capture instance.
  """
  @spec current_lsn(String.t()) :: {:ok, String.t()} | {:error, term()}
  def current_lsn(capture_instance) do
    GenServer.call(__MODULE__, {:current_lsn, capture_instance})
  end

  @spec current_lsn(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def current_lsn(server, capture_instance) do
    GenServer.call(server, {:current_lsn, capture_instance})
  end

  @doc """
  Returns the list of active capture instances being tracked.
  """
  @spec capture_instances() :: [String.t()]
  def capture_instances do
    GenServer.call(__MODULE__, :capture_instances)
  end

  @spec capture_instances(GenServer.server()) :: [String.t()]
  def capture_instances(server) do
    GenServer.call(server, :capture_instances)
  end

  @doc """
  Stops the CDC client.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server \\ __MODULE__) do
    GenServer.stop(server, :normal)
  end

  @impl true
  def init(opts) do
    conn_opts = Keyword.get(opts, :conn)
    repo = Keyword.get(opts, :repo)
    capture_instances = Keyword.get(opts, :capture_instances, [])
    poll_interval = Keyword.get(opts, :poll_interval, @default_poll_interval)

    case {conn_opts, repo} do
      {nil, nil} ->
        raise ArgumentError, "either :conn or :repo must be provided"

      {conn_opts, _} when is_list(conn_opts) ->
        {adapter, enriched_opts} = {Connection.Tds, enrich_conn_opts(conn_opts)}
        conn = connect_with_retry(adapter, enriched_opts)

        state = %__MODULE__{
          adapter: adapter,
          conn: conn,
          conn_opts: enriched_opts,
          capture_instances: capture_instances,
          poll_interval: poll_interval,
          owns_conn?: true
        }

        send(self(), :init_lsn)
        {:ok, state}

      {_, repo} when is_atom(repo) ->
        state = %__MODULE__{
          adapter: Connection.Ecto,
          repo: repo,
          conn: repo,
          capture_instances: capture_instances,
          poll_interval: poll_interval,
          owns_conn?: false
        }

        send(self(), :init_lsn)
        {:ok, state}
    end
  end

  defp enrich_conn_opts(opts) do
    opts
    |> Keyword.put_new(:timeout, 30_000)
    |> Keyword.put_new(:pool_size, 5)
    |> Keyword.put_new(:ownership_timeout, 30_000)
  end

  defp connect_with_retry(adapter, opts) do
    case adapter.start_link(opts) do
      {:ok, conn} ->
        Logger.info("Connected to SQL Server")
        conn

      {:error, reason} ->
        Logger.warning("Failed to connect to SQL Server: #{inspect(reason)}. Retrying in #{@connect_retry_interval}ms...")
        Process.sleep(@connect_retry_interval)
        connect_with_retry(adapter, opts)
    end
  end

  @impl true
  def handle_call({:subscribe, capture_instance, pid}, _from, state) do
    if capture_instance in state.capture_instances do
      subscribers = Map.update(state.subscribers, capture_instance, [pid], &[pid | &1])
      Process.monitor(pid)
      Logger.info("Process #{inspect(pid)} subscribed to #{capture_instance}")
      {:reply, :ok, %{state | subscribers: subscribers}}
    else
      Logger.warning("Subscribe failed: capture instance #{capture_instance} not found")
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:unsubscribe, capture_instance, pid}, _from, state) do
    subscribers =
      Map.update(state.subscribers, capture_instance, [], &List.delete(&1, pid))

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:current_lsn, capture_instance}, _from, state) do
    case Map.get(state.lsn_positions, capture_instance) do
      nil -> {:reply, {:error, :not_found}, state}
      lsn -> {:reply, {:ok, lsn}, state}
    end
  end

  def handle_call(:capture_instances, _from, state) do
    {:reply, state.capture_instances, state}
  end

  @impl true
  def handle_info(:init_lsn, state) do
    lsn_positions = initialize_lsn_positions(state)
    timer_ref = schedule_poll(state.poll_interval)

    state = %{state | lsn_positions: lsn_positions, timer_ref: timer_ref}
    Logger.info("LSN positions initialized: #{inspect_lsn_positions(lsn_positions)}")
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    case Connection.Tds.start_link(state.conn_opts) do
      {:ok, conn} ->
        Logger.info("Reconnected to SQL Server")
        lsn_positions = initialize_lsn_positions(state)
        timer_ref = schedule_poll(state.poll_interval)

        state = %{state | conn: conn, lsn_positions: lsn_positions, timer_ref: timer_ref, owns_conn?: true}
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Failed to reconnect: #{inspect(reason)}. Retrying in 5s...")
        Process.send_after(self(), :reconnect, 5_000)
        {:noreply, state}
    end
  end

  def handle_info(:poll, state) do
    state = poll_changes(state)
    timer_ref = schedule_poll(state.poll_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    Logger.info("Subscriber #{inspect(pid)} exited, removing from lists")
    subscribers =
      Map.new(state.subscribers, fn {ci, pids} ->
        {ci, List.delete(pids, pid)}
      end)

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info({:tds_disconnected, _conn_pid}, %{owns_conn?: true} = state) do
    Logger.warning("TDS connection lost. Reconnecting...")
    if state.conn, do: Connection.Tds.stop(state.conn)
    send(self(), :reconnect)
    {:noreply, %{state | conn: nil, timer_ref: nil}}
  end

  def handle_info({:tds_disconnected, _conn_pid}, state) do
    Logger.warning("TDS connection lost (using repo, not managing connection)")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    if state.owns_conn? and state.conn, do: Connection.Tds.stop(state.conn)
    :ok
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp inspect_lsn_positions(positions) do
    positions
    |> Enum.map(fn {ci, lsn} -> "#{ci}: #{Lsn.to_hex(lsn)}" end)
    |> Enum.join(", ")
  end

  defp query(state, sql, params) do
    state.adapter.query(state.conn, sql, params)
  end

  defp initialize_lsn_positions(state) do
    Enum.reduce(state.capture_instances, %{}, fn ci, acc ->
      case query(state, Lsn.min_lsn_query(ci), []) do
        {:ok, %{rows: [[lsn]]}} ->
          Logger.info("Initialized LSN for #{ci}: #{Lsn.to_hex(lsn)}")
          Map.put(acc, ci, lsn)

        {:ok, _} ->
          Logger.warning("No LSN returned for #{ci}")
          acc

        {:error, reason} ->
          Logger.warning("Failed to get min LSN for #{ci}: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp poll_changes(state) do
    Enum.reduce(state.capture_instances, state, fn ci, acc ->
      case Map.get(acc.lsn_positions, ci) do
        nil ->
          Logger.warning("No LSN position for #{ci}, skipping")
          acc

        from_lsn ->
          with {:ok, min_lsn} <- get_min_lsn(acc, ci),
               :lt <- Lsn.compare(from_lsn, min_lsn) do
            publish_gap_detected(ci, from_lsn, min_lsn, acc.subscribers)
            acc = put_in(acc.lsn_positions[ci], min_lsn)
            fetch_and_publish(acc, ci, min_lsn)

          else
            {:error, reason} ->
              Logger.warning("Failed to get min LSN for #{ci}: #{inspect(reason)}")
              fetch_and_publish(acc, ci, from_lsn)

            _ ->
              fetch_and_publish(acc, ci, from_lsn)
          end
      end
    end)
  end

  defp get_min_lsn(state, ci) do
    case query(state, Lsn.min_lsn_query(ci), []) do
      {:ok, %{rows: [[lsn]]}} -> {:ok, lsn}
      {:ok, _} -> {:error, :no_result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_and_publish(state, ci, from_lsn) do
    with {:ok, max_lsn} <- get_max_lsn(state),
         true <- Lsn.compare(from_lsn, max_lsn) == :lt or {:ok, []},
         {:ok, inc_lsn} <- get_increment_lsn(state, from_lsn) do
      query = Lsn.all_changes_query(ci, inc_lsn, max_lsn)

      case query(state, query, []) do
        {:ok, %{rows: nil}} ->
          state

        {:ok, %{rows: rows, columns: columns}} when is_list(rows) and rows != [] ->
          changes =
            rows
            |> Enum.map(&row_to_map(columns, &1))
            |> Enum.map(&Change.from_row(ci, &1))

          Logger.info("Fetched #{length(changes)} change(s) for #{ci}")
          publish_changes(ci, changes, state.subscribers)

          case extract_last_lsn(changes) do
            nil -> state
            last_lsn -> put_in(state.lsn_positions[ci], last_lsn)
          end

        {:ok, _} ->
          state

        {:error, reason} ->
          Logger.warning("Failed to fetch changes for #{ci}: #{inspect(reason)}")
          state
      end
    else
      {:ok, []} -> state
      {:error, reason} ->
        Logger.warning("Failed to fetch changes for #{ci}: #{inspect(reason)}")
        state
    end
  end

  defp get_max_lsn(state) do
    case query(state, Lsn.max_lsn_query(), []) do
      {:ok, %{rows: [[lsn]]}} -> {:ok, lsn}
      {:ok, _} -> {:error, :no_result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_increment_lsn(state, from_lsn) do
    case query(state, Lsn.increment_lsn_query(from_lsn), []) do
      {:ok, %{rows: [[lsn]]}} -> {:ok, lsn}
      {:ok, _} -> {:error, :no_result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row_to_map(columns, row) do
    columns
    |> Enum.zip(row)
    |> Map.new(fn {col, val} -> {col, val} end)
  end

  defp publish_gap_detected(capture_instance, from_lsn, min_lsn, subscribers) do
    subscribers_for_ci = Map.get(subscribers, capture_instance, [])

    Enum.each(subscribers_for_ci, fn pid ->
      send(pid, {:tds_cdc_gap_detected, capture_instance, from_lsn, min_lsn})
    end)

    Logger.warning(
      "CDC gap detected for #{capture_instance}: stored LSN #{Lsn.to_hex(from_lsn)} " <>
        "is behind min LSN #{Lsn.to_hex(min_lsn)}. Resetting position. " <>
        "Some changes may have been lost due to CDC retention cleanup."
    )
  end

  defp publish_changes(capture_instance, changes, subscribers) do
    subscribers_for_ci = Map.get(subscribers, capture_instance, [])

    if subscribers_for_ci == [] do
      Logger.debug("No subscribers for #{capture_instance}, #{length(changes)} change(s) dropped")
    end

    Enum.each(subscribers_for_ci, fn pid ->
      Enum.each(changes, fn change ->
        send(pid, {:tds_cdc_change, capture_instance, change})
      end)
    end)
  end

  defp extract_last_lsn([]), do: nil

  defp extract_last_lsn(changes) do
    changes
    |> Enum.max_by(& &1.seqval, fn -> nil end)
    |> case do
      nil -> nil
      change -> change.lsn
    end
  end
end