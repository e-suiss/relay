defmodule Relay.Channels.Email.Wizard do
  @moduledoc """
  The sending domain wizard of an e-mail provider account (CH-36). For each stream the account's settings name (`Relay.Channels.Email.Streams`) it lists the DNS records the tenant publishes and runs the checks of `Relay.Channels.Email.DomainCheck` against live DNS: the return path CNAME to the bounce host, the stream's DKIM selector record, the SPF record and the recommended DMARC record (DMARCbis ramp with `t=y`, `np=reject`, strict alignment). A value Relay cannot know here, such as a provider's SPF include or a DKIM public key not held by Relay, is `nil`. A lookup is a network call, so the wizard runs outside any transaction.
  """

  alias Relay.Channels.Email.DomainCheck

  @streams ["transactional", "marketing"]
  @dmarc "v=DMARC1; p=reject; t=y; np=reject; adkim=s; aspf=s"

  @type record :: %{
          purpose: String.t(),
          type: String.t(),
          name: String.t(),
          value: String.t() | nil
        }
  @type check :: %{
          stream: String.t(),
          domain: String.t(),
          records: [record()],
          result: DomainCheck.t()
        }

  # CH-36
  # INV-43
  @doc "Runs the wizard for every stream an e-mail account's settings name, with `resolver` (a `Relay.Channels.Email.Resolver`), the installation's bounce host `target` (`nil` when not configured) and `now`; an account of another channel has no stream."
  @spec run(map(), module(), String.t() | nil, DateTime.t()) :: [check()]
  def run(
        %{"channel" => "email", "settings" => %{"streams" => %{} = streams}},
        resolver,
        target,
        now
      ) do
    for name <- @streams,
        %{"domain" => domain} = stream <- [Map.get(streams, name)],
        text(domain) != nil,
        do: stream(name, stream, streams, resolver, target, now)
  end

  def run(_account, _resolver, _target, _now), do: []

  defp stream(name, stream, streams, resolver, target, now) do
    domain = stream["domain"] |> text() |> String.downcase(:ascii)
    return_path = lower(text(stream["return_path_domain"])) || "bounces." <> domain
    target = text(stream["return_path_target"]) || text(target)
    selector = text(stream["selector"])

    input = %{
      domain: domain,
      stream: name,
      return_path_domain: return_path,
      return_path_target: target || "",
      selectors: selectors(selector, name),
      other_stream_domain: other_domain(streams, name)
    }

    result = DomainCheck.run(input, resolver, now)

    %{
      stream: name,
      domain: domain,
      records: records(domain, return_path, target, selector),
      result: unknown_target(result, target, return_path)
    }
  end

  defp selectors(nil, _stream), do: []

  defp selectors(selector, stream),
    do: [%{selector: selector, stream: stream, state: :active, activated_at: nil}]

  defp other_domain(streams, name) do
    [other] = @streams -- [name]

    case Map.get(streams, other) do
      %{"domain" => domain} -> text(domain)
      _none -> nil
    end
  end

  defp records(domain, return_path, target, selector) do
    dkim =
      if selector,
        do: [record("dkim", "TXT", selector <> "._domainkey." <> domain, nil)],
        else: []

    [record("return_path", "CNAME", return_path, target)] ++
      dkim ++
      [
        record("spf", "TXT", domain, nil),
        record("dmarc", "TXT", "_dmarc." <> domain, @dmarc)
      ]
  end

  defp record(purpose, type, name, value),
    do: %{purpose: purpose, type: type, name: name, value: value}

  defp unknown_target(result, nil, return_path) do
    finding = %{severity: :warning, code: :return_path_target_unknown, subject: return_path}
    %{result | findings: result.findings ++ [finding]}
  end

  defp unknown_target(result, _target, _return_path), do: result

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil

  defp lower(nil), do: nil
  defp lower(value), do: String.downcase(value, :ascii)
end
