import Config

config :tds_cdc,
  ecto_repos: []

import_config "#{config_env()}.exs"
