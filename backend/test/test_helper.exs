# :e2e tests boot a real `mix run` subprocess (slow; compiles the dev build).
# Run them with `mix test --include e2e`.
ExUnit.start(exclude: [:e2e])
