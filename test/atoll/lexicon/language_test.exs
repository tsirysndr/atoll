defmodule Atoll.Lexicon.LanguageTest do
  use ExUnit.Case, async: true
  alias Atoll.Lexicon.Language

  test "accepts well-formed BCP 47 including private and grandfathered tags" do
    for tag <- [
          "en",
          "mg",
          "zh-Hant-TW",
          "de-CH-1901",
          "sl-rozaj-biske-1994",
          "en-US-u-ca-gregory",
          "x-private",
          "en-x-a",
          "i-klingon",
          "sgn-BE-FR",
          "qaa-Qaaa-QM-x-southern",
          "en-a-aaa-b-bbb"
        ] do
      assert Language.valid?(tag), tag
    end
  end

  test "rejects malformed tags and duplicate variants or extension singletons" do
    for tag <- [
          "",
          "en_US",
          "en-Kelvin",
          "e",
          "en-",
          "en-a",
          "en-abcdefghi",
          "de-1901-1901",
          "en-a-aaa-A-bbb",
          "en-x",
          "en-1234-1234"
        ] do
      refute Language.valid?(tag), tag
    end
  end
end
