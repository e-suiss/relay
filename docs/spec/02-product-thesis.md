## 2. Product Thesis / IS / IS NOT

### 2.1 Tez

Relay bir **teslim ve kanıt** katmanıdır. Bir olayın ya da mesajın doğru alıcıya, doğru kanaldan, doğru zamanda ve kurallara uyarak ulaşmasını sağlar; ulaşıp ulaşmadığını ve ulaşmadıysa nedenini kaydeder; yanıt bekleniyorsa yanıtı toplar. Sınırı teslim, yanıt toplama ve kanıttadır. Yetki, onay, iş yürütme ve iş verisinin doğruluğu sınırın dışındadır (F-1).

Relay'in temel problemi ve tek sorusu §1.3 ve §1.5'teki gibidir; "yanıtı ne?" sorusunun cevabı yanıtın kendisidir, geçerliliği değil (F-2).

Tezin üç dayanağı:

1. **Kurallar tek yerde.** Kanal seçimi, retry, sağlayıcı yedeği, tercih, izin, sessiz saat ve kill switch her ürünün kendi kodunda değil, tek karar katmanındadır. Bir kuralın uygulanıp uygulanmadığı kayıttan görülür (MD-12, MD-14).
2. **Kanıt, iddiadan önce gelir.** Relay, sağlayıcının ya da kanalın kanıtlayamadığı bir sonucu iddia etmez (push için "delivered" yok, açılma verisi karar girdisi değil, bilinmeyen sonuç `unknown`). Garanti dili kanıtın izin verdiği kadardır (MD-15).
3. **İnsan, servis, cihaz ve ajan aynı motorda.** Ajan için ayrı bir bildirim ürünü yoktur. Kalıcı posta kutusu, realtime akış, webhook ve bekleme noktası aynı kalıcı kayıt çekirdeğini paylaşır (F-4).

### 2.2 Relay IS

| Alan | Relay'in yaptığı | Ayrıntı |
|---|---|---|
| Giriş | Kendi API'si ve CloudEvents HTTP bağlaması ile olay ve bildirim kabulü; idempotency; batch; iptal | §9 |
| Workflow ve yönlendirme | Sürümlü workflow, sekiz adım türü, rota politikaları, kanal yükseltme, eskalasyon, digest, throttle, tekrar eden bildirimler, A/B, topic | §10 |
| İçerik | Şablon, layout, marka, yerelleştirme, üretici sahipli korunan şablonlar, kanala göre render | §11 |
| Kanal ve sağlayıcı | Push (APNs, FCM, Web Push), e-posta, SMS, WhatsApp, sesli arama, in-app; sağlayıcı yedeği; hata sınıflandırması; teslim edilebilirlik | §12 |
| Tercih ve uyum | Mesaj sınıfları, tercih merkezi, izin kopyası, İYS, tek tıkla çıkış, ülke tablosu, sessiz saat, frekans tavanı | §13 |
| Teslim durumu | Append-only teslim defteri, normalleştirilmiş durum, atlama nedenleri, analitik özetler, iz (trace) | §14 |
| Inbox ve realtime | Kalıcı inbox, rozet, okundu semantiği, WebSocket ve SSE akışı, cihazlar arası senkron | §15 |
| Webhook ve olay teslimi | Relay olaylarının ve kiracı olaylarının imzalı teslimi; kuyruk ve nesne deposu hedefleri; DLQ, replay, gömülebilir portal | §16 |
| Ajanlar | Ajan alıcı kaydı, kalıcı posta kutusu, bekleme noktası, yanıt toplama, A2A/MCP/AG-UI uyumu, ajan kaynaklı bildirim tavanı | §17 |
| Kiracılık ve güvenlik | Kiracı, alt kiracı, bölge, operatör kimliği, anahtar ve sır yönetimi, kill switch, denetim kaydı | §18 |
| Ürün yüzeyi | Panel, görsel editör, CLI, SDK'lar, hazır UI bileşenleri, ürün içi test ortamı | §8 |
| Dağıtım | Aynı paketle self-host ve bölge başına SaaS kurulumu | §19, §20 |

Türkiye mevzuatı mimarinin girdisidir; AB ve ABD kuralları aynı tabloya satırdır (F-8). Kiracı ve alt kiracı özellikleri (marka, tercih varsayılanı, sağlayıcı hesabı, gönderici kimliği, inbox kapsamı) ücretsiz çekirdektedir (F-9). Ürün içi test ortamı canlı ortamla aynı işleme hattını kullanır; yalnız son adımda sahte sağlayıcı çalışır; sanal saat yalnız test düzlemindedir (F-10).

### 2.3 Relay IS NOT

