defmodule Web.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Web.DB, []},
      {Plug.Cowboy, scheme: :http, plug: Web.Router, options: [port: Application.get_env(:web, :port, 4000)]}
    ]

    opts = [strategy: :one_for_one, name: Web.Supervisor]
    Supervisor.start_link(children, opts)
  end
end