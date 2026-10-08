## 20. Veri ve Operasyon

**Bu bölümün kuralları.**
- Bu bölüm veri modelinin genel kurallarını, yazma yollarını ve veritabanı rollerini, partition ve arşivi, saklama ve silmeyi (Access OP-73 ve Access OP-74'ün Relay'de uygulanışı), HA/DR'ı, gözlemlenebilirlik ve SLO'yu, mutabakatı, runbook ve olay müdahalesini, göç ve yayılımı, bölge kurulumunu, ön katmanı, kapasiteyi ve self-host işletimini tanımlar.
- Kararlar OP-1–OP-63'tür. Statüler §3'teki sözlüğe uyar. Register §20.14'tedir. Relay'in OP ailesi Access'in OP ailesinden ayrıdır; Access kararlarına her zaman "Access OP-n" diye atıf yapılır.
- Kanal, teslim durumu, inbox ve webhook tablolarının alan düzeyi tanımı ilgili bölümlerdedir (§12, §14, §15, §16); bu bölüm hepsine uygulanan ortak kuralları verir.
- ⚠️ işaretli sayılar ölçülmemiştir.

---

### 20.1 Veri modeli

**OP-1 — Kimlik, tip ve şema kuralları.**

| Konu | Kural | Gerekçe |
|---|---|---|
| Birincil anahtar | `uuid` v7; sıralama `id` ile değil `created_at` ile | Kiracılar arası sayaç sızıntısı yok; sağ uçta ekleme; v7 monotonluğu oturumlar arası garanti değil |
| Kapsam | Her kiracı tablosunda `tenant_id` + `environment`, PK öneki (§18 TN-12) | Yalıtım |
| Zaman | Yalnız `timestamptz`, yalnız UTC saklanır; SQL'de `AT TIME ZONE` lint ile yasak; saat dilimi hesabı yalnız uygulamada, tzdata sürümü imaja sabit | Düğümler arası tutarlılık; tek tzdata kaynağı |
| Para | `bigint` mikro birim (`cost_micros`) + ISO para birimi | Float yasak; numeric yavaş |
| Durum ve tür | PG `ENUM` kullanılmaz; `CHECK` kısıtlı alan | `ENUM` değeri geri alınamaz; genişlet-daralt uyumu |
| Telefon | E.164 `CHECK`; `+900…` reddedilir | İYS'nin sessizce kabul edip kullanamadığı biçim |
| E-posta | Normalize edilmiş metin; `citext` kullanılmaz | Unicode büyük/küçük harf katlama hatası |
| Adres ve token araması | HMAC kör indeks (anahtar DB dışında; §18 TN-33); indekste PII yok | KVKK veri minimizasyonu |
| Sayaçlar | `bigint` | Uzun ömürde `int` taşar |
| `jsonb` | Sorguda (`WHERE/JOIN/ORDER BY/GROUP BY`) geçen ya da kısıt gereken alan normal sütundur; `jsonb` yalnız gerçekten şemasız ya da kiracı tanımlı veri içindir; `json` kullanılmaz | Planlayıcı ve indeks |
| Yük boyutu | Olay yükü ve istek gövdesi için sert tavan (`CHECK`); değer §9'daki limitler sayfasıyla aynı kaynaktan | Şişme ve TOAST |
| Kanal ve sağlayıcı sözlükleri | Referans tablolarında veri (kanal yasal bayrakları, sağlayıcı durum kodu eşlemesi, kanal olay kanıt tablosu, sağlayıcı idempotency politikası, fiyat ve limitler) | Mevzuat ve sağlayıcı değişikliği kod dağıtımı beklemez |

**OP-2 — Mantıksal bildirim, teslim, deneme ve olay ayrı varlıklardır.**

| Varlık | Anlam | Not |
|---|---|---|
| Bildirim (`notifications`) | Bir tetiklemenin bir alıcıya mantıksal karşılığı | `UNIQUE (tenant_id, environment, dedup_key)`; partition'lanmaz (tekillik zamana bağlı olmamalı) |
| Teslim (`deliveries`) | Kanal × adres × sağlayıcı hedefi | Fallback yeni teslim açar ve öncekine bağlanır; aynı kanalda aynı bildirim için tek canlı teslim |
| Deneme (`delivery_attempts`) | Bir teslimin tek sağlayıcı çağrısı | Retry yeni teslim değil yeni denemedir |
| Teslim olayı (`delivery_events`) | Append-only defter; hakikat kaynağı | Durum bundan türetilir (OP-3) |
| Gelen sağlayıcı olayı makbuzu (`webhook_receipts`) | `(tenant, provider, provider_event_id)` tekilliği | Sağlayıcı tekrarları tek kez işlenir |

Engellenen hedef de teslim satırı açar ve neden koduyla görünür kalır (atlama kuyrukta değil teslim tablosunda kaydedilir). Diğer varlıklar ilgili bölümlerdedir: şablon ve sürümleri (§11; sürüm değişmez, teslim sürüme çivilidir), izin ve tercih (§13; ayrı kayıtlar), inbox öğesi ve sayaçları (§15), webhook teslimi (§16; `(endpoint_id, event_id)` tekilliği zamana bağlı olmayan ayrı tabloda), bekleme noktası ve posta kutusu (§17), digest penceresi (§10), bastırma listesi (§13), kullanım kayıtları (OP-38), denetim kaydı (§18), kill switch (§18), DLQ (§19).

**OP-3 — Teslim defteri değişmezdir; durum ondan yeniden kurulabilir.** `delivery_events` yalnız ekleme alır; `UPDATE` ve `DELETE` yoktur. Teslim durumu (iç modelin dört ekseni; §14) bu defterden türetilen bir projeksiyondur ve her zaman yeniden kurulabilir. Haftalık "defterden yeniden kur" testi projeksiyonu defterden yeniden hesaplar; fark çıkmaması gerekir (§20.7).

**OP-4 — Monotonluk koşullu güncellemeyle sağlanır; geç olay her zaman yazılır.** Projeksiyon güncellemesi `UPDATE … WHERE rank < $yeni … RETURNING` kalıbıyla yapılır; sıfır satır dönmesi "geç olay" demektir ve sayılır. Geç olay projeksiyonu geri almaz ama deftere her zaman yazılır. Olay indirgeme sırası: deneme numarası (eski denemenin geç olayı yeni denemeyi ezemez) → aynı sağlayıcı kapsamında sağlayıcı sıra numarası → gerçekleşme zamanı → alma zamanı. Olay zamanları geleceğe yazılamaz (`occurred_at ≤ received_at +` küçük tolerans).

**OP-5 — Sıra numarası ve cursor commit sırasına dayanır.** Inbox akışı, posta kutusu, olay akışı ve outbox okuyucuları için sıra numarası ID ya da insert sırasına değil commit sırasına dayanır. `id > son_id` biçiminde okuma yapılmaz (ID insert anında atanır, satır commit anında görünür; bu yöntem satır atlar). Doğru yöntem: durum sütunu + `SKIP LOCKED` ya da işlem anlık görüntüsü (xid8) tabanlı su çizgisi.

**OP-6 — Tekilleştirme katmanlarının deposu veritabanıdır.**
1. **İstek tekrarı:** `Idempotency-Key` deposu Postgres'tedir; kapsam `(tenant, environment, endpoint, key)`; `INSERT … ON CONFLICT DO NOTHING`; anahtar uzunluğu 8–255; süre 24 saat sabittir. Aynı anahtar + aynı gövde ilk yanıtın birebir aynısını (durum kodu dahil) `Idempotency-Replayed: true` ile döner; aynı anahtar + farklı gövde `422`; eşzamanlı ikinci istek `409`. Yalnız iş mantığı başlamış istekler önbelleğe alınır. Süresi dolan kayıt silinmez; yumuşak sona erer ve partition arşiviyle sıcak depodan çıkar (OP-15).
2. **Olay tekrarı:** `dedup_key` bildirim kaydında benzersizdir ve bildirim saklandığı sürece geçerlidir.
3. **Teslim tekrarı:** teslim defterinde `(notification_id, recipient, channel)` tekilliği; sağlayıcıya göndermeden önce yazılır.
4. **Sağlayıcı tekrarı:** sağlayıcı idempotency anahtarı mantıksal gönderim boyunca sabittir (§19 T-28).
Ürün davranışı §9 ve §10'dadır. Teslim defteri yazımı ücretli kanallarda (SMS, WhatsApp) gönderimden önce senkron yapılır; push'ta toplu yazım kabul edilebilir ve bu bilinçli bir maliyet takasıdır (push mükerrerinin maliyeti çok düşüktür).

---

### 20.2 Yazma yolları ve veritabanı rolleri

**OP-7 — Kabul yolu tek transaction'dır.** Sıra: idempotency kaydı → bildirim → teslimler → açılış olayları (defter) → kuyruk işi. Hepsi birlikte olur ya da hiçbiri olmaz; bu garanti kuyruğun aynı Postgres örneğinde olmasına dayanır. Kabul edilip kuyruğa girmeyen mesaj oluşamaz. Veritabanı dışına giden olayların (giden webhook, olay hedefleri) outbox'ı aynı transaction'da yazılır; teslim işi outbox satırından beslenir.

**OP-8 — Çekirdek tablolara yazma yalnız `SECURITY DEFINER` fonksiyonlarıyla yapılır.** Uygulama rolünün çekirdek tablolarda (bildirim, teslim, deneme, defter, makbuz, idempotency, bastırma, inbox, sayaçlar, bekleme noktası, posta kutusu, denetim kaydı, kill switch, kullanım kayıtları) doğrudan `INSERT`/`UPDATE` yetkisi yoktur; yazma, kuralları içinde taşıyan fonksiyonlarla yapılır (kabul, plan sabitleme, teslim açma, deneme açma, olay alma, bastırma ekleme/kaldırma, inbox işaretleme, bekleme çözme vb.). Fonksiyonlar sabit `search_path` ile tanımlanır, kapsamı (kiracı bağlamı) kendi içinde doğrular ve sonuç kodunu döner (ör. `created | replayed | in_progress | conflict`; `applied | duplicate_ignored | stale_ignored | conflict_flagged`). Fonksiyon imzaları API sözleşmesinin veritabanı yüzüdür ve şema testleriyle korunur.

