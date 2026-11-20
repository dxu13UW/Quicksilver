import Config

# stdout is part of the launch protocol (the QUICKSILVER_READY line), so all
# logging goes to stderr. The client must drain or redirect stderr.
config :logger, :default_handler, config: [type: :standard_error]

config :quicksilver,
  # Read QUICKSILVER_PORT / QUICKSILVER_TOKEN from the OS environment.
  read_launch_env: true,
  # Print the QUICKSILVER_READY line once the listener is bound.
  announce_ready: true,
  hello_timeout_ms: 5_000,
  health_interval_ms: 5_000,
  # Data sources shown as `idle` in `health` from startup (PROTOCOL.md, Week 2).
  health_sources: ["poe_ninja", "trade_leagues"],
  # nil = :filename.basedir(:user_config, "Quicksilver")
  settings_dir: nil

import_config "#{config_env()}.exs"
