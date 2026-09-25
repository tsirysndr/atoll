defmodule Atoll.Syntax do
  @moduledoc "ATProto identifier syntax checks. These do not perform identity resolution."

  @label ~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/
  @name ~r/\A[a-zA-Z][a-zA-Z0-9]{0,62}\z/
  @did ~r/\Adid:[a-z]+:[a-zA-Z0-9._:%-]*[a-zA-Z0-9._-]\z/
  @rkey ~r/\A[A-Za-z0-9._:~-]{1,512}\z/

  def did?(value) when is_binary(value),
    do: byte_size(value) <= 2048 and Regex.match?(@did, value)

  def did?(_), do: false

  def handle?(value) when is_binary(value) and byte_size(value) <= 253 do
    labels = String.split(value, ".")

    length(labels) >= 2 and Enum.all?(labels, &Regex.match?(@label, &1)) and
      Regex.match?(~r/\A[A-Za-z]/, List.last(labels))
  end

  def handle?(_), do: false

  def nsid?(value) when is_binary(value) and byte_size(value) <= 317 do
    labels = String.split(value, ".")
    {authority, names} = Enum.split(labels, -1)

    length(authority) >= 2 and byte_size(Enum.join(authority, ".")) <= 253 and
      Enum.all?(authority, &Regex.match?(@label, &1)) and
      Regex.match?(~r/\A[A-Za-z]/, hd(authority)) and Regex.match?(@name, hd(names))
  end

  def nsid?(_), do: false

  def record_key?(value) when is_binary(value),
    do: value not in [".", ".."] and Regex.match?(@rkey, value)

  def record_key?(_), do: false

  def repo_path?(value) when is_binary(value) do
    case String.split(value, "/") do
      [collection, rkey] ->
        nsid?(collection) and normalized_nsid?(collection) and record_key?(rkey)

      _ ->
        false
    end
  end

  def repo_path?(_), do: false

  def at_uri?("at://" <> rest = value) when byte_size(value) <= 8192 do
    case String.split(rest, "/") do
      [authority] ->
        authority?(authority)

      [authority, collection] ->
        authority?(authority) and nsid?(collection) and normalized_nsid?(collection)

      [authority, collection, key] ->
        authority?(authority) and repo_path?(collection <> "/" <> key)

      _ ->
        false
    end
  end

  def at_uri?(_), do: false

  defp authority?(value), do: did?(value) or (handle?(value) and value == String.downcase(value))

  defp normalized_nsid?(value) do
    {authority, _} = value |> String.split(".") |> Enum.split(-1)
    Enum.all?(authority, &(&1 == String.downcase(&1)))
  end
end
