defmodule Atoll.Lexicon.WriteValidation do
  @moduledoc "Request-local network schema preparation before authenticated write transactions."
  alias Atoll.Lexicon.{Catalog, Schema}

  def enabled_from_env!(nil), do: false
  def enabled_from_env!("true"), do: true
  def enabled_from_env!("false"), do: false
  def enabled_from_env!(_), do: raise("ATOLL_NETWORK_LEXICONS must be true or false")

  def catalog(_body, :delete), do: {:ok, %{}}

  def catalog(body, action) do
    mode = Map.get(body, "validate", :optimistic)

    local =
      Map.merge(Application.get_env(:atoll, :record_lexicons, %{}), Schema.builtin_documents())

    unknown =
      collections(body, action)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(local, &1))

    if mode == false or unknown == [] or
         not Application.get_env(:atoll, :network_lexicons_enabled, false) do
      {:ok, %{}}
    else
      opts = Application.get_env(:atoll, :lexicon_resolution_options, [])

      case Catalog.resolve_many(unknown, opts) do
        {:ok, result} -> {:ok, result.documents}
        {:error, _} when mode == :optimistic -> {:ok, %{}}
        {:error, _} -> {:error, :validation_unavailable}
      end
    end
  end

  defp collections(body, :batch) do
    Enum.flat_map(body["writes"], fn
      %{"$type" => type, "collection" => collection}
      when type in ["com.atproto.repo.applyWrites#create", "com.atproto.repo.applyWrites#update"] ->
        [collection]

      _ ->
        []
    end)
  end

  defp collections(body, _), do: [body["collection"]]
end
