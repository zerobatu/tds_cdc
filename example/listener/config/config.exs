import Config

config :listener,
  conn: [
    hostname: System.get_env("TDS_HOST", "localhost"),
    port: System.get_env("TDS_PORT", "1433") |> String.to_integer(),
    username: System.get_env("TDS_USERNAME", "sa"),
    password: System.get_env("TDS_PASSWORD", "YourStrong!Passw0rd"),
    database: System.get_env("TDS_DATABASE", "cdc_example")
  ],
  capture_instances: ["dbo_users"],
  poll_interval: 1000

import_config "#{config_env()}.exs"