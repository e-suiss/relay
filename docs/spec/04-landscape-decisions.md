## 4. Landscape Decisions

### 4.1 Verdict

Bildirim, mesajlaşma ve event teslimi olgun bir sektördür. Relay yeni bir taşıma protokolü ya da yeni bir webhook biçimi icat etmez; olgun standartları kullanır: CloudEvents 1.0 (giriş ve olay zarfı), Standard Webhooks (giden webhook), RFC 8058 (tek tıkla çıkış), RFC 8291/8292 (Web Push), OpenAPI 3.1 ve AsyncAPI 3.x (sözleşme), A2A ve MCP (ajan protokolleri), OIDC ve RFC 8693 (kimlik ve jeton değişimi).

Sektörün parçaları olgundur ama dağınıktır. İncelenen ürünlerin hiçbiri şu kombinasyonu birlikte sunmaz: self-host'ta tam özellik eşitliği, yerleşik eskalasyon zinciri, dayanıklı log olarak giden webhook, gönderilmeyen her mesaj için neden olayı, Türkiye uyumunun (İYS) çekirdekte olması ve ajan yanıtının kaybolmadan, kimden geldiği bilinerek toplanması. Relay'in farklılaşması bu kombinasyondadır (§4.4). Kanıt seviyesi: incelenen ürün kümeleri (§4.4.1); evrensel yokluk iddiası değildir (§3.4).

Bölümün yapısı:
- **§4.2** sektörden benimsenen kalıplar (L-1–L-30)
- **§4.3** bilerek kaçınılan hatalar ve olaylar (L-31–L-58)
- **§4.4** farklılaşma ve parite (MKT-1–MKT-22)
- **§4.5** kanal ve platform çalkantısı (WATCH)
- **§4.6** karar register'ı

Bu bölümdeki kalıpların normatif yeri ilgili bölümdür; burada kalıbın kaynağı ve Relay'deki karşılığı kayıtlıdır. Bir L satırı ile ilgili bölümün kararı çelişirse ilgili bölüm kazanır ve L satırı güncellenir.

### 4.2 Benimsenen kalıplar (L-1–L-30)

Statü: **FROZEN (landscape)**.

