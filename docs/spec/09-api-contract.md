## 9. API sözleşmesi

**Bölüm notu.**

- **Kapsam.** Bu bölüm Relay'in dışa açık HTTP API'sinin ve olay kataloğunun sözleşme kurallarını yazar: sözleşmenin kaynağı, uç aileleri, ortak kurallar, idempotency ve iş anahtarı, alıcı upsert'i, CloudEvents girişi, batch, hata modeli, kimlik doğrulama ve ortamlar, hız ve kota, sürümleme, sayfalama, iptal, önizleme ve test uçları.
- **Kapsam dışında kalan ve başka bölümde yazılanlar.** Workflow, rota, digest, throttle, içerik tekilleştirmesi ve zamanlama semantiği §10'dadır. Şablon ve render kuralları §11'dedir. Teslim durumu projeksiyonu ve `rule_id` sözlüğü §14'te, inbox ve realtime protokolü §15'te, giden webhook ve olay teslimi §16'da, bekleme noktası ve ajan uçları §17'de, kiracı, anahtar saklama, kill switch ve denetim kaydı §18'dedir. Bu bölüm o konuların yalnız API yüzeyine dokunan kurallarını yazar.
- **Karar kimlikleri.** API-1 … API-71. Register §9.17'dedir.
- **Access ile hizalama.** Ortak API kuralları Access OP-65 ile aynı yöndedir (RFC 9457, opak imleçle sayfalama, değişiklik yapan her istekte `Idempotency-Key`, öneki olan opak kimlikler, `snake_case`, RFC 3339 UTC). Relay'e özgü farklar bu bölümde açıkça yazılıdır.

### 9.1 Sözleşme önce (API-1 … API-5)

1. **Kaynak belge.** HTTP API'si OpenAPI 3.1, olay güdümlü yüzey (giden webhook olayları, realtime yayınları, ajan olayları, bildirim türleri) AsyncAPI 3.1 ile yazılır. Gövde ve olay şemaları JSON Schema 2020-12'dir. Belgeler elle yazılır ve onaylanır; onaya bağlı kod onaydan sonra yazılır (API-1).
2. **Sözleşme testi.** Sunucu her CI çalışmasında bu belgelere karşı sözleşme testinden geçer. Belge ile davranış arasındaki her uyuşmazlık build'i kırar. Belge ile veritabanı kısıtı arasındaki kayma da bu testle yakalanır (ör. `Idempotency-Key` uzunluğu, API-11) (API-2).
3. **SDK üretimi.** Sunucu ve istemci SDK'ları bu belgelerden üretilir; üstüne ince, elle yazılmış bir kullanım katmanı eklenir. Dil listesi §08 ve §19'dadır (API-2).
4. **Olay kataloğu.** Bütün olay adları `noun.verb_past` biçimindedir ve tek bir sözlükte tutulur. Aynı kavram iki adla yayımlanmaz (ör. `cancelled` tek yazımdır). Katalog müşteri portalını, SDK'ları ve webhook doğrulayıcılarını besler (API-3).
5. **Limitler sayfası.** "Limitler, retry takvimleri, garantiler" sayfası kodla aynı kaynaktan üretilir; elle yazılmış ayrı bir kopya yoktur. Bir limit aşıldığında hata gövdesi hangi limitin aşıldığını (`limit`, `actual`) söyler (API-4).
6. **Çalışan örnekler.** Belgelerdeki her `curl` ve dil örneği CI'da `test` düzlemine karşı çalıştırılır. İlk bildirim tek bir `curl` çağrısıyla gönderilebilir (API-5).

### 9.2 Uç aileleri ve adresler (API-6, API-7)

| Aile | Kimlik | Kullanan | İçerik |
|---|---|---|---|
| Gönderim | Gizli API anahtarı (`publish` kapsamı) | Kiracı backend'i, üretici ürünler | `POST /v1/events` (yerel JSON ve CloudEvents), `POST /v1/events/batch`, kampanya gönderimi, iptal uçları |
| Yönetim | Gizli API anahtarı (yönetim kapsamları) veya operatör oturumu | Kiracı backend'i, panel, CLI, GitOps | Alıcı, cihaz, topic ve abonelik, workflow, şablon, layout, parça, rota, tekrar kuralı, webhook uçları, kill switch, API anahtarları |
| Sorgu | Gizli API anahtarı (`read` kapsamı) | Kiracı backend'i, panel | Olay, bildirim, teslim, deneme geçmişi ve olay defteri |
| İstemci | Abone jetonu | Tarayıcı, mobil uygulama, UI bileşenleri | Abonenin kendi inbox'ı, tercihleri ve kendi cihaz kaydı |
| Ajan | API anahtarı, abone jetonu veya Access jetonu (§17) | Ajanlar, ajan çerçeveleri, müşteri kodu | Bekleme noktası, posta kutusu, A2A ve MCP uçları |
| Gelen sağlayıcı olayları | Sağlayıcı başına imza doğrulaması | APNs, FCM, ESP'ler, SMS sağlayıcıları, İYS | Teslim raporu, bounce, şikâyet, gelen mesaj (§12, §14) |
| Operatör | Operatör oturumu + yeniden doğrulama | Kurulum operatörü | Platform düzeyi işlemler (§18) |

1. **Tek ana sürüm yolu.** Bütün aileler `/v1` altındadır; istemci uçları da dahil. Ayrı bir `/api` öneki yoktur (API-6).
2. **Her kavram için tek yol.** Aynı kavram iki mekanizmayla ifade edilmez (ör. hem gövde alanı hem başlık olarak idempotency; hem `routing` hem `channels` hem `providers` olarak kanal seçimi). Kanal başına ayrı gönderim ucu yoktur; kanalı orkestrasyon seçer. Workflow kimliği okunabilir bir slug'dır (`siparis-kargolandi`), sayısal kimlik değildir (API-6).
3. **Bölge adresi.** Her veri bölgesinin kendi temel adresi vardır; bir bölgenin adresi başka bölgenin verisine erişmez ve bölgeler arası yönlendirme yapmaz (§18). Access ile bağlı kurulumda bağlantı ayarı ve keşif belgesi §07'dedir (API-7).

### 9.3 Ortak kurallar (API-8, API-9)

1. Gövde `application/json; charset=utf-8`; hata gövdesi `application/problem+json` (API-8).
2. Alan adları istisnasız `snake_case` (API-8).
3. **Bilinmeyen alan reddedilir:** üst düzeyde, iç içe nesnelerde ve `overrides` altında bilinmeyen alan `422 unknown_field` üretir; sessizce yok sayılmaz (API-8).
4. `null` "açıkça temizle", alanın yokluğu "dokunma" demektir (API-8).
5. Zaman RFC 3339, UTC. Süreler ISO 8601 duration (`PT30M`, `P1D`); özel süre dili icat edilmez (API-8).
6. Tutarlar ve büyük tamsayılar JSON'da string taşınır; para `{ "amount": "1234.50", "currency": "TRY" }` biçimindedir (§11) (API-8).
7. Yalnız HTTPS, TLS 1.2 ve üstü. Düz HTTP isteği reddedilir; HSTS gönderilir (API-8).
8. Her yanıtta `Request-Id` başlığı; tekil kaynak yanıtları `object` alanı taşır (API-8).
9. **Kimlikler** opak, türe göre önekli ve zaman sıralıdır (ör. `evt_`, `ntf_`, `sub_`, `wfl_`, `tpl_`). Önek tablosu tek yerde, OpenAPI belgesinin ekinde tutulur. İç biçim §20'dedir (API-9).
10. **Başka kiracının kaynağı 404 döner**, 403 değil; varlık sızdırılmaz (API-9).

### 9.4 Idempotency ve iş anahtarı (API-10 … API-18)

Relay'de üç ayrı tekrar koruması vardır ve birbirinin yerine kullanılmaz:

