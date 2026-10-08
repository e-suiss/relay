## 19. Teknik Mimari

**Bu bölümün kuralları.**
- Bu bölüm çalışma zamanını, dağıtım rollerini, zorunlu bileşenleri, iş kuyruğunu, Relay'in kendi yazdığı akış kontrolü bileşenlerini, öncelik şeritlerini, kanal istemcilerini, BEAM işletim kurallarını ve bağımlılık politikasını tanımlar.
- Kararlar T-1–T-68'dir. Statüler §3'teki sözlüğe uyar. Register §19.14'tedir.
- Kiracı yalıtımı ve sır yönetimi §18'de; veri modeli, yazma yolları, saklama ve operasyon §20'dedir. Kanal davranışı (hata sınıfları, fallback, sağlayıcı yedeklemesi) §12'de, teslim durumu §14'tedir; bu bölüm bunların çalıştığı mekanizmayı verir.
- ⚠️ işaretli sayılar ölçülmemiştir; ENGINEERING ASSUMPTION olarak taşınır ve ölçümle düzeltilir.

---

### 19.1 Çalışma zamanı

**T-1 — Çalışma zamanı Elixir/OTP'dir.** Gerekçe performans değildir: bildirim teslimatında darboğaz sağlayıcıdır (FCM proje kotası, APNs akış sınırı) ve fan-out teslimi için diller arası güvenilir bir kuyruk gecikmesi karşılaştırması yoktur. Kararı veren etkenler: (1) Postgres üzerinde işlemsel iş kuyruğu (Oban) ile kaydın ve işin aynı transaction'da yazılması; (2) talep güdümlü geri basınç primitifleri (GenStage/Broadway); (3) hata yalıtımı: bir sağlayıcının yavaşlaması düğüm geneli gecikmeye dönüşmez, süreç çökmesi bağlantıları öldürmez; (4) aynı yığında üretimde çalışan bildirim ve gerçek zamanlı sistemler (Phoenix Channels). Bilinen zayıflıklar açıkça kabul edilir: TLS sonlandırma verimi, sırların bellekten silinememesi, sertifikalı FIPS modülünün olmaması, işe alım havuzunun küçüklüğü.

**T-2 — Dil kararının yeniden değerlendirme koşulları yazılıdır.** Şu koşullardan biri gerçekleşirse dil kararı yeniden açılır: (1) Relay'in workflow/bekleme bileşeni çok adımlı, telafili (saga) yürütme yapmak zorunda kalırsa (bu, Relay'in dayanıklı yürütme motoru olmadığı kuralıyla da çelişir; §7'deki Executor sınırı); (2) Postgres üstü zamanlayıcı ve bekleme tablosu ölçümde hedef ölçeğe yetmezse; (3) sertifikalı FIPS kriptografisi düzenleyici zorunluluk olursa. Risk şu tasarımla karşılanır: bekleme noktası çalışan bir iş değil bir satırdır (T-24); iş etkisi telafisi Relay'in değildir.

---

### 19.2 Tek uygulama ve roller

**T-3 — Relay tek uygulama, tek imajdır; düğüm rolü yapılandırmayla seçilir.**

| Rol | Görev | Not |
|---|---|---|
| `api` | HTTP API, CloudEvents girişi, gelen sağlayıcı webhook'ları, panel arka ucu, tercih merkezi sayfaları | Kabul kontrolü burada (T-35) |
| `worker` | Kuyruk işleri: planlama, render, teslim, retry, digest, zamanlayıcılar, bekleme noktası süresi, mutabakat, bakım | Tekil görevler DB liderliğiyle (T-12) |
| `socket` | Realtime bağlantılar: WebSocket (Phoenix Channels), SSE, long-poll | Kalıcılık Postgres'te (§15) |

Küçük kurulumda üç rol aynı düğümde çalışır. Rol ayrımı ölçek ve arıza alanı içindir; kod yolu aynıdır. SaaS bölgeleri ve self-host aynı paketle kurulur; "yalnız bulut" kod yolu ya da lisans bayrağı yoktur.

**T-4 — Realtime Relay'in içindedir; ayrı realtime sunucusu yoktur.** WebSocket ve SSE eşit sınıf taşımalardır ve aynı olay akışını taşır; son yedek long-poll/polling'dir. Doğruluk Postgres kaydındadır; taşıma yalnız sinyal ve teslim katmanıdır. Ayrı realtime sunucusu (Centrifugo vb.) kurulmaz; WebTransport kapsam dışıdır. Phoenix Presence kullanılmaz (büyük kümelerde ve dağıtımlar arasında bilinen yakınsama ve bellek sorunları). Akış modeli ve kurtarma kuralları §15'tedir.

**T-5 — Dağıtım ve kapatma kuralları.**
1. Konteyner giriş noktası exec biçimindedir (kabuk biçimi sinyali iletmez).
2. Kapatma sırası: hazırlık (readiness) sinyalini düşür → yük dengeleyicinin düğümü çıkarmasını bekle → kuyruk işlerini ve bağlantıları boşalt. Orkestratörün kapatma süresi, kuyruğun kapatma payı + en uzun realtime boşaltma süresinden uzundur; bu ilişki dağıtım testiyle korunur. Kısa kapatma süresi zombi iş ve "gizemli mükerrer"in en sık nedenidir.
3. Şema göçleri ayrı bir adımda çalışır (init/release komutu); düğüm açılışında göç yapılmaz (§20.9).
4. Realtime bağlantıları yeniden bağlanma fırtınası üretmeyecek biçimde boşaltılır: istemci SDK'ları jitter'lı üstel yeniden bağlanma uygular, dağıtım bir seferde sınırlı sayıda düğümü yeniler.

**T-6 — Ölçekleme kuyruk gecikmesine göre yapılır, CPU yüzdesine göre yapılmaz.** Otomatik ölçekleme sinyali şerit başına en eski bekleyen işin yaşı ve kuyruk derinliğidir. BEAM'in boşta bekleme davranışı işletim sistemi CPU yüzdesini birkaç kat abartır ⚠️. Sağlayıcı kapasitesi doğrulanmadan yatay ölçekleme yapılmaz; retry fırtınasında ölçeklemek durumu kötüleştirir (§20.8).

---

### 19.3 Zorunlu bileşenler

**T-7 — Zorunlu bileşenler PostgreSQL ve Valkey'dir.** Diğer her şey isteğe bağlıdır.

| Bileşen | Statü | Rol |
|---|---|---|
| PostgreSQL | Zorunlu | Bütün asıl kayıtlar, iş kuyruğu, defterler, denetim kaydı, yedek hız limitleyici |
| Valkey (Redis tam uyumlu) | Zorunlu | Düğümler arası sinyal, hız limiti ve frekans sayaçları, kısa ömürlü kayıtlar |
| NATS, Kafka vb. | İsteğe bağlı | Yalnız olay kaynağı (ingest) ya da teslim hedefi adaptörü |
| Analitik veritabanı (ClickHouse vb.) | İsteğe bağlı | Yalnız teslim hedefi (§20.6) |
| S3 uyumlu depo | İsteğe bağlı | Soğuk arşiv, toplu dışa aktarım, teslim hedefi |

Valkey referans uygulamadır; Redis tam uyumludur. Dragonfly test edilmez. Valkey lisans incelemesi gerektirmeyen (BSD-3) ve protokol özdeş seçenektir.

**T-8 — PostgreSQL sürümü 18 ve üstüdür.** Gerekçe: bölümlenmiş tablolarda sorgu başına kilit sayısını taşıyan fast-path kilitleme düzeltmesi. PG18'e geçişin genel OLTP veriminde gerileme getirebileceği bilinir ⚠️; kendi iş yükü karışımı ölçülür. Yeni ana sürüm beta iken dağıtılmaz.

**T-9 — Valkey kuralları.**
1. Valkey asla asıl kayıt tutmaz. Valkey'in tamamen kaybı veri kaybı değildir; yalnız gecikme ve kısa süreli kaba sınırlama üretir.
2. Sinyaller yalnız "yeni bir şey var" + sıra numarası taşır; veri her zaman Postgres'ten çekilir. Kaçırılan sinyal Postgres cursor'uyla telafi edilir.
3. Valkey erişilemezse sinyaller kısa aralıklı yoklamaya, hız limiti ve sayaçlar Postgres yedek limitleyicisine düşer. "Limitsiz" duruma hiçbir koşulda düşülmez.
4. Hız limiti ve sayaçlar için tek davranış test seti hem Valkey hem Postgres arka ucunda koşar; iki arka uç aynı kararları üretmek zorundadır.
5. Arka uç geçiş penceresinde iki sayaç birlikte kontrol edilir; daha katı olan uygulanır.
6. Valkey örneği tahliye etmeyen (`noeviction`) yapılandırmayla çalışır; önbellek amaçlı kullanım aynı örnekte sinyal ve sayaçlarla karışmaz.
7. Valkey anahtarları kiracı + ortam önekini taşır (§18 TN-17) ve süre (TTL) ile yaşar.

**T-10 — Düğümler arası haberleşme Valkey pub/sub iledir; Postgres LISTEN/NOTIFY kullanılmaz.** Gerekçe: LISTEN/NOTIFY dayanıklı değildir, işlem havuzlayıcıdan geçmez, commit'leri serileştiren global kilit alır ve kanal adı türetme yüzeyi açar. İş kuyruğunun düğümler arası bildirimleri de Valkey üzerinden, Relay'in kendi bildiricisiyle taşınır (T-55). Pub/sub kaybı gecikmeye mal olur, iş kaybına değil: "kaçırılan bir bildirimin iş kaybettirdiği her tasarım bozuktur".

**T-11 — Tek saat otoritesi.** Hız limiti, kota ve süre kararlarında zaman, kararı veren arka ucun saatinden okunur (Valkey `TIME`, Postgres `clock_timestamp()`); uygulama düğümünün duvar saati karara girmez. GCRA'da `tat = max(saklanan, now)` geri giden saati güvenli tarafa çeker. Süre ölçümleri (devre kesici, backoff, zaman aşımı) monotonik saatle yapılır.

**T-12 — Lider ve tekil sorumluluk veritabanı tabanlıdır.** Küme genelinde tek çalışması gereken görevler (zamanlayıcı lideri, partition bakımı, DRR dağıtıcısı, mutabakat tetikleyicisi) Postgres tabanlı liderlik (advisory lock / iş kuyruğunun peer mekanizması) ile seçilir. Horde, `:global` tabanlı tekil süreçler ve küme kütüphanesine bağlı liderlik kullanılmaz. Tekil görevin durumu veritabanındadır; lider değişince yeni lider kaldığı yerden devam eder. Liderlik tablosunun bütünlüğü (birincil anahtarın varlığı) testle korunur; lidersiz kalma alarm üretir.

---

### 19.4 Erlang distribution

**T-13 — Erlang distribution isteğe bağlıdır ve koordinasyon için kullanılmaz.**
1. Varsayılan: distribution kapalıdır. Canlı düğüme teşhis (uzak kabuk, `rpc`) konteyner/pod'a komut çalıştırma yetkisiyle, düğümün kendi içinden yapılır; bunun için ağ üzerinden distribution gerekmez.
2. Düğümler arası koordinasyon distribution'a dayanmaz: sinyal Valkey'den (T-10; iş kuyruğu bildirimi dahil, distribution tabanlı bildirici kullanılmaz, T-55), liderlik Postgres'ten (T-12), durum Postgres'ten gelir. Distribution kapalıyken bütün özellikler çalışır.
3. Distribution açılırsa (hangi arayüzde olursa olsun) yalnız TLS + karşılıklı sertifika kimliğiyle açılır: çerez sır deposundan gelir (imaja ya da derleme anına gömülmez), dinleme portları sabitlenir ve güvenlik duvarıyla sınırlanır, EPMD iç adrese kısıtlanır, ayrı iç ağ kullanılır. Bir Erlang kümesi uygulama güven katmanlarını aşmaz.

---

### 19.5 İş kuyruğu