| ID | Kalıp | Kaynak örnek | Relay karşılığı | Normatif yer |
|---|---|---|---|---|
| L-1 | Relay olgun standartları kullanır; yeni taşıma ya da imza biçimi icat etmez | CloudEvents (CNCF graduated), Standard Webhooks, RFC 8058, RFC 8291/8292, AsyncAPI 3.1 | §4.1'deki standart seti | §9, §12, §16 |
| L-2 | Rota tek bir iç içe ağaç ifadesidir; kanal seçim stratejileri adlandırılmış politikadır | Courier `single`/`all` ağacı; Airship Fan Out / Last Active / Priority / User Preference | Adlandırılmış rota politikaları; stratejiler: sırayla dene, hepsine gönder, son aktif kanal, kullanıcı tercihi | §10 |
| L-3 | Koşu başında veri ve alıcı dondurulur; her alıcı için ayrı koşu kaydı gözlemin birimidir | Courier snapshot yürütme; Knock recipient workflow run ve abonelik dondurma | Plan sabitleme (şablon sürümü, adres, `dedup_key`); fanout anında abone listesi dondurulur | §10 |
| L-4 | Kademeli kanal yükseltmesi etkileşimde durur | SuprSend Smart Channel Routing; Notifo "görüldüyse gönderme" | "Görülmezse yükselt" adımı; yalnız güvenilir sinyal (in-app görüldü, insan tıklaması, push SDK makbuzu) durdurur | §10 |
| L-5 | Idempotency sözleşmesi ayrıntılıdır: işlem sürerken kilit, aynı anahtar farklı gövde hatası, tekrar yanıtında replay başlığı | Novu ve Knock `Idempotency-Key` sözleşmeleri | Idempotency-Key zorunlu, `Idempotency-Replayed: true` | §9 (MD-20) |
| L-6 | Olay girişi CloudEvents'i doğrudan kabul eder; `source` + `id` tekrar anahtarıdır; `traceparent` uçtan uca taşınır | CloudEvents HTTP bağlaması (binary, structured, batch) | `POST /v1/events` + CloudEvents; `(tenant, source, id)` tekrar anahtarı | §9 |
| L-7 | İptal, tetiklemeyle aynı sıralı anahtardan işlenir; henüz başlamamış koşu için tombstone bırakılır | Knock'un belgelenmiş iptal yarışı (karşı örnek) | İptal tombstone'u; zamanlanmış her iş iptal edilebilir | §9, §10 |
| L-8 | Digest zengin bir pencere modelidir; bildirim "konu + aktiviteler" biçimindedir | Knock batch (kayan pencere, max activity, leading flush); Liveblocks subject + activity | Tek digest pencere modeli; digest yeni inbox öğesi açmaz, mevcut öğeyi günceller | §10, §15 |
| L-9 | İçerik tabanlı tekilleştirme hatalı istemci döngülerine karşı emniyet kemeridir | NotificationAPI | `operational` sınıfında varsayılan açık kısa pencere; diğer sınıflarda isteğe bağlı | §10 |
| L-10 | Throttle, frekans tavanı ve teslim hızı üç ayrı kavram ve üç ayrı ayardır | Braze frequency capping ve delivery speed; Knock throttle; OneSignal throttling | Throttle adımı, kategori × kanal frekans tavanı, kampanya/kanal teslim hızı ayrı | §10, §13 |
| L-11 | "Gönderilmedi" de bir olaydır; atlama nedeni makinece okunur ve webhook ile yayılır | Iterable skip nedeni olayları | Tek atlama sözlüğü, `notification.suppressed` olayı | §14 (MD-12) |
| L-12 | Hata sınıflandırması iki seviyelidir (grup + ham ayrıntı) ve sürümlü veridir | Infobip DLR grupları; APNs/FCM/Twilio/WhatsApp kalıcı hata kodları | Normalleştirilmiş eksen + ham sağlayıcı kodu; kod eşlemesi veri, test vektörlü | §12, §14 |
| L-13 | Üç katmanlı zaman aşımı (mesaj, kanal, sağlayıcı) ve `Retry-After`'a saygı çekirdektedir, paralı katmanda değil | Courier zaman aşımı katmanları (override'ın yalnız Enterprise'da olması karşı örnek) | `expires_at` + kanal + sağlayıcı zaman aşımı çekirdekte | §12 |
| L-14 | Kanal başına birincil + yedek sağlayıcı, devre kesiciyle geçiş | AWS us-east-1 2025 kesintisi; çok sağlayıcılı SMS orkestrasyonu (Fyno) | Aktif-pasif ve ağırlıklı/maliyet tabanlı mod; iki seviyeli devre kesici | §12 |
| L-15 | Toplu ve pazarlama e-postasında RFC 8058 tek tık; işlemsel ve pazarlama akışları ayrıdır | Gmail/Yahoo toplu gönderici kuralları (2024); Postmark akışları; SES Tenants itibar yalıtımı | Otomatik `List-Unsubscribe` + `List-Unsubscribe-Post`; ayrı akış, IP havuzu, kuyruk; kiracı × alan adı itibar devresi | §12, §13 |
| L-16 | Teslim durumu monotondur; DLR bekleme penceresi `unknown` ile kapanır; geç olay deftere yazılır ve durumu yükseltir | AWS End User Messaging 72 saat penceresi | İki aşamalı pencere (`unknown_pending` → `unknown`); `unknown` için otomatik yeniden gönderim yok | §14 |
| L-17 | Sağlayıcı olaylarında sağlayıcı olay kimliğiyle tekilleştirme ve periyodik mutabakat | SendGrid `sg_event_id`; SES `messageId`; Twilio DLR'ın gelmeyebilmesi | Kalıcı gelen webhook dedup'ı + kanal başına mutabakat | §14, §16 |
| L-18 | Inbox iki katmanlıdır: Postgres'te kalıcı log + realtime "yeni var" sinyali | Signal, Matrix, Discord fanout modelleri; Phoenix PubSub'ın at-most-once olması | Kalıcı inbox doğruluk kaynağı; WebSocket/SSE yalnız sinyal | §15 (MD-15) |
| L-19 | Her akış `(stream, epoch, seq)` taşır; istemci cursor'la kaçırdıklarını alır; epoch değişince tam senkron | JMAP `changes?since=`; SSE `Last-Event-ID`; Ably recovery | `since` cursor'u, epoch değişiminde "baştan senkronize ol" sinyali | §15 |
| L-20 | Push ipucudur, durum kaynaktır: önemli bildirim kalıcı kayda yazılır | APNs'in çevrimdışı cihaz için yalnız son bildirimi saklaması; Signal uyandırma modeli | Posta kutusu ve inbox doğruluk kaynağı; push/webhook/A2A push yalnız uyandırma | §15, §17 |
| L-21 | Giden webhook Standard Webhooks'a uyar; Ed25519 imza varsayılan; rotasyonda çakışmalı anahtar | Standard Webhooks `v1a`; Stripe imza rotasyonu | `v1a` Ed25519 varsayılan, `v1` HMAC uyumluluk; Access ile ortak profil (Access TN-136) | §16 |
| L-22 | Webhook ince olaydır; ayrıntı imzalı API çağrısıyla alınır; snapshot isteğe bağlıdır | Stripe thin events; Anthropic webhook olayları | İnce olay varsayılan; uç bazında beyaz listeli snapshot | §16 |
| L-23 | Webhook teslimi kurtarma API'si birinci sınıftır | Svix recover ve replay; Convoy devre kesici | Filtreli toplu retry, pause/resume, replay, kaçırılan olaylar listesi | §16 |
| L-24 | Webhook SSRF koruması zorunludur: özel ve metadata IP reddi, bağlanma anında IP kontrolü, yönlendirme izlenmez | A2A'da SSRF korumasının yalnız SHOULD olması (karşı örnek) | Ortak teslim motorunda SSRF koruması | §16 |
| L-25 | Bekleme noktası birinci sınıf nesnedir: kimlik, beklenen yanıt şeması, son tarih, heartbeat, durum; listelenir ve iptal edilir | Trigger.dev waitpoint; Restate awakeable; Step Functions callback ve heartbeat | Bekleme noktası; heartbeat zaman aşımı ≠ toplam zaman aşımı | §17 (MD-3) |
| L-26 | Erken gelen yanıt kaybolmaz; alıcı tarafında kalıcı posta kutusunda tamponlanır | DBOS ve Temporal kalıcı mesaj modeli; Inngest `waitForEvent` (karşı örnek) | Bekleme noktası açılınca önce posta kutusuna bakılır | §17 |
| L-27 | Onay metni yapılandırılmış alanlardan sunucuda üretilir; başlatan = tamamlayan kontrolü; yanıt işlem özetine bağlanır | CIBA `binding_message`; RFC 9396 RAR; OWASP HITL dialog forging; MCP URL-elicitation phishing | Sunucuda render edilen karar isteği; yanıt işin özetine bağlı; yanıtlayan ≠ bekleyen | §17 |
| L-28 | Ajan protokollerinin teslim boşlukları (retry, imza, zaman damgası, DLQ, SSRF) teslim motoruyla kapatılır | A2A push bildirimi; Anthropic webhook'larının 3 denemede düşürmesi | A2A push gönderimi ve alımı Relay teslim motorundan; `(task, seq)` idempotent alım | §17 |
| L-29 | Kiracı şablonu kod çalıştırmayan bir dille yazılır; render zaman, bellek ve çıktı sınırlıdır; önizleme sandbox'tadır | Solid (Liquid), Shopify filtre uyumu; ntfy şablon CPU-DoS olayı; Listmonk önizleme XSS | Liquid; render sınırları; ayrı origin + CSP + iframe sandbox önizleme | §11 (MD-16) |
| L-30 | Geliştirici giriş eşiği düşüktür: tek `curl` ile ilk bildirim; CLI tünel ve tetikleme; yerel eşdeğerlerle geliştirme; ajan dostu CLI ve MCP sunucusu | ntfy tek `curl`; Stripe ve Knock CLI (`listen`, `trigger`, `push`/`pull`); Mailpit; Novu/Knock/SuprSend MCP sunucuları | CLI `listen`, `trigger`, `pull`/`push`/`promote`; `--json`; MCP sunucusu + skills paketi | §8 |

