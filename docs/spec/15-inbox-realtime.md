## 15. In-app Inbox ve Realtime

**Bu bölümün kuralları.**
- Bu bölüm insanın uygulama içi gelen kutusunu (inbox), okundu ve rozet semantiğini, gerçek zamanlı teslimi, cihazlar arası yayılımı, abone jetonunu ve inbox saklamasını tanımlar. Karar ID'leri IN-1…IN-46'dır; register §15.8'dedir.
- Inbox ve ajan posta kutusu aynı kalıcı kayıt çekirdeğini paylaşır; bu bölüm **insan yüzünü** tanımlar, ajan yüzü (lease, ack, yeniden teslim) §17'dedir.
- In-app kanalının teslim kanıtı ve etkileşim olaylarının teslim defterine nasıl yazıldığı §14'tedir. Hazır inbox bileşenleri ve UX §8'de; tercih merkezi §13'tedir.
- Doğruluk kaynağı Postgres'tir. Realtime taşıma yalnız sinyal ve teslim katmanıdır; realtime yokken inbox doğru çalışır, yalnız güncellik gecikir.

---

### 15.1 Ortak kalıcı kayıt

#### 15.1.1 Ortak çekirdek (IN-1)

1. Her alıcı için sıra numaralı kalıcı bir kayıt, bir cursor ve bir outbox vardır. İnsan için bu kayıt inbox'tır, ajan için posta kutusudur; ikisi aynı yapı taşını kullanır.
2. Aynı kayıt realtime akışını besler: inbox'a yazılan her değişiklik akışta sıra numaralı bir olaydır (§15.4).
3. İnsan yüzü şu eylemleri taşır: görüldü, okundu/okunmadı, arşivle/arşivden çıkar, gizle, ertele (snooze).

#### 15.1.2 Ayrı depo (IN-2)

1. Inbox teslim kayıtlarından ayrı bir depodur; liste ve sayaç okumaları teslim tablolarından yapılmaz. Erişim deseni farklıdır (sayfalı liste + sayaç, sık durum değişikliği) ve saklama rejimi farklıdır.
2. In-app teslim kaydı inbox öğesine işaret eder. In-app teslimin `delivered` kanıtı öğenin commit'idir (§14).
3. Depo alıcıya göre bölümlenir (hash), sayfalama keyset ile yapılır, sayaç tablosu öğe yazımıyla aynı transaction'da güncellenir. Bölüm sayısı ve depolama ayrıntıları §20'dedir.

#### 15.1.3 Kişisel kayıt ve duyuru (IN-3)

1. Kişisel inbox kişi başına satır yazar (yazma anında yayılım).
2. Kiracı, alt kiracı ya da liste geneli **duyuru** ayrı bir duyuru kaydıdır ve okuma anında kişisel listeyle birleştirilir (okuma anında yayılım). On milyon alıcıya on milyon satır yazılmaz.
3. Duyurunun alıcı başına durumu (görüldü, okundu, arşiv, gizle) yalnız alıcı bir eylem yaptığında alıcı başına yazılır; sayaçlar duyuruyu birleştirilmiş görünüm üzerinden sayar.

#### 15.1.4 Öğe modeli (IN-4)

1. Öğe **konu + aktiviteler** modelindedir: digest yeni öğe açmaz, mevcut öğeyi günceller (`activity_count`, son aktörler, son aktivite zamanı) (§10).
2. Alanlar: başlık, gövde, yapılandırılmış içerik (avatar, eylem butonları, veri satırları), kategori, etiketler, `severity`, `group_key`, `expires_at`, `snoozed_until`, `state_version`, `locale`, `dir`.
3. Render edilmiş içerik saklanır; öğe gönderildiği andaki metni gösterir, şablon yeniden çalıştırılmaz. Şablonun sonradan değişmesi eski öğeleri değiştirmez.
4. Alan boyut sınırları vardır ve yayımlanmış sınırlar sayfasında belgelenir.

#### 15.1.5 Tekil öğe (IN-5)

Bir alıcı için bir bildirimden en fazla bir inbox öğesi oluşur. Yazma idempotenttir: aynı bildirimin tekrar işlenmesi mevcut öğeyi döndürür. Öğe kimliği ve `state_version` API'de her zaman birlikte taşınır.

#### 15.1.6 Eylem butonları ve onay (IN-6)

1. Inbox eylem butonu hiçbir zaman onay değildir. Onay türündeki öğede eylem yalnız Access onay yüzeyine derin bağlantıdır (Access EI-18).
2. Onay dışı yanıt butonları yanıt toplar; yanıtın kaydı, kanıt düzeyi ve sahibine iletilmesi §17'deki kurallara tabidir. Yanıt bütün cihaz ve kanallardaki kopyalara yansır.

#### 15.1.7 Kapsam (IN-7)

Inbox kapsamı kiracı × ortam (`live`/`test`) × isteğe bağlı alt kiracıdır. Alt kiracının inbox kapsamı alt kiracı ayarıdır (§18). Sayaçlar kapsam başına ayrı alınabilir; kapsam dışındaki öğe listede görünmez.

