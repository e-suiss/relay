## 16. Webhook ve Event Teslimi

**Bu bölümün kuralları.**
- Bu bölüm Relay'in dışarıya olay teslim eden motorunu tanımlar: Suiss webhook profili, olay biçimi, hedef türleri, yeniden deneme takvimi, DLQ ve replay, uç sağlığı, SSRF koruması ve gömülebilir portal. Gelen sağlayıcı webhook'larının kabulü de buradadır. Karar ID'leri WH-1…WH-51'dir; register §16.12'dedir.
- Teslim projeksiyonu ve olayların anlamı §14'te; workflow'daki `webhook` adımının akış içindeki yeri §10'da; sır ve anahtar yönetimi ile kriptografi §18'de; ajanlara push ve A2A teslimi §17'dedir.
- Webhook bir bildirimdir, durum kaynağı değildir. Teslim en az bir kezdir; kesin durum her zaman API'den okunur. Teslimin kaybı ya da gecikmesi hiçbir yetki kararını etkilemez (Access TN-136, Access E40).

---

### 16.1 Tek teslim motoru, iki kullanım

#### 16.1.1 İki kullanım (WH-1)

Relay'de dışarıya olay teslim eden tek bir motor vardır. İki kullanımı vardır:

| Kullanım | Kim gönderir, kime | Örnek |
|---|---|---|
| **A. Relay olayları** | Relay → kiracının kendi sistemleri | Teslim, bounce, etkileşim, atlama nedeni, İYS reddi, cihaz geçersizleşmesi |
| **B. Event destination (`webhook` kanalı)** | Kiracı → kendi müşterilerinin sistemleri | Bir e-ticaret platformunun mağazalarına imzalı "sipariş kargoya verildi" olayı |

İki kullanım aynı retry takvimini, imzayı, DLQ'yu, replay'i, SSRF korumasını ve uç sağlığı denetimini kullanır. Ajanlara A2A push teslimi de bu motoru kullanır (§17).

#### 16.1.2 Kavramlar (WH-2)

