defmodule TdsCdc.Client do
  @moduledoc """
  GenServer that manages the connection to SQL Server and polls for CDC changes.

  The client maintains a TDS connection, tracks LSN positions for each
  capture instance, and publishes changes to subscribers via Elixir's
  `Registry` and `Phoenix.PubSub`-style message passing.
  """

  use GenServer

  require Logger

  alias TdsCdc.{Capture, Lsn}

  @default_poll_interval 1_000

  defstruct [
    :conn,
    :conn_opts,
    capture_instances: [],
    poll_interval: @default_poll_interval,
    lsn_positions: %{},
    subscribers: %{},
    timer_ref: nil
  ]

  @type state :: %__MODULE__{}

  @doc """
  Starts a CDC client linked to the calling process.
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
  Returns the list of capture instances being tracked.
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
    conn_opts = Keyword.fetch!(opts, :conn)
    capture_instances = Keyword.get(opts, :capture_instances, [])
    poll_interval = Keyword.get(opts, :poll_interval, @default_poll_interval)

    state = %__MODULE__{
      conn_opts: conn_opts,
      capture_instances: capture_instances,
      poll_interval: poll_interval
    }

    send(self(), :connect)

    {:ok, state}
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
  def handle_info(:connect, state) do
    case Tds.start_link(state.conn_opts) do
      {:ok, conn} ->
        Logger.info("Connected to SQL Server")
        lsn_positions = initialize_lsn_positions(conn, state.capture_instances)
        timer_ref = schedule_poll(state.poll_interval)

        state = %{state | conn: conn, lsn_positions: lsn_positions, timer_ref: timer_ref}
        Logger.info("LSN positions initialized: #{inspect_lsn_positions(lsn_positions)}")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Failed to connect to SQL Server: #{inspect(reason)}. Retrying in 5s...")
        Process.send_after(self(), :connect, 5_000)
        {:noreply, state}
    end
  end

  def handle_info(:poll, %{conn: conn} = state) when not is_nil(conn) do
    Logger.debug("Poll cycle started for #{inspect(state.capture_instances)}")
    state = poll_changes(state, conn)
    timer_ref = schedule_poll(state.poll_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info(:poll, state) do
    Logger.warning("Poll triggered but no connection. Reconnecting...")
    send(self(), :connect)
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

  def handle_info({:tds_disconnected, _conn_pid}, state) do
    Logger.warning("TDS connection lost. Reconnecting...")
    if state.conn, do: GenServer.stop(state.conn)
    send(self(), :connect)
    {:noreply, %{state | conn: nil, timer_ref: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    if state.conn, do: GenServer.stop(state.conn)
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

  defp initialize_lsn_positions(conn, capture_instances) do
    Enum.reduce(capture_instances, %{}, fn ci, acc ->
      case Capture.get_min_lsn(conn, ci) do
        {:ok, lsn} ->
          Logger.info("Initialized LSN for #{ci}: #{Lsn.to_hex(lsn)}")
          Map.put(acc, ci, lsn)

        {:error, reason} ->
          Logger.warning("Failed to get min LSN for #{ci}: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp poll_changes(state, conn) do
    Enum.reduce(state.capture_instances, state, fn ci, acc ->
      case Map.get(acc.lsn_positions, ci) do
        nil ->
          Logger.warning("No LSN position for #{ci}, skipping")
          acc

        from_lsn ->
          with {:ok, min_lsn} <- Capture.get_min_lsn(conn, ci),
               :lt <- Lsn.compare(from_lsn, min_lsn) do
            publish_gap_detected(ci, from_lsn, min_lsn, acc.subscribers)
            acc = put_in(acc.lsn_positions[ci], min_lsn)
            fetch_and_publish(conn, ci, min_lsn, acc)
          else
            {:error, reason} ->
              Logger.warning("Failed to get min LSN for #{ci}: #{inspect(reason)}")
              fetch_and_publish(conn, ci, from_lsn, acc)

            _ ->
              fetch_and_publish(conn, ci, from_lsn, acc)
          end
      end
    end)
  end

  defp fetch_and_publish(conn, ci, from_lsn, acc) do
    case Capture.fetch_changes(conn, ci, from_lsn) do
      {:ok, []} ->
        acc

      {:ok, changes} ->
        Logger.info("Fetched #{length(changes)} change(s) for #{ci}")
        publish_changes(ci, changes, acc.subscribers)
        case extract_last_lsn(changes) do
          nil -> acc
          last_lsn -> put_in(acc.lsn_positions[ci], last_lsn)
        end

      {:error, reason} ->
        Logger.warning("Failed to fetch changes for #{ci}: #{inspect(reason)}")
        acc
    end
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