| Relay ... değildir | Sahibi | Gerekçe | ID |
|---|---|---|---|
| Yetki ya da onay kaynağı | Access | Teslim ve kanal yanıtı yetki kanıtı değildir | MD-2 |
| Dayanıklı yürütme motoru (checkpoint, devam, telafi) | Executor, ajan çerçevesi, müşteri kodu | Relay bekleme noktası tutar, iş yürütmez | MD-3, F-6 |
| İnsanın iş ve onay kuyruğu | Work | Relay'deki posta kutusu ajanın kutusudur | F-14 |
| Kimlik sağlayıcı | Access ya da başka OIDC IdP | Relay kimliği bağlı IdP'den alır | MD-19 |
| OTP kodu üretici ve doğrulayıcı | Access ya da gönderen ürün | Relay kod üretmez, sır tutmaz, doğrulama yapmaz; yalnız teslim ve hedef korumaları | F-15 |
| Pazarlama otomasyonu (segment motoru, journey) | Kiracının sistemi | Öznitelik sorgulu segmentasyon ayrı ürün sınıfıdır | F-5, F-12 |
| Taşıma katmanı / MTA işletmecisi | Platformlar, ESP'ler, operatörler | Relay onları kullanır; SaaS'ta kendi MTA'sını işletmez | F-3 |
| Analitik veritabanı (OLAP) | Kiracının veri ambarı | Relay özet rapor üretir ve olay akışını dışa aktarır | F-7 |
| Müşteri veritabanını okuyan bağlayıcı | Kiracı (CDC araçları) | Debezium/Sequin gibi araçlar CloudEvents çıkışıyla bağlanır | F-13 |
| Uzun vadeli zamanlayıcı | Müşterinin zamanlayıcısı | İleri tarihli gönderim ve bekleme sınırlıdır | F-16 |
| Koşullu tercih motoru | Kiracının sistemi | Koşul iş kuralıdır; kiracı değerlendirir, olayı gönderir | F-17 |
| Müşteri kodu çalıştıran platform | — | Bridge, fetch, dönüşüm betiği, kod çalıştıran şablon yoktur | MD-16, F-19 |
| Ayrı realtime sunucusu ya da edge uygulaması | — | Realtime Phoenix içindedir; edge çalışma ortamı yoktur | MD-5, F-18 |

### 2.4 Kapsam ayrıntısı

#### 2.4.1 Alıcı türleri

Relay dört alıcı türüne teslim eder:

| Alıcı | Teslim yolu | Kalıcı kayıt |
|---|---|---|
| İnsan | Push, e-posta, SMS, WhatsApp, sesli arama, in-app | Inbox (insan yüzü: görüldü / okundu / arşiv / gizle) |
| Cihaz | Push, realtime akış | Inbox üzerinden; cihazlar arası okundu senkronu |
| Servis | HTTPS webhook, kuyruk/akış, nesne deposu | Teslim kaydı, DLQ, replay |
| Ajan | Posta kutusu + uyandırma ipucu (push, webhook, A2A push) | Posta kutusu (ajan yüzü: lease → ack) |

İnsan inbox'ı ile ajan posta kutusu aynı kalıcı kayıt çekirdeğini paylaşır: alıcı başına sıra numaralı kayıt, cursor ve outbox (§15, §17).

#### 2.4.2 Mesaj sınıfları kapsamı

Yedi sınıfın hepsi Relay'in kapsamındadır (MD-8). `marketing` sınıfı aynı motordan geçer ama ayrı şeritte, ayrı şablon tipiyle, ayrı uyum kurallarıyla ve e-postada ayrı akışla gider. Relay pazarlama iletisini gönderebilir; pazarlama kampanyasını (segment, journey) kurgulamaz.

#### 2.4.3 Kitle

Kitle üç yolla verilir: tek alıcı, istekte verilen liste ve topic aboneleri. Topic en fazla iki seviye hiyerarşilidir; fanout anında abone listesi dondurulur; aynı alıcı birden fazla yoldan abone olsa da tek bildirim alır. Öznitelik sorgulu segment yoktur; kiracı segmenti kendi sisteminde hesaplar ve liste olarak gönderir (§10).

#### 2.4.4 Zaman ufku

Relay kısa ve orta vadeli zamanlamayı üstlenir: ileri tarihli gönderim ve bekleme adımı ≤ 90 gün; digest/batch ve throttle penceresi ≤ 31 gün; olay bekleme (insan ve ajan yanıtı bekleyen bekleme noktaları dahil) ≤ 30 gün. Sınırı aşan istek doğrulama hatasıyla reddedilir. Daha uzun vadeli zamanlama müşterinin kendi zamanlayıcısının işidir (§10).

#### 2.4.5 Komşu sınırları