**T-14 — Çekirdek kuyruk açık kaynak Oban'dır; Oban Pro kullanılmaz.** Ne çekirdekte ne SaaS'ta ticari eklenti kullanılır. Oban'dan alınanlar:

| Yetenek | Kullanım |
|---|---|
| İşlemsel insert | İş, kayıtla aynı transaction'da yazılır; ayrı outbox gerekmez (§20.2) |
| Retry, backoff, `{:snooze, n}`, `{:cancel, reason}` | Backoff fonksiyonu Relay'indir (T-26) |
| İleri tarihli çalıştırma, cron | Zamanlanmış gönderim ve bakım görevleri |
| Kuyruk ayrımı, duraklatma/sürdürme | Şerit × kanal kuyrukları (T-32), kill switch (§18) |
| İş benzersizliği | Yalnız ucuz ön filtre (T-16) |
| `suspended` durumu | Dış eylemle sürdürülen işler |
| `discarded` | DLQ'nun ham katmanı (T-29) |
| Öncelik 0–9 | Yalnız şerit içi ince ayar (T-36) |
| Lifeline, peer liderliği, telemetri | Zombi iş kurtarma, tekil görevler, gözlem |

Ürün belgelerinde ticari kuyruk eklentisinin özelliklerine atıf yapılmaz; Relay ile aynı adı taşıyan eklenti özelliği ad karışıklığı yaratır.

**T-15 — İş kuralları.**
1. İş argümanı yalnız kimlik taşır (ör. `notification_id`, `delivery_id`, `tenant_id`); içerik, adres ve kişisel veri iş tablosuna yazılmaz. Gerekçe: kuyruk tablosu imha yükümlülüğüne girmez, şişmez.
2. İş yalnız ilgili kaydı yazan transaction'ın içinde eklenir; transaction dışında iş eklenmez.
3. Hiçbir iş bir saati aşmaz. Büyük işler parçalanır (T-23). Uzun beklemeler (zamanlanmış gönderim, digest penceresi, bekleme noktası son tarihi, eskalasyon kademesi) bir satır + zamanlayıcıdır; kuyruk slotu ve süreç tutmaz.
4. Zombi iş kurtarma eşiği (Lifeline) iş süresi sınırının üstündedir; kurtarılan işin mükerrer etkisi teslim defteri tekilliğiyle (T-16) zararsızdır. Elle zombi kurtarma, yaşayan düğüm filtresi olmadan çalıştırılmaz.
5. İşin içindeki ilk adım kill switch ve iptal kontrolüdür (§18 TN-40). İptal kuyruk tablosunda değil teslim kaydında işaretlenir; iş çalışırken kontrol eder ve işlem yapmadan biter.
6. Dış çağrı (sağlayıcı, webhook, KMS) veritabanı transaction'ı içinde yapılmaz; durum güncellemesi çağrıdan sonra ayrı ve kısa bir transaction'dır.
7. İş tablosu kayıt değil geçici çalışma listesidir; kalıcı iz teslim defteri ve denetim kaydıdır. İşin sonucu kalıcı kayda yazıldıktan sonra iş satırı temizlenebilir; bu, fiziksel silme yasağının tek istisnasıdır ve kayıt tablolarına uygulanmaz (§20.2 OP-12). Uyum kanıtı iş tablosunda değil, temizlenmeyen kayıtlarda tutulur.

**T-16 — Kesin tekillik veritabanı kısıtındadır; kuyruk benzersizliği bir optimizasyondur.** Oban açık kaynak sürümünün benzersizlik özelliği veritabanı kısıtına dayanmaz ve yarışa açıktır; test modunda yarış üretilemez. Garanti Relay'in kendi tablolarındaki `UNIQUE` kısıtlarıdır: `(tenant_id, environment, dedup_key)`, teslim defterinde `(notification_id, recipient, channel)`, digest ve bekleme noktası tekillik indeksleri. Dedup katmanları §10 ve §20.1'dedir. Teslimat yolunda olasılıksal yapı (Bloom filtresi, HyperLogLog) kullanılmaz: yanlış pozitif kaybolan bildirim demektir.

**T-17 — Kuyruk işletim kuralları.** Oban tabloları uygulama tablolarından ayrı şemadadır (vakum, izleme ve yetki ayrımı). Oban göç sürümü açıkça sabitlenir ve her sürüm farkı okunur; kuyruk şeması göçü uygulama kodundan önce çalışır. Kuyruğun düğümler arası bildirimleri Relay'in kendi Valkey bildiricisiyle taşınır (T-10, T-55); bildirim kanalı koptuğunda kuyruk yoklamaya düşer ve bu durum alarm üretir. Kuyruk kütüphanesinin varsayılan bildiricisi (Postgres LISTEN/NOTIFY) ve Erlang `:pg` tabanlı bildirici kullanılmaz. Operatör paneli Oban Web (Apache-2.0) + oban_met'tir; büyük tablolarda bu araçların sayım sorgularının veritabanı yükü izlenir ve sınırlanır.

**T-55 — İş kuyruğunun düğümler arası bildiricisi Relay'in kendi Valkey bildiricisidir.** Bildirici Oban'ın bildirici (notifier) arayüzünü uygulayan, Relay'in kendi Apache-2.0 bileşenidir (T-18) ve Valkey pub/sub kullanır. Valkey erişilemezse Oban yoklamaya düşer; bildirim kaybı yalnız gecikmedir, iş kaybı değildir (T-10). Postgres LISTEN/NOTIFY bildiricisi (T-10) ve Erlang `:pg` bildiricisi (distribution varsayılan kapalı, T-13) kullanılmaz. Bildirici, Valkey kesintisi ve yeniden bağlanma senaryolarında kural testleriyle doğrulanır.

---

### 19.6 Relay'in kendi bileşenleri

**T-18 — Açık kaynak kuyruğun vermediği yetenekler Relay'in kendi Apache-2.0 kodudur ve kural testleriyle doğrulanır.** Bileşenler: küme geneli hız limiti, kiracı adaleti (DRR), global eşzamanlılık sınırı, batch/fan-out takibi, bekleme noktası tablosu, devre kesici, retry/DLQ politikası, Valkey kuyruk bildiricisi (T-55). Her bileşen yarış koşulları, adalet ve sınır davranışı için kural testleriyle doğrulanır; hız limiti testleri bilinen limitleyici hatalarından (kesirli dolum kaybı, başlatma yarışı, `retry-after` hesabı, CAS yarışı) türetilir. Bu bileşenler çekirdek kapsamdır; yapım sırasında erken aşamaya yerleşir.

#### 19.6.1 Hız limiti

**T-19 — Hız limiti algoritması kullanıma göre seçilir; varsayılan GCRA'dır.**

| Kullanım | Algoritma | Gerekçe |
|---|---|---|
| Giden kanal ve sağlayıcı limitleri | GCRA (tek durum: teorik varış zamanı) | Tam doğruluk, anahtar başına sabit bellek, `τ` ile ayarlanabilir burst, kesin `retry_after` → işin snooze süresi |
| Uzun pencereli kaba kotalar (günlük gönderim, aylık sayaç, hesap günlük hacmi, APNs jeton yenileme) | Sabit pencere | Basit; uzun pencerede sınır etkisi önemsiz |
| Orta pencereli kaba kotalar | Kayan pencere sayacı, `L_eff = 0,90·L` | Hata eşiğin üstüne izin verme yönünde asimetrik; hedef aşağı çekilir |
| Küçük `L`'li alıcı başına kapaklar (ör. aynı alıcıya saatte en fazla N) | Kayan pencere kaydı | Küçük `L`'de bellek sorunu yok, kesin |

Sabit pencere kısa pencereli sağlayıcı limitlerinde kullanılmaz (pencere sınırında çift patlama). Sayım birimi kanala göre değişir: e-postada alıcı, SMS'te segment, WhatsApp mesajlaşma limitinde benzersiz alıcı (24 saatlik üyelik kümesi; yaklaşık sayaç kullanılmaz), push'ta mesaj. Pencere başlangıcı anahtara göre kaydırılır (`w = floor((t + hash(key) mod W) / W)`); bütün kiracılar aynı sınırda serbest kalıp tepe üretmez.

**T-20 — Hız limiti durumu Valkey'dedir, yedeği Postgres'tir; Relay'in limiti sağlayıcınınkinden katıdır.**
1. Birincil arka uç Valkey'dir (tek atomik betik, Valkey saati). Yedek arka uç Postgres'tir: tek `INSERT … ON CONFLICT DO UPDATE … WHERE … RETURNING` ifadesiyle kilitsiz GCRA; boş `RETURNING` reddir.
2. Valkey erişilemezse yedek limitleyiciye otomatik düşülür; "limitsiz" duruma düşülmez (T-9).
3. Sağlayıcının `Retry-After` değeri her zaman uygulanır; üstüne yüzde 20'ye kadar jitter eklenir.
4. Relay'in limiti sağlayıcının yayımlanmış limitinden kasten katıdır. Gerekçe: bazı sağlayıcılar aşımda mesajı sessizce düşürür ya da saatlerce kendi kuyruğunda tutup sonra başarısız sayar; bu sürede sistem "gönderildi" sanır.
5. Burst dostu kanallarda düğümler merkezden kredi bloğu kiralayabilir (global aşım ≤ (N−1)·k); katı saniye limitli kanallarda (SMS) kredi kiralanmaz, her karar merkezde verilir.
6. Hız limiti anahtarı kanal × sağlayıcı hesabı × kiracı ve ilgili hedef (cihaz, numara) bileşenlerinden oluşur; global, anahtarsız limitleyici kullanılmaz.

#### 19.6.2 Kiracı adaleti

**T-21 — Kiracı adaleti şerit içinde DRR ile sağlanır; `security` şeridi beklemez.**
1. Hedef max-min adalettir; FIFO reddedilir (tek bir kampanya paylaşılan kaynağı sınırsız işgal edip parola sıfırlamasını arkada bırakır).
2. Toplu şeritlerde işler önce kiracı bekleme tablosuna yazılır; küme genelinde tekil dağıtıcı (T-12) her döngüde aktif kiracıların açığını (deficit) `ağırlık × kuantum` kadar artırır ve o kadar işi kuyruğa taşır. Kuantum en büyük iş biriminden küçük olamaz. Boşalan kiracının açığı sıfırlanır (birikim yapılamaz). Ağırlıklar kiracı yapılandırmasının verisidir. Dağıtıcı durumu veritabanındadır; lider değişince en fazla bir döngülük adalet kaybı kabul edilir.
3. İptal, bekleme tablosundaki işi `cancelled` olarak işaretlemektir; kuyruğa hiç girmez.
4. `security` şeridinde kiracı bekleme tablosu yoktur; iş doğrudan kuyruğa girer. `security` şeridinin yalıtımı fiziksel ayrımla sağlanır (T-32).
5. Açlığa karşı fiziksel ayrım (ayrı kuyruk, ayrı eşzamanlılık bütçesi) tercih edilir; öncelik yaşlandırması kullanılmaz.

**T-22 — Global eşzamanlılık sınırı küme genelidir.** Kiracı × kanal, sağlayıcı hesabı ve kiracı başına eşzamanlı bekleme noktası için uçuştaki iş sayısı küme genelinde sınırlanır (Valkey sayaçları, Postgres yedekli; T-9). Düğüm başına sınır tek başına kullanılmaz (N düğümde limiti N katına çıkarır). Sınır aşımında iş hata değil snooze alır.

#### 19.6.3 Batch, fan-out ve bekleme