| Koruma | Neye karşı | Anahtar | Ömür | Yer |
|---|---|---|---|---|
| `Idempotency-Key` | Aynı HTTP isteğinin kazara tekrarı (istemci zaman aşımı sonrası yeniden POST) | İstemcinin ürettiği başlık | 24 saat, sabit | Bu bölüm |
| `dedup_key` | Aynı iş olayının saatler/günler sonra yeniden gelmesi (outbox retry) | Üreticinin olay kimliğinden türetilen iş anahtarı | Bildirim kaydı saklandığı sürece | Bu bölüm |
| İçerik tekilleştirmesi | Hatalı istemci döngüsünün aynı içeriği tekrar tekrar göndermesi | Alıcı + kanal + içerik | Pencere; varsayılan kapalı | §10 |

Teslim defterindeki `(notification, recipient, channel)` tekilliği dördüncü, iç bir korumadır (§14).

1. **Zorunluluk.** Değişiklik yapan her istekte (POST, PUT, PATCH, DELETE) `Idempotency-Key` zorunludur; anahtarsız istek `400 idempotency_key_missing` ile reddedilir. GET'te yok sayılır. SDK'lar anahtarı otomatik üretir ve aynı çağrının retry'larında aynı anahtarı kullanır. Relay anahtarı içerikten türetmez. Tek istisna başlık ekleyemeyen CloudEvents üreticisidir; anahtar olay kimliği `(tenant, source, id)`'den türetilir (API-31) (API-10).
2. **Biçim ve kapsam.** Anahtar gövde alanı değil, başlıktır. Uzunluk 8–255 karakter; `[A-Za-z0-9_.:-]` önerilir; tırnaklı ve tırnaksız biçim kabul edilir, içeride tırnak soyulur. Anahtara kişisel veri konmaz (denetim kayıtlarında görünür). Kapsam `(tenant, environment, endpoint, key)`'dir (API-11).
3. **Ömür.** 24 saat, sabit sunucu politikası; istemci uzatamaz ya da kısaltamaz (API-12).
4. **Semantik.** Gövde parmak izi ham gövde baytlarının SHA-256 özetidir; JSON yeniden serileştirilmez.
   - Aynı anahtar + aynı gövde + tamamlanmış istek → ilk yanıtın birebir aynısı döner (durum kodu ve gövde dahil) ve `Idempotency-Replayed: true` başlığı eklenir.
   - Aynı anahtar + farklı gövde → `422 idempotency_key_reuse`; eski yanıt hiçbir koşulda dönmez.
   - Aynı anahtar, ilk istek hâlâ işleniyor → `409 idempotency_key_in_progress`, `Retry-After: 1`, `retryable: true` (API-13).
5. **Önbellek politikası.** Yalnız iş mantığı başladıktan sonra üretilen yanıtlar saklanır. 400, 401, 403 ve 429 saklanmaz. 5xx yalnız yürütme kısmen ilerlediyse saklanır; yan etkisiz bir arıza saklanmaz ve `retryable: true` döner (API-14).
6. **Depo.** Idempotency kaydı PostgreSQL'dedir; "ilk giren kazanır" tek atomik insert ile sağlanır (çakışmada yazmama). Kayıt Valkey'de tutulmaz; kaydın kaybı çift gönderim demektir (API-15).
7. **`dedup_key`.** Bildirim kaydında kiracı ve ortam içinde benzersizdir ve bildirim saklandığı sürece geçerlidir. Örnek: `access:password-changed:<event-id>`. Access ve diğer Suiss ürünleri her olayı kendi olay kimliğinden türetilmiş `dedup_key` ile gönderir. Aynı `dedup_key` ile gelen istek yeni bildirim açmaz; yanıt mevcut bildirimin kimliğini ve `duplicate_of` alanını döner ve tekrar kayda geçer (API-16).
8. **Meşru yeni istek.** "Kodu tekrar gönder" gibi meşru tekrar yeni `Idempotency-Key` ve yeni `dedup_key` ile gelir; idempotency ile karıştırılmaz (API-17).
9. **Garanti dili.** Relay'in garantisi "en az bir kez teslim + kalıcı idempotency ile etkin olarak bir kez işlem"dir. "Exactly-once" tek başına kullanılmaz. `Idempotency-Key` için "yaygın pratik" denir; IETF taslağının süresi dolduğu için "standarda uyum" denmez (API-18).

### 9.5 Gönderim: `POST /v1/events` (API-19 … API-27)

1. **Kabul ≠ teslim.** Uç `202 Accepted` döner; senkron teslim beklenmez. Yanıt `Location: /v1/events/{id}`, `Request-Id`, `Idempotency-Key` başlıklarını ve şu gövdeyi taşır: `object: event`, `id`, `workflow {key, version}`, `status: accepted`, `recipient_count`, `notifications [{recipient_id, notification_id}]`, `created_at`. Alıcı başına `notification_id` hemen döner (API-19).
2. **İstek alanları** (API-20):

| Alan | Anlam |
|---|---|
| `workflow` | Yayımlanmış workflow'un slug'ı. Yayımlanmamış workflow `422 workflow_not_published` |
| `to` | 1–100 alıcı; her biri alıcı nesnesi (`{id, email, phone, locale, timezone, ...}`), yalnız kimlik ya da topic (`{topic}`). Hedefsiz istek `422` |
| `actor` | Olayı yapan (insan, sistem, ajan); gönderen türü sınıftan ayrı alandır (§13) |
| `tenant` | Anahtarın kiracısı içindeki alt kiracı (API-25) |
| `data` | Olay verisi, en fazla 256 kB; workflow sürümünün olay şemasına karşı doğrulanır (API-27) |
| `dedup_key` | İş anahtarı (API-16) |
| `channels` | Filtre: workflow adımlarını daraltır, yeni adım eklemez |
| `overrides` | Kanal başına geçersiz kılmalar (API-23) |
| `send_at` | İleri tarihli gönderim; gelecekte ve en fazla 90 gün (§10). Geçmiş tarih `422` |
| `expires_at` | Bu andan sonra gönderilmez; `expired` terminal durumu (§10) |
| `priority` | `low` / `normal` / `high`; yalnız şerit içi ince ayar (API-22) |
| `security_subtype` | Yalnız `security` sınıfında: `otp_oob` / `email_verification` (API-24) |
| `on_expire` | Yalnız `security` sınıfında: `drop` (varsayılan) / `inbox_only` (§10) |
| `cancellation_key` | İsteğe bağlı iptal anahtarı; benzersiz olması gerekmez (API-57) |
| `retention` | `none`: render edilmiş içerik saklanmaz (API-26) |
| `metadata` | Opak; en fazla 16 anahtar, değer en fazla 512 karakter; olayda ve webhook'larda geri döner |

3. **Alıcı upsert'i** (API-21):
   - Alıcı nesnesi kimlik dışında iletişim bilgisi taşıyorsa (`to: {id, email, phone, locale, ...}`) alıcı o anda oluşturulur ya da güncellenir ve bildirim gönderilir.
   - Yalnız kimlik verilmişse ve alıcı yoksa `422 recipient_not_found` döner; hayalet alıcı oluşturulmaz.
   - Yalnız in-app inbox için alıcı, nesne biçiminde yalnız kimlikle açıkça oluşturulabilir (`to: {id}` nesnesi); adres kimliğin kendisidir. Düz string kimlik bu anlamı taşımaz.
   - Telefon E.164 biçimindedir. `test` ve `live` düzlemleri aynı davranır.
4. **Öncelik alanı.** Şerit yalnız mesaj sınıfından türer; `priority` mesajı başka şeride geçiremez. Her sınıfın öncelik tavanı vardır (ör. `marketing` en fazla `normal`); tavanı aşan değer tavana indirilir ve yanıtta `priority_clamped` uyarısı döner. Platform önceliği (APNs interruption level ve priority, FCM priority, Android kanal önemi, Web Push `Urgency`) sınıf + ince ayar ikilisinden tek eşleme tablosuyla türetilir (§12). `priority` kanal SLA'sı değildir (API-22).
5. **Overrides.** Birinci sınıf özelliktir, kaçış kapağı değildir.
   - Anahtarlar kanal adıdır (`email`, `sms`, `push`, `in_app`, `whatsapp`, `webhook`), sağlayıcı adı değil. `overrides.<kanal>.provider` yalnız doğrulanmış sağlayıcılar arasında daraltır (§12).
   - Öncelik tek yönlüdür: istek > adım > workflow > kiracı varsayılanı.
   - Sağlayıcıya özgü ham blok yalnız push (APNs, FCM, Web Push) ve WhatsApp'ta vardır.
   - Ham blok politika alanlarını ezemez: interruption level, priority, push türü, `critical` ve `time-sensitive` kuralları istek alanıyla delinemez (§12). Bu tür bir alan `422 policy_field_not_overridable` üretir.
   - `overrides.email.from` yalnız doğrulanmış alan adlarından olabilir; değilse `403 channel_not_configured` (API-23).
