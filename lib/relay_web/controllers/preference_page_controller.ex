defmodule RelayWeb.PreferencePageController do
  @moduledoc false

  use RelayWeb, :controller

  alias Relay.Api.PreferencePage
  alias RelayWeb.Links

  @consent_channels ~w(email sms voice whatsapp)
  @active ~w(active)
  @style "body{font-family:system-ui,sans-serif;max-width:56rem;margin:2rem auto;padding:0 1rem;line-height:1.5;color:#1a1a1a;background:#fff}table{border-collapse:collapse;width:100%}th,td{border:1px solid #767676;padding:.5rem;text-align:left;vertical-align:top}small{display:block;color:#3d3d3d}form{margin:.25rem 0}.choice{font:inherit;min-width:8rem;min-height:2.75rem;padding:.5rem 1rem;color:#1a1a1a;background:#fff;border:2px solid #1a1a1a;font-weight:400}.choices{display:flex;flex-wrap:wrap;gap:.5rem}"

  @copy %{
    "en" => %{
      title: "Notification preferences",
      intro: "Choose which notifications you receive on which channel. A change applies at once.",
      saved: "Your preferences are saved.",
      refused: "This change could not be applied.",
      last_channel: "A locked category keeps at least one channel on.",
      category: "Category",
      all: "All",
      on: "On",
      off: "Off",
      turn_on: "Turn on",
      turn_off: "Turn off",
      digest_on: "On · digest",
      channel_off: "All off",
      channel_turn_off: "Turn all off",
      channel_turn_on: "Turn all on",
      row_off: "Turn this category off",
      locked: "On (locked)",
      beneficiary_subscriber: "Locked to protect your account.",
      beneficiary_tenant: "Locked because the service needs it to serve you.",
      last_open: "At least one channel stays on.",
      admin: "Your administrator turned this off",
      device: "Turned off in device settings",
      consent_waiting: "Consent pending",
      consent_give: "Give consent",
      step_title: "How do you want to receive these notifications?",
      instant: "Instant",
      digest: "Digest",
      never: "Never",
      back: "Back",
      muted: "Muted",
      unmute: "Unmute",
      muted_title: "Muted notifications",
      quiet_title: "Quiet hours",
      quiet_none: "No quiet hours are set.",
      quiet_every_day: "Every day",
      quiet_start: "Start",
      quiet_end: "End",
      quiet_save: "Save quiet hours",
      quiet_clear: "Remove quiet hours",
      quiet_email_on: "E-mail also follows quiet hours.",
      quiet_email_off: "E-mail does not follow quiet hours.",
      consents_title: "Your consents",
      consents_note: "Consents are kept by your account and shown here only to read.",
      consents_none: "No consent is recorded.",
      consents_manage: "Manage my consents",
      statuses: %{
        "none" => "Not given",
        "pending" => "Pending",
        "pending_iys" => "Pending",
        "active" => "Given",
        "revoked" => "Withdrawn",
        "expired" => "Expired"
      },
      channels: %{
        "push" => "Push",
        "web_push" => "Browser",
        "email" => "E-mail",
        "sms" => "SMS",
        "voice" => "Voice call",
        "whatsapp" => "WhatsApp",
        "in_app" => "In-app"
      },
      invalid: "This link is not valid.",
      expired: "This link has expired.",
      unavailable: "This page cannot be opened right now. Please try again later."
    },
    "tr" => %{
      title: "Bildirim tercihleri",
      intro: "Hangi bildirimi hangi kanaldan alacağınızı seçin; değişiklik hemen geçerlidir.",
      saved: "Tercihleriniz kaydedildi.",
      refused: "Bu değişiklik uygulanamadı.",
      last_channel: "Kilitli bir kategoride en az bir kanal açık kalır.",
      category: "Kategori",
      all: "Tümü",
      on: "Açık",
      off: "Kapalı",
      turn_on: "Aç",
      turn_off: "Kapat",
      digest_on: "Açık · özet",
      channel_off: "Tümü kapalı",
      channel_turn_off: "Tümünü kapat",
      channel_turn_on: "Tümünü aç",
      row_off: "Bu kategoriyi kapat",
      locked: "Açık (kilitli)",
      beneficiary_subscriber: "Hesabınızın güvenliği için kilitli.",
      beneficiary_tenant: "Hizmetin size sunulabilmesi için gerekli olduğundan kilitli.",
      last_open: "En az bir kanal açık kalır.",
      admin: "Yöneticiniz kapattı",
      device: "Cihaz ayarlarından kapalı",
      consent_waiting: "İzin bekleniyor",
      consent_give: "İzin ver",
      step_title: "Bu bildirimleri nasıl almak istersiniz?",
      instant: "Anında al",
      digest: "Özet al",
      never: "Hiç alma",
      back: "Geri dön",
      muted: "Sessize alındı",
      unmute: "Sesi aç",
      muted_title: "Sessize alınan bildirimler",
      quiet_title: "Sessiz saatler",
      quiet_none: "Sessiz saat ayarlanmadı.",
      quiet_every_day: "Her gün",
      quiet_start: "Başlangıç",
      quiet_end: "Bitiş",
      quiet_save: "Sessiz saati kaydet",
      quiet_clear: "Sessiz saati kaldır",
      quiet_email_on: "E-postalar da sessiz saate uyar.",
      quiet_email_off: "E-postalar sessiz saate uymaz.",
      consents_title: "İzinleriniz",
      consents_note: "İzinleriniz hesabınızda tutulur; burada yalnız gösterilir.",
      consents_none: "Kayıtlı izin yok.",
      consents_manage: "İzinlerimi yönet",
      statuses: %{
        "none" => "Verilmedi",
        "pending" => "Bekleniyor",
        "pending_iys" => "Bekleniyor",
        "active" => "Verildi",
        "revoked" => "Geri alındı",
        "expired" => "Süresi doldu"
      },
      channels: %{
        "push" => "Anlık bildirim",
        "web_push" => "Tarayıcı",
        "email" => "E-posta",
        "sms" => "SMS",
        "voice" => "Sesli arama",
        "whatsapp" => "WhatsApp",
        "in_app" => "Uygulama içi"
      },
      invalid: "Bu bağlantı geçerli değil.",
      expired: "Bu bağlantının süresi doldu.",
      unavailable: "Bu sayfa şu anda açılamıyor. Lütfen daha sonra yeniden deneyin."
    }
  }

  # X-51
  # X-18
  # X-22
  # PC-17
  # PC-18
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"token" => token} = params) do
    case PreferencePage.read(token) do
      {:ok, model} -> render_model(conn, 200, model, params, notice(params))
      {:error, reason} -> message(conn, reason)
    end
  end

  # X-51
  # X-20
  # PC-15
  # PC-17
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"token" => token} = params) do
    case PreferencePage.change(token, Map.delete(params, "token")) do
      :ok ->
        conn
        |> put_resp_header("location", conn.request_path <> "?saved=1")
        |> send_resp(303, "")

      {:error, %Relay.Error{} = error} ->
        refused(conn, token, error)

      {:error, reason} ->
        message(conn, reason)
    end
  end

  defp refused(conn, token, error) do
    case PreferencePage.read(token) do
      {:ok, model} -> render_model(conn, 422, model, %{}, refusal(error))
      {:error, reason} -> message(conn, reason)
    end
  end

  defp notice(%{"saved" => "1"}), do: :saved
  defp notice(_params), do: nil

  defp refusal(%Relay.Error{code: :preference_last_channel}), do: :last_channel
  defp refusal(_error), do: :refused

  defp render_model(conn, status, model, params, notice) do
    text = copy(model.locale)
    view = model.preferences

    body =
      case step(params, view) do
        %{} = cell ->
          step_body(cell, text, conn.request_path)

        nil ->
          [
            notice_html(notice, text),
            tag("p", text.intro),
            matrix(model, text),
            muted(view, text),
            quiet(view["profile"], text),
            consents(model, text)
          ]
      end

    page(conn, status, model.locale, text.title, body)
  end

  # PC-17
  defp step(%{"category" => category, "channel" => channel}, view) do
    Enum.find(view["cells"], fn cell ->
      cell["category"] == category and cell["channel"] == channel and
        cell["digest_allowed"] and PreferencePage.changeable?(cell, view)
    end)
  end

  defp step(_params, _view), do: nil

  # PC-17
  # X-20
  defp step_body(cell, text, path) do
    [
      tag("p", cell["category_name"] <> " · " <> channel_label(cell["channel"], text)),
      tag("p", text.step_title),
      ~s(<form method="post">),
      hidden("action", "choose"),
      hidden("category", cell["category"]),
      hidden("channel", cell["channel"]),
      ~s(<div class="choices">),
      choice("instant", text.instant),
      choice("digest", text.digest),
      choice("none", text.never),
      "</div></form>",
      ["<p>", link(path, text.back), "</p>"]
    ]
  end

  defp choice(value, label) do
    [
      ~s(<button type="submit" class="choice" name="choice" value="),
      escape(value),
      ~s(">),
      escape(label),
      "</button>"
    ]
  end

  defp notice_html(nil, _text), do: ""
  defp notice_html(key, text), do: [~s(<p role="status">), escape(Map.fetch!(text, key)), "</p>"]

  # X-18
  # X-22
  defp matrix(model, text) do
    view = model.preferences
    channels = view["cells"] |> Enum.map(& &1["channel"]) |> Enum.uniq()
    categories = view["cells"] |> Enum.map(& &1["category"]) |> Enum.uniq()

    [
      "<table><thead><tr>",
      tag("th", text.category, ~s( scope="col")),
      Enum.map(channels, &channel_head(&1, view, text)),
      tag("th", text.all, ~s( scope="col")),
      "</tr></thead><tbody>",
      Enum.map(categories, &row(&1, model, text)),
      "</tbody></table>"
    ]
  end

  # X-22
  # PC-12
  defp channel_head(channel, view, text) do
    off? = Enum.any?(view["channels"], &(&1["channel"] == channel and &1["value"] == "opt_out"))

    {state, label, value} =
      if off?,
        do: {text.channel_off, text.channel_turn_on, "unset"},
        else: {"", text.channel_turn_off, "opt_out"}

    fields = [hidden("action", "channel"), hidden("channel", channel), hidden("value", value)]

    [
      ~s(<th scope="col">),
      escape(channel_label(channel, text)),
      small(state),
      form(fields, label),
      "</th>"
    ]
  end

  defp row(category, model, text) do
    cells = Enum.filter(model.preferences["cells"], &(&1["category"] == category))

    [
      "<tr>",
      tag("th", hd(cells)["category_name"], ~s( scope="row")),
      Enum.map(cells, &["<td>", cell(&1, model, text), "</td>"]),
      ["<td>", row_off(category, cells, text), "</td>"],
      "</tr>"
    ]
  end

  # X-22
  defp row_off(category, cells, text) do
    open = Enum.filter(cells, &(&1["effective"] and not &1["disabled_by_admin"]))

    if open != [] and not Enum.any?(cells, &(&1["locked"] or &1["digest_allowed"])),
      do: form([hidden("action", "row_off"), hidden("category", category)], text.row_off),
      else: ""
  end

  # PC-6
  # PC-15
  # PC-16
  # X-44
  defp cell(%{"disabled_by_admin" => true}, _model, text), do: escape(text.admin)

  defp cell(cell, model, text) do
    view = model.preferences

    if consent_waiting?(cell, model),
      do: waiting(text),
      else: [state(cell, view, text), control(cell, view, text), device(cell, text)]
  end

  # X-44
  # PC-21
  defp consent_waiting?(cell, model) do
    Map.get(model.classes, cell["category"]) == "marketing" and
      cell["channel"] in @consent_channels and
      not Enum.any?(model.consents, &active?(&1, cell["channel"]))
  end

  defp active?(consent, channel) do
    consent["channel"] == channel and is_nil(consent["brand_subtenant_id"]) and
      consent["status"] in @active
  end

  defp waiting(text) do
    case Links.consent_url() do
      "https://" <> _rest = url ->
        [escape(text.consent_waiting), " · ", link(url, text.consent_give)]

      _none ->
        escape(text.consent_waiting)
    end
  end

  # PC-6
  defp state(%{"locked" => true, "effective" => true} = cell, view, text) do
    beneficiary =
      case cell["lock_beneficiary"] do
        "subscriber" -> text.beneficiary_subscriber
        _tenant -> text.beneficiary_tenant
      end

    last = if PreferencePage.changeable?(cell, view), do: "", else: small(text.last_open)
    [escape(text.locked), small(beneficiary), last]
  end

  defp state(%{"effective" => true, "digest_allowed" => true} = cell, view, text) do
    if view["profile"]["digest"][cell["category"]] == "digest",
      do: escape(text.digest_on),
      else: escape(text.on)
  end

  defp state(%{"effective" => true}, _view, text), do: escape(text.on)
  defp state(_cell, _view, text), do: escape(text.off)

  # PC-17
  # X-20
  defp control(cell, view, text) do
    label = if cell["effective"], do: text.turn_off, else: text.turn_on
    target = [hidden("category", cell["category"]), hidden("channel", cell["channel"])]

    cond do
      not PreferencePage.changeable?(cell, view) ->
        ""

      cell["digest_allowed"] ->
        [~s(<form method="get">), target, button(label), "</form>"]

      true ->
        value = if cell["effective"], do: "opt_out", else: "opt_in"
        form([hidden("action", "set"), target, hidden("value", value)], label)
    end
  end

  # PC-16
  defp device(%{"disabled_in_device_settings" => true}, text), do: small(text.device)
  defp device(_cell, _text), do: ""

  defp muted(view, text) do
    levels = [{"workflow", view["workflows"]}, {"scope_key", view["scope_keys"]}]

    rows =
      for {level, list} <- levels, entry <- list, entry["value"] == "opt_out" do
        fields = [hidden("action", "unmute"), hidden("level", level), hidden("key", entry[level])]

        [
          "<li>",
          escape(entry[level]),
          " · ",
          escape(text.muted),
          form(fields, text.unmute),
          "</li>"
        ]
      end

    if rows == [],
      do: "",
      else: [tag("h2", text.muted_title), "<ul>", rows, "</ul>"]
  end

  # PC-57 (5)
  defp quiet(profile, text) do
    ranges = profile["quiet_hours"]

    current =
      if ranges == [],
        do: tag("p", text.quiet_none),
        else: ["<ul>", Enum.map(ranges, &range/1), "</ul>"]

    save = [
      hidden("action", "quiet_hours"),
      tag("p", text.quiet_every_day),
      time_input("start", text.quiet_start),
      time_input("end", text.quiet_end)
    ]

    clear =
      if ranges == [],
        do: "",
        else: form([hidden("action", "quiet_hours_clear")], text.quiet_clear)

    [
      tag("h2", text.quiet_title),
      current,
      form(save, text.quiet_save),
      clear,
      quiet_email(profile["quiet_hours_email"], text)
    ]
  end

  defp range(r), do: tag("li", r["day"] <> " " <> r["start"] <> "–" <> r["end"])

  defp quiet_email(included?, text) do
    {state, label, value} =
      if included?,
        do: {text.quiet_email_on, text.turn_off, "false"},
        else: {text.quiet_email_off, text.turn_on, "true"}

    [
      tag("p", state),
      form([hidden("action", "quiet_hours_email"), hidden("value", value)], label)
    ]
  end

  defp time_input(name, label) do
    [
      "<label>",
      escape(label),
      ~s( <input type="time" required name="),
      escape(name),
      ~s("></label> )
    ]
  end

  # X-44
  # X-21
  defp consents(model, text) do
    rows =
      Enum.map(model.consents, fn consent ->
        status = Map.get(text.statuses, consent["status"], consent["status"])
        tag("li", channel_label(consent["channel"], text) <> ": " <> status)
      end)

    list = if rows == [], do: tag("p", text.consents_none), else: ["<ul>", rows, "</ul>"]

    manage =
      case Links.consent_url() do
        "https://" <> _rest = url -> ["<p>", link(url, text.consents_manage), "</p>"]
        _none -> ""
      end

    [tag("h2", text.consents_title), tag("p", text.consents_note), list, manage]
  end

  defp channel_label(channel, text), do: Map.get(text.channels, channel, channel)

  defp form(fields, label), do: [~s(<form method="post">), fields, button(label), "</form>"]

  defp hidden(name, value),
    do: [~s(<input type="hidden" name="), escape(name), ~s(" value="), escape(value), ~s(">)]

  defp button(label), do: [~s(<button type="submit" class="choice">), escape(label), "</button>"]

  defp link(url, label),
    do: [~s(<a rel="noreferrer" href="), escape(url), ~s(">), escape(label), "</a>"]

  defp tag(name, text, attributes \\ ""),
    do: ["<", name, attributes, ">", escape(text), "</", name, ">"]

  defp small(""), do: ""
  defp small(text), do: tag("small", text)

  defp message(conn, reason) do
    text = copy(nil)
    page(conn, status(reason), nil, Map.fetch!(text, reason), "")
  end

  defp status(:invalid), do: 404
  defp status(:expired), do: 410
  defp status(:unavailable), do: 503

  defp copy(locale), do: Map.fetch!(@copy, language(locale))

  defp language(locale) when is_binary(locale) do
    language = locale |> String.split("-") |> hd() |> String.downcase()
    if is_map_key(@copy, language), do: language, else: "en"
  end

  defp language(_locale), do: "en"

  # sobelow_skip ["XSS.SendResp"]
  defp page(conn, status, locale, title, body) do
    html = [
      ~s(<!doctype html>\n<html lang="),
      language(locale),
      ~s(">\n<head>\n<meta charset="utf-8">\n),
      ~s(<meta name="viewport" content="width=device-width, initial-scale=1">\n),
      ~s(<meta name="robots" content="noindex">\n),
      tag("title", title),
      "\n<style>",
      @style,
      "</style>\n</head>\n<body>\n",
      tag("h1", title),
      "\n",
      body,
      "\n</body>\n</html>\n"
    ]

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end

  defp escape(text), do: Plug.HTML.html_escape(text)
end