| Kavram | Anlamı |
|---|---|
| **Olay türü** | Katalogdaki sürümlü şemalı olay (`notification.suppressed`, kiracının `order.shipped`'i) |
| **Tüketici** | Olayları alan taraf. A kullanımında kiracının kendisi, B kullanımında kiracının bir müşterisi |
| **Uç (hedef)** | Tüketicinin teslim adresi: HTTPS URL, kuyruk, akış ya da nesne deposu (§16.4) |
| **Mesaj** | Bir olayın bir uca teslim işi |
| **Deneme** | Bir mesajın tek teslim girişimi |

Bir olay bir uca en fazla bir mesaj üretir: tekillik `(endpoint_id, event_id)` üzerinde, zamana bağlı olmayan bir DB kısıtıyla sağlanır.

#### 16.1.3 Garanti dili (WH-3)

1. Teslim en az bir kezdir; aynı olay birden fazla gelebilir. Tüketici `webhook-id` ile tekilleştirir.
2. Sıra garantisi yoktur (§16.4.4).
3. "Exactly-once" ifadesi kullanılmaz; doğru ifade "en az bir kez teslim + tüketici tarafında kalıcı tekilleştirme"dir.

---

### 16.2 Suiss webhook profili

#### 16.2.1 Başlıklar ve imza (WH-4)

1. Relay, Standard Webhooks ile uyumlu Suiss webhook profilini kullanır; profil Access ile ortaktır ve müşteri iki ürünün olaylarını tek doğrulayıcıyla kabul eder (Access TN-136, Access E40).
2. Başlıklar: `webhook-id` (olay kimliği; denemeler arasında değişmez), `webhook-timestamp` (Unix saniye), `webhook-signature` (boşlukla ayrılmış imza listesi).
3. İmzalanan içerik: `{webhook-id}.{webhook-timestamp}.{ham gövde}`.
4. Varsayılan imza şeması `v1a` (Ed25519). `v1` (HMAC-SHA256) yalnız uyumluluk için uç başına seçilebilir.

#### 16.2.2 Anahtarlar (WH-5)

1. Her uç kendi imza anahtarına sahiptir; anahtar uçlar arasında paylaşılmaz.
2. Ed25519 özel anahtarı KMS/HSM arka ucunda tutulur (§18); açık anahtar her zaman okunabilir ve portalda yayımlanır.
3. HMAC sırrı yalnız oluşturma yanıtında bir kez gösterilir; sonra hiçbir uçtan geri okunamaz.

#### 16.2.3 Anahtar rotasyonu (WH-6)

Rotasyon çakışmalıdır: yeni anahtar oluşturulur, çakışma penceresi boyunca her mesaj iki imza taşır (`v1a,<yeni> v1a,<eski>`), pencere sonunda eski anahtar devre dışı kalır. Varsayılan pencere 24 saattir (0–168 saat).

#### 16.2.4 Zaman damgası ve tüketici önerileri (WH-7)

1. `webhook-timestamp` her denemede yenilenir; olayın oluşma zamanı gövdedeki `time` alanıdır.
2. Tüketiciye yayımlanan doğrulama kuralları: imzayı ham gövde üzerinde doğrula (yeniden serileştirme yok); sabit zamanlı karşılaştır; zaman damgası toleransı 5 dakika; `webhook-id`'yi en az 96 saat sakla (retry penceresinin üstünde).
3. Her sunucu SDK'sı ham gövde webhook doğrulayıcısını taşır; dokümantasyon her dilde doğrulama örneği içerir.

#### 16.2.5 Olay zarfı (WH-8)

1. Gövde CloudEvents 1.0 structured JSON'dur: `specversion`, `id` (= `webhook-id`), `source`, `type`, `time`, `subject`, `datacontenttype`, `dataschema` (sürümlü şema), `data`.
2. Uzantılar: `seq` (konu başına monoton sıra; §16.4.4), `traceparent` (§14.8.1), ortam (`live`/`test`).
3. Kuyruk ve akış hedeflerinde, hedefin CloudEvents bağlamasına göre structured ya da binary mod kullanılır.
4. B kullanımında kiracının müşterisine giden olaylarda Relay'in iç kiracı kimliği bulunmaz; `source` kiracının tanımladığı değerdir.

#### 16.2.6 İmzasız başlıklar (WH-9)

Kolaylık için eklenen imzasız başlıklar (olay türü, deneme numarası) bulunabilir; hiçbir güvenlik kararı bunlara dayanmaz ve tüketici dokümantasyonu bunu açıkça yazar.

#### 16.2.7 Deneme günlüğü (WH-10)

Her denemede şunlar kaydedilir: ham gövdenin özeti, üretilen imza, hedef IP'si, durum kodu, süre ve yanıt gövdesinin ilk 8 kB'ı. Yanıt gövdesi tüketiciye ham hâliyle gösterilir; kişisel veri taşıyabileceği için teslim günlüğünün saklama sınıfındadır.

---

### 16.3 İnce olay, snapshot ve olay kataloğu

#### 16.3.1 İnce olay varsayılanı (WH-11)

Varsayılan yük ince olaydır: `type`, `id` ve ilgili kimlikler (bildirim, teslim, alıcının dış kimliği, workflow anahtarı, alt kiracı, `rule_id`). Ayrıntı yetkili API çağrısıyla alınır. İnce olay kişisel veri taşımaz, şema sürümü sorununu ve sırasız olayda bayat veri sorununu azaltır.

#### 16.3.2 Snapshot (WH-12)

1. Uç bazında isteğe bağlı snapshot: yüke eklenecek alanlar beyaz listeyle seçilir.
2. Snapshot uç sürümüne sabitlenir; API sürümü yükseltmek ya da iç modelin değişmesi webhook yükünü değiştirmez. Beyaz listeyi değiştirmek uçta yeni bir sürüm açar.
3. Kişisel veri taşıyan alanlar beyaz listeye yalnız açık seçimle ve panelde uyarıyla girer.

#### 16.3.3 `webhook` kanalında yük (WH-13)

1. B kullanımında yükün şeması kiracının olay türü şemasıdır (JSON Schema 2020-12). Varsayılan yük `type`, `id` ve kiracının olay türünde beyan ettiği kimliklerdir; ek alanlar beyaz listeyle seçilir ve sürüme sabitlenir.
2. Kiracı kodu (dönüşüm betiği) çalıştırılmaz. Dönüşüm yalnız alan beyaz listesi ve CloudEvents öznitelik eşlemesiyle yapılır.

#### 16.3.4 Olay adları ve katalog (WH-14)

1. Olay adları `noun.verb_past` biçimindedir (`notification.suppressed`, `webhook_endpoint.disabled`) ve tek bir sözlükte tutulur.
2. Olay kataloğu AsyncAPI 3.1 belgesi + JSON Schema 2020-12 şemaları olarak yazılır ve sözleşme önce onaylanır (§9). Her olay türünün şeması sürümlüdür; şema değişikliği olay türünde yeni sürüm açar.
3. Kiracının B kullanımındaki olay türleri de aynı katalog yapısında, kiracı kapsamında tutulur ve portalda şema ile örnek yükle gösterilir.

#### 16.3.5 Relay olay aileleri (WH-15)

A kullanımında Relay'in kiracıya teslim ettiği olay aileleri:

| Aile | İçerik |
|---|---|
| Teslim projeksiyonu | `status` geçişleri (§14.3) |
| Atlama ve hata | `notification.suppressed` (`reason`, `rule_id`), `notification.render_failed` |
| Etkileşim | Görüldü, okundu, tıklandı (insan/bot ayrımı), arşivlendi |
| E-posta geri bildirimi | Bounce, şikâyet |
| İzin ve uyum | İYS reddi, tek tık çıkış, SMS ret anahtar kelimesi (§13) |
| Abone, cihaz, tercih | Cihaz geçersizleşmesi, tercih değişikliği |
| Kota ve limit | Kota eşiklerine ulaşma |
| Bekleme noktası ve ajan | §17'deki olaylar (ör. `waitpoint.expired`) |
| Webhook işletimi | §16.6.5'teki olaylar |

Kesin ad listesi olay kataloğudur (WH-14).

#### 16.3.6 Abonelik filtresi (WH-16)

1. Uç yalnız seçtiği olay türlerini alır. Seçim boşsa hiçbir olay gönderilmez.
2. Bütün olay türleri (`*`) açıkça seçilebilir; panelde ve portalda uyarı gösterilir.
3. Kiracı başına ve tüketici başına uç sayısı sınırlıdır; aynı URL'ye birden fazla uç tanımlanabilir.

---

### 16.4 Hedef türleri

#### 16.4.1 Hedef seti (WH-17)

Bütün hedefler ortak bir hedef arayüzünün (port) arkasındadır:

| Hedef | Kimlik doğrulama |
|---|---|
| HTTPS webhook | Suiss profili imzası; ek olarak isteğe bağlı mTLS ya da OAuth2 client credentials |
| Kafka, NATS JetStream, RabbitMQ | Aracının kimlik doğrulama yöntemi (SASL, TLS istemci sertifikası, kullanıcı kimlik bilgisi) |
| AWS SQS, SNS, EventBridge | IAM rolü ya da erişim anahtarı |
| Google Pub/Sub | Servis hesabı |
| Azure Service Bus, Event Grid | Bağlantı kimlik bilgisi ya da yönetilen kimlik |
| S3 uyumlu nesne deposu | Depo kimlik bilgisi; toplu yazım |

#### 16.4.2 Başarı tanımı (WH-18)

| Hedef | Başarı |
|---|---|
| HTTPS | 2xx yanıt (§16.5.2) |
| Kuyruk, akış | Aracının kalıcı yazım onayı |
| Nesne deposu | Nesne yazımının onayı |

Bütün hedeflerde teslim en az bir kezdir; tüketici CloudEvents `id` ile tekilleştirir.

#### 16.4.3 Hedef kimlik bilgileri (WH-19)

Hedef kimlik bilgileri veritabanında yalnız sır referansı olarak durur (§18). URL ya da bağlantı dizgesi içine düz sır yazılmaz; sırlar loglara ve deneme günlüğüne yazılmaz.

#### 16.4.4 Sıra (WH-20)

1. Varsayılan olarak teslim sırası garanti edilmez; sıra garantisi head-of-line tıkanması üretir (bir uçta takılan mesaj arkasındakileri bekletir).
2. Her olay konu (`subject`) başına monoton bir `seq` taşır; tüketici boşluğu ve sırayı görür, kesin durum için API'yi okur.
3. Bölümlü hedeflerde (Kafka, sıralı Pub/Sub, FIFO kuyruklar) sıra anahtarı hedefin bölüm anahtarına eşlenir: aynı konunun olayları aynı bölüme gider.

#### 16.4.5 Nesne deposuna toplu yazım (WH-21)

Nesne deposu hedefine olaylar süre ya da boyut eşiğiyle partiler hâlinde yazılır; dosya biçimi CloudEvents structured JSON satırlarıdır. Dosya adı parti kimliğinden türetilir; aynı partinin yeniden yazılması aynı nesneyi üretir. Ham verinin CSV/Parquet dışa aktarımı §14.7'dedir.

---

### 16.5 Yeniden deneme takvimi ve durum kodları

#### 16.5.1 Takvim (WH-22)

1. Varsayılan takvim 10 deneme, toplam yaklaşık 76 saattir. Denemeler arası bekleme: hemen, 5 sn, 5 dk, 30 dk, 2 sa, 5 sa, 10 sa, 14 sa, 20 sa, 24 sa.
2. Her beklemeye ±%20 jitter uygulanır; jitter deterministiktir (mesaj kimliğinden türetilir), rastgele değildir.
3. Kiracı uç başına takvimi değiştirebilir; deneme sayısı ve toplam süre üst ve alt sınırlar içindedir. Sonsuz yeniden deneme yoktur.

#### 16.5.2 Durum kodu tablosu (WH-23)

| Yanıt | Davranış |
|---|---|
| 2xx | Başarı |
| 3xx | Başarısız; yönlendirme izlenmez; yeniden denenmez (`failed_permanent`, `redirect_not_followed`); uç sağlığına uyarı yazılır |
| 410 | Kalıcı: mesaj `failed_permanent`, uç anında devre dışı (§16.7.2) |
| 401, 407, 409, 429, 5xx | Yeniden denenir |
| Diğer 4xx | Yeniden denenmez (`failed_permanent`) |
| Bağlantı hatası, zaman aşımı, TLS hatası | Yeniden denenir |

#### 16.5.3 Zaman aşımları (WH-24)

Bağlantı kurma zaman aşımı 5 saniye, toplam istek süresi 20 saniyedir. Yanıt gövdesinin en fazla 8 kB'ı okunur.

#### 16.5.4 `Retry-After` (WH-25)

429 ve 503 yanıtında `Retry-After` varsa, takvimdeki bekleme ile `Retry-After`'dan uzun olan (temkinli olan) uygulanır. `Retry-After` kaynaklı ertelemeler deneme sayacını tüketmez; bir mesaj için en fazla 3 kez böyle ertelenir, sonra normal takvim işler.

#### 16.5.5 Tüketicinin iptal sinyali (WH-26)

Tüketici yanıtta `webhook-delivery: abort-message` başlığını dönerse mesaj yeniden denenmez ve `failed_permanent` (`aborted_by_consumer`) olur.

#### 16.5.6 Terminal durumlar (WH-27)

| Durum | Anlamı |
|---|---|
| `delivered` | Başarılı teslim |
| `failed_permanent` | Kalıcı hata (410, yeniden denenmeyen 4xx, 3xx, tüketici iptali) |
| `exhausted` | Takvimdeki bütün denemeler başarısız |
| `expired` | Olayın teslim süresi (TTL) doldu |
| `window_exceeded` | Hedefin hız sınırı ya da birikmiş kuyruk yüzünden denemeler pencere içinde yapılamadı |
| `dead_lettered` | Teslim girişimi yapılamadı (uç silindi, hedef yapılandırması geçersiz, yük sınırı aşıldı, hedef reddetti) |
| `cancelled` | Kiracı ya da operatör mesajı iptal etti |

`delivered` dışındaki terminal durumlardaki mesajlar DLQ'da kalıcıdır (§16.6.1).

#### 16.5.7 Birikme ve pencere (WH-28)

1. Uç başına birikmiş kuyruğun yaşı (en eski bekleyen mesajın yaşı) metrik olarak ölçülür.
2. Hedef hız sınırı ile retry penceresinin etkileşimi modellenir: birikme yüzünden mesajın penceresi dolarsa `window_exceeded` olur ve kiracıya alarm gider.

#### 16.5.8 Yük boyutu (WH-29)

Yük boyutunun sert sınırı vardır; sınırı aşan olay teslim edilmez (`dead_lettered`, `payload_too_large`) ve kaydedilir. İnce olay hedefi 20 kB'ın altıdır.

---

### 16.6 DLQ, replay ve kurtarma

#### 16.6.1 Dayanıklı log (WH-30)

1. Webhook dayanıklı bir log olarak çalışır: başarısız terminal mesajlar kalıcı DLQ'da tutulur.
2. "Kaçırılan olaylar" listesi uç ve zaman aralığına göre sorgulanır: DLQ'daki mesajlar ve uç devre dışıyken üretilip denenmemiş olaylar.
3. Teslim günlüğü (mesajlar, denemeler) API ve portalda listelenir. Teslim günlüğünün ve DLQ'nun saklama süresi kiracı saklama politikasının parametresidir.

#### 16.6.2 Kurtarma API'si (WH-31)

Kurtarma işlemleri birinci sınıf API'dir:

| İşlem | Anlamı |
|---|---|
| Tek mesaj yeniden gönder | Bir mesaj için hemen bir deneme |
| `recover` | Bir uç için belirli bir zamandan beri başarısız ya da denenmemiş mesajları yeniden kuyruğa al |
| Filtreli toplu retry | Olay türü, durum, zaman aralığı ve hata koduna göre seçilen mesajlar |
| Replay | Saklama süresindeki olayları başka bir uca (ör. yeni eklenen uç) teslim et |
| Pause / resume | Uca teslimi durdur ve sürdür; duraklatılmış uçta mesajlar birikir, atılmaz |
| Planlanmış retry iptali | Bekleyen denemeleri iptal et (`cancelled`) |

#### 16.6.3 Elle gönderim ile otomatik retry (WH-32)

1. Takvimi süren bir mesaj için elle gönderim hemen bir deneme yapar. Başarılıysa bekleyen otomatik denemeler iptal edilir ve mesaj `delivered` olur. Başarısızsa takvim değişmeden devam eder; elle deneme takvim sayacını tüketmez.
2. Terminal durumdaki mesaj için elle gönderim tek bir deneme yapar. Başarısızsa mesaj önceki terminal durumunda kalır ve deneme günlüğe eklenir.
3. Toplu retry ve `recover`, seçilen her mesaj için takvimi baştan başlatır.
4. Aynı mesaj için aynı anda en fazla bir deneme yürür; elle ve otomatik deneme yarışmaz.

#### 16.6.4 Replay kimliği ve hızı (WH-33)

1. Yeniden gönderim, recover ve replay olayın `id`'sini (`webhook-id`) korur; tüketici tekilleştirmesi çalışır. Deneme numarası artar.
2. Kurtarma işlemleri uç hız sınırı içinde, kontrollü hızda ve kiracılar arası adil biçimde çalışır; canlı trafiği bastırmaz.

#### 16.6.5 İşletim olayları (WH-34)

1. Relay şu olayları üretir: `webhook.attempt_exhausted`, `webhook_endpoint.disabled`, `webhook_endpoint.recovered`.
2. Bu olaylar kiracının diğer uçlarına webhook olarak, panelde ve e-postayla bildirilir. Devre dışı kalan uç kendi devre dışı olayını almaz.

---

### 16.7 Uç sağlığı

#### 16.7.1 Uç devre kesicisi (WH-35)

1. Her uç için bir devre kesici vardır; art arda hata ve zaman aşımıyla açılır.
2. Kesici açıkken olaylar atılmaz, bekletilir; kesici yarı açık durumda sınırlı yoklama yapar, başarıda kapanır.
3. Kesicinin açık kaldığı süre deneme sayacını tüketmez; olayın penceresi ise işlemeye devam eder.

#### 16.7.2 Otomatik devre dışı bırakma (WH-36)

1. Bir uç 5 gün kesintisiz başarısız olursa devre dışı kalır. Saat ancak 24 saat içinde birden fazla hata olduğunda **ve** ilk ile son hata arasında en az 12 saat bulunduğunda başlar. Tek bir başarılı teslim saati sıfırlar.
2. 410 yanıtı uçu anında devre dışı bırakır.
3. Kesintinin 72. saatinde kiracıya uyarı gider.
4. Kiracı uç başına otomatik devre dışı bırakmayı kapatabilir; bu durumda uç etkin kalır, mesajlar yine kendi takvimiyle sonlanır.

#### 16.7.3 Devre dışı uç ve geri açma (WH-37)

1. Devre dışı uca yeni olay denenmez; olaylar "kaçırılan olaylar" listesine yazılır ve saklama süresince durur. Tüketicinin uç arızası yüzünden verisi atılmaz.
2. Uç yeniden etkinleştirildiğinde kiracı `recover` ile kaçırılan olayları kuyruğa alabilir.

#### 16.7.4 Uç izolasyonu ve adalet (WH-38)

1. Her uçun eşzamanlılık ve hız sınırı vardır; kiracı sınırlar içinde ayarlar.
2. Yavaş ya da hatalı bir uç diğer uçların teslimini bloklamaz.
3. Kiracı başına ayrı kuyruk yoktur; kiracılar arası adalet kuyruk içinde sağlanır (§19).

#### 16.7.5 Sağlık paneli (WH-39)

Panelde ve portalda her uç için: başarı oranı, gecikme dağılımı, son başarılı teslim, birikmiş kuyruk yaşı, kesici durumu, devre dışı nedeni ve son hataların özeti gösterilir. Uç belirli bir süredir yanıt vermiyorsa kiracıya otomatik bildirim gider.

---

### 16.8 SSRF koruması

#### 16.8.1 Kayıt kuralları (WH-40)

1. HTTPS uçları yalnız `https://` olabilir; bu kural test düzleminde de geçerlidir.
2. Port 443'tür; kurulum yöneticisi ek portları izin listesine alabilir.
3. Kullanıcı bilgisi (`user:pass@`) içeren URL reddedilir.
4. Kayıtta alan adının bütün A/AAAA kayıtları engelli aralıklara karşı kontrol edilir. Bu kontrol yalnız erken geri bildirimdir, güvenlik sınırı değildir.

#### 16.8.2 Bağlanma anında doğrulama (WH-41)

1. Asıl güvenlik sınırı bağlanma anındadır: alan adı çözülür, IP doğrulanır, bağlantı doğrulanmış IP'ye kurulur; SNI ve `Host` özgün alan adıdır. DNS yeniden bağlama (rebinding) bu yolla etkisizdir.
2. IPv4-mapped IPv6 adresleri kanonik IPv4'e indirgenerek kontrol edilir.
3. Engelli aralıklar: `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `127.0.0.0/8`, `169.254.0.0/16`, `172.16.0.0/12`, `192.0.0.0/24`, `192.0.2.0/24`, `192.168.0.0/16`, `198.18.0.0/15`, `198.51.100.0/24`, `203.0.113.0/24`, `224.0.0.0/4`, `240.0.0.0/4`, `255.255.255.255/32`, `::/128`, `::1/128`, `::ffff:0:0/96`, `64:ff9b::/96`, `100::/64`, `2001:db8::/32`, `fc00::/7`, `fe80::/10`, `ff00::/8` ve bulut sağlayıcılarının metadata adresleri. Liste veridir.

#### 16.8.3 Ağ izolasyonu ve çıkış (WH-42)

1. Teslim işçileri, iç servislere (Postgres, Valkey, iç API'ler, KMS) erişimi olmayan ayrı bir ağ bölümünden çıkar.
2. IP filtreli bir çıkış proxy'si isteğe bağlı ek katmandır.
3. Yönlendirmeler izlenmez.
4. Her bölgenin sabit çıkış IP'leri yayımlanır; çıkış IP'leri bölge dışına taşmaz (§18).

#### 16.8.4 Kapsam (WH-43)

1. SSRF kuralları bütün dış teslim yollarına uygulanır: HTTPS uçları, workflow `webhook` adımı, A2A push, kuyruk ve aracı adresleri, OAuth2 token uçları.
2. Workflow `webhook` adımı yalnız kayıtlı bir uca teslim eder; çalışma anında olay verisinden hesaplanan bir URL'ye istek atmaz. Adımın yanıtı workflow'a veri olarak dönmez (veri çekme adımı yoktur; §10).

#### 16.8.5 Self-host'ta iç ağ hedefleri (WH-44)

Self-host kurulumunda kurumun iç ağındaki bir hedefe teslim (engelli aralıktaki adres) varsayılan olarak yapılmaz. İç ağ hedefi yalnız kurulum operatörünün tanımladığı izin listesiyle açılır:
1. İzin listesi kurulum düzeyindedir ve aralık (CIDR) ya da ana makine başına beyan edilir; kiracı izin listesini açamaz, genişletemez.
2. Her ekleme, değişiklik ve kaldırma denetim kaydına girer (§18).
3. İzin listesi bağlanma anındaki doğrulamayı (WH-41) kaldırmaz; yalnız listedeki aralıklar engelli aralık kontrolünden muaf tutulur. Bulut metadata adresleri ve geri döngü (`127.0.0.0/8`, `::1/128`) izin listesine eklenemez.
4. SaaS kurulumunda iç ağ hedefi yoktur.

#### 16.8.6 Ortam ve yerel geliştirme (WH-45)

1. Uç oluşturulduğu ortama (`live`/`test`) bağlıdır ve sonradan değiştirilemez. Test düzlemi de aynı SSRF kurallarına tabidir; güvenliği zayıflatan bayrak yoktur.
2. Yerel geliştirme CLI tüneliyle yapılır (`relay listen --forward-to`); API'de müşteri tanımlı köprü URL'si yoktur.
3. Her uç için sahte olay gönderen test işlemi vardır.

---

### 16.9 Gömülebilir portal

#### 16.9.1 Portal yetenekleri (WH-46)

Kiracı, kendi müşterilerine gömülebilir bir webhook portalı sunar (React bileşeni + web component; §8). Tüketici portalda: uç ekler ve devre dışı bırakır, olay türü seçer, katalogdaki şema ve örnek yükleri görür, teslim günlüğünü ve başarısız teslimleri görür ve yeniden gönderir, `recover` yapar, imza anahtarını döndürür, açık anahtarı ve doğrulama örneklerini görür, test olayı gönderir, uç sağlık panelini görür.

#### 16.9.2 Portal yetkisi ve marka (WH-47)

1. Portal, kiracı backend'inin Relay API anahtarıyla bastığı kısa ömürlü bir portal jetonuyla açılır. Jeton tek bir tüketiciye kapsamlıdır; tüketici yalnız kendi uçlarını ve mesajlarını görür.
2. Portal kiracının ve alt kiracının marka ve temasını kullanır.

#### 16.9.3 Portal denetimi (WH-48)

Portal ve API'den yapılan uç ekleme, silme, anahtar rotasyonu, otomatik devre dışıyı kapatma ve toplu kurtarma işlemleri denetim kaydına girer (§18).

---

### 16.10 Gelen webhook'lar

#### 16.10.1 Sağlayıcı webhook kabulü (WH-49)

1. Sağlayıcıdan gelen webhook (DLR, bounce, etkileşim, gelen mesaj) önce kalıcı bir makbuz olarak yazılır, sonra hızlı bir 2xx döner; işleme kuyruktan yapılır.
2. İmza sağlayıcı başına, ham gövde üzerinde, sabit zamanlı karşılaştırmayla doğrulanır. Standard Webhooks uyumlu sağlayıcılar için tek ortak doğrulayıcı kullanılır.
3. Tekilleştirme kalıcıdır: `(tenant, provider, provider_event_id)` üzerinde tekil makbuz; tekrar gelen olay işlenmez, sayılır.
4. Doğrulanan olay §14'teki kanıt tablosuna göre deftere yazılır.

#### 16.10.2 Uzun iş bitişi bildirimi (WH-50)

Uzun süren işlerin bitiş bildirimleri (ör. dışa aktarım tamamlandı) Suiss webhook profiliyle gönderilir. Giden ve gelen yönde aynı doğrulayıcı kullanılır.

#### 16.10.3 Access webhook'ları (WH-51)

Access kendi kimlik ve yetki olaylarını kendisi teslim eder (Access TN-136). Relay bu olayları (izin değişikliği, organizasyon eşlemesi, ajan askısı) aynı profil ve aynı doğrulayıcıyla tüketir; kabul kuralları §16.10.1 ile aynıdır.

---

### 16.11 Bölüm sınırları

- Access ile ortak profil Access TN-136'dadır; profil değişikliği iki üründe birlikte yapılır.
- Teslim edilen olayların anlamı ve projeksiyon değerleri §14'te; ajan push ve A2A teslim kuralları §17'dedir.

### 16.12 WH karar register'ı (WH-1–WH-51)

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| WH-1 | Tek teslim motoru, iki kullanım: Relay olayları ve `webhook` kanalı (event destination); ortak retry, imza, DLQ, replay, SSRF, uç sağlığı (§16.1.1) | FROZEN (ürün) | Svix, Hookdeck Outpost ve Stripe Event Destinations emsali; iki ayrı motorun bakım maliyeti |
| WH-2 | Olay türü / tüketici / uç / mesaj / deneme kavramları; `(endpoint_id, event_id)` zamandan bağımsız tekillik kısıtı (§16.1.2) | FROZEN (teknik) | Svix veri modeli; bölümlü tabloda zaman içeren tekillik olay tekilliğini zorlamaz |
| WH-3 | En az bir kez; sıra garantisi yok; "exactly-once" denmez (§16.1.3) | KANONİK DEĞİŞMEZ | Dürüst garanti dili; MD-15 |
| WH-4 | Suiss webhook profili: Standard Webhooks başlıkları, imzalanan içerik, varsayılan `v1a` Ed25519, `v1` HMAC yalnız uyumluluk; Access ile ortak (§16.2.1) | FROZEN (teknik) | Standard Webhooks v1.0.0; Access TN-136, Access E40; MD-1 |
| WH-5 | Uç başına anahtar; Ed25519 özel anahtar KMS/HSM'de; açık anahtar okunur; HMAC sırrı bir kez gösterilir (§16.2.2) | FROZEN (teknik) | Asimetrik imzada DB sızıntısı sahte imzaya yol açmaz; Standard Webhooks uç başına anahtar önerisi |
| WH-6 | Çakışmalı rotasyon, pencerede iki imza; varsayılan 24 sa (0–168 sa) (§16.2.3) | POLICY DEFAULT | Stripe: rotasyonda eski sır 24 saate kadar geçerli |
| WH-7 | Zaman damgası her denemede yeni; tüketici önerileri (ham gövde, sabit zamanlı, 5 dk tolerans, `webhook-id` ≥ 96 sa); SDK'larda doğrulayıcı (§16.2.4) | FROZEN (teknik) | Standard Webhooks'un 5 dk tekilleştirme önerisi ~76 saatlik retry penceresine yetmez |
| WH-8 | Zarf CloudEvents 1.0 structured; `id` = `webhook-id`; `seq`, `traceparent`, ortam uzantıları; kuyruklarda bağlamaya göre mod; tüketiciye iç kiracı kimliği gitmez (§16.2.5) | FROZEN (teknik) | Access TN-136 ortak zarf; CloudEvents protokol bağlamaları |
| WH-9 | İmzasız başlıklar güvenlik kararına temel olmaz (§16.2.6) | KANONİK DEĞİŞMEZ | Yalnız imzalı içerik doğrulanabilir |
| WH-10 | Deneme günlüğü: gövde özeti, imza, hedef IP, durum, süre, yanıtın ilk 8 kB'ı (§16.2.7) | FROZEN (teknik) | İmza uyuşmazlığı ve SSRF incelemesi; Svix/Stripe teslim günlüğü |
| WH-11 | Varsayılan ince olay: `type` + `id` + ilgili kimlikler; ayrıntı yetkili API'den (§16.3.1) | FROZEN (ürün) | Stripe thin event; KVKK veri minimizasyonu; sırasız olayda bayat veri |
| WH-12 | Snapshot uç bazında beyaz listeyle, uç sürümüne sabit; kişisel veri alanı açık seçimle (§16.3.2) | FROZEN (ürün) | Stripe snapshot API sürümüyle donar; API yükseltmesi webhook'u bozmamalı |
| WH-13 | `webhook` kanalında yük kiracının olay türü şeması; varsayılan kimlikler; ek alan beyaz listeyle; kiracı kodu çalıştırılmaz (§16.3.3) | FROZEN (teknik) | Dönüşüm betiği çalıştırmak kod yürütme ve kaynak tüketimi yüzeyi (Convoy/Svix JS dönüşümü reddi); MD-16 |
| WH-14 | Olay adları `noun.verb_past`, tek sözlük; katalog AsyncAPI 3.1 + JSON Schema 2020-12; sürümlü şemalar (§16.3.4) | FROZEN (teknik) | Sözleşme önce; SDK üretimi; MD-13 |
| WH-15 | Relay olay aileleri (§16.3.5) | POLICY DEFAULT | Kesin liste katalogdadır |
| WH-16 | Uç yalnız seçtiği türleri alır; boş seçim hiçbir şey; `*` açık + uyarı; uç sayısı sınırı (§16.3.6) | FROZEN (ürün) · PD (kiracı başına 20 uç; tüketici başına değer ölçümle) | Yanlışlıkla bütün olayların dış sisteme akması |
| WH-17 | Tam hedef seti ortak port arkasında: HTTPS (+ mTLS, OAuth2 CC), Kafka, NATS JetStream, RabbitMQ, SQS/SNS/EventBridge, Pub/Sub, Service Bus/Event Grid, S3 uyumlu (§16.4.1) | FROZEN (ürün) | Hookdeck Outpost ve Stripe Event Destinations hedef setleri; EventBridge'de mTLS yok |
| WH-18 | Başarı tanımı hedef türüne göre; hepsinde en az bir kez (§16.4.2) | FROZEN (teknik) | Hedeflerin farklı onay semantiği |
| WH-19 | Hedef kimlik bilgileri yalnız sır referansı; URI'de ve logda düz sır yok (§16.4.3) | KANONİK DEĞİŞMEZ | Sır hijyeni |
| WH-20 | Sıra garantisi yok; konu başına monoton `seq`; bölümlü hedefte sıra anahtarı = bölüm anahtarı (§16.4.4) | FROZEN (teknik) | Head-of-line tıkanması; Kafka bölüm sırası, Pub/Sub ordering key |
| WH-21 | Nesne deposuna süre/boyut eşiğiyle parti; CloudEvents JSON satırları; parti kimliğinden türetilen dosya adı (§16.4.5) | FROZEN (teknik) · PD (eşikler, değer ölçümle) | En az bir kez yazımda aynı partinin tek nesne üretmesi |
| WH-22 | Takvim: 10 deneme ~76 sa (hemen, 5 sn, 5 dk, 30 dk, 2 sa, 5 sa, 10 sa, 14 sa, 20 sa, 24 sa), ±%20 deterministik jitter; kiracı sınırlar içinde değiştirir; sonsuz retry yok (§16.5.1) | POLICY DEFAULT | Standard Webhooks örnek takvimi (75:35:05); Svix ~27,5 sa yetersiz kabul edildi; kiracı ayarı sınırları ⚠️ belirlenmedi |
| WH-23 | Durum kodu tablosu: 2xx başarı; 3xx izlenmez, yeniden denenmez; 410 kalıcı + uç devre dışı; 401/407/409/429/5xx retry; diğer 4xx retry yok (§16.5.2) | FROZEN (teknik) | EventBridge API destinations retry tablosu; Standard Webhooks 410 kuralı |
| WH-24 | Zaman aşımı: bağlantı 5 sn, toplam 20 sn; yanıtın en fazla 8 kB'ı (§16.5.3) | POLICY DEFAULT | Standard Webhooks 15–30 sn önerisi |
| WH-25 | 429/503'te `Retry-After` ile takvimden temkinli olan; sayaç tüketilmez, en fazla 3 kez (§16.5.4) | FROZEN (teknik) · PD (en fazla 3 kez) | EventBridge: politika ile `Retry-After`'dan temkinlisi |
| WH-26 | `webhook-delivery: abort-message` → `failed_permanent` (§16.5.5) | FROZEN (teknik) | Svix tüketici iptal başlığı |
| WH-27 | Ayrık terminal durumlar: `delivered`, `failed_permanent`, `exhausted`, `expired`, `window_exceeded`, `dead_lettered`, `cancelled` (§16.5.6) | FROZEN (teknik) | Tek "failed" durumu kurtarma kararını bilgisiz bırakır |
| WH-28 | Birikmiş kuyruk yaşı metriği; hız sınırı × pencere etkileşimi; `window_exceeded` + alarm (§16.5.7) | FROZEN (teknik) | EventBridge uyarısı: hedef hız limiti retry penceresini tüketir |
| WH-29 | Yük boyutu sert sınırı; aşan olay `dead_lettered`; ince olay hedefi < 20 kB (§16.5.8) | POLICY DEFAULT (değer ölçümle) | Standard Webhooks < 20 kB önerisi; sert sınır değeri ⚠️ belirlenmedi |
| WH-30 | Dayanıklı log: kalıcı DLQ, "kaçırılan olaylar" listesi, teslim günlüğü API'si; saklama kiracı politikası parametresi (§16.6.1) | FROZEN (ürün) | Anthropic webhooks 3 denemede düşürür, GitHub retry yapmaz; Infobip pencere kaybı |
| WH-31 | Kurtarma API'si: tek mesaj, `recover`, filtreli toplu retry, replay, pause/resume, planlanmış retry iptali (§16.6.2) | FROZEN (ürün) | Svix recover/replay, Hookdeck filtreli toplu retry ve planlanmış retry iptali |
| WH-32 | Elle gönderim ile otomatik retry etkileşimi yazılı kurallarla; aynı anda tek deneme (§16.6.3) | FROZEN (teknik) | Stripe'ta bu etkileşimin belirsizliği |
| WH-33 | Kurtarma ve replay olay kimliğini korur; kontrollü hız, kiracılar arası adalet (§16.6.4) | FROZEN (teknik) | Tüketici tekilleştirmesinin çalışması; replay dalgasının canlı trafiği bastırmaması |
| WH-34 | İşletim olayları `webhook.attempt_exhausted`, `webhook_endpoint.disabled`, `webhook_endpoint.recovered`; diğer uçlara, panele, e-postaya (§16.6.5) | FROZEN (ürün) | Svix operational webhooks |
| WH-35 | Uç devre kesicisi; açıkken olaylar bekletilir; kesici süresi sayacı tüketmez (§16.7.1) | FROZEN (teknik) | Convoy circuit breaker; çöken uça yüklenmeme |
| WH-36 | 5 gün kesintisiz hata + başlatma koşulu (24 sa içinde birden çok hata, ilk–son ≥ 12 sa); tek 2xx sıfırlar; 410 anında; 72. saatte uyarı; kapatılabilir (§16.7.2) | POLICY DEFAULT | Svix koşullu devre dışı saati; Anthropic "süreye göre, tek 2xx sıfırlar" |
| WH-37 | Devre dışı uçta olaylar "kaçırılan olaylar"a yazılır, atılmaz; geri açmada `recover` (§16.7.3) | KANONİK DEĞİŞMEZ | Tüketicinin uç arızası yüzünden veri kaybı olmamalı |
| WH-38 | Uç başına eşzamanlılık ve hız sınırı; yavaş uç diğerlerini bloklamaz; kiracı başına kuyruk yok (§16.7.4) | FROZEN (teknik) | Gürültülü komşu; kiracı başına kuyruk binlerce üretici demek |
| WH-39 | Uç sağlık paneli panelde ve portalda; yanıt vermeyen uç için otomatik bildirim (§16.7.5) | FROZEN (ürün) | Tüketicinin sorunu kendisinin görmesi destek yükünü azaltır |
| WH-40 | Kayıt kuralları: yalnız `https://` (test dahil), port 443 (+ kurulum izin listesi), userinfo yok; kayıtta DNS kontrolü yalnız erken geri bildirim (§16.8.1) | KANONİK DEĞİŞMEZ | Standard Webhooks SSRF bölümü; güvenliği zayıflatan bayrak yok; MD-14 |
| WH-41 | Bağlanma anında IP doğrulama asıl sınır; IPv4-mapped indirgeme; engelli aralıklar veri (§16.8.2) | KANONİK DEĞİŞMEZ | DNS yeniden bağlama; RFC 6890, 4291, 6052; bulut metadata uçları |
| WH-42 | Teslim işçileri iç servislere erişimsiz ayrı ağ bölümünden; isteğe bağlı çıkış proxy'si; yönlendirme izlenmez; bölge başına sabit çıkış IP'leri (§16.8.3) | FROZEN (teknik) | Smokescreen benzeri çıkış proxy'si; derinlemesine savunma |
| WH-43 | SSRF kuralları bütün dış teslim yollarında; `webhook` adımı yalnız kayıtlı uca, hesaplanan URL yok; yanıt workflow'a veri dönmez (§16.8.4) | KANONİK DEĞİŞMEZ | Veri çekme adımının SSRF yüzeyi ve deterministik tekrar oynatmayı bozması; MD-16 |
| WH-44 | Self-host'ta iç ağ hedefine teslim varsayılan kapalı; yalnız kurulum operatörünün aralık/ana makine başına izin listesiyle açılır, kiracı açamaz, her değişiklik denetim kayıtlı; bağlanma anı doğrulaması sürer; metadata ve geri döngü listeye girmez; SaaS'ta yok (§16.8.5) | FROZEN (teknik) | Kurumsal self-host iç ağ webhook ihtiyacı; SSRF korumasının kiracıya bırakılmaması |
| WH-45 | Uç ortamına bağlı ve değiştirilemez; test düzlemi aynı kurallar; yerel geliştirme CLI tüneliyle, API'de köprü URL yok; test olayı (§16.8.6) | FROZEN (teknik) | Novu `bridgeUrl` SSRF yüzeyi dersi; ortam karışması |
| WH-46 | Gömülebilir portal yetenekleri (§16.9.1) | FROZEN (ürün) | Svix App Portal, Convoy portal emsali |
| WH-47 | Portal tek tüketiciye kapsamlı kısa ömürlü jetonla; kiracı/alt kiracı markası (§16.9.2) | FROZEN (ürün) | Tüketiciler arası görünürlük sızıntısı |
| WH-48 | Uç, anahtar ve kurtarma işlemleri denetim kaydına (§16.9.3) | FROZEN (teknik) | Hassas işlem izi |
| WH-49 | Gelen sağlayıcı webhook'u: önce kalıcı makbuz sonra hızlı 2xx; sağlayıcı başına imza, ham gövde, sabit zamanlı; ortak Standard Webhooks doğrulayıcısı; kalıcı tekilleştirme (§16.10.1) | FROZEN (teknik) | Slack 3 sn yanıt sınırı; sağlayıcı yeniden gönderimleri |
| WH-50 | Uzun iş bitişi bildirimi Suiss profiliyle; giden ve gelen için aynı doğrulayıcı (§16.10.2) | FROZEN (teknik) | Tek doğrulayıcı yüzeyi |
| WH-51 | Access webhook'ları aynı profil ve doğrulayıcıyla tüketilir (§16.10.3) | FROZEN (teknik) | Access TN-136; Access E40 sürtünmesizlik |
