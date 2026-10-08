## 12. Kanallar ve Sağlayıcılar

**Bu bölümün kuralları.**
- Bu bölüm, bir teslimin kanala ve sağlayıcıya nasıl çıktığını tanımlar: kanal adaptörü sözleşmesi, sağlayıcı hata sınıflandırması, aynı kanalda sağlayıcı yedeklemesi, devre kesici, öncelik eşleme tablosu, collapse ve kanal başına kurallar (push, e-posta, SMS, ses, WhatsApp, mesajlaşma kanalları).
- Kapsam dışında kalanlar başka bölümlerdedir: kanal sırası, rota politikası, kanal yükseltme ve fallback tetikleri §10'da; şablon render'ı ve kanal varyantları §11'de; mesaj sınıfları, tercihler, izin, İYS ve OTP alt türleri §13'te; teslim durumu projeksiyonu ve olay defteri §14'te; in-app inbox ve realtime §15'te; webhook ve event hedefleri §16'da; kiracı adaleti, şerit ve hız limiti bileşenlerinin uygulanışı §18–§19'da.
- **Fallback ≠ failover.** *Fallback* teslimi başka bir kanala taşır (push → SMS) ve rota politikasının konusudur (§10). *Failover* aynı kanalda başka bir sağlayıcıya geçer (SMS sağlayıcısı A → B) ve bu bölümün konusudur (§12.3).
- Bu bölümdeki bütün tablolar (hata eşlemesi, backoff, devre kesici parametreleri, fiyat, limit, öncelik eşlemesi, platform sınırları, toplu gönderici kuralları) kod değil **sürümlü veridir** (CH-18). Tablo değişikliği deploy gerektirmez; her değişiklik denetim kaydına girer.
- Sayısal değerlerin statüsü register'da yazılıdır. ⚠️ işaretli kanıtlar doğrulanmamıştır ve yalnız gerekçe sütununda kullanılır.

---

### 12.1 Kanal modeli ve adaptör sözleşmesi

#### 12.1.1 Kanal kümesi (CH-1)

| Kanal | Sağlayıcı türleri | Self-host'ta hesap gerekir mi | Not |
|---|---|---|---|
| Push (mobil) | APNs, FCM HTTP v1, Huawei HMS Push Kit, UnifiedPush | APNs/FCM/HMS: kiracının kendi hesabı; UnifiedPush: hayır | iOS için APNs dışında push yolu yoktur (CH-5) |
| Web Push | RFC 8030/8291/8292 (Chrome, Firefox, Safari uç noktaları) | Hayır (VAPID) | Kendi uygulamamız (CH-3) |
| E-posta | ESP adaptörleri (HTTP API), kiracının kendi MTA'sı (SMTP) | Genel SMTP: hayır | Relay MTA işletmez (CH-34) |
| SMS | Ülke başına yetkili işletmeci/aggregator adaptörleri, uluslararası CPaaS | Evet | TR'de yalnız BTK yetkili rota (CH-51) |
| Ses | Yerel operatör/aggregator sesli arama adaptörleri | Evet | `otp_oob` kanalı (§13.10) |
| WhatsApp | Cloud API (doğrudan), BSP adaptörleri | Evet | Şablon onayı ve pencere modeli (§12.9) |
| Mesajlaşma | Slack, Microsoft Teams, Telegram, Discord | Evet (bot/uygulama) | Teslim bilgisi vermez (§12.10) |
| In-app / realtime | Relay'in kendisi | Hayır | §15 |
| Webhook / event hedefi | HTTPS, kuyruk/akış, nesne deposu | Hedefe göre | §16 |

RCS bu kümede yoktur (CH-63). Yeni kanal yalnız adaptör portunun (§12.1.2) bütün beyanlarıyla eklenir.

#### 12.1.2 Adaptör portu ve zorunlu beyanlar

Her kanal adaptörü ortak bir port arkasında çalışır ve devreye alınmadan önce aşağıdaki beyanları sürümlü veri olarak verir. Beyanı eksik adaptör kayıtlı görünür ama trafik almaz (CH-2).

