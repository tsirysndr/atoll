defmodule Atoll.Lexicon.Language do
  @moduledoc "BCP 47 well-formed syntax (RFC 5646), without registry or preferred-value lookup."
  @grandfathered ~w(en-gb-oed i-ami i-bnn i-default i-enochian i-hak i-klingon i-lux i-mingo i-navajo i-pwn i-tao i-tay i-tsu sgn-be-fr sgn-be-nl sgn-ch-de art-lojban cel-gaulish no-bok no-nyn zh-guoyu zh-hakka zh-min zh-min-nan zh-xiang)
  @tag ~r/\A(?:[a-z]{2,3}(?:-[a-z]{3}){0,3}|[a-z]{4}|[a-z]{5,8})(?:-[a-z]{4})?(?:-(?:[a-z]{2}|[0-9]{3}))?(?<variants>(?:-(?:[a-z0-9]{5,8}|[0-9][a-z0-9]{3}))*)(?<extensions>(?:-[0-9a-wy-z](?:-[a-z0-9]{2,8})+)*)(?:-x(?:-[a-z0-9]{1,8})+)?\z/

  def valid?(value) when is_binary(value) do
    Regex.match?(~r/\A[A-Za-z0-9-]+\z/, value) and valid_ascii?(String.downcase(value))
  end

  def valid?(_), do: false

  defp valid_ascii?(value) do
    cond do
      value in @grandfathered ->
        true

      Regex.match?(~r/\Ax(?:-[a-z0-9]{1,8})+\z/, value) ->
        true

      true ->
        case Regex.named_captures(@tag, value) do
          nil ->
            false

          captures ->
            variants = String.split(captures["variants"], "-", trim: true)

            singletons =
              captures["extensions"]
              |> String.split("-", trim: true)
              |> Enum.filter(&(byte_size(&1) == 1))

            unique?(variants) and unique?(singletons)
        end
    end
  end

  defp unique?(values), do: length(values) == MapSet.size(MapSet.new(values))
end