**OP-9 — Veritabanı rolleri ayrıdır; kayıt tablolarında hiçbir uygulama ya da operasyon rolünün `DELETE`/`TRUNCATE` yetkisi yoktur.** Tek istisna iş kuyruğu tablolarıdır (OP-12).

| Rol | Yetki | Not |
|---|---|---|
| `relay_migrator` | Tablo sahibi; şema göçleri | Yalnız göç adımında kullanılır |
| `relay_app` | `SELECT` + yazma fonksiyonlarında `EXECUTE`; çekirdek dışı tablolarda kısıtlı `INSERT/UPDATE` | Superuser değil, `BYPASSRLS` yok, tablo sahibi değil (§18 TN-14) |
| `relay_queue` | Kuyruk şemasında kuyruk kütüphanesinin gerektirdiği yetkiler; tamamlanmış iş satırını temizleme yalnız bu şemada | OP-12; kuyruk şeması dışında `DELETE` yok |
| `relay_archive` | Partition ayırma, soğuk arşive aktarma, doğrulanmış arşiv kopyasından sonra ayrılmış tablonun sıcak depodan kaldırılması | Yalnız bakım görevi; OP-15 |
| `relay_report` | Salt okunur; rapor ve rollup okuma | Uzun sorgu sınırı ayrı (OP-11) |

`DELETE`, `TRUNCATE` ve veri taşıyan tablo için `DROP` uygulama ve operasyon yollarında yoktur; CI SQL lint'i bu ifadeleri reddeder (Access OP-73). Lint iki yeri ayrıca tanır: kuyruk şemasında `relay_queue`'nun tamamlanmış iş temizliği (OP-12) ve `relay_archive`'ın doğrulanmış arşiv taşımasındaki sıcak kopya kaldırması (OP-15). Silme bir durum geçişidir: durum + `deleted_at` + tombstone.

**OP-10 — Kritik yazmalar senkron replikasyonla onaylanır.** İzin, tercih, bastırma, denetim kaydı ve kill switch yazmaları senkron commit ile yapılır. Teslim defterinin toplu alımında daha gevşek commit modu ölçümle değerlendirilebilir; tersi yapılmaz.

**OP-11 — Sorgu ve işlem süreleri rol başına sınırlıdır.** `statement_timeout` rol başınadır (başlangıç: API 5 sn, işçi 30 sn, rapor 5 dk ⚠️); global ayar yapılmaz (göçleri kırar). `idle_in_transaction_session_timeout` ve `transaction_timeout` ayarlıdır. Sorgu istatistikleri açıktır ve en pahalı sorgular düzenli gözden geçirilir. Sık çalışan sorguların planı CI'da denetlenir.

**OP-12 — İş kuyruğu tablosu kayıt değil geçici çalışma listesidir; fiziksel silme yasağının tek istisnasıdır (Access OP-73 madde 7).** Kuyruk tablosu yalnız kimlik ve işletim durumu (zamanlama, deneme sayısı) taşır; kişisel veri taşımaz (§19 T-15). Kayıt ve kanıt Relay'in kendi tablolarındadır (OP-3, §18 TN-46); uyum kanıtı hiçbir zaman kuyruk tablosunda tutulmaz. Bir işin sonucu kalıcı kayda (teslim defteri, denetim kaydı) yazıldıktan sonra kuyruk satırı yalnız `relay_queue` rolüyle temizlenebilir; sonucu kalıcı kayda yazılmamış iş temizlenmez. İstisna yalnız kuyruk şemasındaki iş tablolarına uygulanır; kayıt tablolarına (bildirim, teslim, defter, outbox, bekleme noktası, posta kutusu, denetim, kullanım vb.) istisna yoktur.

---

### 20.3 Partition ve arşiv

**OP-13 — Partition bakımı tek mekanizmadır.** Partition'lar uygulama içindeki bakım görevi (tekil, DB liderlikli; §19 T-12) tarafından önceden oluşturulur. Dış partition aracı ve DEFAULT partition kullanılmaz. "En ileri partition sınırı < now + N gün" alarmı vardır (POLICY DEFAULT N = 3 gün, sayfalar). Partition aralıkları ve ön oluşturma ufku tablo başına veridir ve hacim ölçüldükten sonra kesinleşir.
- DEFAULT partition yasağının gerekçesi: her ekleme DEFAULT'u tam tarar, eş zamanlı ayırmayı yasaklar ve aralık dışı yazmayı sessizce yanlış yere koyar. DEFAULT olmadığında aralık dışı yazma gürültülü hata verir; iş bunu yakalar ve yeniden dener.
- Partition sınırları UTC ve açık ofsetle yazılır.

**OP-14 — Partition DDL'i kilitsiz yöntemle yapılır.**
1. Yeni partition bağımsız tablo olarak `LIKE … INCLUDING ALL` ile oluşturulur, eşleşen geçerli `CHECK` eklenir, sonra bağlanır (`ATTACH`); doğrudan `PARTITION OF` üst tabloda ağır kilit alır.
2. Bölümlenmiş tabloya indeks: üst tabloda `ON ONLY` ile geçersiz kabuk → partition başına eş zamanlı indeks → bağlama.
3. Depolama parametreleri (fillfactor, autovacuum, TOAST hedefi) her yaprak partition'a ayrıca uygulanır.
4. Üst tablo istatistikleri günlük güncellenir (autovacuum bölümlenmiş üst tabloyu analiz etmez).
5. Her partition DDL'inde kısa `lock_timeout` + `statement_timeout`; zaman aşımında ertesi çalışmaya ertelenir.
6. Toplu içe aktarma bağımsız tabloya `COPY` + geçerli `CHECK` + bağlama ile yapılır.

**OP-15 — Saklama sonu partition'ın soğuk arşive taşınmasıdır; veri imha edilmez.** Sıra: kayıtlar yumuşak silinir ve kişisel alanları crypto-shred edilir (OP-16) → partition `DETACH … CONCURRENTLY` ile ayrılır → açık biçimde (Parquet + şema) nesne deposundaki değiştirilemez (WORM) soğuk arşive aktarılır → arşiv kopyası satır sayısı ve özetle doğrulanır → sıcak depodaki ayrılmış tablo ancak doğrulamadan sonra ve yalnız `relay_archive` rolüyle kaldırılır. Arşiv taşıması budur: doğrulanmış WORM kopya + sıcak kopyanın arşiv rolüyle kaldırılması; veri arşivde kaldığı için bu imha sayılmaz (Access OP-73 madde 4). Doğrulama başarısızsa sıcak kopya kaldırılmaz ve taşıma bir sonraki çalışmada baştan yapılır. Ayrılmış tabloya kaldırılana kadar yalnız `relay_archive` rolü erişir, uygulama rolü erişemez. Aynı anda en fazla bir partition ayrılma sürecindedir; yarım kalan ayırma bir sonraki çalışmada tamamlanır. Soğuk arşiv nesne kilitlidir (WORM), erişimi denetlidir ve kendi bölgesindedir.

**OP-16 — Kiracı bazlı saklama satır silmeyle değil, yumuşak silme + crypto-shred ile uygulanır.** Bir partition, içindeki en uzun saklama süresine göre tutulur. Daha kısa saklama süresi olan kiracının satırları süre dolunca yumuşak silinir ve DEK'leri imha edilir; satır partition'la birlikte arşive gider. Kiracı × zaman iki seviyeli partition kullanılmaz (tablo sayısı ve planlama maliyeti patlar).

---

### 20.4 Saklama ve silme

**OP-17 — Relay, Access OP-73 ve Access OP-74'ü aynen uygular; süre ve dayanaklar Access Ek C'den gelir.** Fiziksel silme yoktur. Kişisel verinin silinmesi crypto-shredding'dir. Saklama sonu yumuşak silme + crypto-shred + soğuk arşive taşımadır (doğrulanmış WORM kopya, sonra sıcak kopyanın arşiv rolüyle kaldırılması; OP-15). Tek istisna yalnız kimlik taşıyan iş kuyruğu tablolarıdır (OP-12). Dava ve regülatör saklaması imhayı durdurur. Okunabilir çıkarma iki kişilik onay ve denetim kaydıyla yapılır ve 24 saat içinde tamamlanabilir olmalıdır. Şüpheli işlem bildirimine bağlı saklamalar talep sahibine açıklanmaz. İmha DEK'in bütün kopyalarını kapsar (önbellek, yedek, KMS/HSM yedeği). Şifreli artıklar arşivde kalır. Simetrik şifreleme AES-256 sınıfındadır.

**OP-18 — DEK kişi × saklama sınıfı başınadır; Relay sınıfları Access Ek C sınıflarına eşlenir.**

| Relay saklama sınıfı | İçerik | Access Ek C sınıfı |
|---|---|---|
| Alıcı profili ve iletişim adresleri | Abone kimliği, ad, e-posta, telefon, cihaz token'ları, yerel ayar, saat dilimi | `profile` |
| Bildirim içeriği | Render edilmiş içerik, olay verisi (veri yükü), inbox öğesi gövdesi | `profile` (içerik alt sınıfı; kiracı daha kısa süre seçebilir) |
| Teslim kayıtları | Teslim, deneme, teslim olayı defteri, sağlayıcı yanıtları | `message_log` |
| Ticari ileti onay ve gönderim kayıtları | Pazarlama izni kopyası ve kanıtı, ticari ileti gönderim/ret kayıtları, İYS senkron kayıtları | `consent`, `message_log` |
| Tercihler | Kategori × kanal tercihleri, sessiz saat, digest seçimi ve değişiklik geçmişi | `profile` |
| Denetim kaydı | Operatör ve yönetici eylemleri | `audit` |
| Trafik ve erişim logu | IP, port, oturum | `traffic` |
| Bastırma listesi | Bir daha gönderme kayıtları | `suppression` |

Silme talebinde yükümlülüğü olmayan sınıfların DEK'i hemen imha edilir; yükümlülüğü olan sınıflar kanuni saklamada kalır ve normal hiçbir işlemde (bildirim, pazarlama, arama, konsol) kullanılamaz.

**OP-19 — Ticari ileti onay ve gönderim kayıtları Türkiye'de 10 yıl saklanır.** Dayanak 6563 m.11/3 (7416 ile değişik); kanundaki süre yönetmelikteki daha kısa süreye baskındır. Süre kiracı saklama politikasının parametresidir; kiracı yalnız uzatabilir.

