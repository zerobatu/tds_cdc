defmodule TdsCdc.Lsn do
  @moduledoc """
  Utilities for working with SQL Server Log Sequence Numbers (LSNs).

  LSNs are used by CDC to track the position in the transaction log.
  They are represented as binary(10) values in SQL Server and are
  typically displayed as hexadecimal strings like "0x00000028:00000120:0001".
  """

  @doc """
  Compares two LSN binary values.

  Returns `:lt`, `:eq`, or `:gt` similar to `Enum.sort/2`.

  SQL Server LSNs are `binary(10)` values that sort lexicographically,
  which corresponds to their chronological order in the transaction log.

  ## Examples

      iex> TdsCdc.Lsn.compare(<<0,0,0,1,0,0,0,0,0,1>>, <<0,0,0,2,0,0,0,0,0,1>>)
      :lt

      iex> TdsCdc.Lsn.compare(<<0,0,0,2,0,0,0,0,0,1>>, <<0,0,0,1,0,0,0,0,0,1>>)
      :gt

      iex> TdsCdc.Lsn.compare(<<0,0,0,1,0,0,0,0,0,1>>, <<0,0,0,1,0,0,0,0,0,1>>)
      :eq
  """
  @spec compare(binary(), binary()) :: :lt | :eq | :gt
  def compare(lsn_a, lsn_b) do
    cond do
      lsn_a < lsn_b -> :lt
      lsn_a > lsn_b -> :gt
      true -> :eq
    end
  end

  @doc """
  Converts a binary LSN from SQL Server to a hex string representation.

  SQL Server stores LSNs as `binary(10)`, which is 10 bytes. This function
  converts those bytes into the standard LSN display format:
  three groups of hex digits separated by colons.

  ## Examples

      iex> TdsCdc.Lsn.to_hex(<<0, 0, 0, 40, 0, 0, 1, 32, 0, 1>>)
      "0x00000028:00000120:0001"
  """
  @spec to_hex(binary()) :: String.t()
  def to_hex(<<part1::binary-size(4), part2::binary-size(4), part3::binary-size(2)>>) do
    "0x#{Base.encode16(part1)}:#{Base.encode16(part2)}:#{Base.encode16(part3)}"
  end

  def to_hex(binary) when is_binary(binary) do
    "0x#{Base.encode16(binary)}"
  end

  @doc """
  Returns the SQL query to get the minimum LSN for a given capture instance.

  This is used to start reading changes from the beginning of available
  CDC data.
  """
  @spec min_lsn_query(String.t()) :: String.t()
  def min_lsn_query(capture_instance) do
    "SELECT sys.fn_cdc_get_min_lsn('#{capture_instance}') AS lsn"
  end

  @doc """
  Returns the SQL query to get the maximum LSN from the transaction log.
  """
  @spec max_lsn_query() :: String.t()
  def max_lsn_query do
    "SELECT sys.fn_cdc_get_max_lsn() AS lsn"
  end

  @doc """
  Returns the SQL query to get the LSN from a binary value.

  This wraps the `sys.fn_cdc_map_lsn_to_time` function.
  """
  @spec lsn_to_time_query(binary()) :: String.t()
  def lsn_to_time_query(lsn_binary) do
    hex = Base.encode16(lsn_binary)
    "SELECT sys.fn_cdc_map_lsn_to_time(0x#{hex}) AS time"
  end

  @doc """
  Returns the SQL query to increment an LSN value.

  Used with the `sys.fn_cdc_increment_lsn` function to get the next
  LSN after a given position.
  """
  @spec increment_lsn_query(binary()) :: String.t()
  def increment_lsn_query(lsn_binary) do
    hex = Base.encode16(lsn_binary)
    "SELECT sys.fn_cdc_increment_lsn(0x#{hex}) AS lsn"
  end

  @doc """
  Builds the SQL query to get all changes for a capture instance
  between two LSN values (inclusive endpoints).
  """
  @spec all_changes_query(String.t(), binary(), binary()) :: String.t()
  def all_changes_query(capture_instance, from_lsn, to_lsn) do
    from_hex = Base.encode16(from_lsn)
    to_hex = Base.encode16(to_lsn)

    "SELECT * FROM cdc.fn_cdc_get_all_changes_#{capture_instance}(" <>
      "0x#{from_hex}, 0x#{to_hex}, 'all')"
  end
end
