defmodule Relay.Channels.Email.DomainCheck do
  @moduledoc """
  The checks behind the sending domain wizard (CH-36, INV-43). One run checks one sending domain of one stream and returns its findings and whether it is verified, which feeds the verified route rule (§12.3.2): a domain is verified when no finding is an error.

  * SPF: the lookup and void lookup limits (`Relay.Channels.Email.Spf`); when both streams send from the same domain, a subdomain per stream is suggested (`stream_subdomain`), each with its own lookup budget.
  * Return path: the return path domain is a CNAME to Relay's bounce host (`return_path_cname_missing`, `return_path_cname_mismatch`) and is aligned with the sending domain (`return_path_unaligned`).
  * DKIM: every published selector of the stream has one record (`dkim_missing`, `dkim_multiple_records`), of an RSA key (`dkim_unsupported_key_type`) of at least 2048 bits (`dkim_key_too_short`) that allows SHA-256 (`dkim_sha1_only`), is not revoked (`dkim_revoked`), decodes once its character strings are joined (`dkim_malformed`, `dkim_string_too_long`) and, when the key store's key is given, is that key (`dkim_key_mismatch`); `t=y` is warned about (`dkim_testing`).
  * Selectors: a selector belongs to one stream (`dkim_selector_shared`), a stream has an active selector (`dkim_no_active_selector`), and the active selector is rotated, with the next selector published beside it, at most six months after it became active (`dkim_rotation_due`).
  * DMARC: the policy by the tree walk (`Relay.Channels.Email.Dmarc`); at `p=reject` a DKIM error is also `dmarc_reject_requires_dkim`, since SPF alone is not relied on.
  """

  alias Relay.Channels.Email.Dkim
  alias Relay.Channels.Email.Dmarc
  alias Relay.Channels.Email.Spf

  @rotation_months 6

  @type severity :: :error | :warning | :suggestion
  @type finding :: %{severity: severity(), code: atom(), subject: String.t()}
  @type selector :: %{
          required(:selector) => String.t(),
          required(:stream) => String.t(),
          required(:state) => :active | :next | :retired,
          required(:activated_at) => DateTime.t() | nil,
          optional(:public_key) => {binary(), binary()} | nil
        }
  @type input :: %{
          required(:domain) => String.t(),
          required(:stream) => String.t(),
          required(:return_path_domain) => String.t(),
          required(:return_path_target) => String.t(),
          required(:selectors) => [selector()],
          optional(:other_stream_domain) => String.t() | nil
        }
  @type t :: %{
          verified: boolean(),
          findings: [finding()],
          spf: Spf.result(),
          dmarc: Dmarc.policy() | nil
        }

  # CH-36
  # INV-43
  @doc "Checks a sending domain of a stream with `resolver` (a `Relay.Channels.Email.Resolver`) at `now`."
  @spec run(input(), module(), DateTime.t()) :: t()
  def run(%{domain: domain, stream: stream} = input, resolver, %DateTime{} = now) do
    domain = String.downcase(domain, :ascii)
    spf = Spf.check(domain, resolver)
    dmarc = Dmarc.discover(domain, resolver)
    stream_selectors = Enum.filter(input.selectors, &(&1.stream == stream))

    dkim =
      stream_selectors
      |> Enum.reject(&(&1.state == :retired))
      |> Enum.flat_map(&check_selector(domain, &1, resolver))

    findings =
      Enum.map(spf.errors, &finding(:error, &1, domain)) ++
        Enum.map(spf.warnings, &finding(:warning, &1, domain)) ++
        streams(domain, Map.get(input, :other_stream_domain)) ++
        return_path(domain, input.return_path_domain, input.return_path_target, resolver) ++
        dkim ++
        selectors(input.selectors, stream, now) ++
        Enum.map(Dmarc.findings(dmarc), &finding(elem(&1, 0), elem(&1, 1), domain)) ++
        reject_needs_dkim(dmarc, dkim, domain)

    %{
      verified: not Enum.any?(findings, &(&1.severity == :error)),
      findings: findings,
      spf: spf,
      dmarc: dmarc
    }
  end

  defp finding(severity, code, subject), do: %{severity: severity, code: code, subject: subject}

  defp streams(domain, other) when is_binary(other) do
    if String.downcase(other, :ascii) == domain,
      do: [finding(:suggestion, :stream_subdomain, domain)],
      else: []
  end

  defp streams(_domain, _other), do: []

  # CH-36
  @doc "Checks the return path domain: a CNAME to `target` and aligned with the sending domain."
  @spec return_path(String.t(), String.t(), String.t(), module()) :: [finding()]
  def return_path(domain, return_path_domain, target, resolver) do
    return_path_domain = String.downcase(return_path_domain, :ascii)
    target = target |> String.trim_trailing(".") |> String.downcase(:ascii)

    cname =
      case resolver.cname(return_path_domain) do
        {:ok, ^target} -> []
        {:ok, _other} -> [finding(:error, :return_path_cname_mismatch, return_path_domain)]
        {:error, _reason} -> [finding(:error, :return_path_cname_missing, return_path_domain)]
      end

    if Dmarc.aligned?(return_path_domain, domain, "r", resolver),
      do: cname,
      else: cname ++ [finding(:warning, :return_path_unaligned, return_path_domain)]
  end

  # CH-36
  @doc "Checks the DKIM record of one selector of a sending domain."
  @spec check_selector(String.t(), selector(), module()) :: [finding()]
  def check_selector(domain, %{selector: selector} = entry, resolver) do
    name = selector <> "._domainkey." <> domain

    case resolver.txt(name) do
      {:ok, records} ->
        case Enum.filter(records, &key_record?/1) do
          [strings] -> key_findings(strings, Map.get(entry, :public_key), name)
          [] -> [finding(:error, :dkim_missing, name)]
          _many -> [finding(:error, :dkim_multiple_records, name)]
        end

      {:error, _reason} ->
        [finding(:error, :dkim_missing, name)]
    end
  end

  defp key_record?(strings) do
    tags = strings |> Enum.join() |> Dkim.tags()
    Map.has_key?(tags, "p") or String.starts_with?(Enum.join(strings), "v=DKIM1")
  end

  defp key_findings(strings, expected, name) do
    tags = strings |> Enum.join() |> Dkim.tags()

    long =
      if Enum.any?(strings, &(byte_size(&1) > 255)),
        do: [finding(:error, :dkim_string_too_long, name)],
        else: []

    long ++ tag_findings(tags, expected, name)
  end

  defp tag_findings(tags, expected, name) do
    hashes = (tags["h"] || "sha256") |> String.downcase(:ascii) |> String.split(":", trim: true)

    cond do
      String.downcase(tags["k"] || "rsa", :ascii) != "rsa" ->
        [finding(:error, :dkim_unsupported_key_type, name)]

      "sha256" not in Enum.map(hashes, &String.trim/1) ->
        [finding(:error, :dkim_sha1_only, name)]

      (tags["p"] || "") == "" ->
        [finding(:error, :dkim_revoked, name)]

      true ->
        key_value(tags, expected, name)
    end
  end

  defp key_value(tags, expected, name) do
    testing =
      if "y" in String.split(tags["t"] || "", ":"),
        do: [finding(:warning, :dkim_testing, name)],
        else: []

    with {:ok, der} <- Base.decode64(Regex.replace(~r/\s+/, tags["p"], "")),
         {:ok, {:RSAPublicKey, modulus, exponent}} <- Dkim.decode_spki(der) do
      size =
        case Dkim.check_key(modulus) do
          :ok -> []
          {:error, _error} -> [finding(:error, :dkim_key_too_short, name)]
        end

      size ++ mismatch(expected, modulus, exponent, name) ++ testing
    else
      _invalid -> [finding(:error, :dkim_malformed, name) | testing]
    end
  end

  defp mismatch({modulus, exponent}, modulus_int, exponent_int, name) do
    if :binary.decode_unsigned(modulus) == modulus_int and
         :binary.decode_unsigned(exponent) == exponent_int,
       do: [],
       else: [finding(:error, :dkim_key_mismatch, name)]
  end

  defp mismatch(_expected, _modulus, _exponent, _name), do: []

  # CH-36
  @doc "Checks the selectors of all streams for `stream`: no selector shared between streams, an active selector, and rotation at most six months after activation."
  @spec selectors([selector()], String.t(), DateTime.t()) :: [finding()]
  def selectors(all, stream, %DateTime{} = now) do
    own = Enum.filter(all, &(&1.stream == stream))

    others =
      all |> Enum.reject(&(&1.stream == stream)) |> MapSet.new(&String.downcase(&1.selector))

    shared =
      own
      |> Enum.filter(&MapSet.member?(others, String.downcase(&1.selector)))
      |> Enum.map(&finding(:error, :dkim_selector_shared, &1.selector))

    active = Enum.filter(own, &(&1.state == :active))

    rotation =
      case active do
        [] ->
          [finding(:error, :dkim_no_active_selector, stream)]

        entries ->
          entries
          |> Enum.filter(&rotation_due?(&1, now))
          |> Enum.map(&finding(:warning, :dkim_rotation_due, &1.selector))
      end

    shared ++ rotation
  end

  # CH-36
  @doc "Whether an active selector is due for rotation: six months have passed since it became active."
  @spec rotation_due?(selector(), DateTime.t()) :: boolean()
  def rotation_due?(%{activated_at: %DateTime{} = activated}, %DateTime{} = now),
    do: DateTime.compare(DateTime.shift(activated, month: @rotation_months), now) != :gt

  def rotation_due?(_selector, _now), do: false

  defp reject_needs_dkim(%{policy: "reject"}, dkim, domain) do
    if Enum.any?(dkim, &(&1.severity == :error)),
      do: [finding(:error, :dmarc_reject_requires_dkim, domain)],
      else: []
  end

  defp reject_needs_dkim(_dmarc, _dkim, _domain), do: []
end
