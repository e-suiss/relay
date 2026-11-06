defmodule Relay.Channels.Email.Sns do
  @moduledoc """
  Amazon SNS message signatures (CH-47, T-40), for SES events that reach Relay through an SNS topic and an SQS queue. A notification is accepted only when its topic is the account's configured topic and its signature verifies with the certificate named by `SigningCertURL`: an `https` URL on an `sns.<region>.amazonaws.com` host whose path ends in `.pem`, fetched over verified TLS. Signature version 1 is SHA1withRSA and version 2 SHA256withRSA over the canonical string of the notification's fields. Only `Notification` messages are read; a subscription confirmation is never acted on.
  """

  @cert_host ~r/\Asns\.[a-z0-9\-]+\.amazonaws\.com(\.cn)?\z/
  @notification ~w(Message MessageId Subject Timestamp TopicArn Type)

  @type reason ::
          :not_a_notification
          | :wrong_topic
          | :bad_certificate_url
          | :certificate_unavailable
          | :bad_signature

  @type fetch :: (String.t() -> {:ok, binary()} | :error)

  # CH-47
  # T-40
  @doc "Verifies an SNS notification, decoded or as JSON text, for `topic_arn`; `fetch` reads the PEM certificate of a URL. Returns the notification's fields."
  @spec verify(binary() | map(), String.t(), fetch()) :: {:ok, map()} | {:error, reason()}
  def verify(body, topic_arn, fetch) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = notification} -> verify(notification, topic_arn, fetch)
      _other -> {:error, :not_a_notification}
    end
  end

  def verify(%{"Type" => "Notification"} = notification, topic_arn, fetch)
      when is_binary(topic_arn) and is_function(fetch, 1) do
    with :ok <- topic(notification, topic_arn),
         {:ok, url} <- certificate_url(notification["SigningCertURL"]),
         {:ok, digest} <- digest(notification["SignatureVersion"]),
         {:ok, signature} <- signature(notification["Signature"]),
         {:ok, key} <- key(fetch.(url)) do
      if :public_key.verify(canonical(notification), digest, signature, key),
        do: {:ok, notification},
        else: {:error, :bad_signature}
    end
  end

  def verify(%{}, _topic_arn, _fetch), do: {:error, :not_a_notification}

  defp topic(%{"TopicArn" => arn}, arn), do: :ok
  defp topic(_notification, _arn), do: {:error, :wrong_topic}

  @doc "Checks that a certificate URL is an SNS certificate on an `sns.<region>.amazonaws.com` host over HTTPS."
  @spec certificate_url(term()) :: {:ok, String.t()} | {:error, :bad_certificate_url}
  def certificate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, path: "/" <> _ = path, query: nil, port: 443}
      when is_binary(host) ->
        if host =~ @cert_host and String.ends_with?(path, ".pem"),
          do: {:ok, url},
          else: {:error, :bad_certificate_url}

      _other ->
        {:error, :bad_certificate_url}
    end
  end

  def certificate_url(_url), do: {:error, :bad_certificate_url}

  defp digest("1"), do: {:ok, :sha}
  defp digest("2"), do: {:ok, :sha256}
  defp digest(_version), do: {:error, :bad_signature}

  defp signature(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, signature} -> {:ok, signature}
      :error -> {:error, :bad_signature}
    end
  end

  defp signature(_value), do: {:error, :bad_signature}

  defp key({:ok, pem}) when is_binary(pem) do
    case for({:Certificate, der, _enc} <- :public_key.pem_decode(pem), do: der) do
      [der | _rest] -> {:ok, public_key(der)}
      [] -> {:error, :certificate_unavailable}
    end
  rescue
    _invalid -> {:error, :certificate_unavailable}
  end

  defp key(_fetched), do: {:error, :certificate_unavailable}

  defp public_key(der) do
    der
    |> :public_key.pkix_decode_cert(:otp)
    |> elem(1)
    |> elem(7)
    |> elem(2)
  end

  # T-40
  @doc "The canonical string an SNS notification's signature covers: each present field of `Message`, `MessageId`, `Subject`, `Timestamp`, `TopicArn` and `Type`, as its name and value on lines of their own."
  @spec canonical(map()) :: binary()
  def canonical(notification) do
    Enum.map_join(@notification, fn name ->
      case notification[name] do
        value when is_binary(value) -> name <> "\n" <> value <> "\n"
        _absent -> ""
      end
    end)
  end
end