#### 15.1.8 Yalnız inbox alıcısı (IN-8)

Yalnız in-app inbox için alıcı, nesne biçiminde yalnız kimlikle açıkça oluşturulabilir (`to: {id}`); adres kimliğin kendisidir. Hayalet alıcı oluşturulmaz (§9).

---

### 15.2 Durumlar ve okundu semantiği

#### 15.2.1 Öğe durumları (IN-9)

| Durum | Nasıl oluşur | Geri alınabilir mi |
|---|---|---|
| `seen` | Öğe ekranda görüntülendi (istemci otomatik bildirir) | Hayır (monoton) |
| `read` | Kullanıcı öğeyi açtı ya da okundu işaretledi | Evet (`unread`) |
| `archived` | Kullanıcı arşivledi; inbox'tan kalkar, arşiv sekmesinde durur | Evet (`unarchive`) |
| `hidden` | Kullanıcı gizledi (arayüzde "sil" etiketi kullanılabilir); inbox'tan ve arşivden kalkar | Kullanıcı için hayır; kayıt saklama süresince kalır |
| `snoozed` | Kullanıcı erteledi; `snoozed_until`'e kadar listeden kalkar, sonra geri gelir | Evet |

`read` her zaman `seen`'i de getirir. `hidden` kullanıcı için terminaldir; veritabanında fiziksel silme yoktur (§15.7).

#### 15.2.2 Okundu iki ekseni (IN-10)

Görüldü ve okundu iki ayrı eksendir. Görüldü "bakmadığın bir şey var" sorusunu cevaplar ve rozetin varsayılan kaynağıdır; okundu "bunu açtın mı" sorusunu cevaplar ve listedeki kalın/ince görünümü ile "okunmamış" sekmesini belirler. Tek bir `read` bayrağına indirgemek rozeti bozar (inbox açılınca sönmeyen rozet).

#### 15.2.3 İki monoton sunucu damgası (IN-11)

1. Geri alınabilir her durum iki monoton sunucu damgasıyla tutulur: `read_at` / `unread_marked_at` ve `archived_at` / `unarchived_at`. Etkin durum, hangisinin daha yeni olduğuyla belirlenir.
2. Damgaları sunucu atar; istemci saati yalnız teşhis amaçlı taşınır. Olay zamanı geleceğe yazılamaz.
3. Her durum değişikliği `state_version`'ı artırır.

#### 15.2.4 Niyet protokolü (IN-12)

1. İstemci durum değil **niyet** gönderir: `{op, item_id, client_seq, base_state_version}`.
2. Monoton yöndeki işlemler (`seen`, `read`, `archive`, `hide`) koşulsuz ve eşgüçlüdür.
3. Ters yöndeki işlemler (`unread`, `unarchive`) iyimser eşzamanlılık denetimiyle yapılır: `base_state_version` güncel değilse `409` ve öğenin güncel durumu döner.
4. `409` alan istemci sunucu durumunu sessizce kabul eder; yalnız kullanıcı o an ekranda ters işlem yaptıysa "başka cihazda güncellendi" bilgisi gösterilir.

Asimetri bilinçlidir: işlemlerin büyük çoğunluğu monoton yöndedir ve kilitsiz çalışır; nadir ters işlem bir gidiş-dönüş ve nadir bir `409` öder.

#### 15.2.5 Çevrimdışı kuyruk (IN-13)

1. İstemcinin çevrimdışı kuyruğu `client_seq` sıralıdır ve öğe başına sıkıştırılır: bir öğe için yalnız son niyet kalır.
2. Çevrimdışı cihazın eski niyeti başka cihazdaki daha yeni ters eylemi ezemez: sunucuda daha büyük `state_version` görülürse monoton yöndeki niyet gönderilmeye devam eder, ters yöndeki niyet kuyruktan düşürülür.

#### 15.2.6 Toplu işlemler (IN-14)

1. **Tümünü okundu** (kapsam: tüm inbox ya da kategori) tek istekte biter: okunmamış sayacının sıfırlanması ve okundu işareti aynı işlemde atomik yazılır; rozet ile liste çelişmez.
2. Keyfi filtreyle toplu işlem ile toplu arşiv ve toplu gizle asenkron ve parçalı yapılır; istemciye ilerleme gösterilir.
3. Tümünü okundu'nun mekanizması (kapsam başına okundu işareti ya da parçalı güncelleme) ölçüme bağlıdır; alıcı başına okunmamış öğe sayıları küçük kaldıkça parçalı güncelleme yeterlidir. API semantiği mekanizmadan bağımsızdır.

#### 15.2.7 Geri al (IN-15)

Arayüzdeki "geri al" kısa bir istemci tamponuyla sunucuya yazmadan çözülür; tampon süresi dolduktan sonra işlem sunucuya gider.

#### 15.2.8 Geri çekme (IN-16)