**OP-20 — Bastırma listesi anahtarlı özet olarak tutulur ve özne silmesinde imha edilmez.** Bastırma kaydı tanımlayıcının anahtarlı özetidir; yalnız bastırma kontrolü için kullanılır. Gerekçe: silinen kişinin adresi bir sonraki içe aktarmada yeniden gönderim almamalıdır (Access OP-74 madde 7).

**OP-21 — Denetim kaydının genel varsayılan saklaması 400 gündür.** Sektör şablonları uzatır (Access Ek C).

**OP-22 — Inbox saklama varsayılanları: görünür son 1.000 öğe, aktif 90 gün, arşiv 1 yıl.** Kiracı bu değerleri platform üst sınırları içinde değiştirir. Kullanıcı inbox öğesini yalnız arşivler ya da gizler; fiziksel silme hiçbir koşulda yoktur (§15).

**OP-23 — `security` sınıfının OTP ve doğrulama alt türlerinde render edilmiş içerik saklanmaz.** Yalnız içerik özeti ve şablon sürümü tutulur. Diğer sınıflarda mesaj başına `retention: none` bayrağı vardır; bayraklı mesajın render edilmiş içeriği teslimden sonra tutulmaz. İçerik saklamayan mesaj da teslim defterine ve kanıt alanlarına girer.

**OP-24 — Özne silmesi bekleyen her şeye uygulanır.** Özne bazlı silme API'si şunları kapsar: kuyruktaki işlerin bekleyen teslimleri, zamanlanmış gönderimler, tekrar kuralları, digest tamponları, bekleme noktalarındaki kişisel alanlar, inbox. Bekleyen teslimler `cancelled` + `rule_id` olur. Yasal saklama gereken kanıt ayrı ve en az veriyle tutulur. Silme talebi ve yanıtı ayrı saklama sınıfında kaydedilir (`dsr_log`, `erasure_log`).

**OP-25 — Kişisel veri kopyalarının kapsam listesi tutulur.** Aynı adres ya da token'ın bulunabileceği her yer (teslim satırı, digest tamponu, inbox, giden webhook gövdesi, DLQ, log, trace, analitik akış, soğuk arşiv) sütun sütun listelenir ve her yerin şifreleme ve imha kuralı yazılır. Kurallar: kuyruk argümanında kişisel veri yok; log ve trace'te kişisel veri yok; DLQ ve analitik akışlarında adres yerine kör indeks; giden webhook varsayılan olarak ince olaydır (§16). Kişisel alan taşıyan her tablo bu listede olmak zorundadır; olmayan tablo imha kapsamı testini kırar (§18 TN-16).

**OP-26 — Kiracı kapatma crypto-shred ile yapılır.** Kiracı kapatılınca kiracı veri anahtarları ve özne DEK'leri (kanuni saklama gerektirmeyenler) imha edilir; satırlar yumuşak silinmiş ve okunamaz olarak kalır, partition'larla arşive gider. Kapatma öncesinde kiracıya tam dışa aktarma (JSON/CSV/Parquet) sunulur. Kiracı ayrıca kişi bazlı dışa aktarma (bir alıcının gönderim geçmişi) yapabilir.

---

### 20.5 HA ve felaket kurtarma

**OP-27 — Postgres HA yönetilen HA ya da olgun bir operatörle kurulur.** Bulutta yönetilen HA tercih edilir; Kubernetes'te olgun bir Postgres operatörü kullanılır. Senkron replikasyon kuorumla yapılır (`ANY 1 (s1, s2)`); tek senkron yedek (`FIRST 1`) kullanılmaz (yedek çökünce commit'ler durabilir). Felaket kurtarma kopyası kiracının bölgesindedir; bölge dışına replikasyon yoktur (§18 TN-55). Zaman noktasına geri dönüş (PITR) yedekleri bölge içindedir. RPO ve RTO hedefleri POLICY DEFAULT'tur ve oyun gününde ölçülür.

**OP-28 — Failover mükerrere mal olabilir, kayba olamaz.** Failover sonrası yeniden çalışan işlerin mükerrer etkisi teslim defteri tekilliğiyle zararsızdır; zombi iş kurtarma eşiği kısa tutulur ve tekilliğe güvenilir. Salt okunur hataya düşen bağlantılar kesilip yeniden kurulur. Uygulama düzeyinde idempotency isteğe bağlı değildir: istemci, gerçekte commit olmuş bir işlemde zaman aşımı alabilir.

**OP-29 — Valkey kaybı veri kaybı değildir.** Valkey yeniden başlarsa ya da kaybolursa sinyaller yoklamaya, sayaçlar Postgres yedeğine düşer (§19 T-9); realtime istemciler cursor'larından kurtarır. Valkey için yedekleme gerekmez; HA isteğe bağlıdır.

**OP-30 — Bağlantı havuzlama kuralı.** `düğüm × havuz_boyutu × 2` (dağıtım örtüşmesi) `max_connections`'ın yaklaşık yarısının altındaysa havuzlayıcı kullanılmaz. Üstündeyse ya da düğümler otomatik ölçekleniyorsa işlem kipinde güncel bir PgBouncer kullanılır; yeni küçük sürümüne ilk geçen olunmaz. LISTEN/NOTIFY kullanılmadığı için (§19 T-10) işlem kipi havuzlama kısıt üretmez. Havuz bekleme hatası tasarım gereği yük atmadır; "havuzu büyüt" anlamına gelmez.

**OP-31 — Veritabanı sağlık alarmları.** Replikasyon slotu (`wal_status`, güvenli WAL boyutu, pasif slot), slotların WAL tutma üst sınırı, XID sarma uyarıları, arşivleyici hataları, disk (%70 uyarı, %85 sayfa), ölü satır oranı, indeks şişmesi, uzun açık işlemler ve geçersiz indeksler izlenir. WAL dizini elle silinmez. Kuyruk tablosunun ve en hızlı büyüyen defter tablolarının autovacuum ayarları yaprak partition başınadır ve ölçümle ayarlanır.

---

### 20.6 Gözlemlenebilirlik ve SLO

**OP-32 — Üç sinyal üç araçla taşınır.** Trace'ler OpenTelemetry ile; metrikler Prometheus biçiminde (kazıma); log'lar yapılandırılmış biçimde ve her satırda `trace_id`/`span_id` ile. Metrik ve log'u OTLP'ye taşımak gerekiyorsa dönüşüm toplayıcıda (Collector) yapılır; toplayıcı kardinalite sınırını uygular. Gözlem verisi kiracının bölgesinde kalır.

**OP-33 — Birincil sağlık metriği huni tamlığıdır; huninin otoritesi defterdir.**

| Aşama | Anlam |
|---|---|
| 1 `accepted` | API kabul etti |
| 2 `enqueued` | Kuyruğa girdi |
| 3 `dispatched` | Sağlayıcıya gönderildi |
| 4 `provider_accepted` | Sağlayıcı kabul etti |
| 5 `delivered` | Kanalın güvenilir teslim kanıtı geldi (kanal başına tanımlı; §14) |
| 6 `engaged` | Etkileşim (isteğe bağlı; insan/bot ayrımıyla) |

Kayıp ölçüleri: `accepted − enqueued` (sıfırdan büyükse veri kaybı; en ağır durum), `dispatched − provider_accepted − failed`, `provider_accepted − delivered − failed` (kanal başına açıklık). Push (APNs/FCM) için `delivered` iddia edilmez; huni 4. aşamada biter, istatistiksel tahmin ayrı gösterilir. Metrikler "sistem sağlıklı mı", trace'ler "bu mesaja ne oldu", defter "şu koşula uyan bütün mesajlara ne oldu" sorusunu cevaplar. Alıcı başına huni bir defter sorgusudur, metrik değildir.

**OP-34 — Trace bağlamı her sınırda açıkça taşınır.** `traceparent` teslim defterine ve iş meta verisine yazılır. Geç gelen sağlayıcı olayı uzun açık span ile değil, yeni trace'te kısa span + span bağlantısıyla gönderime bağlanır (uzun açık span sınırsız bellek ve örnekleme sorunları üretir). Bağlam her süreç, iş ve mesaj sınırında açıkça taşınır; çıplak görev başlatma CI'da reddedilir (§19 T-47). Span'ler kişisel veri taşımaz. OpenTelemetry'nin yanında uygulama düzeyinde korelasyon kimliği her log satırında, işte ve span'de bulunur.

**OP-35 — Metrik etiketlerinde kardinalite kuralı uygulanır.**
1. Temel etiket kümesi `channel × provider × status`'tur; ayrıntı exemplar (`trace_id`) ile taşınır.
2. Histogramlarda `tenant` etiketi yoktur.
3. Sayaçlarda `tenant` yalnız sınırlı boyutla: en yoğun N kiracı (POLICY DEFAULT 20) ayrı, kalanı `tenant="other"`.
4. Yasak etiketler: mesaj kimliği, kampanya kimliği, şablon kimliği, alıcı, kullanıcı, cihaz, token, ham hata metni (yalnız sınırlı hata kodu sözlüğü), ham süreç kimliği.
5. Yüksek kardinaliteli sorular defterden ya da kiracının analitik hedefinden cevaplanır.
6. Kiracı başına SLO, olay verisinden periyodik iş ile hesaplanır ve tabloya yazılır; Prometheus'a yalnız ihlal sayacı (`channel`, `severity`) gider.

**OP-36 — SLO tablosu mesaj sınıfı başına tektir; değerler ölçülene kadar POLICY DEFAULT'tur.**

| Sınıf (şerit) | SLI | Hedef |
|---|---|---|
| `security` (L0) | Kabulden sağlayıcı kabulüne süre eşiği altında kalan oran; sağlayıcı kabul oranı | PD; ölçümle |
| `transactional`, `action_required` (L1) | Aynı | PD; ölçümle |
| `operational`, `system`, `social` (L2) | Aynı | PD; ölçümle |
| `marketing` (L3) | Aynı; kampanya süre tahmini sapması | PD; ölçümle |
| API | `5xx` dışı yanıt oranı | PD; ölçümle |
| Giden webhook | İlk denemede teslim oranı; backlog yaşı | PD; ölçümle |

