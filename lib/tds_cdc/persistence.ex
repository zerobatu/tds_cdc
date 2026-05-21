defmodule TdsCdc.Persistence do
  @moduledoc """
  Behaviour for LSN position persistence.

  By default, `TdsCdc.Persistence.File` writes LSN positions to disk so they
  survive application restarts. You can implement this behaviour to store
  positions in a database, Redis, or any other backend.

  ## Example: custom persistence module

      defmodule MyApp.DbPersistence do
        @behaviour TdsCdc.Persistence

        @impl true
        def save_positions(_name, positions) do
          # Write positions to your database
          :ok
        end

        @impl true
        def load_positions(_name) do
          # Read positions from your database
          {:ok, %{}}  # or {:error, reason}
        end
      end

  Then pass it to the client:

      TdsCdc.start_link(
        conn: [...],
        capture_instances: ["dbo_users"],
        persistence: {MyApp.DbPersistence, []}
      )
  """

  @type positions :: %{String.t() => binary()}
  @type opts :: keyword()

  @doc """
  Saves the current LSN positions for all capture instances.

  - `name` is the client's registered name (atom).
  - `positions` is a map of capture instance name to LSN binary.
  """
  @callback save_positions(name :: atom(), positions :: positions()) :: :ok | {:error, term()}

  @doc """
  Loads the saved LSN positions.

  - `name` is the client's registered name (atom).

  Returns `{:ok, positions}` where positions is a map of capture instance
  name to LSN binary, or `{:error, reason}` if no positions are found.
  """
  @callback load_positions(name :: atom()) :: {:ok, positions()} | {:error, term()}
end