### 4.3 Kaçınılan hatalar ve olaylar (L-31–L-58)

Statü: **FROZEN (landscape)**. Her satır sektörde belgelenmiş bir hatayı ya da olayı ve Relay'in karşı önlemini kaydeder. Tarihli olaylar gerekçedir; karar metnine taşınmaz.

#### 4.3.1 Ürün tasarım hataları

| ID | Hata | Örnek | Relay karşı önlemi | Normatif yer |
|---|---|---|---|---|
| L-31 | Abonelik eşleşmesi bağlam tam eşleşmesine dayanır, eşleşmeyen tetikleme sessizce kaybolur | Novu bağlam tam eşleşmesi (joker yok) | Eşleşme joker ya da bağlam tam eşleşmesine dayanmaz; eşleşmeyen tetikleme ve kapsam uyuşmazlığı `rule_id` ile kaydedilir | §10, §18 (MD-12) |
| L-32 | Çalışma anında müşteri sunucusuna çağrı (bridge): müşteri ucu düşerse bildirim de düşer | Novu bridge modeli | Bridge yok; kodla yazılan workflow yayında tanım biçimine derlenir | §10 (MD-16) |
| L-33 | Temel güvenilirlik ayarlarının paralı katmana konması | Courier zaman aşımı override'ı yalnız Enterprise; Knock kiracı tercihi/markası Enterprise; Azure NH telemetri Standard; Centrifugo push PRO; OneSignal frequency capping ücretli | Tam özellik eşitliği; kiracı özellikleri ücretsiz çekirdekte | MD-4, F-9 |
| L-34 | Open-core ile self-host'un ikinci sınıf yapılması ve çok bileşenli bağımlılık yığını | Novu CE (SSO, RBAC, aktivite takibi dışarıda; MongoDB + 2×Redis + S3); Dittofeed (ClickHouse + Temporal); lisans karışıklığı | Apache-2.0 tek lisans; zorunlu bileşen yalnız PostgreSQL + Valkey | MD-4, MD-6 |
| L-35 | Erken gelen yanıtın kaybolması | Inngest `waitForEvent` yalnız bekleme başladıktan sonraki olayları görür | Erken yanıt posta kutusunda tamponlanır | §17 |
| L-36 | Bearer yetenek URL'si ya da kimliği callback yetkisi olarak kullanılır | Trigger.dev token URL'si; Restate awakeable kimliği; MCP task kimliği | Callback yetkisi kimliğe bağlı; bearer gerekiyorsa tek kullanımlık, kısa ömürlü, tek bekleme noktasına kapsamlı; ajan bağlamına girmez | §17 |
| L-37 | Kilit ekranından onay; ajanın yazdığı metinle onay diyaloğu | OWASP HITL dialog forging; Lies-in-the-Loop (Markdown ile gizlenen komut) | Kilit ekranından yanıt yok; onay metni sunucuda yapılandırılmış alanlardan; ajan metni "ajanın iddiası" etiketiyle, Markdown/HTML kapalı | §17 (MD-2, MD-11) |
| L-38 | Webhook'un retry'sız ya da kayıp sinyalsiz düşürülmesi | GitHub otomatik retry yok; Anthropic 3 denemede düşürür, replay yok; Infobip pencere dolunca kayıp | Kalıcı DLQ, replay, kaçırılan olaylar listesi; webhook dayanıklı log | §16 |
| L-39 | Hedef hız limiti ile retry penceresinin etkileşiminin modellenmemesi | EventBridge API destinations: düşük rate limit + 24 saat pencere → kayıp | Backlog yaşı metriği; "pencere doldu" ayrı terminal durum | §16 |
| L-40 | Elle yeniden gönderim ile otomatik retry etkileşiminin belirsiz olması | Stripe | Etkileşim yazılı olarak tanımlanır | §16 |
| L-41 | Kısa dedup pencereleri uzun retry'larla tutarsızdır | Ably ve NATS 2 dakikalık pencere | `dedup_key` bildirim saklandığı sürece geçerli; giden webhook tekilliği zamana bağlı değil | MD-20, §16 |
| L-42 | Replay cursor'unun ID sırasına bakması: commit sırası ≠ ID sırası, olay atlanır | Transactional outbox polling tuzağı | Sıra numarası commit sırasına dayanır | MD-15, §15, §17 |
| L-43 | Sınırsız replay ve okuma yolunun yazma kuyruğuna bağlı olması; saat başı patlamanın yazma yolunu tıkaması | ntfy v2.28 (imleçsiz poll tüm önbelleği oynatır), v2.29 (saatlik cron patlaması, 40 sn gecikmeli yazma) | Replay üst sınırı; deterministik jitter her yerde; okuma yolu yazma kuyruğunu beklemez | §10, §15 |
| L-44 | Kopan bağlantının kurtarılmasında yetkinin yeniden kontrol edilmemesi | Socket.IO `skipMiddlewares` | Yeniden bağlanma ve kurtarma yetkiyi baştan kontrol eder; askıya alma ya da jeton iptalinde açık bağlantılar sunucudan kesilir | §15 |
| L-45 | Veritabanı WAL'ından her aboneye fanout | Supabase Postgres Changes (tek replikasyon slotu darboğazı ⚠️) | Fanout uygulama katmanında | §15 |
| L-46 | Bastırılmış alıcıya gönderimin "başarılı" görünmesi | SES `Send`, SendGrid `dropped`, Postmark 406 | Bastırma kararı Relay'de kaydedilir; sağlayıcının sessiz düşürmesi hata sınıfı tablosunda ayrı normalleştirilir; bilinmeyen kod olay + alarm üretir | §12, §14 |
| L-47 | E-posta açılma verisine dayanarak karar vermek | Apple Mail Privacy Protection, proxy açılmaları | Açılma verisi hiçbir kararda kullanılmaz; açılma pikseli ve link sarmalama varsayılan kapalı; insan/bot tıklama ayrımı | §12, §14 |
| L-48 | Gönderici kimlik doğrulama hatasında aboneyi bastırmak | `5.7.x` kodlarının otomatik bastırmayla karıştırılması | `sender_config` sınıfı aboneyi bastırmaz; alan adı/kiracı düzeyinde olay ve devre kesici | §12 |
| L-49 | Frekans tavanına takılan alıcının akışta sessizce ilerlemesi | Braze Canvas | Tavana takılanın kaderi (`drop`/`defer`/`digest`/`inbox_only`) kategori politikasında açıkça yazılır | §13 |
| L-50 | Kimlik alanı adlarının çakışması ve sonradan yeniden adlandırma | OneSignal `external_id` | Alan adları baştan ayrılır; önek ve terim tablosu tek yerde | §9 |
| L-51 | Locale'in tek biçime zorlanması | Novu yalnız `en_US` | BCP 47; fallback zinciri `tr-TR → tr → kiracı varsayılanı` | §11 |
| L-52 | Workflow'lar arası throttle ve aktif throttle sıfırlamanın olmaması; şablonların paylaşılamaması | Knock | Throttle anahtarı kiracı geneli; aktif throttle API ile sıfırlanabilir; layout ve kontrollü parçalar paylaşılır | §10, §11 |
| L-53 | Uzun bekleme için kuyruk slotu ya da süreç tutmak; heartbeat'siz beklemenin takılı kalması | Trigger.dev kısa beklemede slot tutma; Step Functions heartbeat'siz 1 yıl takılma | Bekleme bir kayıt + zamanlayıcı; hiçbir iş 1 saati aşmaz; heartbeat kesilirse `waitpoint.stalled` | MD-3, §17, §19 |
| L-54 | Tekil sorumluluğu (lider, sayaç sahibi) dağıtık BEAM kayıt defterine bağlamak | Horde (ağ bölünmesinde aynı isimli süreç iki kez ⚠️) | Tekil sorumluluk veritabanı tabanlı | MD-6, §19 |
| L-55 | Hız sınırlayıcıda doğruluk hataları | Hammer 2026 hata listesi: başlatma yarışı, kesirli refill kaybı, sabit `retry-after`, CAS yarışları | Hız sınırlayıcı kural testleri bu hata listesinden türetilir; tek davranış test seti iki arka uçta | MD-6, MD-7, §19 |