Kurallar:
1. Birincil erişilebilirlik SLO'su sağlayıcı kabulünü "iyi" sayar. Kabul sonrası teslim hatası sayfalamayan ayrı bilgilendirici SLO'dur. Gösterildi/açıldı hata bütçesine girmez.
2. Persentil yerine gecikme eşiği SLI'ı kullanılır ("isteklerin %X'i Y saniyede sağlayıcıya ulaşır").
3. Çok pencereli yanma oranı alarmları: 1 saat/5 dk ×14,4 (sayfa), 6 saat/30 dk ×6 (sayfa), 3 gün/6 saat ×1 (bilet).
4. SLO etiket kümesi `channel × provider`'dır.
5. Kabul temelli SLO yeşilken kullanıcılar hiçbir şey almıyor olabilir; bu yüzden ayrıca "kanıtlı teslim/kabul oranında bir saatte %40 düşüş" alarmı vardır (açıkça belirtilir).
6. Çelişen eski gecikme hedefleri spec'e taşınmaz; tek kaynak bu tablodur.

**OP-37 — Alarm hijyeni.**
1. Kuyruk alarmı derinliğe değil şerit başına en eski bekleyen işin yaşına bağlıdır.
2. Sağlayıcı alarmı ham hata oranına değil devre kesici durumuna bağlıdır ("APNs kesicisi 10 dakikadır açık").
3. Eşikler sınıf bazlıdır; `marketing` için gece sayfası yoktur.
4. Türetilmiş metrik kullanılır, ham metrik değil.
5. Sağlayıcının durum sayfası olay bildiriyorsa ilgili alarmlar tek bir "sağlayıcı olayı" alarmında birleşir.
6. Her alarm `runbook_url` taşır; CI bunu doğrular; runbook'suz sayfa yoktur.
7. Ek alarmlar: `rule_id` kırılımlı atlama oranında ani değişim (ör. izin eksikliği atlamalarının birden artması), bilinmeyen sağlayıcı kodu, sessiz saat ihlali > 0 (yasal), mükerrer teslim ve çakışma oranı, boş digest oranı, kampanya süresinin tahminin 1,5 katını aşması, ajan tarafında sessiz bekleme ve "yanıt oranı düşerken hacim artışı" (§17).
8. Uyandırma bütçesi izlenir: vardiya başına sayfa sayısı, gece sayfaları ve aksiyon gerektirmeyen sayfa oranı; aşım alarm gözden geçirmesini zorunlu kılar.

**OP-38 — Faturalama metrikten değil değişmez kullanım kayıtlarından yapılır.** `usage_records` günlük toplulaştırmayla `(tenant, environment, day, channel, provider)` başına idempotent yazılır ve değiştirilmez. Teslim kayıtları arşive gitse de kullanım kayıtları kalır. Ölçüm boyutları baştan kaydedilir: kanal, sağlayıcı, hedef ülke/operatör, SMS segment sayısı, WhatsApp konuşma kategorisi, sonuç, deneme sayısı. Kullanım kayıtları sağlayıcı faturasıyla mutabık kılınır; sapma uyarı üretir. `is_test` işaretli gönderimler faturada ve ürün metriklerinde ayrı satırdır.

**OP-39 — Analitik Postgres özet tablolarından ve kiracıya akıtılan olaylardan yapılır; Relay içinde OLAP yoktur.** Hazır raporlar Postgres rollup'larındandır: teslim hunisi, kanal ve sağlayıcı oranları, etkileşim (insan/bot ve `machine_open` ayrımıyla), A/B sonuçları, maliyet, atlama nedeni dağılımı. Bütün anlamsal olaylar kiracının hedefine (S3, Kafka, kuyruklar, webhook) sürekli akıtılabilir; ham veri CSV/Parquet olarak dışa aktarılabilir. ClickHouse vb. yalnız teslim hedefi olarak bağlanır. Rollup'lar `relay_report` rolüyle okunur ve OLTP havuzunu kullanmaz.

**OP-40 — "Neden almadım" ekranı ve operatör paneli.** Destek personeli telefon, e-posta ya da abone kimliğiyle bir alıcının son kararlarını (gönderilmeyenler dahil) `rule_id` ve sözlükten gelen tek cümleyle görür; hedef 30 saniyede cevap. PII maskelidir; "göster" denetlenir (§18 TN-21); toplu müşteri listesi çekilemez. Operatör panelindeki kuyruk araçlarının sayım sorgularının veritabanı yükü izlenir ve sınırlanır (§19 T-17).

---

### 20.7 Mutabakat ve bütünlük denetimleri

**OP-41 — Mutabakat dürüst kalır.** Mutabakat `delivered` ya da `failed` uydurmaz; kesin olay gelmemişse kanal başına tanımlı pencerelerle `unknown_pending` ve `unknown` kullanılır (§14). Geç gelen kesin olay her zaman kabul edilir ve yükseltir. Mutabakat "teslim edilmedi" derse otomatik yeniden gönderim yapılmaz; karar sınıfa göre insanındır ya da kiracınındır.

**OP-42 — Mutabakat ve denetim işleri.**

| İş | Sıklık | Ne yapar |
|---|---|---|
| Sağlayıcı olay tekilleştirme | Sürekli | `webhook_receipts` ile sağlayıcı olay kimliği tekilliği |
| Kanal mutabakatı | Kanal tablosunda veri; varsayılan ölçümle | Sağlayıcı durum API'si/raporlarıyla sayım karşılaştırması, boşlukları doldurma |
| Defterden yeniden kurma testi | Haftalık | Projeksiyon = defterden türetilen değer; fark sorgusu boş dönmeli (OP-3) |
| Yetim kayıt ve bileşik FK denetimi | Gecelik | `tenant_id IS NULL` yok, yetim yok, FK yerinde (§18 TN-16) |
| Inbox sayaç uzlaştırması | Gecelik | Yalnız sapan sayaçları düzeltir; sapma metriği üretir |
| Kullanım ↔ fatura | Dönemsel | OP-38 |
| İYS mutabakatı | En az saatlik + gerektiğinde tam senkron | §13 |
| Partition ufku | Her bakım çalışması | OP-13 |
| Denetim kaydı kontrol noktası | Beyan edilen aralık | Merkle kontrol noktası üretimi, imzası, dış yayını ve yayımlanmış kontrol noktalarının kayıtla karşılaştırılması (OP-63) |

**OP-63 — Denetim kaydının Merkle kontrol noktası tekil bir bakım işidir.** Kontrol noktası işi DB liderlikli tekil bakım görevidir (§19 T-12); son kontrol noktasından bu yana eklenen denetim kayıtlarını Merkle ağacına bağlar, kökü KMS'teki imza anahtarıyla imzalar ve kontrol noktasını yayın hedeflerine gönderir (§18 TN-46). Kurallar:
1. Kontrol noktası aralığı dışarıya beyan edilen bir parametredir (en uzun birleştirme gecikmesi); değeri Access identity denetim kaydının beyanıyla aynı tutulur (Access OP-38). Beyan aşımı güvenlik olayıdır ve sayfalar.
2. Yayın hedeflerinden en az biri Relay işletiminden bağımsızdır (nesne kilitli depo ya da müşteri hedefi); yalnız Relay veritabanında duran kontrol noktası bütünlük iddiası sayılmaz.
3. Doğrulama işi yayımlanmış kontrol noktalarını veritabanındaki kayıtlardan yeniden hesaplanan köklerle karşılaştırır; uyuşmazlık güvenlik olayıdır.
4. Kontrol noktası biçimi ve kapsama kanıtı Access ile aynıdır; aynı doğrulayıcı iki ürünün kontrol noktalarını ve tek kaydın kapsama kanıtını doğrular.

---

### 20.8 Runbook ve olay müdahalesi

**OP-43 — Runbook disiplini.**
1. Her runbook altı zorunlu bölüm taşır: semptom, etki (patlama yarıçapı), teşhis (kopyala-yapıştır komutlar + "ne görüyorsan ne demektir"), karar ağacı, azaltma, kalıcı düzeltme + eskalasyon. Boş bölüm atlanmaz, "bilinmiyor" yazılır.
2. Öncelik: kanamayı durdur, hizmeti geri getir, kanıtı koru. Azaltma kök nedenden önce gelir.
3. Makine okunur başlık bloğu: kimlik, şiddet, etkilenen kanal ve kiracı kapsamı, alarm adı, son test tarihi, otomasyon düzeyi, tahmini azaltma süresi, geri alınabilirlik.
4. Son testi 6 aydan eski runbook "güvenilmez" işaretlenir ve CI'ı kırar; son test yalnız oyun gününde ya da gerçek olayda güncellenir.
5. Komutlar kopyala-yapıştır çalışır; durum değiştiren blok ayrı işaretlenir ve tek komut içerir.
6. Karar ağaçları diff'lenebilir metin diyagramıyla yazılır.
7. Runbook'lar depoda sürümlüdür; nöbetçi için çevrimdışı kopyası düzenli üretilir.

**OP-44 — Azaltma adımları tek düğmeli operatör eylemleridir.** Her azaltma adımı bir operatör API ucu ya da CLI komutudur: test edilebilir, denetim kaydı üretir ve idempotent'tir (stresli operatör iki kez çalıştırır). Otomasyon merdiveni: 0 serbest metin (kabul edilmez), 1 kopyala-yapıştır, 2 tek düğme (hedef), 3 alarm tetikli insan onaylı, 4 tam otomatik + sonradan bildirim. Otomasyona dönüştürme koşulları: karar ağacı yalnız makine gözlemlenebilir sinyale dayanır, eylem geri alınabilir ve sınırlıdır, ayda en az iki kez tetiklenir. Geri alınamaz eylemler (gönderim, token devre dışı bırakma, toplu iptal), uyum bağlamı isteyen kararlar ve sağlayıcı itibarı otomatik açılmaz: otomatik durdurma olabilir, otomatik yeniden açma asla. Ölü token temizliği (yumuşak devre dışı bırakma) üst sınır parametresi olmadan çalışmaz.

**OP-45 — Tek şiddet taksonomisi: mesaj sınıfı × etki genişliği × geri alınabilirlik + değiştiriciler.**