6. **Güvenlik alt türü.** `security` sınıfında hangi alt türün kullanılacağına gönderen karar verir; güven seviyesi gönderenin işidir. Relay seçilen alt türün kanal kurallarını uygular (`otp_oob` e-postaya gitmez, `email_verification` yalnız e-postadır; §10, §12). Bu alt türlerde `expires_at` zorunludur ve render edilmiş içerik saklanmaz (API-24).
7. **Alt kiracı.** `tenant` alanı API anahtarının kiracısı içindeki alt kiracıyı seçer; anahtarın kiracısı istekle ezilemez. Tanımsız ya da kapsamı uyuşmayan alt kiracıya giden teslim kaybolmaz: `skipped` + `scope_mismatch` olarak kaydedilir ve görünür (API-25).
8. **İçerik saklamama.** `security` dışındaki sınıflarda mesaj başına `retention: none` verilebilir; render edilmiş içerik saklanmaz, yalnız özeti ve şablon sürümü kalır. OTP ve doğrulama alt türlerinde bu davranış her zaman geçerlidir (§11). `retention: none` ile in-app kanalı birleşimi doğrulama hatasıyla reddedilir (§15 IN-46) (API-26).
9. **Kabulde doğrulama.** `data` workflow'un yayındaki sürümünün olay şemasına karşı doğrulanır; geçersizse `422 validation_failed` döner ve olay kuyruğa girmez (API-27).

### 9.6 CloudEvents girişi (API-28 … API-31)

1. **Biçimler.** Aynı giriş, yerel JSON'a ek olarak CloudEvents 1.0 HTTP bağlamasını kabul eder: binary mod (`ce-*` başlıkları), structured mod (`application/cloudevents+json`) ve toplu biçim (`application/cloudevents-batch+json`; batch kuralları §9.7) (API-28).
2. **Eşleme.** CloudEvents `type` kiracının tanımladığı eşleme tablosuyla bir workflow'a bağlanır. `(tenant, source, id)` bu olayın `dedup_key`'idir ve API-16 kuralına tabidir. `traceparent` uçtan uca taşınır (§20) (API-28).
3. **Eşlenmemiş tür.** Eşlemesi olmayan `type` senkron `422 event_type_not_mapped` üretir; bu bir sözleşme hatasıdır, politika kararı değildir (API-29).
4. **Sorumluluk sınırı.** Olayların müşteri tarafında hangi sırayla ve nasıl üretildiği Relay'in sorumluluğu değildir; Relay gelen olayı sözleşmeye göre işler. Müşteri veritabanını okuyan bağlayıcı kapsam dışıdır; isteyen Debezium veya Sequin gibi araçları CloudEvents çıkışıyla Relay'e bağlar ve dokümantasyonda rehber bulunur (API-30).
5. **Başlık ekleyemeyen üretici.** Değişiklik yapan her istekte `Idempotency-Key` zorunludur (API-10). Yalnız CloudEvents girişinde, `Idempotency-Key` başlığı olmayan istekte idempotency anahtarı `(tenant, source, id)`'den türetilir ve başlığın yerine geçer. Anahtar içerikten değil olay kimliğinden türediği için API-10 ile uyumludur. Başlık varsa başlık geçerlidir. İstisna yalnız bu uca uygulanır; yerel JSON girişi ve diğer uçlar başlıksız isteği reddetmeye devam eder (API-31).

### 9.7 Batch ve toplu gönderim (API-32 … API-35)

1. **Satır bazlı sonuç.** `POST /v1/events/batch` tümü-veya-hiç değildir. Durum haritası (API-32):

| Durum | Anlam |
|---|---|
| 202 | Bütün satırlar kabul edildi |
| 207 | Bazı satırlar kabul edildi, bazıları reddedildi |
| 422 | Hiçbir satır kabul edilmedi (tam başarısızlık asla 2xx dönmez) |
| 400 | Zarf bozuk |
| 413 | Satır ya da boyut limiti aşıldı (`batch_too_large`, `limit`, `actual`) |
| 401 / 403 / 429 | Kimlik, yetki, hız ya da kota; satır bazlı değil, bütün istek için |

2. **Eşleme ve hata.** İstemci her satıra `ref` verir (en fazla 128 karakter) ve sonucu `ref` ile eşler; `ref` yoksa `index` kullanılır. Her satır hatası tam bir RFC 9457 problem nesnesidir; tekil ve toplu uç aynı hata işleyicisini kullanır. `summary` alanı zorunludur (API-32).
3. **Limitler.** Parti başına 500 olay, olay başına 100 alıcı, gövde 5 MB, satır `data`'sı 256 kB. Limitler `Relay-Batch-Max-Events` ve `Relay-Batch-Max-Recipients-Per-Event` yanıt başlıklarıyla da duyurulur (API-33).
4. **Idempotency ve sıra.** Tek `Idempotency-Key` bütün partiyi kapsar; satır başına anahtar yoktur ve `ref` idempotency birimi değildir. Reddedilen satırlar yeni anahtarla yeni parti olarak gönderilir. Parti atomik ve sıralı değildir: `results` sırası girdi sırasıdır, işleme sırası garanti edilmez; aynı partide aynı alıcıya giden iki olayın teslim sırası belirsizdir. Parti, hız limitinden ve kotadan satır sayısı kadar tüketir (API-34).
5. **Kampanya gönderimi.** Büyük liste ya da topic gönderimi ayrı bir kampanya ucundan yapılır: "hazırla, sonra tetikle" (§10), kendi ilerleme kaydı, son teslim tarihi ve iptali vardır. Kiracı alıcı listesini istekte verir ya da topic seçer; öznitelik sorgulu segment yoktur (§10). Kiracı geneli duyuru, inbox'taki duyuru kaydıyla yapılır (§15) (API-35).

### 9.8 Hata modeli (API-36 … API-40)

1. **Problem nesnesi.** Her hata RFC 9457 `application/problem+json`'dır. Zorunlu alanlar: `type`, `title`, `status`, `code`, `retryable`. Uzantılar: `request_id`, `errors`, `retry_after`, `limit` ve `actual`, `required_scope` ve `granted_scopes`, `policy`.
   - `type` çözülebilir bir URL'dir (hata kodunun belge sayfası); `about:blank` kullanılmaz.
   - `title` sabit, `detail` değişkendir.
   - `code`, `type`'ın `snake_case` kopyasıdır (makine için bilinçli tekrar).
   - `instance` istek yoludur.
   - `errors` yalnız alan doğrulamasında bulunur; boşsa gönderilmez (API-36).
2. **Alan işaretçisi ve toplu rapor.** Alan hataları RFC 6901 JSON Pointer ile işaretlenir. Alt kodlar: `required`, `invalid_format`, `too_long`, `too_short`, `not_found`, `not_allowed`, `conflict`, `unsupported_value`. Doğrulama hataları toplu raporlanır; ilk hatada durma yoktur (API-37).
3. **`retryable` her hatada.** Her hata `retryable` taşır. `true` ise `Retry-After` delta-saniye olarak döner. Varsayılan tablo (API-38):

| Durum | `retryable` | `Retry-After` |
|---|---|---|
| 400, 401, 403, 404, 413, 422 | false | — |
| 409 `resource_conflict` | false | — |
| 409 `idempotency_key_in_progress` | true | 1 sn |
| 429 `rate_limited` | true | Kalan pencere |
| 429 `quota_exhausted` | false | — |
| 500 | true | 2 sn |
| 503 | true | 5–30 sn |
| 504 | true | 5 sn |

