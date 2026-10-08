## 10. Workflow ve yönlendirme

**Bölüm notu.**

- **Kapsam.** Bu bölüm bir olayın bildirime, bildirimin kanallara nasıl dönüştüğünü yazar: workflow tanımı ve yazım yolları, sürüm sabitleme, adım seti, koşul dili, rota politikaları, kanal yükseltmesi, eskalasyon, digest, throttle, içerik tekilleştirmesi, zamanlama ve süre limitleri, saat dilimi, tekrar eden bildirimler, A/B deneyleri, topic ve kampanya.
- **Başka bölümde yazılanlar.** Mesaj sınıfları, tercih ve izin kafesi, sessiz saat, frekans tavanı ve yasal gönderim penceresi §13'tedir; bu bölüm onlara yalnız sıralama ve bağlantı noktası olarak atıf yapar. Kanal içi sağlayıcı seçimi, retry takvimi, hata sınıfları ve OTP kanal zinciri §12'de, teslim kanıtı ve `rule_id` sözlüğü §14'te, bekleme noktası ve ajan tarafı §17'de, kill switch §18'dedir. API yüzeyi §9'dadır.
- **Karar kimlikleri.** WF-1 … WF-55. Register §10.15'tedir.

### 10.1 Terimler (WF-1, WF-2)

```text
olay ──► workflow (sürümlü, adımlar) ──► bildirim (alıcı başına) ──► teslim (kanal × hedef) ──► deneme (tek dış istek)
              │
              └─ kanal adımı ──► şablon (kanal × locale matrisi, sürümlü; §11)
```

1. **Hiyerarşi.** Workflow sürümlü bir adım listesidir. Kanal adımı bir şablona işaret eder; şablon kanal × locale matrisidir ve ayrıca sürümlüdür (§11). Olay veri şeması (JSON Schema 2020-12) workflow sürümüne aittir; şablon değişkenleri yayında bu şemaya karşı doğrulanır (WF-1).
2. **Bildirim, teslim, deneme.** Bildirim alıcı başına iş olayıdır ve kanal sayısından bağımsızdır. Teslim belirli bir kanal ve hedefe gönderim niyetidir; fallback yeni teslim açar, retry açmaz. Deneme tek bir dış istektir (WF-1).
3. **Kategori ve sınıf.** Her workflow bir kiracı kategorisine bağlıdır; kategori yedi sabit mesaj sınıfından birine bağlanır (§13). Sınıf kabul anında atanır ve değişmez. Gönderen türü (insan, sistem, ajan) sınıftan ayrı bir alandır (WF-2).

### 10.2 Workflow tanımı ve yazım yolları (WF-3 … WF-7)

1. **Üç eşit yazım yolu, tek tanım biçimi** (WF-3):

| Yol | Kim için | Kural |
|---|---|---|
| Görsel editör (panel) | Kod bilmeyen kullanıcı; ana yol | Sürükle-bırak akış; taslak, test, yayın, tek tıkla eski sürüme dönüş |
| Dosya (YAML/JSON + JSON Schema) | Git'te tutmak isteyen ekip | CLI ile `pull`/`push`/`promote`; API aynı biçimi kabul eder |
| SDK ile kod | Geliştirici, kendi dilinde | Yayında aynı tanım biçimine derlenir |

Üç yol aynı tanım biçimini üretir; hiçbiri ötekinden güçlü değildir. Rotalar (§10.4), deneyler (§10.12) ve eskalasyon politikaları (§10.6) da üç yolda tanımlanabilir.

2. **Tek yönetici.** Her workflow'un tek yöneticisi vardır: "panelden" ya da "koddan" (dosya veya SDK). Koddan yönetilen workflow'un yapısı panelde değiştirilemez ve panel bunu uyarıyla gösterir; metin alanları ve kodda işaretlenmiş kontrol alanları panelde düzenlenebilir (WF-4).
3. **Tanım veridir.** Çalışma anında müşteri koduna ya da müşteri sunucusuna çağrı yoktur; bridge modeli yoktur. SDK ile yazılan workflow da yayında veriye derlenir (WF-5).
4. **Yaşam döngüsü.** Taslak → test → yayın. Yayın `202` ile kabul edilir ve yayın kapısından geçer (§11). Eski sürüme dönüş tek işlemdir. Çalışan koşular başladıkları sürümde biter. Ortamlar arası taşıma (`test` → `live`) CLI `promote` ile yapılır. Workflow Mermaid biçiminde dışa aktarılabilir (WF-6).
5. **Sürüm sabitleme.** Bildirim oluşurken şunlar donar: şablon sürüm kümesi (kanal × locale, fallback dahil), layout ve parça sürümleri (§11), alıcı adres çözümlemesi, `dedup_key`, deney varyantı (§10.12). Kapılar (izin, tercih, bastırma, kill switch, süre) her denemede yeniden değerlendirilir. Sabitlenmiş sürüm gönderilemiyorsa sessizce yeni sürüme geçilmez; açık bir sonuç ve `rule_id` kaydedilir (WF-7).

### 10.3 Adım seti ve koşul dili (WF-8 … WF-12)

1. **Sekiz adım** (WF-8):

