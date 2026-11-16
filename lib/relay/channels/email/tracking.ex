defmodule Relay.Channels.Email.Tracking do
  @moduledoc """
  Open and click tracking of an e-mail (CH-43, CH-44, CH-76, INV-25, DS-29). The open pixel and link wrapping are off unless the tenant turns them on for the message's category or template, and they are never on for the `security` class or for a message with a security subtype (`email_verification`, `otp_oob`), whatever the tenant's setting. Links the sender wrote, Access's `email_verification` link among them, are passed unchanged and unwrapped when tracking is off; a security e-mail has no redirect chain.

  The tenant's settings are `email.tracking.category.<category>` and `email.tracking.template.t_<template>` (`setting_key/2`), each `{"open_pixel": boolean, "wrap_links": boolean}`; the template's setting, when there is one, replaces the category's.

  When tracking is on, `instrument/4` rewrites the `href` of every `http`/`https` link of the HTML part to Relay's click endpoint `<base>/e/c/<token>` and, with the open pixel, appends an image of `<base>/e/o/<token>`; the plain text part is left as written. A token is opaque and signed:

      token = base64url(payload ‖ HMAC-SHA256(K_tracking, det-CBOR(["relay.tracking.v1", payload]))[0..16))
      payload = 0x01 ‖ kind ("o" or "c") ‖ environment (0 live, 1 test) ‖ tenant id (16) ‖ delivery id (16) ‖ link number (uint16) ‖ URL (UTF-8, click only)

  `K_tracking` is the tenant environment's tracking key in the key store; the HMAC is computed inside it. The click redirect is a plain redirect to the signed URL, never a state change (CH-44, CH-76).
  """

  alias Relay.Error

  @context "relay.tracking.v1"
  @version 1
  @tag_bytes 16
  @max_url 2048
  @max_links 65_535
  @href ~r/(<a\b[^>]*?\bhref\s*=\s*)(["'])(https?:\/\/[^"'\s]+)\2/i
  @pixel ~s(<img src="URL" width="1" height="1" alt="" style="display:none;border:0">)

  @type plan :: %{open_pixel: boolean(), wrap_links: boolean()}
  @type mac :: (binary() -> {:ok, <<_::256>>} | {:error, Error.t()})
  @type kind :: :open | :click
  @type decoded :: %{
          scope: Relay.Scope.t(),
          delivery_id: Relay.Id.t(),
          kind: kind(),
          link: non_neg_integer(),
          url: String.t() | nil
        }

  # CH-43
  # CH-44
  # INV-25
  @doc "The tracking of a message: `class`, `security_subtype` (or `nil`) and the tenant's `open_pixel` and `wrap_links` settings, both off when absent."
  @spec plan(map()) :: plan()
  def plan(%{class: class} = message) do
    if untrackable?(class, Map.get(message, :security_subtype)) do
      %{open_pixel: false, wrap_links: false}
    else
      %{
        open_pixel: Map.get(message, :open_pixel, false) == true,
        wrap_links: Map.get(message, :wrap_links, false) == true
      }
    end
  end

  # CH-44
  @doc "Whether no tracking can ever be turned on for a message of `class` with `security_subtype`."
  @spec untrackable?(String.t(), String.t() | nil) :: boolean()
  def untrackable?(class, security_subtype), do: class == "security" or security_subtype != nil

  # DS-29
  @doc "The setting keys of a category's and a template's tracking, the template's last; a missing key is left out."
  @spec setting_keys(String.t() | nil, String.t() | nil) :: [String.t()]
  def setting_keys(category, template) do
    [{"category", category}, {"template", template}]
    |> Enum.filter(fn {_target, key} -> is_binary(key) and key != "" end)
    |> Enum.map(fn {target, key} -> setting_key(target, key) end)
  end

  @doc "The setting key of the tracking of a `category` or `template` key; a template key's hyphens become underscores behind a `t_` prefix, so the key stays a setting key segment."
  @spec setting_key(String.t(), String.t()) :: String.t()
  def setting_key("category", key), do: "email.tracking.category." <> key

  def setting_key("template", key),
    do: "email.tracking.template.t_" <> String.replace(key, "-", "_")

  # DS-29
  @doc "The tenant's `open_pixel` and `wrap_links` for a message from its settings: the template's setting replaces the category's, and both are off without one."
  @spec configured(%{String.t() => term()}, String.t() | nil, String.t() | nil) :: map()
  def configured(settings, category, template) do
    found =
      category
      |> setting_keys(template)
      |> Enum.map(&Map.get(settings, &1))
      |> Enum.filter(&is_map/1)
      |> List.last(%{})

    %{
      open_pixel: Map.get(found, "open_pixel") == true,
      wrap_links: Map.get(found, "wrap_links") == true
    }
  end

  # CH-43
  # DS-29
  @doc "Applies a tracking plan to the HTML part of a delivery's e-mail; an e-mail without HTML or a plan with nothing on is returned unchanged. `base` is Relay's public root."
  @spec instrument(
          String.t() | nil,
          plan(),
          {Relay.Scope.t(), Relay.Id.t()},
          {String.t(), mac()}
        ) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def instrument(nil, _plan, _delivery, _endpoint), do: {:ok, nil}

  def instrument(html, %{open_pixel: false, wrap_links: false}, _delivery, _endpoint),
    do: {:ok, html}

  def instrument(html, plan, {scope, delivery_id}, {base, mac}) when is_binary(html) do
    with {:ok, wrapped} <- wrap(html, plan.wrap_links, scope, delivery_id, base, mac) do
      pixel(wrapped, plan.open_pixel, scope, delivery_id, base, mac)
    end
  end

  defp wrap(html, false, _scope, _delivery_id, _base, _mac), do: {:ok, html}

  defp wrap(html, true, scope, delivery_id, base, mac) do
    parts = Regex.split(@href, html, include_captures: true)

    parts
    |> Enum.reduce_while({:ok, [], 0}, fn part, {:ok, acc, n} ->
      case link(part, n + 1, scope, delivery_id, base, mac) do
        {:ok, nil} -> {:cont, {:ok, [part | acc], n}}
        {:ok, rewritten} -> {:cont, {:ok, [rewritten | acc], n + 1}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc, _n} -> {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, _error} = error -> error
    end
  end

  defp link(part, n, scope, delivery_id, base, mac) do
    case Regex.run(@href, part) do
      [^part, prefix, mark, href] when n <= @max_links ->
        url = unescape(href)

        if byte_size(url) <= @max_url,
          do: wrapped({prefix, mark}, url, n, scope, delivery_id, {base, mac}),
          else: {:ok, nil}

      _other ->
        {:ok, nil}
    end
  end

  defp wrapped({prefix, mark}, url, n, scope, delivery_id, {base, mac}) do
    with {:ok, token} <- token(scope, delivery_id, {:click, n, url}, mac),
         do: {:ok, prefix <> mark <> base <> "/e/c/" <> token <> mark}
  end

  defp pixel(html, false, _scope, _delivery_id, _base, _mac), do: {:ok, html}

  defp pixel(html, true, scope, delivery_id, base, mac) do
    with {:ok, token} <- token(scope, delivery_id, :open, mac) do
      image = String.replace(@pixel, "URL", base <> "/e/o/" <> token)

      case String.split(html, ~r/<\/body>/i, parts: 2, include_captures: true) do
        [head, close, tail] -> {:ok, head <> image <> close <> tail}
        [_whole] -> {:ok, html <> image}
      end
    end
  end

  defp unescape(href) do
    href
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  # CH-43
  @doc "Signs the tracking token of a delivery's open pixel (`:open`) or of its link number `n` to `url` (`{:click, n, url}`)."
  @spec token(
          Relay.Scope.t(),
          Relay.Id.t(),
          :open | {:click, pos_integer(), String.t()},
          mac()
        ) :: {:ok, String.t()} | {:error, Error.t()}
  def token(scope, <<_::128>> = delivery_id, target, mac) do
    {kind, n, url} =
      case target do
        :open -> {?o, 0, ""}
        {:click, n, url} when n in 1..@max_links and is_binary(url) -> {?c, n, url}
      end

    head = <<@version, kind, environment(scope.environment)>>
    payload = head <> scope.tenant_id <> delivery_id <> <<n::16>> <> url

    with {:ok, tag} <- tag(payload, mac),
         do: {:ok, Base.url_encode64(payload <> tag, padding: false)}
  end

  # CH-43
  # CH-44
  @doc "Reads and verifies a tracking token of `kind`; `mac_of` gives the key function of the token's scope. Any token that does not verify is `:invalid`; an unavailable key store is its error."
  @spec read(String.t(), kind(), (Relay.Scope.t() -> mac())) ::
          {:ok, decoded()} | {:error, :invalid | Error.t()}
  def read(token, kind, mac_of) when is_binary(token) and is_function(mac_of, 1) do
    with {:ok, raw} <- base64(token),
         {:ok, payload, tag} <- split(raw),
         {:ok, decoded} <- payload(payload, kind),
         {:ok, expected} <- tag(payload, mac_of.(decoded.scope)) do
      if Relay.Crypto.secure_compare(tag, expected), do: {:ok, decoded}, else: {:error, :invalid}
    end
  end

  def read(_token, _kind, _mac_of), do: {:error, :invalid}

  defp base64(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :invalid}
    end
  end

  defp split(raw) when byte_size(raw) > @tag_bytes do
    size = byte_size(raw) - @tag_bytes
    <<payload::binary-size(^size), tag::binary-size(@tag_bytes)>> = raw
    {:ok, payload, tag}
  end

  defp split(_raw), do: {:error, :invalid}

  defp payload(
         <<@version, kind, env, tenant::binary-16, delivery::binary-16, n::16, url::binary>>,
         expected
       )
       when env in [0, 1] do
    scope = Relay.Scope.new!(tenant, if(env == 0, do: :live, else: :test))

    case {kind, expected} do
      {?o, :open} when n == 0 and url == "" ->
        {:ok, %{scope: scope, delivery_id: delivery, kind: :open, link: 0, url: nil}}

      {?c, :click} when n > 0 and url != "" ->
        if String.valid?(url),
          do: {:ok, %{scope: scope, delivery_id: delivery, kind: :click, link: n, url: url}},
          else: {:error, :invalid}

      _other ->
        {:error, :invalid}
    end
  end

  defp payload(_payload, _kind), do: {:error, :invalid}

  defp tag(payload, mac) do
    case mac.(Relay.Canonical.encode!([@context, {:bytes, payload}])) do
      {:ok, <<tag::binary-size(@tag_bytes), _rest::binary>>} -> {:ok, tag}
      {:error, %Error{}} = error -> error
    end
  end

  defp environment(:live), do: 0
  defp environment(:test), do: 1
end
