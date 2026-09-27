defmodule Atoll.Telemetry.ConfigTest do
  use ExUnit.Case, async: true
  alias Atoll.Telemetry.Config

  test "export is opt-in and the standard kill switch disables every signal" do
    refute Config.from_env!(%{}).enabled
    refute Config.from_env!(%{"OTEL_EXPORTER_OTLP_ENDPOINT" => ""}).enabled
    env = %{"OTEL_EXPORTER_OTLP_ENDPOINT" => "http://127.0.0.1:4318"}
    assert Config.from_env!(env).enabled
    refute Config.from_env!(Map.put(env, "OTEL_SDK_DISABLED", "true")).enabled
  end

  test "validates endpoint and interval without disclosing credentials" do
    for endpoint <- [
          "ftp://example.com",
          "http://user:secret@example.com",
          "https://example.com?token=secret"
        ] do
      assert_raise ArgumentError,
                   "OTEL_EXPORTER_OTLP_ENDPOINT must be an HTTP(S) collector URL",
                   fn ->
                     Config.from_env!(%{"OTEL_EXPORTER_OTLP_ENDPOINT" => endpoint})
                   end
    end

    assert_raise ArgumentError, fn ->
      Config.from_env!(%{"OTEL_METRIC_EXPORT_INTERVAL" => "0"})
    end

    assert_raise ArgumentError, fn -> Config.from_env!(%{"OTEL_SDK_DISABLED" => "no"}) end
    assert Config.from_env!(%{"OTEL_METRIC_EXPORT_INTERVAL" => "15000"}).interval == 15_000
  end
end
