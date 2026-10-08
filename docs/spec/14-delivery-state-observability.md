## 14. Teslim Durumu, Analitik ve Gözlem

**Bu bölümün kuralları.**
- Bu bölüm bir bildirimin teslim yaşam döngüsünün nasıl kaydedildiğini, dışarıya nasıl gösterildiğini, "gönderilmedi" kararlarının nasıl kayda geçtiğini ve teslim verisinin analitik ile gözlemde nasıl kullanıldığını tanımlar. Karar ID'leri DS-1…DS-46'dır; register §14.10'dadır.
- Mesaj sınıfları, rota, fallback ve kanal yükseltme §10'da; hata sınıfı tablosu, sağlayıcı adaptörleri ve sağlayıcı idempotency politikası §12'de; tercih, izin ve uyum kapıları §13'te; inbox §15'te; dışarıya olay teslimi §16'da; saklama mekanizması, SLO işletimi ve alarm eşikleri §20'dedir.
- Teslim ve etkileşim hiçbir durumda yetki durumu değildir. Relay'in teslim kaydı bilgidir; onay, yetki ya da iş sonucu kanıtı değildir (Access E30, Access E40).
- Bu bölümdeki tablolar (kanıt tablosu, pencere tablosu, neden sözlüğü) kod değil sürümlü veridir; değişiklikleri dağıtım beklemeden yapılır ve denetim kaydına girer.

---

### 14.1 Kayıt modeli

#### 14.1.1 Bildirim, teslim, deneme, defter olayı (DS-1)

Teslim verisi dört düzeyde tutulur:

| Düzey | Ne | Örnek |
|---|---|---|
| **Bildirim** | Bir alıcı için bir tetiklemenin mantıksal kaydı. Plan (şablon sürümleri, adres çözümlemesi, `dedup_key`) burada sabitlenir (§10) | "Sipariş kargoya verildi", alıcı `u_42` |
| **Teslim** | Kanal × adres (ya da cihaz) × sağlayıcı hedefi | Aynı bildirimin SMS'i, push'u (cihaz başına) ve inbox öğesi: üç ayrı teslim |
| **Deneme** | Bir teslimin sağlayıcıya tek gönderim girişimi | SMS'in ikinci denemesi |
| **Defter olayı** | Bir teslim ya da deneme hakkında gelen her bilgi (Relay'in kendi olayları, sağlayıcı API yanıtı, sağlayıcı webhook'u, istemci SDK makbuzu, kullanıcı eylemi) | `dlr.delivered`, `bounce.hard`, `inbox.read` |

Kurallar:
1. **Retry yeni deneme açar, fallback yeni teslim açar.** Aynı kanala yeniden gönderim aynı teslimin yeni denemesidir. Başka kanala geçiş (ör. SMS → WhatsApp) yeni bir teslimdir ve `fallback_of` ile öncekine bağlanır.
2. **Engellenen hedef de teslim kaydı açar.** Bir kapı ya da kural yüzünden gönderilmeyen teslim, kuyrukta değil teslim kayıtlarında görünür (§14.5).
3. **Bir kanalda tek canlı teslim.** Aynı bildirim için aynı kanal ve hedefte aynı anda yalnız bir canlı teslim vardır; bu DB kısıtıyla korunur.

#### 14.1.2 Değişmez defter (DS-2)

1. `delivery_events` append-only'dir: satır güncellenmez, silinmez (Access OP-73). Teslimin bütün durum alanları bu defterden türetilmiş projeksiyondur ve her zaman defterden yeniden kurulabilir.
2. Haftalık **yeniden kurma testi** çalışır: projeksiyon, defterden yeniden hesaplanan değerle karşılaştırılır; fark sorgusu boş dönmelidir, dönmezse alarm üretir.
3. Geç gelen olay her zaman deftere yazılır; projeksiyonu yalnız aşağıdaki monotonluk kurallarının izin verdiği yönde değiştirir (DS-4).

#### 14.1.3 Dört eksen (DS-3)

İç model tek bir durum alanına sıkıştırılmaz; üç ayrı soru ("iş hangi aşamada", "sağlayıcı ne dedi", "kullanıcı ne yaptı") ve bir hata sorusu dört eksende tutulur:

| Eksen | Değerler | Yazan | Monoton mu |
|---|---|---|---|
| **Deneme** | `pending`, `in_flight`, `succeeded`, `failed`, `unknown` | Yalnız Relay | Hayır (her deneme kendi yaşam döngüsünü taşır) |
| **Teslim (kesinlik)** | `none` < `accepted` < `delivered` | Kanıt tablosu (DS-10) | Evet, asla azalmaz |
| **Hata türü** | `skipped`, `failed`, `bounced`, `expired`, `cancelled` + hata sınıfı (§12 tablosu) + `reason` + `rule_id` | Kanıt tablosu ve politika kararları | Kanal başına tabloya göre (DS-6) |
| **Etkileşim** | `seen`, `read`, `clicked`, `archived`; her biri ayrı zaman damgası, kaynak ve (tıklamada) insan/bot sınıfıyla | Kanıt tablosu, inbox eylemleri, SDK makbuzları | Her biri kendi içinde; birbirinden ve teslim ekseninden bağımsız |

Örnek: bir SMS denemesi sağlayıcıda zaman aşımına uğrar (deneme `unknown`), ikinci deneme kabul edilir (teslim `accepted`), sonra ilk denemenin geç DLR'ı `delivered` gelir. Sonuç: teslim `delivered`; iki deneme de teslim olduysa bu `duplicate_delivered` olarak görünür (DS-5).

#### 14.1.4 Monotonluk ve olay indirgeme (DS-4)

