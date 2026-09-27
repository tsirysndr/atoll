defmodule Atoll.Blobs.MediaValidationTest do
  use Atoll.DataCase, async: true
  alias Atoll.Blobs
  alias Atoll.Blobs.MediaValidation
  @did "did:plc:mediavalidation"
  @strict [storage: [backend: :postgres], media_validation: [mode: :images]]

  setup do
    {:ok, _} = Atoll.Repositories.create(@did, Atoll.SigningKey.generate())
    :ok
  end

  defp png(width, height, trailer \\ :complete) do
    ihdr = <<13::32, "IHDR", width::32, height::32, 8, 6, 0, 0, 0, 0::32>>
    idat = <<0::32, "IDAT", 0::32>>
    iend = <<0::32, "IEND", 0::32>>

    chunks =
      case trailer do
        :complete -> ihdr <> idat <> iend
        :no_idat -> ihdr <> iend
        :truncated -> ihdr <> idat
      end

    <<137, "PNG", 13, 10, 26, 10>> <> chunks
  end

  defp jpeg(width, height, opts \\ []) do
    sof = <<255, 0xC0, 11::16, 8, height::16, width::16, 1, 1, 17, 0>>
    sos = <<255, 0xDA, 8::16, 1, 1, 0, 0, 63, 0>>
    tail = if Keyword.get(opts, :eoi, true), do: <<0, 255, 217>>, else: <<0, 0>>
    body = if Keyword.get(opts, :double_sof, false), do: sof <> sof, else: sof
    <<255, 216>> <> body <> sos <> tail
  end

  defp gif(width, height),
    do: "GIF89a" <> <<width::16-little, height::16-little, 0, 0, 0, 0x3B>>

  defp webp_lossless(b1, b2, b3, b4) do
    payload = "VP8L" <> <<5::32-little, 0x2F, b1, b2, b3, b4>>
    "RIFF" <> <<byte_size(payload) + 4::32-little>> <> "WEBP" <> payload
  end

  defp bmp(width, height) do
    "BM" <>
      <<58::32-little, 0::32, 54::32-little, 40::32-little, width::32-signed-little,
        height::32-signed-little, 0::32>>
  end

  test "parses dimensions from structurally complete images" do
    assert MediaValidation.dimensions(png(640, 480), "image/png") == {:ok, {640, 480}}
    assert MediaValidation.dimensions(jpeg(1024, 768), "image/jpeg") == {:ok, {1024, 768}}
    assert MediaValidation.dimensions(gif(3, 7), "image/gif") == {:ok, {3, 7}}
    assert MediaValidation.dimensions(webp_lossless(2, 64, 0, 0), "image/webp") == {:ok, {3, 2}}
    assert MediaValidation.dimensions(bmp(31, -17), "image/bmp") == {:ok, {31, 17}}
  end

  test "rejects truncated, inconsistent, or bomb-shaped structures" do
    assert MediaValidation.dimensions(png(640, 480, :truncated), "image/png") == :error
    assert MediaValidation.dimensions(png(640, 480, :no_idat), "image/png") == :error
    assert MediaValidation.dimensions(png(0, 480), "image/png") == :error
    assert MediaValidation.dimensions(jpeg(1024, 768, eoi: false), "image/jpeg") == :error
    assert MediaValidation.dimensions(jpeg(1024, 768, double_sof: true), "image/jpeg") == :error
    assert MediaValidation.dimensions(<<255, 216, 255, 217>>, "image/jpeg") == :error
    assert MediaValidation.dimensions("GIF89a" <> <<0, 0, 0, 0>>, "image/gif") == :error
    assert MediaValidation.dimensions(bmp(0, 5), "image/bmp") == :error

    hostile = <<255, 216>> <> :binary.copy(<<255>>, 200_000) <> <<217>>
    assert MediaValidation.dimensions(hostile, "image/jpeg") == :error
  end

  test "disabled mode stores bytes verbatim while strict mode validates and matches types" do
    assert MediaValidation.check(<<1, 2, 3>>, "image/png", "image/png") == :ok
    assert {:ok, _} = Blobs.stage(@did, <<1, 2, 3>>, "image/png", storage: [backend: :postgres])

    assert {:ok, _} = Blobs.stage(@did, png(2, 2), "image/png", @strict)
    assert {:ok, _} = Blobs.stage(@did, "just text", "text/plain", @strict)
    assert {:ok, _} = Blobs.stage(@did, jpeg(4, 4), "application/octet-stream", @strict)

    # Declared supported image types must match the detected signature.
    assert Blobs.stage(@did, jpeg(4, 4), "image/png", @strict) == {:error, :invalid_media}
    assert Blobs.stage(@did, "not an image", "image/png", @strict) == {:error, :invalid_media}

    # Detected images must parse and stay inside the pixel budget.
    assert Blobs.stage(@did, png(2, 2, :truncated), "image/png", @strict) ==
             {:error, :invalid_media}

    limited = [storage: [backend: :postgres], media_validation: [mode: :images, max_pixels: 16]]
    assert {:ok, _} = Blobs.stage(@did, png(4, 4), "image/png", limited)
    assert Blobs.stage(@did, png(5, 4), "image/png", limited) == {:error, :invalid_media}
    assert Repo.aggregate(Atoll.Blobs.Blob, :count) == 5
  end
end