| Adım | Ne yapar | Sınır |
|---|---|---|
| Kanal | Bir kanala ya da rota politikasına gönderir; isteğe bağlı A/B varyantları (§10.12) ve yükseltme (§10.5) | Rota seçimi §10.4 |
| Bekle | Belirli süre ya da belirli bir saate kadar bekler | ≤ 90 gün (§10.10) |
| Digest | Olayları pencere boyunca biriktirip tek bildirime katlar | §10.7; ≤ 31 gün |
| Throttle | Anahtar başına eşik ve pencereyle akışı kısar | §10.8; ≤ 31 gün |
| Koşul | Dallanır | Basit kural dili (bu alt bölüm, madde 3) |
| Olay bekle | Bir korelasyon anahtarına yanıt/olay bekler | Bekleme noktası (§17); ≤ 30 gün |
| Zaman penceresi | Gönderimi tanımlı pencereye (ör. iş saatleri, alıcı saat diliminde) erteler | Alıcı saat dilimi §10.10 |
| Webhook | Kiracının olay hedefine imzalı olay teslim eder | Ortak teslim motoru (§16) |

2. **Olmayan adımlar.** Veri çek (fetch/HTTP), veri güncelle ve başka workflow çağır adımları yoktur. Gerekçe: SSRF yüzeyi, deterministik tekrar oynatmanın bozulması (dış veri koşunun ortasında değişebilir), döngü riski ve gizli yazma yolu. Gereken veri olayla gelir; zincirleme akış webhook adımı + kiracının göndereceği yeni olayla kurulur (WF-9).
3. **Koşul dili.** Basit, deterministik bir kural dilidir: olay verisi, şemada beyan edilmiş alıcı öznitelikleri ve önceki adımların sonucu (ör. teslim edildi, görüldü, tıklandı, throttle edildi) üzerinde karşılaştırma ve mantıksal birleşim. Kod çalıştırmaz, dış çağrı yapmaz, zamanı yalnız olay ve koşu damgalarından okur. Görsel editörde listelerle kurulur. Bekleme noktasının ikinci aşama eşleme koşulu (§17) aynı dildir. İfade boyutu ve derinliği sınırlıdır (WF-10).
4. **Webhook adımı.** Workflow'daki `webhook` kanalı bir olay hedefidir: kiracı kendi müşterisine imzalı olay teslim eder. Teslim Relay'in kendi webhook'larıyla aynı motordan geçer (retry, imza, DLQ, replay, SSRF koruması; §16). Adımın teslim sonucu sonraki koşulda kullanılabilir; yanıt gövdesi veri olarak workflow'a girmez (WF-11).
5. **Olay bekle adımı.** Olay bekle, ajan ve insan yanıtı için kullanılan bekleme noktasıyla aynı yapı taşıdır (§17). Son tarih zorunludur ve en fazla 30 gündür. Eşleme iki aşamalıdır: önce kiracı + olay türü + korelasyon anahtarı ile birebir eşleşme, sonra isteğe bağlı ek koşul. Bekleme açılmadan önce gelen yanıt kaybolmaz; alıcının kalıcı posta kutusunda tamponlanır ve bekleme açılınca önce oraya bakılır. Süre dolarsa adımın zaman aşımı dalı çalışır (WF-12).

### 10.4 Rota politikaları (WF-13 … WF-20)

1. **Adlandırılmış rota.** Kanal sırası adlandırılmış bir rota politikasında tanımlanır. Rota iç içe `single`/`all` ağacıdır: `single` sırayla dener ve ilk başarıda durur (fallback), `all` hepsine gönderir (fan out). Ağaç düğümlerinde stratejiler kullanılır (WF-13):

| Strateji | Anlam |
|---|---|
| Sırayla dene | Kalıcı başarısızlıkta sıradaki kanala geçer |
| Hepsine gönder | Bütün kanallara paralel gönderir |
| Son aktif kanal | Alıcının en son etkileşim gösterdiği kanalı seçer |
| Kullanıcı tercihi | Alıcının tercih ettiği kanalı seçer (§13) |
| Yalnız son aktif cihaz | Push'u yalnız alıcının son aktif cihazına gönderir |
| Görülmezse yükselt | Etkileşim gelmezse bir sonraki kanala süreyle geçer (§10.5) |

Örnek: `{ "single": ["in_app", { "all": ["push", "email"] }] }`.

