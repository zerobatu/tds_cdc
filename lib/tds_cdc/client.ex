defmodule TdsCdc.Client do
  @moduledoc """
  GenServer that manages the connection to SQL Server and polls for CDC changes.

  The client maintains a TDS connection, tracks LSN positions for each
  capture instance, and publishes changes to subscribers via Elixir's
  `Registry` and `Phoenix.PubSub`-style message passing.
  """

  use GenServer

  alias TdsCdc.Capture

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
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
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
      {:reply, :ok, %{state | subscribers: subscribers}}
    else
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
        lsn_positions = initialize_lsn_positions(conn, state.capture_instances)
        timer_ref = schedule_poll(state.poll_interval)

        {:noreply, %{state | conn: conn, lsn_positions: lsn_positions, timer_ref: timer_ref}}

      {:error, _reason} ->
        Process.send_after(self(), :connect, 5_000)
        {:noreply, state}
    end
  end

  def handle_info(:poll, %{conn: conn} = state) when not is_nil(conn) do
    state = poll_changes(state, conn)
    timer_ref = schedule_poll(state.poll_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info(:poll, state) do
    send(self(), :connect)
    timer_ref = schedule_poll(state.poll_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    subscribers =
      Map.new(state.subscribers, fn {ci, pids} ->
        {ci, List.delete(pids, pid)}
      end)

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info({:tds_disconnected, _conn_pid}, state) do
    if state.conn, do: GenServer.stop(state.conn)
    send(self(), :connect)
    {:noreply, %{state | conn: nil, timer_ref: nil}}
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

  defp initialize_lsn_positions(conn, capture_instances) do
    Enum.reduce(capture_instances, %{}, fn ci, acc ->
      case Capture.get_min_lsn(conn, ci) do
        {:ok, lsn} -> Map.put(acc, ci, lsn)
        {:error, _} -> acc
      end
    end)
  end

  defp poll_changes(state, conn) do
    Enum.reduce(state.capture_instances, state, fn ci, acc ->
      case Map.get(acc.lsn_positions, ci) do
        nil ->
          acc

        from_lsn ->
          case Capture.fetch_changes(conn, ci, from_lsn) do
            {:ok, []} ->
              acc

            {:ok, changes} ->
              publish_changes(ci, changes, acc.subscribers)
              last_lsn = extract_last_lsn(changes)
              put_in(acc.lsn_positions[ci], last_lsn)

            {:error, _reason} ->
              acc
          end
      end
    end)
  end

  defp publish_changes(capture_instance, changes, subscribers) do
    subscribers_for_ci = Map.get(subscribers, capture_instance, [])

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