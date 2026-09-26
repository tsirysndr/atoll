defmodule Atoll.Blobs.MimeSnifferTest do
  use ExUnit.Case, async: true
  alias Atoll.Blobs.MimeSniffer
  @fallback "application/octet-stream"

  test "recognizes common binary media signatures independent of the declaration" do
    for {header, type} <- [
          {<<137, "PNG", 13, 10, 26, 10>>, "image/png"},
          {<<255, 216, 255, 224>>, "image/jpeg"},
          {"GIF87a", "image/gif"},
          {"GIF89a", "image/gif"},
          {<<"RIFF", 12::little-32, "WEBPVP8 ">>, "image/webp"},
          {"BM", "image/bmp"},
          {<<0, 0, 1, 0>>, "image/x-icon"},
          {"ID3", "audio/mpeg"},
          {<<"OggS", 0>>, "application/ogg"},
          {<<"MThd", 6::32>>, "audio/midi"},
          {<<"FORM", 4::32, "AIFF">>, "audio/aiff"},
          {<<"RIFF", 4::32, "WAVE">>, "audio/wave"},
          {<<"RIFF", 4::32, "AVI ">>, "video/avi"}
        ] do
      assert MimeSniffer.detect(header <> "payload", "text/plain") == type
    end
  end

  test "MP4 requires a complete bounded first ftyp box and an aligned mp4 brand" do
    assert MimeSniffer.detect(<<16::32, "ftypmp42", 0::32>>, @fallback) == "video/mp4"
    assert MimeSniffer.detect(<<24::32, "ftypisom", 0::32, "isommp41">>, @fallback) == "video/mp4"

    for bytes <- [
          <<20::32, "ftypmp42", 0::32>>,
          <<17::32, "ftypmp42", 0::40>>,
          <<20::32, "ftypisom", 0::32, "xmp4">>,
          <<16::32, "ftypavif", 0::32>>,
          <<16::32, "ftypisom", "mp42">>,
          <<0::32, "ftypmp42", 0::32>>
        ] do
      assert MimeSniffer.detect(bytes, @fallback) == @fallback
    end

    assert MimeSniffer.detect(<<516::32, "ftypmp42", 0::4000>>, @fallback) == @fallback
  end

  test "unknown or incomplete content preserves the declaration without text sniffing" do
    for bytes <- [
          "",
          <<137, "PNG">>,
          <<255, 216>>,
          "GIF89",
          "<html>hello</html>",
          "<svg></svg>",
          String.duplicate("x", 512) <> "GIF89a"
        ] do
      assert MimeSniffer.detect(bytes, "text/plain") == "text/plain"
    end
  end
end
