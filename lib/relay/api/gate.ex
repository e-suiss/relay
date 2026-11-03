defmodule Relay.Api.Gate do
  @moduledoc """
  What the template, layout and partial publications of the server API share (TP-31, TP-32): the dictionary data sets the gate reads (the active installation versions of `sensitive_terms` and `promotional_terms`, or the bundled ones), the `GateFinding` view of a finding, the answer to the gate's findings (a hard finding refuses, warnings refuse unless accepted), the difference between two definitions and the audit record digest.
  """

  @messages %{
    parse: "the cell does not parse or exceeds the static limits",
    variables: "a variable does not match the event schema",
    locale_not_supported: "the locale is not supported",
    translation_unapproved: "a machine translated cell has no approval",
    mjml_compile: "the MJML does not compile",
    mjml_default_asset: "an MJML element leaves its icon or arrow image to the compiler default",
    email_plain_text: "the email has no plain text body",
    sensitivity_missing: "the template has no sensitivity class",
    sensitive_terms: "sensitive terms matched and the sensitivity class is not confirmed",
    push_characters: "a push field can exceed 1024 characters",
    push_payload_size: "the push payload can exceed 4096 bytes",
    push_body_missing: "the push variant has no body",
    promotion: "a transactional or operational template contains a promotional call",
    legal_footer_missing: "the commercial template does not use the legal_footer helper",
    legal_footer_fields: "the legal footer misses required brand fields",
    icu_categories: "an ICU message lacks plural or select forms of the locale",
    sms_emoji: "the SMS template text contains emoji",
    worst_case_render: "the worst-case sample does not render",
    locale_variables: "the locales of a channel read different variables",
    sms_segments: "the SMS can need more than one segment in the worst case",
    sms_ucs2_characters: "characters force the SMS to UCS-2",
    sms_emoji_value: "an emoji in a value forces the SMS to UCS-2",
    whatsapp_parameter_length: "a WhatsApp parameter can exceed its component limit",
    email_html_size: "the rendered email HTML is large",
    email_subject_length: "the rendered email subject is longer than 78 characters",
    email_color_scheme: "the email has no color-scheme meta tag",
    email_amp: "AMP for Email is not supported",
    email_dir: "the right-to-left email has no dir attribute",
    a11y_lang: "the email html element has no lang attribute",
    a11y_img_alt: "an image has no alt text",
    a11y_image_only: "the email consists of images only",
    a11y_plain_text: "the email has no plain text body",
    a11y_contrast: "text and background colours have low contrast",
    a11y_first_line: "the first line does not carry the meaning",
    a11y_lock_screen: "a field shown on the lock screen carries a sensitive term"
  }
  @channels %{inbox: "in_app"}
  @sensitivity_checks [
    [:sensitivity_missing],
    [:sensitive_terms],
    [:sensitive_terms, :sensitivity_missing]
  ]

  # TP-46
  # TP-54
  @doc "The lint entries of `sensitive_terms` and `promotional_terms`: the active installation version of each, or the bundled one; read outside any transaction."
  @spec terms() :: %{sensitive: [map()], promotional: [map()]}
  def terms,
    do: %{sensitive: entries("sensitive_terms"), promotional: entries("promotional_terms")}

  defp entries(name) do
    content =
      case Relay.Datasets.active(Relay.Datasets.installation_scope(), name) do
        {:ok, %{content: content}} when is_map(content) -> content
        _none -> nil
      end

    Relay.Templates.term_entries(name, content)
  rescue
    _error -> Relay.Templates.term_entries(name, nil)
  end

  # TP-32
  @doc "The `GateFinding` view of a gate finding."
  @spec view(map()) :: map()
  def view(finding) do
    detail =
      if finding.pointer,
        do: Map.put(finding.detail, :pointer, finding.pointer),
        else: finding.detail

    %{
      "check" => Atom.to_string(finding.check),
      "level" => Atom.to_string(finding.level),
      "message" => Map.get(@messages, finding.check, "a publication check failed"),
      "detail" => detail
    }
    |> put("channel", channel(finding.channel))
    |> put("locale", finding.locale)
  end

  defp channel(nil), do: nil
  defp channel(channel), do: Map.get(@channels, channel, Atom.to_string(channel))

  defp put(view, _key, nil), do: view
  defp put(view, key, value), do: Map.put(view, key, value)

  # TP-32
  @doc "The answer to a gate's findings: `:ok`, or the refusal of a hard finding or of warnings that were not accepted. `kind` is `:template` for the template codes, `:asset` for layouts and partials."
  @spec outcome([map()], boolean(), :template | :asset) :: :ok | {:error, Relay.Error.t()}
  def outcome(findings, accept_warnings, kind) do
    {hard, warnings} = Enum.split_with(findings, &(&1.level == :hard))

    cond do
      hard != [] ->
        {:error, refusal(kind, hard, findings)}

      warnings != [] and not accept_warnings ->
        {:error,
         Relay.Error.new(
           :template_warnings_unacknowledged,
           "the publication gate found warnings; publish with accept_warnings",
           %{findings: Enum.map(warnings, &view/1)}
         )}

      true ->
        :ok
    end
  end

  defp refusal(:template, hard, findings) do
    case hard |> Enum.map(& &1.check) |> Enum.uniq() |> Enum.sort() do
      [:translation_unapproved] ->
        Relay.Error.new(
          :template_translation_unapproved,
          "a machine translated cell needs a person's approval"
        )

      checks when checks in @sensitivity_checks ->
        sensitivity(hard)

      [:locale_not_supported] ->
        Relay.Error.new(:locale_not_supported, "a locale of the template is not supported")

      _other ->
        gate_failed(findings)
    end
  end

  defp refusal(:asset, _hard, findings), do: gate_failed(findings)

  defp sensitivity(hard) do
    terms =
      for %{check: :sensitive_terms, detail: %{terms: found}} <- hard,
          match <- found,
          uniq: true,
          do: match.term

    message =
      if terms == [],
        do: "choose the template's sensitivity class",
        else: "confirm the sensitivity class for " <> Enum.join(terms, ", ")

    Relay.Error.new(:template_sensitivity_unconfirmed, message)
  end

  @doc "The refusal of a failed publication gate with every finding."
  @spec gate_failed([map()]) :: Relay.Error.t()
  def gate_failed(findings) do
    Relay.Error.new(:template_gate_failed, "a hard publication check failed", %{
      findings: Enum.map(findings, &view/1)
    })
  end

  # TP-31
  @doc "The difference of a definition from the live one, by top-level field and by channel/locale cell; `nil` without a live definition."
  @spec diff(map() | nil, map()) :: map() | nil
  def diff(nil, _definition), do: nil

  def diff(live, definition) do
    fields =
      for key <- Enum.sort(Map.keys(Map.merge(live, definition))),
          key != "cells",
          Map.get(live, key) != Map.get(definition, key),
          do: key

    before = cells(live)
    now = cells(definition)

    changed =
      for {cell, content} <- Enum.sort(now),
          Map.has_key?(before, cell),
          before[cell] != content,
          do: cell

    %{
      "fields" => fields,
      "cells_added" => now |> Map.keys() |> Kernel.--(Map.keys(before)) |> Enum.sort(),
      "cells_removed" => before |> Map.keys() |> Kernel.--(Map.keys(now)) |> Enum.sort(),
      "cells_changed" => changed
    }
  end

  defp cells(definition) do
    for {channel, by_locale} <- Map.get(definition, "cells") || %{},
        is_map(by_locale),
        {locale, content} <- by_locale,
        into: %{},
        do: {channel <> "/" <> locale, content}
  end

  @doc "The audit record digest of an action on a reference in a scope."
  @spec digest(Relay.Scope.t(), String.t(), String.t()) :: <<_::256>>
  def digest(scope, action, ref) do
    environment = Atom.to_string(scope.environment)
    canonical = Relay.Canonical.encode!([action, {:bytes, scope.tenant_id}, environment, ref])
    :crypto.hash(:sha256, canonical)
  end

  @doc "A field error of a validation failure."
  @spec field_error(String.t(), String.t(), String.t()) :: Relay.Error.t()
  def field_error(pointer, code, detail) do
    Relay.Error.new(:validation_failed, "the request breaks a field rule", %{
      errors: [%{pointer: pointer, code: code, detail: detail}]
    })
  end

  @doc "The lowercase hex form of a digest; `nil` stays `nil`."
  @spec hex(binary() | nil) :: String.t() | nil
  def hex(nil), do: nil
  def hex(digest), do: Base.encode16(digest, case: :lower)
end
