defmodule TdsCdc.Persistence.File do
  @moduledoc """
  Default file-based LSN position persistence.

  Saves positions as JSON to disk at a configurable path. The default path
  is `<system_tmp>/tds_cdc/<client_name>.json`.

  ## Configuration

  Pass via the `:persistence` option:

      TdsCdc.start_link(
        conn: [...],
        capture_instances: ["dbo_users"],
        persistence: {TdsCdc.Persistence.File, path: "/var/lib/myapp/lsn_positions.json"}
      )

  Options:

    * `:path` - Directory where position files are stored.
      Defaults to `<system_tmp>/tds_cdc/`.

  Each client writes a file named `<client_name>.json` inside the path.
  For example, a client named `TdsCdc.Client` writes
  `<path>/TdsCdc.Client.json`.

  The file format is JSON:

      {
        "dbo_users": "0x0000002800000B800052",
        "dbo_orders": "0x0000002800000C010003"
      }

  You can also configure the default path via application config:

      config :tds_cdc, persistence: [path: "/var/lib/myapp/lsn"]
  """

  alias TdsCdc.Lsn

  @behaviour TdsCdc.Persistence

  @impl true
  def save_positions(name, positions) do
    dir = resolve_path()
    File.mkdir_p!(dir)

    file_path = Path.join(dir, "#{name}.json")

    data =
      positions
      |> Enum.map(fn {ci, lsn} -> {ci, Lsn.to_hex(lsn)} end)
      |> Map.new()

    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        File.write(file_path, json)

      {:error, reason} ->
        {:error, {:encode_error, reason}}
    end
  end

  @impl true
  def load_positions(name) do
    dir = resolve_path()
    file_path = Path.join(dir, "#{name}.json")

    case File.read(file_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_map(data) ->
            positions =
              data
              |> Enum.map(fn {ci, hex} -> {ci, Lsn.from_hex(hex)} end)
              |> Map.new()

            {:ok, positions}

          {:error, reason} ->
            {:error, {:decode_error, reason}}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:read_error, reason}}
    end
  end

  defp resolve_path do
    Keyword.get(Application.get_env(:tds_cdc, :persistence, []), :path, default_path())
  end

  defp default_path do
    Path.join(System.tmp_dir!(), "tds_cdc")
  end
end