| Komşu | Sınır | Ayrıntı |
|---|---|---|
| Access | Kimlik, yetki, onay yüzeyi (CIBA), pazarlama izninin hukuki kaydı, OTP üretimi ve doğrulaması Access'tedir. Relay teslim kanalıdır | MD-1, MD-2, §7 |
| Executor ve ajan çerçeveleri | Yürütme durumu, checkpoint ve devam bekleyen taraftadır; Relay bekleme noktası ve "çözüldü" olayını sağlar | MD-3, §7, §17 |
| Work | İnsanın iş ve onay kuyruğu ve eskalasyon politikası Work'tedir; Relay politikayı uygular ve teslim eder | §7, §10 |
| One | Ajan çalıştırıcıdır; Relay One ajanlarına posta kutusu ve bekleme noktası sağlar | §7 |
| Pay ve diğer Suiss ürünleri | Olay üreticisi ve korunan şablon yayımcısıdır; içerik ve "kime, neden" üreticinindir | §7, §11 |
| Dış IdP'ler | Operatör girişi ve abone kimliği standart OIDC ile | §7, §18 |

### 2.5 Hangi problemi bilerek çözmez

| Problem | Neden Relay'in değil |
|---|---|
| "Bu kullanıcı bu kampanyaya uygun mu?" | Segment ve uygunluk iş kuralıdır; kiracı hesaplar |
| "Bu onay geçerli mi?" | Access'in sorusudur (MD-2) |
| "Ajan nerede kaldı, nasıl devam eder?" | Bekleyen tarafın sorusudur (MD-3) |
| "Bu kod doğru mu?" | Kodu üreten doğrular (F-15) |
| "Geçen yılın bildirimlerinden kohort analizi" | Kiracının veri ambarı; Relay olay akışını aktarır (F-7) |
| "Müşteri veritabanındaki değişikliği yakala" | CDC araçlarının işi (F-13) |

### 2.6 Farklılaşma

Relay'in farklılaşma iddiaları §4.4'tedir ve her biri karşılaştırma kümesi, tarih ve geçersiz kılacak karşı örnek taşır (§3.4). Tez farklılaşmaya dayanmaz: bir farklılaşma iddiası düşse de tez ve kapsam değişmez.

### 2.7 Relay must-never listesi (F-11)

| # | Must-never |
|---|---|
| 1 | Relay hiçbir teslimi, ack'i, görüldü/okundu/tıklama sinyalini ya da kanal yanıtını yetki ya da onay olarak sunmaz ve kaydetmez. |
| 2 | Relay, Access ve Work olaylarında üreticinin belirlediği alıcı kümesini genişletmez ya da daraltmaz. |
| 3 | Relay hiçbir bildirimi sessizce düşürmez; gönderilmeyen her bildirim `reason` + `rule_id` ile kaydedilir. |
| 4 | Relay kiracının, operatörün ya da müşterinin sağladığı kodu sunucuda çalıştırmaz (bridge çağrısı, dönüşüm betiği, kod çalıştıran şablon dili dahil). |
| 5 | Relay veritabanında fiziksel silme yapmaz. |
| 6 | Relay bir uyum ya da güvenlik kapısını bayrak, kategori, öncelik ya da mesaj başına alanla atlatmaz; kiracıya uyum kuralını gevşetme hakkı vermez. |
| 7 | Relay ajana serbest metin talimat yazmaz; güvenilmez içeriği kontrol alanlarında taşımaz. |
| 8 | Relay OTP kodu üretmez, sır tutmaz, doğrulama yapmaz; `otp_oob` iletisini ve onun fallback zincirini e-postaya düşürmez. |
| 9 | Relay bir bölgenin verisini başka bölgeye akıtmaz. |
| 10 | Relay hiçbir özelliği yalnız SaaS'a ya da lisans bayrağına kilitlemez. |
| 11 | Relay push için "delivered" iddia etmez; e-posta açılma verisini hiçbir kararında kullanmaz. |
| 12 | Relay `security` sınıfını ve kilitli kategorileri hiçbir tercih seviyesinden kapattırmaz; `security` sınıfında ve OTP/doğrulama e-postalarında açılma ya da tıklama takibi açmaz. |
| 13 | Relay yanıt jetonunu ya da bekleme noktası kimliğini ajanın bağlamına koymaz; bekleyenin kendi bekleme noktasını yanıtlamasına izin vermez. |
| 14 | Relay bir mesajın sınıfını kabulden sonra değiştirmez ve mesajı sınıfının şeridinden başka şeride geçirmez. |
| 15 | Relay Valkey'e asıl kayıt yazmaz; bir sayaç okunamadığında "limitsiz" duruma düşmez. |
| 16 | Relay "exactly-once" ifadesini tek başına kullanmaz. |

Bu listenin her maddesi bir merkezi karardan ya da bölüm kararından türer; kanonik değişmez dili §6'dadır.