4. **Karar ≠ hata.** İzin yokluğu, tercih kapalı, sessiz saat, frekans tavanı, kill switch, İYS reddi gibi politika sonuçları API hatası değildir. İstek 202 ile kabul edilir; sonuç bildirim ve teslim kaydında `suppressed` ya da `skipped` + `rule_id` olarak raporlanır (§14). Politika sonucunun senkron döndüğü tek yerler önizleme, test ve `dry_run` uçlarıdır. Her karar yanıtı `decision` ve kural kimliği taşır. Tam başarısızlık hiçbir uçta 2xx dönmez (API-39).
5. **Hata kodu aileleri** (API-40):

| Aile | Kodlar |
|---|---|
| `auth_*` | `missing_credentials`, `malformed_credentials`, `invalid_api_key`, `revoked_api_key`, `expired_token`, `insufficient_scope`, `environment_mismatch`, `tenant_suspended` |
| `request_*` | `malformed_request`, `payload_too_large`, `unsupported_media_type`, `validation_failed`, `unknown_field`, `unsupported_api_version` |
| `idempotency_*` | `key_missing`, `key_invalid`, `key_reuse`, `key_in_progress` |
| `workflow_*` | `not_found`, `not_published`, `event_type_not_mapped` |
| `recipient_*` | `not_found`, `invalid` |
| `channel_*` | `not_configured`, `policy_field_not_overridable` |
| `quota_*` | `rate_limited`, `quota_exhausted`, `batch_too_large` |
| `platform_*` | `internal_error`, `service_unavailable`, `upstream_timeout` |

Politika sonuçları (`consent_missing`, `preference_blocked`, `quiet_hours` vb.) bu tabloda yoktur; onlar `rule_id` sözlüğündedir (§14).

### 9.9 Kimlik doğrulama ve ortamlar (API-41 … API-48, API-70, API-71)

1. **Sunucu kimliği.** Sunucu API'si gizli API anahtarıyla (Bearer) çağrılır. Anahtar biçimi tür × ortam önekini taşır (secret scanning için; önek tablosu API-9). Anahtar yalnız oluşturulduğunda bir kez gösterilir; yalnız özeti saklanır (§18); panelde son 4 karakteri görünür. Kurumsal kiracı için anahtarın üstüne mTLS (RFC 8705, sertifikaya bağlı) eklenebilir (API-41).
2. **Ortam anahtarın özelliğidir.** Her kiracının `live` ve `test` olmak üzere ayrı veri düzlemleri vardır: ayrı alıcılar, workflow yayınları, webhook uçları, idempotency uzayı ve kotalar. Ortam yalnız API anahtarında taşınır; gövde alanıyla seçilemez ya da değiştirilemez. `test` anahtarı `live` veriye erişemez; çapraz erişim `403 auth_environment_mismatch`. Webhook ucu, oluşturulduğu anahtarın ortamına bağlıdır ve değiştirilemez (API-42).
3. **Kapsamlar.** Kaba taneli, kısa bir kapsam listesi vardır; yayın (`publish`) ve okuma (`read`) ayrı kapsamlardır. Anahtar yönetimi hiçbir API anahtarına verilemez; yalnız operatör oturumu + yeniden doğrulama ile yapılır (§18). Eksik kapsam `403 auth_insufficient_scope` + `required_scope` ve `granted_scopes` döner (401 değil) (API-43).
4. **Anahtar yaşam döngüsü.** Döndürme (`roll`) eski anahtar için bir çakışma penceresi tanır; pencerede iki anahtar da çalışır. İptal anında etkilidir. `last_used_at` ve `last_used_ip` tutulur; uzun süre kullanılmayan anahtar için uyarı gösterilir. Kiracı başına anahtar sayısının üst sınırı vardır (API-44).
5. **İstemci API'si.** Tarayıcı ve mobil istemci gizli anahtar taşımaz.
   - Kiracı backend'i `POST /v1/subscribers/{id}/tokens` ile kısa ömürlü abone jetonu alır. Access'li kiracılarda Access jetonu RFC 8693 token exchange ile Relay abone jetonuna çevrilir; kiracı backend'ine kod gerekmez.
   - Relay, Access jetonunu doğrudan inbox erişimi için kabul etmez.
   - Abone jetonunun kapsamı dardır (`inbox:read`, `inbox:write`, `preferences`) ve yalnız o abonenin inbox'ına ve tercihlerine dokunur.
   - İstemci uçları bir izin listesidir; `POST /v1/events` istemciye hiçbir koşulda açılmaz.
   - Mobil SDK olay tetiklemez, abone profili ve izin kaydı yazmaz, gizli anahtar tutmaz.
   - Abone jetonu iptal edildiğinde ya da abone askıya alındığında açık realtime bağlantıları sunucudan kesilir (§15) (API-45).
6. **İstemcinin cihaz kaydı.** Mobil SDK push jetonunu ayrı ve dar `devices:write` abone jetonu kapsamıyla kaydeder. Kapsam yalnız jeton sahibi abonenin kendi cihazını kaydetme, güncelleme ve kaldırmaya izin verir; başka aboneye cihaz bağlayamaz, cihaz jetonunu geri okuyamaz. Cihaz kaydı için kiracı backend'ine kod gerekmez; sunucu API'sindeki cihaz uçları (§9.16) ayrıca kullanılabilir (API-46).
7. **Kimlik hata sözleşmesi.** 401'de `WWW-Authenticate: Bearer` başlığı ve `auth_*` kodu döner. Geçersiz anahtar denemeleri IP başına sınırlanır. Anahtar karşılaştırması sabit sürelidir. Askıya alınmış kiracı bütün giriş noktalarında (API, kampanya, CloudEvents, ajan uçları) `403 auth_tenant_suspended` alır (§18) (API-47).
8. **Üç sunucu kimliği yolu.** Sunucu API'sine üç yolla erişilir ve üçü birlikte desteklenir: API anahtarı (madde 1), OAuth2 client credentials (madde 9) ve Access servis jetonu (madde 10). mTLS (RFC 8705) her biriyle ek katman olarak kullanılabilir. Üç yol aynı kapsam modeline (API-43), ortam kuralına (API-42), hata sözleşmesine (API-47) ve kiracı askı kuralına uyar. Anahtar ve kimlik yönetimi hiçbir yolla verilen kimlik bilgisine açılmaz; yalnız operatör oturumu + yeniden doğrulama ile yapılır (API-48).
9. **OAuth2 client credentials.** Kiracı kendi IdP'sini ortam başına kaydeder (issuer, JWKS adresi, beklenen `aud`, kapsam eşleme tablosu). Backend IdP'den kısa ömürlü JWT erişim jetonu alır ve Bearer olarak gönderir. Relay imzayı kayıtlı JWKS ile, `iss`, `aud`, `exp` ve `nbf`'yi her istekte doğrular; izinli algoritma listesi dışındaki ve imzasız jeton reddedilir. IdP kapsamları kiracının eşleme tablosuyla Relay kapsamlarına çevrilir; eşlenmeyen kapsam yetki vermez. Ortam ve kiracı jetondaki bir alandan değil kayıtlı IdP bağlantısından gelir (API-70).
10. **Access servis jetonu.** Access bağlı kiracıda backend, Access'in verdiği servis jetonuyla sunucu API'sine erişir. Relay jetonu Access'in yayımladığı anahtarlarla doğrular; `aud` Relay sunucu API'si olmalıdır. Kiracı Access ↔ Relay kiracı eşlemesinden (§7) gelir; kapsamlar API-43 kapsamlarına eşlenir. Bu jeton yalnız sunucu API'sinde geçerlidir; inbox, tercih ve realtime erişimi her zaman Relay abone jetonuyladır (API-45) (API-71).

### 9.10 Hız limiti ve kota (API-49 … API-51)