#### 4.3.2 İşletim olayları

| ID | Olay | Örnek | Relay karşı önlemi | Normatif yer |
|---|---|---|---|---|
| L-56 | Tek bölge ya da tek sağlayıcı bağımlılığı | AWS us-east-1, 20 Ekim 2025 (~15 saat, 140+ servis) | Kanal başına sağlayıcı yedeği; doğrulanmış rotaya sınırlı failover; bölge başına bağımsız kurulum | §12, MD-10 |
| L-57 | Orkestrasyon katmanının bulut sağlayıcısı tarafından kapatılabilmesi | Amazon Pinpoint destek sonu (30 Ekim 2026) | Self-host tam eşitlik; aynı paket her bölgede; olay akışı ve ham veri dışa aktarımı | MD-4, F-7 |
| L-58 | Bildirim sisteminin kendi kesintisini kendi kanalıyla bildirmeye çalışması | Bildirim gönderemeyen sistem "gönderemiyorum" bildirimini de gönderemez | Relay'in olay bildirimi ve nöbet sayfalaması Relay'den geçmez; ayrı barındırılan durum sayfası ve ayrı e-posta hesabı | §20 |

### 4.4 Farklılaşma ve parite

#### 4.4.1 Karşılaştırma kümeleri

Karşılaştırma tarihi: **2026-10-07**. "Bulunamadı" yalnız ilgili kümedeki ürünler ve o tarih için geçerlidir; sektörün tamamı için doğrulanmamıştır (§3.4).

| Küme | Ürünler |
|---|---|
| K1 — Bildirim orkestrasyonu | Novu, Knock, Courier, SuprSend, OneSignal, MagicBell, Engagespot, Fyno, NotificationAPI, Customer.io, Braze, Iterable, Airship, AWS End User Messaging / Pinpoint, Azure Notification Hubs / ACS |
| K2 — Ajan ve dayanıklı yürütme | Temporal, Inngest, Trigger.dev, Restate, Hatchet, DBOS, AWS Step Functions, Oban Pro, A2A, MCP, AG-UI, OpenAI, Anthropic, LangGraph, CIBA, Slack/Teams onay akışları, AgentMail |
| K3 — Realtime, webhook ve event teslimi | Svix, Convoy, Stripe, GitHub, Amazon EventBridge, Google Pub/Sub, Ably, Pusher, Centrifugo, Supabase Realtime, Socket.IO, Phoenix PubSub |
| K4 — Kanal sağlayıcıları | Amazon SES, SendGrid, Postmark, Mailgun, Resend, SparkPost, Brevo; Twilio, Vonage, Sinch, Infobip, Bird, Plivo, Telnyx, Netgsm; WhatsApp Cloud API |
| K5 — Açık kaynak ve Elixir ekosistemi | Novu, Dittofeed, Keila, Notifo, ntfy, Gotify, Apprise, Listmonk, Mautic, Postal, Oban OSS, Hammer, Pigeon |

