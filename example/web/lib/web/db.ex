defmodule Web.DB do
  use Agent

  @retry_interval 2_000

  def start_link(_opts) do
    Agent.start_link(&connect/0, name: __MODULE__)
  end

  def conn, do: Agent.get(__MODULE__, & &1)

  def query(sql, params \\ []) do
    Tds.query(conn(), sql, params)
  end

  defp connect do
    conn_opts = [
      hostname: Application.get_env(:tds, :hostname, "localhost"),
      port: Application.get_env(:tds, :port, 1433),
      username: Application.get_env(:tds, :username, "sa"),
      password: Application.get_env(:tds, :password, "YourStrong!Passw0rd"),
      database: Application.get_env(:tds, :database, "cdc_example")
    ]

    case Tds.start_link(conn_opts) do
      {:ok, conn} ->
        conn

      {:error, _reason} ->
        Process.sleep(@retry_interval)
        connect()
    end
  end
end