1. **Başlıklar.** `RateLimit` ve `RateLimit-Policy` başlıkları (IETF taslağı) ile uyumluluk için `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` (delta saniye) gönderilir. `Retry-After` her zaman delta-saniyedir (API-49).
2. **Katmanlar ve ağırlık.** API hız limiti kiracı kapsamındadır ve iki katmanlıdır: kısa pencere (burst) ve uzun pencere (sustained); daha kısıtlayıcı olan raporlanır. Bir API anahtarına kiracı limitinin altında ayrı bir limit verilebilir. Uç sınıfına göre ağırlık uygulanır: GET 1, tekil olay 1, batch satır sayısı kadar, kampanya başlatma sabit yüksek ağırlık, şablon yazma ve önizleme orta ağırlık (API-50).
3. **Kota ≠ hız limiti; yük ≠ istemci hatası.**
   - Gönderim kotası senkron reddedilir: `429 quota_exhausted`, `retryable: false`, `Retry-After` yok. Kota eşiklerinde kiracıya olay gider.
   - API hız limiti `429 rate_limited` (retryable) döner.
   - Sistem aşırı yükü `503`'tür, 429 değildir.
   - Sıcak yol hiçbir zaman senkron sağlayıcı gönderimine bağlanmaz; sağlayıcı limitleri müşteriye 429 olarak yansımaz, teslimi yavaşlatır ve teslim durumunda görünür.
   - OTP ve toplu gönderim ayrı kovalardadır. Aşırı yükte kabul kontrolü yalnız ertelenebilir sınıfları reddeder; `security` sınıfı kabul kontrolünde reddedilmez (API-51).
   - Kota tükendiğinde `security` sınıfı kiracının ek payı (POLICY DEFAULT %10) bitene kadar kabul edilir; ek pay da bitince `security` de `429 quota_exhausted` alır. Kiracının sınıf başına kota payı dolan sınıf aynı hatayı alır; hata gövdesi aşılan kotayı ve sınıfı söyler (§18 TN-52) (API-51).

### 9.11 Sürümleme (API-52 … API-55)

1. **Yol + tarih.** Ana sürüm yoldadır (`/v1`) ve kalıcıdır; yeni bir ana sürüm yolu yalnız kavramsal model değişirse açılır. Ana sürüm içindeki davranış tarihli sürüm başlığıyla seçilir: `Relay-Version: YYYY-MM-DD`. Başlık yoksa kiracının sabitlenmiş sürümü geçerlidir. Yeni hesapta ilk başarılı istekteki güncel sürüm otomatik sabitlenir. "En güncel sürüm" hiçbir zaman varsayılan değildir. Geçersiz değer `400 unsupported_api_version` + desteklenen sürüm listesi döner (API-52).
2. **Kırıcı değişiklik tanımı** (API-53):

| Kırıcı değil | Kırıcı |
|---|---|
| Yanıta yeni alan; enum'a yeni değer (istemci bilinmeyen değeri ele almalıdır); yeni uç, isteğe bağlı alan, sorgu parametresi; `detail` metni; alan sırası; yeni olay türü; yeni yanıt başlığı; null olabilirliğin daraltılması | Alan kaldırma ya da yeniden adlandırma; tür değişikliği; enum değeri kaldırma; zorunlu alan ekleme; varsayılan davranış değişikliği; durum kodu değişikliği; anlam değişikliği; limit düşürme; kimlik doğrulamanın sıkılaştırılması |

3. **Destek penceresi.** Her tarihli sürüm en az 24 ay desteklenir. Kaldırma en az 12 ay önce duyurulur: e-posta, panel bandı, değişiklik günlüğü ve `Deprecation` (RFC 9745), `Sunset` (RFC 8594), `Link rel="deprecation"` başlıkları. 90 gündür hiç kullanılmayan sürüm erken kaldırılabilir. İçeride tek model ve sürüm başına dönüştürücü zinciri vardır (API-54).
4. **Webhook, SDK, beta.** Webhook payload sürümü ayrıdır, uç oluşturulurken sabitlenir; API sürümünü yükseltmek webhook payload'ını değiştirmez (§16). SDK sürümü API sürümüne sabittir; paket güncellemesi davranış değiştirmez. Beta özellikler `Relay-Beta: <özellik>` başlığıyla açılır, sürüm sözleşmesinin dışındadır ve yanıtta `"beta": true` taşır (API-55).

### 9.12 Sayfalama (API-56)

1. Liste uçları opak imleçle sayfalanır; offset ve sayfa numarası yoktur.
2. Parametreler `limit` (1–100, varsayılan 50), `starting_after`, `ending_before`. Yanıt `{ "object": "list", "data": [...], "has_more": ..., "next_cursor": ... }`.
3. İmleçler imzalıdır ve kiracı (istemci uçlarında kiracı + abone) kapsamına bağlıdır; başka bağlamda kullanılamaz.
4. Liste uçlarında ilişkili nesneler otomatik genişletilmez; `expand` yalnız tekil kaynakta kullanılır.
5. SDK'lar tembel sayfalama yineleyicisi sunar.

### 9.13 İptal (API-57 … API-59)

1. **Uçlar.** `POST /v1/events/{id}/cancel`, `POST /v1/notifications/{id}/cancel`, `POST /v1/events/cancel_by_key` (`cancellation_key` + isteğe bağlı alıcı ve kanal filtresi), kampanya iptali, tekrar kuralı iptali; bekleme noktası iptali §17'dedir. İptal için önceden anahtar tanımlamak gerekmez; olay ya da bildirim kimliği yeterlidir. `cancellation_key` benzersiz olmak zorunda değildir ve eşleşen bütün bekleyenleri hedefler. Yanıt `200` + sayımlardır (`cancelled`, `already_sent`, `not_found`, `details[]`); 204 dönmez (API-57).
2. **Sıra ve tombstone.** İptal komutu, tetiklemeyle aynı sıralı anahtardan işlenir. İptal anında koşu henüz yoksa tombstone yazılır; sonradan gelen koşu tombstone'u görür ve `cancelled` olur. Zamanlanmış her iş iptal edilebilir: `send_at`, bekleme adımı, digest penceresi, tekrar kuralı, kampanya (API-58).
3. **Sınır.** İptal yalnız sağlayıcıya henüz verilmemiş teslimleri durdurur. Gönderilmiş SMS, e-posta ve push geri alınamaz; dokümantasyonda açıkça yazılır. Tek istisna in-app'tir: teslim edilmiş inbox öğesi geri çekilebilir. Durum yazımı her yerde `cancelled`'dır (API-59).

### 9.14 Önizleme, test ve gönderim modu (API-60 … API-63)

1. **Önizleme.** `POST /v1/workflows/{key}/preview` ve `POST /v1/templates/{key}/preview` senkron `200` döner: adım başına `would_send`, `rule_id`, render edilmiş içerik, uyarılar (ör. `missing_variable`); SMS için `encoding`, `segments`, `characters`. Önizleme taslak ya da yayındaki sürüm üzerinde çalışabilir (API-60).
2. **Test gönderimi.** `POST /v1/workflows/{key}/test` `live` düzlemde gerçek sağlayıcıya gönderir; alıcılar kiracının doğrulanmış test alıcıları listesinden en fazla 5 kişi ya da cihazdır. Gönderim `is_test` işaretlidir: faturalamada ve ürün metriklerinde ayrı satırdır, kotası ayrı ve küçüktür, loglarda ayrı süzülebilir (API-61).
3. **Gönderim modu.** `send_mode` değerleri: `live` (normal), `shadow` (bütün hat çalışır, hız limitleri ve kararlar gerçektir; son adımda sağlayıcıya gönderilmez, yalnız doğrulanır ve sonuç kaydedilir), `dry_run` (kararlar ve render senkron döner; kuyruk ve teslim kaydı açılmaz), `off` (gönderilmez; her bildirim `skipped` + `send_mode_off` olarak kaydedilir). Mod hiyerarşik çözülür: `(tenant, category, channel)` → `(tenant, channel)` → `(tenant)` → kurulum varsayılanı. İstek başına açık mod yalnız `test` düzleminde kabul edilir (API-62).
4. **Test düzlemi.** `test` düzlemi aynı işleme hattını çalıştırır (doğrulama, idempotency, tercihler, İYS, rota, şablon, kill switch); yalnız son adımda sahte sağlayıcı adaptörü çalışır ve belirli adreslere belirli sonuçlar üretir (bounce, teslim edilmedi, gecikmeli teslim vb.). Sanal saat (zamanı ileri sarma) yalnız `test` düzleminde vardır ve API'de yalnız `test` anahtarıyla görünür. Güvenliği zayıflatan bir bayrak yoktur (§08, §18) (API-63).

