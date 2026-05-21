defmodule TdsCdc.Connection.Ecto do
  @moduledoc """
  Connection adapter that uses an existing Ecto.Repo for database queries.

  This allows TdsCdc to share the connection pool with the rest of the
  application, avoiding the need for a separate TDS connection.

  ## Requirements

  The repo must be configured with the `tds_ecto` adapter and already started
  as part of the application's supervision tree.

  ## Example

      # In your application supervision tree:
      children = [
        MyApp.Repo,
        {TdsCdc.Client, repo: MyApp.Repo, capture_instances: ["dbo_users"]}
      ]

      # Or at runtime:
      TdsCdc.start_link(
        repo: MyApp.Repo,
        capture_instances: ["dbo_users"]
      )
  """

  @behaviour TdsCdc.Connection

  @impl true
  def start_link(_opts) do
    {:ok, :ecto_connection}
  end

  @impl true
  def query(repo, sql, params) do
    result =
      try do
        apply(Ecto.Adapters.SQL, :query, [repo, sql, params])
      rescue
        UndefinedFunctionError ->
          {:error, "Ecto is not available. Add {:ecto_sql, \"~> 3.0\"} to your dependencies."}
      end

    case result do
      {:ok, resp} -> {:ok, normalize_result(resp)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def stop(_conn) do
    :ok
  end

  defp normalize_result(%{rows: rows, columns: columns, num_rows: _num_rows}) do
    %{rows: rows, columns: columns}
  end

  defp normalize_result(%{rows: rows, columns: columns}) do
    %{rows: rows, columns: columns}
  end
end