defmodule Atoll.Blobs.MimeSniffer do
  @moduledoc "Bounded signature detection for common binary media; not a decoder or malware scanner."

  @doc "Returns a recognized media type, otherwise the caller's normalized declaration."
  def detect(bytes, declared) when is_binary(bytes) and is_binary(declared) do
    header = binary_part(bytes, 0, min(byte_size(bytes), 512))
    signature(header) || declared
  end

  # Binary signatures follow the WHATWG image/audio/video pattern tables.
  defp signature(<<137, "PNG", 13, 10, 26, 10, _::binary>>), do: "image/png"
  defp signature(<<255, 216, 255, _::binary>>), do: "image/jpeg"
  defp signature(<<"GIF87a", _::binary>>), do: "image/gif"
  defp signature(<<"GIF89a", _::binary>>), do: "image/gif"
  defp signature(<<"RIFF", _::binary-size(4), "WEBPVP", _::binary>>), do: "image/webp"
  defp signature(<<"BM", _::binary>>), do: "image/bmp"
  defp signature(<<0, 0, 1, 0, _::binary>>), do: "image/x-icon"
  defp signature(<<0, 0, 2, 0, _::binary>>), do: "image/x-icon"
  defp signature(<<"ID3", _::binary>>), do: "audio/mpeg"
  defp signature(<<"OggS", 0, _::binary>>), do: "application/ogg"
  defp signature(<<"MThd", 6::32, _::binary>>), do: "audio/midi"
  defp signature(<<"FORM", _::binary-size(4), "AIFF", _::binary>>), do: "audio/aiff"
  defp signature(<<"RIFF", _::binary-size(4), "WAVE", _::binary>>), do: "audio/wave"
  defp signature(<<"RIFF", _::binary-size(4), "AVI ", _::binary>>), do: "video/avi"

  defp signature(<<size::32, "ftyp", major::binary-size(4), _version::32, _::binary>> = header)
       when size >= 16 and rem(size, 4) == 0 and size <= byte_size(header) do
    compatible = binary_part(header, 16, size - 16)
    brands = [major | for(<<brand::binary-size(4) <- compatible>>, do: brand)]
    if Enum.any?(brands, &match?(<<"mp4", _>>, &1)), do: "video/mp4", else: nil
  end

  defp signature(_), do: nil
end
