defmodule TdsCdc.Capture do
  @moduledoc """
  Handles querying SQL Server CDC tables and parsing the results.

  This module is responsible for:
  - Checking if CDC is enabled on the database
  - Listing available capture instances
  - Fetching changes from CDC tables
  """

  alias TdsCdc.{Change, Lsn}

  @doc """
  Returns the SQL query to check if CDC is enabled on the current database.
  """
  @spec cdc_enabled_query() :: String.t()
  def cdc_enabled_query do
    "SELECT name FROM sys.databases WHERE is_cdc_enabled = 1 AND database_id = DB_ID()"
  end

  @doc """
  Returns the SQL query to list all capture instances in the current database.
  """
  @spec list_capture_instances_query() :: String.t()
  def list_capture_instances_query do
    "SELECT capture_instance FROM cdc.change_tables"
  end

  @doc """
  Returns the SQL query to check if a specific capture instance exists.
  """
  @spec capture_instance_exists_query(String.t()) :: String.t()
  def capture_instance_exists_query(capture_instance) do
    "SELECT COUNT(*) FROM cdc.change_tables WHERE capture_instance = '#{capture_instance}'"
  end

  @doc """
  Fetches all changes from a capture instance since the given LSN.

  Returns `{:ok, changes}` with a list of `%Change{}` structs, or `{:error, reason}`.
  The `from_lsn` should be a binary LSN value; changes after this LSN will be returned.
  """
  @spec fetch_changes(GenServer.server(), String.t(), binary()) ::
          {:ok, [Change.t()]} | {:error, term()}
  def fetch_changes(conn, capture_instance, from_lsn) do
    query = Lsn.changes_since_query(capture_instance, from_lsn)

    case Tds.query(conn, query, []) do
      {:ok, %{rows: rows, columns: columns}} ->
        changes =
          rows
          |> Enum.map(&row_to_map(columns, &1))
          |> Enum.map(&Change.from_row(capture_instance, &1))

        {:ok, changes}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the minimum LSN for a capture instance, which represents the earliest
  available change data.
  """
  @spec get_min_lsn(GenServer.server(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def get_min_lsn(conn, capture_instance) do
    query = Lsn.min_lsn_query(capture_instance)

    case Tds.query(conn, query, []) do
      {:ok, %{rows: [[lsn]]}} -> {:ok, lsn}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets the maximum LSN from the transaction log.
  """
  @spec get_max_lsn(GenServer.server()) :: {:ok, binary()} | {:error, term()}
  def get_max_lsn(conn) do
    query = Lsn.max_lsn_query()

    case Tds.query(conn, query, []) do
      {:ok, %{rows: [[lsn]]}} -> {:ok, lsn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row_to_map(columns, row) do
    columns
    |> Enum.zip(row)
    |> Map.new(fn {col, val} -> {col, val} end)
  end
end