| Beyan | İçerik |
|---|---|
| Yetenek bayrakları | Teslim bilgisi verir mi (APNs, Telegram, Slack vermez), okundu bilgisi, collapse/replace, TTL, mesaj güncelleme/geri çekme, işletmenin ilk mesajı başlatabilmesi, gelen mesaj alma |
| `channel_event_evidence` | Kanalın hangi olayı hangi kanıt düzeyiyle verdiği (sağlayıcı kabulü, DLR, SDK makbuzu, insan tıklaması). "Görülmezse yükselt" ve diğer etkileşim kararları yalnız bu tabloda güvenilir işaretli kanıtla tetiklenir (§10) |
| `provider_idempotency_policy` | Sağlayıcının gönderim idempotency'si var mı, korelasyon alanı ne (ör. `custom_id`, `biz_opaque_callback_data`), belirsiz zaman aşımında durum sorgu ucu var mı |
| Hata eşleme tablosu | Her sağlayıcı kodunun §12.2 sınıflarına eşlemesi + test vektörleri |
| Fiyat ve limit verisi | Birim (mesaj, segment, oturum, doğrulama), ülke × kategori fiyatı, hesap/gönderici/alıcı limitleri (CH-18) |
| Veri yerleşimi meta verisi | İşleme ülkesi, yurt dışı aktarım dayanağı, standart sözleşme bildirim tarihi (CH-6) |
| Gelen webhook doğrulaması | İmza yöntemi; imza yoksa telafi edici kontrol (URL'de gizli belirteç, Basic + IP izin listesi) ve "özgünlük doğrulanamaz" işareti |

#### 12.1.3 Adaptör yapım kuralları

- Adaptörler ince ve test vektörlüdür. SMS, WhatsApp, Slack ve İYS adaptörleri HTTP istemcisi (Req/Finch) üzerinde yazılır; sağlayıcı imza doğrulaması Relay'in kendi kodudur, bakımı bırakılmış üçüncü taraf istemci kütüphanesi kullanılmaz (CH-3).
- E-posta çekirdeği Swoosh'tur (≥ 1.26.3). Failover, itibar ve bounce normalizasyonu Swoosh'ta değil Relay katmanındadır (CH-3).
- Web Push RFC 8291 (`aes128gcm`) ve RFC 8292 (VAPID) Relay'in kendi uygulamasıdır (`:crypto` + JOSE), RFC 8291 Ek A test vektörleriyle doğrulanır (CH-3).
- Gelen imza doğrulaması ham gövde üzerinde, ayrıştırmadan önce ve sabit zamanlı karşılaştırmayla yapılır.
- Adaptörler sürümlüdür. Sağlayıcı bir API'yi kullanımdan kaldırdığında (FCM legacy, Teams O365 Connectors örnekleri) panelde kiracıya uyarı gösterilir (CH-4).

#### 12.1.4 Veri yerleşimi

Kanal sağlayıcısı kaydı işleme ülkesini ve aktarım dayanağını taşır. Yurt dışına veri gönderen kanal panelde "yurt dışına veri gönderir" uyarısıyla görünür. Kiracı isteğe bağlı **"yalnız yurt içi"** politikası açabilir; bu politikada yurt dışı işleme ülkeli sağlayıcı rota listesinde görünür ama devreye girmez (CH-6). APNs ve FCM'nin yurt dışı olduğu ve iOS için APNs'siz yol bulunmadığı belgelenir (CH-5). Push yük minimizasyonu bu riski azaltır (CH-33).

---

### 12.2 Sağlayıcı hata sınıflandırması

#### 12.2.1 Sınıflar ve türeyen eylemler

Her sağlayıcı yanıtı (HTTP kodu, DSN durum kodu, DLR durumu, sağlayıcıya özel hata kodu) sekiz sınıftan birine eşlenir. Retry, fallback, adres devre dışı bırakma, bastırma ve devre kesici ağırlığı yalnız bu sınıftan türer; adaptör kodunda ayrı karar mantığı yoktur (CH-7).

| Sınıf | Örnek | Retry | Kanal fallback tetikler mi (§10) | Adres/token | Devre kesici ağırlığı |
|---|---|---|---|---|---|
| `transient` | 429, 5xx, timeout, APNs `TooManyRequests`, Mint `too_many_concurrent_requests`, SMTP 4xx, Gmail 421 4.7.x | Evet, backoff + jitter (CH-12) | Hayır (zinciri ilerletmez) | Dokunulmaz | 5xx/timeout 1,0; 429 0,5 |
| `permanent_target` | APNs 410 `Unregistered` / `BadDeviceToken`, FCM `UNREGISTERED`, Web Push 404/410, hard bounce 5.1.1, Telegram 403 blocked, WhatsApp `131026` | Hayır | Evet | Anında devre dışı (yumuşak silme) + olay (CH-11) | 0 (açmaz) |
| `permanent_content` | 413 payload büyük, şablon/biçim reddi, `INVALID_ARGUMENT` (yük kaynaklı) | Hayır | Evet | Dokunulmaz | 0 + alarm |
| `policy` | Alıcı çıkışı (WhatsApp `131050`, SMS STOP `21610`), alıcı başına pazarlama tavanı (`131049`), operatör filtresi, `NOT_ALLOWED_BY_IYS` | Hayır (`131049` için ≥ 24 saat, CH-59) | Evet | Tercih/bastırma kaydı (§13) | 0 |
| `quota` | Hesap/proje kotası, `QUOTA_EXCEEDED`, WhatsApp kademe/pacing (`132015`, `135000`) | Kota yenilenene kadar ertele | Hayır | Dokunulmaz | 0,5 |
| `auth` | APNs 403 `ExpiredProviderToken`/`InvalidProviderToken`, FCM `THIRD_PARTY_AUTH_ERROR`, 401 | Kimlik yenilenince bir kez | Hayır | Dokunulmaz | 5,0 (hızlı aç, `{tenant, provider}`) |
| `sender_config` | Gmail 5.7.26 (DMARC), Microsoft 5.7.515, 5.7.27/5.7.30 (SPF/DKIM), tescilsiz başlık, 10DLC kaydı yok | Hayır | Evet (başka sağlayıcı/kimlik doğrulanmışsa) | **Aboneyi bastırmaz**; alan adı/gönderici düzeyinde olay (CH-39) | Açar (`{tenant, provider}`) |
| `unknown` | Eşlemesi olmayan kod | Sınırlı retry | Hayır | Dokunulmaz | 1,0 + olay + alarm |

#### 12.2.2 Grup + ayrıntı

Teslim olayı iki katmanla tutulur: Relay'in normalleştirilmiş sınıfı/ekseni ve sağlayıcının ham kodu (HTTP durumu, DSN `Status`/`Diagnostic-Code`, DLR kodu). İkisi de append-only olay defterine yazılır (§14). Eşlemesi olmayan kod `unknown` sınıfına düşer, `provider.unknown_code` olayı üretir ve operatör alarmı açar; eşleme tablosu güncellenene kadar sınıflandırma sessizce tahmin edilmez (CH-8).

#### 12.2.3 Zaman aşımı ve `Retry-After`

- Üç katmanlı zaman aşımı çekirdektedir: mesajın `expires_at`'i, kanal zaman aşımı, sağlayıcı çağrı zaman aşımı. Hangisi önce dolarsa o uygulanır (CH-9).
- Sağlayıcının `Retry-After` değeri her zaman uygulanır; yerel backoff bunu kısaltamaz. Senkron dönüşü önlemek için üstüne deterministik jitter eklenir (`retry_after + jitter(0, %20)`) (CH-9).
- Kanal TTL'leri (APNs `apns-expiration`, FCM `ttl`, Web Push `TTL`, SMS validity period) `expires_at − now` ile türetilir.

#### 12.2.4 Kör yeniden gönderim yasağı

- Retry kararı uygulama zaman aşımına değil kanıta dayanır: SMS'te DLR, e-postada DSN/olay, WhatsApp'ta durum webhook'u. "Sağlayıcıya gönderildi" bilgisi outbox kaydında tutulur (CH-10).
- Belirsiz sonuçta (bağlantı koptu, yanıt gelmedi) yeniden göndermeden önce sağlayıcının durum/olay ucu sorgulanır (`provider_idempotency_policy`). Durum ucu olmayan sağlayıcıda belirsiz denemenin sonucu `unknown` olarak kaydedilir; ücretli kanalda otomatik ikinci gönderim yapılmaz (§14'teki `unknown` kuralı) (CH-10).

#### 12.2.5 Kalıcı hatada temizlik

`permanent_target` sınıfında adres/token anında devre dışı bırakılır ve `device.unregistered` / `address.disabled` olayı yayılır. Devre dışı bırakma yumuşak silmedir (durum + `deleted_at`); fiziksel silme yoktur (Access OP-73). APNs 410 yanıtındaki `timestamp`, token'ın son kayıt zamanından eskiyse token devre dışı bırakılmaz (token yeniden kaydedilmiştir) (CH-11).

#### 12.2.6 Backoff ve deneme sayısı

Backoff tam jitter'lıdır (`random(0, min(cap, base·2^n))`, deterministik jitter kaynağı ile) ve kanal × sınıf tablosundan gelir. `max_attempts`, mesajın yararlılık ömrünü (`expires_at`) aşamaz: toplam beklenen bekleme süresi `expires_at − now`'dan büyük olan deneme planlanmaz (CH-12). Başlangıç tablosu:

| Kanal / durum | base | cap | max_attempts |
|---|---|---|---|
| APNs 5xx | 30 dk | 2 sa | 5 |
| APNs 429 | 2 sn | 60 sn | 8 |
| FCM 500/503 | 2 dk | 30 dk | 6 |
| FCM 429 | `Retry-After` (yoksa 60 sn) | — | 6 |
| E-posta ESP throttling | 20 dk | 60 dk | 5 |
| WhatsApp 429 (`130429`) | 5 sn | 10 dk | 8 |
| WhatsApp `131056` (çift limiti) | 60 sn | 30 dk | 4 |
| SMS throttling | 2 sn | 5 dk | 8 |
| `security` sınıfı, her kanal | 1 sn | 15 sn | 3 |

---

### 12.3 Sağlayıcı yedekleme, doğrulanmış rota ve devre kesici

#### 12.3.1 İki mod

Kiracı kanal başına iki moddan birini seçer (CH-13):

| Mod | Davranış | Veri kaynağı |
|---|---|---|
| **Aktif-pasif** (varsayılan) | Kanal başına bir birincil + bir ya da daha fazla yedek sağlayıcı. Devre kesici açılınca yedeğe geçilir, kapanınca birincile dönülür | Devre kesici durumu |
| **Ağırlıklı / maliyet tabanlı** | Trafik sağlayıcılara sabit oranla ya da sağlık skoru + teslim oranı + fiyat ile dağıtılır | Teslim defteri rollup'ları (§14), fiyat tablosu (CH-18) |

#### 12.3.2 Doğrulanmış rota kuralı

İki modda da yalnız **önceden doğrulanmış** sağlayıcıya trafik gider (CH-14). Doğrulama kanal başına tanımlıdır:

| Kanal | Doğrulama koşulu |
|---|---|
| SMS | Gönderici kimliği (başlık) o sağlayıcıda tescilli ve onaylı; TR hedefte BTK yetkili rota; ABD'de numara 10DLC/TFV kayıtlı |
| E-posta | Gönderim alan adı o sağlayıcıyla SPF ve DKIM hizalı, return-path doğrulanmış |
| WhatsApp | Numara ve şablon o WABA/BSP'de onaylı |
| Push | Kimlik bilgisi (Apple team/anahtar, Firebase projesi) geçerli ve test gönderimi başarılı |

Doğrulanmamış sağlayıcı rota listesinde "doğrulanmadı" durumuyla görünür, devreye girmez. Devre kesici açıkken bile doğrulanmamış sağlayıcıya geçilmez; yedek yoksa teslim §12.2 sınıfına göre ertelenir ve neden koduyla kaydedilir.

#### 12.3.3 Devre kesici

- Relay'in kendi küçük modülüdür ve iki seviyelidir (CH-15):
  - `{tenant, provider}`: kimlik/yapılandırma hataları (`auth`, `sender_config`). Bir kiracının süresi dolmuş anahtarı diğer kiracıları kesmez.
  - `{provider}`: transport/5xx/timeout oranı, bütün kiracıların katkısıyla.
- Üç durumludur (`closed → open → half_open`); **gerçek half-open** kullanır: yalnız sınırlı sayıda eşzamanlı deneme geçer, başarılar eşiği doldurunca kapanır (CH-15).
- Yalnız transport hatası, 5xx, timeout ve kimlik hatasıyla açılır. 4xx uygulama reddi (geçersiz token, kötü adres, içerik reddi) devreyi açmaz; bunlar sağlayıcının sağlıklı olduğunun kanıtıdır. Bir kiracının milyonlarca bayat token'ı sağlıklı kanalı kapatamaz (CH-15).
- Eşik kayan pencerede orandır; pencerede asgari hacim yoksa oran hesaplanmaz. `open` süresine deterministik jitter eklenir (bütün düğümlerin aynı anda half-open'a geçmemesi için). Süre ölçümleri monotonik saatle yapılır.
- Başlangıç parametreleri (CH-16):

| Kanal | failure_ratio | pencere | open süresi |
|---|---|---|---|
| Ortak | `min_throughput` 20, `half_open_probes` 3, `half_open_successes` 3, open jitter +%0–30 | 30 sn | 30 sn |
| APNs | 0,30 | 30 sn | 20 sn |
| FCM | 0,50 | 30 sn | 60 sn |
| E-posta ESP | 0,40 | 60 sn | 10 dk |
| WhatsApp | 0,50 | 60 sn | 2 dk |
| SMS | 0,50 | 60 sn | 2 dk |

- E-posta **itibar devresi** bu devre kesiciden ayrıdır ve otomatik kapanmaz (CH-41).

#### 12.3.4 Hız limitleri

- Sağlayıcı limitleri üç katmanda modellenir: hesap/proje (FCM proje kotası, ESP gönderim hızı), gönderici (numara MPS'i, WhatsApp numara throughput'u, Slack kanal başına), alıcı/çift (WhatsApp iş–kullanıcı çifti, Telegram sohbet başına, FCM/APNs cihaz başına) (CH-17).
- Limit kovası birimi kanala göredir: SMS'te segment, e-postada alıcı, WhatsApp'ta gelen mesajlar da numara kovasından düşer.
- Relay'in limiti sağlayıcınınkinden kasıtlı olarak daha katıdır; sağlayıcının kendi kuyruğuna güvenilmez (sağlayıcı kuyruğunda saatlerce bekleyip sessizce düşen mesaj "gönderildi" görünür).
- Uyarlanabilir throttle: 429 ve throttling yanıtlarında hız otomatik düşer, başarı geldikçe yavaşça artar (AIMD); `Retry-After` her zaman önceliklidir. E-postada alıcı alan adı başına kova (gmail.com, outlook.com, yahoo.com) tutulur.
- Algoritma ve depolar (GCRA, Postgres/Valkey, kiracı adaleti, şerit tavanları) §19'dadır. Limit sayacı okunamazsa yedek limitleyiciye düşülür; "limitsiz" duruma asla düşülmez.

#### 12.3.5 Fiyat ve limit tabloları

Fiyat, birim (mesaj, segment, oturum, doğrulama, cevaplanan çağrı), ülke × kategori kırılımı, hacim kademeleri ve sağlayıcı limitleri sürümlü veridir; kod sabiti değildir (CH-18). Kurallar:
- WhatsApp fiyat kartı yalnız takvim çeyreği başlarında değiştiği için çeyreklik yenilenir; kanal seçici "pencere içi ücretsiz" varsayımı yapmaz (CH-58).
- Maliyet tabanlı mod ve maliyet raporları (§14) bu tablodan ve sağlayıcının teslim olayında döndüğü fiyat nesnesinden (WhatsApp `pricing`) beslenir; fatura karşılaştırması için ham fiyat nesnesi saklanır.
- Kiracı arayüzünde ücretli kanal seçimi (SMS, ses, WhatsApp marketing) maliyetiyle birlikte gösterilir.

---

### 12.4 Öncelik eşleme ve collapse

#### 12.4.1 Şerit ve ince ayar

Şerit yalnız mesaj sınıfından türer (§13.1); istekteki `priority: low | normal | high` yalnız şerit içinde ince ayardır ve hiçbir alan mesajı başka şeride taşıyamaz. Her sınıfın öncelik tavanı vardır; tavanı aşan değer tavana indirilir ve bu `priority_clamped` olarak kaydedilir (CH-19).

#### 12.4.2 Platform eşleme tablosu

Platform önceliği sınıf + (tavana indirilmiş) ince ayar ikilisinden tek tabloyla türetilir. Tablo veridir; kiracı yalnız daha düşük öncelik seçebilir (CH-19). Hücre değerleri platform belgelerinden türetilmiştir ve platform test cihazlarında ölçülerek kesinleşir (ENGINEERING ASSUMPTION); tablo veri olduğu için düzeltme kod değiştirmez (CH-19).

| Sınıf | Tavan | APNs `apns-priority` (low / normal / high) | iOS `interruption-level` | FCM `priority` (low / normal / high) | Web Push `Urgency` | Android kanal önemi (varsayılan) |
|---|---|---|---|---|---|---|
| `security` | high | 5 / 10 / 10 | `time-sensitive` | normal / high / high | high | HIGH |
| `action_required` | high | 5 / 10 / 10 | `time-sensitive` | normal / high / high | high | HIGH |
| `transactional` | high | 5 / 10 / 10 | `active` | normal / normal / high | normal | DEFAULT |
| `operational` | normal | 5 / 10 / — | `active` | normal / normal / — | normal | DEFAULT |
| `social` | normal | 5 / 5 / — | `passive` (low) / `active` | normal / normal / — | low | LOW |
| `marketing` | normal | 5 / 5 / — | `passive` | normal / normal / — | low | LOW |
| `system` | low | 5 (`apns-push-type: background`, `content-available`) | — (görünmez) | normal (data-only) | — (Web Push'ta gönderilmez, CH-26) | — |

- `critical` interruption level yalnız CH-20 ile açılmış kiracıda ve baştan beyan edilmiş kritik şablonda kullanılır; tabloda bir hücre değil, şablon özniteliğidir.
- Android kanal önemi mesaj başına değiştirilemez; kategori → kanal ID eşlemesi SDK'da kurulur (CH-30). Tablodaki değer, SDK'nın kategoriyi oluştururken kullandığı varsayılandır.
- Doze/arka plan bütçesi nedeniyle `high`/10 her mesajda kullanılmaz; tavanlar bunu yapısal olarak sağlar.

#### 12.4.3 `critical` ve `time-sensitive`

- `critical` varsayılan kapalıdır. Kiracı başına kurulum operatörünün onayıyla açılır (SaaS'ta hizmeti işleten, self-host'ta kurumun kendi Relay yöneticisi; kod aynıdır). Kiracı platform izninin (Apple Critical Alerts entitlement vb.) kanıtını sunar; kritik şablonlar baştan beyan edilir; her kullanım denetim kaydına girer (CH-20).
- `time-sensitive` `security` ve `action_required` sınıflarında otomatik açık, diğer sınıflarda kapalıdır (CH-20).
- Mesaj başına istek alanı (ör. ham `apns.payload` ya da FCM `android` override) politika alanlarını (`interruption-level`, `apns-priority`, `apns-push-type`, FCM `priority`, Android kanal) ezemez; çakışan alan reddedilmez, politika değeri uygulanır ve `override_ignored` kaydedilir (CH-21).
- Kiracı başına yüksek öncelikli gönderim oranı izlenir; eşik aşımında kiracıya uyarı ve denetim kaydı üretilir (CH-22).

#### 12.4.4 Collapse anahtarı

Collapse anahtarı konu bazlıdır: `{tenant, konu türü, konu kimliği, sınıf}` özeti. Aynı konunun bildirimleri birbirini günceller (digest'in kümülatif güncellemesi dahil, "1 yeni → 12 yeni"); farklı konular karışmaz. Relay platform sınırlarını otomatik yönetir (CH-23):

| Platform | Alan | Sınır | Relay eşlemesi |
|---|---|---|---|
| APNs | `apns-collapse-id` | 64 bayt | Tam anahtarın özeti |
| FCM | `collapse_key` | Cihaz başına en fazla 4 farklı anahtar | Sınıf başına sabit anahtar; konu ayrıntısı payload'da |
| Web Push | `Topic` | 32 karakter, URL-safe base64 | Tam anahtarın kısaltılmış özeti |
| Slack / Teams / Telegram | Mesaj güncelleme (`chat.update`, aktivite güncelleme, `editMessageText`) | — | Konu anahtarı → kanal mesaj kimliği eşlemesi saklanır |
| Live Activities / Android ProgressStyle | Etkinlik/bildirim kimliği | Platform kuralları | Konu anahtarına eşlenir (uzun iş ilerlemesi yüzeyi) |

Okunan bildirimin diğer cihazlardan kaldırılması (sessiz push / collapse) §15'tedir.

---

### 12.5 Push

#### 12.5.1 APNs/FCM istemcisi

- HTTP/2 (Finch/Mint) üzerinde Relay'in kendi ince istemcisidir (CH-24).
- **Kabul kontrolü katmanı:** bağlantı başına semafor + sınırlı kuyruk; sunucunun `SETTINGS_MAX_CONCURRENT_STREAMS` değeri gelmeden soğuk bağlantıya eşzamanlı istek gönderilmez (APNs kimliği doğrulanmış ilk istekten önce 1 ilan eder); `too_many_concurrent_requests` `transient` sınıfıdır.
- Kiracı (Apple team / Firebase projesi) başına ayrı bağlantı ve kimlik bilgisi.
- Bütün `apns-push-type` değerleri, broadcast push (`apns-channel-id`, kanal yönetim API'si), Live Activity push-to-start desteklenir. FCM yalnız HTTP v1'dir; kapatılmış batch ucu kullanılmaz.
- Bağlantılar `ping_interval` ve jitter'lı `max_connection_age` ile yenilenir; havuz seçimi yük farkındadır.
- Doğrulama: APNs/FCM mock sunucusu, test vektörleri, sağlayıcı sandbox'ı ve olgun bir istemciye karşı farklılık testi (Access T42 yaklaşımı).

#### 12.5.2 APNs kimlik bilgisi

Token auth (.p8) kullanılır. JWT 20–60 dakikada bir yenilenir (hedef ~40 dk; 20 dakikadan sık yenileme `TooManyProviderTokenUpdates` üretir). İmza KMS/HSM sır portu üzerinden atılır; özel anahtar uygulama belleğinde düz tutulmaz. Kimlik bilgisi bağlantılar düşürülmeden sıcak değiştirilir (CH-25). Sır yönetimi §18'dedir.

#### 12.5.3 Web Push

- Tek uygulama bütün tarayıcıları kapsar; self-host'ta hesap gerektirmeyen push kanalıdır (CH-26).
- `aes128gcm` zorunlu; `aesgcm` yalnız geriye uyum için okunur. Pratik yük sınırı 4.096 bayttır. VAPID JWT `exp` ≤ 24 saat.
- VAPID anahtar çifti kanal kimliği (uygulama) başınadır (C-26, §18 TN-31): bir kiracının birden çok web uygulaması ayrı anahtar taşır; kiracı ya da kurulum başına paylaşılan anahtar yoktur. Anahtar sır portunda yedekli saklanır; değişirse o uygulamanın bütün abonelikleri geçersizleşir, bu yüzden rotasyon yalnız açık operatör eylemiyle ve uyarıyla yapılır (CH-26).
- Declarative Web Push yük biçimi klasik yükün yanında desteklenir.
- `userVisibleOnly` nedeniyle sessiz push yoktur: `system` sınıfı Web Push'a gönderilmez.
- `pushsubscriptionchange` ve 404/410 abonelik yaşam döngüsünü sürer.

#### 12.5.4 HMS ve UnifiedPush

- Relay mesaj sınıfı HMS sınıflandırmasına da eşlenir (`security`/`transactional`/`operational`/`action_required` → "Hizmet ve İletişim"; `marketing`/`social` → "Bilgi ve Pazarlama"); yanlış kategori HMS'te sessiz düşmeye ve kotaya yol açtığı için eşleme kiracıya bırakılmaz (CH-27).
- UnifiedPush, Google servisleri olmayan Android cihazlar için Web Push modülünü paylaşır.

#### 12.5.5 Cihaz kaydı ve izin

- Cihaz kaydı token, platform, uygulama, OS izin durumu (`granted | denied | provisional | not_determined`) ve Android kanal önemlerini taşır; mobil SDK bunları her uygulama açılışında bildirir. Kayıt ucu her zaman kimlik doğrulamalıdır (CH-28).
- İzinsiz cihaza push gönderilmez; rota bir sonraki kanala geçer ve `skipped: no_permission` kaydı yazılır. OS izni Relay tercihini silmez; izin geri açılınca tercih aynen geçerlidir (§13.4) (CH-28).
- iOS provisional yetki yalnız `marketing` ve `social` sınıflarında başlangıç olarak kullanılır; `security`, `transactional`, `action_required` için tam izin istenir (CH-29).
- Android kategori → kanal ID ve önem eşlemesi SDK'da ilk açılışta oluşturulur; kanal ID'leri sürümler arasında sabittir (önem sonradan kodla yükseltilemez) (CH-30).

#### 12.5.6 Token yaşam döngüsü

- Token her uygulama açılışında yeniden gönderilir; `onNewToken` / `pushsubscriptionchange` güncellemeyi sürer (CH-31).
- Çıkış (logout) token'ı devre dışı bırakır.
- Uzun süre bağlanmamış token "bayat" işaretlenir; FCM'nin 270 gün hareketsizlik kuralına ulaşan token devre dışı bırakılır. Eşikler POLICY DEFAULT'tur.
- Token devre dışı bırakma yumuşak silmedir ve tercihleri silmez; cihaz ve tercih kayıtları ayrıdır.
- Token'lar loglarda tam görünmez (kısaltılmış özet).

#### 12.5.7 Push teslim semantiği ve yük

- Push için `delivered` iddia edilmez; APNs/FCM yalnız kabul verir. Mobil SDK makbuzu (gösterildi/tıklandı) ayrı kanıttır (§14) (CH-32).
- APNs çevrimdışı cihaz için uygulama başına yalnız son bildirimi saklar; kayıt in-app inbox'tadır, push uyandırma sinyalidir (§15) (CH-32).
- OTP kodu, sır ve kimlik doğrulama bağlantısı hiçbir push yükünde taşınmaz (push bir `otp_oob` kanalı değildir, §13.10) (CH-33).
- **İçerik taşımayan push:** push yükü yalnız "yeni bildirim var" + opak kimlik taşır, içerik uygulama tarafından Relay'den TLS ile çekilir (APNs `mutable-content` + Notification Service Extension, Android data mesajı). Bu mod yurt dışı aktarılan içeriği ve kilit ekranı sızıntısını azaltır. Varsayılanlar (CH-33):
  1. Türkiye bölgesindeki kiracılarda ve "yalnız yurt içi" politikası (§12.1.4) seçen kiracılarda varsayılan açıktır.
  2. Her bölgede `security` sınıfında ve hassasiyet sınıfı `sensitive` olan şablonlarda (§11 TP-21) varsayılan açıktır.
  3. Diğer durumlarda kiracı ya da kategori düzeyinde seçilir; varsayılan kapalıdır.
  4. İçerik çekilemezse (ağ yok, süre doldu, yetki yok) cihazda genel bir metin gösterilir; içerik push yüküne geri düşmez. Gerekli bildirim servis eklentisi (iOS) ve data mesajı işleyicisi (Android) desteği mobil SDK'larda hazır gelir (§8). Kilit ekranı içerik kuralları §11'deki linter'dadır.

---

### 12.6 E-posta

#### 12.6.1 Adaptörler ve kendi MTA'nı bağla

- Relay ESP adaptörleri (HTTP API) ve "kendi posta sunucunu bağla" SMTP adaptörü sağlar. Kiracı Postfix, KumoMTA, Exchange vb. kendi MTA'sına standart SMTP ile bağlanabilir. Relay MTA işletmez; SaaS'ta ticari ESP'ler kullanılır (CH-34).
- SMTP istemcisi TLS'i açıkça yapılandırır: TLS 1.2/1.3, `verify_peer`, CA deposu, SNI, ana bilgisayar adı kontrolü; port 465 ve STARTTLS ayrı test edilir. Doğrulamasız TLS seçeneği yoktur.
- Bounce işleme her durumda Relay'dedir (§12.6.5).
- ESP olayları dayanıklı bir ara kuyrukla alınır (ör. SES için SNS → SQS); kısa ömürlü doğrudan HTTP aboneliği kullanılmaz. Alarm API hatasına değil teslim olayı gecikmesine kurulur (bazı ESP'ler askıdaki hesapta API başarısı dönüp mesajı günlerce bekletir) (CH-47).

#### 12.6.2 Akış ayrımı ve gönderen kimliği

- İşlemsel (`security`, `transactional`, `operational`, `action_required`) ve pazarlama/toplu (`marketing`, `social` digest'leri) akışlar ayrı stream, ayrı IP havuzu, ayrı kuyruk kullanır (CH-35).
- Gönderen kimliği kategori başına tanımlanabilir (§13.2); kategori başına ayrı gönderen adresi ve gerekirse ayrı alt alan adı.
- Pazarlama için ayrı **organizasyonel** alan adı önerilir: alt alan adı itibar panolarını, SPF bütçesini ve DKIM/FBL kimliğini ayırır, ama Gmail toplu gönderici durumunu ve günlük eşiği ayırmaz (eşik organizasyonel alan adı başına toplanır) (CH-35).
- Access gibi platform kiracıları kendi gönderen alan adıyla ve ayrı izlenen itibarla çalışır.

#### 12.6.3 Alan adı doğrulama sihirbazı

Kiracı gönderim alan adı eklerken sihirbaz şunları yapar (CH-36):
- SPF: DNS sorgulu mekanizma sayımı (> 10 → `permerror` uyarısı), void lookup sınırı; akış başına alt alan adı önerisi (her alt alan adı ayrı 10 sorgu bütçesi).
- Return-path için CNAME'li alt alan adı (VERP için).
- DKIM: 2048 bit, `rsa-sha1` yok, akış başına ayrı selector; iki selector'lı örtüşmeli rotasyon, en geç 6 ayda bir; özel anahtar KMS/HSM'de. 2048 bit TXT kaydının çok parçalı yazımı doğrulanır.
- DMARC: DMARCbis (RFC 9989) DNS tree walk ile değerlendirilir (PSL mantığı yazılmaz); eski `pct`/`rf`/`ri` etiketlerine uyarı; rampa için `t=y`; `np=reject` ve strict alignment önerisi; `p=reject` ise yalnız SPF'e dayanılmaz, DKIM zorunludur.
- Doğrulama sonucu §12.3.2 doğrulanmış rota koşulunu besler.

#### 12.6.4 Toplu gönderici kuralları ve zorunlu başlıklar

- Büyük posta sağlayıcılarının gönderici kuralları (Gmail, Yahoo, Microsoft tüketici kutuları, Apple iCloud: SPF + DKIM, DMARC ≥ `p=none` ve hizalama, RFC 8058, şikâyet oranı < %0,3 ve hedef < %0,1, çıkışın 2 gün içinde uygulanması) sürümlü veri tablosudur; sihirbaz ve itibar panosu bu tabloyla çalışır (CH-37).
- Şikâyet oranı doğru paydayla hesaplanır (gelen kutusuna teslim edilmiş posta).
- Pazarlama/toplu kategorideki her e-postaya `List-Unsubscribe` (HTTPS + mailto) ve `List-Unsubscribe-Post: List-Unsubscribe=One-Click` otomatik eklenir ve DKIM `h=` kapsamındadır; işlemsel e-postaya eklenmez. Uç nokta davranışı §13.7'dedir (CH-38).
- Her giden e-postada VERP return-path ve `Feedback-ID` (`<kampanya>:<kategori>:<kiracı>:<gönderen>`) bulunur (CH-38).

#### 12.6.5 Bounce sınıfları ve ayrıştırıcılar

| Bounce sınıfı | Örnek | Abone | Alan adı/kiracı |
|---|---|---|---|
| Hard | 5.1.1, 5.1.10, 5.2.1 | Anında bastırılır, süresiz | — |
| Soft | 4.x.x, 5.2.2 posta kutusu dolu | Pencere içinde N denemeden sonra süreli bastırma | — |
| Şikâyet (ARF/FBL) | Kullanıcı "spam" dedi | Anında; pazarlama kategorilerinden çıkış (§13.7) | İtibar sayacına girer |
| `sender_config` | 5.7.26, 5.7.515, 5.7.27, 5.7.30 | **Bastırılmaz** | Alan adı/kiracı olayı + devre kesici |
| Politika/içerik | Spam filtresi reddi | Bastırılmaz | İtibar sayacına girer |

- DSN ayrıştırıcı RFC 3464 + bilinen sağlayıcı lehçeleriyle, ARF ayrıştırıcı RFC 5965 ile çalışır; ikisi de gerçek bounce/şikâyet test vektörleriyle doğrulanır (CH-39).
- `sender_config` sınıfı aboneyi bastırmaz; aksi halde tek bir DMARC hatası bütün listeyi siler (CH-39).

#### 12.6.6 Bastırma

- Hard bounce ve şikâyet anında bastırır. Soft bounce pencere içinde N denemeden sonra süreli bastırır (başlangıç: 72 saatte 3; ölçümle ayarlanır). Kalıcı bounce süreli olamaz (CH-40).
- Bastırma kiracı bazlıdır; bir kiracının kötü listesi diğerini etkilemez.
- Bastırma kaydı tanımlayıcının anahtarlı özeti olarak tutulur ve özne silmesinde (crypto-shredding) imha edilmez; böylece silinen kişiye yeniden gönderim yapılmaz (Access OP-74 ile uyumlu).
- Bastırılmış adrese gönderim denenmez; `suppressed` + `rule_id` kaydı yazılır (§14).

#### 12.6.7 İtibar devresi

İtibar devresi kiracı × gönderim alan adı (ve kiracı × kanal) başına çalışır. Bounce ve şikâyet oranı kayan pencerede izlenir; uyarı eşiğinde kiracıya olay, durdurma eşiğinde o akış otomatik duraklatılır. Devre **otomatik kapanmaz**; kapatma kiracı ya da operatörün açık eylemidir ve denetim kaydına girer (oran düştü diye otomatik açılırsa aynı kötü listeyle yeniden gönderilir) (CH-41). Başlangıç eşikleri: uyarı bounce %2 / şikâyet %0,05; durdurma bounce %4 / şikâyet %0,08; pencere 6 saat.

#### 12.6.8 Isınma

Isınma planı ürün özelliğidir: yeni alan adı/IP için günlük hacim tavanı ve alıcı alan adı başına hız; plan veridir ve sağlayıcının kendi ısınma kurallarıyla birleştirilir. Plan dışı hacim ertelenir, reddedilmez (CH-42).

#### 12.6.9 Açılma ve tıklama takibi

- Açılma pikseli ve link sarmalama her yerde varsayılan kapalıdır; kiracı açar (CH-43).
- `security` sınıfı ve OTP/doğrulama e-postalarında takip hiçbir koşulda açılamaz (CH-43, CH-44).
- Tıklamalar "insan" ve "muhtemel bot" olarak ayrılır (teslimden saniyeler sonra tıklama, bütün linklere aynı anda tıklama, bilinen güvenlik tarayıcısı IP blokları, istek biçimi); etkileşim olayında `machine_open` bayrağı bulunur. Etkileşim tabanlı kararları (§10 "görülmezse yükselt") yalnız insan tıklaması tetikler.
- Açılma verisi hiçbir Relay kararında kullanılmaz; piksel açıldığında panelde güvenilmezlik uyarısı gösterilir (Apple Mail Privacy Protection).

#### 12.6.10 Güvenlik e-postaları

`security` sınıfındaki e-postalarda (`email_verification` alt türü dahil, §13.10) link sarmalama, takip ve yönlendirme zinciri yoktur. Tek kullanımlık bağlantı gerekiyorsa GET yalnız onay sayfasını gösterir, durum değişikliği sayfadaki POST ile yapılır; güvenlik tarayıcılarının bağlantıyı önceden açması bağlantıyı tüketmez (CH-44).

#### 12.6.11 Diğer kurallar

- SMTPUTF8 adresleri reddedilmez; sağlayıcı desteklemiyorsa `permanent_content` sınıfında açık hata verilir (CH-45).
- Relay gelen posta kabul ediyorsa (mailto çıkışı, yanıt toplama) MTA-STS ve TLS-RPT zorunludur. DMARC aggregate ve TLS-RPT rapor alımı desteklenen bir yetenektir; yapım sırası Ek B'dedir (CH-46).
- BIMI kapsam dışıdır: VMC/CMC maliyeti ve marka tescili gerektirir, büyük istemcilerin bir kısmı göstermez ve DMARCbis ile çelişen `pct=100` şartı taşır (CH-64).

---

### 12.7 SMS

#### 12.7.1 Kodlama ve segment

- SMS kodlaması her gönderimde açıkça belirtilir; sağlayıcının otomatik tespitine bırakılmaz (CH-48).
- Kodlama üç değerlidir: `GSM7 | GSM7_TR | UCS2`. `GSM7_TR` 3GPP TS 23.038 Türkçe single shift tablosudur; ikili "Türkçe" bayrağı yoktur.
- Sağlayıcı kataloğunda sağlayıcı başına `turkish_single_shift: verified | unverified` alanı tutulur. Doğrulanmamış sağlayıcıya Türkçe karakterli metin `UCS2` olarak gönderilir. "Türkçe her zaman UCS-2" kuralı yoktur.
- Segment septet cinsinden hesaplanır: GSM-7'de `^ { } \ [ ] ~ | €` 2 septet; `GSM7_TR`'de `ç ğ Ğ ı İ ş Ş` 2 septet, `Ç Ö ö Ü ü` 1 septet. Segment sınırları: GSM-7 160/153, `GSM7_TR` 155/149, UCS-2 70/67. Hesap muhafazakârdır (sağlayıcılar arasında 1–2 karakter farkı olduğunda küçük değer alınır).
- Başlıklı TR SMS'te operatör öneki nedeniyle karakter kaybı segment hesabına sabit olarak girer.
- Şablon yayınında ve önizlemede "bu şablon N segment, kodlama X" gösterilir; metni UCS-2'ye düşüren karakterler (akıllı tırnak, uzun tire, `…`, `₺`, NBSP, emoji) uyarıyla işaretlenir ve isteğe bağlı normalize edilir.

#### 12.7.2 Transliterasyon

Transliterasyon (ş → s) mesaj türüne göre belirlenir (CH-49):

| Tür | Politika |
|---|---|
| `security` / OTP | Transliterasyon yapılır (tek segment); sağlayıcı OTP ürünleri Türkçe karakteri zaten kabul etmeyebilir |
| Yasal zorunlu metin (gönderen kimliği, ileti nitelik ibaresi, ret talimatı) | Transliterasyon yapılmaz; gerekirse ikinci segment kabul edilir |
| `marketing` ve diğerleri | Şablon başına bayrak; varsayılan kapalı (doğru sayım, okunabilirlik) |

#### 12.7.3 Gönderici kimliği

Gönderici kimliği bir kiracı (ve alt kiracı) varlığıdır (CH-50):
- Alanlar: tip (alfanümerik, kısa kod, uzun numara, toll-free, 10DLC), ülke, kayıt/onay durumu (sağlayıcı başına), doğrulama kuralları.
- TR kuralları: alfanümerik 3–11 karakter, yalnız rakamdan oluşamaz, yalnız kendi ad/unvan/marka, genel adlar ("BANKA", "KARGO") yasak; İYS kaydı önkoşuldur. Pratikte bir marka ↔ bir başlık ↔ bir İYS `brandCode` (§13.6).
- ABD meta verisi: 10DLC brand id, campaign id ve kullanım durumu; toll-free doğrulama durumu ve Business Registration Number. Mesaj sınıfı kampanya kullanım durumuyla uyuşmazsa (ör. 2FA kampanyasıyla pazarlama) gönderim reddedilir (`rule_id`).
- Onaysız kimlikle gönderim yoktur.

#### 12.7.4 TR rotası

- TR (+90) hedefe SMS yalnız BTK yetkili işletmeci/aggregator adaptörleriyle gider (CH-51).
- "Yurt dışı rota + URL içeren metin" birleşimi reddedilir (operatörler iletmez); yönlendirici TR rotası yoksa gönderimi `rule_id` ile durdurur.
- IP izin listesi isteyen sağlayıcılar için statik çıkış IP'si kurulum gereksinimidir (self-host belgesi ve SaaS ağ tasarımı).

#### 12.7.5 Sağlayıcı ayar sağlık kontrolü

Sağlayıcı panelindeki bazı ayarlar API semantiğini sessizce ezer (ör. "yalnız ticari içerik" ayarının İYS filtresini ezmesi, Türkçe gönderim yetkisinin hesap bazında kapalı olması, evrensel dil desteği ayarı). Bu ayarlar adaptör sağlık kontrolüyle düzenli doğrulanır; uyuşmazlık `sender_config` olayı üretir ve doğrulanmış rota durumunu düşürür (CH-52).

#### 12.7.6 OTP şeridi

OTP ve kampanya aynı şeritte, kuyrukta ya da sağlayıcı hesabında/kredi havuzunda çalışmaz. Sağlayıcının ayrı OTP ürünü varsa (öncelikli, filtresiz, ayrı kredi) `security` sınıfı o ürüne eşlenir (CH-53). Şerit modeli §19'dadır.

#### 12.7.7 Pumping ve hedef korumaları

`security` sınıfında Relay hedef korumalarını uygular (CH-54; iş bölümü §13.10):
- Numara ve numara bloğu (önek) başına hız sınırı.
- Ülke izin listesi: kiracı başına, varsayılan olarak kiracının bölgesi ve açıkça eklenen ülkeler.
- SMS pumping tespiti: önek/ülke yoğunlaşması, doğrulanmayan gönderim oranı anomalisi; eşikte ilgili önek/ülke için otomatik durdurma + kiracı olayı. Durdurma kaldırma açık eylemdir ve denetim kaydına girer.

#### 12.7.8 Bağlantı kısaltma

SMS bağlantı kısaltma kullanılırsa yalnız kiracının kendi markalı alan adıyla çalışır; paylaşılan genel kısaltıcı alan adı kullanılmaz (CH-55). Gelen SMS anahtar kelimeleri (RET, STOP, HELP) §13.7'dedir.

---

### 12.8 Ses

Sesli arama `otp_oob` kanallarından biridir (§13.10) ve erişilebilirlik/kurtarma yoludur (sabit hat, dolaşım, görme engelli kullanıcı, pumping nedeniyle SMS kapalıyken). Faturalama birimi (cevaplanan çağrı, süre periyodu) fiyat tablosundadır. Ticari sesli ileti İYS `ARAMA` kanalına tabidir (§13.6) ve gönderen kimliği metni seste ticaret unvanıdır; bu fark şablon linter'ında kanal başına kuraldır (§11) (CH-56).

---

### 12.9 WhatsApp

#### 12.9.1 Şablonlar

- Şablonlar değişmez, ad-sürümlü artefaktlardır (`order_shipped_v3`); değişiklik yeni şablon oluşturup geçişle yapılır (CH-57).
- Relay şablonu (§11) WhatsApp onaylı şablonuna eşlenir; onay bekleyen şablonla gönderim yoktur. Onay süresi hedeftir, SLA değildir.
- Relay mesaj sınıfı WhatsApp kategorisine eşlenir (`security` → authentication; `transactional`/`operational`/`action_required` → utility; `marketing`/`social` → marketing). Platformun kategoriyi değiştirmesi (`template_category_update`) izlenir; utility → marketing kayması kiracıya olay olarak gider ve maliyet tablosunu günceller; Relay sınıfı değişmez (CH-57).
- Abone olunan platform webhook'ları: `template_category_update`, `account_update` (`violation_type`), `user_preferences`.

#### 12.9.2 Pencere modeli

24 saatlik müşteri hizmeti penceresinin (CSW) durumu alıcı × kanal (numara) bazında tutulur ve gelen her mesajla yenilenir. Yönlendirici pencere açıksa serbest mesaj, kapalıysa şablon seçer. Pencere içi mesajın ücretsiz olduğu varsayılmaz; fiyat tablosundan okunur (CH-58).

#### 12.9.3 Hata kuralları

| Kod | Anlam | Davranış |
|---|---|---|
| `131026` | Numara WhatsApp kullanıcısı değil / teslim edilemez | `permanent_target`; asla retry yok |
| `131050` | Kullanıcı pazarlama iletilerinden çıktı | `policy`; asla retry yok; tercih kaydına yazılır (§13.7) |
| `131049` | Kullanıcı başına pazarlama tavanı | `policy`; ≥ 24 saat beklemeden retry yok |
| `131047` | Pencere kapalı | Şablonla yeniden planla |
| `130429` | Throughput aşımı | `transient` |
| `131056` | İş–kullanıcı çifti hız sınırı | `transient`, çift kovası yavaşlar |
| `132015` / `135000` | Şablon / portföy pacing | `quota` |
| `131042` | Ödeme/faturalama | `sender_config` |

(CH-59)

#### 12.9.4 Tekilleştirme ve webhook

- Gönderim ucunda sağlayıcı idempotency'si yoktur; Relay kendi outbox'ını ve tekilleştirmesini uygular, korelasyon `biz_opaque_callback_data` alanıyla yapılır (CH-60).
- Webhook tekilleştirme anahtarı `wamid + status + timestamp`'tir; mükerrer ve sırasız webhook tasarım gereği beklenir. Durum geçişleri monotondur (§14).
- İmza `X-Hub-Signature-256` (HMAC-SHA256, ham gövde, ayrıştırmadan önce).
- Teslim olayındaki `pricing` nesnesinin tamamı saklanır; `pricing.type` maliyetin kaynak gerçeğidir.
- Sıra gerekiyorsa sonraki mesaj öncekinin `delivered` olayından sonra gönderilir.

#### 12.9.5 Limitler

Mesajlaşma kademesi (24 saatte pencere dışı benzersiz alıcı), numara throughput'u ve şablon Graph API kotası sürümlü limit verisidir. 24 saatlik benzersiz alıcı sayımı yaklaşık değil, üyelik kümesiyle yapılır ("bu alıcı sayıldı mı" sorusu cevaplanabilmelidir); kademenin %90'ında kiracıya uyarı gider. Throughput yükseltmesi sırasında numara kısa süre kullanılamaz; bu bir olay olarak modellenir ve işler ertelenir (CH-61).

#### 12.9.6 WhatsApp ve uyum

WhatsApp pazarlama iletisi için Relay mevzuatın öngörmediği ek bir izin şartı koymaz; kullanıcının tercihleri (çıkış hakkı) geçerlidir (§13.8). Kiracı platformun kendi opt-in politikasına uymaktan sorumludur. WhatsApp'tan gelen pazarlama çıkışı (`user_preferences`, `131050`) tercih kaydına yazılır.

---

### 12.10 Mesajlaşma kanalları (Slack, Teams, Telegram, Discord)

- Adaptörler bot/uygulama kimliğiyle çalışır; kurulum ve OAuth çalışma alanı başına ayrıdır (CH-62).
- Teams'te proaktif mesaj için uygulamanın kurulu olması ve `conversationReference` saklanması gerekir; ana yol "bot + conversationReference deposu"dur. Kaldırılan webhook entegrasyonlarına (O365 Connectors) dayanılmaz.
- Bu kanallar teslim/okundu bilgisi vermez (yetenek bayrağı); okundu bilgisi etkileşim olaylarından ya da in-app'ten türetilir.
- Telegram `403 bot was blocked` `permanent_target` sınıfıdır.
- Gelen etkileşimler (Slack Events API, Teams `Action.Execute`, Telegram webhook) hızlı 2xx ile onaylanır, imza doğrulanır (`X-Slack-Signature` v0, Telegram secret token), kuyruğa alınır ve sağlayıcı olay kimliğiyle tekilleştirilir.
- Kart butonu ve satır içi yanıt hiçbir zaman onay değildir; onay türündeki istekte eylem yalnız Access onay yüzeyine derin bağlantıdır (§17).

---

### 12.11 RCS

RCS adaptörü kapsam dışıdır. Gerekçe: Türkiye'de RCS Business Messaging sunan operatör yoktur ve lansman doğrudan operatör anlaşması gerektirir; çalışan bir demo lansman edilebilirliği kanıtlamaz. Durum yıllık izlenir (operatör listeleri ve CPaaS bölge listeleri); başka bölgelerde ticari karşılığı oluştuğunda yeniden değerlendirilir (CH-63).

---

### 12.12 Karar register'ı

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| CH-1 | Kanal kümesi §12.1.1'deki gibidir: push (APNs, FCM, HMS, UnifiedPush), Web Push, e-posta (ESP + kendi MTA), SMS, ses, WhatsApp, mesajlaşma (Slack, Teams, Telegram, Discord), in-app, webhook/event hedefi. Fallback (kanal değişimi, §10) ile failover (aynı kanalda sağlayıcı değişimi, §12.3) ayrı kavramlardır | MERKEZİ KARAR | Yapım sırası Ek B'de |
| CH-2 | Her adaptör ortak port arkasında çalışır ve yetenek bayrakları, `channel_event_evidence`, `provider_idempotency_policy`, hata eşleme tablosu + test vektörleri, fiyat/limit verisi, veri yerleşimi meta verisi ve gelen webhook doğrulama beyanını sürümlü veri olarak verir; beyanı eksik adaptör trafik almaz | FROZEN (teknik) | Kabul ≠ teslim; sağlayıcıların çoğunda gönderim idempotency'si yok |
| CH-3 | Adaptörler ince ve test vektörlüdür; SMS/WhatsApp/Slack/İYS HTTP istemcisi (Req/Finch) üzerinde, imza doğrulaması Relay kodunda; e-posta çekirdeği Swoosh ≥ 1.26.3 (failover, itibar, bounce normalizasyonu Relay katmanında); Web Push RFC 8291/8292 kendi uygulamamız, RFC 8291 Ek A vektörleriyle | FROZEN (teknik) | Swoosh CVE-2026-54893 1.26.3'te düzeltildi; bakımsız istemci kütüphaneleri |
| CH-4 | Adaptörler sürümlüdür; sağlayıcı API'si kullanımdan kalkınca panelde uyarı gösterilir | FROZEN (teknik) | FCM legacy ve Teams O365 Connectors kapanışları |
| CH-5 | Self-host'ta hesap gerektirmeyen kanallar çekirdekle gelir (genel SMTP, Web Push/VAPID, in-app/realtime); diğer kanallar kiracının kendi kimlik bilgisiyle çalışır. iOS için APNs dışında push yolu olmadığı belgelenir | FROZEN (teknik) | Açık kaynak değer önerisi; Apple platform kuralı |
| CH-6 | Sağlayıcı kaydı işleme ülkesi, aktarım dayanağı ve standart sözleşme bildirim tarihini taşır; panelde "yurt dışına veri gönderir" uyarısı; kiracıya isteğe bağlı "yalnız yurt içi" politikası | FROZEN (teknik) | KVKK m.9 (7499); BDDK/TCMB yurt içi kuralı olan kiracılar |
| CH-7 | Sağlayıcı hata sınıfları sürümlü veridir: `transient, permanent_target, permanent_content, policy, quota, auth, sender_config, unknown`. Retry, fallback tetiği, adres devre dışı bırakma, bastırma ve devre kesici ağırlığı yalnız bu sınıftan türer; her sağlayıcı kodu test vektörüyle gelir | KANONİK DEĞİŞMEZ | İki seviyeli taksonomi (Infobip DLR grupları modeli) |
| CH-8 | Durum "grup + ayrıntı" olarak append-only saklanır; eşlemesi olmayan kod `unknown` + `provider.unknown_code` olayı + alarm üretir | FROZEN (teknik) | Sessiz yanlış sınıflandırma kayıp üretir |
| CH-9 | Üç katmanlı zaman aşımı (mesaj `expires_at`, kanal, sağlayıcı) çekirdektedir; `Retry-After` her zaman uygulanır ve üstüne deterministik jitter eklenir; kanal TTL'leri `expires_at − now`'dan türetilir | KANONİK DEĞİŞMEZ | Retry fırtınası; bu katmanların ücretli plana kilitlenmesi sektör anti-örneği |
| CH-10 | Retry kanıta (DLR/DSN/durum webhook'u) dayanır; belirsiz sonuçta yeniden göndermeden önce sağlayıcı durumu sorgulanır; durum ucu yoksa sonuç `unknown` kalır, ücretli kanalda otomatik ikinci gönderim yoktur | KANONİK DEĞİŞMEZ | Kör yeniden gönderim tam ücretli ve mükerrer |
| CH-11 | `permanent_target` hatasında adres/token anında yumuşak silinir ve olay yayılır; APNs 410 `timestamp` token'ın son kaydından eskiyse token silinmez | FROZEN (teknik) | Access OP-73; Apple 410 semantiği |
| CH-12 | Backoff tam jitter'lı ve kanal × sınıf tablosundan gelir; `max_attempts` mesajın yararlılık ömrünü (`expires_at`) aşamaz; başlangıç tablosu §12.2.6 | ENGINEERING ASSUMPTION | Değerler sağlayıcı önerilerinin 2 katı tabanla türetildi; ölçümle ayarlanır |
| CH-13 | Aynı kanalda iki failover modu: aktif-pasif (varsayılan; devre kesiciyle geçiş ve geri dönüş) ve ağırlıklı/maliyet tabanlı (oran ya da sağlık skoru + teslim oranı + fiyat; veri teslim defterinden) | MERKEZİ KARAR | DORA yoğunlaşma riski; tek sağlayıcı/bölge kesintileri |
| CH-14 | Doğrulanmış rota: iki modda da yalnız önceden doğrulanmış sağlayıcıya trafik gider (SMS başlığı tescilli, e-posta alan adı SPF/DKIM hizalı, TR'de BTK uygun rota, ABD'de 10DLC/TFV); doğrulanmamış sağlayıcı listede görünür, devreye girmez | KANONİK DEĞİŞMEZ | Doğrulanmamış rotaya failover teslimi ve itibarı bozar |
| CH-15 | Devre kesici Relay'in kendi modülüdür; iki seviyeli (`{tenant, provider}` kimlik/yapılandırma, `{provider}` transport/5xx/timeout), gerçek half-open, kayan pencerede oran eşiği, hata sınıfına göre ağırlık; 4xx uygulama reddi devreyi açmaz | FROZEN (teknik) | Bir kiracının bayat token'ları ya da süresi dolmuş anahtarı başkalarını kesmemeli; half-open'sız kesicide reset anında tam yük dalgası |
| CH-16 | Devre kesici başlangıç parametreleri §12.3.3 tablosundaki gibidir | ENGINEERING ASSUMPTION | Ölçümle ayarlanır |
| CH-17 | Sağlayıcı limitleri üç katmanda (hesap/proje, gönderici, alıcı/çift) kanal birimiyle modellenir; Relay limiti sağlayıcınınkinden katıdır; uyarlanabilir throttle (AIMD) uygulanır; sayaç okunamazsa yedek limitleyiciye düşülür, limitsiz duruma düşülmez | FROZEN (teknik) | Sağlayıcı kuyruğunda sessiz düşme; algoritma ve depo §19 |
| CH-18 | Fiyat, birim, kademe, limit, yetenek bayrağı, hata eşleme, backoff, devre kesici, öncelik eşleme ve toplu gönderici kural tabloları kod değil sürümlü veridir; WhatsApp fiyat kartı çeyreklik yenilenir; ücretli kanal seçimi arayüzde maliyetiyle gösterilir | KANONİK DEĞİŞMEZ | Platform fiyat/limit değişiklikleri sık (WhatsApp'ta yılda birden çok kez) |
| CH-19 | Şerit yalnız sınıftan türer; `priority` şerit içi ince ayardır; sınıf tavanını aşan değer tavana indirilir. APNs priority + interruption level, FCM priority, Web Push `Urgency` ve Android kanal önemi tek eşleme tablosundan (§12.4.2) türetilir; hücre değerleri test cihazlarında ölçülerek kesinleşir | MERKEZİ KARAR · EA (tablo hücre değerleri) | Tablo değerleri platform belgelerinden; kiracı yalnız düşürebilir |
| CH-20 | `critical` varsayılan kapalı; kiracı başına kurulum operatörü onayı, platform izni kanıtı, baştan beyan edilmiş kritik şablon ve her kullanımda denetim kaydıyla açılır. `time-sensitive` yalnız `security` ve `action_required` sınıflarında otomatik açık | FROZEN (teknik) | Apple Critical Alerts entitlement; yüksek önceliğin kötüye kullanımı kullanıcının bildirimi tümden kapatmasına yol açar |
| CH-21 | Mesaj başına ham sağlayıcı payload override'ı politika alanlarını (interruption level, priority, push-type, Android kanal) ezemez; politika değeri uygulanır, `override_ignored` kaydedilir | KANONİK DEĞİŞMEZ | Güvenliği zayıflatan bayrak yok (Access TI-9 ile aynı ilke) |
| CH-22 | Kiracı başına yüksek öncelikli gönderim oranı izlenir; eşik aşımında uyarı + denetim kaydı | POLICY DEFAULT | Eşik değeri ayarlanabilir |
| CH-23 | Collapse anahtarı `{tenant, konu türü, konu kimliği, sınıf}` özetidir; aynı konu birbirini günceller; APNs'te tam anahtar özeti, FCM'de cihaz başına 4 anahtar sınırı için sınıf başına sabit anahtar + payload ayrıntısı, Web Push `Topic`, mesajlaşma kanallarında mesaj güncelleme; platform sınırlarını Relay yönetir | FROZEN (teknik) | APNs 64 bayt, FCM 4 anahtar, Web Push 32 karakter sınırları |
| CH-24 | APNs/FCM istemcisi HTTP/2 (Finch/Mint) üzerinde Relay'in kendi ince istemcisidir: kabul kontrolü (semafor + sınırlı kuyruk, sunucu SETTINGS beklenir, `too_many_concurrent_requests` geçici), kiracı başına bağlantı ve kimlik, bütün push-type'lar, broadcast, push-to-start, FCM HTTP v1; mock sunucu, test vektörü, sandbox ve farklılık testiyle doğrulanır | FROZEN (teknik) | Finch HTTP/2 doygunlukta kuyruklama/back-pressure vermez; mevcut Elixir istemcileri broadcast ve push-to-start desteklemiyor |
| CH-25 | APNs token auth; JWT 20–60 dk'da bir yenilenir (hedef ~40 dk); imza KMS/HSM sır portunda; kimlik bilgisi bağlantı düşürmeden sıcak değiştirilir | FROZEN (teknik) | Apple: 20 dk'dan sık yenileme `TooManyProviderTokenUpdates`, 60 dk'dan eski token geçersiz |
| CH-26 | Web Push: `aes128gcm`, VAPID anahtarı kanal kimliği (uygulama) başına, yedekli sır portunda ve yalnız açık operatör eylemiyle döndürülür, Declarative Web Push desteklenir; sessiz push olmadığı için `system` sınıfı Web Push'a gönderilmez | FROZEN (teknik) | VAPID değişimi bütün abonelikleri geçersiz kılar; `userVisibleOnly` |
| CH-27 | Relay sınıfı HMS sınıflandırmasına sabit tabloyla eşlenir; eşleme kiracıya bırakılmaz | FROZEN (teknik) | Yanlış HMS kategorisi sessiz düşme ve kota |
| CH-28 | Cihaz kaydı OS izin durumunu ve Android kanal önemlerini SDK'dan alır; kayıt ucu kimlik doğrulamalıdır; izinsiz cihaza push gönderilmez, rota ilerler ve `skipped: no_permission` yazılır; OS izni tercihi silmez | FROZEN (teknik) | Platform izin modelleri (iOS, Android 13+) |
| CH-29 | iOS provisional yalnız `marketing` ve `social` sınıflarında başlangıç olarak kullanılır | FROZEN (teknik) | Provisional bildirim sessiz teslim edilir; güvenlik/işlem iletisi için uygun değil |
| CH-30 | Android kategori → kanal ID/önem eşlemesi SDK'da ilk açılışta oluşturulur; kanal ID'leri sürümler arasında sabittir | FROZEN (teknik) | Android kanal önemi sonradan kodla yükseltilemez |
| CH-31 | Token her açılışta yeniden gönderilir; logout'ta devre dışı; bayat ve 270 gün hareketsiz token devre dışı (yumuşak silme); token silme tercihi silmez; token loglarda tam görünmez | POLICY DEFAULT | FCM 270 gün kuralı; eşikler ayarlanabilir |
| CH-32 | Push için `delivered` iddia edilmez; SDK makbuzu ayrı kanıttır; push uyandırma sinyalidir, kayıt inbox'tadır | KANONİK DEĞİŞMEZ | APNs/FCM yalnız kabul verir; APNs çevrimdışı cihaza yalnız son bildirimi saklar |
| CH-33 | OTP kodu, sır ve kimlik doğrulama bağlantısı push yükünde taşınmaz; içerik taşımayan push (opak kimlik + uygulamanın TLS ile içerik çekmesi) TR bölgesi ve "yalnız yurt içi" kiracılarda, her bölgede `security` ve `sensitive` şablonlarda varsayılan açık, diğerlerinde kiracı/kategori seçeneği; içerik çekilemezse genel metin; SDK desteği hazır | FROZEN (teknik) | Push meta verisi ve içeriği platform sağlayıcısından geçer (yurt dışı aktarım); kilit ekranı sızıntısı |
| CH-34 | E-posta: ESP adaptörleri + kendi MTA'sını bağlama SMTP adaptörü; Relay MTA işletmez, SaaS'ta ticari ESP kullanılır; SMTP TLS doğrulaması zorunlu; bounce işleme Relay'de | MERKEZİ KARAR | Giden posta için kendi MTA işletmenin itibar ve maliyet yükü |
| CH-35 | İşlemsel ve pazarlama/toplu akışlar ayrı stream, IP havuzu ve kuyruk kullanır; gönderen kimliği kategori başına tanımlanabilir; pazarlama için ayrı organizasyonel alan adı önerilir | FROZEN (teknik) | Gmail toplu gönderici durumu ve günlük eşik organizasyonel alan adı başına toplanır |
| CH-36 | Kiracı alan adı doğrulama sihirbazı: SPF sorgu sayımı, return-path CNAME, DKIM 2048 bit / `rsa-sha1` yok / akış başına selector / en geç 6 ayda iki selector'lı rotasyon / anahtar KMS-HSM'de, DMARCbis tree walk, eski `pct/rf/ri` uyarısı, `np=reject` önerisi | FROZEN (teknik) | RFC 7208, RFC 8301, RFC 9989 |
| CH-37 | Büyük posta sağlayıcılarının toplu gönderici kuralları sürümlü veri tablosudur; şikâyet oranı gelen kutusuna teslim edilmiş posta paydasıyla hesaplanır | POLICY DEFAULT | Gmail/Yahoo 2024, Microsoft 2025 kuralları; tablo güncellenir |
| CH-38 | Pazarlama/toplu e-postaya `List-Unsubscribe` (HTTPS + mailto) + `List-Unsubscribe-Post` otomatik eklenir ve DKIM `h=` kapsamındadır, işlemselde yoktur; her giden e-postada VERP return-path ve `Feedback-ID` bulunur | FROZEN (teknik) | RFC 8058; Gmail/Yahoo toplu gönderici şartı |
| CH-39 | Bounce sınıfları hard / soft / şikâyet / `sender_config` / politika; `sender_config` aboneyi bastırmaz, alan adı/kiracı olayı ve devre kesici üretir; DSN (RFC 3464) ve ARF (RFC 5965) ayrıştırıcıları gerçek test vektörleriyle | FROZEN (teknik) | Bir DMARC hatası bütün listeyi silmemeli |
| CH-40 | Bastırma: hard bounce ve şikâyet anında; soft bounce pencere içinde N denemeden sonra süreli (başlangıç 72 saatte 3); kalıcı bounce süreli olamaz; bastırma kiracı bazlıdır ve anahtarlı özet olarak özne silmesinde imha edilmez | FROZEN (teknik) · PD (soft bounce eşiği) | Access OP-74 ve Access Ek C; kiracı itibar yalıtımı |
| CH-41 | İtibar devresi kiracı × gönderim alan adı (ve kiracı × kanal) başına; eşikte otomatik duraklatır, otomatik açılmaz. Başlangıç eşikleri uyarı %2 bounce / %0,05 şikâyet, durdurma %4 / %0,08, pencere 6 saat | FROZEN (teknik) · PD (eşikler) | Eşikler ESP askıya alma eşiklerinin yaklaşık yarısı (ESP: bounce %5/%10, şikâyet %0,1/%0,5 ⚠️) |
| CH-42 | Isınma planı ürün özelliğidir: yeni alan adı/IP için günlük hacim tavanı + alıcı alan adı başına hız; plan dışı hacim ertelenir | POLICY DEFAULT | Plan değerleri ayarlanabilir |
| CH-43 | Açılma pikseli ve link sarmalama her yerde varsayılan kapalı, kiracı açar; `security` ve OTP/doğrulama e-postalarında açılamaz; tıklamalar insan / muhtemel bot ayrılır, `machine_open` bayrağı taşınır; etkileşim kararlarını yalnız insan tıklaması tetikler; açılma verisi hiçbir kararda kullanılmaz | KANONİK DEĞİŞMEZ | Apple Mail Privacy Protection, güvenlik tarayıcılarının bağlantı açması |
| CH-44 | Güvenlik e-postalarında link sarmalama, takip ve yönlendirme zinciri yoktur; tek kullanımlık bağlantıda GET yalnız sayfayı gösterir, durum değişikliği POST ile | KANONİK DEĞİŞMEZ | Microsoft Safe Links bağlantıyı teslimden önce açar; NIST SP 800-63B-4 |
| CH-45 | SMTPUTF8 reddedilmez; sağlayıcı desteklemiyorsa açık hata | FROZEN (teknik) | RFC 6531 |
| CH-46 | Gelen posta kabul ediliyorsa MTA-STS ve TLS-RPT zorunlu; DMARC aggregate ve TLS-RPT rapor alımı desteklenir (yapım sırası Ek B) | FROZEN (teknik) | RFC 8461, 8460 |
| CH-47 | ESP olayları dayanıklı ara kuyrukla alınır; alarm API hatasına değil teslim olayı gecikmesine kurulur | FROZEN (teknik) | SES doğrudan HTTP aboneliğinin 1 saatlik tavanı; askıdaki hesapta API başarısı |
| CH-48 | SMS kodlaması her gönderimde açıkça belirtilir; değerler `GSM7 / GSM7_TR / UCS2`; sağlayıcı kataloğunda `turkish_single_shift: verified / unverified`, doğrulanmamışa UCS-2; segment septetle ve muhafazakâr hesaplanır; başlık öneki kaybı segment hesabındadır; yayında segment ve kodlama gösterilir | FROZEN (teknik) | 3GPP TS 23.038 Türkçe single shift; sağlayıcı desteği ölçülmedi ⚠️; BTK DK-YED/211 önek kuralı birincil kaynaktan alınamadı ⚠️ |
| CH-49 | Transliterasyon mesaj türüne göre: OTP yapılır, yasal zorunlu metin yapılmaz, diğerlerinde şablon bayrağı (varsayılan kapalı) | FROZEN (teknik) | Yasal metnin bozulmaması; OTP'de tek segment |
| CH-50 | Gönderici kimliği kiracı varlığıdır (tip, ülke, sağlayıcı başına onay durumu, doğrulama kuralları); TR 3–11 karakter, yalnız rakam olamaz, genel adlar yasak; ABD 10DLC/TFV meta verisi ve sınıf–kampanya uyuşmazlığında ret; onaysız kimlikle gönderim yok | FROZEN (teknik) | BTK başlık kuralları; TCR/TFV kayıt şartları |
| CH-51 | TR (+90) SMS yalnız BTK yetkili işletmeci/aggregator adaptörleriyle gider; "yurt dışı rota + URL" reddedilir; IP izin listesi isteyen sağlayıcılar için statik çıkış IP'si | KANONİK DEĞİŞMEZ | 5809; BTK yurt dışı kaynaklı bağlantılı A2P kuralı |
| CH-52 | API semantiğini ezen sağlayıcı panel ayarları adaptör sağlık kontrolüyle doğrulanır; uyuşmazlık `sender_config` olayı üretir ve doğrulanmış rotayı düşürür | FROZEN (teknik) | Panel ayarlarının İYS filtresini ve Türkçe kodlamayı sessizce ezmesi |
| CH-53 | OTP ve kampanya aynı şeritte, kuyrukta ya da sağlayıcı hesabında/kredi havuzunda çalışmaz; sağlayıcının OTP ürünü varsa `security` ona eşlenir | KANONİK DEĞİŞMEZ | Kampanya patlaması OTP'yi bekletmemeli |
| CH-54 | `security` sınıfında numara ve numara bloğu başına hız sınırı, kiracı başına ülke izin listesi, SMS pumping tespiti ve otomatik durdurma; durdurma kaldırma denetim kayıtlı açık eylemdir | FROZEN (teknik) | SMS pumping dolandırıcılığı; eşikler POLICY DEFAULT |
| CH-55 | SMS bağlantı kısaltma yalnız kiracının markalı alan adıyla | FROZEN (teknik) | CTIA kısaltıcı filtreleme |
| CH-56 | Sesli arama `otp_oob` kanalıdır; ticari sesli ileti İYS `ARAMA` kanalına tabidir ve gönderen kimliği metni seste ticaret unvanıdır | FROZEN (teknik) | 6563 Yönetmeliği m.8/4 |
| CH-57 | WhatsApp şablonları değişmez ve ad-sürümlüdür; Relay sınıfı WhatsApp kategorisine sabit eşlenir; platformun kategori değişikliği izlenir ve kiracıya olay olarak gider, Relay sınıfı değişmez | FROZEN (teknik) | Meta'nın utility şablonu marketing'e çevirmesi (maliyet farkı, hata dönmeden) |
| CH-58 | CSW durumu alıcı × numara bazında tutulur; yönlendirici pencere açıksa serbest mesaj, kapalıysa şablon seçer; pencere içi ücretsiz varsayımı yoktur | FROZEN (teknik) | Pencere içi service/utility ücretlendirmesi |
| CH-59 | WhatsApp hata kuralları §12.9.3'teki gibidir: `131026` ve `131050` asla retry edilmez, `131049` ≥ 24 saat beklenir | FROZEN (teknik) | Meta hata belgeleri |
| CH-60 | WhatsApp gönderiminde Relay kendi outbox/tekilleştirmesini uygular (`biz_opaque_callback_data`); webhook tekilleştirme `wamid + status + timestamp`; ham gövde HMAC doğrulaması; `pricing` nesnesi saklanır | FROZEN (teknik) | Gönderim ucunda idempotency key yok; mükerrer webhook garantili |
| CH-61 | WhatsApp kademe, throughput ve şablon API kotaları limit verisidir; 24 saatlik benzersiz alıcı sayımı üyelik kümesiyle yapılır, %90'da uyarı; throughput yükseltmesi olay olarak modellenir | FROZEN (teknik) | Kademe portföy düzeyinde; yaklaşık sayım "sayıldı mı" sorusunu cevaplayamaz |
| CH-62 | Mesajlaşma kanalları bot/uygulama kimliğiyle; Teams'te bot + `conversationReference`; teslim/okundu bilgisi vermez; Telegram blocked `permanent_target`; gelen etkileşimler hızlı 2xx + imza + kuyruk + tekilleştirme; kart butonu onay değildir | FROZEN (teknik) | Platform kuralları; Access EI-18 |
| CH-63 | RCS adaptörü kapsam dışıdır; operatör ve CPaaS bölge listeleri yıllık izlenir | KAPSAM DIŞI · WATCH (operatör ve CPaaS RCS listeleri) | Türkiye'de RBM sunan operatör yok; lansman doğrudan operatör anlaşması gerektirir |
| CH-64 | BIMI kapsam dışıdır | KAPSAM DIŞI | VMC/CMC maliyeti ve marka tescili; sınırlı istemci desteği; DMARCbis ile çelişen `pct=100` şartı |