In-app, gönderildikten sonra geri çekilebilen tek kanaldır. Bildirim iptal edildiğinde ya da kiracı öğeyi geri çektiğinde öğe `retracted` nedeniyle gizlenir, sayaçlar güncellenir ve realtime güncelleme yayımlanır. Diğer kanallarda gönderilmiş mesaj geri alınamaz (§10).

#### 15.2.9 Süre sonu (IN-17)

`expires_at`'i geçen öğe listeden ve sayaçlardan düşer; kayıt saklama kuralına göre durur (§15.7).

---

### 15.3 Rozet ve sayaçlar

#### 15.3.1 Rozet neyi sayar (IN-18)

1. Kiracı uygulama başına rozetin neyi sayacağını seçer: `unseen` (varsayılan) ya da `unread`.
2. Sunucu her zaman üç sayacı tutar: `unseen_count`, `unread_count`, `total_count`. Sayaçlar öğe yazımı ve durum değişikliğiyle aynı transaction'da güncellenir.
3. Gecelik uzlaştırma, son 24 saatte durum değişikliği olan alıcıların sayaçlarını kayıtlarla karşılaştırır ve sapanları düzeltir; sapma metriği alarm eşiklidir.

#### 15.3.2 Sürümlü mutlak sayı (IN-19)

1. Rozet sunucuda hesaplanan, sürümlü, mutlak bir sayıdır; bütün cihazlar aynı sayıyı görür. Uygulama ikonu rozeti de bu sayıdan güncellenir.
2. Rozet asla artış (+1) olarak gönderilmez. Mükerrer ya da sırası bozuk sayaç olayı rozeti bozmaz.
3. Sayaç sürümü (`counters.version`) her değişiklikte artar; istemci kendisindekinden küçük sürümlü sayacı yok sayar.

#### 15.3.3 Platform eşlemesi (IN-20)