1. Monotonluk koşullu güncellemeyle sağlanır: projeksiyon yalnız yeni değerin sırası mevcut değerden büyükse güncellenir. Güncelleme sıfır satır etkilerse olay "geç olay" sayılır ve metriğe yazılır; olay yine defterdedir.
2. DB kısıtları tutarsızlığı engeller (ör. terminal durumda zaman damgası zorunlu); monotonluğun kendisi tek yerde, yazma yolundadır.
3. Aynı teslim için olaylar şu sırayla indirgenir: (a) deneme numarası (eski denemenin geç olayı yeni denemenin durumunu ezemez); (b) aynı sağlayıcı kapsamında sağlayıcı sıra numarası; (c) `occurred_at`, sonra `received_at` (`received_at` Relay'in alma sırasıdır, olayın gerçekleşme sırası değildir); (d) yalnız aynı deneme ve aynı olay türü için kaynak önceliği: sağlayıcı webhook'u > sağlayıcı API'si > Relay.
4. Zaman damgaları geleceğe yazılamaz: `occurred_at ≤ received_at + 1 saat`; istemciden gelen eylem zamanı sunucu saatiyle sınırlanır.

#### 14.1.5 Sonucun tüm denemelerden türetilmesi (DS-5)

1. Bir teslimin sonucu bütün denemelerinden türetilir. Herhangi bir denemenin geçerli `delivered` kanıtı teslimi `delivered` yapar.
2. `delivered` yalnız aynı denemenin önceki hata kaydını geçersiz kılar; başka denemenin hatası olduğu gibi defterde kalır.
3. İki deneme de teslim olduysa bu gizlenmez: `duplicate_delivered` bayrağı ve metriği görünür kalır. Çelişen kanıtlar `has_conflict` ile işaretlenir.

#### 14.1.6 Teslimden sonra gelen hata (DS-6)

"`delivered`'dan sonra hata gelemez" evrensel bir kural değildir; kanal başına tablodur (`after_delivered`):

| Değer | Anlamı | Örnek |
|---|---|---|
| `valid` | Hata geçerlidir; hata ekseni ayarlanır, teslim ekseni `delivered` kalır, projeksiyon `failed` olur | E-postada asenkron bounce; WhatsApp'ta numaranın sonradan geçersizleşmesi |
| `stale` | Olay deftere yazılır, projeksiyonu değiştirmez | Teslimden sonra gelen süre aşımı (teslim edilmiş mesajın TTL'i dolmaz) |
| `conflict` | Olay yazılır, teslim `has_conflict` ile işaretlenir | Okunmuş mesaj için gelen kalıcı hata (okunmuş mesaj başarısız sayılamaz) |

#### 14.1.7 Okuma ve kaynak (DS-7)

1. Okuma olayı kaynağını taşır: `inbox_action`, `provider_signal`, `client_sdk`.
2. Bir kanaldaki okuma yalnız kendi kanalının teslimini kanıtlar. Inbox'ta yapılan eylem aynı bildirimin SMS ya da push teslimini kanıtlamaz.
3. Bir okuma olayı kendi teslimini `delivered`'a yükseltir; tersi yönde kural yoktur.

#### 14.1.8 Olay kaynağı sözlüğü (DS-8)

Defter olayının `actor` alanı: `relay`, `provider_api`, `provider_webhook`, `client_sdk`, `user`. `client_sdk` cihazdaki uygulamanın gönderdiği makbuzdur (gösterildi, tıklandı); `user` insan eylemidir. İkisi karıştırılmaz.

#### 14.1.9 Bildirim düzeyi durum (DS-9)

Bildirim düzeyinde ayrı bir teslim durumu uydurulmaz. Bildirimin teslim görünümü, teslimlerinin listesi ve durum başına sayımıdır. Workflow'un çalışma durumu (bekliyor, tamamlandı, iptal) ayrı alandır (§10).

---

### 14.2 Kanal başına kanıt tablosu

#### 14.2.1 Kanıt tablosu (DS-10)

`channel_event_evidence` her kanal × olay kodu için şunları tanımlar:

| Alan | Değerler | Anlamı |
|---|---|---|
| `effect_kind` | `evidence`, `operational_signal`, `side_effect` | Olay teslim kanıtı mı, işletim sinyali mi, yan etki tetikleyicisi mi |
| `sets_delivery` | `none`, `accepted`, `delivered` | Teslim eksenine etkisi |
| `sets_failure` | hata türü ya da `none` | Hata eksenine etkisi |
| `attempt_effect` | `none`, `succeeded`, `failed`, `unknown` | Deneme eksenine etkisi |
| `after_delivered` | `valid`, `stale`, `conflict` | DS-6 |
| `projection_effect` | `none`, `raise_delivery`, `set_failure`, `flag_conflict` | Projeksiyona etkisi |
| `side_effect` | `none`, `deactivate_device`, `add_suppression` | Örn. APNs 410 cihazı pasifleştirir; hard bounce bastırma ekler (§12, §13) |
| `scope` | `attempt`, `delivery` | Deneme kapsamlı olay deneme kimliği ister; teslim kapsamlı olay almaz |
| `decision_grade` | `reliable`, `unreliable` | Olay etkileşim tabanlı kararlara (kanal yükseltme, eskalasyon durdurma, digest iptali) girdi olabilir mi |

Kurallar:
1. Tabloda tanımlı olmayan olay kodu reddedilir.
2. Eşlemesi olmayan sağlayıcı kodu projeksiyonu değiştirmez; `unknown_provider_code` olayı yazılır ve alarm üretilir. Sessiz düşürme yoktur.
3. Sağlayıcı kodundan normalleştirilmiş olaya eşleme de veridir; ham sağlayıcı kodu ve DSN alanları defterde her zaman saklanır ("grup + ayrıntı").

#### 14.2.2 Adaptör kanıt sözleşmesi (DS-11)

Bir kanal adaptörü şu üçü olmadan devreye alınmaz: (1) kanıt tablosu satırları, (2) her sağlayıcı kodu için test vektörü, (3) §12'deki sağlayıcı idempotency politikası beyanı. Yeni sağlayıcı kodu dağıtım beklemeden tabloya eklenir.

#### 14.2.3 Kanal teslim semantiği (DS-12)

Bu tablo normatif özettir; ayrıntı kanıt tablosundadır. Müşteri dokümantasyonu bu tablodan üretilir.

| Kanal | `sent` ne demek | `delivered` kanıtı | Etkileşim kanıtı | Karar girdisi olabilen sinyal | Not |
|---|---|---|---|---|---|
| E-posta | ESP ya da bağlı MTA kabul etti | Sağlayıcının teslim olayı ya da başarı DSN'i; insan tıklaması | Açılma (güvenilmez), tıklama (insan/bot ayrımlı) | Yalnız insan tıklaması | Asenkron bounce teslimden sonra geçerlidir (`valid`) |
| SMS | Sağlayıcı kabul etti | DLR `delivered` | Yok | Yok | DLR saatlerce gecikebilir ya da hiç gelmeyebilir (DS-18) |
| WhatsApp | Sağlayıcı kabul etti | `delivered` olayı | `read` (alıcı kapatabilir; yokluğu bilgi değildir), etkileşimli yanıt | `read` | `read`, `delivered`'dan önce gelebilir |
| Push (APNs, FCM, Web Push) | Sağlayıcı kabul etti | Yalnız mobil/web SDK'nın "gösterildi" makbuzu (`client_sdk`) | SDK "gösterildi" ve "tıklandı" makbuzları | SDK makbuzları | Sağlayıcı kabulü teslim sayılmaz (DS-13) |
| In-app | — | Inbox öğesinin kalıcı kaydının commit'i | `seen`, `read`, `clicked`, `archived` (§15) | `seen`, `read`, `clicked` | Teslim = kalıcı kutuya yazıldı; görüldü ayrı eksendir |
| Webhook kanalı | — | Hedefin başarı yanıtı (§16) | Yok | Yok | Teslim kuralları §16 |
| Sesli arama | Sağlayıcı aramayı başlattı | Sağlayıcının "cevaplandı/tamamlandı" olayı | Tuşlama yanıtı (varsa) | Yok | Ayrıntı sağlayıcı satırlarında |

Yeni kanal, tabloya satırı ve kanıt tablosu yazılmadan devreye alınmaz.

#### 14.2.4 Push'ta teslim iddiası (DS-13)

1. Sağlayıcı kabulüne (APNs 200, FCM kabul, Web Push 201) dayanarak `delivered` iddia edilmez. Push teslimi, SDK makbuzu yoksa `sent`'te kalır ve raporda "sağlayıcı kabul etti" diye gösterilir.
2. Push'a DLR penceresi uygulanmaz; push hiçbir zaman `unknown`'a düşmez (beklenecek bir DLR yoktur).
3. Teslim oranı raporu push için "kabul oranı" ile "SDK makbuzlu teslim oranı"nı ayrı gösterir.

---

### 14.3 Dış projeksiyon

#### 14.3.1 Projeksiyon alanları (DS-14)

API ve webhook'larda iç model değil sade bir projeksiyon görünür:

| Alan | Değerler |
|---|---|
| `status` | `queued`, `sent`, `delivered`, `unknown_pending`, `unknown`, `failed`, `skipped`, `expired`, `cancelled` |
| `engagement` | `seen`, `read`, `clicked`, `archived` için ayrı zaman damgaları; `clicked` için insan/bot ayrımı |
| `reason`, `rule_id` | `skipped`, `failed`, `expired`, `cancelled` durumlarında zorunlu; erteleme kararlarında da bulunur (DS-27) |
| `failure` | `kind` (`bounced`, `failed` …), `class` (§12 hata sınıfı), normalleştirilmiş kod, `retryable` |

Durumların anlamı:

| `status` | Anlamı |
|---|---|
| `queued` | Kabul edildi; gönderimi bekliyor (zamanlanmış, ertelenmiş, hız limitinde bekleyen dahil) |
| `sent` | Sağlayıcı kabul etti; kesin teslim kanıtı yok |
| `delivered` | Kanal tablosundaki teslim kanıtı geldi (DS-12) |
| `unknown_pending` | Kısa pencere doldu, kesin olay yok; hâlâ bekleniyor |
| `unknown` | Uzun pencere doldu, kesin olay yok; geç olay gelirse yükselir |
| `failed` | Kesin hata (bounce dahil; `failure.kind` ayırır) |
| `skipped` | Relay kararıyla gönderilmedi (§14.5) |
| `expired` | Mesaj `expires_at`'i geçti, gönderilmedi |
| `cancelled` | Gönderilmeden iptal edildi |

#### 14.3.2 Projeksiyon türetme kuralı (DS-17)

1. Teslim ekseninde `delivered` varsa ve hata ekseninde `after_delivered = valid` olan bir hata yoksa `status = delivered`.
2. Geçerli kesin hata varsa `status = failed`; `delivered_at` korunur (ör. e-postada teslimden sonra gelen bounce).
3. Kesin olay yoksa pencere kuralları uygulanır: `sent` → `unknown_pending` → `unknown` (DS-18).
4. Geç gelen kesin olay `unknown_pending` ve `unknown`'ı her zaman yükseltir (`unknown` < `delivered`; `unknown` → `failed` de olur).
5. `skipped`, `expired`, `cancelled` gönderim olmadığı için kesin terminaldir.

#### 14.3.3 Sözleşme kararlılığı (DS-15)

Dış projeksiyon, iç model değişse de sabit kalır. İç eksenlere değer eklemek ya da kanıt tablosunu değiştirmek dış sözleşmeyi bozmaz; `status` kümesine değer eklemek ancak API sürümleme kurallarıyla yapılır (§9). Projeksiyon yazılan sözleşme AsyncAPI/OpenAPI belgelerindedir (§9).

#### 14.3.4 Deneme geçmişi ve defter erişimi (DS-16)

Deneme geçmişi ve defter olayları panelde ve ayrı bir API ucunda okunur: her deneme için zaman, sağlayıcı, normalleştirilmiş sonuç, ham sağlayıcı kodu ve (yetki kapsamına göre) sağlayıcı yanıtı. Ham yanıttaki kişisel veriler yetkisiz görünümde maskelidir; açık gösterme hassas işlemdir (§18).

---

### 14.4 DLR pencereleri ve `unknown`

#### 14.4.1 İki aşamalı pencere (DS-18)

1. Kesin teslim olayı beklenen kanallarda `sent`'ten sonra iki pencere işler: **kısa pencere** dolunca teslim görünür biçimde `unknown_pending` olur; **uzun pencere** dolunca `unknown` olur.
2. Pencereler kanal başına veridir; kanal × sağlayıcı ve kiracı düzeyinde sıkılaştırılabilir ya da uzatılabilir (üst sınır içinde).
3. `unknown` dürüst bir durumdur: Relay kesin olay yokken `delivered` ya da `failed` uydurmaz.

#### 14.4.2 Varsayılan pencereler (DS-19)

| Kanal | Kısa pencere (`unknown_pending`) | Uzun pencere (`unknown`) |
|---|---|---|
| SMS | 6 saat | 72 saat |
| E-posta | 24 saat | 72 saat |
| WhatsApp | 36 saat | 7 gün |
| Sesli arama | 1 saat | 24 saat |
| Push, in-app, webhook kanalı | Uygulanmaz | Uygulanmaz |

#### 14.4.3 Geç kesin olay (DS-20)

Geç gelen kesin olay (`delivered`, `failed`) ne zaman gelirse gelsin kabul edilir, deftere yazılır ve projeksiyonu yükseltir. Olayın teslim saklama süresi dolmuş bir kayda ait olması hâlinde olay yalnız deftere yazılır ve sayılır.

#### 14.4.4 Otomatik yeniden gönderim yok (DS-21)

1. `unknown` ya da mutabakatın "teslim edilmedi" sonucu için otomatik yeniden gönderim yapılmaz. Yeniden gönderim sınıfa göre insan ya da kiracı kararıdır (OTP'de anlamsız, işlemsel mesajda değerli olabilir, pazarlamada yapılmaz) ve yeni bir istekle yapılır.
2. `unknown` fallback tetiklemez; fallback yalnız kalıcı hatada ilerler (§10).
3. Zaman tabanlı "görülmezse yükselt" adımları ve eskalasyon zamanlayıcıları `unknown`'dan bağımsız çalışır; durdurma koşulları yalnız `decision_grade = reliable` sinyallerdir (DS-10, §10).

#### 14.4.5 Mutabakat (DS-22)

1. Gelen sağlayıcı olayları sağlayıcı olay kimliğiyle kalıcı olarak tekilleştirilir (`webhook_receipts`; §16.10).
2. Webhook kaybına karşı kanal başına periyodik mutabakat çalışır: açık teslimler için sağlayıcının durum ya da olay API'sinden çekme yapılır. Mutabakat sıklığı kanal tablosunda tutulur; varsayılan değer ölçümle konur.
3. Mutabakat da defter olayı üretir (`actor = provider_api`) ve aynı monotonluk kurallarına tabidir; kesin olay bulamazsa yalnız pencere kuralı işler.

#### 14.4.6 Test düzleminde teslim simülasyonu (DS-23)

Test düzleminde (§8.9, §18) sahte sağlayıcı adaptörü belirli test adreslerine belirli sonuçlar üretir: anında teslim, gecikmeli teslim, bounce, hiç DLR gelmemesi, geç DLR, mükerrer teslim. Sanal saatle pencereler ileri sarılarak `unknown_pending` → `unknown` → geç `delivered` akışı test edilir.

---

### 14.5 Atlama ve karar kayıtları

#### 14.5.1 Sessiz kayıp yok (DS-24)

1. Gönderilmeyen her bildirim ya da teslim bir neden koduyla kaydedilir ve üç yerde görünür: panel, `notification.suppressed` webhook olayı (§16), metrik.
2. Kapsam uyuşmazlığı (tanımsız ya da eşleşmeyen alt kiracı), kill switch, İYS reddi ve sessiz saatte düşürme dahil her atlama kayıt açar.

#### 14.5.1a Karar hata değildir (DS-26)

Politika sonuçları kabulden (202) sonra `skipped` + `rule_id` olarak raporlanır; kabul yanıtı bir politika kararı yüzünden hata dönmez. Senkron karar sonucu yalnız önizleme, test ve dry-run uçlarında döner (§9). Her karar kaydı `decision` ve kural kimliğini taşır.

#### 14.5.2 Tek kural sözlüğü (DS-25)

1. Bütün atlama, erteleme ve engelleme kararları tek bir `rule_id` sözlüğünden gelir. Sözlük sürümlü veridir; her kural kimliği bir `reason` koduna ve kuralın tanımlandığı bölüme bağlıdır.
2. Neden aileleri:

| `reason` ailesi | Örnek kural | Ek alan |
|---|---|---|
| `preference_off` | Kullanıcı tercihi kapalı | Kapatan seviye: kategori × kanal / bildirim türü / tek nesne (`scope_key`) / haftalık program (§13) |
| `consent_missing`, `consent_revoked`, `iys_rejected` | İzin yok, geri çekildi, İYS'de onay yok ya da senkron bayat | İzin kaydı referansı (§13) |
| `suppressed_address` | Bastırma listesi (hard bounce, şikâyet, çıkış) | Bastırma kaydı referansı |
| `quiet_hours_dropped` | Sessiz saatte düşürme politikası | Alıcı yerel saati, saat dilimi kaynağı |
| `frequency_capped` | Frekans tavanı | Tavan kuralı |
| `duplicate_content` | İçerik tekilleştirme penceresi | Pencere ve eşleşen bildirim |
| `scope_mismatch` | Alt kiracı tanımsız ya da eşleşmiyor | İstenen kapsam |
| `kill_switch` | Kill switch | Switch kaydı ve sebebi |
| `no_channel_variant` | Kanalın şablon varyantı yok | Şablon sürümü |
| `no_address` | Kanal adresi ya da aktif cihaz yok | — |
| `no_permission` | Cihazda OS bildirim izni yok | Cihaz izin durumu |
| `country_rule` | Ülke uyum tablosu kuralı | Ülke × kanal × sınıf satırı |
| `channel_policy` | Sınıf–kanal kuralı (ör. `otp_oob` e-postaya düşmez) | — |
| `tenant_suspended`, `sender_unverified` | Kiracı ya da gönderici askıda, gönderici kimliği onaysız | — |
| `expired` | `expires_at` geçti | — |
| `cancelled` | İptal komutu ya da tombstone | İptal isteği |

3. Render hatası atlama değildir; ayrı olaydır: `notification.render_failed` + `failure_reason` (`missing_variable`, `render_timeout`, `output_too_large`, `schema_violation`) (§11).

#### 14.5.3 Erteleme kaydı (DS-27)

Ertelenen gönderim (sessiz saat, frekans tavanında `defer`, hız limiti, zaman penceresi) atlama değildir. Defterde erteleme olayı (`deferred`, `reason`, `rule_id`, `deferred_until`) yazılır; projeksiyon `queued` kalır ve `deferred_until` alanını taşır. Ajan kaynaklı bildirimlerde tavan aşımıyla kalıcı bekletme de bu sınıftadır (§17).

#### 14.5.4 "Neden almadım" sorgusu (DS-28)

Panel ve API, bir alıcı ve zaman aralığı için her bildirimin karar zincirini gösterir: hangi kapıdan geçti, hangi kural hangi seviyede durdurdu ya da erteledi, hangi kanallara hangi sonuçla gidildi. Sorgu defterden ve karar kayıtlarından okunur; panel ekranının yanıt hedefi §8'dedir.

---

### 14.6 Etkileşim, açılma ve tıklama

#### 14.6.1 Takip varsayılanları (DS-29)

1. E-posta açılma pikseli ve link sarmalama her yerde varsayılan kapalıdır; kiracı kategori ya da şablon düzeyinde açar.
2. `security` sınıfında ve OTP/doğrulama e-postalarında takip hiçbir koşulda açılamaz; bu e-postalarda link sarmalama ve piksel yoktur.

#### 14.6.2 İnsan ve bot tıklaması (DS-30)

1. Her tıklama `human` ya da `likely_bot` olarak sınıflanır. Sinyaller: teslimden saniyeler sonra gelen tıklama, aynı mesajdaki bütün linklere aynı anda tıklama, bilinen güvenlik tarayıcısı IP blokları, user-agent ve istek biçimi.
2. Sinyal listesi ve eşikleri sürümlü veridir; sınıflandırma sonucu ve hangi sinyalin karar verdiği olayda saklanır.
3. Raporlarda insan ve bot tıklamaları ayrı gösterilir; birleşik "tıklama" sayısı ayrıca verilmez.

#### 14.6.3 Kararlarda yalnız insan tıklaması (DS-31)

Kanal yükseltmesini durdurma, eskalasyonu durdurma ve diğer etkileşim tabanlı kararları e-posta kanalında yalnız insan tıklaması tetikler.

#### 14.6.3a Tıklamanın teslim kanıtı olması (DS-34)

İnsan tıklaması e-posta teslim kanıtıdır: sağlayıcının teslim olayı gelmemiş olsa da teslimi `delivered`'a yükseltir (`actor = user`). Bot olarak sınıflanan tıklama ve açılma teslim kanıtı sayılmaz; teslim oranı raporu bu kurala göre hesaplanır.

#### 14.6.4 Açılma verisi (DS-32)

1. Açılma verisi Relay'in hiçbir kararında kullanılmaz ve teslim kanıtı sayılmaz.
2. Etkileşim olaylarında `machine_open` bayrağı bulunur (Apple Mail Privacy Protection, proxy önbellekleri, güvenlik tarayıcıları); açılma metriği bu bayrakla ayrıştırılır.
3. Açılma pikseli açıkken panelde güvenilmezlik uyarısı gösterilir.

#### 14.6.5 Etkileşim ekseninin bağımsızlığı (DS-33)

Etkileşim olayları teslim sonucundan bağımsız ilerleyebilir (ör. `failed` görünen bir e-postada sonradan gelen tıklama). Olay kaydedilir; güvenilir etkileşim kanıtı ise kendi teslimini DS-7 ve DS-34'e göre yükseltir.

---

### 14.7 Analitik

#### 14.7.1 Hazır raporlar (DS-35)

1. Hazır raporlar Postgres özet tablolarından (rollup) üretilir; rollup'lar defterden türetilir ve yeniden hesaplanabilir. Relay içinde OLAP motoru yoktur.
2. Rapor seti: teslim hunisi; kanal ve sağlayıcı başına kabul, teslim, `unknown`, hata oranları; etkileşim (insan/bot ayrımıyla, açılma `machine_open` ayrımıyla); A/B varyantı başına gönderim, teslim, görülme, tıklama; maliyet (sağlayıcı fiyat tablosundan, segment/alıcı birimiyle); atlama nedeni dağılımı (`reason` × `rule_id` × seviye); yedek saat dilimiyle giden mesaj sayısı (§10).
3. Test gönderimleri (`is_test`) ve test düzlemi ayrı satırlardır; ürün metriklerine karışmaz.

#### 14.7.2 Teslim hunisi (DS-36)

1. Huni aşamaları: kabul → kuyruğa alındı → sağlayıcıya gönderildi → sağlayıcı kabul etti → teslim edildi → etkileşim.
2. Aşamalar arası boşluklar ölçülür. "Kabul edildi ama kuyruğa girmedi" sıfırdan büyükse bu veri kaybıdır ve en yüksek önemde alarmdır (kabul ve kuyruk kaydı aynı transaction'dadır; §19).
3. Birincil teslim sağlık metriği hata oranı değil **huni tamlığıdır**.
4. Push hunisi "sağlayıcı kabul etti" aşamasında biter; SDK makbuzu varsa ayrı satır olarak devam eder (DS-13).

#### 14.7.3 Olay akışı ve dışa aktarım (DS-37)

1. Bütün anlamsal olaylar (teslim geçişleri, etkileşimler, atlamalar, kararlar) kiracının hedefine sürekli akıtılabilir: S3 uyumlu depo, Kafka, kuyruklar, webhook. Akış §16'daki teslim motorunu kullanır.
2. Ham veri CSV ve Parquet olarak dışa aktarılabilir.
3. ClickHouse ve benzeri analitik veritabanları yalnız teslim hedefi olarak bağlanır.

#### 14.7.4 Faturalama verisi (DS-38)

Faturalama metriklerden değil, değişmez kullanım kayıtlarından (`usage_records`) yapılır. Kullanım kaydı faturalanabilir olayla aynı transaction'da yazılır; metrik kaybı faturayı etkilemez.

#### 14.7.5 Kesin sayaçlar (DS-39)

Deneme, teslim ve kullanım sayaçları Postgres'te kesindir. Teslim yolunda olasılıksal yapı (Bloom filtresi, HyperLogLog) kullanılmaz; yanlış pozitif gönderilmeyen bildirim demektir. Olasılıksal yapılar yalnız operatör metriklerinde (ör. benzersiz cihaz tahmini) kullanılabilir.

---

### 14.8 Gözlem

#### 14.8.1 Tek iz (DS-40)

1. Tetiklemeden workflow adımına, sağlayıcı çağrısına ve DLR webhook'una tek bir iz (trace) uzanır. `traceparent` defter olaylarına ve iş meta verisine yazılır; geç gelen sağlayıcı webhook'u asıl ize span link ile bağlanır.
2. İz bağlamı her süreç sınırında açıkça taşınır; bağlam taşımayan süreç başlatma CI kuralıyla yasaktır.
3. Span öznitelikleri kişisel veri içermez. Kiracı etiketi kardinalite kuralıyla kullanılır (§20).

#### 14.8.2 Görünür kalan teslim metrikleri (DS-41)

Şu metrikler her zaman üretilir ve gizlenmez: `duplicate_delivered` ve çakışma sayısı; geç olay sayısı; kanal × sağlayıcı başına `unknown_pending` ve `unknown` oranı; `unknown_provider_code` sayısı; huni boşlukları; mutabakat gecikmesi; DLR gecikmesi dağılımı; bot tıklama oranı. Alarm eşikleri §20'dedir.

#### 14.8.3 SLO tablosu (DS-42)

Mesaj sınıfı başına tek bir SLO tablosu tutulur (kabul gecikmesi, sağlayıcıya gönderim gecikmesi, erişilebilirlik). Değerler ölçülene kadar sayı yazılmaz; tablo §20'de işletilir.

#### 14.8.4 Access sınırı (DS-43)

Access'in mesajları Relay'den gittiğinde teslim durumu Access'e yalnız bilgi olarak döner (webhook ya da API). Relay'in Access state'ini değiştiren hiçbir çağrısı yoktur. Teslim, okundu ya da ack bir yetki durumu, onay ya da kimlik kanıtı değildir (Access E30, Access E40, Access EI-18).

---

### 14.9 Saklama ve içerik minimizasyonu

#### 14.9.1 Saklama sınıfları (DS-44)

1. Teslim verisi Access OP-73 ve Access OP-74'e tabidir: fiziksel silme yoktur; kişisel alanlar özne × saklama sınıfı DEK'iyle şifrelidir; saklama sonu yumuşak silme + crypto-shredding + soğuk arşivdir. Süreler ve dayanaklar Access Ek C'deki bölge × sektör tablosundan gelir.
2. Bu bölümün saklama sınıfları: **teslim kayıtları** (defter, deneme, projeksiyon) ve **ticari ileti gönderim/teslim kayıtları** (`message_log`; Türkiye'de 10 yıl, 6563 m.11/3). Bildirim içeriği ayrı sınıftır (§11, §20).
3. Defter kademeli saklanır (sıcak, ılık, soğuk arşiv); uyum kanıtı iş kuyruğu tablolarının temizlenmesinden etkilenmeyen kalıcı kayıtlarda ve arşivde tutulur. Mekanizma §20'dedir.

#### 14.9.2 İçerik minimizasyonu (DS-45)

1. Teslim kaydı render edilmiş içeriği saklamaz; içerik özeti ile şablon, layout ve parça sürümlerini saklar. "Hangi metni gönderdin" sorusu sürüm + değişken özetiyle cevaplanır.
2. Kiracı render içeriğinin saklanmasını açabilir; içerik ayrı saklama sınıfında tutulur.
3. OTP ve doğrulama alt türlerinde render içerik hiçbir koşulda saklanmaz (yalnız özet + şablon sürümü). Mesaj başına `retention: none` bayrağı kiracı ayarından bağımsız olarak içerik saklamayı kapatır; bu bayrakla in-app kanalı birleşimi kabulde reddedilir (§15).
4. Ham sağlayıcı yanıtları defterde tutulur; kişisel veri taşıyan alanları içerik sınıfının anahtarıyla şifrelenir.

---

### 14.10 DS karar register'ı (DS-1–DS-46)

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| DS-1 | Bildirim → teslim → deneme → defter olayı hiyerarşisi; retry yeni deneme, fallback yeni teslim (`fallback_of`); engellenen hedef de teslim kaydı açar; kanal başına tek canlı teslim (§14.1.1) | FROZEN (ürün) | Knock (`workflow_run_id` / `workflow_recipient_run_id`), Courier ve SuprSend aynı ayrımı yapar; skip'in kuyrukta kaybolması (Novu) dersi |
| DS-2 | `delivery_events` append-only hakikat kaynağı; projeksiyon defterden yeniden kurulur; haftalık yeniden kurma testi; geç olay yazılır, durumu geri almaz (§14.1.2) | KANONİK DEĞİŞMEZ | Event log + türetilmiş görünüm; tam event sourcing gerekmez; Access OP-73; MD-15 |
| DS-3 | İç model dört eksen: deneme, teslim (monoton), hata türü, etkileşim (§14.1.3) | FROZEN (teknik) | Tek eksenli durum kafesi "okundu→hata", "teslim→süre aşımı", "hata→teslim" geçişlerinde yanlış sonuç verir; Knock iki eksen modeli |
| DS-4 | Monotonluk koşullu güncellemeyle; olay indirgeme sırası (deneme no → sağlayıcı sırası → `occurred_at`/`received_at` → kaynak önceliği yalnız aynı deneme ve tür için); gelecek zaman damgası yok (§14.1.4) | FROZEN (teknik) | Sırasız sağlayıcı olayları (WhatsApp `read` önce, SendGrid `delivered` önce); `received_at` gerçekleşme sırası değildir |
| DS-5 | Sonuç tüm denemelerden; `delivered` yalnız aynı denemenin hatasını geçersiz kılar; `duplicate_delivered` ve çakışma görünür (§14.1.5) | FROZEN (teknik) | Kayıp yanıtlı deneme + geç DLR senaryosu; mükerrer teslim gizlenmez |
| DS-6 | Teslimden sonra hata kanal başına tablo: `valid` / `stale` / `conflict` (§14.1.6) | FROZEN (teknik) | E-posta asenkron bounce ve WhatsApp numara geçersizleşmesi meşru; okunmuş mesaj başarısız sayılamaz |
| DS-7 | Okuma kaynağını taşır; bir kanalın okuması başka kanalın teslimini kanıtlamaz (§14.1.7) | FROZEN (teknik) | Inbox eylemi SMS/push teslimini kanıtlamaz |
| DS-8 | Olay kaynağı sözlüğü; `client_sdk` ≠ `user` (§14.1.8) | FROZEN (teknik) | Cihaz makbuzu ile insan eylemi farklı eksenlere yazar |
| DS-9 | Bildirim düzeyinde ayrı teslim durumu uydurulmaz; teslim listesi + sayım (§14.1.9) | FROZEN (teknik) | `partially_delivered` gibi türetilmiş tek durum bilgi kaybettirir |
| DS-10 | `channel_event_evidence` kanıt tablosu (etki, eksen etkileri, `after_delivered`, yan etki, kapsam, `decision_grade`); tanımsız olay red; bilinmeyen sağlayıcı kodu olay + alarm (§14.2.1) | KANONİK DEĞİŞMEZ | Sağlayıcılar sık yeni kod üretir; eşleme dağıtımsız güncellenmeli; sessiz düşürme yok |
| DS-11 | Kanıt satırı + test vektörü + sağlayıcı idempotency politikası beyanı olmadan adaptör devreye alınmaz (§14.2.2) | FROZEN (teknik) | Adaptör sözleşmesinin denetlenebilirliği |
| DS-12 | Kanal teslim semantiği tablosu normatif; müşteri dokümantasyonu bundan üretilir; tablosuz kanal yok (§14.2.3) | FROZEN (ürün) | Kanallar farklı kanıt düzeyi verir (APNs/FCM tekil teslim onayı vermez; SMS DLR gecikir) |
| DS-13 | Push'ta sağlayıcı kabulüyle `delivered` iddia edilmez; yalnız SDK makbuzu; push `unknown`'a düşmez (§14.2.4) | KANONİK DEĞİŞMEZ | APNs/FCM yalnız kabul bildirir; "teslim = %100 − hata" yaklaşımı (Courier) yanıltıcıdır |
| DS-14 | Dış projeksiyon: `status` dokuz değer, `engagement`, `reason` + `rule_id`, `failure` (§14.3.1) | FROZEN (ürün) | İçeride eksenler, dışarıda sade sözleşme; AWS End User Messaging `UNKNOWN`, Telnyx `delivery_unconfirmed` emsalleri |
| DS-15 | Dış projeksiyon iç model değişse de sabit; değişiklik API sürümlemesiyle (§14.3.3) | KANONİK DEĞİŞMEZ | Müşteri entegrasyonlarının kararlılığı; MD-13 |
| DS-16 | Deneme geçmişi ve defter panelde ve ayrı API ucunda; ham sağlayıcı kodu dahil, kişisel veri maskeli (§14.3.4) | FROZEN (ürün) | Destek ve hata ayıklama; Courier Logs |
| DS-17 | Projeksiyon türetme kuralı; geç kesin olay `unknown`'ı her zaman yükseltir (§14.3.2) | FROZEN (teknik) | Monoton `unknown < delivered` |
| DS-18 | İki aşamalı pencere: kısa → `unknown_pending`, uzun → `unknown`; kanal başına veri; Relay kesin olay uydurmaz (§14.4.1) | FROZEN (teknik) | AWS End User Messaging: DLR operatörden 72 saate kadar gelebilir; "sent'te sonsuza kadar kalma" sorunu |
| DS-19 | Varsayılan pencereler: SMS 6 sa / 72 sa; e-posta 24 sa / 72 sa; WhatsApp 36 sa / 7 gün; sesli arama 1 sa / 24 sa (§14.4.2) | POLICY DEFAULT | SMS 72 sa (AWS); WhatsApp webhook yeniden deneme süresi ⚠️ (7 gün, doğrulanmadı); sesli arama değerleri ⚠️ ölçülmedi |
| DS-20 | Geç kesin olay her zaman kabul edilir ve yükseltir (§14.4.3) | KANONİK DEĞİŞMEZ | DLR gecikmesi; mutabakatla gelen kesin sonuç |
| DS-21 | `unknown` ve "teslim edilmedi" için otomatik yeniden gönderim yok; `unknown` fallback tetiklemez; zaman tabanlı yükseltme bağımsız (§14.4.4) | FROZEN (ürün) | Belirsiz sonuçta kör yeniden gönderim mükerrer ve maliyet üretir; sınıfa göre insan kararı |
| DS-22 | Sağlayıcı olay kimliğiyle kalıcı tekilleştirme; kanal başına periyodik mutabakat; sıklık ölçümle (§14.4.5) | ENGINEERING ASSUMPTION | "Webhook dayanıklı log değildir, reconcile et" ilkesi; Infobip pencere dolunca olay kaybı; sıklık ölçülmedi |
| DS-23 | Test düzleminde sahte sağlayıcıyla teslim senaryoları ve sanal saat (§14.4.6) | FROZEN (teknik) | Pencere ve geç olay davranışı test edilebilir olmalı |
| DS-24 | Sessiz kayıp yok: her atlama neden koduyla panel + `notification.suppressed` + metrik; karar ≠ hata (§14.5.1) | KANONİK DEĞİŞMEZ | Iterable Send Skip olayları; denetim ve destek için en değerli kayıt; MD-12 |
| DS-25 | Tek `rule_id` sözlüğü, sürümlü veri; neden aileleri; tercihte kapatan seviye; render hatası ayrı olay (§14.5.2) | FROZEN (teknik) | Tek "suppressed" değeri İYS/KVKK denetiminde kanıt taşımaz; Courier `reason`, Novu `STEP_FILTERED_BY_*`; MD-12 |
| DS-26 | Karar ≠ hata: politika sonucu kabulden sonra `skipped` + `rule_id`; senkron sonuç yalnız önizleme/test/dry-run (§14.5.1a) | FROZEN (teknik) | Kabul ile politika kararının ayrılması; OneSignal "hata durumunda 200" anti-deseninden kaçınma; MD-12 |
| DS-27 | Erteleme atlama değildir; defterde `deferred` olayı, projeksiyonda `queued` + `deferred_until` (§14.5.3) | FROZEN (teknik) | Erteleme ile düşürmenin ayrılması (sessiz saat politikaları) |
| DS-28 | "Neden almadım" karar zinciri sorgusu panel ve API'de (§14.5.4) | FROZEN (ürün) | Destek yükü; karar kayıtlarının tüketim yüzeyi |
| DS-29 | Açılma pikseli ve link sarmalama varsayılan kapalı; `security` ve OTP/doğrulama e-postalarında açılamaz (§14.6.1) | FROZEN (ürün) | Gizlilik; güvenlik e-postalarında link izleme saldırı yüzeyi |
| DS-30 | Tıklamalar `human` / `likely_bot`; sinyal listesi veri; raporlarda ayrı (§14.6.2) | FROZEN (teknik) | Kurumsal güvenlik tarayıcıları linkleri teslimden saniyeler sonra açar |
| DS-31 | Etkileşim tabanlı kararları e-postada yalnız insan tıklaması tetikler (§14.6.3) | KANONİK DEĞİŞMEZ | Bot tıklaması yanlış "görüldü" sinyali üretir |
| DS-32 | Açılma verisi hiçbir kararda ve teslim kanıtında kullanılmaz; `machine_open` bayrağı; panel uyarısı (§14.6.4) | KANONİK DEĞİŞMEZ | Apple Mail Privacy Protection açılmaları önceden yükler |
| DS-33 | Etkileşim ekseni teslim sonucundan bağımsız ilerler (§14.6.5) | FROZEN (teknik) | Courier: açılma `UNDELIVERABLE`'dan sonra gelebilir |
| DS-34 | İnsan tıklaması e-posta teslim kanıtıdır; bot tıklaması ve açılma değildir (§14.6.3a) | FROZEN (teknik) | Teslim olayı gelmeyen e-postalarda teslim oranının sistematik düşük ölçülmesi; Courier |
| DS-35 | Hazır raporlar Postgres rollup'larından; Relay içinde OLAP yok; rapor seti; test gönderimleri ayrı (§14.7.1) | FROZEN (ürün) | Tek zorunlu veri deposu Postgres; analitik hedefe akıtılır |
| DS-36 | Teslim hunisi; birincil sağlık metriği huni tamlığı; "kabul edildi ama kuyruğa girmedi" en ağır alarm (§14.7.2) | FROZEN (teknik) | Hata oranı sessiz kaybı göstermez; huni gösterir |
| DS-37 | Anlamsal olay akışı kiracı hedefine sürekli; CSV/Parquet dışa aktarım; analitik DB yalnız hedef (§14.7.3) | FROZEN (ürün) | Customer.io ve Braze Currents anlamsal olay akışı emsali |
| DS-38 | Faturalama değişmez `usage_records`'tan, metrikten değil (§14.7.4) | FROZEN (teknik) | Metrik kaybı fatura hatasına dönüşmemeli |
| DS-39 | Teslim sayaçları Postgres'te kesin; teslim yolunda Bloom/HLL yok (§14.7.5) | FROZEN (teknik) | Olasılıksal yapının yanlış pozitifi kayıp bildirimdir; Pub/Sub DLT sayacı yaklaşık |
| DS-40 | Tek iz: `traceparent` deftere ve iş meta verisine; geç webhook span link; bağlamsız süreç başlatma CI ile yasak; span'de kişisel veri yok (§14.8.1) | FROZEN (teknik) | OpenTelemetry; uçtan uca teslim izi |
| DS-41 | `duplicate_delivered`, çakışma, geç olay, `unknown` oranı, bilinmeyen kod, huni boşluğu, mutabakat ve DLR gecikmesi, bot oranı metrikleri gizlenmez (§14.8.2) | FROZEN (teknik) | Dürüst garanti dili |
| DS-42 | Mesaj sınıfı başına tek SLO tablosu; değerler ölçülene kadar yazılmaz (§14.8.3) | ENGINEERING ASSUMPTION | Ölçülmemiş gecikme hedefi sözleşmeye girmez |
| DS-43 | Teslim durumu Access'e yalnız bilgi; Access state'ini değiştiren çağrı yok; teslim/ack yetki değildir (§14.8.4) | KANONİK DEĞİŞMEZ | Access E30, Access E40, Access EI-18; MD-2 |
| DS-44 | Teslim verisi Access OP-73/Access OP-74 ve Access Ek C'ye tabi; sınıflar: teslim kayıtları, `message_log` (TR 10 yıl); kademeli defter saklama; uyum kanıtı ayrı arşivde (§14.9.1) | FROZEN (teknik) | 6563 m.11/3; Access OP-73, Access OP-74, Access Ek C; MD-9 |
| DS-45 | Teslim kaydı render içerik saklamaz (özet + sürümler); kiracı açabilir; OTP/doğrulamada hiçbir koşulda; `retention: none` bayrağı, in-app ile birleşimi reddedilir (§14.9.2) | FROZEN (teknik) | KVKK veri minimizasyonu; OTP içeriği tekrar kullanılabilir sır niteliğinde |
| DS-46 | Bu bölümün tabloları (kanıt, pencere, neden sözlüğü, bot sinyalleri) sürümlü veridir; değişiklik denetim kaydına girer (§14 kuralları) | FROZEN (teknik) | Mevzuat ve sağlayıcı değişikliği kod dağıtımı beklememeli |
