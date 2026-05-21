defmodule Listener.Application do
  use Application

  @impl true
  def start(_type, _args) do
    conn_opts = Application.get_env(:listener, :conn)
    capture_instances = Application.get_env(:listener, :capture_instances, ["dbo_users"])
    poll_interval = Application.get_env(:listener, :poll_interval, 1000)

    children = [
      {TdsCdc.Client, conn: conn_opts, capture_instances: capture_instances, poll_interval: poll_interval}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Listener.Supervisor)
  end
end