| Platform | Kural |
|---|---|
| iOS | `aps.badge` mutlak değerdir: `min(sayı, 999)`. Sunucu sayıdan emin değilse (uzlaştırma sürüyorsa) alan hiç konmaz; alan yoksa rozet değişmez |
| Android | `notification_count` doldurulur; ürün tasarımı rozete bağlanmaz (launcher'lar farklı gösterir); okunmamış sinyali uygulama içinde gösterilir |
| Web | `setAppBadge` yalnız kurulu PWA'da; Service Worker push alınca rozeti günceller |
| Uygulama içi | Gösterim tavanı `99+` |

Push payload'ındaki sayı, sayacı güncelleyen işlemin kendi sonucundan alınır; ek sorgu yapılmaz.

#### 15.3.4 Ön plana gelişte senkron (IN-21)

1. Uygulama ön plana geldiğinde istemci koşulsuz olarak güncel sayaçları ister; rozet doğruluğunun asıl garantisi budur.
2. İstemci, sunucunun sayısı ile listelediği öğelerden hesapladığı sayıyı tutarsız bulursa tutarsızlık bildirir; sunucu o alıcı için anında uzlaştırma yapar. Tutarsızlık oranı metriktir.

---

### 15.4 Realtime

#### 15.4.1 Tek olay akışı modeli (IN-22)

1. Her akış `(stream, epoch, seq)` ile sıralıdır. `seq` akış içinde monoton artar ve commit sırasına dayanır.
2. İstemci kaldığı yerden `since` cursor'uyla devam eder; bağlantı kopması kayıp üretmez.
3. `epoch` değişirse (akış yeniden kuruldu, kurtarma penceresi aşıldı) istemciye "baştan senkronize ol" sinyali gider.

#### 15.4.2 Taşımalar (IN-23)

1. WebSocket (Phoenix Channels) ve SSE (`Last-Event-ID`) eşit sınıftır; ikisi de aynı akışı aynı olaylarla taşır. Son yedek long-poll ve periyodik yoklamadır.
2. Ayrı bir realtime sunucusu yoktur; realtime Relay'in kendi sürecinde çalışır.
3. SSE eşit tutulur çünkü kurumsal TLS proxy'leri WebSocket `Upgrade`'ini düşürebilir ve ajan/LLM dünyası SSE kullanır. HTTP/1.1 üzerinde tarayıcı başına bağlantı sınırı nedeniyle web SDK'sı WebSocket'i önce dener.
4. WebTransport kapsam dışıdır: sunucu tarafı olgun değildir, UDP/443 sık engellenir ve her durumda WebSocket yedeği gerekir.

#### 15.4.3 Doğruluk ve sinyal (IN-24)

1. Doğruluk Postgres kaydındadır. Düğümler arası haber Valkey pub/sub ile gider ve yalnız "yeni bir şey var" + sıra numarası taşır; veri Postgres'ten okunur.
2. Kaçırılan sinyal cursor ile telafi edilir. Valkey erişilemezse sinyal kısa aralıklı yoklamaya düşer.
3. Realtime bir bağımlılık değil iyileştirmedir: realtime çalışmıyorsa istemci HTTP liste ve yoklamayla doğru veriyi görür.

#### 15.4.4 Yayın yolu (IN-25)

1. Öğe yazımı, sayaç güncellemesi ve yayın kaydı aynı transaction'dadır (outbox). Yayın commit'ten sonra çıkar (hayalet bildirim yoktur); commit olduysa yayın er geç çıkar (en az bir kez).
2. Yayın inbox yazma yolunu hiçbir zaman bloklamaz.

#### 15.4.5 Zarf ve olay adları (IN-26)

1. Her realtime mesajı tek zarfı kullanır: `{t, v, ts, d}` (`t` olay türü, `v` şema sürümü, `ts` sunucu zamanı, `d` gövde) ve her mesaj `counters` taşır (rozet ayrı bir mesaja bağlı kalmaz).
2. İnsan inbox akışının olay türleri:

| Olay | Gövde |
|---|---|
| `inbox.item_created` | Tam öğe + `state_version` |
| `inbox.item_updated` | Öğe kimliği, `state_version`, değişen durum alanları |
| `inbox.items_bulk_updated` | Kapsam (tüm inbox ya da kategori), toplu işlem türü; satır listesi yok |
| `inbox.counters_changed` | `unseen`, `unread`, `total`, `version` |
| `stream.resync_required` | `reason` |

3. Topic adları, olay adları ve zarf tek bir takım olarak AsyncAPI sözleşmesinde yazılır (§9).

#### 15.4.6 Kendine yeterli yayın (IN-27)

1. `inbox.item_created` listeyi çizmek için gereken her şeyi içerir (boyut sınırı içinde); istemci ek okuma yapmaz. Boyut sınırını aşan öğede yalnız ince özet yayımlanır ve istemci öğeyi okur.
2. Her yayın ilgili varlığın sürümünü taşır (öğe olaylarında `state_version`, sayaç olaylarında `counters.version`). İstemci kendisindeki sürümden küçük ya da eşit sürümlü olayı sessizce atar. Sıra bozulması, mükerrer olay ve kurtarma tekrarı tek mekanizmayla çözülür.

#### 15.4.7 İstemci kalıbı (IN-28)

İstemci SDK'larına şu kalıp gömülüdür: önce akışı aç ve gelen olayları tamponla; sonra anlık görüntüyü (snapshot) ya da geçmişi listele; tamponu uygularken kimlik ve sürümle tekilleştir. Akış açılmadan liste okumak, iki adım arasındaki değişiklikleri kaybettirir.

#### 15.4.8 Senkron türleri (IN-29)

1. **Soğuk senkron:** ilk sayfa + sayaçlar (ilk açılış, oturum açma, `epoch` değişimi).
2. **Delta senkron:** `changes?since=<cursor>` → oluşan, güncellenen ve gizlenen öğeler + yeni cursor (kısa çevrimdışı süre, arka plandan dönüş).
3. Delta yanıtı en fazla 500 değişiklik taşır (POLICY DEFAULT); üst sınır aşılırsa yanıt `truncated` işaretlidir ve istemci soğuk senkrona geçer. Replay'in üst sınırı vardır; sınırsız geçmiş akışla geri oynatılmaz.

#### 15.4.9 Sayfalama (IN-30)

Liste sayfalaması keyset'tir; cursor opaktır. Offset ve toplam sayfa sayısı yoktur (başa yeni öğe gelince offset tekrar gösterir). Offset yalnız destek ve yönetim uçlarında, ayrı limitle bulunur.

#### 15.4.10 Yazmalar REST'ten (IN-31)

İstemciden sunucuya bütün yazmalar (durum niyetleri, toplu işlemler, görüntüleme bildirimi) REST API'sinden yapılır. Realtime bağlantısı üzerinden yazma yoktur; istemci realtime kanalına yayın yapamaz. Çevrimdışı kuyruk zaten REST kullandığı için tek kod yolu kalır.

#### 15.4.11 Sunucu tarafı abonelik (IN-32)

1. Abonelik sunucu tarafındadır: izinli topic'ler abone jetonunda yazılıdır; istemci kendi isteğiyle başka topic'e abone olamaz.
2. Kiracı kimliği istemcinin görebileceği alanlarda (topic adı, zarf) bulunmaz.
3. İstemci akış geçmişini realtime katmanından kendisi sorgulayamaz; geçmiş yalnız yetkili REST uçlarından okunur.

#### 15.4.12 Yetki sürekliliği (IN-33)

Abone ya da kiracı askıya alındığında veya jeton iptal edildiğinde açık bağlantılar sunucudan kesilir. Yeniden bağlanma ve kurtarma yetkiyi baştan kontrol eder; kurtarma yolu yetki denetimini atlamaz.

#### 15.4.13 Yeniden bağlanma dalgası (IN-34)

Yayın (deploy) sonrası toplu yeniden bağlanmaya karşı: (1) istemci yeniden bağlanmada üstel geri çekilme + tam jitter kullanır; (2) düğüm başına bağlantı kabul hızı sınırlıdır, aşımda istemci geri çekilir; (3) anlık görüntü ucu alıcı başına ve kiracı başına hız sınırlıdır; (4) yayın kademelidir ve düğüm kapanırken bağlantılar parti parti boşaltılır.

#### 15.4.14 Mobil yaşam döngüsü (IN-35)

1. Mobil uygulama arka plana geçince realtime bağlantısını kapatır; güncellik push'a devredilir.
2. Ön plana dönüş sırası: sayaçları iste (rozeti hemen düzelt) → bağlan → akışı aç, delta ya da soğuk senkron → çevrimdışı kuyruğu boşalt → `409`'larda sunucu durumunu kabul et. Kuyruk en sonda boşaltılır ki gereksiz `409` oluşmasın.
3. iOS sessiz push'u inbox içeriği taşımaz, yalnız "senkronize ol" sinyalidir (`{sync, counter_version}`) ve alıcı başına kısılır. Android'de senkron sinyali normal öncelik ve kısa TTL ile gider; görünür bildirim yüksek öncelikle.

#### 15.4.15 Web çok sekme (IN-36)

1. Aynı tarayıcıda tek bağlantı: Web Locks ile lider sekme seçilir, lider akışı BroadcastChannel ile diğer sekmelere dağıtır.
2. Takipçi sekmeler kendi yazmalarını REST ile kendileri yapar; lidere devretmez (lider değişiminde kayıp olmaz).
3. Uzun süre gizli kalan lider sekme bağlantıyı kapatır ve görünür olunca delta senkronla döner.
4. Service Worker push alınca rozeti günceller ve bildirim tıklamasını açık sekmeye yönlendirir.

#### 15.4.16 Opak yükler (IN-37)

Realtime kanalı ajan arayüz olaylarını (AG-UI) ve benzeri opak yükleri ayrı akış türü olarak taşır; Relay bu yükleri yorumlamaz (§17). Opak akışlar da aynı `(stream, epoch, seq)` modeline ve aynı yetki kurallarına tabidir.

---

### 15.5 Cihazlar arası yayılım

#### 15.5.1 Varsayılan: bütün aktif cihazlar (IN-38)

1. Bir bildirim alıcının bütün aktif cihazlarına gider.
2. Bir cihazda okunduğunda diğer cihazlarda da okundu olur ve gösterilen bildirim kaldırılır (sessiz push ya da collapse ile). iOS'ta kaldırma SDK ile yapılır ve gecikebilir.

#### 15.5.2 Yalnız son aktif cihaz (IN-39)

Kiracı workflow adımında ya da rotada "yalnız son aktif cihaz" stratejisini seçebilir (§10).

#### 15.5.3 Aktif bağlantılı cihaza push yok (IN-40)

1. Aktif realtime bağlantısı olan cihaza aynı bildirim için ayrıca push gönderilmez; bildirim realtime ile teslim edilir.
2. Varlık (presence) sinyali Relay'in kendi bağlantı kaydından ve istemcinin görüntüleme bildiriminden gelir; kısa ömürlü kayıt olarak tutulur. Push kararı realtime katmanına senkron sorguya bağlanmaz.

---

### 15.6 Abone jetonu

#### 15.6.1 Jeton kaynağı (IN-41)

1. Varsayılan: Relay kısa ömürlü abone jetonu basar; jetonu kiracının backend'i Relay API anahtarıyla ister ve istemcisine verir.
2. Access'li kiracılarda RFC 8693 token exchange ile Access jetonu Relay abone jetonuna çevrilir; kiracı backend'ine kod gerekmez.
3. Relay, Access jetonunu doğrudan inbox erişimi için kabul etmez.
4. Jeton dar kapsamlıdır: `inbox:read`, `inbox:write`, `preferences`, `devices:write`. Yalnız o abonenin inbox'ına, tercihlerine ve kendi cihaz kaydına dokunur; `devices:write` yalnız jeton sahibinin cihazını kaydeder, günceller ve kaldırır (§9 API-46).
5. Token exchange'de Relay abonesi Access'in kiracıya özgü (pairwise) `sub` değeriyle eşlenir; Access bağlı kiracıda abonenin `external_id`'si bu değerdir. Kiracı backend'i ayrı eşleme vermez; pairwise gizlilik korunur.

#### 15.6.2 Jeton özellikleri (IN-42)

1. Jeton asimetrik imzalıdır (algoritmalar §18); `aud` Relay'in inbox ve realtime yüzeyidir; ortam (`live`/`test`) ve izinli topic'ler jetondadır.
2. Ömrü kısadır (varsayılan 15 dakika); SDK süre dolmadan yeniler.
3. İptal, kısa ömürle sınırlı değildir: iptal anında açık bağlantılar kesilir (IN-33).

#### 15.6.3 İstemci yüzeyinin sınırı (IN-43)

İstemci (mobil, tarayıcı) gizli anahtar tutmaz, olay tetiklemez, alıcı profili ya da izin kaydı yazmaz. İstemci uçları izin listesiyle sınırlıdır; abone jetonu yalnız bu uçlarda geçerlidir. Kendi cihazının kaydı (`devices:write`) izin listesindedir; profil yazımı sayılmaz.

---

### 15.7 Saklama

#### 15.7.1 Saklama modeli (IN-44)

1. Kullanıcı yalnız arşivler ya da gizler; veritabanında fiziksel silme hiçbir koşulda yoktur (Access OP-73). Gizle ve arşiv durumdur; satır kalır.
2. KVKK/GDPR silme talebi crypto-shredding'dir: kişisel alanlar özne × saklama sınıfı DEK'iyle şifrelidir, talepte DEK imha edilir, satırlar okunamaz olarak kalır (Access OP-74).
3. Saklama sonu: yumuşak silme + crypto-shredding; eski bölümler soğuk arşive taşınır (doğrulanmış WORM kopya, sonra sıcak kopyanın arşiv rolüyle kaldırılması; §20 OP-15), imha edilmez.
4. Varsayılan saklama: görünür son 1.000 öğe, aktif 90 gün, arşiv 1 yıl. Kiracı Access Ek C üst sınırları içinde değiştirir.
5. Inbox saklaması teslim kaydı saklamasından ayrıdır (§14.9).

#### 15.7.2 Özne silmesinin kapsamı (IN-45)

Özne bazlı silme talebi kuyruktaki işlere, zamanlanmış gönderimlere, digest tamponlarına ve inbox'a uygulanır. Yasal saklama gereken kanıt ayrı tutulur ve en az veriyle sınırlıdır (ör. ticari ileti gönderim kaydı; §14.9).

#### 15.7.3 İçerik saklamayan mesaj ve inbox (IN-46)

Inbox, öğeyi göstermek için render içeriğini saklamak zorundadır (IN-4). Bu yüzden `retention: none` işaretli mesajın in-app kanalına gitmesi kabul edilmez: birleşim kabul anında doğrulama hatasıyla reddedilir. İçeriksiz "yeni bildiriminiz var" öğesi ve kısa ömürlü öğe kapsam dışıdır; talep oluşursa ayrı kararla değerlendirilir.

---

### 15.8 IN karar register'ı (IN-1–IN-46)

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| IN-1 | Ortak kalıcı kayıt çekirdeği (sıra no + cursor + outbox); insan yüzü burada, ajan yüzü §17; aynı kayıt realtime akışını besler (§15.1.1) | FROZEN (teknik) | Tek yapı taşı; JMAP `state`/`changes` ve Signal cihaz kuyruğu kalıbı |
| IN-2 | Inbox ayrı depo; teslim tablolarından okunmaz; in-app teslim kanıtı öğenin commit'i; hash bölümleme, keyset, aynı transaction'da sayaç (§15.1.2) | FROZEN (teknik) | Erişim deseni ve saklama rejimi teslim kaydından farklı; Knock'ta log kısa, feed uzun saklanır |
| IN-3 | Kişisel inbox yazma anında; duyuru ayrı kayıt, okuma anında birleştirilir (§15.1.3) | FROZEN (teknik) | Büyük kitleye kişi başı satır yazmanın maliyeti |
| IN-4 | Öğe "konu + aktiviteler" modeli; digest mevcut öğeyi günceller; render içerik saklanır; boyut sınırları yayımlanır (§15.1.4) | FROZEN (ürün) | Kullanıcı aylar sonra gönderildiği andaki metni görmeli; Novu snooze/severity/sekme emsali |
| IN-5 | Alıcı × bildirim başına tek öğe; idempotent yazma (§15.1.5) | KANONİK DEĞİŞMEZ | Yeniden işleme mükerrer öğe üretmemeli |
| IN-6 | Inbox eylem butonu onay değildir; onay öğesinde eylem yalnız Access onay yüzeyine derin bağlantı (§15.1.6) | KANONİK DEĞİŞMEZ | Access EI-18; kanal yanıtı yetki kanıtı değildir; MD-2 |
| IN-7 | Inbox kapsamı kiracı × ortam × alt kiracı; kapsam başına sayaç (§15.1.7) | FROZEN (ürün) | Alt kiracı modeli; Courier kapsamlı okunmamış sayısı |
| IN-8 | Yalnız inbox alıcısı `to: {id}` ile açıkça oluşturulur (§15.1.8) | FROZEN (teknik) | Hayalet alıcı oluşturmama ilkesi |
| IN-9 | Durumlar: `seen` (monoton), `read`⇄`unread`, `archived`⇄`unarchived`, `hidden` (kullanıcı için terminal), `snoozed` (§15.2.1) | FROZEN (ürün) | Dört ayrı kullanıcı niyeti; fiziksel silme yok |
| IN-10 | Görüldü ve okundu iki ayrı eksen (§15.2.2) | KANONİK DEĞİŞMEZ | Tek bayrak rozeti bozar (Novu seen/read ayrımı) |
| IN-11 | Geri alınabilir durumlar iki monoton sunucu damgasıyla; damgayı sunucu atar; her değişiklik `state_version`'ı artırır (§15.2.3) | FROZEN (teknik) | Saf son-yazan-kazanır istemci saatine güvenir; saf monoton kafes "okunmadı işaretle"yi bozar |
| IN-12 | Niyet protokolü: monoton yön koşulsuz, ters yön iyimser eşzamanlılık + `409` (§15.2.4) | FROZEN (teknik) | Tek Postgres yazmaları serileştirir; gerçek sorun çevrimdışı cihazın eski niyeti |
| IN-13 | Çevrimdışı kuyruk öğe başına sıkıştırılmış; eski ters niyet yeni durumu ezemez (§15.2.5) | KANONİK DEĞİŞMEZ | Çok cihazlı tutarlılık |
| IN-14 | Tümünü okundu atomik (sayaç sıfırı + işaret); keyfi filtre ve toplu arşiv/gizle asenkron parçalı; mekanizma ölçüme bağlı (§15.2.6) | ENGINEERING ASSUMPTION | Büyük toplu güncelleme vacuum ve kilit maliyeti; karmaşıklık ölçüm göstermeden eklenmez |
| IN-15 | "Geri al" istemci tamponuyla, sunucuya yazmadan (§15.2.7) | FROZEN (ürün) | Gizle kullanıcı için terminal |
| IN-16 | In-app tek geri çekilebilir kanal; iptal/geri çekmede öğe `retracted` gizlenir ve yayımlanır (§15.2.8) | FROZEN (ürün) | Gönderilmiş SMS/e-posta/push geri alınamaz |
| IN-17 | `expires_at` geçen öğe listeden ve sayaçlardan düşer (§15.2.9) | FROZEN (teknik) | Süreli içerik (ör. bekleyen istek) |
| IN-18 | Rozet kaynağı uygulama başına `unseen` (varsayılan) ya da `unread`; üç sayaç her zaman; aynı transaction; gecelik uzlaştırma + sapma metriği (§15.3.1) | FROZEN (ürün) | `unread` rozeti aylarca takılı kalır; kiracı ürün kararı |
| IN-19 | Rozet sunucuda hesaplanan sürümlü mutlak sayı; artış gönderilmez; küçük sürüm yok sayılır (§15.3.2) | KANONİK DEĞİŞMEZ | APNs `badge` mutlak değerdir; artış semantiği kalıcı bozulma üretir |
| IN-20 | Platform eşlemesi: iOS `min(sayı, 999)`, emin değilse alan yok; Android `notification_count`; Web `setAppBadge`; UI `99+` (§15.3.3) | POLICY DEFAULT | APNs: alan yoksa rozet değişmez; Android launcher farkları; Badging API desteği |
| IN-21 | Ön plana gelişte koşulsuz sayaç senkronu; istemci tutarsızlık raporu → anlık uzlaştırma (§15.3.4) | FROZEN (teknik) | Push teslimi garanti değil; rozet yarışı tam çözülemez |
| IN-22 | Tek akış modeli `(stream, epoch, seq)`; `since` cursor; `epoch` değişiminde resync (§15.4.1) | FROZEN (teknik) | Centrifugo epoch/offset + `recovered`, PubNub timetoken, JMAP `changes`; MD-15 |
| IN-23 | WebSocket (Phoenix Channels) ve SSE (`Last-Event-ID`) eşit; son yedek long-poll/yoklama; ayrı realtime sunucusu yok; WebTransport kapsam dışı (§15.4.2) | FROZEN (teknik) | Kurumsal proxy `Upgrade` düşürür; SSE ajan dünyasında fiilî standart; tek süreç işletim kolaylığı; MD-5 |
| IN-24 | Doğruluk Postgres'te; Valkey yalnız "yeni var + seq" sinyali; kaçırılan sinyal cursor ile; Valkey yoksa yoklama; realtime iyileştirmedir (§15.4.3) | KANONİK DEĞİŞMEZ | Pub/sub en çok bir kez teslim eder; kayıp yalnız gecikmeye mal olmalı; MD-15, MD-6 |
| IN-25 | Öğe + sayaç + yayın kaydı aynı transaction (outbox); commit sonrası, en az bir kez; yazma yolunu bloklamaz (§15.4.4) | KANONİK DEĞİŞMEZ | Çift yazma sorunu (commit oldu yayın çöktü / yayın gitti rollback); MD-15 |
| IN-26 | Zarf `{t, v, ts, d}` + her mesajda `counters`; inbox olay türleri; tek takım AsyncAPI'de (§15.4.5) | FROZEN (teknik) | Rozetin ayrı mesaja bağımlı olmaması; adlandırma tekliği |
| IN-27 | Yayın kendine yeterli tam öğe (sınır içinde); sürüm taşır; istemci ≤ sürümü atar (§15.4.6) | FROZEN (teknik) | Replika gecikmesinde ek okuma 404 riski; tek dedup mekanizması |
| IN-28 | İstemci kalıbı: önce akışı aç ve tamponla, sonra geçmişi listele, kimlik + sürümle tekilleştir (§15.4.7) | FROZEN (teknik) | İlk yükleme ile abonelik arasındaki boşluk |
| IN-29 | Soğuk ve delta senkron; delta yanıtı en fazla 500 değişiklik; `truncated` → soğuk; replay üst sınırı (§15.4.8) | FROZEN (teknik) · PD (delta tavanı 500) | ntfy sınırsız replay dersi; JMAP `changes` |
| IN-30 | Keyset sayfalama, opak cursor; offset yok (§15.4.9) | FROZEN (teknik) | Offset O(n) ve başa öğe gelince tekrar gösterme |
| IN-31 | İstemci yazmaları REST'ten; realtime üzerinden yazma ve yayın yok (§15.4.10) | KANONİK DEĞİŞMEZ | Kullanıcının kendi kanalına sahte bildirim basması saldırısı; tek kod yolu |
| IN-32 | Abonelik sunucu tarafında, izinli topic jetonda; kiracı kimliği istemciye görünmez; istemci geçmişi realtime'dan sorgulayamaz (§15.4.11) | KANONİK DEĞİŞMEZ | İstemci kontrollü abonelik yetki atlatma yüzeyi |
| IN-33 | Askı/iptalde açık bağlantılar kesilir; yeniden bağlanma ve kurtarma yetkiyi baştan kontrol eder (§15.4.12) | KANONİK DEĞİŞMEZ | Socket.IO kurtarmada middleware atlama tuzağı |
| IN-34 | Yeniden bağlanma dalgasına dört katmanlı savunma (§15.4.13) | FROZEN (teknik) | Yayın sonrası eşzamanlı yeniden bağlanma Postgres'i ezer |
| IN-35 | Mobilde arka planda bağlantı kapalı; ön plana dönüş sırası; iOS sessiz push yalnız senkron sinyali ve kısılır; Android senkron normal öncelik + kısa TTL (§15.4.14) | FROZEN (teknik) | APNs arka plan push teslimi garanti değil ve saatte birkaç denemeyle sınırlı; yarı ölü bağlantı maliyeti |
| IN-36 | Web çok sekmede Web Locks lider + BroadcastChannel; takipçi kendi yazar; gizli lider kapanır (§15.4.15) | FROZEN (teknik) | SharedWorker desteği eksik; sekme başına bağlantı maliyeti |
| IN-37 | AG-UI vb. opak yükler ayrı akış türü; Relay yorumlamaz; aynı model ve yetki (§15.4.16) | FROZEN (teknik) | AG-UI taşıma katmanı olarak realtime |
| IN-38 | Varsayılan bütün aktif cihazlara; okununca diğerlerinde okundu ve kaldırma (§15.5.1) | FROZEN (ürün) | Çok cihazlı kullanıcıda tutarlı deneyim |
| IN-39 | "Yalnız son aktif cihaz" stratejisi rota/adımda seçilebilir (§15.5.2) | FROZEN (ürün) | Kiracı tercihi; rota politikası stratejisi |
| IN-40 | Aktif realtime bağlantılı cihaza push yok; varlık sinyali Relay'in kendi kaydından, senkron sorgu yok (§15.5.3) | FROZEN (teknik) | Çift bildirim önleme; `userVisibleOnly` tarayıcıda bastırılamaz |
| IN-41 | Relay kısa ömürlü abone jetonu basar; Access'li kiracıda RFC 8693 token exchange, abone Access'in kiracıya özgü `sub`'ıyla eşlenir (`external_id` = bu değer); Access jetonu doğrudan kabul edilmez; kapsamlar `inbox:read`, `inbox:write`, `preferences`, `devices:write` (§15.6.1) | FROZEN (ürün) | Ürünlerin bağımsız çalışması (Access E40); dar kapsam; MD-1 |
| IN-42 | Jeton asimetrik imzalı, kısa ömürlü (varsayılan 15 dk, POLICY DEFAULT), ortam ve topic'ler jetonda; iptal bağlantıyı keser (§15.6.2) | FROZEN (teknik) | Paylaşılan sır sızıntısında herkes adına jeton basılabilir |
| IN-43 | İstemci gizli anahtar tutmaz, olay tetiklemez, profil/izin yazmaz; istemci uçları izin listesi, kendi cihaz kaydı dahil (§15.6.3) | KANONİK DEĞİŞMEZ | Hesap ele geçirme vektörü; izin kanıtı sunucuda |
| IN-44 | Fiziksel silme yok; gizle/arşiv durum; KVKK = crypto-shredding; saklama sonu yumuşak silme + crypto-shred + soğuk arşiv; varsayılan 1.000 öğe / 90 gün / 1 yıl (§15.7.1) | FROZEN (teknik) · PD (süreler) | Access OP-73, Access OP-74, Access Ek C; MD-9 |
| IN-45 | Özne silmesi kuyruktaki işlere, zamanlanmış gönderimlere, digest tamponlarına ve inbox'a uygulanır; yasal kanıt ayrı ve en az veriyle (§15.7.2) | FROZEN (teknik) | KVKK m.7; Access OP-74 |
| IN-46 | `retention: none` + in-app birleşimi kabul anında doğrulama hatasıyla reddedilir; içeriksiz ya da kısa ömürlü inbox öğesi yok (§15.7.3) | FROZEN (teknik) | Inbox içeriği saklamak zorunda; içerik saklamama bayrağıyla çelişki sessizce çözülmez |