#### 4.4.2 Farklılaşma iddiaları

Statü: her satır **WATCH** (pazar durumu değişebilir). Kural satırı MKT-1 **FROZEN (landscape)**'dır. Bir iddianın düşmesi tezi ya da kapsamı değiştirmez (§2.6).

| ID | Farklılaşma | Gözlenen durum (2026-10-07) | Küme | Geçersiz kılacak karşı örnek |
|---|---|---|---|---|
| MKT-2 | Yerleşik eskalasyon zinciri (süre → yeni alıcı/kanal; son kademe olay) | K2'nin 17 ürününün hiçbirinde yerleşik eskalasyon yok | K2 | Kümeden bir ürünün süreli, çok kademeli alıcı eskalasyonunu yerleşik sunması |
| MKT-3 | Kimliğe ve işleme bağlı insan yanıtı (Access onay yüzeyi + Relay teslim kanalı) | Slack/Teams'te kanal kimliği kurumsal kimlik değil; bearer callback'ler yaygın; CIBA teslim kanalını tanımlamıyor; HITL onay servisi olarak sunulan ürünler sürdürülmedi | K1, K2 | Bir ürünün CIBA OP + çok kanallı teslim + işlem özetine bağlı yanıtı birlikte sunması |
| MKT-4 | Self-host'ta tam özellik eşitliği ve küçük bağımlılık seti | K1'de yalnız Novu açık kaynak/self-host ve self-host'u kırpılmış; Dittofeed ClickHouse + Temporal istiyor | K1, K5 | Kümeden bir ürünün self-host'ta SSO, RBAC, inbox, aktivite takibi ve webhook replay'i ücretsiz ve tam sunması |
| MKT-5 | Dayanıklı log olarak giden webhook (kalıcı DLQ, replay, recover, kaçırılan olaylar) | K2'deki ajan protokollerinin hiçbirinde DLQ/replay yok; GitHub retry yapmıyor; Anthropic 3 denemede düşürüyor | K2, K3 | Bir ajan protokolünün ya da K1 ürününün kalıcı DLQ + replay'i standart olarak sunması |
| MKT-6 | Gönderilmeyen her mesaj için makinece okunur neden olayı | K1'de yalnız Iterable tam; Knock ve Braze kısmi | K1 | K1'den üç ya da daha fazla ürünün her atlama için neden olayı yayımlaması |
| MKT-7 | İçerik tabanlı tekilleştirme | K1'de yalnız NotificationAPI | K1 | K1'in büyük oyuncularından birinin (Novu, Knock, Courier, Braze) sunması |
| MKT-8 | Etkileşimde duran kanal yükseltmesi, güvenilir sinyale bağlı | K1'de yalnız SuprSend tam; K5'te yalnız Notifo (son sürüm 2022) | K1, K5 | Kümeden ikinci bir aktif ürünün etkileşimle duran yükseltmeyi sunması |
| MKT-9 | Türkiye uyumu çekirdekte: İYS iki yönlü senkron, fail-closed kapı, BTK başlık/rota kuralları, Türkçe SMS segment hesabı, aktarım meta verisi | K1'de İYS yok; K4'te İYS filtresi yalnız Netgsm'de (Infobip ⚠️) | K1, K4 | K1'den bir ürünün İYS senkronunu ve fail-closed kapıyı yerleşik sunması |
| MKT-10 | Kiracı ve alt kiracı özellikleri ücretsiz çekirdekte | Knock kiracı tercih/marka Enterprise; Courier zaman aşımı override Enterprise | K1 | Kümeden bir ürünün kiracı marka, tercih ve sağlayıcı hesabını ücretsiz katmanda sunması |
| MKT-11 | Erken yanıtın kaybolmaması + doğrulanan karar (önce şema doğrulama, sonra kayıt) | K2'de erken mesaj tamponu Inngest ve Step Functions'ta yok; senkron doğrulanan yanıt yalnız Temporal ve Anthropic'te; K1'de hiçbirinde | K1, K2 | K1'den bir ürünün bekleme noktası + erken yanıt tamponu sunması |
| MKT-12 | Kanal-bağımsız kalıcı ajan posta kutusu, güven etiketli gelen mesajla | K2'de yalnız DBOS, Anthropic, AgentMail; AgentMail yalnız e-posta, Anthropic yalnız kendi oturumları | K1, K2 | Self-host edilebilir, kanal-bağımsız, Postgres-kalıcı bir ajan posta kutusunun kümede çıkması |
| MKT-13 | Özne bazlı silme API'si (crypto-shredding) kuyruk, zamanlanmış gönderim, digest tamponu ve inbox dahil | Ably'de kalıcı mesaj silme API'si yok; K3'te çoğu belirsiz | K3 | K3'ten bir ürünün kalıcı veri dahil özne bazlı silme API'si sunması |
| MKT-14 | Kesin teslim sayaçları ve dürüst garanti dili | Pub/Sub DLT sayacı yaklaşık ve sıfırlanabilir; Ably ve NATS dedup penceresi 2 dk | K3 | — (yalnız Relay'in kendi doğruluk kanıtıyla sınanır; kural testleri) |
| MKT-15 | Elixir ekosisteminde açık kaynak workflow takibi ve dağıtık hız limiti | Oban OSS'te global eşzamanlılık, hız limiti, partition ve workflow yok (Oban Pro'da); Hammer'ın Postgres arka ucu yok ⚠️ | K5 | Apache-2.0 lisanslı eşdeğer bir Elixir bileşeninin çıkması |
| MKT-16 | Yalnız önceden doğrulanmış sağlayıcıya failover (SPF/DKIM hizası, BTK rota yetkisi, 10DLC kaydı) | Kümelerde failover'ın bu doğrulamayla kısıtlandığına dair belge bulunamadı | K1, K4 | Bir ürünün doğrulama-kısıtlı failover'ı belgelemesi |
| MKT-17 | Gönderici yapılandırma hatası sınıfı (`sender_config`): aboneyi bastırmaz, devre kesiciyi açar | ESP'lerde otomatik bastırmayla karışabiliyor | K4 | Büyük bir ESP'nin bu ayrımı varsayılan davranış yapması |
| MKT-18 | Gelen ajan mesajına güven etiketi (`authenticated`/`unauthenticated`/`spam`/`blocked`), ajan uyandırılmadan önce | K2'de yalnız AgentMail; ajan protokollerinde yok | K2 | A2A ya da MCP'nin gelen mesaj güven etiketini standartlaştırması |