| Şiddet | Tanım (örnekler) | Yanıt |
|---|---|---|
| SEV1 | `security`, `transactional` ya da `action_required` herhangi bir kanalda/kiracıda gönderilemiyor; kabul edilip kaybolan mesaj; uyum ihlali (izinsiz ticari ileti, İYS süre aşımı); kişisel veri sızıntısı ya da yanlış alıcıya içerik; sağlayıcı hesabı askıya alındı; SLO yeşilken kullanıcılar hiçbir şey almıyor | Anında sayfa, gece dahil; olay komutanı zorunlu |
| SEV2 | `marketing` durdu; bir kanal tamamen çalışmıyor ama fallback var; huni açığı eşiği aştı; itibar metriği eşiğe yakın; tek büyük kiracı ciddi etkilendi | Sayfa (mesai dışı dahil, sınıf eşiğine göre) |
| SEV3 | Tek kiracı, fallback çalışıyor; kademeli tükenme (disk, kota); tek webhook ucu ölü | Bilet, sonraki iş günü |
| SEV4 | Gözlem eksiği, runbook güncelliği, teknik borç | Plan |

Değiştiriciler: geri alınamaz bir şey olduysa +1; uyum veya hukuki maruziyet en az SEV1; yayılıyorsa +1; `security` sınıfı etkilendiyse +1; bilinen tepe döneminde +1; fallback çalışıyorsa −1; tek ve küçük kiracı −1; sağlayıcı olayı (bizde aksiyon yok) şiddeti düşürmez, eskalasyon yolu değişir. Yanıt süresi hedefleri POLICY DEFAULT'tur. Başka bir şiddet tablosu kullanılmaz.

**OP-46 — Olay ilanı, roller ve postmortem.**
1. Olay erken ilan edilir. İlan soruları: kullanıcı etkisi var mı, ikinci bir ekip gerekiyor mu, bir saat içinde çözülemeyecek mi, geri alınamaz bir şey oldu mu, bir sağlayıcı hesabı risk altında mı.
2. Roller: olay komutanı, operasyon sorumlusu, iletişim sorumlusu, uyum sorumlusu (uyum değiştiricisi tetiklenince). Olay komutanı kendisi düzeltme yapmaz; rol devri prosedürün parçasıdır.
3. Müşteri bildirimi Relay'den geçmez (OP-48); SEV1'de ilk bildirim hedefi POLICY DEFAULT'tur (başlangıç 30 dk); içerik: ne olduğu (tahmin değil), mesaj sınıfı bazında etki, geri alınamazlık açıkça.
4. Postmortem suçlamasızdır ve şu olaylarda zorunludur: her SEV1, iki saati aşan SEV2, tekrar eden SEV3, geri alınamaz bir şeyin olduğu ve kill switch açılan her olay. Şablon: sayılarla etki (sınıf bazında gönderilemeyen, yanlış gönderilen, etkilenen kiracı ve alıcı, kaybedilen izin, itibar etkisi), UTC zaman çizelgesi, tespit süresi ve alarmın neden çalmadığı, nedenler, iyi/kötü/şans eseri kötü gitmeyen, aksiyon maddeleri (önle/tespit et/azalt; sahip, tarih), runbook etkisi. Aksiyon maddeleri kapanmadan postmortem tamamlanmış sayılmaz.
5. Nöbet devri yazılı ve şablonludur; aktif kill switch'ler devirde canlı komutla okunur (listeye güvenilmez).

