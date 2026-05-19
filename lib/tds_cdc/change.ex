defmodule TdsCdc.Change do
  @moduledoc """
  Represents a single change event captured from SQL Server CDC.

  Each change contains the operation type, the row data after the change,
  and metadata about the change such as the LSN and transaction order.
  """

  @type operation :: :insert | :update | :delete

  @type t :: %__MODULE__{
          capture_instance: String.t(),
          operation: operation(),
          data: map(),
          lsn: String.t(),
          lsn_prev: String.t() | nil,
          seqval: String.t(),
          commit_lsn: String.t() | nil,
          transaction_order: non_neg_integer() | nil
        }

  @enforce_keys [:capture_instance, :operation, :data, :lsn, :seqval]
  defstruct [
    :capture_instance,
    :operation,
    :data,
    :lsn,
    :lsn_prev,
    :seqval,
    :commit_lsn,
    :transaction_order
  ]

  @doc """
  Parses a raw CDC row from SQL Server into a `%Change{}` struct.

  Expects a map with string keys as returned by `Tds` queries, including
  the standard CDC columns: `__$operation`, `__$start_lsn`, `__$seqval`,
  `__$update_mask`, and the tracked table columns.
  """
  @spec from_row(String.t(), map()) :: t()
  def from_row(capture_instance, row) do
    operation = parse_operation(row["__$operation"])

    data =
      row
      |> Map.drop(["__$operation", "__$start_lsn", "__$end_lsn", "__$seqval", "__$update_mask"])
      |> atomize_keys()

    %__MODULE__{
      capture_instance: capture_instance,
      operation: operation,
      data: data,
      lsn: row["__$start_lsn"],
      lsn_prev: row["__$end_lsn"],
      seqval: row["__$seqval"],
      commit_lsn: nil,
      transaction_order: nil
    }
  end

  defp parse_operation(1), do: :delete
  defp parse_operation(2), do: :insert
  defp parse_operation(3), do: :update
  defp parse_operation(4), do: :update
  defp parse_operation(_), do: :unknown

  defp atomize_keys(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end
end