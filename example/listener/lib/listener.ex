defmodule Listener do
  @moduledoc """
  Terminal listener that subscribes to CDC changes and prints them to stdout.

  Usage:

      mix run --no-halt -e "Listener.start()"

  Or in iex:

      iex -S mix
      iex> Listener.start()
  """

  alias TdsCdc.Change

  @line_width 60

  def start do
    capture_instances = Application.get_env(:listener, :capture_instances, ["dbo_users"])

    IO.puts("""

    =========================================
      TdsCdc Listener - SQL Server CDC
    =========================================
    """)

    case TdsCdc.wait_for_ready(timeout: 10_000, capture_instance: hd(capture_instances)) do
      :ok ->
        IO.puts("  CDC client ready")

      {:error, :timeout} ->
        IO.puts("  [WARNING] Client not ready after 10s, continuing anyway...")
    end

    Enum.each(capture_instances, fn ci ->
      case TdsCdc.subscribe(ci) do
        :ok -> IO.puts("  Subscribed to #{ci}")
        {:error, reason} -> IO.puts("  Failed to subscribe to #{ci}: #{inspect(reason)}")
      end
    end)

    IO.puts("\n--- Listening for changes (press Ctrl+C to stop) ---\n")
    listen_loop()
  end

  defp listen_loop do
    receive do
      {:tds_cdc_change, capture_instance, %Change{} = change} ->
        print_change(capture_instance, change)
        listen_loop()

      {:tds_cdc_gap_detected, capture_instance, old_lsn, min_lsn} ->
        IO.puts("""
        [GAP] #{capture_instance}
              Old LSN: #{TdsCdc.Lsn.to_hex(old_lsn)}
              Min LSN: #{TdsCdc.Lsn.to_hex(min_lsn)}
        """)
        listen_loop()
    after
      300_000 ->
        IO.puts("\nNo changes received in 5 minutes. Still listening...")
        listen_loop()
    end
  end

  defp print_change(capture_instance, change) do
    op = format_op(change.operation)
    data = change.data

    IO.puts("""
    #{String.duplicate("-", @line_width)}
    CDC Change | #{capture_instance} | #{op}
    #{String.duplicate("-", @line_width)}
      ID:    #{format_val(data[:id])}
      Name:  #{format_val(data[:name])}
      Email: #{format_val(data[:email])}
      Age:   #{format_val(data[:age])}
    #{String.duplicate("-", @line_width)}
    """)
  end

  defp format_op(:insert), do: "INSERT"
  defp format_op(:update), do: "UPDATE"
  defp format_op(:delete), do: "DELETE"
  defp format_op(op), do: inspect(op)

  defp format_val(nil), do: "-"
  defp format_val(val), do: to_string(val)
end