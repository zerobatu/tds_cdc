defmodule TdsCdc.Connection do
  @moduledoc """
  Behaviour for database connection adapters used by TdsCdc.

  This allows TdsCdc to work with different connection backends:

    * `TdsCdc.Connection.Tds` - Direct TDS connection pool (default)
    * `TdsCdc.Connection.Ecto` - Uses an existing Ecto.Repo

  ## Example with direct TDS connection

      {:ok, pid} = TdsCdc.start_link(
        conn: [hostname: "localhost", username: "sa", password: "pass", database: "mydb"],
        capture_instances: ["dbo_users"]
      )

  ## Example with Ecto.Repo

      {:ok, pid} = TdsCdc.start_link(
        repo: MyApp.Repo,
        capture_instances: ["dbo_users"]
      )
  """

  @type query_result :: {:ok, %{rows: list() | nil, columns: list() | nil}} | {:error, term()}

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback query(conn :: term, String.t(), list()) :: query_result()
  @callback stop(conn :: term) :: :ok | {:error, term()}
end