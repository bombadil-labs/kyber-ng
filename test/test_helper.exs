Code.require_file("support/wire.ex", __DIR__)
Code.require_file("support/channel_fake.ex", __DIR__)

# With `mod: {Kyber.Application, []}` in mix.exs, `mix test` auto-boots :kyber
# (app.start runs before test_helper.exs) — on the config/test.exs tmp log
# path, so nothing touches the user's real store. The T2 suite starts its own
# per-test DurableStore instances via start_supervised!/1, so the
# auto-started app is stopped here: no test may rely on the app being
# auto-started or auto-stopped outside the pinned commands in
# test/application_test.exs (T3 suite choreography).
Application.stop(:kyber)

ExUnit.start()
