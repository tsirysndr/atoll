defmodule AtollWeb.ErrorJSON do
  @moduledoc "Renders sanitized framework errors, using the XRPC error shape for API routes."

  def render(template, assigns) do
    message = Phoenix.Controller.status_message_from_template(template)

    if xrpc?(assigns) do
      %{error: name(template), message: message}
    else
      %{errors: %{detail: message}}
    end
  end

  defp xrpc?(%{conn: %{path_info: [prefix | _]}}), do: URI.decode(prefix) == "xrpc"
  defp xrpc?(_), do: false

  defp name("401.json"), do: "AuthRequired"
  defp name("403.json"), do: "Forbidden"
  defp name("404.json"), do: "NotFound"
  defp name("405.json"), do: "MethodNotAllowed"
  defp name("406.json"), do: "NotAcceptable"
  defp name("413.json"), do: "PayloadTooLarge"
  defp name("415.json"), do: "UnsupportedMediaType"
  defp name("429.json"), do: "RateLimitExceeded"
  defp name("501.json"), do: "MethodNotImplemented"
  defp name("502.json"), do: "UpstreamFailure"
  defp name("503.json"), do: "ServiceUnavailable"
  defp name("504.json"), do: "UpstreamTimeout"
  defp name("4" <> _), do: "InvalidRequest"
  defp name(_), do: "InternalServerError"
end