### 2.8 Karar register'ı

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| F-1 | Tez: Relay teslim, yanıt toplama ve kanıt katmanıdır; yetki, onay, yürütme ve iş verisi sınırın dışındadır | FROZEN (ürün) | MD-2, MD-3 |
| F-2 | Relay'in temel problemi ve tek sorusu §1.3 ve §1.5'teki gibidir; "yanıtı ne?" sorusunun cevabı yanıtın kendisidir, geçerliliği değil | FROZEN (ürün) | MD-2 |
| F-3 | Relay taşıma katmanlarını kullanır, yerine geçmez; giden e-postada ESP adaptörleri ve "kendi posta sunucunu bağla" SMTP adaptörü vardır; SaaS'ta Relay MTA işletmez; bounce işleme Relay'dedir | FROZEN (ürün) | Kendi MTA'nın MTA-STS, DKIM rotasyonu ve ısınma yükü; ESP'lerin olgunluğu |
| F-4 | İnsan, cihaz, servis ve ajan alıcıları aynı motordan geçer; inbox ve ajan posta kutusu aynı kalıcı kayıt çekirdeğinin iki yüzüdür | FROZEN (ürün) | Ajan için ayrı ürün yerine tek teslim motoru; MD-15 |
| F-5 | Relay pazarlama iletisini gönderir ama pazarlama otomasyonu değildir; kitle tek alıcı, liste ya da topic ile verilir | FROZEN (ürün) | `marketing` ayrı şeritte (MD-8); segment ve journey ayrı ürün sınıfı (Braze, Iterable, Customer.io Journeys) |
| F-6 | Relay workflow'u bir bildirim akışıdır (kanal, bekle, digest, throttle, koşul, olay bekle, zaman penceresi, webhook); iş süreci değildir | FROZEN (ürün) | MD-3, MD-16 |
| F-7 | Analitik Postgres özet tablolarından hazır raporlar + anlamsal olay akışının kiracı hedefine aktarılmasıdır; Relay içinde OLAP yoktur; analitik veritabanları yalnız teslim hedefidir | FROZEN (ürün) | MD-6 bağımlılık sınırı; Customer.io/Braze olay akışı modeli |
| F-8 | Türkiye mevzuatı mimarinin girdisidir; AB ve ABD kuralları aynı tabloya satırdır | FROZEN (ürün) | MD-17; küresel orkestrasyon platformlarında İYS bulunmaması (§4.4) |
| F-9 | Kiracı ve alt kiracı özellikleri (marka, tercih varsayılanı, sağlayıcı hesabı, gönderici kimliği, inbox kapsamı) ücretsiz çekirdektedir | FROZEN (ürün) | MD-4, MD-18 |
| F-10 | Ürün içi test ortamı canlı ortamla aynı işleme hattını kullanır; yalnız son adımda sahte sağlayıcı çalışır; sanal saat yalnız test düzlemindedir | FROZEN (ürün) | MD-18; güvenliği zayıflatan bayrak yok (MD-14) |
| F-11 | §2.7 must-never listesi (#1–#16) bağlayıcıdır | FROZEN (ürün) | Her madde bir MD ya da bölüm kararından türer |
| F-12 | Öznitelik sorgulu segment motoru | KAPSAM DIŞI | Pazarlama otomasyonu ürünüdür; kiracı segmenti hesaplayıp liste gönderir |
| F-13 | Müşteri veritabanını okuyan bağlayıcı | KAPSAM DIŞI | CDC araçları (Debezium, Sequin) CloudEvents çıkışıyla bağlanır; dokümantasyonda rehber verilir |
| F-14 | İnsanın iş ve onay kuyruğu | KAPSAM DIŞI | Work'ündür (Access XI-7); Relay'deki posta kutusu ajanın kutusudur |
| F-15 | OTP kodu üretme, sır tutma ve doğrulama | KAPSAM DIŞI | Kod ve güven seviyesi gönderenin işidir; Relay hedef korumalarını uygular |
| F-16 | 90 günden uzun zamanlama, 31 günden uzun digest/throttle penceresi, 30 günden uzun olay bekleme | KAPSAM DIŞI | Uzun beklemeler müşterinin zamanlayıcısının işidir; sınırlar §10'da |
| F-17 | Koşullu tercih | KAPSAM DIŞI | Koşul iş kuralıdır; kiracı sistemi değerlendirip olayı gönderir |
| F-18 | Ayrı realtime sunucusu (Centrifugo vb.), WebTransport ve edge çalışma ortamları | KAPSAM DIŞI | Realtime Phoenix içindedir (MD-5); ayrı çalışma ortamı ayrı jeton katmanı ve işletim yükü getirir |
| F-19 | Kiracı dönüşüm betiği, bridge modeli, fetch/update/invoke adımları | KAPSAM DIŞI | MD-16 |