#### 4.4.3 Parite kalemleri

Aşağıdakiler sektörde yaygındır; Relay'de bulunmaları zorunludur ama farklılaşma iddiası değildir. Statü: **FROZEN (landscape)** (parite olarak; ayrıntı ilgili bölümde).

| ID | Parite kalemi | Örnek | Normatif yer |
|---|---|---|---|
| MKT-19 | Görsel workflow editörü + kodla yazım + dosya tabanlı GitOps; ortamlar arası promote | Novu, Knock | §8, §10 |
| MKT-20 | Gömülebilir inbox, toast ve tercih merkezi bileşenleri; mobil SDK'lar | Novu, Courier, Knock, MagicBell | §8, §15 |
| MKT-21 | Digest, throttle, gecikme, topic aboneliği, A/B varyant | Knock, Novu, Courier, SuprSend | §10 |
| MKT-22 | Gömülebilir webhook uç nokta portalı ve olay türü kataloğu | Svix App Portal, Convoy | §16 |

### 4.5 Kanal ve platform çalkantısı

Statü: **WATCH**. Aşağıdaki bilgiler hızla eskir; hiçbiri karar metnine girmez. Karar metinleri bu bilgiye değil, bilginin veri olarak tutulması kuralına dayanır (fiyat ve limit tabloları veri, adaptörler sürümlü, kullanımdan kaldırma uyarısı panelde; §12).

| Alan | Gözlenen değişim | Relay kuralı |
|---|---|---|
| WhatsApp | Fiyat ve kategori kuralları 2024–2026 arasında birçok kez değişti; mesajlaşma limiti 7 Ekim 2025'ten beri işletme portföyü düzeyinde; Meta utility şablonu marketing'e yeniden sınıflandırabiliyor ⚠️ | Rate card ve limitler veri; "pencere içi ücretsiz" varsayımı yok |
| Türkiye SMS (BTK) | Yurt dışı kaynaklı + link içeren SMS engeli; 850'li ve coğrafi numaradan SMS yasağı; toplu mesajda e-imza; alfanümerik başlık kuralları | TR hedefte yurt dışı rota + URL birleşimi reddedilir; TR SMS yalnız yetkili işletmeci/aggregator adaptörleriyle (§12) |
| Türkçe SMS kodlaması | Sağlayıcıların 3GPP TS 23.038 Türkçe tek kaydırma tablosu desteği doğrulanmadı ⚠️ | Sağlayıcı kataloğunda `turkish_single_shift` (`verified` / `unverified`); doğrulanmamışa `ucs2` (§11, §12) |
| Push platformları | FCM legacy API kapandı; FCM'de cihaz başına collapse anahtarı sınırı ⚠️; APNs JWT 20–60 dakikada yenilenir; VAPID anahtarı değişirse bütün Web Push abonelikleri geçersiz olur | Collapse sınırları otomatik yönetilir; VAPID anahtar yaşam döngüsü bu kısıtla tasarlanır (§12, §18) |
| Sohbet kanalları | Teams Office 365 Connectors kapandı ⚠️; Slack geçmiş API'lerinde yeni hız sınırları ⚠️ | Adaptörler sürümlü; kullanımdan kaldırma uyarısı panelde |
| E-posta | Gmail/Yahoo toplu gönderici kuralları (2024); Gmail Kasım 2025 yaptırımı; Microsoft toplu gönderici yaptırımının biçimi kaynaklarda çelişkili ⚠️ | Alan adı doğrulama sihirbazı ve RFC 8058 çekirdekte (§12, §13) |
| ABD mesajlaşma | TCPA rıza geri çekme kuralı; "revoke all" ertelemesinin yürürlük durumu doğrulanmadı ⚠️; 10DLC ve toll-free kayıt kuralları | Uyum kuralları veri tablosu (MD-17); geri çekme kapsamı veri (§13) |
| Ajan protokolleri | A2A v1.0 ve MCP 2026-07-28 yayımlandı; MCP'de `tasks/list` kaldırıldı | Durum eşleme tablosu protokol sürümüne bağlı veri (§17) |
| Lisanslar | Bağımlı olunan projelerin lisansı değişebiliyor (Sygnal'in AGPL'e geçişi); OSI dışı lisanslar (ELv2) yeniden sunumu kısıtlar | AGPL/GPL projelerden kod kopyalanmaz; bağımlılık lisans değişikliği izlenir (§19) |