### 9.15 Geliştirici araçlarının sınırı (API-64, API-65)

1. **Tünel CLI'dadır.** Yerel geliştirme tüneli API sözleşmesinde değil CLI'dadır (`relay listen --forward-to`, `relay trigger`). API'de müşteri tanımlı köprü URL'si ya da çalışma anında müşteri sunucusuna çağrı yoktur (§10) (API-64).
2. **Her SDK'da dört zorunlu.**
   - Otomatik `Idempotency-Key`; retry'larda aynı kalır.
   - Yalnız `retryable: true` hatada üstel artış + jitter ile retry; `Retry-After`'a uyulur.
   - Yazılı hata hiyerarşisi (kimlik, doğrulama ve `errors[]`, hız ve `retry_after`, idempotency, sunucu).
   - Ham gövdeyle çalışan webhook doğrulayıcısı (§16) (API-65).

### 9.16 Kaynak uçları (API-66 … API-69)

1. **Alıcı.** `POST /v1/subscribers` (çakışmada 409), `PUT /v1/subscribers/{id}` (upsert, tam değiştirme; ilk oluşturmada 201), `PATCH`, `GET`, liste ve toplu upsert (207, batch kuralları). Yanıt kanal erişilebilirlik özetini taşır (`channels.*.reachable` + neden). `DELETE` `202` + silme talebi döner: talep kuyruktaki işlere, zamanlanmış gönderimlere, digest tamponlarına ve inbox'a uygulanır; kişisel alanlar crypto-shredding ile okunamaz hâle gelir. Fiziksel silme yoktur (Access OP-73, Access OP-74; §20) (API-66).
2. **Cihaz.** `POST /v1/subscribers/{id}/devices`, `GET`, `DELETE .../devices/{device_id}`, `DELETE /v1/devices/by-token`. Cihaz jetonu hiçbir zaman geri okunmaz; yalnız parmak izi döner. Aynı jetonun yeniden kaydı idempotenttir ve `last_seen_at`'i günceller. Jeton başka aboneye aitse o aboneden koparılıp yenisine bağlanır ve `device.reassigned` olayı üretilir. APNs ortamı `apns_environment: production | sandbox` alanındadır; Relay ortamıyla (`live`/`test`) karıştırılmaz. Cihaz kaydı OS izin durumunu ve Android kanal önemini taşır (§12). Abone başına aktif cihaz sayısının üst sınırı vardır (API-67).
3. **Sorgu.** `GET /v1/events/{id}`, `GET /v1/notifications/{id}` (varsayılan özet; `expand=deliveries` ile teslimler), `GET /v1/notifications` (abone, workflow, durum, zaman filtreleri), `GET /v1/notifications/{id}/deliveries` ve deneme geçmişi ile olay defterini döndüren ayrı uç. Dış projeksiyon (durum, etkileşim, `reason` + `rule_id`) §14'tedir; iç model değişse de bu sözleşme sabit kalır (API-68).
4. **Yönetim.** Workflow: `GET/POST /v1/workflows`, `GET/PUT /v1/workflows/{key}` (PUT yeni taslak), `POST .../publish` (`202`), sürüm listesi, `POST .../versions/{n}/promote` (eski sürüme dönüş). Şablon, layout, parça, rota, topic ve abonelik, tekrar kuralı, throttle sıfırlama, webhook uçları (§16), kill switch (§18) ve API anahtarları aynı ortak kurallara uyar. Workflow ve şablon yönetim uçları dosya biçimiyle (§10) aynı tanımı kabul eder (API-69).

