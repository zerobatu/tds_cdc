defmodule TdsCdc.Listener do
  @moduledoc """
  Behaviour for structured CDC event listeners.

  Use this module to create a listener that follows a defined workflow,
  with mandatory handling of each change operation type via callbacks.

  ## Usage

      defmodule MyApp.CdcListener do
        use TdsCdc.Listener

        @impl true
        def on_init(_opts) do
          {:ok, %{inserts: 0, updates: 0, deletes: 0}}
        end

        @impl true
        def on_insert(change, state) do
          IO.puts("New record: \#{inspect(change.data)}")
          {:ok, %{state | inserts: state.inserts + 1}}
        end

        @impl true
        def on_update(change, state) do
          IO.puts("Updated: \#{inspect(change.data)}")
          {:ok, %{state | updates: state.updates + 1}}
        end

        @impl true
        def on_delete(change, state) do
          IO.puts("Deleted: \#{inspect(change.data)}")
          {:ok, %{state | deletes: state.deletes + 1}}
        end

        @impl true
        def on_gap(ci, old_lsn, min_lsn, state) do
          Logger.warning("Gap detected in \#{ci}")
          {:ok, state}
        end
      end

  Then add to your supervision tree:

      children = [
        {MyApp.CdcListener, conn: [hostname: "localhost", ...], capture_instances: ["dbo_users"]}
      ]

  Or start manually:

      {:ok, pid} = MyApp.CdcListener.start_link(
        conn: [hostname: "localhost", username: "sa", password: "pass", database: "mydb"],
        capture_instances: ["dbo_users"]
      )

  ## Connection options

  Same as `TdsCdc.Client.start_link/1`:

    * `:conn` - Direct TDS connection options
    * `:repo` - An existing Ecto.Repo module
    * `:capture_instances` - List of CDC capture instance names (required)
    * `:poll_interval` - Polling interval in ms (default: 1000)
    * `:name` - GenServer name registration (default: module name)

  ## Callbacks

  All callbacks are optional and have default implementations.
  Returning `{:ok, state}` continues the listener.
  Returning `{:stop, reason}` stops the listener process.
  """

  alias TdsCdc.Change

  @type state :: term()
  @type reason :: term()

  @doc """
  Called when the listener starts, after CDC subscription is established.

  Use this to initialize your listener state. Receives the full options
  keyword list passed to `start_link/1`.

  Return `{:ok, state}` to continue, or `{:stop, reason}` to stop.
  """
  @callback on_init(opts :: keyword()) :: {:ok, state()} | {:stop, reason()}

  @doc """
  Called when an INSERT change is received.

  The `change` argument is a `%TdsCdc.Change{}` struct with `operation: :insert`.
  """
  @callback on_insert(change :: Change.t(), state :: state()) :: {:ok, state()} | {:stop, reason()}

  @doc """
  Called when an UPDATE change is received.

  The `change` argument is a `%TdsCdc.Change{}` struct with `operation: :update`.
  Note: CDC produces two rows per update (before-image with operation=3, after-image
  with operation=4). Both are mapped to `:update` and delivered separately.
  """
  @callback on_update(change :: Change.t(), state :: state()) :: {:ok, state()} | {:stop, reason()}

  @doc """
  Called when a DELETE change is received.

  The `change` argument is a `%TdsCdc.Change{}` struct with `operation: :delete`.
  """
  @callback on_delete(change :: Change.t(), state :: state()) :: {:ok, state()} | {:stop, reason()}

  @doc """
  Called when a CDC gap is detected.

  This happens when the stored LSN position falls behind the minimum available
  LSN in CDC tables, meaning some changes were lost due to retention cleanup.

  - `capture_instance` - The capture instance where the gap was detected.
  - `old_lsn` - The LSN that was stored (now too old).
  - `min_lsn` - The new minimum LSN (position will be reset to this).
  """
  @callback on_gap(
              capture_instance :: String.t(),
              old_lsn :: binary(),
              min_lsn :: binary(),
              state :: state()
            ) :: {:ok, state()} | {:stop, reason()}

  @doc """
  Called when the listener process is about to terminate.

  Use this for cleanup. The return value is ignored.
  """
  @callback on_terminate(reason :: term(), state :: term()) :: term()

  @optional_callbacks on_init: 1, on_insert: 2, on_update: 2, on_delete: 2, on_gap: 4, on_terminate: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour TdsCdc.Listener
      use GenServer

      require Logger

      alias TdsCdc.Listener

      def start_link(opts \\ []) do
        name = Keyword.get(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker
        }
      end

      @impl GenServer
      def init(opts) do
        capture_instances = Keyword.fetch!(opts, :capture_instances)
        cdc_client_name = Module.concat(__MODULE__, CdcClient)

        cdc_opts =
          opts
          |> Keyword.take([:conn, :repo, :capture_instances, :poll_interval])
          |> Keyword.put(:name, cdc_client_name)

        case TdsCdc.Client.start_link(cdc_opts) do
          {:ok, cdc_pid} ->
            case TdsCdc.wait_for_ready(
                   timeout: 10_000,
                   capture_instance: hd(capture_instances)
                 ) do
              :ok ->
                Logger.info("[#{__MODULE__}] CDC client ready")

              {:error, :timeout} ->
                Logger.warning("[#{__MODULE__}] CDC client not ready after 10s, continuing anyway")
            end

            Enum.each(capture_instances, fn ci ->
              TdsCdc.subscribe(ci)
            end)

            case Listener.__dispatch_on_init(__MODULE__, opts) do
              {:ok, user_state} ->
                {:ok,
                 %{
                   cdc_client_name: cdc_client_name,
                   cdc_pid: cdc_pid,
                   capture_instances: capture_instances,
                   owns_cdc?: true,
                   user_state: user_state
                 }}

              {:stop, reason} ->
                TdsCdc.Client.stop(cdc_client_name)
                {:stop, reason}
            end

          {:error, reason} ->
            {:stop, reason}
        end
      end

      @impl GenServer
      def handle_info({:tds_cdc_change, capture_instance, %Change{} = change}, state) do
        Listener.__dispatch_change(__MODULE__, change, state)
      end

      @impl GenServer
      def handle_info({:tds_cdc_gap_detected, capture_instance, old_lsn, min_lsn}, state) do
        Listener.__dispatch_gap(__MODULE__, capture_instance, old_lsn, min_lsn, state)
      end

      @impl GenServer
      def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
        if pid == state.cdc_pid do
          Logger.error("[#{__MODULE__}] CDC client process died: #{inspect(reason)}")
          {:stop, {:cdc_client_died, reason}, state}
        else
          {:noreply, state}
        end
      end

      @impl GenServer
      def handle_info(msg, state) do
        Logger.debug("[#{__MODULE__}] Unexpected message: #{inspect(msg)}")
        {:noreply, state}
      end

      @impl GenServer
      def terminate(reason, state) do
        Listener.__dispatch_terminate(__MODULE__, reason, state)
      end

      def on_init(_opts), do: {:ok, %{}}
      def on_insert(_change, state), do: {:ok, state}
      def on_update(_change, state), do: {:ok, state}
      def on_delete(_change, state), do: {:ok, state}

      def on_gap(capture_instance, old_lsn, min_lsn, state) do
        Logger.warning(
          "[#{__MODULE__}] CDC gap detected for #{capture_instance}: " <>
            "stored LSN #{TdsCdc.Lsn.to_hex(old_lsn)} behind min LSN #{TdsCdc.Lsn.to_hex(min_lsn)}"
        )

        {:ok, state}
      end

      def on_terminate(_reason, _state), do: :ok

      defoverridable TdsCdc.Listener
    end
  end

  @doc false
  def __dispatch_on_init(module, opts) do
    module.on_init(opts)
  end

  require Logger

  @doc false
  def __dispatch_change(module, change, state) do
    callback =
      case change.operation do
        :insert -> :on_insert
        :update -> :on_update
        :delete -> :on_delete
        _ -> nil
      end

    if callback do
      case apply(module, callback, [change, state.user_state]) do
        {:ok, new_user_state} ->
          {:noreply, %{state | user_state: new_user_state}}

        {:stop, reason} ->
          {:stop, reason, state}
      end
    else
      Logger.warning("[#{module}] Unknown operation: #{inspect(change.operation)}")
      {:noreply, state}
    end
  end

  @doc false
  def __dispatch_gap(module, capture_instance, old_lsn, min_lsn, state) do
    case module.on_gap(capture_instance, old_lsn, min_lsn, state.user_state) do
      {:ok, new_user_state} ->
        {:noreply, %{state | user_state: new_user_state}}

      {:stop, reason} ->
        {:stop, reason, state}
    end
  end

  @doc false
  def __dispatch_terminate(module, reason, state) do
    if state.owns_cdc? and state.cdc_client_name do
      TdsCdc.Client.stop(state.cdc_client_name)
    end

    module.on_terminate(reason, state.user_state)
  end
end