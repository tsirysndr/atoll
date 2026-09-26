defmodule Atoll.Email do
  @moduledoc """
  Shared delivery boundary for all PDS email. The configured Cloudflare Worker
  owns sender identity and provider credentials. Callers retain the same opaque
  idempotency key when retrying a logical message. No SMTP fallback is provided.
  """

  @doc "Submits a plain-text email; success means the Worker accepted responsibility for delivery."
  def deliver(message, idempotency_key, opts \\ []) do
    config = Application.get_env(:atoll, :email_worker, [])

    with :ok <- configured(config),
         :ok <- validate_message(message, idempotency_key) do
      request = [
        url: config[:url],
        auth: {:bearer, config[:token]},
        headers: [{"idempotency-key", idempotency_key}],
        json: Map.take(message, [:to, :subject, :text]),
        redirect: false,
        retry: false,
        decode_body: false,
        connect_options: [timeout: 3_000],
        receive_timeout: 5_000,
        finch: [pool_timeout: 3_000, request_timeout: 10_000],
        into: fn {:data, _data}, acc -> {:cont, acc} end
      ]

      # Only the test transport can be overridden; callers cannot replace auth or URL.
      case Req.post(Keyword.merge(request, Keyword.take(opts, [:plug]))) do
        {:ok, %{status: status}} when status in [200, 202, 204] ->
          :ok

        {:ok, %{status: status}} when status in [408, 429] or status >= 500 ->
          {:error, :email_delivery_unavailable}

        {:ok, _} ->
          {:error, :email_delivery_rejected}

        {:error, _} ->
          {:error, :email_delivery_unavailable}
      end
    end
  end

  defp configured(config) do
    case Atoll.Email.Config.validate(config[:url], config[:token]) do
      :ok -> :ok
      _ -> {:error, :email_not_configured}
    end
  end

  defp validate_message(%{to: to, subject: subject, text: text}, key) do
    if line?(to, 254) and Regex.match?(~r/\A[^\s@]+@[^\s@]+\z/u, to) and
         line?(subject, 200) and is_binary(text) and byte_size(text) in 1..65_536 and
         String.valid?(text) and is_binary(key) and byte_size(key) in 16..128 and
         Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, key),
       do: :ok,
       else: {:error, :invalid_email}
  end

  defp validate_message(_, _), do: {:error, :invalid_email}

  defp line?(value, max) do
    is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
      not Regex.match?(~r/[\x00-\x1f\x7f]/u, value)
  end
end