**OP-47 — Toplu yanlış gönderimde önce durdurulur, sonra düşünülür.** İki adım sırayla: ilgili kapsamda kill switch + bekleyen işlerin bekletilmesi; hedef 60 saniyenin altındadır. Yeniden açma yönetsel karardır ve kontrol listesi ister: kök neden düzeltildi, test ortamında doğrulandı, etkilenenler tekrar almayacak, gerekiyorsa hukuk onayı, kademeli açılış (%1 → %10 → %100). Yanlış gönderimden sonra aynı kitleye otomatik "özür" mesajı gönderilmez. Şablon değişkeninin yanlış eşlenmesiyle başka kişinin verisinin gönderilmesi kişisel veri ihlali karar noktasıdır ve bildirim değerlendirmesi başlatır. Kampanya güvenlikleri: rastgele örnek alıcılarla render önizlemesi ve onay, kitle beklenenin çok üstündeyse insan onayı, büyük kampanyada küçük yüzdeyle başlangıç (§10'daki kampanya kuralları).

**OP-48 — Relay kendine bağımlı değildir.** Relay'in kendi olay bildirimi ve nöbet sayfalaması Relay'den geçmez. Müşteri bildirimi statik, ayrı barındırılan bir durum sayfası (birincil) ve ayrı bir e-posta hesabı/itibar havuzu (ikincil) ile yapılır; panel içi banner güvenilir yol sayılmaz. Nöbetçiyi uyandıran mekanizma Relay dışında, bağımsız bir sağlayıcıdadır; o sağlayıcının durum sayfası izlenir. Uyandırma yolunda SMS birincil olamaz; mobil push ve sesli arama önce gelir; yol operatör bazında gece testiyle doğrulanmadan seçilmez. Runbook'lar Relay altyapısına bağımlı olmadan erişilebilirdir. Self-host kurulumlar için aynı kural belgede yazılıdır.

**OP-49 — Oyun günü ve kaos.** Senaryolar dört ailededir: (A) sağlayıcı hatası enjeksiyonu (kimlik hatası, eşzamanlı akış tükenmesi, kota 429, bounce oranı artışı, şablon duraklatma, gecikmeli teslim raporu); (B) uyum (İYS çekmenin durması, uyum lint'inin kaldırılması, yasal altbilgisiz şablon); (C) altyapı (dağıtıcı sürecin öldürülmesi → mükerrer 0, Postgres failover → kayıp 0, Valkey yeniden başlatma → yoklama ve yedek limitleyici, veritabanı havuzu doygunluğu → kabul katmanı `503`, kabul edilip kuyruğa girmeyen 0); (D) insan ve prosedür (runbook'suz teşhis, kill switch tatbikatı ve yayılım süresi, toplu yanlış gönderim tatbikatı, rol devri, bağımsız bildirim yolu testi, uyandırma testi). Her senaryo hipotez, ölçülen çıktı ve kabul kriteri taşır; ölçülen tek şey süredir. Hata enjeksiyonu kill switch altyapısını yeniden kullanır; oran ve TTL zorunludur ve yalnız üretim dışı ortamda ya da açıkça açılmış kaos kipinde çalışır. Her yeni runbook belirli bir süre içinde bir kez oyun gününden geçer; ritim POLICY DEFAULT'tur.

**OP-50 — Kapasite olayları sırayla ele alınır.** Sıra: sağlayıcı kapasitesi → kuyruk limiti → düğüm sayısı → veritabanı (veritabanı darboğazında düğüm eklemek işe yaramaz). Beklenmedik yükte üç ayrım yapılır: gerçek talep (dağınık; ölçekle), kötüye kullanım (tek kiracı ya da anahtar baskın; kiracı bazlı limit, canary ya da kill switch), retry fırtınası (kabul normal, retry oranı yüksek; yavaşla, ölçekleme). Bilinen tepe (kampanya günü, bayram, ay sonu) bir projedir: önceden sağlayıcı kota artırımı, şablon onayları, yük testi, kill switch tatbikatı ve değişiklik dondurma planlanır.

---

### 20.9 Göç ve yayılım

#### 20.9.1 Gönderim modları

**OP-51 — Gönderim modu birinci sınıf bir kavramdır: `live | shadow | dry_run | off`.**

| Mod | Davranış |
|---|---|
| `live` | Normal gönderim |
| `shadow` | Bütün hat (hız limiti, eşzamanlılık, dilimleme dahil) gerçekten çalışır; son adımda sağlayıcıya gönderilmez ya da yalnız doğrulama ucuna gider; karar ve içerik özeti karşılaştırma için kaydedilir |
| `dry_run` | Politika kafesi ve render çalışır; kuyruk ve gönderim yoktur; sonuç senkron döner (önizleme/test uçları; §9) |
| `off` | Kabul edilir, gönderilmez; `skipped` + `send_mode_off` ile kaydedilir. Acil durdurma kill switch'tir (§18); `off` onun yerine kullanılmaz |

Mod sevk sınırında uygulanır, kuyrukta değil: kuyruk davranışları gölgede de gerçek çalışmalıdır. Çözüm sırası: istekteki açık mod (yalnız test düzleminde ve önizleme uçlarında; canlı gönderim isteğinde reddedilir) → `(tenant, category, channel)` → `(tenant, channel)` → `(tenant)` → kurulum varsayılanı. Mod değişikliği denetim kaydına girer.

**OP-52 — Gölge mod kuralları.**
1. Sağlayıcı sınırı: sağlayıcının resmî doğrulama kipi varsa o kullanılır (ör. FCM `validate_only`); yoksa sağlayıcıya gidilmez ve yerel doğrulama yapılır (SMS segment/kodlama, WhatsApp şablon adı/parametre/dil). Giden webhook yalnız kiracı ayrı bir gölge uç verdiyse gönderilir. İYS API'sine gidilmez; yerel İYS kopyası sorgulanır.
2. Gölge modda kullanıcıya her zaman mevcut sistemin sonucu döner; Relay'in hatası kullanıcıyı etkilemez.
3. Gölge açılmadan önce "kasıtlı davranış farkları" listesi yazılır; her yok sayma kuralı sahipli, gerekçeli ve son kullanma tarihlidir; yok sayma listesinin boyutu bir metriktir.
4. Karşılaştırma katmanları: karar (alıcı kümesi, kanal kararı, izin ve bastırma kararı, sessiz saat/frekans/throttle, `dedup_key`, zamanlama) %100 karşılaştırılır; içerik kanonikleştirilmiş özetle (takip pikseli, imzalı bağlantı, tek kullanımlık belirteç, zaman damgası, kimlik maskelenir; para/tarih biçim farkı maskelenmez); yönlendirme (sağlayıcı, gönderici kimliği); performans.
5. Gölge karşılaştırma verisi maskelenmiş ve özetlenmiş değerlerle tutulur; kendi saklama sınıfındadır, kısa azami süreyle (POLICY DEFAULT 14 gün) crypto-shred edilir.
6. Gölgeden çıkış kriterinin birimi süre değil kapsamadır: her aktif (şablon × dil × kanal) birleşimi yeterli sayıda görülmüş, en az iki tam iş döngüsü geçmiş, açıklanamayan karar farkı sıfır olmalıdır. Eşikler POLICY DEFAULT'tur.
7. Gölge mod "uyum"u ölçer, "doğruluk"u değil: teslim oranı, sağlayıcı reddi, bounce/şikâyet, kullanıcı tepkisi ve yük altındaki gecikme gölgede ölçülemez; bu belgede açıkça yazılır.

#### 20.9.2 Kademeli yayılım

**OP-53 — Trafik bölmesi kullanıcıya yapışkan ve deterministiktir.** Bölme birimi her zaman kullanıcıdır: `kova = özet(tenant, external_id) mod 10.000`; rastgele bölme yasaktır. Yönlendirme sırası: acil durdurma → sabit Relay listesi → sabit eski sistem listesi → etkin kategoriler → `kova < yayılım_bp[kategori]` → eski sistem. Kategori ve kanal yalnız olgunluk kapısıdır; kanal ekseninde bölme fallback zincirini, kategori ekseninde bölme frekans ve digest'i bozar. Yapılandırma değişikliği bütün düğümlere ≤ 60 sn'de yayılır. Geri alma, yayılım oranını düşürmek ya da acil durdurmadır; hedef 60 saniye, dağıtım değil. Acil durdurma tek kişinin tek komutudur ve otomatik olay kaydı açar. Rampa adımı önceki adımın en fazla 5 katı ve en az bir tam gündür; alt sınır %1'dir. Müdahale kademelidir: uyarı / dondur / geri al / acil durdurma. Eşikler (mükerrer oranı, izinsiz ya da bastırılmış alıcıya gönderim — mutlak sayıyla, tek örnek bile acil —, kuyruk birikimi, `5xx`, kanal bazlı kabul ve teslim düşüşü) POLICY DEFAULT'tur.

**OP-54 — Çift gönderim kaza değil ihlaldir.** Göç ve yayılım boyunca aynı bildirimin iki sistemden gitmesi engellenir: iki sistem aynı kuraldan aynı tekilleştirme anahtarını üretir ve paylaşılan bir tekillik deposunu kullanır; istemci tarafında tek bildirim gösterme noktası kalır (eski SDK'nın bildirim kodu kaldırılır). Çift yazım tek yazma + outbox ile yapılır; aynı istekte ardışık iki yazma (kısmi başarısızlıkta sessiz ayrışma) yapılmaz. Mükerrer oranı sunucu tarafında ölçülemez; istemci telemetrisi (yalnız özet, içerik yok) ile ölçülür.

#### 20.9.3 Başka sistemden Relay'e geçiş

**OP-55 — İçe aktarma veri kuralları.**
1. Kimlik bağlamına dokunulmaz: uygulama paket kimliği, Apple takımı, Firebase projesi, WhatsApp işletme hesabı, SMS başlığı ve gönderen alan adı aynı kalır; yalnız adres defteri taşınır. Çift çalışma penceresinde ayrı APNs anahtarı kullanılır.
2. Sıra: bastırma listesi + izin/ret → token ve adresler → bastırmayı adreslere uygula ve sayıyı doğrula → ancak sonra gönderim modu.
3. İzin eşlemesi asimetriktir: herhangi bir kaynakta ret varsa ret; izin ancak doğrulanabiliyorsa izin (Türkiye'de İYS'de kayıtlı). Bilinmeyen tercih `false` ya da `true` uydurulmaz; köken alanında "göçle gelen, bilinmiyor" olarak işaretlenir.
4. Token göçü önce taşır, taşıyamadığını yeniden kaydettirir. Token'ın son görülme zamanı kaynakta yoksa boş bırakılır ve ayrı "göç zamanı" yazılır. `(token, platform)` benzersizdir; çakışmada en yeni görülme kazanır. Ölü token temizliği göçten önce yapılır.
5. Kimlik çakışmalarında otomatik birleştirme yoktur (aynı e-posta/telefon, iki dış kimlik → rapor); aynı dış kimlik birleştirilir; dış kimliği olmayan cihaz anonim abonedir.
6. Sağlayıcı iç kimlikleri hiçbir zaman birincil anahtar olmaz; yalnız izlenebilirlik için ayrı alanda tutulur.
7. Telefonlar E.164'e, diller BCP 47'ye normalize edilir; karakter kodlama bozulmaları taranır; geçersiz kayıtlar ayrı kovaya alınır.
8. Geçmiş teslim verisinden yalnız frekans, tekilleştirme ve digest için gereken yakın dönem taşınır; geri kalanı kiracının arşivinde kalır.
9. Şablon dönüştürme sözdizimi ağacı tabanlıdır, düzenli ifadeyle yapılmaz ve tahmin etmez (`AUTO_OK | NEEDS_REVIEW | CANNOT`); değişken adları için geçici, son kullanma tarihli takma ad katmanı kullanılabilir; şablon içi HTTP çağrısı taşınmaz.
10. İçe aktarma bir veri işleme faaliyetidir; kiracının işleyen sözleşmesi ve yurt dışı aktarım değerlendirmesi kiracının işidir, Relay gerekli meta veriyi (§18 TN-58) sağlar.

**OP-56 — Kesme ve zamanlanmış işlerin devri.** Kesme yeni iş kabulünü çevirir; uçuştaki işler eski sistemde boşalır; iki sistem aynı işi devralmaz. Zamanlanmış işlerde tercih sırası: eski sistemde iptal + Relay'de yeniden üretim > Relay'e devir (önce ekle, sonra iptal; kayıp mükerrerden kötüdür) > eski sistemin boşaltması; planlama, en uzak zamanlama ufku kadar önce dondurulur. Açık digest penceresi olan kullanıcı pencere kapanana kadar geçirilmez. Cron devri atomiktir: iki sistemde aynı anda etkin cron hiçbir an olmaz; durum (son çalışma, sonraki çalışma, cursor) devredilir ve ilk çalışma gözetimli `dry_run`'dır. Sağlayıcı teslim raporu ve bounce pencereleri boyunca eski sistemin webhook alıcısı açık kalır. Eski sistem bir süre sıcak yedek olarak tutulur; bu sürenin değeri kiracının kararıdır, rehberde önerilir.

#### 20.9.4 Şema değişikliği

**OP-57 — Şema değişikliği sıfır kesintilidir.**
1. Göçler genişlet-daralt (expand-contract) düzenindedir; bir sürüm hem eski hem yeni şemayla çalışır.
2. Oturum düzeyinde kısa `lock_timeout` (başlangıç 3 sn) + yeniden deneme; `statement_timeout ≥ lock_timeout` kullanılmaz. Gerekçe: bekleyen ağır kilit talebi arkasındaki bütün okumaları durdurur.
3. `NOT NULL`, `CHECK` ve FK `NOT VALID` + `VALIDATE` ile iki adımda eklenir; indeksler eş zamanlı (`CONCURRENTLY`) ve ayrı göç dosyasında kurulur; varsayılansız ya da değişmez varsayılanlı sütun ekleme güvenlidir; yeniden yazma gerektiren tip değişikliği beş adımlı yolla yapılır.
4. Bölümlenmiş tabloya sütun ekleme her partition'da kilit alır; düşük trafikli saatte yapılır.
5. CI geçersiz indeks ve genel plan kullanımı kontrolü yapar; göçler üretim şeklinde veriyle gecelik tekrar edilir.
6. Kuyruk kütüphanesinin şema göçü uygulama kodundan önce çalışır (genişlet-daralt'ın belgelenmiş istisnası); sürümü sabittir.
7. Commitlenmiş göç değiştirilmez; düzeltme yeni göçtür.

---

### 20.10 Bölge kurulumu

**OP-58 — Her bölge aynı paketle, aynı adımlarla kurulur.**
1. Bölgenin kendi Postgres'i (HA, PITR, bölge içi DR), Valkey'i ve KMS/HSM'i kurulur; hiçbiri başka bölgeyle paylaşılmaz.
2. Türkiye bölgesi yurt içi veri merkezinde ya da yerli bulutta kurulur; yedekler, anahtar yedekleri ve gözlem verisi de yurt içindedir (§18 TN-56).
3. Bölgenin sağlayıcı kataloğu veri yerleşimi meta verisiyle doldurulur (§18 TN-58); bölge için varsayılan sağlayıcılar bölge içi işleme yapanlar arasından seçilir.
4. Ön katman (CDN/WAF/DDoS) bölgenin kuralına göre seçilir (OP-59).
5. Bölgenin keşif ucu ve Access bağlantı ayarı aynı bölgedeki Access kurulumunu gösterir (§18 TN-57).
6. Durum sayfası, nöbet sayfalaması ve işletim e-postası bölgeden ve Relay'den bağımsızdır (OP-48).
7. Bölge kabul testi: kiracı yalıtım testleri, kill switch yayılım tatbikatı, failover tatbikatı, arşiv ve geri yükleme tatbikatı ve uçtan uca gölge gönderim.
Bölgelerin açılış sırası yapım sırasında belirlenir.

**OP-59 — Ön katman kuralı.** CDN/WAF/DDoS ön katmanı isteğe bağlıdır ve bölgenin veri yerleşimi kurallarına uyar. Regüle Türkiye kiracılarında TLS yurt dışında sonlandırılmaz: ya yurt içi ön katman sağlayıcısı kullanılır ya da TLS'i açmayan TCP geçişi yapılır. TLS'i açan ön katman, istek içeriğini (kişisel veri dahil) gördüğü için veri işleyen sayılır ve bölge kuralına tabidir. Ön katman kullanıldığında da sağlayıcı webhook'larının imza doğrulaması uygulamadadır (ön katman doğrulamanın yerini tutmaz).

**OP-60 — Edge çalışma ortamları kapsam dışıdır.** Relay Cloudflare Workers gibi edge çalışma ortamlarında çalışmaz. Gerekçe: kalıcı bağlantılar, Postgres transaction'ı, uzun ömürlü HTTP/2 sağlayıcı bağlantıları ve veri yerleşimi kuralları edge modeliyle uyuşmaz.

---

### 20.11 Kapasite

**OP-61 — Kapasite varsayımları ölçülene kadar ENGINEERING ASSUMPTION'dır.**

| Varsayım | Değer | Kural |
|---|---|---|
| Düğüm başına iş verimi | Düşük binler/sn, Postgres'e bağlı ⚠️ | Darboğaz sağlayıcı ve veritabanıdır; ölçümle kesinleşir |
| Teslim başına defter olayı | ~3 ⚠️ | Partition aralığı ve depolama bütçesi buna göre |
| Teslim başına kuyruk işi | ~1,2 ⚠️ | Kuyruk tablosu boyutu ve WAL bütçesi buna göre |
| Postgres tek anahtar GCRA verimi | 2–5k op/sn ⚠️ | Valkey birincil olduğu için yalnız yedek yolda; yedek yolda kaba sınırlamaya izin verilir |
| Hedef kullanım oranı | 0,7 | §19 T-35 |
| 10M push gönderimi | Sağlayıcı kotasıyla sınırlı, dakikalar ⚠️ | "Anında" iddia edilmez |

Tek birincil veritabanı yetmediğinde kaçış sırası: indeks ve şişme düzeltmesi → kuyruk tablosu ayarları → okuma yükünü rapor rolüne/replikaya taşıma → kiracıya göre ayrı kurulum. Kuyruk tablosunu ayrı veritabanına taşımak işlemsel insert garantisini bozar ve gerçek outbox gerektirir; bu ancak ölçümle ve ayrı kararla yapılır.

---

### 20.12 Self-host işletimi

**OP-62 — Self-host aynı paketle, belgelenmiş işletim yüzeyiyle gelir.**
1. Resmî `docker compose` dosyası tek komutla bütün bileşenleri (Postgres, Valkey, Relay rolleri) kaldırır; üretim için Kubernetes kurulum belgesi vardır. Sağlayıcı bağlantıları dosya ya da ortam değişkeniyle, sırlar yalnız referansla verilir (§18 TN-26).
2. Hesap gerektirmeyen kanallar çekirdekte çalışır: genel SMTP, Web Push (VAPID), in-app/realtime. Diğer kanallar kurumun kendi sağlayıcı hesabıyla (BYO) çalışır; APNs'siz iOS push yolu olmadığı belgelenir.
3. Self-host kuran her özelliği alır (kill switch, inbox, webhook yeniden oynatma, tercih merkezi, SSO/RBAC'li panel, aktivite takibi, ajan özellikleri). SaaS'ın ek değeri hizmettir: paylaşılan sağlayıcı hesapları ve hazır gönderici itibarı, çok bölgeli işletim ve SLA, yönetilen İYS bağlantısı, yedekleme, güncelleme ve nöbet.
4. Self-host belgeleri bu bölümün kurallarını kurumun kendi işletmesi için verir: yedekleme ve geri yükleme, partition bakımı alarmı, sürüm yükseltme (göç adımı, genişlet-daralt), kill switch erişim yolları, bağımsız olay bildirim yolu (OP-48) ve runbook seti.

---

### 20.13 Kapsam dışı

| Konu | Gerekçe |
|---|---|
| Relay içinde OLAP motoru | Analitik Postgres rollup'ları ve kiracı hedefine akışla (OP-39) |
| Kiracı başına şema ya da veritabanı | Pool modeli (§18 TN-11) |
| Bölgeler arası replikasyon | Veri yerleşimi (§18 TN-55) |
| Edge çalışma ortamı | OP-60 |
| Fiziksel silme | Access OP-73 |

---

### 20.14 OP karar register'ı (OP-1–OP-63)

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| OP-1 | Kimlik ve tip kuralları: uuidv7 (`created_at` ile sıralama), yalnız `timestamptz`/UTC, `AT TIME ZONE` lint yasağı, `bigint` mikro para, `ENUM` yok, E.164, normalize e-posta, HMAC kör indeks, `bigint` sayaç, `jsonb` kuralı, yük tavanı, sözlükler veri | FROZEN (teknik) | Tek tzdata kaynağı; kiracılar arası sayaç sızıntısı yok |
| OP-2 | Bildirim, teslim, deneme, olay ayrı; bildirim partition'sız ve `dedup_key` benzersiz; engellenen hedef de satır açar | FROZEN (teknik) | Rakiplerin hepsi tetikleme/teslim ayrımı yapar; atlama görünür kalır |
| OP-3 | Teslim defteri append-only; durum projeksiyon; haftalık yeniden kurma testi | KANONİK DEĞİŞMEZ | İç model değişse de dış sözleşme sabit kalır |
| OP-4 | Monotonluk koşullu `UPDATE`; geç olay daima defterde; indirgeme sırası; gelecek zamanlı olay yok | KANONİK DEĞİŞMEZ | Sırasız ve çift sağlayıcı olayları |
| OP-5 | Sıra numarası ve cursor commit sırasına dayanır; `id > son_id` yok | KANONİK DEĞİŞMEZ | Commit sırası ≠ ID sırası; outbox atlama tuzağı |
| OP-6 | Tekilleştirme depoları DB'de; Idempotency-Key kapsamı, 8–255, 24 saat, birebir replay + başlık, 422/409; teslim defteri ücretli kanalda senkron | FROZEN (teknik) | Stripe kalıbı; Idempotency-Key "yaygın pratik" (taslak süresi doldu) |
| OP-7 | Kabul yolu tek transaction; dış olay outbox'ı aynı transaction'da | KANONİK DEĞİŞMEZ | Kabul edilip kuyruğa girmeyen mesaj sıfır |
| OP-8 | Çekirdek tablolara yazma yalnız `SECURITY DEFINER` fonksiyonlarıyla; sabit `search_path`; sonuç kodları | FROZEN (teknik) | Kurallar tek yerde; uygulama rolü kuralı atlayamaz |
| OP-9 | Roller: migrator, app, queue, archive, report; kayıt tablolarında hiçbirinde `DELETE`/`TRUNCATE`; istisnalar yalnız kuyruk temizliği (OP-12) ve arşiv taşımasında sıcak kopya kaldırma (OP-15); CI lint | FROZEN (teknik) | Access OP-73 |
| OP-10 | İzin, tercih, bastırma, denetim, kill switch yazmaları senkron commit | FROZEN (teknik) | Hukuki kanıt ve güvenlik durumu kaybolamaz |
| OP-11 | `statement_timeout` rol başına; işlem süre sınırları; plan denetimi | POLICY DEFAULT | Global zaman aşımı göçleri kırar |
| OP-12 | İş kuyruğu tablosu geçici çalışma listesidir: yalnız kimlik taşır, kişisel veri ve kanıt taşımaz; iş sonucu kalıcı kayda yazıldıktan sonra satır yalnız `relay_queue` rolüyle temizlenebilir; fiziksel silme yasağının tek istisnası, kayıt tablolarına uygulanmaz | FROZEN (teknik) | Access OP-73 madde 7 |
| OP-13 | Partition bakımı uygulama içi tek mekanizma; DEFAULT yok; ufuk alarmı (3 gün); aralıklar veri; UTC sınır | FROZEN (teknik) · PD (ufuk, aralık) | 2026'da partition oluşturma kodu olmayan sistemlerde tam yazma reddi kesintileri |
| OP-14 | Kilitsiz partition DDL'i (bağımsız tablo + CHECK + ATTACH; `ON ONLY` indeks; yaprak parametreleri; günlük analiz; kısa kilit süreleri) | FROZEN (teknik) | `PARTITION OF` üst tabloda ağır kilit alır |
| OP-15 | Saklama sonu: yumuşak silme + crypto-shred → DETACH CONCURRENTLY → Parquet soğuk arşiv (WORM, bölge içi) → doğrulama → sıcak kopya yalnız doğrulamadan sonra ve `relay_archive` rolüyle kaldırılır; veri imha edilmez | FROZEN (teknik) | Access OP-13(b), Access OP-73 madde 4 |
| OP-16 | Kiracı bazlı saklama yumuşak silme + crypto-shred ile; kiracı × zaman partition yok | FROZEN (teknik) | Satır silme yasağı; planlayıcı maliyeti |
| OP-17 | Access OP-73 ve Access OP-74 aynen; değerler Access Ek C'den | MERKEZİ KARAR | Suiss ortak veri kuralı |
| OP-18 | DEK kişi × saklama sınıfı; Relay sınıfları ↔ Access Ek C eşlemesi | FROZEN (teknik) | Access OP-74 madde 1 |
| OP-19 | Ticari ileti onay ve gönderim kayıtları Türkiye'de 10 yıl; kiracı yalnız uzatabilir | FROZEN (teknik) | 6563 m.11/3 (7416 ile); kanun süresi yönetmelikteki kısa süreye baskın |
| OP-20 | Bastırma listesi anahtarlı özet; özne silmesinde imha edilmez | FROZEN (teknik) | Access OP-74 madde 7; GDPR m.17/3 istisnası |
| OP-21 | Denetim kaydı varsayılan saklama 400 gün; sektör şablonu uzatır | POLICY DEFAULT | Access Ek C |
| OP-22 | Inbox: görünür son 1.000 öğe, aktif 90 gün, arşiv 1 yıl; kiracı üst sınır içinde değiştirir; fiziksel silme yok | POLICY DEFAULT | Inbox ve teslim kaydı farklı saklama rejimleri |
| OP-23 | OTP/doğrulama içeriği saklanmaz (özet + şablon sürümü); diğer sınıflarda mesaj başına `retention: none` | FROZEN (teknik) | Onay/OTP içeriğinin saklanması bilinen kötü varsayılan |
| OP-24 | Özne silmesi bekleyen işler, zamanlanmış gönderim, tekrar kuralı, digest tamponu, bekleme noktası ve inbox'a uygulanır; kanıt ayrı ve en az veri | FROZEN (teknik) | Silinen kişiye bekleyen mesajın gitmesi |
| OP-25 | Kişisel veri kopyalarının kapsam listesi; kuyrukta/log'da/trace'te PII yok; DLQ ve analitikte kör indeks; listede olmayan tablo testi kırar | FROZEN (teknik) | "Token'lar şifreli" garantisinin hangi kopyada geçerli olduğu bilinmeli |
| OP-26 | Kiracı kapatma crypto-shred; önce tam dışa aktarma; kişi bazlı dışa aktarma | FROZEN (teknik) | Fiziksel silme yok; taşınabilirlik |
| OP-27 | Yönetilen HA; senkron kuorum `ANY 1`; DR ve PITR bölge içinde; RPO/RTO PD | FROZEN (teknik) · PD (RPO/RTO) | `FIRST 1` yedek çökünce commit'leri durdurur |
| OP-28 | Failover mükerrere mal olur, kayba olmaz; kısa zombi kurtarma + tekillik; salt okunur bağlantı yenileme | FROZEN (teknik) | Commit olmuş işlemde istemci zaman aşımı |
| OP-29 | Valkey kaybı veri kaybı değildir; yedek gerekmez | FROZEN (teknik) | Valkey asıl kayıt tutmaz (§19 T-9) |
| OP-30 | Havuzlama kuralı: `düğüm × havuz × 2` < `max_connections`/2 ise havuzlayıcısız; aksi hâlde güncel PgBouncer işlem kipi | FROZEN (teknik) | PG14+ boşta bağlantı maliyeti düşük; havuz hatası yük atmadır |
| OP-31 | Veritabanı sağlık alarmları (slot, WAL, XID, disk %70/%85, şişme, uzun işlem, geçersiz indeks) | FROZEN (teknik) · PD (eşikler) | Terk edilmiş slot WAL'ı sabitler |
| OP-32 | Trace OTel, metrik Prometheus, log yapılandırılmış + trace kimliği; dönüşüm ve kardinalite sınırı toplayıcıda; bölge içinde | FROZEN (teknik) | Erlang OTel'de metrik/log OTLP ihracı yayımlanmış pakette yok ⚠️ |
| OP-33 | Birincil sağlık metriği huni tamlığı; defter otoriter; kayıp ölçüleri; push'ta `delivered` iddiası yok | KANONİK DEĞİŞMEZ | APNs/FCM'de tekil teslim onayı yok |
| OP-34 | `traceparent` defterde ve iş meta verisinde; geç olay span bağlantısıyla; bağlam açık taşınır; span'de PII yok; korelasyon kimliği | FROZEN (teknik) | Tail sampling 20 dk sonra gelen makbuzu barındıramaz |
| OP-35 | Kardinalite kuralı: `channel × provider × status` + exemplar; histogramda kiracı yok; ilk 20 kiracı + `other`; yasak etiketler; kiracı SLO'su olay verisinden | FROZEN (teknik) · PD (N=20) | Kiracı etiketli histogramın seri patlaması ⚠️ (aritmetik) |
| OP-36 | Tek SLO tablosu sınıf başına; değerler PD; kabul temelli SLI + eşik; yanma oranı alarmları; "%40 düşüş" alarmı; çelişen eski değerler taşınmaz | FROZEN (teknik) · PD (değerler, değer ölçümle) | Ölçülmemiş OTP hedefleri birbiriyle çelişiyordu |
| OP-37 | Alarm hijyeni: en eski iş yaşı, kesici durumu, sınıf eşikleri, gece pazarlama sayfası yok, sağlayıcı olayı birleştirme, `runbook_url` zorunlu, ek alarm seti, uyandırma bütçesi | FROZEN (teknik) | Aksiyonsuz sayfa nöbeti tüketir |
| OP-38 | Faturalama değişmez `usage_records`'tan; ölçüm boyutları baştan; fatura mutabakatı; test gönderimi ayrı satır | KANONİK DEĞİŞMEZ | Metrik kayıp ve örnekleme içerir |
| OP-39 | Analitik PG rollup + kiracı hedefine akış + CSV/Parquet dışa aktarım; Relay içinde OLAP yok; ClickHouse yalnız hedef | MERKEZİ KARAR | Çok bileşenli yığından kaçınma; self-host sadeliği |
| OP-40 | "Neden almadım" ekranı 30 sn hedefli, PII maskeli; panel sayım sorgusu yükü sınırlı | FROZEN (teknik) | Destek maliyeti; operatör panelinin DB yükü |
| OP-41 | Mutabakat `delivered`/`failed` uydurmaz; `unknown` dürüst; otomatik yeniden gönderim yok | KANONİK DEĞİŞMEZ | Bilinmeyen durumun uydurulması müşteriyi yanıltır |
| OP-42 | Mutabakat ve denetim işleri tablosu | FROZEN (teknik) · PD (sıklıklar) | Sağlayıcı olayları kaybolabilir ve sırasız gelir |
| OP-43 | Runbook altı bölüm; makine okunur başlık; 6 aydan eski test CI'ı kırar; komut yazım kuralları; depoda sürümlü | FROZEN (teknik) | Playbook'un MTTR'yi belirgin düşürdüğü SRE deneyimi |
| OP-44 | Azaltma tek düğmeli, idempotent, denetimli; otomasyon merdiveni 0–4; itibar ve geri alınamaz eylemler otomatik açılmaz | FROZEN (teknik) | Stresli operatör eylemi iki kez çalıştırır |
| OP-45 | Tek şiddet taksonomisi: sınıf × genişlik × geri alınabilirlik + değiştiriciler; SEV1–4 tablosu; başka tablo yok | MERKEZİ KARAR | Genel SEV tanımları bildirim sisteminde işlemez (servis hiç "tamamen kapalı" olmaz) |
| OP-46 | Erken ilan; olay rolleri; müşteri bildirimi; suçlamasız ve zorunlu postmortem; yazılı devir, kill switch canlı okunur | FROZEN (teknik) · PD (süre hedefleri) | Google SRE olay yönetimi |
| OP-47 | Toplu yanlış gönderimde önce durdur (< 60 sn); kontrol listeli yeniden açma; özür mesajı yok; yanlış veri eşleme ihlal karar noktası; kampanya güvenlikleri | FROZEN (teknik) | Geri alınamaz zararın sınırlanması |
| OP-48 | Relay kendine bağımlı değildir: durum sayfası ve işletim e-postası ayrı; sayfalama bağımsız sağlayıcıda; SMS birincil uyandırma değil; runbook'lar bağımsız erişilebilir | KANONİK DEĞİŞMEZ | Bootstrap bağımlılığı: Relay düştüğünde Relay'le haber verilemez |
| OP-49 | Oyun günü dört aile (sağlayıcı, uyum, altyapı, insan); hipotez/ölçüm/kabul; hata enjeksiyonu kill switch altyapısıyla, oran + TTL, yalnız üretim dışı ya da kaos kipi | FROZEN (teknik) · PD (ritim) | Test edilmemiş runbook runbook değildir |
| OP-50 | Kapasite sırası: sağlayıcı → kuyruk → düğüm → DB; beklenmedik yük üçlü ayrımı; bilinen tepe proje olarak planlanır | FROZEN (teknik) | Retry fırtınasında ölçeklemek kötüleştirir |
| OP-51 | Gönderim modu `live/shadow/dry_run/off`; sevk sınırında uygulanır; hiyerarşik çözüm; açık mod canlıda reddedilir | MERKEZİ KARAR | Kuyruk davranışları gölgede de gerçek çalışmalı |
| OP-52 | Gölge mod kuralları: sağlayıcı sınırı, kullanıcıya mevcut sonuç, kasıtlı farklar listesi, katmanlı karşılaştırma, maskeli kısa saklama, kapsama temelli çıkış, ölçülemeyenler belgeli | FROZEN (teknik) · PD (eşikler, 14 gün) | Scientist kalıbı (Stripe/GitHub göçleri) |
| OP-53 | Kullanıcıya yapışkan deterministik bölme; yönlendirme sırası; ≤ 60 sn yayılım; 60 sn geri alma; acil durdurma tek komut; rampa ≤ 5× ve ≥ 1 gün, alt sınır %1; kademeli müdahale | FROZEN (teknik) · PD (eşikler) | Rastgele bölme fallback ve frekansı bozar |
| OP-54 | Çift gönderim ihlaldir; ortak tekilleştirme anahtarı ve deposu; tek gösterim noktası; outbox ile çift yazım; mükerrer istemci telemetrisiyle | KANONİK DEĞİŞMEZ | Sunucu tarafında mükerrer ölçülemez |
| OP-55 | İçe aktarma kuralları: kimlik bağlamı sabit; bastırma ve izin token'lardan önce; asimetrik izin eşlemesi; token taşı → yeniden kaydet; otomatik birleştirme yok; sağlayıcı kimliği PK değil; normalizasyon; AST tabanlı şablon dönüşümü | FROZEN (teknik) | Göçün en sık hataları erozyon ve izinsiz gönderim |
| OP-56 | Kesme ve devir: yeni iş kabulü çevrilir, uçuştaki eskide boşalır; zamanlanmış iş tercih sırası; açık digest geçirilmez; atomik cron devri; webhook alıcısı açık kalır | FROZEN (teknik) | Kayıp mükerrerden kötüdür; iki etkin cron mükerrer üretir |
| OP-57 | Sıfır kesintili şema değişikliği: genişlet-daralt, kısa `lock_timeout` + retry, `NOT VALID` + `VALIDATE`, eş zamanlı indeks, CI kontrolleri, kuyruk şeması önce | FROZEN (teknik) | Bekleyen ağır kilit talebi okumaları durdurur |
| OP-58 | Bölge kurulumu: bölgeye özel PG/Valkey/KMS, TR yurt içi, veri yerleşimli sağlayıcı kataloğu, ön katman, aynı bölgede Access, bağımsız bildirim yolu, bölge kabul testi | FROZEN (teknik) | Bölge başına bağımsız kurulum (§18 TN-55) |
| OP-59 | Ön katman isteğe bağlı ve bölge kuralına uyar; regüle TR kiracısında TLS yurt dışında sonlandırılmaz; imza doğrulaması uygulamada | MERKEZİ KARAR | TLS'i açan ön katman içerik görür |
| OP-60 | Edge çalışma ortamları kapsam dışı | KAPSAM DIŞI | Kalıcı bağlantı, transaction ve veri yerleşimi edge modeliyle uyuşmaz |
| OP-61 | Kapasite varsayımları tablosu; tek birincil DB kaçış sırası; kuyruğu ayrı DB'ye taşımak ayrı karar | ENGINEERING ASSUMPTION | Sayılar ölçülmedi ⚠️ |
| OP-62 | Self-host aynı paket: compose + Kubernetes belgesi, hesap gerektirmeyen kanallar çekirdekte, tam özellik eşitliği, SaaS farkı yalnız hizmet, işletim belgeleri | MERKEZİ KARAR | Açık çekirdek yok; Novu CE'nin kırpılmış self-host'unun tersi |
| OP-63 | Denetim kaydı Merkle kontrol noktası tekil bakım işi: kayıtları ağaca bağlar, KMS ile imzalar, en az bir bağımsız hedefe yayımlar; aralık beyan edilir ve Access identity denetim kaydıyla aynıdır, aşım güvenlik olayı; yayımlanmış kökler kayıtla periyodik karşılaştırılır | FROZEN (teknik) · PD (aralık) | Access OP-37, Access OP-38 |
