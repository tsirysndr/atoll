defmodule Atoll.Blobs.MediaValidation do
  @moduledoc """
  Opt-in bounded structural validation for common image uploads.

  Parses container structure and dimensions without decoding pixel data; it is
  not a malware scanner and does not transform bytes. When enabled, a declared
  supported image type must match its detected signature, and detected images
  must parse with dimensions inside the configured pixel budget. Other media
  types continue to be stored verbatim.
  """
  import Bitwise

  @images ~w(image/png image/jpeg image/gif image/webp image/bmp)
  @default_max_pixels 268_435_456

  @doc "Supported image media types for structural validation."
  def image_types, do: @images

  def check(bytes, declared, detected, opts \\ []) when is_binary(bytes) do
    config = Keyword.merge(Application.get_env(:atoll, :media_validation, []), opts)

    if Keyword.get(config, :mode, :off) == :images do
      max_pixels = Keyword.get(config, :max_pixels, @default_max_pixels)

      cond do
        declared in @images and detected != declared ->
          {:error, :invalid_media}

        detected in @images ->
          case dimensions(bytes, detected) do
            {:ok, {width, height}} when width * height <= max_pixels -> :ok
            _ -> {:error, :invalid_media}
          end

        true ->
          :ok
      end
    else
      :ok
    end
  end

  @doc "Bounded structural parse returning positive pixel dimensions."
  def dimensions(bytes, type)

  def dimensions(
        <<137, "PNG", 13, 10, 26, 10, 13::32, "IHDR", width::32, height::32, depth, color, 0, 0,
          interlace, _crc::32, rest::binary>>,
        "image/png"
      )
      when width in 1..2_147_483_647 and height in 1..2_147_483_647 and
             depth in [1, 2, 4, 8, 16] and color in [0, 2, 3, 4, 6] and interlace in [0, 1] do
    if png_chunks?(rest, false), do: {:ok, {width, height}}, else: :error
  end

  def dimensions(<<255, 216, rest::binary>>, "image/jpeg"), do: jpeg_segments(rest, nil)

  def dimensions(
        <<"GIF8", version, "a", width::16-little, height::16-little, rest::binary>>,
        "image/gif"
      )
      when version in [?7, ?9] and width > 0 and height > 0 do
    if byte_size(rest) > 0 and :binary.last(rest) == 0x3B,
      do: {:ok, {width, height}},
      else: :error
  end

  def dimensions(<<"RIFF", size::32-little, "WEBP", rest::binary>> = bytes, "image/webp")
      when size == byte_size(bytes) - 8,
      do: webp_chunk(rest)

  def dimensions(
        <<"BM", _size::32-little, _::32, _offset::32-little, 12::32-little, width::16-little,
          height::16-little, _::binary>>,
        "image/bmp"
      )
      when width > 0 and height > 0,
      do: {:ok, {width, height}}

  def dimensions(
        <<"BM", _size::32-little, _::32, _offset::32-little, dib::32-little,
          width::32-signed-little, height::32-signed-little, _::binary>>,
        "image/bmp"
      )
      when dib >= 40 and width > 0 and height != 0,
      do: {:ok, {width, abs(height)}}

  def dimensions(_, _), do: :error

  defp png_chunks?(<<0::32, "IEND", _crc::32>>, idat?), do: idat?

  defp png_chunks?(<<length::32, type::binary-size(4), rest::binary>>, idat?)
       when length <= byte_size(rest) - 4 do
    <<_data::binary-size(length), _crc::32, remaining::binary>> = rest
    png_chunks?(remaining, idat? or type == "IDAT")
  end

  defp png_chunks?(_, _), do: false

  # Markers before start-of-scan carry explicit lengths; entropy data must end in EOI.
  defp jpeg_segments(<<255, 255, _::binary>> = bytes, size) do
    <<_fill, rest::binary>> = bytes
    jpeg_segments(rest, size)
  end

  defp jpeg_segments(<<255, marker, rest::binary>>, size) when marker in [0xD8, 0x01],
    do: jpeg_segments(rest, size)

  defp jpeg_segments(<<255, 0xDA, _::binary>> = _scan, nil), do: :error

  defp jpeg_segments(<<255, 0xDA, rest::binary>>, size) do
    if byte_size(rest) >= 2 and binary_part(rest, byte_size(rest) - 2, 2) == <<255, 0xD9>>,
      do: {:ok, size},
      else: :error
  end

  defp jpeg_segments(<<255, marker, length::16, rest::binary>>, size)
       when length >= 2 and length - 2 <= byte_size(rest) do
    payload = binary_part(rest, 0, length - 2)
    remaining = binary_part(rest, length - 2, byte_size(rest) - (length - 2))

    if marker in [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF] do
      case payload do
        <<_precision, height::16, width::16, _::binary>>
        when width > 0 and height > 0 and is_nil(size) ->
          jpeg_segments(remaining, {width, height})

        _ ->
          :error
      end
    else
      jpeg_segments(remaining, size)
    end
  end

  defp jpeg_segments(_, _), do: :error

  defp webp_chunk(<<"VP8 ", length::32-little, rest::binary>>)
       when length >= 10 and length <= byte_size(rest) do
    case rest do
      <<_tag::binary-size(3), 0x9D, 0x01, 0x2A, w::16-little, h::16-little, _::binary>> ->
        dims(band(w, 0x3FFF), band(h, 0x3FFF))

      _ ->
        :error
    end
  end

  defp webp_chunk(<<"VP8L", length::32-little, 0x2F, b1, b2, b3, b4, _::binary>>)
       when length >= 5,
       do:
         dims(
           1 + bor(bsl(band(b2, 0x3F), 8), b1),
           1 + bor(bsl(band(b4, 0x0F), 10), bor(bsl(b3, 2), bsr(b2, 6)))
         )

  defp webp_chunk(
         <<"VP8X", length::32-little, _flags::32, w::24-little, h::24-little, _::binary>>
       )
       when length >= 10,
       do: dims(w + 1, h + 1)

  defp webp_chunk(_), do: :error

  defp dims(width, height) when width > 0 and height > 0, do: {:ok, {width, height}}
  defp dims(_, _), do: :error

  @doc false
  def mode_from_env!(nil), do: []
  def mode_from_env!("off"), do: []
  def mode_from_env!("images"), do: [mode: :images]

  def mode_from_env!(_),
    do: raise(ArgumentError, "ATOLL_MEDIA_VALIDATION must be \"off\" or \"images\"")

  @doc false
  def max_pixels_from_env!(nil), do: @default_max_pixels

  def max_pixels_from_env!(value) when is_binary(value) do
    case Integer.parse(value) do
      {pixels, ""} when pixels in 1..1_000_000_000_000 -> pixels
      _ -> raise ArgumentError, "ATOLL_MEDIA_MAX_PIXELS must be an integer from 1 to 1e12"
    end
  end
end