### 9.17 Karar register'ı

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| API-1 | HTTP API OpenAPI 3.1, olay yüzeyi AsyncAPI 3.1, şemalar JSON Schema 2020-12; elle yazılır, onaylanır, bağımlı kod onaydan sonra | FROZEN (teknik) | Sözleşme önce; Access ile aynı süreç. AsyncAPI yüzeyi koddan güvenilir üretilemez |
| API-2 | Her CI'da sözleşme testi; uyuşmazlık build'i kırar. SDK'lar belgelerden üretilir + ince elle yazılmış katman | FROZEN (teknik) | Belge, kod ve DB kısıtı arasındaki kaymayı yakalar |
| API-3 | Olay adları `noun.verb_past`, tek sözlük; AsyncAPI kataloğu portal, SDK ve doğrulayıcıları besler | FROZEN (teknik) | Tek ad, tek kavram; CloudEvents `type` ile uyumlu |
| API-4 | "Limitler, retry takvimleri, garantiler" sayfası kodla aynı kaynaktan; hata gövdesi aşılan limiti söyler | FROZEN (teknik) | Belgesiz limit (Braze 50 `external_id`) dersi |
| API-5 | Belgedeki her örnek CI'da `test` düzlemine karşı çalışır; ilk bildirim tek `curl` | FROZEN (teknik) | Geliştirici deneyimi; bozuk örnek üretmeme |
| API-6 | Uç aileleri tablosu; hepsi `/v1` altında; her kavram için tek yol; kanal başına uç yok; slug workflow kimliği | FROZEN (teknik) | Novu `transactionId` + başlık, Courier `routing/providers/channels` ikiliği; Customer.io sayısal kimlik dersi |
| API-7 | Her veri bölgesinin kendi temel adresi; bölgeler arası yönlendirme yok | FROZEN (teknik) | §18 bölge kararı; veri yerleşimi |
| API-8 | Ortak kurallar: JSON utf-8, `snake_case`, bilinmeyen alan 422, `null` = temizle, RFC 3339 UTC, ISO 8601 süre, tutar string, yalnız HTTPS, `Request-Id` | FROZEN (teknik) | Access OP-65 ile hizalı; sessiz yok sayma veri kaybı üretir |
| API-9 | Opak, önekli, zaman sıralı kimlikler; önek tablosu tek yerde; başka kiracının kaynağı 404 | FROZEN (teknik) | İmleçli sayfalama sıralı kimlik ister; 403 varlığı sızdırır |
| API-10 | `Idempotency-Key` değişiklik yapan her istekte zorunlu, yoksa 400; SDK otomatik üretir; Relay içerikten türetmez; tek istisna CloudEvents girişinde olay kimliğinden türetme (API-31) | FROZEN (teknik) | Access OP-63 ile aynı kural; içerikten türetme meşru tekrarı yutar |
| API-11 | Anahtar başlıkta, 8–255 karakter, tırnaklı/tırnaksız; kapsam `(tenant, environment, endpoint, key)` | FROZEN (teknik) | Gövde alanı farklı-gövde karşılaştırmasını kirletir; uzunluk DB kısıtıyla eşit |
| API-12 | Idempotency ömrü 24 saat, sabit; istemci değiştiremez | FROZEN (teknik) | Stripe modeli; sunucu politikası istemciye devredilmez (Courier `x-idempotency-expiration` dersi) |
| API-13 | SHA-256 ham gövde parmak izi; birebir replay + `Idempotency-Replayed: true`; farklı gövde 422; işleniyor 409 + `Retry-After: 1` | FROZEN (teknik) | Replay "atlama" değildir (SuprSend dersi); IETF taslak semantiği |
| API-14 | Yalnız iş mantığı başladıktan sonraki yanıtlar saklanır; 400/401/403/429 saklanmaz; 5xx yalnız kısmi yürütmede | FROZEN (teknik) | Geçici hatanın kalıcı replay'e dönüşmesini önler |
| API-15 | Idempotency deposu PostgreSQL, atomik "ilk giren kazanır"; Valkey'de değil | FROZEN (teknik) | Valkey asıl kayıt tutmaz (§19); kayıp çift gönderimdir |
| API-16 | `dedup_key` bildirim kaydında benzersiz, bildirim saklandığı sürece geçerli; Suiss ürünleri olay kimliğinden türetir; tekrar `duplicate_of` ile döner ve kaydedilir | FROZEN (teknik) | Saatler/günler sonra gelen outbox retry'larını yakalar; sessiz kayıp yok |
| API-17 | Meşru yeni istek (kodu tekrar gönder) yeni anahtarlarla gelir | FROZEN (teknik) | Idempotency ile niyet tekrarı karıştırılmaz |
| API-18 | Garanti dili: en az bir kez teslim + kalıcı idempotency ile etkin bir kez işlem; "exactly-once" tek başına yok; `Idempotency-Key` "yaygın pratik" | FROZEN (teknik) | IETF idempotency taslağının süresi doldu; Google Pub/Sub, Stripe, Svix dürüst dil örnekleri |
| API-19 | `POST /v1/events` 202; alıcı başına `notification_id` hemen döner | FROZEN (teknik) | Kabul ≠ teslim; Knock tek `workflow_run_id` eleştirisi |
| API-20 | Gönderim isteği alan tablosu (§9.5) | FROZEN (teknik) | Tek sözleşme; `send_at` ≤ 90 gün §10 |
| API-21 | Açık upsert: iletişim bilgisi varsa oluştur/güncelle; yalnız kimlik + alıcı yok → `recipient_not_found`; yalnız inbox için `{id}` nesnesi; `test` = `live` | FROZEN (teknik) | Hayalet alıcı yazım hatasını gizler (SuprSend dersi); aynı kod yolu |
| API-22 | Şerit yalnız sınıftan; `priority` şerit içi ince ayar, sınıf tavanına indirilir; platform önceliği tek eşleme tablosundan | FROZEN (teknik) | Şerit izolasyon garantisidir; tavan pazarlamanın yüksek öncelik bütçesini tüketmesini önler |
| API-23 | Overrides kanal anahtarlı, birinci sınıf; istek > adım > workflow > kiracı; ham blok yalnız push ve WhatsApp; politika alanları ezilemez; `from` yalnız doğrulanmış alan adı | FROZEN (teknik) | Orkestrasyon alttaki kanalı kısıtlamamalı (Twilio Notify dersi); güvenliği zayıflatan yol yok |
| API-24 | `security_subtype` gönderen seçer; Relay kanal kurallarını uygular; bu alt türlerde `expires_at` zorunlu, içerik saklanmaz | FROZEN (teknik) | NIST SP 800-63B; güven seviyesi gönderenindir |
| API-25 | `tenant` alt kiracı seçer, anahtarın kiracısı ezilemez; tanımsız alt kiracı `skipped: scope_mismatch` | FROZEN (teknik) | Sessiz kayıp yok |
| API-26 | `retention: none` mesaj başına (security dışı); OTP ve doğrulamada içerik hiç saklanmaz; in-app kanalıyla birleşimi reddedilir (IN-46) | FROZEN (teknik) | Customer.io `disable_message_retention` dersi; Access OP-74 |
| API-27 | `data` kabulde olay şemasına karşı doğrulanır; geçersizse 422, kuyruğa girmez | FROZEN (teknik) | Üç noktada doğrulama (§11) |
| API-28 | CloudEvents binary, structured ve batch aynı girişte; `type` → workflow eşlemesi; `(tenant, source, id)` = `dedup_key`; `traceparent` uçtan uca | FROZEN (teknik) | CloudEvents 1.0.2 (CNCF graduated); `source` + `id` benzersizliği standarttır |
| API-29 | Eşlenmemiş `type` senkron `422 event_type_not_mapped` | FROZEN (teknik) | Sözleşme hatası politika kararı değildir |
| API-30 | Üretim sırası Relay'in sorumluluğu değil; müşteri DB bağlayıcısı yok, CDC araçları için rehber | KAPSAM DIŞI | Müşteri DB erişimi ve CDC işletimi Relay'in yükü olmamalı; Debezium/Sequin CloudEvents çıkışıyla bağlanır |
| API-31 | Yalnız CloudEvents girişinde başlıksız istekte idempotency anahtarı `(tenant, source, id)`'den türetilir ve `Idempotency-Key`'in yerine geçer; başlık varsa başlık geçerli; diğer uçlarda istisna yok | FROZEN (teknik) | API-10 ile uyumlu: anahtar içerikten değil olay kimliğinden; binary/structured üreticilerin bir kısmı başlık ekleyemez |
| API-32 | Batch satır bazlı: 202/207/422/400/413; `ref` (≤ 128) veya `index`; satır başına RFC 9457; `summary` zorunlu | FROZEN (teknik) | Tam başarısızlık 2xx dönmez; AWS SQS `Id` deseni; Zalando 207 kuralı |
| API-33 | Batch limitleri: 500 olay, olay başına 100 alıcı, 5 MB gövde, 256 kB `data`; başlıkla duyurulur | POLICY DEFAULT | Novu 100 düşük, 10.000 yönetilemez; ⚠️ 500 satırın p99 ~400 ms içinde doğrulanacağı ölçülmedi |
| API-34 | Tek `Idempotency-Key` bütün parti; `ref` idempotency birimi değil; atomik ve sıralı değil; satır sayısı kadar kota/limit | FROZEN (teknik) | Satır başına anahtar karışık replay semantiği üretir; limit atlatma yolu kapanır |
| API-35 | Büyük liste/topic gönderimi ayrı kampanya ucundan; hedefsiz istek yok; kiracı geneli duyuru inbox duyuru kaydıyla | FROZEN (teknik) | Fanout muhasebesi, hız ve iptal semantiği farklı; Braze `broadcast` bayrağı dersi |
| API-36 | RFC 9457 + `code`, `retryable`, `request_id` ve diğer uzantılar; `type` çözülebilir URL; `title` sabit | FROZEN (teknik) | RFC 9457; Access OP-64 |
| API-37 | Alan işaretçisi RFC 6901 JSON Pointer + alt kodlar; hatalar toplu raporlanır | FROZEN (teknik) | Nokta yolu belirsiz, JSONPath aşırı güçlü |
| API-38 | Her hatada `retryable`; `true` ise `Retry-After`; durum → `retryable` tablosu | FROZEN (teknik) | Yan etkiyi bilen tek taraf sunucudur |
| API-39 | Karar ≠ hata: politika sonucu 202 sonrası `suppressed`/`skipped` + `rule_id`; senkron yalnız önizleme/test/`dry_run`; tam başarısızlık asla 2xx | FROZEN (teknik) | OneSignal 200 + boş id, Novu 201 + `status:error` dersleri |
| API-40 | Hata kodu aileleri tablosu; politika sonuçları `rule_id` sözlüğünde | FROZEN (teknik) | Tek sözlük (§14) |
| API-41 | Sunucu kimliği gizli API anahtarı (Bearer); tür × ortam önekli; bir kez gösterilir, özeti saklanır; isteğe bağlı mTLS | FROZEN (teknik) | Önek secret scanning'i mümkün kılar; RFC 8705 |
| API-42 | Ortam (`live`/`test`) API anahtarının özelliği; ayrı veri düzlemleri; gövdeyle seçilemez; çapraz erişim 403; webhook ucu ortamı sabit | FROZEN (teknik) | Knock `sandbox_mode` gövde alanı dersi; test anahtarı canlı veriye erişemez |
| API-43 | Kaba kapsamlar; yayın ve okuma ayrı; anahtar yönetimi API anahtarına verilemez; eksik kapsam 403 + kapsam listesi | FROZEN (teknik) | Sızan anahtarın yarıçapını daraltır |
| API-44 | Anahtar döndürmede çakışma penceresi, anında iptal, son kullanım bilgisi, kullanılmayan anahtar uyarısı, kiracı başına üst sınır | POLICY DEFAULT | Pencere başlangıç değeri 0–30 gün; kullanılmayan anahtar sızmış anahtar sayılır |
| API-45 | İstemci yalnız kısa ömürlü dar kapsamlı abone jetonuyla; Access'li kiracıda RFC 8693 exchange; Access jetonu inbox için kabul edilmez; `POST /v1/events` istemciye kapalı; mobil SDK sınırı | FROZEN (teknik) | Gizli anahtar istemciye inmez; Access ile tek kimlik |
| API-46 | Mobil SDK cihazını ayrı dar `devices:write` abone jetonu kapsamıyla kaydeder; yalnız jeton sahibinin kendi cihazı; jeton geri okunmaz | FROZEN (teknik) | Dar kapsam ilkesi; kiracı backend'ine kod gerekmez |
| API-47 | 401'de `WWW-Authenticate`; geçersiz anahtar denemesi IP başına sınırlı; sabit süreli karşılaştırma; askıdaki kiracı bütün girişlerde 403 | FROZEN (teknik) | Zamanlama ve kaba kuvvet sınıfları; askı her girişte etkili (§18) |
| API-48 | Sunucu kimliği üç yol birlikte: API anahtarı, OAuth2 client credentials, Access servis jetonu; mTLS her biriyle ek katman; aynı kapsam, ortam ve hata kuralları; kimlik yönetimi hiçbir yola açılmaz | FROZEN (teknik) | Kurumsal kiracının kendi IdP'si; Access ile sürtünmesiz çalışma (Access E40); RFC 8705 |
| API-49 | `RateLimit`/`RateLimit-Policy` + `X-RateLimit-*`; `Retry-After` delta-saniye | FROZEN (teknik) | `draft-ietf-httpapi-ratelimit-headers` henüz RFC değil; eski istemci uyumu |
| API-50 | Kiracı kapsamlı iki katmanlı API hız limiti; anahtar başına alt limit; uç sınıfına göre ağırlık | POLICY DEFAULT | Değerler plan ve ölçümle konur; batch satır ağırlığı limit atlatmayı kapatır |
| API-51 | Kota 429 `quota_exhausted` (retryable değil) ≠ hız 429 `rate_limited` ≠ aşırı yük 503; sağlayıcı limiti 429 olarak yansımaz; OTP ayrı kova; `security` kabul kontrolünde reddedilmez; kota tükenince `security` ek pay bitene kadar kabul edilir (TN-52); sınıf payı dolan sınıf aynı hatayı alır | FROZEN (teknik) | "429 sen çok istedin, 503 biz yetişemiyoruz"; OTP asla beklemez |
| API-52 | Kalıcı `/v1` + `Relay-Version: YYYY-MM-DD`; ilk istekte sabitleme; en güncel sürüm varsayılan değil; geçersiz 400 + liste | FROZEN (teknik) | Stripe tarihli sürüm modeli; sessiz kırılma olmaz |
| API-53 | Kırıcı / kırıcı olmayan değişiklik tablosu | FROZEN (teknik) | Anlam değişikliği en sinsi kırılmadır |
| API-54 | Sürüm desteği ≥ 24 ay; kaldırma ≥ 12 ay önce duyurulur (RFC 9745, RFC 8594); tek iç model + dönüştürücü zinciri | POLICY DEFAULT | Süreler alt sınırdır; dönüştürücü zinciri her kırıcı değişikliğin kalıcı kod bırakmasını kabul eder |
| API-55 | Webhook sürümü ayrı ve uçta sabit; SDK API sürümüne sabit; beta başlığı sözleşme dışı | FROZEN (teknik) | API yükseltmesi tüketiciyi kırmamalı |
| API-56 | Opak imleçle sayfalama; `limit` 1–100 (varsayılan 50); imleç imzalı ve kapsamlı; listede otomatik genişletme yok; tembel yineleyici | FROZEN (teknik) · PD (`limit` değerleri) | Access OP-65; offset büyük tabloda tutarsız ve pahalı |
| API-57 | İptal uçları; önceden anahtar gerekmez; `cancellation_key` benzersiz değil; 200 + sayımlar | FROZEN (teknik) | Knock zorunlu iptal anahtarı eleştirisi |
| API-58 | İptal tetiklemeyle aynı sıralı anahtardan; koşu yoksa tombstone; zamanlanmış her iş iptal edilebilir | FROZEN (teknik) | Knock "< 5 sn iptal yarışı" belgelenmiş hata |
| API-59 | İptal yalnız sağlayıcıya verilmemiş teslimi durdurur; in-app geri çekilebilir; yazım `cancelled` | FROZEN (teknik) | Gönderilmiş SMS/e-posta/push geri alınamaz; dürüst sınır |
| API-60 | Senkron önizleme: `would_send`, `rule_id`, render, uyarılar, SMS kodlama/segment | FROZEN (teknik) | Politika sonucunun senkron döndüğü yer |
| API-61 | Test gönderimi `is_test`, gerçek sağlayıcı, doğrulanmış ≤ 5 test alıcısı, ayrı faturalama/metrik, küçük kota | FROZEN (teknik) · PD (test alıcı sayısı 5) | Gerçek cihazda doğrulama ürün metriğini kirletmemeli |
| API-62 | `send_mode`: `live` / `shadow` / `dry_run` / `off`; hiyerarşik çözüm; istek başına mod yalnız `test` düzleminde | FROZEN (teknik) | Göç ve canlıya alma güvenliği; kuyruk davranışı gölgede de gerçek |
| API-63 | `test` düzlemi aynı hat + sahte sağlayıcı; sanal saat yalnız `test`; güvenliği zayıflatan bayrak yok | FROZEN (teknik) | Sahte sağlayıcı ayrı kod yolu değildir; Access OP-69 ile uyumlu |
| API-64 | Geliştirme tüneli CLI'da; API'de köprü URL'si yok | FROZEN (teknik) | Novu `bridgeUrl` SSRF ve güvenilirlik dersi |
| API-65 | Her SDK'da: otomatik idempotency, yalnız `retryable`'da jitter'lı retry, yazılı hata hiyerarşisi, ham gövde webhook doğrulayıcı | FROZEN (teknik) | Retry amplifikasyonunu ve ham gövde imza hatalarını önler |
| API-66 | Alıcı uçları; PUT upsert; `DELETE` 202 + silme talebi, crypto-shredding, fiziksel silme yok | FROZEN (teknik) | Access OP-73, Access OP-74; senkron 204 gerçeği yansıtmaz |
| API-67 | Cihaz jetonu geri okunmaz; yeniden kayıt idempotent; başka aboneye aitse yeniden bağlanır + `device.reassigned`; `apns_environment` ayrı alan; abone başına cihaz üst sınırı | FROZEN (teknik) · PD (üst sınır) | Sırlar geri okunmaz; "ortam" terimi tek anlamlı kalır |
| API-68 | Sorgu uçları; özet + `expand`; deneme geçmişi ve olay defteri ayrı uçta; dış projeksiyon sabit | FROZEN (teknik) | §14 dış sözleşme |
| API-69 | Yönetim uçları ortak kurallara uyar; workflow PUT taslak, publish 202, promote ile dönüş; dosya biçimiyle aynı tanım | FROZEN (teknik) | Tek tanım biçimi (§10) |
| API-70 | OAuth2 client credentials: kiracı IdP'si ortam başına kayıtlı (issuer, JWKS, `aud`, kapsam eşleme); kısa ömürlü JWT; imza ve `iss`/`aud`/`exp`/`nbf` her istekte doğrulanır, izinli algoritma listesi; eşlenmeyen kapsam yetki vermez; ortam ve kiracı kayıtlı bağlantıdan | FROZEN (teknik) | RFC 6749 §4.4; RFC 9068; RFC 8725 |
| API-71 | Access servis jetonu: Access bağlı kiracıda backend sunucu API'sine Access jetonuyla erişir; Access anahtarlarıyla doğrulanır, `aud` Relay sunucu API'si; kiracı eşlemeden; yalnız sunucu API'sinde geçerli, inbox/tercih/realtime için kabul edilmez | FROZEN (teknik) | Access E40; E-25 ile uyum |
