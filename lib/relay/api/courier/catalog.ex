defmodule Relay.Api.Courier.Catalog do
  @moduledoc """
  The protected catalogue of Access's messages (E-108, E-10, E-12), pure. Every `relay.message.<name>.v1` type of Access's message schema (`contracts/access/relay-message.v1.schema.json`, an exact copy of Access's own) is either delivered or, for `iys_consent`, written to İYS (E-109). A delivered type has one entry: its message class (`security` for the account and security notices, E-11; `action_required` for the CIBA invitation and the approval requests, E-15, E-16), whether it carries a sign-in or verification secret (its request then names the security subtype of its channel, INV-22), the protected workflow and the producer-owned template of the same key (`access-<name>`), Turkish and English text built only from the schema's fields, and the field of its link. A link is a secret and travels only into the rendered message; `client`, `binding_message` and every other value enter the render as plain text that the template engine escapes for its channel.

  The workflow has one step for each of e-mail, SMS and push; a request narrows it to the channel of its recipient's address. Its event schema is the type's `data` schema without the recipient, the locale and the mailbox age, which never enter the event.
  """

  @schema_file Path.expand("../../../../contracts/access/relay-message.v1.schema.json", __DIR__)
  @external_resource @schema_file
  @schema @schema_file |> File.read!() |> Jason.decode!()
  @prefix "relay.message."
  @suffix ".v1"
  @envelope ~w(recipient locale recipient_valid_since)
  @verification ~w(otp sms_otp magic_link reset_intent)
  @approvals ~w(ciba_invite approval_requested approval_inline push_approval device_code_approval
                guardian_consent support_access_request)

  @labels %{"tr" => "Bağlantıyı açın", "en" => "Open the link"}

  @texts %{
    "otp" => [
      "Doğrulama kodunuz",
      "Your verification code",
      "Kodunuz: {{ code }}. {{ expires_at | datetime }} saatine kadar geçerlidir. Bu kodu kimseyle paylaşmayın.",
      "Your code is {{ code }}. It is valid until {{ expires_at | datetime }}. Do not share it with anyone.",
      nil
    ],
    "sms_otp" => [
      "Doğrulama kodunuz",
      "Your verification code",
      "Kodunuz: {{ code }}. {{ expires_at | datetime }} saatine kadar geçerlidir. Bu kodu kimseyle paylaşmayın.",
      "Your code is {{ code }}. It is valid until {{ expires_at | datetime }}. Do not share it with anyone.",
      nil
    ],
    "magic_link" => [
      "Giriş bağlantınız",
      "Your sign-in link",
      "Giriş yapmak için bağlantıyı açın. Bağlantı {{ expires_at | datetime }} saatine kadar geçerlidir.",
      "Open the link to sign in. It is valid until {{ expires_at | datetime }}.",
      "link"
    ],
    "password_changed" => [
      "Parolanız değiştirildi",
      "Your password was changed",
      "Parolanız {{ at | datetime }} tarihinde değiştirildi. Bu işlemi siz yapmadıysanız hesabınızı hemen koruyun.",
      "Your password was changed on {{ at | datetime }}. If this was not you, secure your account now.",
      nil
    ],
    "new_sign_in" => [
      "Yeni giriş",
      "New sign-in",
      "Hesabınıza {{ at | datetime }} tarihinde yeni bir giriş yapıldı ({{ method }}). Bu siz değilseniz hesabınızı koruyun.",
      "There was a new sign-in to your account on {{ at | datetime }} ({{ method }}). If this was not you, secure your account.",
      nil
    ],
    "account_status" => [
      "Hesap durumunuz değişti",
      "Your account status changed",
      "Hesabınızın yeni durumu: {{ status }} ({{ at | datetime }}).",
      "Your account is now {{ status }} ({{ at | datetime }}).",
      nil
    ],
    "recovery_requested" => [
      "Hesap kurtarma istendi",
      "Account recovery requested",
      "Hesabınız için {{ at | datetime }} tarihinde kurtarma istendi. Bu siz değilseniz hemen bildirin.",
      "Recovery of your account was requested on {{ at | datetime }}. If this was not you, report it now.",
      nil
    ],
    "recovery_cooling" => [
      "Hesap kurtarma bekliyor",
      "Account recovery is waiting",
      "{{ at | datetime }} tarihinde başlayan hesap kurtarma {{ until | datetime }} tarihinde tamamlanacak. Bu siz değilseniz hemen iptal edin.",
      "The account recovery started on {{ at | datetime }} completes on {{ until | datetime }}. If this was not you, cancel it now.",
      nil
    ],
    "recovery_completed" => [
      "Hesap kurtarma tamamlandı",
      "Account recovery completed",
      "Hesabınızın kurtarılması {{ at | datetime }} tarihinde tamamlandı.",
      "Recovery of your account completed on {{ at | datetime }}.",
      nil
    ],
    "recovery_codes_regenerated" => [
      "Kurtarma kodları yenilendi",
      "Recovery codes regenerated",
      "Kurtarma kodlarınız {{ at | datetime }} tarihinde yenilendi; eski kodlar artık geçmez.",
      "Your recovery codes were regenerated on {{ at | datetime }}; the old codes no longer work.",
      nil
    ],
    "second_factor_enabled" => [
      "İki adımlı doğrulama açıldı",
      "Two-step verification turned on",
      "Hesabınızda {{ at | datetime }} tarihinde iki adımlı doğrulama açıldı.",
      "Two-step verification was turned on for your account on {{ at | datetime }}.",
      nil
    ],
    "new_method" => [
      "Yeni giriş yöntemi eklendi",
      "New sign-in method added",
      "Hesabınıza {{ at | datetime }} tarihinde yeni bir giriş yöntemi eklendi. Bu siz değilseniz hesabınızı koruyun.",
      "A new sign-in method was added to your account on {{ at | datetime }}. If this was not you, secure your account.",
      nil
    ],
    "email_changed" => [
      "E-posta adresiniz değişti",
      "Your e-mail address changed",
      "Hesabınızın e-posta adresi {{ at | datetime }} tarihinde değiştirildi. Bu siz değilseniz hemen bildirin.",
      "The e-mail address of your account was changed on {{ at | datetime }}. If this was not you, report it now.",
      nil
    ],
    "deletion_scheduled" => [
      "Hesap silme planlandı",
      "Account deletion scheduled",
      "Hesabınız {{ until | datetime }} tarihinde silinecek. Vazgeçmek için bu tarihten önce giriş yapın.",
      "Your account will be deleted on {{ until | datetime }}. Sign in before then to cancel.",
      nil
    ],
    "deletion_completed" => [
      "Hesabınız silindi",
      "Your account was deleted",
      "Hesabınız {{ at | datetime }} tarihinde silindi.",
      "Your account was deleted on {{ at | datetime }}.",
      nil
    ],
    "inactivity_notice" => [
      "Hesabınız kullanılmıyor",
      "Your account is inactive",
      "Hesabınız uzun süredir kullanılmıyor. Etkin kalması için {{ until | datetime }} tarihinden önce giriş yapın.",
      "Your account has not been used for a long time. Sign in before {{ until | datetime }} to keep it active.",
      nil
    ],
    "signup_existing" => [
      "Kayıt denemesi",
      "Sign-up attempt",
      "Bu adresle {{ at | datetime }} tarihinde yeniden kayıt olunmaya çalışıldı. Zaten bir hesabınız var; giriş yapabilirsiniz.",
      "Someone tried to sign up with this address on {{ at | datetime }}. You already have an account and can sign in.",
      nil
    ],
    "ownership_handover" => [
      "Sahiplik devri",
      "Ownership handover",
      "{{ at | datetime }} tarihinde başlayan sahiplik devri {{ until | datetime }} tarihinde tamamlanacak.",
      "The ownership handover started on {{ at | datetime }} completes on {{ until | datetime }}.",
      nil
    ],
    "membership_cooling" => [
      "Üyelik değişikliği bekliyor",
      "Membership change pending",
      "Üyeliğinizdeki değişiklik {{ until | datetime }} tarihinde geçerli olacak.",
      "The change to your membership takes effect on {{ until | datetime }}.",
      nil
    ],
    "guardian_consent" => [
      "Veli onayı gerekiyor",
      "Guardian consent needed",
      "Velisi olduğunuz bir hesap için onayınız gerekiyor. Lütfen {{ until | datetime }} tarihine kadar yanıt verin.",
      "An account you are the guardian of needs your consent. Please answer by {{ until | datetime }}.",
      nil
    ],
    "reset_intent" => [
      "Parola sıfırlama",
      "Password reset",
      "Parolanızı sıfırlamak için bağlantıyı açın. Bağlantı {{ expires_at | datetime }} saatine kadar geçerlidir. Bu isteği siz yapmadıysanız bu iletiyi yok sayın.",
      "Open the link to reset your password. It is valid until {{ expires_at | datetime }}. If you did not ask for this, ignore this message.",
      "link"
    ],
    "export_ready" => [
      "Verileriniz hazır",
      "Your data export is ready",
      "Verilerinizin kopyası hazır. Bağlantı {{ expires_at | datetime }} tarihine kadar geçerlidir.",
      "A copy of your data is ready. The link is valid until {{ expires_at | datetime }}.",
      "link"
    ],
    "invitation" => [
      "Davet",
      "Invitation",
      "{{ inviter }} sizi {{ organization }} kuruluşuna davet etti. Davet {{ expires_at | datetime }} tarihine kadar geçerlidir.",
      "{{ inviter }} invited you to {{ organization }}. The invitation is valid until {{ expires_at | datetime }}.",
      "link"
    ],
    "agent_suspended" => [
      "Ajan askıya alındı",
      "Agent suspended",
      "{{ agent }} adlı ajan {{ at | datetime }} tarihinde askıya alındı.",
      "The agent {{ agent }} was suspended on {{ at | datetime }}.",
      nil
    ],
    "agent_sponsor_needed" => [
      "Ajan için sorumlu gerekiyor",
      "Agent needs a sponsor",
      "{{ agent }} adlı ajanın bir sorumluya ihtiyacı var ({{ at | datetime }}).",
      "The agent {{ agent }} needs a sponsor ({{ at | datetime }}).",
      nil
    ],
    "agent_connection_needs_reconnect" => [
      "Bağlantı yenilenmeli",
      "Connection needs to be renewed",
      "{{ connection }} bağlantısının yeniden kurulması gerekiyor. Bağlantı {{ expires_at | datetime }} tarihine kadar geçerlidir.",
      "The connection {{ connection }} needs to be set up again. The link is valid until {{ expires_at | datetime }}.",
      "link"
    ],
    "device_code_approval" => [
      "Cihaz girişi onayı",
      "Device sign-in approval",
      "{{ client }} bir cihazda giriş için onayınızı bekliyor. İstek {{ expires_at | datetime }} saatine kadar geçerlidir.",
      "{{ client }} is waiting for your approval to sign in on a device. The request is valid until {{ expires_at | datetime }}.",
      "link"
    ],
    "approval_requested" => [
      "Onay isteği",
      "Approval request",
      "{{ requester }} onayınızı bekliyor. İstek {{ expires_at | datetime }} saatine kadar geçerlidir.",
      "{{ requester }} is waiting for your approval. The request is valid until {{ expires_at | datetime }}.",
      "link"
    ],
    "sso_setup_link" => [
      "Tek oturum açma kurulumu",
      "Single sign-on setup",
      "{{ organization }} için tek oturum açma kurulum bağlantınız. Bağlantı {{ expires_at | datetime }} tarihine kadar geçerlidir.",
      "Your single sign-on setup link for {{ organization }}. It is valid until {{ expires_at | datetime }}.",
      "link"
    ],
    "ciba_invite" => [
      "Giriş onayı isteği",
      "Sign-in approval request",
      "{{ client }} onayınızı istiyor. Kontrol metni: {{ binding_message | default: \"-\" }}. İstek {{ expires_at | datetime }} saatine kadar geçerlidir.",
      "{{ client }} asks for your approval. Check text: {{ binding_message | default: \"-\" }}. The request is valid until {{ expires_at | datetime }}.",
      "link"
    ],
    "upstream_subject_conflict" => [
      "Hesap eşleştirme sorunu",
      "Account matching problem",
      "{{ upstream }} üzerinden gelen kimlik başka bir hesapla çakışıyor ({{ at | datetime }}).",
      "The identity from {{ upstream }} conflicts with another account ({{ at | datetime }}).",
      nil
    ],
    "ldap_credential_changed" => [
      "Uygulama parolası değişti",
      "Application password changed",
      "{{ application }} için uygulama parolası değişti: {{ change }} ({{ at | datetime }}).",
      "The application password for {{ application }} changed: {{ change }} ({{ at | datetime }}).",
      nil
    ],
    "push_approval" => [
      "Onay isteği",
      "Approval request",
      "{{ application }}: {{ action }}. İstek {{ expires_at | datetime }} saatine kadar geçerlidir.",
      "{{ application }}: {{ action }}. The request is valid until {{ expires_at | datetime }}.",
      nil
    ],
    "semantic_notice" => [
      "Hesabınızla ilgili bildirim",
      "A notice about your account",
      "Bir işlem için dikkatiniz gerekiyor: {{ intent }}",
      "Your attention is needed: {{ intent }}",
      "link"
    ],
    "security_authority_notice" => [
      "Yetki bildirimi",
      "Authority notice",
      "{{ name }} ile ilgili bir yetki değişikliği oldu ({{ event }}, {{ at | datetime }}). Gözden geçirmek için bağlantıyı açın.",
      "There was an authority change about {{ name }} ({{ event }}, {{ at | datetime }}). Open the link to review it.",
      "review_link"
    ],
    "passkey_setup_invite" => [
      "Geçiş anahtarı kurulumu",
      "Passkey setup",
      "{{ organization }} bir geçiş anahtarı kurmanızı istiyor. Bağlantı {{ expires_at | datetime }} tarihine kadar geçerlidir.",
      "{{ organization }} asks you to set up a passkey. The link is valid until {{ expires_at | datetime }}.",
      "link"
    ],
    "critical_interrupt" => [
      "Kritik bildirim",
      "Critical notice",
      "{{ agent }}: {{ summary }} ({{ at | datetime }}).",
      "{{ agent }}: {{ summary }} ({{ at | datetime }}).",
      nil
    ],
    "support_access_request" => [
      "Destek erişimi isteği",
      "Support access request",
      "{{ organization }} için {{ case }} kaydında {{ minutes }} dakikalık destek erişimi isteniyor ({{ scope }}). İstek {{ expires_at | datetime }} saatine kadar geçerlidir.",
      "Support asks for {{ minutes }} minutes of access to {{ organization }} for case {{ case }} ({{ scope }}). The request is valid until {{ expires_at | datetime }}.",
      "link"
    ],
    "support_access_notice" => [
      "Destek erişimi bildirimi",
      "Support access notice",
      "{{ operator }}, {{ organization }} için {{ case }} kaydında destek erişimi: {{ event }} ({{ at | datetime }}).",
      "Support access by {{ operator }} to {{ organization }} for case {{ case }}: {{ event }} ({{ at | datetime }}).",
      nil
    ],
    "breakglass_used" => [
      "Acil erişim kullanıldı",
      "Emergency access used",
      "{{ organization }} için acil erişim kullanıldı ({{ incident }}, {{ approvals }} onay). Erişim {{ at | datetime }} tarihinde başladı ve {{ until | datetime }} tarihine kadar sürer.",
      "Emergency access to {{ organization }} was used ({{ incident }}, {{ approvals }} approvals). It started on {{ at | datetime }} and lasts until {{ until | datetime }}.",
      nil
    ],
    "breakglass_alarm" => [
      "Acil erişim alarmı",
      "Emergency access alarm",
      "{{ account }} hesabı için acil erişim alarmı: {{ alarm }} ({{ at | datetime }}).",
      "Emergency access alarm for the account {{ account }}: {{ alarm }} ({{ at | datetime }}).",
      "link"
    ],
    "approval_inline" => [
      "Onay isteği",
      "Approval request",
      "{{ render }} İstek {{ expires_at | datetime }} saatine kadar geçerlidir.",
      "{{ render }} The request is valid until {{ expires_at | datetime }}.",
      nil
    ],
    "review_campaign" => [
      "Erişim gözden geçirme",
      "Access review",
      "{{ campaign }} kapsamında {{ items }} kaydı gözden geçirmeniz gerekiyor. Son tarih: {{ due | datetime }}.",
      "The review {{ campaign }} has {{ items }} items for you. It is due on {{ due | datetime }}.",
      "link"
    ],
    "domain_recovered" => [
      "Alan adı kurtarıldı",
      "Domain recovered",
      "{{ domain }} yeniden doğrulandı (konum {{ position }}; {{ lost_after | datetime }} sonrası kayıp; {{ at | datetime }}).",
      "{{ domain }} was verified again (position {{ position }}; lost after {{ lost_after | datetime }}; {{ at | datetime }}).",
      "link"
    ],
    "domain_handover" => [
      "Alan adı devri",
      "Domain handover",
      "{{ domain }} alan adı {{ provider }} sağlayıcısına devrediliyor (konum {{ position }}, {{ at | datetime }}).",
      "{{ domain }} is being handed over to {{ provider }} (position {{ position }}, {{ at | datetime }}).",
      "link"
    ],
    "divergence_notice" => [
      "Kayıt ayrışması",
      "Log divergence",
      "{{ domain }} için {{ items }} kayıt ayrıştı ({{ from }}-{{ to }}, {{ at | datetime }}).",
      "{{ items }} entries of {{ domain }} diverged ({{ from }}-{{ to }}, {{ at | datetime }}).",
      "link"
    ],
    "equivocation_alarm" => [
      "Çelişkili kayıt alarmı",
      "Equivocation alarm",
      "{{ domain }} için {{ witness }} tanığı çelişkili bir kayıt bildirdi (boyut {{ size }}, {{ at | datetime }}).",
      "The witness {{ witness }} reported an equivocation of {{ domain }} (size {{ size }}, {{ at | datetime }}).",
      "link"
    ],
    "degraded_alarm" => [
      "Hizmet bozulması",
      "Service degraded",
      "{{ dependency }} bileşeni {{ since | datetime }} tarihinden beri bozuk çalışıyor.",
      "The {{ dependency }} component has been degraded since {{ since | datetime }}.",
      "link"
    ],
    "decommission_notice" => [
      "Hizmet kapanışı",
      "Decommission notice",
      "{{ domain }} {{ closes_at | datetime }} tarihinde kapanacak.",
      "{{ domain }} closes on {{ closes_at | datetime }}.",
      "link"
    ],
    "algorithm_retired" => [
      "Algoritma emekliye ayrıldı",
      "Algorithm retired",
      "{{ domain }} için {{ algorithm }} algoritması emekliye ayrıldı (yeniden bağlama boyutu {{ reanchor_size }}, {{ at | datetime }}).",
      "The algorithm {{ algorithm }} of {{ domain }} was retired (re-anchor size {{ reanchor_size }}, {{ at | datetime }}).",
      "link"
    ]
  }

  @type kind :: :deliver | :iys
  @type entry :: %{
          name: String.t(),
          type: String.t(),
          key: String.t(),
          class: String.t(),
          category: String.t(),
          verification: boolean(),
          link: String.t() | nil
        }

  # E-108
  @doc "The vendored Access message schema, decoded."
  @spec schema() :: map()
  def schema, do: @schema

  # E-108
  @doc "Every `relay.message.*.v1` type Access's schema defines."
  @spec types() :: [String.t()]
  def types, do: get_in(@schema, ["properties", "type", "enum"])

  # E-108
  @doc "Whether a CloudEvents type is in Access's message namespace."
  @spec courier_type?(term()) :: boolean()
  def courier_type?(type) when is_binary(type),
    do: String.starts_with?(type, @prefix) and String.ends_with?(type, @suffix)

  def courier_type?(_type), do: false

  # E-108
  # E-109
  @doc "What Relay does with a type: `{:deliver, entry}`, `:iys` for the İYS consent record, `:unknown` outside the schema."
  @spec lookup(String.t()) :: {:deliver, entry()} | :iys | :unknown
  def lookup("relay.message.iys_consent.v1"), do: :iys

  def lookup(type) when is_binary(type) do
    with true <- type in types(),
         name = name(type),
         [_, _, _, _, link] <- Map.get(@texts, name) do
      {:deliver, entry(type, name, link)}
    else
      _other -> :unknown
    end
  end

  defp name(type),
    do: type |> String.replace_prefix(@prefix, "") |> String.replace_suffix(@suffix, "")

  defp entry(type, name, link) do
    class = if name in @approvals, do: "action_required", else: "security"

    %{
      name: name,
      type: type,
      key: "access-" <> String.replace(name, "_", "-"),
      class: class,
      category: class,
      verification: name in @verification,
      link: link
    }
  end

  # E-108
  # E-10
  @doc "The protected workflow definition of an entry."
  @spec workflow(entry()) :: map()
  def workflow(%{} = entry) do
    steps =
      for channel <- ~w(email sms push) do
        %{
          "type" => "channel",
          "key" => channel <> "_step",
          "channel" => channel,
          "template" => entry.key
        }
      end

    %{
      "name" => "Access " <> String.replace(entry.name, "_", " "),
      "category" => entry.category,
      "message_class" => entry.class,
      "event_schema" => event_schema(entry.type),
      "steps" => steps
    }
  end

  # E-108
  @doc "The `data` schema of a type without the envelope fields, the event schema of its workflow."
  @spec event_schema(String.t()) :: map()
  def event_schema(type) do
    data = get_in(@schema, ["$defs", type]) || %{"type" => "object"}
    required = Enum.reject(Map.get(data, "required", []), &(&1 in @envelope))

    data
    |> Map.update("properties", %{}, &Map.drop(&1, @envelope))
    |> Map.put("required", required)
    |> Map.delete("description")
  end

  # E-108
  @doc "The data fields of a type that enter its event: every field of its `data` schema but the envelope fields."
  @spec data_fields(String.t()) :: [String.t()]
  def data_fields(type), do: Map.keys(event_schema(type)["properties"])

  # E-108
  # E-35
  @doc "The producer-owned template definition of an entry: e-mail, SMS and push cells in Turkish and English."
  @spec template(entry()) :: map()
  def template(%{name: name, link: link}) do
    [tr_heading, en_heading, tr_body, en_body, _link] = Map.fetch!(@texts, name)
    texts = [{"tr", tr_heading, tr_body}, {"en", en_heading, en_body}]

    cells =
      for channel <- ~w(email sms push), into: %{} do
        {channel,
         Map.new(texts, fn {locale, heading, body} ->
           {locale, cell(channel, heading, body, link, Map.fetch!(@labels, locale))}
         end)}
      end

    %{"default_locale" => "tr", "sensitivity" => "personal", "cells" => cells}
  end

  defp cell("sms", heading, body, link, _label),
    do: %{"body" => heading <> ": " <> body <> sms_link(link)}

  defp cell("push", heading, body, _link, _label), do: %{"title" => heading, "body" => body}

  defp cell("email", heading, body, link, label) do
    %{
      "subject" => heading,
      "html_kind" => "raw_html",
      "html" => email_html(heading, body, link, label),
      "text" => heading <> "\n\n" <> body <> text_link(link, label)
    }
  end

  defp sms_link(nil), do: ""
  defp sms_link(field), do: " {{ " <> field <> " }}"

  defp text_link(nil, _label), do: ""
  defp text_link(field, label), do: "\n\n" <> label <> ": {{ " <> field <> " }}"

  defp email_html(heading, body, link, label) do
    anchor =
      case link do
        nil -> ""
        field -> ~s(<p><a href="{{ ) <> field <> ~s( }}">) <> label <> "</a></p>"
      end

    IO.iodata_to_binary([
      ~s(<!doctype html><html><head><meta charset="utf-8">),
      ~s(<meta name="color-scheme" content="light dark"></head><body>),
      "<h1>",
      heading,
      "</h1><p>",
      body,
      "</p>",
      anchor,
      "</body></html>"
    ])
  end

  # INV-22
  # API-24
  @doc "The security subtype a request of an entry names for a recipient's address kind: a sign-in or verification secret is `email_verification` by e-mail and `otp_oob` by phone; `nil` otherwise."
  @spec subtype(entry(), String.t()) :: String.t() | nil
  def subtype(%{verification: true}, "email"), do: "email_verification"
  def subtype(%{verification: true}, "phone"), do: "otp_oob"
  def subtype(_entry, _kind), do: nil

  # E-108
  @doc "The delivered names of the catalogue; with `iys_consent` they are every type of the schema."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@texts)
end
