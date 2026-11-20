import Config

config :logger, level: :warning

config :quicksilver,
  # Ignore QUICKSILVER_* from the shell; tests use the values below.
  read_launch_env: false,
  port: 0,
  token: "test-token",
  exit_on_stdin_eof: false,
  announce_ready: false,
  # Never touch the real user config directory from tests.
  settings_dir: Path.expand("../_build/test/settings", __DIR__)
