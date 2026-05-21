defmodule TdsCdc.Connection.Tds do
  @moduledoc """
  Connection adapter that uses the `tds` library directly with a connection pool.

  This is the default adapter when using `conn:` options.

  ## Options

  All options are forwarded to `Tds.start_link/1`, plus:

    * `:pool_size` - Number of connections in the pool (default: 5)
    * `:ownership_timeout` - Maximum time a connection can be checked out (default: 30_000ms)

  ## Example

      TdsCdc.start_link(
        conn: [hostname: "localhost", username: "sa", password: "pass", database: "mydb"],
        capture_instances: ["dbo_users"]
      )
  """

  @behaviour TdsCdc.Connection

  @default_pool_size 5
  @default_ownership_timeout 30_000

  @impl true
  def start_link(opts) do
    opts =
      opts
      |> Keyword.put_new(:pool_size, @default_pool_size)
      |> Keyword.put_new(:ownership_timeout, @default_ownership_timeout)

    Tds.start_link(opts)
  end

  @impl true
  def query(conn, sql, params) do
    case Tds.query(conn, sql, params) do
      {:ok, result} -> {:ok, normalize_result(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def stop(conn) do
    GenServer.stop(conn, :normal)
  end

  defp normalize_result(%{rows: rows, columns: columns}) do
    %{rows: rows, columns: columns}
  end
end