### 4.6 Karar register'ı

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| L-1 | Relay olgun standartları kullanır (CloudEvents, Standard Webhooks, RFC 8058, RFC 8291/8292, OpenAPI 3.1, AsyncAPI 3.x, A2A, MCP, OIDC, RFC 8693); yeni taşıma ya da imza biçimi icat etmez | FROZEN (landscape) | §4.1; standartların olgunluğu ve birlikte çalışabilirlik |
| L-2 | İç içe `single`/`all` rota ağacı + adlandırılmış kanal seçim stratejileri | FROZEN (landscape) | Courier, Airship |
| L-3 | Koşu başında plan ve abone dondurma; alıcı başına koşu kaydı | FROZEN (landscape) | Courier snapshot, Knock recipient run |
| L-4 | Etkileşimde duran kanal yükseltmesi, yalnız güvenilir sinyal | FROZEN (landscape) | SuprSend, Notifo; Apple MPP |
| L-5 | Ayrıntılı idempotency sözleşmesi ve replay başlığı | FROZEN (landscape) | Novu, Knock; Idempotency-Key IETF taslağı (süresi doldu, yaygın pratik) |
| L-6 | CloudEvents girişi; `(tenant, source, id)` tekrar anahtarı; `traceparent` | FROZEN (landscape) | CloudEvents 1.0.2 |
| L-7 | İptal aynı sıralı anahtardan + tombstone | FROZEN (landscape) | Knock iptal yarışı (karşı örnek) |
| L-8 | Zengin digest pencere modeli; konu + aktiviteler bildirim modeli | FROZEN (landscape) | Knock batch, Liveblocks |
| L-9 | İçerik tabanlı tekilleştirme emniyet kemeri | FROZEN (landscape) | NotificationAPI |
| L-10 | Throttle, frekans tavanı, teslim hızı ayrı kavramlar | FROZEN (landscape) | Braze, Knock, OneSignal |
| L-11 | Atlama nedeni olayları | FROZEN (landscape) | Iterable |
| L-12 | İki seviyeli, sürümlü veri olarak hata sınıflandırması | FROZEN (landscape) | Infobip; platform kalıcı hata kodları |
| L-13 | Üç katmanlı zaman aşımı ve `Retry-After` çekirdekte | FROZEN (landscape) | Courier (Enterprise kilidi karşı örnek) |
| L-14 | Kanal başına birincil + yedek sağlayıcı, devre kesici | FROZEN (landscape) | AWS us-east-1 2025; Fyno |
| L-15 | RFC 8058 ve akış ayrımı; kiracı × alan adı itibar yalıtımı | FROZEN (landscape) | Gmail/Yahoo 2024, Postmark, SES Tenants |
| L-16 | Monoton teslim durumu; DLR penceresi `unknown` ile kapanır | FROZEN (landscape) | AWS End User Messaging |
| L-17 | Sağlayıcı olay kimliğiyle dedup + mutabakat | FROZEN (landscape) | SendGrid, SES, Twilio DLR davranışı |
| L-18 | Kalıcı inbox log + realtime sinyal | FROZEN (landscape) | Signal, Matrix, Discord; Phoenix PubSub at-most-once |
| L-19 | `(stream, epoch, seq)` + cursor kurtarma | FROZEN (landscape) | JMAP, SSE `Last-Event-ID`, Ably |
| L-20 | Push ipucu, durum kaynak | FROZEN (landscape) | APNs saklama davranışı; Signal |
| L-21 | Standard Webhooks, Ed25519 varsayılan, çakışmalı rotasyon | FROZEN (landscape) | Standard Webhooks, Stripe; Access TN-136 |
| L-22 | İnce webhook olayı varsayılan; snapshot isteğe bağlı | FROZEN (landscape) | Stripe, Anthropic; KVKK veri en aza indirme |
| L-23 | Webhook kurtarma API'si birinci sınıf | FROZEN (landscape) | Svix, Convoy |
| L-24 | Webhook SSRF koruması zorunlu | FROZEN (landscape) | A2A SHOULD (karşı örnek); bulut metadata uç noktaları |
| L-25 | Bekleme noktası birinci sınıf nesne; heartbeat ≠ toplam zaman aşımı | FROZEN (landscape) | Trigger.dev, Restate, Step Functions |
| L-26 | Erken yanıt kalıcı posta kutusunda tamponlanır | FROZEN (landscape) | DBOS, Temporal; Inngest (karşı örnek) |
| L-27 | Sunucuda render edilen onay metni; başlatan = tamamlayan; işlem özetine bağlı yanıt | FROZEN (landscape) | CIBA, RFC 9396, OWASP, MCP URL-elicitation phishing |
| L-28 | Ajan protokollerinin teslim boşlukları Relay teslim motoruyla kapatılır | FROZEN (landscape) | A2A push, Anthropic webhook davranışı |
| L-29 | Kod çalıştırmayan şablon dili, render sınırları, sandbox önizleme | FROZEN (landscape) | Solid/Liquid; ntfy CPU-DoS; Listmonk XSS (GHSA-jmr4-p576-v565) |
| L-30 | Düşük giriş eşiği: tek `curl`, CLI, yerel eşdeğerler, ajan dostu CLI ve MCP | FROZEN (landscape) | ntfy, Stripe, Knock, Mailpit |
| L-31 | Bağlam tam eşleşmesiyle sessiz kayıp yok | FROZEN (landscape) | Novu |
| L-32 | Bridge modeli yok | FROZEN (landscape) | Novu |
| L-33 | Güvenilirlik ayarları paralı katmana konmaz | FROZEN (landscape) | Courier, Knock, Azure NH, Centrifugo, OneSignal |
| L-34 | Open-core ve çok bileşenli yığın yok | FROZEN (landscape) | Novu CE, Dittofeed |
| L-35 | Erken yanıt kaybı yok | FROZEN (landscape) | Inngest |
| L-36 | Bearer callback yetkisi yok (istisna tek kullanımlık, kısa ömürlü, tek kapsamlı) | FROZEN (landscape) | Trigger.dev, Restate, MCP task ID |
| L-37 | Kilit ekranı onayı ve ajan metniyle onay diyaloğu yok | FROZEN (landscape) | OWASP HITL dialog forging; Lies-in-the-Loop |
| L-38 | Webhook kayıp sinyalsiz düşürülmez | FROZEN (landscape) | GitHub, Anthropic, Infobip |
| L-39 | Hedef hız limiti × retry penceresi modellenir; "pencere doldu" ayrı durum | FROZEN (landscape) | EventBridge API destinations |
| L-40 | Elle yeniden gönderim × otomatik retry etkileşimi yazılıdır | FROZEN (landscape) | Stripe |
| L-41 | Kısa dedup penceresi yok | FROZEN (landscape) | Ably, NATS |
| L-42 | Cursor commit sırasına dayanır | FROZEN (landscape) | Outbox polling tuzağı |
| L-43 | Replay üst sınırı; deterministik jitter; okuma yolu yazmayı beklemez | FROZEN (landscape) | ntfy v2.28/v2.29 |
| L-44 | Kurtarmada yetki baştan kontrol edilir | FROZEN (landscape) | Socket.IO `skipMiddlewares` |
| L-45 | WAL'dan aboneye fanout yok | FROZEN (landscape) | Supabase Postgres Changes ⚠️ |
| L-46 | Bastırılmış alıcıya "başarılı" gönderim ayrı normalleştirilir; bilinmeyen kod alarm üretir | FROZEN (landscape) | SES, SendGrid, Postmark |
| L-47 | Açılma verisi karar girdisi değil | FROZEN (landscape) | Apple MPP |
| L-48 | `sender_config` hatası aboneyi bastırmaz | FROZEN (landscape) | `5.7.x` sınıflandırma hatası |
| L-49 | Frekans tavanına takılanın kaderi açıkça yazılır | FROZEN (landscape) | Braze Canvas |
| L-50 | Alan adı çakışmasına karşı terim tablosu tek yerde | FROZEN (landscape) | OneSignal `external_id` |
| L-51 | Locale BCP 47 ve fallback zinciri | FROZEN (landscape) | Novu `en_US` |
| L-52 | Workflow'lar arası throttle, aktif throttle sıfırlama, paylaşılan layout/parça | FROZEN (landscape) | Knock |
| L-53 | Bekleme kayıt + zamanlayıcıdır; heartbeat zorunlu ayrım | FROZEN (landscape) | Trigger.dev, Step Functions |
| L-54 | Tekil sorumluluk dağıtık süreç kayıt defterine bağlanmaz | FROZEN (landscape) | Horde ⚠️ |
| L-55 | Hız sınırlayıcı kural testleri bilinen doğruluk hatalarından türetilir | FROZEN (landscape) | Hammer 2026 hata listesi |
| L-56 | Tek bölge / tek sağlayıcı bağımlılığı yok | FROZEN (landscape) | AWS us-east-1, 20 Ekim 2025 |
| L-57 | Orkestrasyon katmanı taşınabilir; kapanma riskine karşı self-host eşitliği ve dışa aktarım | FROZEN (landscape) | Amazon Pinpoint destek sonu |
| L-58 | Relay'in kendi olay bildirimi Relay'den geçmez | FROZEN (landscape) | Kendi kanalına bağımlı olay bildirimi döngüsü |
| MKT-1 | Her farklılaşma iddiası karşılaştırma kümesi, tarih ve geçersiz kılacak karşı örnek taşır; "bulunamadı ≠ ilk biz"; iddiaların düşmesi tezi değiştirmez | FROZEN (landscape) | §3.4; karşı örneksiz iddianın aylarca yanlış kalabilmesi |
| MKT-2 | Yerleşik eskalasyon zinciri | WATCH | K2, 2026-10-07 |
| MKT-3 | Kimliğe ve işleme bağlı insan yanıtı (Access + Relay) | WATCH | K1, K2, 2026-10-07 |
| MKT-4 | Self-host tam eşitlik + küçük bağımlılık seti | WATCH | K1, K5, 2026-10-07 |
| MKT-5 | Dayanıklı log olarak giden webhook | WATCH | K2, K3, 2026-10-07 |
| MKT-6 | Atlama nedeni olayları | WATCH | K1, 2026-10-07 |
| MKT-7 | İçerik tabanlı tekilleştirme | WATCH | K1, 2026-10-07 |
| MKT-8 | Etkileşimde duran kanal yükseltmesi | WATCH | K1, K5, 2026-10-07 |
| MKT-9 | Türkiye uyumu çekirdekte | WATCH | K1, K4, 2026-10-07; Infobip İYS desteği ⚠️ |
| MKT-10 | Kiracı özellikleri ücretsiz çekirdekte | WATCH | K1, 2026-10-07 |
| MKT-11 | Erken yanıt tamponu + doğrulanan karar | WATCH | K1, K2, 2026-10-07 |
| MKT-12 | Kanal-bağımsız kalıcı ajan posta kutusu | WATCH | K1, K2, 2026-10-07 |
| MKT-13 | Özne bazlı silme API'si (crypto-shredding) | WATCH | K3, 2026-10-07 |
| MKT-14 | Kesin sayaçlar ve dürüst garanti dili | WATCH | K3, 2026-10-07 |
| MKT-15 | Elixir'de açık kaynak workflow takibi ve dağıtık hız limiti | WATCH | K5, 2026-10-07; Hammer Postgres arka ucu ⚠️ |
| MKT-16 | Doğrulanmış sağlayıcıya kısıtlı failover | WATCH | K1, K4, 2026-10-07 |
| MKT-17 | `sender_config` hata sınıfı | WATCH | K4, 2026-10-07 |
| MKT-18 | Gelen ajan mesajı güven etiketi | WATCH | K2, 2026-10-07 |
| MKT-19 | Görsel editör + kod + GitOps (parite) | FROZEN (landscape) | Novu, Knock |
| MKT-20 | Gömülebilir inbox/toast/tercih bileşenleri, mobil SDK (parite) | FROZEN (landscape) | Novu, Courier, Knock, MagicBell |
| MKT-21 | Digest, throttle, gecikme, topic, A/B (parite) | FROZEN (landscape) | Knock, Novu, Courier, SuprSend |
| MKT-22 | Gömülebilir webhook portalı ve olay kataloğu (parite) | FROZEN (landscape) | Svix, Convoy |