**T-23 — Fan-out dilimlenir, kontrol noktalıdır ve takip edilir.**
1. Alıcı başına iş üretilmez. Büyük kitle dilimlere bölünür (dilim 5.000 alıcı, alt-parti 200 ⚠️); dilim işi yalnız keyset aralığı taşır (OFFSET yok), alt-parti sonrası kontrol noktası yazılır, retry kontrol noktasından devam eder.
2. Alıcı sayısına göre model değişir: küçük kitle normal yol; orta kitle ayrı toplu kuyruk, düşük öncelik, hız şekillendirme; çok büyük kitle kampanya modu (zamanlanmış, oran bütçeli, ilerleme takipli, iptal edilebilir) ⚠️ eşikler ölçümle.
3. Kampanya ilerlemesi ayrı tabloda tutulur (dilim başına bir güncelleme); durumlar `pending | running | paused | completed | partial | cancelled`. Kapanış, bütün dilimler terminal olduğunda (bir kısmı başarısız olsa da) çalışır; kısmi başarı `partial` olarak raporlanır ve kiracıya olay gider.
4. Kampanya iptali çalışan dilimin her alt-partiden önce durumu kontrol etmesiyle uygulanır.
5. "Hazırla, sonra tetikle": snapshot aşamasında alıcı listesi, render ve dedup anahtarları üretilir; tetikte yalnız gönderim yapılır (§10'daki kampanya kuralları).
6. Ölçek dürüstlüğü: 10M push gibi bir gönderim sağlayıcı kotasıyla sınırlıdır ve dakikalar sürer ⚠️; "anında gönderim" bu ölçekte iddia edilmez, ilerleme arayüzü gösterilir.

**T-24 — Bekleme noktası bir satır ve bir zamanlayıcıdır.** Bekleme noktası tablosu Relay'in kendi bileşenidir: bekleme noktası kuyruk slotu, süreç ya da çalışan iş tutmaz. Son tarih ilk park anında kalıcı yazılır; sonsuz bekleme yoktur. Eşleme `(tenant, environment, olay türü, korelasyon anahtarı)` üzerinde tek indeksle yapılır; erken gelen yanıt alıcının kalıcı posta kutusunda tamponlanır. Toplam süre ve bekleyen tarafın heartbeat'i iki ayrı zamanlayıcıdır. Kanal yükseltmesi ve eskalasyon aynı zamanlayıcı mekanizmasını kullanır. Bekleme değişmezleri (yanıtlayan ≠ bekleyen, süresi geçmiş bekleme çözülemez, çözülmüş bekleme değişmez) veritabanı kısıtıdır. Davranış kuralları §10 ve §17'dedir.

#### 19.6.4 Devre kesici

**T-25 — Devre kesici iki seviyelidir ve Relay'in kendi küçük modülüdür.**
1. Seviyeler: `{tenant, provider}` (kimlik ve yapılandırma hataları; ör. bir kiracının süresi dolmuş anahtarı) ve `{provider}` (bütün kiracıların katkısıyla taşıma/5xx/zaman aşımı oranı). Yalnız sağlayıcı anahtarlı kesici reddedilir: tek kiracının bozuk kimliği herkesi keser.
2. Durumlar `closed → open → half_open → closed | open`. Gerçek half-open: yalnız N eşzamanlı deneme isteği geçer; ardışık başarılarla kapanır.
3. Açılma koşulu kayan pencerede oran eşiğidir; asgari işlem hacminin altında oran hesaplanmaz. Hata sınıfına göre ağırlık uygulanır: kimlik hatası hızlı açar, 429 yavaş açar.
4. Kesici yalnız taşıma hatası, 5xx, zaman aşımı ve kimlik hatasıyla açılır. 4xx uygulama reddi (geçersiz token, geçersiz numara, APNs 410) açmaz: bunlar sağlayıcının sağlıklı olduğunun kanıtıdır; kötü bir alıcı listesi sağlıklı kanalı kapatmamalıdır.
5. Gecikme de açılma sinyalidir: yalnız hata oranına bakan kesici yavaş sağlayıcıda işe yaramaz; p99 gecikme eşiği tanımlanır.
6. Açık kalma süresine jitter eklenir (bütün düğümler aynı anda half-open'a geçip toplu deneme üretmez).
7. Başlangıç parametreleri (POLICY DEFAULT, kanal tablosunda veri): pencere 30 sn, asgari hacim 20, oran 0,5, açık kalma 30 sn + %30'a kadar jitter, deneme 3, kapanma için 3 ardışık başarı. Kanal ve şerit başına parametreler kanal tablosundadır.
8. İtibar devresi (bounce/şikâyet oranı) ayrı bir devredir ve kendiliğinden kapanmaz (§12'deki itibar kuralları).
9. Sıcak yolda kesici durumu düğüm içi atomik sayaçlardan okunur; merkezi bir sürece senkron çağrı yapılmaz. Kesici açılınca aktif-pasif modda yedek sağlayıcıya geçilir (§12'deki sağlayıcı yedekleme kuralları).

#### 19.6.5 Retry ve DLQ

**T-26 — Tek retry otoritesi iş kuyruğudur.** HTTP istemcisinin ve adaptörün kendi retry'ı kapalıdır; müşterinin tekrar POST'u idempotency ile yeni iş üretmez. Gerekçe: katman başına retry çarpımsal büyür. Backoff "tam jitter"dir: `sleep = random(0, min(cap, base·2^a))`; beklenen bekleme yarıya indiği için taban iki katı alınır. Kanal ve hata türü başına `base`, `cap` ve `max_attempts` kanal tablosunda veridir. `max_attempts`'in üst sınırı mesajın yararlılık ömrüdür (`expires_at`); süresi geçen mesaj denenmez, `expired` olur. Yeniden denenen işin önceliği düşürülür (sağlıklı yeni işler hasta işlerin arkasına itilmez). Hata sınıfı tablosu (`transient`, `permanent_target`, `permanent_content`, `policy`, `quota`, `auth`, `sender_config`, `unknown`) retry, fallback ve adres devre dışı bırakmayı belirler (§12).

**T-27 — Retry bütçesi vardır.** Kanal başına kayan 60 saniyelik pencerede retry/toplam oranı %10'u aşarsa (asgari taban sayısı korunarak) yeni retry'lar ertelenir ve `budget_denied` sınıfıyla DLQ'ya gider. Gerekçe: retry fırtınası sağlayıcı kesintisini uzatır.

**T-28 — Belirsiz sonuç kör retry edilmez.** Bağlantı hiç kurulamadıysa retry güvenlidir. İstek gitti ama yanıt yoksa: sağlayıcı idempotency anahtarını destekliyorsa aynı anahtarla retry; desteklemiyorsa kanal başına beyan edilmiş politika uygulanır (`wait_and_query`, `retry_accepting_duplicate_risk`, `no_auto_retry`). Ücretli kanallarda zaman aşımı sonrası en fazla bir retry yapılır ve teslim `delivery_uncertain` işaretlenir; kesin durum sağlayıcı olayından ya da durum sorgusundan gelir. Sağlayıcı idempotency anahtarı mantıksal gönderim boyunca sabittir.

**T-29 — DLQ sınıflandırılmış, sorgulanabilir ve yeniden oynatılabilir bir tablodur.** Kuyruğun `discarded` durumu ham katmandır; yeterli değildir (yarı yapısal neden, toplu sınıflandırma yok, kuyruk satırı temizlenebildiği için geçmiş kaybolur; §20 OP-12). DLQ tablosu kayıt tablosudur ve temizlenmez. DLQ tablosu kiracı, kanal, sağlayıcı, hata sınıfı (`permanent`, `quality_alarm`, `exhausted`, `budget_denied`), sağlayıcı kodu, deneme sayısı ve zamanları tutar; kişisel veri yerine alıcı kör indeksini taşır. Yeniden oynatma kuralları:
1. Token/adres geçersizleştiren hatalar asla oynatılmaz; `permanent` yalnız neden düzeltildiyse; `quality_alarm` yalnız insan onayıyla; `exhausted` ve `budget_denied` oynatılabilir.
2. Yararlılık ömrü geçmiş kayıt oynatılmaz; `expired` kapatılır.
3. Oynatma kendi düşük öncelikli kuyruğunda, hız sınırlı çalışır.
4. Oynatma derinliği en fazla 1'dir (oynatılmış kaydın oynatılması yok).
5. Oynatma kopyalama değil yeniden üretmedir; yeni idempotency anahtarı orijinal anahtardan türetilir.
6. Sağlayıcı devresi kapanınca o sağlayıcının yakın zamandaki `exhausted` kayıtları otomatik oynatılabilir (POLICY DEFAULT: son 30 dk).
Giden webhook DLQ'su ve "kaçırılan olaylar" listesi §16'dadır; aynı tabloyu ve kuralları kullanır.

#### 19.6.6 Jitter

**T-30 — Jitter her yerde deterministiktir.** Zamanlama yayılımı, sessiz saat bitişi serbest bırakması, tekrar kuralı tetiklemesi ve retry jitter'ı kararlı bir özetle (`phash2` sınıfı) alıcı ve zaman anahtarından türetilir; `rand` kullanılmaz. Gerekçe: retry ve tekrar oynatma aynı ana düşer, deney bölmesi bozulmaz, dilim sıralaması kararlıdır. Backoff'taki "tam jitter" de deneme kimliğinden türetilen deterministik değerle hesaplanır.

---

### 19.7 Öncelik şeritleri ve yük atma

**T-31 — Dört şerit vardır; şerit yalnız mesaj sınıfından türer.**

| Şerit | Sınıflar | Hedef gecikme | Kayıp | Yük atmada |
|---|---|---|---|---|
| L0 | `security` | En düşük; değerler §20.6 SLO tablosunda | Kaybedilemez; yalnız `expires_at` ile eskir | Asla atılmaz |
| L1 | `transactional`, `action_required` | Düşük | Kaybedilemez | Son çare olarak ertelenir |
| L2 | `operational`, `system`, `social` | Orta | Ertelenebilir | İkinci sırada; digest penceresi uzatılır, ertelenir |
| L3 | `marketing` | Yüksek | Ertelenebilir | İlk sırada; kampanya duraklatılır (atılmaz) |

Mesaj hiçbir istek alanıyla başka şeride geçemez; `priority: low|normal|high` yalnız şerit içinde ince ayardır ve sınıf tavanını aşamaz (§12'deki öncelik kuralları). L1/L2 ataması, `action_required`'ın ertelenemez ve digest'lenemez olmasından ve `social`'ın digest'lenebilir olmasından türetilmiştir. L0 yalnız `security`'dir; böylece yük atmada "asla" kuralı en dar kümede uygulanır (T-34).

**T-32 — Şerit ayrımı fizikseldir.** Yazılımsal öncelik yetmez: öncelik sıraya girişi belirler, kesip almayı değil; eşzamanlılık, bağlantılar, kota ve arıza alanı paylaşılır. Bu yüzden:
1. Şerit × kanal başına ayrı kuyruk ve ayrı eşzamanlılık bütçesi.
2. Kritik (L0+L1) ve toplu (L2+L3) için ayrı HTTP istemci örnekleri ve bağlantı havuzları; aynı sağlayıcıya iki ayrı havuz.
3. OLTP (L0/L1) ve toplu yazma (fan-out, L2/L3) için aynı veritabanında ayrı bağlantı havuzları; dev fan-out OTP insert'ini bekletemez.
4. Ölçek büyüdüğünde kritik ve toplu şeritler ayrı düğüm havuzlarında çalışabilir (rol yapılandırması; T-3). Eşik ölçümle konur.
5. Fan-out insert'leri küçük parçalar hâlinde yapılır; tek dev transaction yoktur.

**T-33 — Paylaşılan sağlayıcı kotasında kümülatif şerit tavanı uygulanır.** Aynı sağlayıcı limit anahtarının kullanım oranı okunur; şeride göre eşik vardır. POLICY DEFAULT: L3 %60, L2 %80, L1 %95, L0 %100. Eşiğin üstündeki iş reddedilmez; GCRA'nın `retry_after` süresi kadar snooze alır. Aynı formül kiracının kendi sağlayıcı hesabında ve paylaşılan hesapta geçerlidir (§18 TN-53).

**T-34 — Yük atma kuyruk gecikmesiyle tetiklenir; sıra L3 → L2 → L1'dir, L0 asla.**
1. Tetik kuyruk derinliği değil kuyruk gecikmesidir (işin başlarken beklediği süre). Gecikme bir hedefi bir aralık boyunca sürekli aşarsa atma başlar (CoDel kontrol yasası). Şerit parametreleri POLICY DEFAULT'tur (başlangıç: L0 500 ms/5 sn, L1 5 sn/30 sn, L2 60 sn/5 dk, L3 30 dk/30 dk ⚠️).
2. L3'te kampanyalar duraklatılır; kiracının ödediği kampanya atılmaz, kuyruk korunur. L2'de digest pencereleri uzatılır ve işler ertelenir. L1 son çare olarak ertelenir. L0 yük atmayla hiçbir zaman düşürülmez; yalnız `expires_at` geçince eskir.
3. L0'da eskimiş iş başladığında kendini `expired` olarak kapatır; etkin davranış "TTL + FIFO"dur. L1 FIFO + TTL ile ertelenir.
4. Her atma ya da erteleme kararı `rule_id` ile kaydedilir.

**T-35 — Kabul kontrolü girişte yapılır; zincirde sınırsız tampon yoktur.**
1. İşin hiç yaratılmadığı yer atmanın en ucuz yeridir. Aşırı yükte API, L2/L3 istekleri için `429` + `Retry-After`; ilgili kanal devresi açıkken `marketing` istekleri için `503` + `Retry-After` döner. `RateLimit` başlıkları yalnız ek bilgidir.
2. Hedef gecikmeyi kesin ihlal edecek iş kuyruğa alınmaz: `L_max = μ · W_max` üstü reddedilir. Kuyruğa almak burada yalan söylemektir.
3. Kapasite planı hedef kullanım oranı 0,7'dir; sürdürülebilir kullanımda %80'in üstü hedeflenmez.
4. Geri basınç zincirinin her halkası sınırlıdır (bellek içi tamponlar, HTTP havuz bekleme kuyrukları, adaptör semaforları). Tek kasıtlı sınırsız tampon kalıcı kuyruk tablosudur; derinliği ve en eski iş yaşı izlenir ve alarm üretir.
5. Giriş hızı kuyruk derinliğine göre uyarlanır (AIMD): yüksek su çizgisinin üstünde oran azaltılır, alçak su çizgisinin altında artırılır.
6. Veritabanı havuzu doyarsa API `503` döner; kabul edilip kuyruğa girmeyen mesaj hiçbir koşulda oluşmaz (kayıt ve iş aynı transaction'da).

**T-36 — Kuyruk önceliği (0–9) şerit içi ince ayardır.** Harita: 0 şeridin en acil ilk denemesi; 1 normal ilk deneme; 2 ikinci-üçüncü deneme; 3 vakti gelen zamanlanmış iş; 4 digest ateşlemesi; 5 kampanya ilk dilimi; 6 sonraki dilimler; 7 yeniden denenen toplu dilim. DLQ oynatma ve bakım işleri katı öncelikte aç kalacağı için ayrı kuyruklardadır.

---

### 19.8 Kanal istemcileri

**T-37 — APNs ve FCM istemcisi Finch/Mint (HTTP/2) üzerinde Relay'in kendi ince istemcisidir.** Gerekçe: bakımlı ve eksiksiz bir APNs kütüphanesi yoktur; kendi istemci token yaşam döngüsüne, kabul kontrolüne ve test vektörlerine bağlanabilir.
1. **Kabul kontrolü:** semafor + sınırlı bekleme kuyruğu. Uçuştaki istek sayısı taşıma kapasitesini (bağlantı sayısı × sunucunun ilan ettiği eşzamanlı akış) asla aşmaz; soğuk başlangıç için pay bırakılır.
2. **Soğuk bağlantı:** sunucunun SETTINGS çerçevesi beklenir; ilan gelmeden akış açılmaz. `too_many_concurrent_requests` ve "bağlantı hazır değil" geçici hatadır.
3. **Kiracı yalıtımı:** kiracı (Apple takımı / Firebase projesi) başına ayrı bağlantı ve kimlik bilgisi. Farklı takımların ya da ortamların (sandbox/production) token'ları aynı bağlantıda taşınmaz; havuz `(ortam × anahtar)` başınadır. Aynı takımın birden çok topic'i tek bağlantıyı paylaşabilir.
4. **Bağlantı yaşam döngüsü:** tembel açılır; yoğun kiracıda bağlantı sayısı artar; boşta kapatma eşiği cömerttir (15–30 dk; hızlı bağlan-kapat sağlayıcıca kötüye kullanım sayılabilir); bağlantı yaşı 30–60 dk + jitter ile yenilenir; ping ile ölü bağlantı tespit edilir; GOAWAY işlenir.
5. **Kapsam:** bütün `apns-push-type` değerleri, broadcast push, Live Activity push-to-start; FCM HTTP v1 (kaldırılmış toplu uç kullanılmaz; her mesaj tekil istektir, hız ve retry Relay'indir).
6. **Kimlik:** JWT ve OAuth jetonu kuralları §18 TN-28–TN-30; kimlik bilgisi sıcak değişir.
7. **Kimlikler:** `apns-id` Relay tarafından teslim kimliğinden türetilir; dönen sağlayıcı kimlikleri teslim defterine yazılır.
8. **Doğrulama:** kendi APNs mock sunucusu (token önekine göre deterministik yanıt tablosu: 410, 429, süresi dolmuş jeton, yavaş yanıt, GOAWAY, düşük eşzamanlı akış ilanı), FCM için HTTP/2 destekli mock, test vektörleri, sağlayıcı sandbox'ı ve olgun bir istemciye karşı farklılık testi (Access T42 yaklaşımı).

**T-38 — Web Push Relay'in kendi RFC 8291/8292 uygulamasıdır.** `:crypto` + JOSE ile yazılır, RFC test vektörleriyle doğrulanır. Terk edilmiş Web Push şifreleme kütüphaneleri kullanılmaz. Anahtar kuralları §18 TN-31.

**T-39 — E-posta çekirdeği Swoosh'tur (≥ 1.26.3).** Sağlayıcı failover'ı, itibar takibi ve bounce normalizasyonu Relay katmanındadır (Swoosh bunları vermez). Bamboo kullanılmaz. "Kendi posta sunucunu bağla" SMTP adaptörüyle sağlanır; Relay MTA işletmez (§12).

**T-40 — SMS, WhatsApp, mesajlaşma ve İYS adaptörleri Req/Finch üzerinde ince ve test vektörlüdür.** Resmî SDK'lara bağımlılık kurulmaz; gelen webhook imza doğrulaması kendi kodumuzdadır (Standard Webhooks uyumlu sağlayıcılar için ortak doğrulayıcı). Her adaptör `provider_idempotency_policy` ve kanal kanıt tablosu beyanıyla gelir; beyan etmeyen adaptör devreye alınmaz (§12).

**T-41 — Broadway yalnız ingest konnektörlerinde kullanılır.** Kullanım yerleri: müşterinin Kafka/SQS/outbox kaynağından olay alımı ve sağlayıcı teslim raporu yağmurunu toplu yazan batcher. Broadway'in hız sınırlama özelliği sağlayıcı limiti için kullanılmaz (düğüm ve hat başına sabit pencere; sınırda çift patlama).

**T-42 — Hammer yalnız düğüm-yerel API korumasıdır.** Dağıtık limit Relay'in kendi limitleyicisidir (T-20). Düğüm-yerel koruma, dağıtık limitin önünde ucuz bir ilk filtredir.

**T-43 — TLS sonlandırma uygulamanın önünde yapılabilir; sağlayıcıya giden TLS doğrulaması kapatılamaz.** Gelen bağlantılarda TLS yük dengeleyicide ya da ters vekilde sonlandırılabilir (BEAM'in saf Erlang TLS'i toplu verimde zayıftır ⚠️); sonlandırma noktası bölgenin veri yerleşimi kurallarına uyar (§20.10). Giden bağlantılarda sertifika doğrulaması her zaman açıktır ve sağlayıcı kök sertifika değişiklikleri izlenir.

---

### 19.9 BEAM işletim kuralları

**T-44 — VM bayraklarına ölçmeden dokunulmaz.** Değişiklikten önce mikro durum muhasebesi (`msacc`) ve zamanlayıcı kullanımıyla ölçülür. Kurallar:
1. Zamanlayıcı sayısı açılışta loglanır; konteyner CPU kotasının doğru algılanmadığı durumda açıkça ayarlanır.
2. Meşgul bekleme yalnız konteyner CPU kısıtlaması (throttling) ölçüldüyse kapatılır; aksi hâlde gecikmeyi kötüleştirir.
3. Süreç yığın sınırı önce gözlem modunda açılır (öldürmeden raporla); sınırsız yığın varsayılanı bilinçli olarak yönetilir.
4. Konteyner bellek tavanı ölçülmüş tepenin üstünde, VM bellek kullanımı limitin yaklaşık %75'inde tutulur; limit yükseltmek sızıntının çözümü değildir.
5. Container'da önyüklemede bellek ayıran ya da topoloji gerektiren bayraklar kullanılmaz.

**T-45 — Süreç ve bellek kuralları.**
1. Posta kutusu veri yerleşimi süreç başına ayarlanır (global değil): az sayıda, büyük ve patlamalı posta kutulu süreçler (HTTP havuzu, soket taşıması, kuyruk bildirimcisi) yığın dışı.
2. Büyük ikili veri (refc binary) sızıntısı için oyun kitabı uygulanır: büyük yanıt gövdesinin parçası tutma sınırında kopyalanır; toptan kopyalama yapılmaz; teşhis sırası bellek dağılımı → süreç başına ikili → hedefli GC.
3. Gözetim ağacında yeniden başlatma bütçeleri bilinçli tasarlanır; bütçeler ağaçta çarpılır ve bir sağlayıcı kesintisi ağacı tepeye yürütüp düğümü düşürmemelidir.
4. Geri basınç her zaman uygulama kodudur; posta kutuları sınırsızdır. Posta kutusu birikmesi azaltma değil eskalasyon sinyalidir (süreç öldürmek mesaj kaybettirir).
5. Okuma ağırlıklı paylaşılan veri ETS'te, nadiren değişen büyük terimler `persistent_term`'de tutulur; `persistent_term` yazması global GC tetiklediği için sık değişen veriye konmaz. Kiracı başına ETS tablosu açılmaz.
6. Durumlu kiracı bileşenleri (APNs bağlantısı, kiracı × sağlayıcı kesicisi) tembel başlar ve boşta kendini sonlandırır; durumsuz işçiler paylaşılır.

**T-46 — Sır hijyeni.** Kimlik bilgisi ve onay kaydı işleyen süreçler hassas bayrağı taşır; sırlar sıfır argümanlı kapanış içinde taşınır; yapıların inceleme çıktısı izin listesiyle (`only:`) kısıtlanır ve sürüm derlemesinde doğrulanır; durum biçimlendirme geri çağrıları sırları gizler; yığın izinden argümanlar budanır; crash dump üretimde kapalıdır ya da şifreli birime yazılır; cihaz token'ı tutan ETS tabloları özeldir; HTTP parametre filtresi token, onay kimliği ve PII alan adlarıyla genişletilir.

**T-47 — Dış veriden sembol üretilmez; süreç sınırında bağlam açıkça taşınır.** CI şunları reddeder: dış veriden atom üretme, `keys: :atoms` ile JSON çözme, güvenli kip olmadan terim çözme. Çıplak `Task`/`spawn` kullanımı CI'da reddedilir; her süreç, iş ve mesaj sınırında trace bağlamı ve korelasyon kimliği açıkça taşınır (§20.6).

**T-48 — Sistem izleme kendi monitörümüzledir.** VM sistem olayları (uzun GC, uzun zamanlama, büyük yığın, uzun posta kutusu, meşgul port) güncel izleme API'si üzerinden kendi küçük monitörümüzle telemetriye dönüştürülür; etiketlerde ham süreç kimliği değil kayıtlı ad ya da başlangıç fonksiyonu kullanılır; monitör kendisi yüksek öncelikli ve yığın dışı posta kutuludur. Periyodik ölçümler (bellek kalemleri, çalışma kuyrukları, atom/süreç sayıları) ayrı metrik olarak toplanır. Atom sayısı eğimi alarm üretir. Kirli (dirty) zamanlayıcı kuyrukları ayrıca enstrümante edilir.

**T-49 — OTP güvenlik yamaları takip edilir; araç zinciri sabitlenir.** OTP'nin sabit güvenlik sürüm takvimi yoktur; yama gecikmesi işletenin sorumluluğudur. Kullanılan OTP ve Elixir sürümü imajda sabitlenir; güvenlik bildirimleri takip edilir ve kritik yamalar hızlandırılmış sürümle uygulanır. İsteğe bağlı OTP uygulamaları (SSH sunucusu, `inets` HTTP sunucusu) başlatılmaz.

---

### 19.10 Bağımlılık politikası ve yerel geliştirme

**T-50 — Kütüphane sürümleri sabitlenir; beklenmeyen davranış farkı yükseltmeyi durdurur.** Bütün bağımlılıklar kilit dosyasında sağlama toplamıyla sabitlenir. Sağlayıcı istekleri, render çıktıları ve imzalar için altın dosya regresyon testleri vardır; beklenmeyen fark yükseltmeyi durdurur. Başlangıç sürümleri: Finch 0.24.0, Phoenix 1.8.15, Swoosh 1.28.1, Oban 2.24.1, oban_web 2.13.0. Sürüm değişikliği PR'ı değişiklik günlüğünün okunduğunu kaydeder.

**T-51 — Lisans disiplini ve çekirdek dışı kütüphaneler.**
1. AGPL/GPL lisanslı projelerden (ör. Keila, Sygnal'in Element sürümü, Mautic, Listmonk) kod kopyalanmaz; yalnız fikir alınır. Bağımlı olunan projelerin lisans değişiklikleri izlenir; OSI dışı lisansa geçen bağımlılık değiştirilir.
2. Ash ve Commanded/EventStore çekirdekte kullanılmaz: durum, append-only durum olayları + outbox ile tutulur; açık katman ayrımı ve "SQL yalnız veri katmanında" ilkesiyle çelişen çerçeve kullanılmaz.
3. Kiracı ve sistem şablonları tek motorla (Liquid; Solid) render edilir; EEx yalnız Relay'in derleme zamanı kodunda, kiracı verisinde asla. MJML yalnız yayın anında derlenir. Ayrıntı §11.
4. Yerelleştirme ex_cldr + ICU MessageFormat ile; tzdata otomatik güncellemesi kapalıdır ve sürümü imaja sabitlenir; JSON Schema doğrulaması Draft 2020-12 ile.

**T-52 — Geliştirme yerel eşdeğerlerle yapılır; "geliştirme modu" yoktur.** Resmî `docker compose` tek komutla Postgres, Valkey, Mailpit, APNs mock, FCM mock (WireMock HTTP/2) ve toxiproxy'yi kaldırır; KMS yerine SoftHSM ya da yerel `age` kullanılır. Güvenliği zayıflatan bayrak yoktur (§18 TN-8; Access OP-69). Yük testleri açık döngüdür (sabit varış oranı); kapalı döngü araçlar kuyruk gecikmesini ölçmediği için kullanılmaz. Kaos testleri toxiproxy ile hem sağlayıcı mock'larının hem Postgres'in önünde yapılır.

---

### 19.11 Rust NIF istisna kapısı

**T-53 — Yerel kod (NIF) istisnadır ve kapıdan geçer.** Tırmanma merdiveni: saf Elixir → Port (ayrı OS süreci) → Rustler NIF → ayrı servis. Bir üst basamağa yalnız ölçüm kanıtıyla çıkılır.
1. NIF çökmesi bütün VM'i düşürür. Güvenilmeyen girdi işleyen yerel kod tercihen Port'tur. Kiracıya özgü yerel kod yoktur.
2. NIF, 1 ms kuralına uyar; uzun iş için tercih sırası: verim veren (yielding) → iş parçacıklı → kirli (dirty) NIF. Kirli CPU kuyruğu enstrümante edilir (T-48).
3. Derleme kapısı: Rustler ve önceden derlenmiş ikili dağıtım; sağlama toplamı dosyası pakettedir; musl hedefi dahil bütün hedef mimariler üretilir; kaynak derlemeye zorlama kaçış kapısı belgelenir.
4. İzin verilen NIF'ler listesi tektir ve register'dadır. Başlangıç listesi: MJML derleyicisi (yalnız yayın anında, gönderim yolunda değil). Listeye ekleme bu bölümde yeni karar gerektirir.
5. Kriptografi zaten platform kütüphanesindedir (`:crypto`); kriptografi için NIF yazılmaz.

---

### 19.12 Yapım sırası kısıtları

**T-54 — Yapım sırası eki (Ek B) iki kısıta uyar.** Yapım sırası spec'in parçası değildir ve ayrı bir ekte belirlenir; ancak o ek şu iki kısıtı taşır:
1. Ürün yüzeyi (HTTP API, CLI, operatör aracı) erken aşamadadır. Gerekçe: arka uç çekirdeği önce yazılıp yüzey sona bırakıldığında ürün kullanılabilir hâle gelmeden uzun süre kalır; yüzey erken geldiğinde her yeni yetenek hemen denenebilir.
2. Kuyruk eklentisinin ticari sürümünü kullanmamanın (T-14) gerektirdiği kendi bileşenler (küme geneli hız limiti, kiracı adaleti, global eşzamanlılık, batch ve fan-out takibi, bekleme noktası tablosu, devre kesici, DLQ; §19.6) erken aşamadadır ve ayrı, çok aylık bileşenler olarak bütçelenir. Bunlar olmadan teslim çekirdeği doğru çalışmaz.

---

### 19.13 Mühendislik kuralları

#### 19.13.1 T-56 Repo ve klasör yapısı

**T-56 — Tek depo; tek Mix uygulaması; bağlamlar arası bağımlılık yönü derleme anında zorlanır.** Relay'in bütün kodu tek depodadır (`e-suiss/relay`). Sunucu tek bir Mix uygulamasıdır (umbrella yok) ve tek sürüm paketi olarak dağıtılır; roller (`api`, `worker`, `socket`) aynı paketten seçilir (T-3). Çekirdek bağlamlar ayrı sınırlardır ve aralarındaki izinli bağımlılık yönü `boundary` ile derleme anında denetlenir; ihlal derlemeyi kırar. Yönetim paneli React (TypeScript) ile yazılır, derlenmiş statik dosyalar olarak aynı sürüm paketinden sunulur ve hazır UI bileşenleriyle aynı tasarım sistemini paylaşır (Access ile aynı).

```text
relay/
├── lib/relay/            çekirdek bağlamlar (her biri ayrı sınır)
│   ├── ingest/           olay kabulü, idempotency, dedup
│   ├── workflow/         workflow, adımlar, rota, eskalasyon, zamanlama
│   ├── policy/           sınıf, tercih, izin, İYS, sessiz saat (kapı → filtre)
│   ├── templates/        şablon, yerelleştirme, render
│   ├── channels/         kanal adaptörleri, sağlayıcılar, failover
│   ├── delivery/         teslim defteri, durum, mutabakat
│   ├── inbox/            posta kutusu, rozet, realtime akışı
│   ├── webhooks/         teslim motoru, hedefler, portal
│   ├── agents/           bekleme noktası, ajan kaydı, A2A/MCP
│   ├── tenancy/          kiracı, alt kiracı, ortam, kimlik, kill switch
│   ├── audit/            denetim kaydı, kontrol noktası
│   └── platform/         Valkey, hız limiti, adalet, şeritler, kuyruk bileşenleri
├── lib/relay_web/        Phoenix: API, WebSocket/SSE, MCP ucu, panelin statik sunumu
├── priv/repo/migrations/ SQL göçleri ve veritabanı fonksiyonları
├── native/               Rust NIF'leri (yalnız T-53 kapısından geçenler)
├── sdks/                 openapi/, asyncapi/, typescript/, python/, go/, java/, dotnet/,
│                         elixir/, php/, ruby/, swift/, kotlin/, react-native/, flutter/
├── web/                  yönetim paneli + UI bileşenleri (React + web components)
├── conformance/          sağlayıcı taklitleri (APNs, FCM, SMTP, SMS), sözleşme testleri
├── load/                 yük testleri
├── deploy/               Docker, Helm, docker compose
└── docs/                 spec, mimari, runbook'lar
```

#### 19.13.2 T-57 Kod içi mimari

**T-57 — Saf çekirdek, kenarda yan etki; dış dünya behaviour arkasında; saat ve rastgelelik enjekte edilir.**
1. **Saf çekirdek.** Karar veren kod (kapı → filtre → zamanlayıcı kafesi, rota seçimi, şablon render, teslim durumu makinesi, eskalasyon zamanlaması, eşleme) saf fonksiyondur: girdisini parametre olarak alır, karar döner (`{:send, rota}`, `{:skip, reason, rule_id}` …); veritabanına, ağa, Valkey'e ya da saate dokunmaz. Yan etkiler yalnız kenar katmandadır.
2. **Behaviour sınırı.** Her sağlayıcı adaptörü, Valkey, KMS/HSM, İYS istemcisi ve dış HTTP behaviour arkasındadır; testlerde Mox ile sahtelenir. Kanal adaptörleri yeteneklerini ve idempotency politikalarını behaviour sözleşmesinde beyan eder (§12).
3. **Saat ve rastgelelik portu.** Kod saati yalnız `Relay.Clock`, rastgeleliği yalnız enjekte edilen üreteç üzerinden alır; `DateTime.utc_now/0` ve `:rand` doğrudan çağrılmaz (Credo kuralı). Test düzleminin sanal saati (X ailesi, test ortamı) bu porttan çalışır; testler tekrarlanabilirdir.
4. **Tek transaction.** Kayıt, iş kuyruğu satırı ve outbox olayı aynı `Ecto.Multi` içinde yazılır. Dış çağrı (sağlayıcı, webhook, İYS, KMS) hiçbir zaman transaction içinde yapılmaz.
5. **Süreç çalışma zamanı aracıdır.** Kalıcı durum veritabanındadır. Süreç (GenServer vb.) yalnız eşzamanlılık, bağlantı ya da önbellek gerektiğinde kullanılır (APNs bağlantı havuzu, WebSocket, devre kesici, yerel önbellek); süreç çökmesi durum kaybettirmez.
6. **Dar bağlam yüzü.** Her bağlam yalnız kök modülündeki fonksiyonları dışa açar; iç modüllere başka bağlamdan erişim derleme anında engellenir (T-56).
7. **Güvenliği zayıflatan bayrak yok.** Uyum, imza, kimlik veya kapı kontrolünü kapatan yapılandırma yoktur; test düzlemindeki tek fark son adımdaki sahte sağlayıcıdır.

#### 19.13.3 T-58 Kod kalitesi

**T-58 — Kod kalitesi kuralları.**
1. **Dil.** Kod, yorum, commit ve PR İngilizcedir; spec Türkçedir.
2. **Biçim.** `mix format` zorunludur; biçimsiz kod CI'da reddedilir.
3. **Uyarı = hata.** Derleme `--warnings-as-errors` ile yapılır. Elixir'in yerleşik tip denetleyicisinin uyarıları da hatadır. Dialyzer CI'da koşar; dışa açık her fonksiyonda `@spec` zorunludur.
4. **Statik analiz.** Credo katı modda koşar; Relay'e özgü kurallar: saat ve rastgelelik yalnız portlardan (T-57), SQL yalnız veri katmanında, `IO.inspect`/`dbg` commit'lenmez, süreç sınırını geçen işlerde korelasyon kimliği taşınır. Sobelow (Phoenix güvenlik analizi) CI'da koşar; bulgu derlemeyi durdurur.
5. **Hata ve karar ayrımı.** Fonksiyonlar `{:ok, değer}` ya da `{:error, %Relay.Error{}}` döner; hata tipli yapıdır. Gönderilmeme kararı hata değildir: `{:skip, reason, rule_id}` olarak döner ve hata metriğine girmez. API kenarında hatalar RFC 9457 biçimine çevrilir (§9).
6. **Tipli kimlikler.** Dışa verilen kimlikler tür öneki taşır (`ntf_` bildirim, `dlv_` teslim, `rcp_` alıcı, `wp_` bekleme noktası, `evt_` olay vb.); önek kod içinde doğrulanır.
7. **Gizli veri kendini gizler.** Sırlar, anahtarlar, iletişim adresleri ve mesaj içerikleri `inspect` ve log çıktısında maskeli görünen tiplerle tutulur (`@derive {Inspect, except: …}`, `Redacted` sarmalayıcı); düz değere erişim açık bir çağrı gerektirir.
8. **Spec atfı.** Bir kuralı uygulayan kodda kısa yorumla spec ID'si yazılır (ör. `# INV-12: every skip records a reason`).
9. **TODO yalnız issue ile.** `# TODO(#123): …` biçimi dışındaki TODO CI'da reddedilir.
10. **Belgeleme.** Dışa açık her modülde `@moduledoc`, her dışa açık fonksiyonda `@doc` zorunludur.

#### 19.13.4 T-59 API geliştirme kuralları

**T-59 — API geliştirme kuralları.** API içeriği §9'dadır; bu kurallar API'nin geliştirilmesi ve değiştirilmesi içindir.
1. **Aileler ayrı sözleşmelerdedir:** sunucu API'si, abone API'si, realtime (WebSocket/SSE), giden olaylar (webhook ve olay hedefleri; AsyncAPI), ajan protokolleri (MCP, A2A), operatör API'si. Her aile kendi kimlik doğrulama kuralına uyar.
2. **Sürüm içinde yalnız ekleme.** Alan silme, yeniden adlandırma ve anlam değişikliği kırıcıdır; yalnız yeni tarihli sürümle yapılır.
3. **Kırıcı değişiklik CI'da yakalanır.** Her PR'da OpenAPI ve AsyncAPI önceki sürümle karşılaştırılır; yeni sürüm açılmadan yapılan kırıcı değişiklik derlemeyi kırar.
4. **Kaldırma duyurusu.** Kaldırılacak sürüm ya da alan en az 12 ay önceden duyurulur; cevaplar `Deprecation` ve `Sunset` (RFC 8594) başlıklarını taşır; panelde uyarı gösterilir.
5. **Tek biçim:** JSON alanları `snake_case`; zaman RFC 3339 UTC; para en küçük birim + ISO 4217; dil BCP 47; kimlikler önekli ve opak (T-58).
6. **İzlenebilirlik ve sınır başlıkları:** her cevapta `Request-Id`; `RateLimit-*` başlıkları ve aşımda `Retry-After`.
7. **Eşzamanlı güncelleme:** düzenlenebilir kaynaklar `ETag` taşır; güncelleme `If-Match` ister.
8. **SDK hattı:** sözleşme değişince bütün SDK'lar CI'da yeniden üretilir ve her dilin testleri sözleşmeye karşı koşar; kırılan SDK sözleşme değişikliğinin birleşmesini durdurur.

#### 19.13.5 T-60 Veri katmanı kod kuralları

**T-60 — Veri katmanı kod kuralları.**
1. **Sorgunun yeri.** Ecto şemaları yalnız eşleme içindir; iş kuralı taşımaz. `Repo` çağrıları ve SQL yalnız her bağlamın veri katmanı (`*.Store`) modüllerindedir (Credo, T-58). Karmaşık sorgular açık SQL ya da Ecto sorgusuyla yazılır; sorgu başına beklenen plan kritik yollarda testle sabitlenir.
2. **Yazma yolları.** Çekirdek tablolara yazma yalnız veritabanı fonksiyonları (SECURITY DEFINER) üzerinden yapılır; uygulama rolünün bu tablolarda doğrudan DML yetkisi ve hiçbir tabloda `DELETE`/`TRUNCATE` yetkisi yoktur (Access OP-73; tek istisna iş kuyruğu tabloları).
3. **Kiracı izolasyonu şemada zorlanır.** Her tabloda `tenant_id` birincil anahtar önekindedir; kiracı içi referanslar bileşik yabancı anahtardır `(tenant_id, id)`; RLS açık ve FORCE'tur.
4. **Göçler.** Zaman damgalı ve açıklayıcı adlıdır; commitlenmiş göç değiştirilmez, düzeltme yeni göçtür. Genişlet/daralt (expand/contract) kuralı uygulanır. Göç güvenlik denetimi CI'dadır: kilitleyen indeks (CONCURRENTLY'siz), varsayılan değerli sütun ekleme, tablo yeniden yazan değişiklik ve tek adımda yeniden adlandırma reddedilir.
5. **Şema güvenlik testleri (CI).** Her tabloda `tenant_id` önekli PK, RLS FORCE, bileşik FK, append-only tablolarda UPDATE/DELETE engeli ve uygulama rolünün yetki listesi otomatik doğrulanır.
6. **Gerçek veritabanıyla test.** Testler gerçek PostgreSQL 18 ve Valkey ile çalışır (Ecto SQL sandbox, testcontainers); taklit veritabanı kullanılmaz. Üretim verisi geliştirme ve testte kullanılmaz.
7. **Küçük kurallar.** Kimlikler UUIDv7'dir. Durum alanları Postgres `ENUM` değil `CHECK` kısıtlı `text`'tir. JSONB yalnız gerçekten şemasız veri içindir. Zaman `timestamptz` ve UTC'dir; saat dilimi dönüşümü SQL'de yapılmaz.

#### 19.13.6 T-61 Test kuralları

**T-61 — Test katmanları ilk günden; kural kapsamı satır kapsamından önce gelir.**
1. **Katmanlar:** saf çekirdek için birim ve özellik testleri (StreamData); sözleşme testleri (OpenAPI/AsyncAPI); gerçek PostgreSQL ve Valkey ile entegrasyon testleri; sağlayıcı taklitleriyle (`conformance/`: APNs HTTP/2, FCM, SMTP, SMS, WhatsApp) uçtan uca testler; test düzlemi ve sanal saatle akış testleri (eskalasyon, bekleme, digest, saat dilimi); kaos testleri (toxiproxy: Valkey, sağlayıcı ve veritabanı kesintileri); açık döngü yük testleri.
2. **Kural kapsamı.** Her değişmez (INV) ve her kural tabanlı karar en az bir testle doğrulanır; test adı ilgili spec ID'sini taşır. Satır kapsamı hedef değildir.
3. **Eşzamanlılık testleri gerçek motorla.** Benzersizlik, hız limiti, adalet ve bekleme noktası yarışları iş kuyruğunun test kipinde değil, gerçek kuyruk motoru ve gerçek veritabanıyla test edilir.
4. **Süre bütçesi.** PR test paketi ≤ 10 dakikadır; daha uzun paketler gece koşar.
5. **Kararsız test yok.** Tekrar deneyerek geçen test kabul edilmez; kararsız test issue ile karantinaya alınır ve düzeltilene kadar sürüm çıkmaz.

#### 19.13.7 T-62 Tedarik zinciri ve depo güvenliği

**T-62 — Tedarik zinciri ve depo güvenliği.**
1. **Sabitleme.** `mix.lock` commitlenir; Erlang/OTP ve Elixir sürümleri `.tool-versions` ile, taban imajlar özet (digest) ile sabitlenir.
2. **Denetim.** CI'da `mix hex.audit` (geri çekilmiş paketler) ve bilinen açık taraması (`mix_audit`) koşar; bulgu derlemeyi durdurur. Bağımlılık güncellemeleri otomatik PR ile gelir.
3. **Lisans.** Sürüm paketine yalnız izin verici lisanslı bağımlılık girer; AGPL/GPL bağımlılık CI'da reddedilir (T-51).
4. **Yeni bağımlılık.** Gerekçesi, bakım durumu ve lisansı PR'da yazılır; tek bakımcılı kritik bağımlılıkların test süiti Relay CI'ında koşar (Access T42 madde 5 ile aynı).
5. **Sürüm bütünlüğü.** Her sürüm için SBOM (CycloneDX), imzalı konteyner imajı (Sigstore/cosign) ve derleme kaynağı kanıtı (SLSA provenance) üretilir; NIF ikilileri sağlama toplamıyla doğrulanır (T-53). Derleme mümkün olduğunca tekrarlanabilirdir.
6. **Depo güvenliği.** Gizli bilgi taraması ve push koruması açıktır; özel güvenlik açığı bildirimi açıktır; `SECURITY.md` ve `CODEOWNERS` vardır; commit'ler imzalıdır (Access §14.7 F-1…F-18 ile aynı).

#### 19.13.8 T-63 Gözlemlenebilirlik kod kuralları

**T-63 — Gözlemlenebilirlik kod kuralları.**
1. **Üç sinyal.** İz (OpenTelemetry), metrik (Telemetry → Prometheus/OTLP) ve yapılandırılmış JSON log.
2. **Korelasyon.** W3C `traceparent` HTTP isteklerinde, iş kuyruğu işlerinin meta verisinde, webhook ve olay hedeflerinde taşınır. Süreç sınırında iz bağlamı kaybolabildiği için ayrıca kalıcı bir korelasyon kimliği taşınır (T-58).
3. **Ortak log alanları.** `request_id`, `correlation_id`, `tenant_id` (opak), ilgili kaynak kimlikleri (`ntf_`, `dlv_` …), `env`, `role`. Kişisel veri ve sır loglanmaz (T-58 maskeli tipler).
4. **Metrik etiket sınırı.** Etiketler sınırlı kümeden gelir (kanal × sağlayıcı × durum × sınıf); kiracı, kullanıcı, cihaz, adres veya kimlik etiket olamaz. Kiracı bazlı görünürlük rollup tablolarından ve loglardan sağlanır (§14).
5. **Doğruluk kaynağı.** Teslim hunisi ve SLO'lar teslim defterinden hesaplanır; iz yalnız hata ayıklama içindir (§14, §20).
6. **Sağlık uçları.** Canlılık ve hazırlık uçları ayrıdır; hazırlık, rolün bağımlılıklarını (Postgres, Valkey, KMS) kontrol eder.

#### 19.13.9 T-64 Sürümleme, CI ve yayın

**T-64 — Sürümleme, CI ve yayın.**
1. **Sürümler ayrıdır.** Ürün SemVer kullanır; API tarihli sürümlüdür (§9); her SDK kendi SemVer'ini taşır.
2. **Commit ve değişiklik kaydı.** Conventional Commits; `CHANGELOG` commit geçmişinden üretilir.
3. **CI aşamaları.** *PR (≤ 10 dk):* biçim, uyarısız derleme, Credo, Sobelow, Dialyzer (önbellekli), birim + entegrasyon testleri, sözleşme farkı, şema ve göç denetimi, lisans ve açık taraması. *Gece:* yük ve kaos testleri, tam sağlayıcı uyumluluk testleri, SDK testlerinin tamamı, benchmark'lar. *Yayın:* `mix release` ile sürüm paketi, minimal konteyner imajı, imza + SBOM + provenance, Helm chart, SDK'ların trusted publishing ile yayımlanması.
4. **Tek paket.** Self-host ve SaaS aynı imajı ve aynı Helm chart'ı kullanır (§3 tam eşitlik).

#### 19.13.10 T-65 Geliştirici ortamı

**T-65 — Tek komutla yerel ortam; dev modu yok.**
1. `just dev` tek komutla yerel ortamı kurar: docker compose ile PostgreSQL 18, Valkey, Mailpit, APNs/FCM/SMS taklitleri ve isteğe bağlı toxiproxy; örnek veri ve hazır test düzlemi.
2. Komutlar: `just test`, `just check` (CI'nın PR aşamasının yereldeki karşılığı), `just gen` (sözleşmelerden SDK ve tip üretimi).
3. Araç sürümleri `.tool-versions` ile sabittir (asdf/mise).
4. Dev modu yoktur; güvenlik ve uyum kontrolleri yerelde de aynı kod yolundan geçer (T-57.7). Farklılık yalnız yerel eşdeğer servislerdir.

#### 19.13.11 T-66 Dokümantasyon

**T-66 — Dokümantasyon kuralları.**
1. Spec `docs/spec/` altında bölüm başına dosyadır (Türkçe, normatif; dosya adları İngilizce).
2. Ayrı karar belgeleri (ADR) yoktur; spec'teki karar register'ları karar kaydıdır. Register'ı değiştiren PR `decision` etiketini taşır.
3. Mimari diyagramlar Mermaid (C4 düzeyleri) ile `docs/architecture/` altındadır.
4. Kod belgeleri ExDoc ile üretilir (T-58 madde 10).
5. Runbook'lar `docs/runbooks/` altında şablona uyar; her alarmın bir runbook'u vardır (§20).
6. Kamuya açık API belgeleri OpenAPI/AsyncAPI'den üretilir.

#### 19.13.12 T-67 Süreç ve katkı

**T-67 — Süreç ve katkı kuralları.**
1. Trunk-based geliştirme; doğrusal `main` geçmişi; force push ve `main` dalının silinmesi yasaktır; commit'ler imzalıdır.
2. Değişiklikler `main`'e doğrudan gönderilebilir (Adem kararı, Access ile aynı depo kuralı); dış katkılar PR ile gelir ve squash ile birleştirilir.
3. Depoda `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, PR ve issue şablonları ve `CODEOWNERS` bulunur.
4. Güvenlik açıkları yalnız özel güvenlik bildirimiyle alınır.

#### 19.13.13 T-68 Performans disiplini

**T-68 — Ölçmeden optimizasyon yok.**
1. Sıcak yollar için benchmark'lar (Benchee) vardır: kapı → filtre kafesi, rota seçimi, şablon render, hız limiti, eşleme, kimlik ve imza işlemleri.
2. PR'da saf çekirdek fonksiyonları için reduksiyon sayısı tabanlı gerileme kapısı çalışır (gürültüsüz ölçü); gerçek süre benchmark'ları ve açık döngü yük testleri gece ayrılmış makinede koşar.
3. İstek türü başına performans bütçesi tanımlanır; aşım alarm ve issue üretir.
4. Ölçümle gerekçelenmemiş optimizasyon kabul edilmez; NIF yalnız T-53 kapısından geçer.

---

### 19.14 T karar register'ı (T-1–T-68)

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| T-1 | Çalışma zamanı Elixir/OTP; gerekçe performans değil: işlemsel kuyruk, geri basınç primitifleri, hata yalıtımı, aynı yığında realtime | MERKEZİ KARAR | Darboğaz sağlayıcıda; diller arası titiz p99.9 karşılaştırması yok |
| T-2 | Dil kararının yeniden değerlendirme koşulları: telafili saga yürütme zorunluluğu, PG zamanlayıcının ölçümde yetmemesi, FIPS zorunluluğu | WATCH | Temporal'ın Elixir dengi yok; bekleme noktası satır olarak tasarlandı |
| T-3 | Tek uygulama, tek imaj; roller `api`/`worker`/`socket`; aynı paket SaaS, self-host ve bütün bölgelerde | MERKEZİ KARAR | Özellik eşitliği; polyglot/çok servis pişmanlığı (Segment) |
| T-4 | Realtime Phoenix içinde; WebSocket ve SSE eşit; ayrı realtime sunucusu yok; WebTransport kapsam dışı; Presence kullanılmaz | MERKEZİ KARAR | Doğruluk Postgres'te; Presence yakınsama/bellek hataları |
| T-5 | Exec giriş noktası; readiness → bekle → boşalt; orkestratör süresi > kuyruk payı + realtime boşaltma; göç ayrı adım; jitter'lı yeniden bağlanma | FROZEN (teknik) | Zombi iş ve mükerrerin en sık nedeni kısa kapatma süresi |
| T-6 | Ölçekleme kuyruk gecikmesi/derinliğiyle; CPU% ile değil; önce sağlayıcı kapasitesi | FROZEN (teknik) | BEAM meşgul beklemesi CPU%'ü abartır ⚠️ |
| T-7 | Zorunlu: PostgreSQL + Valkey; NATS/Kafka, analitik DB, S3 isteğe bağlı adaptör | MERKEZİ KARAR | Çok bileşenli yığın self-host'u bozar (Novu, Dittofeed dersleri) |
| T-8 | PostgreSQL ≥ 18 | FROZEN (teknik) | Fast-path kilit düzeltmesi; PG18 OLTP gerilemesi kendi iş yükünde ölçülür ⚠️ |
| T-9 | Valkey kuralları: asıl kayıt yok; sinyal yalnız "yeni var" + seq; erişilemezse yoklama ve PG yedek limitleyici, asla limitsiz; tek test seti iki arka uçta; geçişte katı olan; `noeviction` | KANONİK DEĞİŞMEZ | Valkey kaybı veri kaybı olmamalı |
| T-10 | Düğümler arası sinyal Valkey pub/sub; LISTEN/NOTIFY kullanılmaz; sinyal kaybı yalnız gecikme | FROZEN (teknik) | NOTIFY dayanıksız, havuzlayıcıyla uyumsuz, commit'leri serileştirir (Recall.ai kesintileri) |
| T-11 | Tek saat otoritesi: karar veren arka ucun saati; düğüm duvar saati karara girmez; süreler monotonik | KANONİK DEĞİŞMEZ | Düğüm saat kayması limit kararlarını bozar |
| T-12 | Liderlik ve tekil görevler Postgres tabanlı; Horde/`:global` yok; durum DB'de | FROZEN (teknik) | Ağ bölünmesinde aynı isimli sürecin iki kez çalışması |
| T-13 | Distribution isteğe bağlıdır ve varsayılan kapalıdır; koordinasyon için kullanılmaz; açılırsa yalnız TLS + karşılıklı sertifika kimliğiyle | FROZEN (teknik) | Çerez tabanlı erişim RCE yüzeyi; EEF güvenlik rehberi |
| T-14 | Çekirdek kuyruk açık kaynak Oban; Oban Pro hiçbir yerde yok; belgelerde eklenti özelliklerine atıf yok | MERKEZİ KARAR | Apache-2.0 bütünlüğü; açık çekirdek yok |
| T-15 | İş argümanı yalnız kimlik; insert yalnız transaction içinde; iş ≤ 1 saat; uzun bekleme satır + zamanlayıcı; ilk adım kill switch/iptal kontrolü; dış çağrı transaction dışında; iş satırı sonuç kalıcı kayda yazıldıktan sonra temizlenebilir (OP-12) | KANONİK DEĞİŞMEZ | Kuyrukta PII yok; zombi kurtarmada mükerrer; Lifeline eşiği |
| T-16 | Kesin tekillik DB `UNIQUE` kısıtında; kuyruk benzersizliği ön filtre; teslim yolunda Bloom/HLL yok | KANONİK DEĞİŞMEZ | Oban OSS benzersizliği yarışa açık; Bloom yanlış pozitifi kayıp bildirim |
| T-17 | Oban tabloları ayrı şemada; göç sürümü sabit; bildirimler Relay'in Valkey bildiricisiyle (T-55); Oban Web + oban_met, sayım yükü sınırlı | FROZEN (teknik) | oban_met sayım sorgusunun büyük tabloda DB CPU'sunu tüketmesi ⚠️ |
| T-18 | Kendi bileşenler (hız limiti, DRR, global eşzamanlılık, batch, bekleme tablosu, devre kesici, retry/DLQ, Valkey kuyruk bildiricisi) Apache-2.0 ve kural testli; testler bilinen limitleyici hatalarından | MERKEZİ KARAR | Pro'suz yapının bedeli çekirdek kapsamda üstlenilir |
| T-19 | Algoritma matrisi: GCRA varsayılan; sabit pencere uzun kaba kotalar; kayan sayaç `0,90·L`; kayan kayıt küçük kapaklar; kanal birimi; pencere ofseti | FROZEN (teknik) | GCRA kesin `retry_after`; sabit pencerede çift patlama |
| T-20 | Hız limiti Valkey birincil, PG yedek (tek ifade upsert); asla limitsiz; `Retry-After` + jitter; sağlayıcıdan katı; kredi kiralama yalnız burst dostu kanalda | FROZEN (teknik) | Sağlayıcı aşımda sessiz düşürür/geciktirir; tek anahtarda PG verimi 2–5k op/sn ⚠️ |
| T-21 | DRR şerit içinde; kiracı bekleme tablosu + tekil dağıtıcı; boşalan açık sıfırlanır; ağırlık veri; `security` şeridinde bekleme tablosu yok | FROZEN (teknik) | Max-min adalet; OTP asla beklemez |
| T-22 | Global eşzamanlılık sınırı küme geneli; aşımda snooze | FROZEN (teknik) | Düğüm başına limit N katına çıkar |
| T-23 | Fan-out dilimli (5.000/200), keyset, kontrol noktalı; kampanya modu; ilerleme tablosu; `partial`; "anında" iddiası yok | FROZEN (teknik) · EA (dilim ve eşik sayıları) | Alıcı başına iş kuyruğu şişirir ⚠️ |
| T-24 | Bekleme noktası satır + zamanlayıcı; son tarih ilk parkta kalıcı; tek indeks eşleme; iki zamanlayıcı; değişmezler DB kısıtı | KANONİK DEĞİŞMEZ | Relay dayanıklı yürütme motoru değildir |
| T-25 | Devre kesici iki seviye, gerçek half-open, oran + asgari hacim, ağırlık, yalnız taşıma/5xx/zaman aşımı/kimlik ile açılır, gecikme eşiği, jitter; parametreler veri | FROZEN (teknik) · PD (parametreler) | Yalnız sağlayıcı anahtarlı kesici herkesi keser; 4xx açarsa kötü liste kanalı kapatır |
| T-26 | Tek retry otoritesi kuyruk; tam jitter, taban ×2; `max_attempts` ≤ yararlılık ömrü; retry önceliği düşer; hata sınıfı tablosu | FROZEN (teknik) | Katmanlı retry çarpımsal büyür (3×3 = 27×) |
| T-27 | Retry bütçesi: kanal başına 60 sn'de retry/toplam < %10 | POLICY DEFAULT | Retry fırtınası kesintiyi uzatır |
| T-28 | Belirsiz sonuç kör retry edilmez; beyanlı politika; ücretli kanalda ≤ 1 retry + `delivery_uncertain`; sağlayıcı idempotency anahtarı sabit | FROZEN (teknik) | Ücretli kanalda mükerrer maliyet |
| T-29 | DLQ ayrı sınıflandırılmış tablo; oynatma kuralları (geçersizleştiren asla, derinlik ≤ 1, yeni anahtar, ömür kontrolü); devre kapanınca otomatik oynatma | FROZEN (teknik) | `discarded` tek başına yetersiz |
| T-30 | Jitter her yerde deterministik; `rand` yok | FROZEN (teknik) | Tekrar oynatma ve deney bölmesi kararlılığı |
| T-31 | Dört şerit; şerit yalnız sınıftan; eşleme L0 `security`, L1 `transactional`+`action_required`, L2 `operational`+`system`+`social`, L3 `marketing` | FROZEN (teknik) | Eşleme sınıf özelliklerinden türetildi (`action_required` ertelenemez, `social` digest'lenebilir); L0'ın tek sınıf kalması yük atma "asla" kuralını en dar kümede tutar |
| T-32 | Şerit ayrımı fiziksel: kuyruk, eşzamanlılık bütçesi, HTTP örneği, DB havuzu; ölçekte ayrı düğüm havuzu | FROZEN (teknik) | Öncelik kesip almayı sağlamaz; arıza alanı paylaşılır |
| T-33 | Kümülatif şerit tavanı: L3 %60, L2 %80, L1 %95, L0 %100; aşımda snooze | POLICY DEFAULT | Paylaşılan kotada OTP'ye yer ayırır (Stripe filo yük atıcısı) |
| T-34 | Yük atma kuyruk gecikmesiyle (CoDel); sıra L3 → L2 → L1, L0 asla; L3 duraklatılır; kararlar `rule_id`'li | KANONİK DEĞİŞMEZ · PD (parametreler) | Google SRE kritiklik sınıfları |
| T-35 | Kabul kontrolü girişte `429`/`503` + `Retry-After`; `L_max = μ·W_max`; ρ 0,7; sınırlı tamponlar; AIMD giriş; kabul edilip kuyruğa girmeyen mesaj yok | FROZEN (teknik) | "Kuyruğa almak yalan söylemektir" |
| T-36 | Öncelik 0–9 şerit içi harita; DLQ oynatma ve bakım ayrı kuyrukta | FROZEN (teknik) | Katı öncelikte açlık |
| T-37 | Finch/Mint üzerinde kendi APNs/FCM istemcisi: semafor + sınırlı kuyruk, SETTINGS beklemesi, kiracı başına bağlantı, `(ortam × anahtar)` havuzu, bağlantı yaşı + jitter, bütün push türleri, FCM v1; mock + test vektörü + sandbox + farklılık testi | MERKEZİ KARAR | Bakımlı eksiksiz APNs kütüphanesi yok; soğuk bağlantıda 101. istek reddi |
| T-38 | Web Push kendi RFC 8291/8292 uygulaması, test vektörlü | FROZEN (teknik) | Mevcut şifreleme kütüphanesi terk edilmiş |
| T-39 | E-posta çekirdeği Swoosh ≥ 1.26.3; failover/itibar/bounce Relay'de; Bamboo yok | FROZEN (teknik) | Swoosh geniş adaptör seti; Bamboo bakım modunda |
| T-40 | Diğer adaptörler Req/Finch üzerinde ince, test vektörlü; imza doğrulaması kendi kodumuz; beyansız adaptör devreye girmez | FROZEN (teknik) | Küçük bağımlılık yüzeyi; resmî Elixir SDK'ları yok/durgun |
| T-41 | Broadway yalnız ingest ve teslim raporu batcher'ı; hız sınırlaması sağlayıcı limitinde kullanılmaz | FROZEN (teknik) | Broadway hız sınırlaması sabit pencere, düğüm başına |
| T-42 | Hammer yalnız düğüm-yerel API koruması | FROZEN (teknik) | Dağıtık limit Relay'in kendi bileşeni |
| T-43 | Gelen TLS önde sonlandırılabilir (veri yerleşimine uygun); giden TLS doğrulaması kapatılamaz | FROZEN (teknik) | Saf Erlang TLS toplu veriminde zayıf ⚠️ |
| T-44 | VM bayraklarına ölçmeden dokunulmaz; zamanlayıcı sayısı loglanır; meşgul bekleme yalnız throttling ölçülürse kapanır; yığın sınırı gözlem modunda; bellek tavanı ~%75 | FROZEN (teknik) | Konteyner CPU/bellek algısı hataları (OTP cgroup hataları) |
| T-45 | Posta kutusu yerleşimi süreç başına; refc binary oyun kitabı; restart bütçeleri; geri basınç uygulama kodu; ETS/`persistent_term` kuralları; tembel kiracı süreçleri | FROZEN (teknik) | BEAM'in en yaygın arızası bellek tükenmesi (posta kutusu) |
| T-46 | Sır hijyeni sekiz kuralı | FROZEN (teknik) | BEAM iç gözlem yolları sırrı sızdırır |
| T-47 | Dış veriden atom yok; güvenli terim çözme; çıplak Task/spawn CI'da reddedilir; bağlam açık taşınır | FROZEN (teknik) | Atom tablosu sınırı; sessiz öksüz trace |
| T-48 | Kendi sistem monitörü; periyodik VM metrikleri; atom eğimi alarmı; kirli kuyruk enstrümantasyonu | FROZEN (teknik) | Eski izleme API'si tek alıcılı ve süpersede |
| T-49 | OTP güvenlik yamaları takip edilir; araç zinciri imajda sabit; isteğe bağlı OTP uygulamaları başlatılmaz | FROZEN (teknik) | OTP'de sabit güvenlik sürüm takvimi yok |
| T-50 | Sürümler sağlama toplamıyla sabit; altın dosya regresyonu yükseltmeyi durdurur; başlangıç sürümleri listesi | FROZEN (teknik) | Davranış değiştiren küçük sürümler |
| T-51 | AGPL/GPL'den kod kopyalanmaz, lisans değişimi izlenir; Ash ve Commanded/EventStore çekirdekte yok; tek şablon motoru; tzdata sabit | FROZEN (teknik) | Sygnal'in AGPL'e dönmesi; katman ilkesi |
| T-52 | Yerel eşdeğerlerle geliştirme, tek komut compose; dev modu yok; açık döngü yük testi; toxiproxy kaosu | FROZEN (teknik) | Access OP-69 ile aynı; kapalı döngü testte coordinated omission |
| T-53 | NIF istisna kapısı: Port → NIF → servis merdiveni; 1 ms kuralı; önceden derlenmiş + sağlama toplamı; izinli NIF listesi (başlangıç: yayın anında MJML) | FROZEN (teknik) | NIF çökmesi VM'i düşürür |
| T-54 | Yapım sırası eki iki kısıta uyar: ürün yüzeyi (API, CLI, operatör aracı) erken; T-14'ün gerektirdiği kendi bileşenler erken ve ayrı bütçeli | FROZEN (teknik) | Yüzeyi sona bırakan yapım sırasının kullanılabilirliği geciktirmesi; ticari eklentisiz kuyruğun bileşen maliyeti |
| T-55 | İş kuyruğu bildiricisi Relay'in kendi Valkey bildiricisi (Oban notifier arayüzü, Apache-2.0); Valkey yoksa yoklama; LISTEN/NOTIFY ve Erlang `:pg` bildiricisi kullanılmaz | FROZEN (teknik) | T-10 ve T-13 ile uyum; bildirim kaybı yalnız gecikme |
| T-56 | Tek depo; tek Mix uygulaması (umbrella yok), tek sürüm paketi; bağlamlar arası bağımlılık yönü `boundary` ile derleme anında zorlanır; panel React, statik olarak aynı paketten sunulur; klasör yapısı §19.13.1 | FROZEN (teknik) | Access OP-62 ile aynı disiplin |
| T-57 | Saf çekirdek / kenarda yan etki; behaviour sınırı (Mox); saat ve rastgelelik portu (sanal saat); kayıt + iş + outbox tek `Ecto.Multi`, dış çağrı transaction dışında; kalıcı durum DB'de, süreç yalnız çalışma zamanı aracı; dar bağlam yüzü; güvenliği zayıflatan bayrak yok (§19.13.2) | FROZEN (teknik) | Access OP-63 ve TI-9 ile aynı ilkeler |
| T-58 | Kod kalitesi: İngilizce kod; `mix format`; uyarı = hata (yerleşik tip denetleyicisi dahil), Dialyzer + `@spec`; Credo katı + Relay kuralları, Sobelow; tipli hata, karar ≠ hata, RFC 9457; tipli kimlik önekleri; gizli veri maskeli tipler; spec ID yorumları; TODO yalnız issue ile; `@moduledoc`/`@doc` zorunlu (§19.13.3) | FROZEN (teknik) | Access OP-64 ile aynı disiplin |
| T-59 | API geliştirme: aileler ayrı sözleşmelerde; sürüm içinde yalnız ekleme; kırıcı değişiklik CI diff'iyle yakalanır; kaldırma ≥ 12 ay önce, `Deprecation`/`Sunset`; tek biçim kuralları; `Request-Id`, `RateLimit-*`; `ETag`/`If-Match`; SDK'lar sözleşmeden üretilir ve CI'da test edilir (§19.13.4) | FROZEN (teknik) | Access OP-65 ile aynı disiplin |
| T-60 | Veri katmanı: Ecto şeması yalnız eşleme; Repo/SQL yalnız `*.Store`; çekirdek yazma SECURITY DEFINER fonksiyonlarıyla, uygulama rolünde DELETE/TRUNCATE yok; `tenant_id` PK öneki + bileşik FK + RLS FORCE; göçler değişmez, expand/contract, göç güvenlik denetimi; şema güvenlik testleri; gerçek PG 18 + Valkey ile test; UUIDv7, CHECK'li text durum, sınırlı JSONB, UTC (§19.13.5) | FROZEN (teknik) | Access OP-66 ile aynı disiplin |
| T-61 | Testler: birim/özellik, sözleşme, gerçek PG + Valkey entegrasyon, sağlayıcı taklitleriyle uçtan uca, test düzlemi + sanal saat akış testleri, kaos, açık döngü yük; kural kapsamı (spec ID'li testler); eşzamanlılık gerçek kuyruk motoruyla; PR paketi ≤ 10 dk; kararsız test karantina (§19.13.6) | FROZEN (teknik) | Access SA-59 ile aynı disiplin |
| T-62 | Tedarik zinciri: mix.lock, `.tool-versions`, digest'li imajlar; hex.audit + mix_audit CI'da; yalnız izin verici lisans; yeni bağımlılık gerekçeli, tek bakımcılı kritik bağımlılığın testleri CI'da; SBOM, imzalı imaj, SLSA provenance, NIF sağlama toplamı; gizli bilgi taraması, push koruması, SECURITY.md, CODEOWNERS, imzalı commit (§19.13.7) | FROZEN (teknik) | Access §14.7 F-1…F-18 ile aynı |
| T-63 | Gözlemlenebilirlik: OTel iz + Telemetry metrik + JSON log; `traceparent` HTTP/iş/webhook boyunca + kalıcı korelasyon kimliği; ortak log alanları, PII/sır loglanmaz; metrik etiketleri sınırlı (kiracı/kullanıcı/cihaz etiket değil); huni ve SLO defterden; ayrı canlılık/hazırlık uçları (§19.13.8) | FROZEN (teknik) | Access OP-67 ile aynı disiplin |
| T-64 | Sürümleme ve CI: ürün SemVer, API tarihli, SDK kendi SemVer; Conventional Commits + üretilen CHANGELOG; CI aşamaları (PR ≤ 10 dk, gece, yayın); `mix release`, minimal imaj, imza/SBOM/provenance, Helm, trusted publishing; self-host ve SaaS aynı paket (§19.13.9) | FROZEN (teknik) | Access OP-68 ile aynı disiplin |
| T-65 | Geliştirici ortamı: `just dev` (PG 18, Valkey, Mailpit, sağlayıcı taklitleri, toxiproxy, örnek veri); `just test/check/gen`; `.tool-versions`; dev modu yok (§19.13.10) | FROZEN (teknik) | Access OP-69 ile aynı |
| T-66 | Dokümantasyon: spec `docs/spec/`; ADR yok, register'lar karar kaydı, `decision` etiketi; Mermaid C4; ExDoc; runbook şablonu, her alarmın runbook'u; kamu API belgeleri sözleşmeden (§19.13.11) | FROZEN (teknik) | Access OP-70 ile aynı |
| T-67 | Süreç: trunk-based, doğrusal `main`, force push/dal silme yasak, imzalı commit; `main`'e doğrudan gönderim (Adem kararı), dış katkı PR + squash; CONTRIBUTING/SECURITY/CoC/şablonlar/CODEOWNERS; özel güvenlik bildirimi (§19.13.12) | FROZEN (teknik) | Access depo kuralıyla aynı |
| T-68 | Performans: sıcak yol benchmark'ları (Benchee); PR'da reduksiyon tabanlı gerileme kapısı, gece gerçek süre ve yük testleri; istek türü başına bütçe; ölçümsüz optimizasyon yok, NIF yalnız T-53 ile (§19.13.13) | FROZEN (teknik) | Access OP-72 ile aynı |
