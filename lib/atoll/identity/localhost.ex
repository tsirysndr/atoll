defmodule Atoll.Identity.Localhost do
  @moduledoc "Explicit localhost identity exceptions, build-gated to development and test."
  @development Application.compile_env(:atoll, :development_identity, false)

  def enabled?, do: @development and Application.get_env(:atoll, :localhost_dids_enabled, false)

  def parse_enabled!(nil, _environment), do: false
  def parse_enabled!("false", _environment), do: false
  def parse_enabled!("true", environment) when environment in [:dev, :test], do: true

  def parse_enabled!(_, _),
    do:
      raise(
        "ATOLL_LOCALHOST_DIDS_ENABLED must be false outside development/test, or true/false within them"
      )

  def url("did:web:localhost" <> suffix) when byte_size(suffix) <= 8 do
    if enabled?() do
      case suffix do
        "" ->
          {:ok, "http://localhost/.well-known/did.json"}

        <<"%3", a, port::binary>> when a in [?A, ?a] ->
          case Integer.parse(port) do
            {number, ""} when number in 1..65535 ->
              if Integer.to_string(number) == port,
                do: {:ok, "http://localhost:" <> port <> "/.well-known/did.json"},
                else: {:error, :invalid_did}

            _ ->
              {:error, :invalid_did}
          end

        _ ->
          {:error, :invalid_did}
      end
    else
      {:error, :invalid_did}
    end
  end

  def url(_), do: {:error, :invalid_did}

  def endpoint?(value) when is_binary(value) do
    enabled?() and
      case URI.new(value) do
        {:ok,
         %URI{
           scheme: "http",
           host: "localhost",
           port: port,
           path: path,
           userinfo: nil,
           query: nil,
           fragment: nil
         }}
        when port in 1..65535 and path in [nil, "", "/"] ->
          true

        _ ->
          false
      end
  end

  def endpoint?(_), do: false
end