2. **Kategori varsayılanı ve öncelik.** Her kategori varsayılan bir rotaya bağlanır; workflow'un kanal adımı başka bir rota seçebilir. Öncelik tek yönlüdür: adım > kategori. Rotalar yeniden kullanılabilir; bir rotada yapılan değişiklik o rotayı kullanan bütün bildirimlere uygulanır (WF-14).
3. **Fallback tetiği.** Varsayılan tetik `on_failure`'dır: kalıcı kanal hatası ya da tükenmiş deneme bütçesi zinciri ilerletir; geçici hata ilerletmez. Zamana bağlı tetik (`after_delay`) isteğe bağlıdır ve rotada açıkça yazılır; sıfır gecikmeli zamana bağlı tetik reddedilir. Retry kanal başınadır ve teslim raporuna dayanır (§12) (WF-15).
4. **Kanal varyantı yoksa.** Şablonun bir kanal için varyantı yoksa o kanala gönderilmez ve `rule_id` ile kaydedilir; `single` düğümünde sıradaki kanala geçilir. "Boş push" gönderilmez (§11) (WF-16).
5. **Cihazlar arası fanout.** Varsayılan: alıcının bütün aktif cihazlarına gönderilir; bir cihazda okununca diğer cihazlarda okundu olur ve bildirim kaldırılır (sessiz push veya collapse; iOS'ta SDK ile, gecikebilir). Kiracı "yalnız son aktif cihaz" stratejisini adımda ya da rotada seçebilir. Aktif realtime bağlantısı olan cihaza ayrıca push gönderilmez (§15) (WF-17).
6. **Güvenlik alt türü rotaları.** `otp_oob` alt türü yalnız SMS, WhatsApp ve sesli aramaya gider; e-posta içeren bir rota bu alt türle kullanılamaz: yayında reddedilir, çalışma anında da fallback e-postaya düşmez. `email_verification` yalnız e-postaya gider. OTP kanal zinciri sabit bir sıra değil, girdilere göre çalışan bir fonksiyondur (§12) (WF-18).
7. **Üreticinin alıcı kümesi.** Access ve Work olaylarında kime gideceğini (alıcı kümesi) üretici belirler. Relay bu kümeyi genişletmez ya da daraltmaz; yalnız kanal, zamanlama ve teslimi yönetir (WF-19).
8. **Alt kiracı kapsamı.** Tanımsız ya da eşleşmeyen alt kiracıya giden teslim kaybolmaz; `skipped` + `scope_mismatch` olarak kaydedilir ve panelde, webhook olayında ve metrikte görünür (WF-20).

### 10.5 Kanal yükseltmesi (WF-21, WF-22)

1. **Varsayılan ve isteğe bağlı.** Varsayılan kanal geçişi yalnız kalıcı hatadadır (WF-15). Kiracı ek olarak "görülmezse yükselt" davranışını workflow'da ya da rotada bilerek açar: `escalate_unless(seen | read | clicked | event)`. Her basamağın süresi ayrı ayarlanır. Örnek: önce in-app; 10 dk görülmezse push; 1 saat içinde tıklanmazsa e-posta; herhangi bir basamakta durdurma koşulu gelirse kalan basamaklar iptal edilir (WF-21).
2. **Sinyal kanıta bağlıdır.** Durdurma koşulu kanal başına tanımlı güvenilir kanıta bağlıdır: in-app görüldü, e-posta tıklaması, push SDK makbuzu, müşteriden gelen olay (§14 kanıt tablosu). Güvenilmez sinyal yükseltmeyi durdurmaz: e-posta açılma pikseli hiçbir koşulda durdurma sinyali değildir. Tıklamada yalnız "insan" sınıfındaki tıklama sayılır; "muhtemel bot" tıklaması sayılmaz (§14) (WF-22).

### 10.6 Eskalasyon politikası (WF-23 … WF-25)

Kanal yükseltmesi "aynı kişiye başka kanal"dır; eskalasyon "başka kişi ve son eylem"dir. İkisi aynı zamanlayıcı mekanizmasını paylaşır.

1. **Kademeler.** Eskalasyon politikası kademelerden oluşur: her kademe bir süre ve yeni bir alıcı ve/veya daha müdahaleci bir kanal tanımlar. Politika panelde, dosyada ve SDK'da tanımlanır. Suiss ekosisteminde politika Work'ten gelir, Relay uygular (§07) (WF-23).
2. **Son kademe yalnız olaydır.** Son kademe `waitpoint.expired` olayıdır. Otomatik kabul ya da ret kararı bekleme noktasının sahibindedir (Suiss'te Work veya Access, dışarıda müşteri kodu) ya da bekleme noktası açılırken baştan beyan edilmiş varsayılan yanıttır. Relay yetki kaynağı olmaz (WF-24).
3. **İki zaman aşımı ve geri alma.** Toplam süre ("insan geç kaldı") ile bekleyen tarafın heartbeat'i ("bekleyen öldü") ayrı ölçülür. Heartbeat kesilirse `waitpoint.stalled` olayı üretilir, bekleme sahipsiz işaretlenir ve eskalasyon durur. Bekleme çözülünce Relay yalnız kendi adımlarını geri alır: bekleyen eskalasyonu ve bekleyen teslimleri iptal eder. İş etkisinin telafisi (saga) Relay'in işi değildir (§17) (WF-25).

### 10.7 Digest (WF-26 … WF-31)

1. **Tek pencere modeli** (WF-26):

| Alan | Anlam |
|---|---|
| `key` | Kiracının tanımladığı opak gruplama anahtarı (ör. `{{data.thread_id}}`); alıcı her zaman anahtarın parçasıdır |
| `mode` | `fixed` (ilk olay pencereyi açar, sabit süre), `sliding` (her yeni olay pencereyi uzatır), `scheduled` (takvim: günlük/haftalık, alıcı saat diliminde) |
| `debounce` | `sliding` modda son olaydan sonra bekleme süresi |
| `max_wait` | Pencerenin ilk olaydan itibaren açık kalabileceği en uzun süre; sürekli akışta açlığı önler |
| `schedule` | `scheduled` modda takvim ifadesi |
| `max_items` | Bu sayıya ulaşınca pencere erken kapanır |
| `leading` | `immediate`: ilk olay hemen gider, tekrarları gruplanır; `none`: hepsi pencere sonunda |
| render | Şablon `total_activities`, `total_actors` ve ilk/son N aktiviteyi görür |

Ateşleme zamanı `sliding` modda `min(son_olay + debounce, ilk_olay + max_wait)`'tir.

2. **Digest değişmezleri** (WF-27):
   - Alıcının okundu sinyali bekleyen digest penceresini iptal eder.
   - Boş digest gönderilmez; tek olaylı digest olayın kendisi olarak gider (tekil şablonla).
   - Önce olay biriktirme tablosuna yazılır, sonra pencere planlanır ya da ötelenir; işi olmayan açık pencereleri bir süpürücü planlar.
   - Digest içeriği veritabanındadır, iş argümanında değildir.
   - Digest çıktısı da tercih, izin, sessiz saat ve frekans kafesinden geçer (§13).
   - Pencere en fazla 31 gün açık kalır.
3. **Digest'lenmeyen sınıflar.** `security`, `transactional` ve `action_required` digest'lenmez. Access'in semantik olayları `security` sınıfındadır ve digest'lenmez (WF-28).
4. **Kümülatif güncelleme.** Digest aynı konunun collapse anahtarını kullanır; pencere kapandıktan sonra gelen ikinci digest birincinin yerini alır ve toplamı anlatır ("5 yeni mesaj" → "8 yeni mesaj") (§12). Inbox'ta digest yeni öğe açmaz; mevcut öğeyi günceller (`activity_count`, son aktörler) (§15) (WF-29).
5. **Yoğunluk eşiği.** Kiracı isteğe bağlı bir yoğunluk eşiği tanımlayabilir: alıcı ya da cihaz başına eşik aşılınca aynı kategorideki sonraki olaylar otomatik olarak bir digest penceresine alınır (WF-30).
6. **Varsayılan pencereler** (WF-31):

| Kullanım | Varsayılan |
|---|---|
| Doğrudan mesaj | `sliding`, debounce 30 sn, `max_wait` 5 dk |
| Grup mesajı | `sliding`, debounce 2 dk, `max_wait` 15 dk |
| Anma (mention) | `sliding`, debounce 1 dk, `max_wait` 10 dk |
| Yorum / inceleme | `sliding`, debounce 5 dk, `max_wait` 1 saat |
| Günlük / haftalık özet | `scheduled` |

### 10.8 Throttle ve gönderim hızı (WF-32 … WF-34)

1. **Throttle adımı.** Alanlar: anahtar, eşik (pencere başına izin verilen sayı), pencere (sabit süre ya da olay verisinden gelen `throttle_until`), alıcı saat diliminde dinamik pencere. Anahtar kiracı genelidir; aynı anahtarı kullanan workflow'lar arasında throttle mümkündür. Aktif bir throttle API ile sıfırlanabilir. Pencere en fazla 31 gündür. Eşiği aşan olay `skipped` + throttle `rule_id`'si ile kaydedilir (WF-32).
2. **Üç ayrı kavram.** Throttle (workflow adımı), frekans tavanı (kategori × kanal politikası; §13) ve teslim hızı (kampanya ya da kanal akışının hız sınırı) ayrı ayarlanır ve birbirinin yerine kullanılmaz (WF-33).
3. **Son teslim tarihi.** Hız sınırlı toplu gönderim bir son teslim tarihi taşır. Tarih tutmayacaksa hız sağlayıcı limitini aşacak şekilde artırılmaz; kalan alıcılar sayımla `expired` olur ve kiracıya olay gider (WF-34).

### 10.9 İçerik tekilleştirmesi (WF-35, WF-36)

1. **Varsayılan.** İçerik tabanlı tekilleştirme varsayılan olarak kapalıdır. Yalnız `operational` sınıfında güvenli varsayılan açıktır: aynı alıcı + aynı kanal + aynı içerik 5 dakika içinde tekrar gelirse gönderilmez. Diğer sınıflarda kiracı workflow başına `content_dedup: { window }` ile açar. Düşürülen her mesaj "atlandı: aynı içerik tekrarı" `rule_id`'siyle kaydedilir (WF-35).
2. **Korumalar ayrıdır.** Idempotency-Key (istek tekrarı), `dedup_key` (olay tekrarı; §9) ve içerik tekilleştirmesi (bu alt bölüm) ayrı korumalardır; teslim defterindeki `(notification, recipient, channel)` tekilliği iç korumadır (§14). Access'in semantik olaylarında (`security` sınıfı) digest, frekans tavanı ve içerik tekilleştirmesi uygulanmaz; idempotency ve `dedup_key` uygulanır (WF-36).

### 10.10 Zamanlama, süre ve saat dilimi (WF-37 … WF-47)

1. **Sert süre limitleri.** Sınırı aşan istek doğrulama hatasıyla reddedilir. Daha uzun vadeli zamanlama müşterinin kendi zamanlayıcısının işidir (WF-37):

| Ne | Üst sınır |
|---|---|
| İleri tarihli gönderim (`send_at`) | 90 gün |
| Bekle adımı | 90 gün |
| Digest / batch penceresi | 31 gün |
| Throttle penceresi | 31 gün |
| Olay bekle ve bekleme noktası (ajan ve insan onayı dahil) | 30 gün |

2. **`expires_at`.** OTP ve doğrulama alt türlerinde zorunludur ve göndericiden gelir; diğer sınıflarda kategori varsayılanı geçerlidir. Kanal TTL'leri (APNs expiration, FCM TTL, Web Push `TTL`, SMS geçerlilik süresi) `expires_at − şimdi` ile türetilir. Süresi geçen mesaj `expired` terminal durumuna geçer ve `rule_id` ile kaydedilir; sessizce silinmez (WF-38).
3. **Süresi geçen güvenlik bildirimi.** Davranışı gönderen belirler: `on_expire: drop | inbox_only`; varsayılan `drop`. Access semantik olayının "ne zamana kadar" alanı `expires_at`'e eşlenir (WF-39).
4. **OTP.** OTP hiç zamanlanmaz (doğrudan çalıştırılabilir iş olarak eklenir), sessiz saatten geçer, digest'lenmez. Eskime değeri sabit bir süre değil, göndericinin `expires_at`'idir (WF-40).
5. **Zamanlama kural sırası.** Bir teslimin gönderim anı şu sırayla hesaplanır (WF-41):

| # | Kural | Not |
|---|---|---|
| 1 | Sınıf geçişi | `security` ve OTP → şimdi; diğer adımlar atlanır |
| 2 | Açık zamanlama | `send_at` ya da bekle adımı tabanı |
| 3 | Yerel saat çevirimi | Alıcı saat dilimi (WF-45) |
| 4 | Sessiz saat ve yasal pencere | Ertele ya da düşür (§13) |
| 5 | Rahatsız etme (DND) | Kiracının bildirdiği `dnd_until` |
| 6 | Frekans tavanı | Ertele, düşür, digest ya da yalnız inbox (§13) |
| 7 | Deterministik jitter | WF-42 |
| 8 | Hız limiti | Kanal ve sağlayıcı limiti (§12) |

Jitter sondan bir öncedir: önce uygulanırsa mesajı sessiz saate iter, sonra uygulanırsa hız limitini bozar. Ertelenmiş iş sessiz saat ve kapıları çalışma anında yeniden değerlendirir; planlama anındaki karar bağlayıcı değildir.

6. **Deterministik jitter.** Bütün yayma işlemleri deterministik bir özet fonksiyonuyla yapılır (ör. `özet(alıcı, yerel_saat) mod yayılım`); rastgele sayı kullanılmaz. Böylece retry ve tekrar oynatma aynı ana düşer, deney bölmesi bozulmaz. API ile aynı dakikaya yığılan tekil zamanlanmış işler de jitter alır; kiracı tam zaman istiyorsa `strict` modunu açıkça seçer. Sessiz saat bitişinde bekleyen mesajlar da jitter'la serbest bırakılır (WF-42).
7. **Uzun bekleme bir satırdır.** Uzun beklemeler (bekle adımı, digest penceresi, bekleme noktası, ileri tarihli gönderim) kalıcı bir satır + zamanlayıcıdır; kuyruk slotu ya da süreç tutmaz. Hiçbir iş 1 saati aşmaz (§19) (WF-43).
8. **Hazırla, sonra tetikle.** Kampanya iki aşamalıdır: hazırlık aşamasında alıcı listesi dondurulur, render ve `dedup_key`'ler üretilir; tetikte yalnız gönderim yapılır. Sağlayıcı bağlantı havuzları tetikten önce ısıtılır. Kampanyanın ilerlemesi ayrı kayıtta tutulur ve kampanya her an iptal edilebilir (§9) (WF-44).
9. **Saat dilimi kaynak zinciri.** Alıcının saat dilimi şu sırayla bulunur: kullanıcının açık seçimi → cihazın bildirdiği → profil ülkesi → kiracı varsayılanı. Kiracı kurulumunda `default_timezone` zorunludur; sistem varsayılanı yoktur (WF-45).
10. **Çıkarımla bulunan saat dilimi.** Saat dilimi cihazdan, ülkeden ya da kiracı varsayılanından çıkarıldıysa, yasal gönderim penceresi olan ülkelerde (ör. ABD TCPA 08:00–21:00) olası saat dilimleri arasında en kısıtlayıcı pencere uygulanır. Telefon ülke kodu ve IP yalnız bu pencere seçiminde kullanılır. Yedek saat dilimiyle giden mesajlar raporda ayrı sayılır. Yasal pencere ile kullanıcının sessiz saati ayrı mekanizmalardır (§13) (WF-46).
11. **Hesap yalnız uygulamada.** Saat dilimi hesabı yalnız uygulama katmanında yapılır. tzdata sürümü imaja sabitlenir, çalışma anında indirilmez ve golden testlerle doğrulanır; düğümler arası sürüm eşitliği izlenir. Veritabanı yalnız UTC saklar; SQL'de `AT TIME ZONE` lint ile yasaktır. IANA bölge kimliği saklanır, ofset saklanmaz (WF-47).

### 10.11 Tekrar eden bildirimler (WF-48, WF-49)

1. **Tekrar kuralı.** Bir alıcı ya da topic için tanımlanır; RRULE mantığıyla yazılır, panelde "her gün / hafta / ay" seçimiyle kurulur. Alıcının yerel saatine göre çalışır (WF-45) (WF-48).
2. **Çalışma biçimi.** Kural tanım olarak saklanır; her tekrar zamanı gelince oluşturulur ve o anda yayında olan workflow ve şablon sürümüyle gider. Uzun süre bekleyen mesaj kaydı tutulmaz. Aynı anda tetiklenen tekrarlara deterministik jitter uygulanır. Kiracı başına tekrar kuralı sayısının üst sınırı vardır. Kural her an iptal edilebilir (WF-49).

### 10.12 A/B ve içerik deneyleri (WF-50)

1. Kanal adımında 2–10 ağırlıklı varyant tanımlanabilir.
2. Bölme birimi kullanıcıdır ve deterministiktir: aynı kullanıcı deney boyunca aynı varyantı görür.
3. Seçilen varyant bildirim kaydına yazılır (denetim ve tekrar oynatma için).
4. Rapor varyant başına gönderim, teslim, görülme ve tıklama sayar; tıklamada insan/bot ayrımı uygulanır (§14).
5. Deney panelde, dosyada ve SDK'da tanımlanabilir.

### 10.13 Kitle: topic, liste, segment (WF-51 … WF-55)

1. **Topic.** Topic bir nesne + abonelik modelidir; en fazla iki seviye hiyerarşi vardır (ör. proje → görev). Alıcılar topic'e abone olur; olay topic'e gönderilir (WF-51).
2. **Fanout.** Fanout anında abone listesi dondurulur; sonradan gelen abone o bildirimi almaz. Aynı alıcı birden fazla yoldan abone olsa da tek bildirim alır. Liste ile gönderimde kiracı alıcıları istekte verir (WF-52).
3. **Eşleşme kuralı.** Topic/abonelik eşleşmesi joker ya da bağlam tam eşleşmesine dayanmaz; abonelik ile tetikleme arasında gizli bir bağlam koşulu yoktur. Hiçbir aboneye ulaşmayan tetikleme `rule_id` ile kaydedilir; sessizce yok olmaz (WF-53).
4. **Segment motoru yok.** Öznitelik sorgulu segmentasyon pazarlama otomasyonu ürünüdür; kiracı segmenti kendi sisteminde hesaplar ve liste olarak gönderir (WF-54).
5. **Ortak temel.** Topic, ajan aboneliklerinin (§17) ve Access olay aboneliğinin (§07) de temelidir (WF-55).

### 10.14 Bağlantılar

- Tercih, izin, sessiz saat ve frekans tavanı WF-41'deki sırada §13'ün kafesiyle uygulanır; kafes kapıları hiçbir workflow ayarıyla atlanamaz.
- Kill switch workflow, kampanya, kanal ve sağlayıcı kapsamında işleri durdurur; durdurulan iş yeniden başlatıldığında kapılar yeniden çalışır (§18).
- Gönderilmeyen her bildirim neden koduyla kaydedilir ve panelde, webhook olayında ve metrikte görünür (§14).

### 10.15 Karar register'ı

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| WF-1 | Workflow (sürümlü adımlar) → şablon (kanal × locale, sürümlü); olay şeması workflow sürümüne ait; bildirim → teslim → deneme hiyerarşisi | FROZEN (teknik) | Şablon değişkenleri yayında şemaya karşı doğrulanabilir; fallback yeni teslim, retry yeni deneme |
| WF-2 | Workflow bir kategoriye, kategori yedi sabit sınıftan birine bağlı; sınıf kabulde atanır, değişmez; gönderen türü ayrı alan | FROZEN (teknik) | §13 sınıf modeli; şerit, uyum ve fiyat sınıfa bağlıdır |
| WF-3 | Görsel editör, dosya (YAML/JSON + JSON Schema) ve SDK eşit yazım yollarıdır; tek tanım biçimi | FROZEN (teknik) | Kod bilmeyen kullanıcı ve git kullanan ekip aynı ürünü kullanır (Novu, Knock) |
| WF-4 | Workflow'un tek yöneticisi (panel ya da kod); koddan yönetilen yapı panelde kilitli, metin ve işaretli alanlar düzenlenebilir | FROZEN (teknik) | İki kaynaktan çakışan yazımı önler (Novu `controlSchema` deseni) |
| WF-5 | Çalışma anında müşteri koduna çağrı yok; bridge modeli yok | FROZEN (teknik) | Müşteri sunucusu düşünce bildirim düşmez; SSRF yüzeyi yok (Novu bridge dersi) |
| WF-6 | Taslak → test → yayın (202); tek işlemle dönüş; çalışan koşu başladığı sürümde biter; CLI `promote`; Mermaid dışa aktarımı | FROZEN (teknik) | Sürümleme ve ortamlar arası taşıma |
| WF-7 | Bildirim oluşurken şablon, layout ve parça sürümleri, adres çözümlemesi, `dedup_key` ve varyant donar; kapılar her denemede yeniden; sabit sürüm gönderilemiyorsa sessiz yükseltme yok | FROZEN (teknik) | Deterministik tekrar oynatma ve denetim; sonradan yayın gönderimi geriye dönük değiştirmez |
| WF-8 | Sekiz adım: kanal, bekle, digest, throttle, koşul, olay bekle, zaman penceresi, webhook | FROZEN (teknik) | Novu, Knock, SuprSend, Courier ortak kesiti; bekleme noktasıyla tek yapı taşı |
| WF-9 | Fetch/HTTP, veri güncelle ve başka workflow çağır adımı yok | KAPSAM DIŞI | SSRF, deterministik tekrar oynatmanın bozulması, döngü riski, gizli yazma yolu; veri olayla gelir, zincir webhook + yeni olayla kurulur |
| WF-10 | Basit, deterministik koşul dili; önceki adım sonucuna bakabilir; görsel editörde listelerle; bekleme noktası ikinci aşama koşuluyla aynı dil | FROZEN (teknik) | Tek dil, tek editör; kod çalıştırmama |
| WF-11 | Webhook adımı ortak teslim motorundan geçer; teslim sonucu koşulda kullanılabilir, yanıt gövdesi veri olmaz | FROZEN (teknik) | Tek teslim motoru (§16); fetch yasağıyla tutarlı |
| WF-12 | Olay bekle = bekleme noktası; son tarih zorunlu, ≤ 30 gün; iki aşamalı eşleme; erken yanıt posta kutusunda tamponlanır; zaman aşımı dalı | FROZEN (teknik) | Inngest `waitForEvent` erken olay kaybı dersi; §17 |
| WF-13 | Adlandırılmış rota: iç içe `single`/`all` ağacı + stratejiler (sırayla dene, hepsine gönder, son aktif kanal, kullanıcı tercihi, yalnız son aktif cihaz, görülmezse yükselt) | FROZEN (teknik) | Courier routing ağacı, Airship kanal stratejileri |
| WF-14 | Kategori varsayılan rotası; adım başka rota seçer; adım > kategori; rotalar yeniden kullanılır, değişiklik hepsine uygulanır | FROZEN (teknik) | Kategori düzeyindeki maliyet ve uyum bilgisi kaybolmaz; tek yerden ezme |
| WF-15 | Fallback varsayılanı `on_failure`; geçici hata zinciri ilerletmez; `after_delay` isteğe bağlı, sıfır gecikme reddedilir; retry kanal başına ve teslim raporuna dayalı | FROZEN (teknik) | Ücretli kanala gereksiz düşüş maliyeti; kabul edilmiş ama ulaşmamış OTP kalıcı hata üretmez |
| WF-16 | Kanal varyantı yoksa o kanala gönderilmez + `rule_id`; `single`'da sıradakine geçilir | FROZEN (teknik) | Boş mesaj sessiz hatadır |
| WF-17 | Varsayılan bütün aktif cihazlar; okununca diğerlerinde okundu ve kaldırılır; "yalnız son aktif cihaz" seçilebilir; realtime bağlı cihaza push yok | FROZEN (teknik) | Çok cihazlı kullanıcıda tutarlılık; iOS'ta kaldırma SDK'ya bağlı ve gecikebilir |
| WF-18 | `otp_oob` rotasında e-posta yok (yayında ve çalışmada); `email_verification` yalnız e-posta; OTP zinciri bir fonksiyon (§12) | FROZEN (teknik) | NIST SP 800-63B e-postayı ayrı kanal saymaz |
| WF-19 | Üreticinin alıcı kümesi değişmez; Relay yalnız kanal seçer | FROZEN (teknik) | Access §7.9.8: kime gideceği üreticinindir |
| WF-20 | Tanımsız/eşleşmeyen alt kiracı `skipped: scope_mismatch`, görünür | FROZEN (teknik) | Sessiz kayıp yok |
| WF-21 | Kanal yükseltmesi isteğe bağlı: `escalate_unless(seen\|read\|clicked\|event)`, basamak başına süre; varsayılan geçiş yalnız kalıcı hatada | FROZEN (teknik) | SuprSend Smart Channel Routing, Notifo "görüldüyse gönderme"; ücretli kanal harcamasını azaltır |
| WF-22 | Durdurma sinyali kanal başına güvenilir kanıta bağlı; açılma pikseli hiçbir zaman; yalnız insan tıklaması | FROZEN (teknik) | Apple Mail Privacy Protection açılma verisini güvenilmez kılar; güvenlik tarayıcıları linke tıklar |
| WF-23 | Eskalasyon politikası: süre → yeni alıcı ve/veya daha müdahaleci kanal; üç yazım yolunda; Suiss'te politika Work'ten | FROZEN (teknik) | Dayanıklı yürütme ve ajan ürünlerinin hiçbirinde yerleşik eskalasyon yok |
| WF-24 | Son kademe yalnız `waitpoint.expired`; otomatik karar sahibinde ya da baştan beyan edilmiş varsayılan yanıtta | FROZEN (teknik) | Relay yetki kaynağı değildir (Access E40, Access EI-18) |
| WF-25 | Toplam süre ≠ heartbeat; heartbeat kesilince `waitpoint.stalled`, sahipsiz, eskalasyon durur; çözülünce Relay yalnız kendi adımlarını iptal eder | FROZEN (teknik) | Step Functions heartbeat dersi; saga Relay'in işi değil |
| WF-26 | Tek digest pencere modeli: `key`, `mode` (fixed/sliding/scheduled), `debounce`, `max_wait`, `schedule`, `max_items`, `leading`, ilk/son N render | FROZEN (teknik) | Knock batch ve Novu digest seçeneklerinin birleşimi; saf debounce sürekli akışta hiç ateşlemez |
| WF-27 | Okundu digest'i iptal eder; boş digest yok; tek olay = olayın kendisi; önce biriktir sonra planla + süpürücü; içerik DB'de; kafesten geçer; ≤ 31 gün | FROZEN (teknik) | Ters sıra olay kaçırır; iş argümanında biriktirme sessiz kayıp üretir |
| WF-28 | `security`, `transactional`, `action_required` digest'lenmez; Access semantik olayları digest'lenmez | FROZEN (teknik) | §13 sınıf kuralları |
| WF-29 | Digest aynı collapse anahtarıyla kümülatif günceller; inbox'ta mevcut öğeyi günceller | FROZEN (teknik) | "1 yeni → 12 yeni" modeli; Liveblocks subject + activity |
| WF-30 | İsteğe bağlı yoğunluk eşiği aşılınca aynı kategorideki olaylar otomatik digest'e | FROZEN (teknik) | Android 16 bildirim soğuması, FCM öncelik düşürme |
| WF-31 | Kullanım başına varsayılan digest pencereleri tablosu | POLICY DEFAULT | Jira Cloud 3 dk / 10 dk deseni; ⚠️ değerler ölçümle ayarlanır |
| WF-32 | Throttle adımı: anahtar, eşik, sabit ya da `throttle_until` pencere, alıcı tz'sinde; kiracı geneli anahtar (workflow'lar arası); API ile sıfırlama; ≤ 31 gün; aşan olay kaydedilir | FROZEN (teknik) | Knock'ta workflow'lar arası throttle ve sıfırlama eksikliği |
| WF-33 | Throttle, frekans tavanı ve teslim hızı ayrı kavramlardır | FROZEN (teknik) | Üç ihtiyaç tek ayara sığmaz |
| WF-34 | Hız sınırlı toplu gönderimde son teslim tarihi; hız sağlayıcı limitini aşmaz; kalanlar `expired` + olay | FROZEN (teknik) | OneSignal throttling bitiş garantisi dersi; sağlayıcı limiti itibar ve teslim doğruluğudur |
| WF-35 | İçerik tekilleştirmesi varsayılan kapalı; `operational`'da 5 dk açık; workflow başına `content_dedup`; düşürülen kaydedilir | FROZEN (teknik) · PD (5 dk) | Meşru tekrarın sessiz düşmesi en zor teşhis edilen hatadır; NotificationAPI isteğe bağlı modeli |
| WF-36 | Idempotency-Key, `dedup_key`, içerik tekilleştirmesi ayrı; teslim defteri iç koruma; Access semantik olaylarında digest/frekans/içerik tekilleştirmesi yok, idempotency var | FROZEN (teknik) | Tek katman yetmez; güvenlik olayı geciktirilemez |
| WF-37 | Sert limitler: `send_at` ve bekle ≤ 90 gün; digest ≤ 31 gün; throttle ≤ 31 gün; olay bekle ≤ 30 gün; aşan istek reddedilir | FROZEN (teknik) | Sektörün üst bandı (Customer.io 90 gün, Knock 31 gün); uzun satırlar şema göçünü ve sürüm sabitlemeyi zorlaştırır |
| WF-38 | `expires_at` OTP/doğrulamada zorunlu, diğerlerinde kategori varsayılanı; kanal TTL'leri ondan türer; `expired` terminal + `rule_id` | FROZEN (teknik) | Geç gelen OTP kullanıcıyı yanıltır |
| WF-39 | `on_expire: drop \| inbox_only`, varsayılan `drop`; Access "ne zamana kadar" → `expires_at` | FROZEN (teknik) | Davranışı gönderen bilir |
| WF-40 | OTP zamanlanmaz, sessiz saatten geçer, digest'lenmez; eskime = `expires_at` | FROZEN (teknik) | OTP asla beklemez |
| WF-41 | Zamanlama sırası: sınıf geçişi → açık zamanlama → yerel saat → sessiz saat/yasal pencere → DND → frekans → jitter → hız limiti; erteleme çalışma anında yeniden değerlendirilir | FROZEN (teknik) | Jitter'ın yeri hem sessiz saati hem hız limitini korur |
| WF-42 | Deterministik jitter her yerde, rastgele sayı yok; tekil zamanlanmış işlere de; `strict` açık seçimle; sessiz saat çıkışı jitter'lı | FROZEN (teknik) | Retry/tekrar oynatma aynı ana düşer; saat başı yığılması yazma yolunu tıkar (ntfy olayı) |
| WF-43 | Uzun bekleme satır + zamanlayıcıdır; hiçbir iş 1 saati aşmaz | FROZEN (teknik) | Kuyruk slotu tutan bekleme ölçeklenmez |
| WF-44 | Kampanya: hazırla (liste, render, `dedup_key`) → tetikle (yalnız gönderim); havuzlar ısıtılır; ilerleme kaydı; iptal | FROZEN (teknik) | Duolingo "hazırla, sonra tetikle" deseni |
| WF-45 | Saat dilimi zinciri: açık seçim → cihaz → profil ülkesi → kiracı varsayılanı; `default_timezone` kurulumda zorunlu, sistem varsayılanı yok | FROZEN (teknik) | Sabit varsayılan AB/ABD kiracısında sessizce yanlış çalışır |
| WF-46 | Çıkarımla bulunan tz'de yasal pencereli ülkede en kısıtlayıcı pencere; ülke kodu/IP yalnız pencere seçiminde; yedek tz raporda ayrı | FROZEN (teknik) | ABD TCPA 08:00–21:00 alıcının gerçek yerel saati; tahmin değil en dar pencere |
| WF-47 | tz hesabı yalnız uygulamada; tzdata imaja sabit + golden test; DB yalnız UTC; `AT TIME ZONE` lint ile yasak; IANA kimliği saklanır | FROZEN (teknik) | İki tzdb sürümü aynı alıcıya iki farklı saat üretebilir (Fas 2026 değişikliği) |
| WF-48 | Tekrar kuralı alıcı ya da topic için, RRULE mantığıyla, alıcının yerel saatinde | FROZEN (teknik) | Fatura hatırlatması gibi tekrarlar kiracı zamanlayıcısı gerektirmez |
| WF-49 | Her tekrar zamanı gelince o anki yayın sürümüyle oluşur; jitter; kiracı başına üst sınır; her an iptal | FROZEN (teknik) · PD (üst sınır) | Uzun bekleyen mesaj kaydı yok; ntfy cron patlaması dersi |
| WF-50 | Kanal adımında 2–10 ağırlıklı varyant; kullanıcı bazlı deterministik bölme; varyant kayda yazılır; varyant raporu; üç yazım yolu | FROZEN (teknik) | Courier send düğümü A/B; tekrar oynatma ve denetim varyantın kayıtlı olmasını ister |
| WF-51 | Topic = nesne + abonelik, en fazla iki seviye | FROZEN (teknik) | Knock Objects, Notifo hiyerarşik topic |
| WF-52 | Fanout anında abone listesi donar; çok yoldan abone tek bildirim alır; liste ile gönderim | FROZEN (teknik) | Knock abonelik snapshot'ı; tekrar oynatma ve denetim |
| WF-53 | Joker ya da bağlam tam eşleşmesi yok; aboneye ulaşmayan tetikleme `rule_id` ile kaydedilir | FROZEN (teknik) | Novu bağlam tam eşleşmesi sessiz kayıp üretir |
| WF-54 | Öznitelik sorgulu segment motoru yok | KAPSAM DIŞI | Pazarlama otomasyonu ürünüdür; kiracı segmenti hesaplayıp liste gönderir |
| WF-55 | Topic ajan aboneliklerinin ve Access olay aboneliğinin temelidir | FROZEN (teknik) | Tek fanout mekanizması |
