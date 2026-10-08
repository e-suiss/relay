## 13. Tercihler ve Uyum

**Bu bölümün kuralları.**
- Bu bölüm bir teslimin **gönderilip gönderilmeyeceğine ve ne zaman gönderileceğine** dair politika katmanını tanımlar: yedi mesaj sınıfı, kategori, kilitli kategori, karar kafesi (kapı → filtre → zamanlayıcı), dört seviyeli tercih, izin ile tercih ayrımı ve Access ile iş bölümü, İYS, tek tık çıkış, ülke × kanal × sınıf uyum tablosu, sessiz saat, yasal pencereler, frekans tavanı, OTP alt türleri.
- Kanal ve sağlayıcı kuralları §12'de; rota, fallback, digest, throttle, içerik tekilleştirme ve saat dilimi çözümü §10'da; şablon linter'ları (yasal altbilgi, sızma yasağı) §11'de; atlama kayıtlarının dış projeksiyonu §14'te; tercih merkezi ekranının ürün deneyimi §8'dedir.
- **Uyum kuralları gevşetilemez.** Kiracı uyum kurallarını yalnız sıkılaştırabilir; hiçbir istek alanı, workflow ayarı ya da kiracı bayrağı bir kapıyı atlatamaz (PC-9, PC-37).
- **Karar ≠ hata.** Politika sonucu bir hata değildir: istek `202` ile kabul edilir, politika kararı teslim kaydında `decision` + `rule_id` + `detail` olarak yazılır ve `notification.suppressed` olayıyla görünür (§14). Senkron politika hatası yalnız önizleme, test ve dry-run uçlarında döner.
- **Sessiz kayıp yoktur.** Gönderilmeyen her teslim, kararı veren seviye ve kural kimliğiyle kaydedilir; panelde, webhook olayında ve metrikte görünür.

---

### 13.1 Mesaj sınıfları

#### 13.1.1 Yedi sabit üst sınıf

Relay'de yedi sabit üst sınıf vardır. Sınıf kabul anında atanır ve teslimin ömrü boyunca değişmez (PC-1).

| Sınıf | Ne | Tercihle kapatılabilir mi | Sessiz saat | Digest | Öncelik tavanı (§12.4) | İYS kapsamı |
|---|---|---|---|---|---|---|
| `security` | OTP ve doğrulama kodları (§13.10), güvenlik uyarıları, Access semantik olayları | Hayır (her zaman kilitli) | Deler | Hayır | high | Hayır |
| `action_required` | İnsandan yanıt bekleyen istekler: ajan soruları, iş akışı onayları, CIBA daveti. Süresi dolar, bekleme noktasına bağlanır (§17) | Kategori kilitli değilse evet | Ertelenmez (deler) | Hayır | high | Hayır |
| `transactional` | Kullanıcının başlattığı işlemin sonucu: sipariş, ödeme, teslimat, hesap değişikliği | Kategori kilitli değilse evet | Ertelenir; `expires_at` geçerse düşer | Hayır | high | Hayır (bilgilendirme iletisi) |
| `operational` | Sistem inisiyatifli bilgilendirme: hatırlatma, durum değişikliği, bakım duyurusu | Kategori kilitli değilse evet | Ertelenir | Kiracı seçer | normal | Hayır (bilgilendirme iletisi) |
| `social` | Diğer kişilerin etkinliği: yorum, bahsetme, takip | Evet | Digest'e alınır | Evet | normal | Hayır |
| `marketing` | Ticari elektronik ileti (tanıtım, kampanya) | Evet; varsayılan ülke ve platform satırından (§13.4.2) | Ertelenir + yasal pencere + frekans tavanı | Hayır | normal | Evet (§13.6) |
| `system` | Kullanıcıya görünmeyen teknik iletiler: sessiz push, rozet senkronu, diğer cihazdan kaldırma | Tercih yüzeyinde yer almaz | Uygulanmaz | Hayır | low | Hayır |

- Gönderen türü (`human | system | agent`) sınıftan ayrı bir alandır; ajan kaynaklı tavan ve davranış §17'dedir (PC-2).
- Access semantik olayları `security` sınıfındadır: digest, frekans tavanı ve içerik tekilleştirmesi uygulanmaz; idempotency uygulanır. Süresi geçmiş güvenlik bildiriminin davranışını gönderen belirler (`on_expire: drop | inbox_only`); varsayılan `drop`.

#### 13.1.2 Tip ayrımı

- İşlemsel/bilgilendirme şablonları (`security`, `action_required`, `transactional`, `operational`, `social`) ile pazarlama şablonları (`marketing`) birbirine dönüştürülemeyen ayrı tiplerdir; bir şablonun sınıfı yayından sonra değiştirilemez, yeni şablon gerekir (PC-3).
- **Sızma yasağı:** işlemsel/bilgilendirme şablonuna promosyon bloğu, indirim kodu ya da kampanya çağrısı eklenmesi yayın kapısında reddedilir (§11). Bilgilendirme iletisi mal/hizmet tanıtımı içerirse ticari ileti sayılır; bu ayrım tercih merkezinden daha önemli kontroldür (PC-3).
- Sağlayıcıya iletilen ticari ileti/muafiyet bayrağı (ör. SMS sağlayıcısının İYS filtresi) mesaj sınıfından türetilir, hiçbir zaman sağlayıcı varsayılanına bırakılmaz ve denetim kaydına girer; bu bayrak hizmet sağlayıcının beyanıdır (PC-4).

---

### 13.2 Kategori

- Kiracı kendi kategorilerini tanımlar; her kategori yedi sınıftan tam birine bağlanır. Kategori kanaldan bağımsız birinci sınıf kavramdır ve tercih yüzeyinin satırıdır (PC-5).
- Her kategori varsayılan bir rotaya bağlanır (§10), kanal başına gönderen kimliği taşıyabilir (§12.6.2), bir varsayılan `expires_at` süresi ve frekans tavanı politikası taşır (§13.9).
- Bildirim kaydında kategori "ne" sorusunu, ayrı `reason` alanı "neden sana" sorusunu cevaplar (ör. `mentioned`, `assigned`, `subscribed`).
- Alt kiracı kategori varsayılanlarını miras alır; tanımladığı ayar kiracınınkini ezer (§18) (PC-7).

#### 13.2.1 Kilitli kategori

- `security` sınıfındaki her kategori kilitlidir (PC-6).
- Kiracı `transactional`, `operational` ve `action_required` sınıflarındaki bir kategoriyi kilitli ilan edebilir. `marketing` ve `social` kategorileri kilitlenemez (PC-6).
- Kilitli kategoride kanal değil kategori kilitlenir: kullanıcı kanal seçebilir ama en az bir kanal açık kalır; son kanalı kapatma engellenir ve nedeni gösterilir. Tercih ekranında kilitli hücre anahtar değil "Açık (kilitli)" etiketi olarak görünür ve kilidin kimin yararına olduğu yazılır (PC-6).
- Kilit yalnız filtreleri (§13.3, seviye 3) atlar; kapıları asla atlamaz (PC-8).

---

### 13.3 Karar kafesi: kapı → filtre → zamanlayıcı

#### 13.3.1 Üç kural türü

| Tür | Sonuç | Ne ezebilir |
|---|---|---|
| **Kapı** (gate) | `suppressed` (terminal) | Hiçbir şey |
| **Filtre** (filter) | `filtered` (terminal) | Yalnız kilitli kategori |
| **Zamanlayıcı** (shaper) | `deferred` / `batched` / `dropped` (kategori politikası) | Sınıf kuralları (`security` ve `action_required` sessiz saati deler) |

#### 13.3.2 Değerlendirme sırası

Sıra kesindir (PC-8):

```text
1  KAPILAR (hiçbir bayrak, kategori ya da kilit atlatamaz)
   1a  kill switch (§18)
   1b  bastırma listesi (hard bounce, şikâyet, kiracı kara listesi) (§12.6.6)
   1c  ret bildirimi: SMS RET/STOP, tek tık "markadan hiç", İYS RET, ARF şikâyeti (§13.7)
   1d  uyum tablosu: sınıf × ülke × kanal × rıza türü × alıcı türü (§13.8); TR ticari iletide İYS (§13.6)
   1e  kanal teknik durumu: adres/token devre dışı, OS izni yok, OTP alt türü–kanal kuralı (§13.10)
   1f  kapsam: eşleşmeyen alt kiracı (`skip: scope_mismatch`)
2  ZORUNLULUK MUAFİYETİ: kategori kilitliyse 3 atlanır (1 asla)
3  FİLTRELER (VE mantığı; herhangi biri "kapalı" ise gönderilmez)
   3a  kiracı kategoriyi kapatmış
   3b  kullanıcı kategori × kanal tercihi
   3c  kullanıcı bildirim türü (workflow) tercihi
   3d  kullanıcı nesne sessize alma (`scope_key`)
   3e  kullanıcı haftalık uygunluk programı
4  ZAMANLAYICILAR
   4a  yasal pencere (§13.9.2)
   4b  kullanıcı sessiz saati (§13.9.1)
   4c  frekans tavanı (§13.9.4)
   4d  digest penceresi, throttle, içerik tekilleştirme (§10)
→  GÖNDER
```

- Kafes her teslim denemesinde yeniden değerlendirilir; ertelenmiş ya da `PAUSED` iş çalışma anında kafesten yeniden geçer (planlama anındaki sonuç kullanılmaz) (PC-8).
- Zamanlayıcıların ayrıntılı sırası (sınıf geçişi → açık zamanlama → yerel saat → sessiz saat → uygunluk → frekans → jitter → hız limiti) §10'dadır.

#### 13.3.3 Kayıt

Her karar `decision` + `rule_id` + `detail` üçlüsüyle kaydedilir. `rule_id` tek, sabit ve belgelenmiş bir sözlükten gelir (kill switch, kapsam uyuşmazlığı, İYS reddi, sessiz saat dahil); serbest metin kullanılmaz. Filtre kararında kapatan seviye (`category_channel`, `workflow`, `scope_key`, `schedule`, `tenant`) `detail`'da yazılır; "neden almadım" sorusu bu kayıtla cevaplanır (PC-9).

#### 13.3.4 Kilitli kategoride kapı

Kilitli kategoride bir kanal kapıdan geçemezse (ör. token devre dışı, OS izni yok) teslim sessizce bırakılmaz; rota politikasındaki sıradaki kanala geçilir (§10). OTP alt türlerinin kanal kuralları (§13.10) bu geçişte de geçerlidir (PC-10).

#### 13.3.5 Tercih delme bayrağı yoktur

Tercihleri aşmanın tek yolu kategorinin kilitli ilan edilmesidir; kilit kategori tanımında beyan edilir ve denetim kaydına girer. Mesaj başına, workflow başına ya da istek alanıyla tercih delme bayrağı (`send_to_unsubscribed`, "override preferences" benzeri) yoktur (PC-11).

---

### 13.4 Tercihler

#### 13.4.1 Dört seviye

Tercih dört seviyelidir ve çakışmada VE mantığı uygulanır: herhangi bir seviyede "kapalı" ise gönderilmez (PC-12).

| Seviye | Anahtar | Örnek |
|---|---|---|
| Kategori × kanal | `(category, channel)` | "Sipariş bildirimleri: SMS kapalı" |
| Bildirim türü | `workflow` | "Haftalık özet e-postasını alma" |
| Tek nesne sessize alma | `scope_key` (opak dize) | "Bu konuşmayı sessize al"; `scope_key` dolu kayıt, aynı kategorinin genel kaydını ezer (en spesifik sessize alma kazanır) |
| Haftalık uygunluk programı | Gün × saat aralığı, alıcı saat diliminde | "Hafta içi 09:00–18:00"; teslim anında değerlendirilir |

- Kanal sütunu genel kanal anahtarıdır (ör. "bütün SMS'ler kapalı"); bu bir tercihtir, ret bildirimi değildir (§13.7.4).
- Koşullu tercih yoktur ("bakiye 5'in altındaysa bildir" gibi koşul kiracının iş kuralıdır; kiracı sistemi koşulu değerlendirip olayı gönderir) (PC-12).
- `security` sınıfı ve kilitli kategoriler hiçbir seviyeden kapatılamaz.
- Digest seçimi (anında / günde bir özet) `social` ve kiracının izin verdiği `operational` kategorilerinde tercih değeridir (§10). Kapatma eyleminde üç seçenekli ara adım (Anında al / Özet al / Hiç alma) gösterilir; hiçbir seçenek önceden işaretli gelmez (PC-17).

#### 13.4.2 Değer ve varsayılan

- Tercih değeri üç durumludur: `opt_in | opt_out | unset`. `unset` kategori varsayılanına düşer (PC-13).
- Kategori varsayılanı kiracı tarafından kategori × kanal matrisiyle verilir; kiracı vermezse sınıf varsayılanı uygulanır (PC-14):

| Sınıf | Push | E-posta | SMS | WhatsApp | In-app |
|---|---|---|---|---|---|
| `security` | açık (kilitli) | açık (kilitli) | açık (kilitli) | kapalı | açık (kilitli) |
| `action_required` | açık | açık | kapalı | kapalı | açık |
| `transactional` | açık | açık | açık | kapalı | açık |
| `operational` | açık | açık | kapalı | kapalı | açık |
| `social` | açık | kapalı | kapalı | kapalı | açık |
| `marketing` | kapalı ¹ | kapalı ² | kapalı ² | kapalı ¹ | açık ¹ |

- `marketing` varsayılanı kanal başına uyum tablosunun ülke ve platform satırlarından türer (PC-14, PC-54):
  - ¹ iOS push (APNs) ve WhatsApp'ta varsayılan kapalıdır ve kiracı açık yapamaz; kullanıcı açıkça açarsa gönderilir (platform satırı, §13.8.3). Android push ve in-app inbox'ta varsayılanı kiracı kategori × kanal matrisiyle seçer; Relay ek şart koymaz. Tablodaki değer kiracı seçim yapmadığında uygulanır.
  - ² E-posta, SMS ve ses için ülke satırı belirleyicidir: ülke satırı önceden onay istiyorsa (TR İYS kapsamı, AB e-posta ve SMS, özel satırı olmayan ülkeler) varsayılan her zaman kapalıdır ve kiracı açık yapamaz.
  - Relay mevzuatın ya da platform kuralının istemediği izin şartı koymaz (PC-43); ülke ya da platform satırı onay istemiyorsa varsayılanı kiracı seçer.
- Kiracı kullanıcı adına tercih yazabilir ama yalnız kapatma yönünde; `marketing` için kullanıcı adına "açık" yazılamaz. Kiracının kategori × kanal matrisinde seçtiği varsayılan kullanıcı adına yazılmış tercih değildir; kullanıcının `unset` değeri bu varsayılana düşer. Kullanıcı arayüzünde "yöneticiniz bu bildirimi kapattı" gösterilir (PC-15).
- Kullanıcı tercihi kiracı politikasını yalnız kısıtlar, genişletmez; kiracının kapattığı kategoriyi kullanıcı açamaz (PC-15).

#### 13.4.3 Bağlam

- Tercih alıcının hesabına bağlıdır; cihaza ya da çereze bağlı değildir. Tek kanonik kayıt vardır (PC-16).
- OS bildirim izni Relay tercihinin üstündedir ama tercihi silmez: OS'ta push kapalıyken gönderilmez (§12.5.5), tercih merkezinde "cihaz ayarlarından kapalı" gösterilir; izin geri açılınca eski tercih aynen geçerlidir. Token silinmesi de tercihi silmez (PC-16).

#### 13.4.4 Tercih merkezi yüzeyleri

- Tek motor, üç yüzey: uygulama içi tam ekran (gömülebilir bileşen, §8), e-posta altbilgisi bağlantısıyla açılan girişsiz sayfa (imzalı, süreli, tek amaçlı belirteç) ve bildirimin içinden (iOS `providesAppNotificationSettings`) (PC-18).
- Barındırılan sayfa sunucu tarafında JavaScript'siz çalışır; gömülebilir bileşen aynı API'yi kullanır.
- Birincil görünüm kategori (satır) × kanal (sütun) matrisidir; kullanılamayan hücre `—`, kilitli hücre etiket, kanal başlığı genel kanal anahtarıdır; `marketing` satırında izin yoksa anahtar değil "İzin bekleniyor · İzin ver" gösterilir (§13.5).
- **Kabul testleri:** tık simetrisi (izin N tıksa geri alma ≤ N tık), kabul ve ret seçeneklerinin görsel eşdeğerliği, EDPB aldatıcı tasarım kalıplarının yokluğu, WCAG 2.2 AA. Bunlar otomatik testtir (PC-18).
- KVKK kaynaklı üç yasak: izin ekranı her zaman atlanabilir; kiracı izni özellik erişimine bağlayamaz; aydınlatma ve açık rıza ayrı işaretlenir. `transactional` ve `operational` için rıza sorulmaz (gereksiz rıza da ihlaldir) (PC-19).
- Access bağlıyken kullanıcı tek "Tercihlerim" ekranı görür: izinler (Access) + bildirim tercihleri (Relay) (§13.5).

---

### 13.5 İzin ve tercih; Access ile iş bölümü

#### 13.5.1 Ayrım

İzin (consent) ve tercih (preference) ayrı kayıtlardır (PC-20):

| | İzin | Tercih |
|---|---|---|
| Ne | Hukuki onay/ret (ticari ileti onayı, soft opt-in dayanağı) | Kullanıcının bildirim arzusu |
| Kanıt | Zorunlu: kaynak, zaman, kanal, onay metni sürümü, IP/cihaz, İYS işlem kimliği | Yok |
| Yokluğunda | Gönderme (rıza gereken satırda) | Kategori varsayılanı |
| Saklama | Ticari ileti onay ve gönderim kayıtları saklama sınıfı (PC-25) | Tercih saklama sınıfı |
| Kapı/filtre | Kapı (1c, 1d) | Filtre (3b–3e) |

- Kanıtsız onay yazılamaz. Onay metni değişmez ve sürümlüdür; kayıt metin sürümünün özetini taşır (PC-20).
- İzin durumu `NONE ≠ REVOKED`: hiç onay alınmamış adres ile reddetmiş adres tek bir `false`'a indirgenmez. İzin durumları: `NONE`, `PENDING`, `ACTIVE`, `REVOKED`, `EXPIRED` (PC-21).
- Kaynaklar birleşirken herhangi bir kaynakta RET varsa sonuç RET'tir; TR ticari iletide ONAY yalnız İYS'de ONAY varsa geçerlidir (PC-21).
- İYS'de RET varken uygulamada anahtarı açmak yeni onay sayılmaz; ayrı ve kanıtlı onay akışı gerekir.

#### 13.5.2 Access ile iş bölümü

| | Access bağlı | Access yok |
|---|---|---|
| Hukuki izin (pazarlama onayı/ret, kanıt, geçmiş) | Access'te (Access IDP-37). Access her değişiklikte İYS alanlarını eksiksiz taşıyan izin olayı yayınlar | Relay'in kendi izin kaydı |
| Bildirim tercihleri (kategori × kanal, bildirim türü, sessiz saat, digest, uygunluk programı) | Relay'de | Relay'de |
| Gönderimde izin okuma | Relay'in Access olaylarından tuttuğu kopya; gönderimde Access'e sorulmaz | Relay'in kendi kaydı |
| İYS'ye yazma | Relay (§13.6) | Relay (İYS bağlıysa) |
| Kullanıcı ekranı | Tek "Tercihlerim" (Access izinleri + Relay tercihleri) | Relay tercih merkezi (izin bölümü dahil) |

(PC-22)

- Kopya bayatlığı: Access izin olayları Relay'e at-least-once ve olay sırası numarasıyla gelir; Relay eski sıra numaralı olayı uygulamaz. Kopya bir uyum kapısı girdisidir; TR ticari iletide ayrıca İYS önbelleği kontrol edilir (§13.6).
- İzin ve tercih yetki değildir; hiçbir karar kafesi sonucu yetki durumu üretmez (Access IDP-37).

#### 13.5.3 Rıza türü ve alıcı türü

- Rıza türü alanı: `explicit_opt_in | soft_opt_in | legitimate_interest | none`. Hangi türün yeterli olduğunu uyum tablosu söyler (§13.8) (PC-23).
- Alıcı türü alanı: `individual | merchant` (bireysel / tacir-esnaf). Tacir veya esnaf alıcıya ticari iletide önceden onay gerekmez; ret İYS'ye kaydedilir ve uyulur (PC-24).
- Rıza kaynağı İYS `source` kümesine eşlenebilir (Relay tercih merkezi → `HS_WEB`/`HS_MOBIL`, SMS ile alınan → `HS_MESAJ` vb.).

#### 13.5.4 Saklama

Ticari ileti onay ve gönderim kayıtları ayrı saklama sınıfıdır; Türkiye'de 10 yıl saklanır. Saklama ve silme Access OP-74 ve Access Ek C bölge × sektör tablosuna tabidir; özne silmesinde (crypto-shredding) yasal saklama gereken kanıt ayrı ve en az veriyle tutulur (PC-25).

#### 13.5.5 Çift onay (Access'siz kullanım)

Relay izin kaydını kendisi tutarken e-posta pazarlama onayı için çift onay (double opt-in) kiracı seçeneğidir ve varsayılan açıktır; onay bekleyen adres `PENDING` durumundadır ve 1d kapısından geçmez. Access bağlıyken onay toplama akışı Access'indir (PC-26).

---

### 13.6 İYS

#### 13.6.1 Kapsam

- İYS kontrolü yalnız `marketing` sınıfında ve yalnız İYS'nin tanıdığı kanallarda yapılır: `ARAMA` (ses), `MESAJ` (SMS), `EPOSTA` (e-posta) (PC-27).
- Kapsam: kiracının bölgesi Türkiye ise ya da kiracı İYS bilgilerini girmişse. Kapsam dışında İYS işlemi yapılmaz (PC-27).
- Kapsam içinde kiracının İYS bilgisi yoksa bu kanallardan pazarlama iletisi gönderilmez (fail-closed, `rule_id: iys_not_configured`) (PC-27).
- Push, in-app ve WhatsApp İYS kontrolüne girmez; Relay bu kanallarda mevzuatın ya da platform kuralının öngörmediği ek izin şartı koymaz (§13.8, §13.8.3) (PC-27).
- Bilgilendirme iletileri (`transactional`, `operational`; Yönetmelik m.6/2 kapsamı) için İYS sorgusu sıcak yolda yapılmaz (m.6/5) (PC-27).

#### 13.6.2 Tek yazıcı

Bir marka için İYS'ye tek yazıcı Relay'dir: onay/ret yazma, değişiklik çekme, tek tık çıkıştan, SMS RET'ten ve spam şikâyetinden doğan ret, kota ve token yönetimi tek yerdedir. Access İYS'ye hiçbir koşulda doğrudan yazmaz; Relay yoksa kiracı Access izin olayını kendi İYS entegratörüne iletir (PC-28).

#### 13.6.3 Bağlanma modları

| Mod | Ne zaman |
|---|---|
| Kiracının kendi İYS API erişimi | Kiracı doğrudan erişim hakkına sahipse |
| Kiracının yetkili entegratörü üzerinden | 250 bin adresin altındaki markalar (doğrudan API erişimi yok) ve entegratör tercih eden kiracılar |

Kiracı modeli `(hizmet sağlayıcı iysCode) → (brandCode, kanal) → izin`dir. Bir kiracı birden çok marka taşıyabilir; marka alt kiracıya ya da kategori gönderen kimliğine bağlanır ve SMS başlığıyla eşleşir (§12.7.3). Entegratör üzerinden kanal bazlı yetkiler (`MESAJ`/`ARAMA`/`EPOSTA` okuma/yazma) entegratörün yetki listesinden düzenli yenilenir; varsayılmaz (PC-29).

#### 13.6.4 Yazma yolu

```text
izin olayı (Access ya da Relay tercih merkezi)
 → yerel izin kaydı PENDING_IYS (kaynak, TR saatiyle onay tarihi, alıcı türü, marka, kanal)
 → İYS yükleme işi (outbox; alıcı × marka × kanal başına serileştirilmiş; İYS v2 idempotent uç)
 → başarı: ACTIVE (+ İYS işlem kimliği, oluşturma zamanı)
 → kalıcı hata: operatör kuyruğu + kiracı olayı (sessizce yutulmaz)
 → 3 iş günü içinde yüklenemezse: EXPIRED (geçersiz onay)
```

- İYS'ye kaydedilmeyen onay geçersizdir; 3 iş gününden eski onay kaydedilemez. Hedef yükleme gecikmesi dakikalardır; 3 iş günü üst sınırdır (PC-30).
- İş günü hesabı sürümlü iş günü/resmî tatil takvimi veri tablosuyla yapılır; naif 72 saat kullanılmaz (PC-31).
- İYS'nin `200` yanıtı ulusal sicilde işlendiğinin teyidi değildir; yükleme sonrası durum geri okunarak doğrulanır (PC-30).
- Ret yazımı da aynı yoldan ve öncelikli gider; Relay içinde ret yazmadan önce anında uygulanır (§13.7).

#### 13.6.5 Okuma yolu ve yerel önbellek

- İYS ret alımı push (İYS ret bildirimi ucu) ve pull (değişiklik sorgusu, cursor ile) birlikte çalışır. Pull mutabakatı en az saatliktir (varsayılan 15 dakika). Pull 7 günlük değişiklik penceresinden uzun durursa tam senkron yapılır (PC-32).
- İYS izin durumu yerel önbellekte tutulur; gönderim kapısı önbelleği okur. Canlı İYS sorgusu yalnız tekil doğrulama içindir (sorgu limitleri nedeniyle).
- Değişiklik sorgusunun son 1 saati kapsamaması bilinen kör noktadır; operatör ekranında gösterilir.
- **Bayatlık kapısı:** TR + `marketing` + bireysel alıcıda yerel önbellekte `ONAY` yoksa ya da son başarılı senkron bayatlık eşiğini aştıysa gönderilmez (fail-closed, `rule_id: iys_stale`). Başlangıç eşikleri: 6 saatte uyarı, 24 saatte operatör sayfalama ve gönderim durdurma; kesin değer ölçümle konur (PC-33).
- Tacir/esnaf alıcıda onay aranmaz; İYS RET kontrolü yapılır (PC-24).

#### 13.6.6 İşletim kuralları

- İYS erişim belirteci geçerlilik süresi boyunca önbelleklenir; belirteç uç noktasına erken tekrar istek atılmaz (PC-34).
- İYS hız limitleri ve trafik kalitesi kuralları (başarısız istek oranı yüksek IP'nin izin listesinden çıkarılması) adaptör limit verisidir; 4xx üreten istekler gönderilmeden önce yerel doğrulamadan geçer (E.164 telefon biçimi, tarih aralığı, alıcı sayısı).
- İzin kotası (`consentLimit` / `usedConsentLimit`) izlenir; dolmaya yaklaşınca kiracıya uyarı, dolduğunda onay yükleme reddi operatör kuyruğuna düşer (PC-34).
- İYS olayları (yükleme başarısız, EXPIRED, İYS RET alındı, bayatlık) kiracıya webhook olarak gider (§16).
- İYS istemcisi resmî OpenAPI belgesine karşı yazılır ve sandbox ortamına karşı sözleşme testinden geçer.

---

### 13.7 Çıkış

#### 13.7.1 Tek tık (RFC 8058)

- `List-Unsubscribe-Post` ile gelen tek tık POST ve altbilgi bağlantısı kullanıcıyı **o iletinin kategorisinden** çıkarır; tercih olarak kaydedilir, İYS'ye yazılmaz (PC-35).
- Uç nokta kuralları: POST ile çalışır (`List-Unsubscribe=One-Click`), GET durum değiştirmez; yönlendirme ve giriş istemez, onay ekranı göstermez, `200`/`204` döner; URI imzalı opak belirteç taşır `(tenant, alıcı, kategori, kanal)`; belirteç süresiz geçerli ama iptal edilebilirdir; işlem idempotenttir ve anında etkilidir; kanıt kaydı (zaman, IP, user-agent, kaynak `rfc8058`) yazılır. Başlıklar DKIM kapsamındadır (§12.6.4) (PC-35).
- Mailto çıkışları gelen posta ayrıştırmasıyla aynı sonucu üretir.

#### 13.7.2 Çıkış sayfası

Bağlantıyla açılan sayfa "çıkış yapıldı" der ve iki seçenek sunar: "tercihlerimi yönet" ve "bu markadan hiç ticari e-posta almak istemiyorum". İkincisi İYS'ye marka × `EPOSTA` RET yazar (§13.6) ve bütün `marketing` e-posta kategorilerinden çıkarır. Çıkış bir yönlendiricidir (geri dönme / kalanları yönetme), kill switch değildir; yalnız ticari ve toplu kategorilerde bulunur (PC-36).

#### 13.7.3 SMS anahtar kelimeleri ve şikâyet

- Gelen SMS anahtar kelime işleyicisi sağlayıcıdan bağımsız ve çok dillidir (PC-37):

| Küme | Anahtar kelimeler | Etki |
|---|---|---|
| TR ret | `RET`, `IPTAL`, `İPTAL`, `DUR`, `H` | Kanal düzeyinde ret: Relay'de anında bastırma + TR alıcıda İYS `MESAJ` RET |
| STOP ailesi | `STOP`, `QUIT`, `END`, `REVOKE`, `OPT OUT`, `CANCEL`, `UNSUBSCRIBE` | Kanal düzeyinde ret (TCPA kesin geri çekme) |
| Yardım | `HELP`, `YARDIM` | Bilgi yanıtı |
| Yeniden başlatma | `START`, `UNSTOP` | Yeniden abonelik (yeni kanıtlı onay olarak kaydedilir; İYS RET'i kaldırmaz) |

- Eşleştirme Türkçe harf katlamasıyla (`İ/i`, `I/ı`), büyük/küçük harf ve baş/son boşluk duyarsız yapılır.
- Ret sonrası tek, pazarlama içermeyen bir teyit mesajı gönderilir.
- Sağlayıcının kendi STOP işlemesiyle durum senkron tutulur (sağlayıcıdan gelen STOP kodu `policy` sınıfıdır, §12.2).
- ARF/FBL şikâyeti pazarlama kategorilerinden çıkış üretir, TR alıcıda İYS `EPOSTA` RET yazar ve `complained` olayı gönderir (PC-37).
- WhatsApp'tan gelen pazarlama çıkışı (`user_preferences`, hata `131050`) WhatsApp kanalında `marketing` kategorilerinden çıkış olarak kaydedilir.

#### 13.7.4 Tercih ≠ ret bildirimi

Tercih merkezinden bir kanalı kapatmak tercihtir ve İYS'ye yazılmaz. SMS'e RET yanıtı, tek tık "markadan hiç" seçeneği ve şikâyet ret bildirimidir: bastırmaya girer, İYS'ye yazılır ve kapı (1c) olarak çalışır. İkisi tek anahtara indirgenmez (PC-38).

#### 13.7.5 Kapsam ve süre

- Ret anında uygulanır. Yasal süreler (6563: 3 iş günü; TCPA: 10 iş günü; CAN-SPAM: 10 iş günü) hedef değil üst sınırdır (PC-39).
- Rıza geri çekmenin kapsamı veridir: `category | all_marketing | all_channel`. Varsayılanlar: tek tık → kategori; çıkış sayfası ikinci seçeneği → marka × e-posta bütün pazarlama; SMS ret anahtar kelimesi → kanal düzeyinde bütün pazarlama; ARF → bütün pazarlama kategorileri (PC-39).
- Çıkış bağlantıları en az 30 gün (pratikte süresiz) çalışır.

---

### 13.8 Ülke × kanal × sınıf uyum tablosu

#### 13.8.1 Model

Uyum kuralları bir veri tablosudur: **ülke × kanal × mesaj sınıfı × rıza türü × alıcı türü** → gönderim koşulu, ek yükümlülük (altbilgi, pencere, kayıt). Tablo her ülke için çalışır; yeni ülke yalnız satır eklenerek desteklenir (PC-40).

- Kiracı tabloyu yalnız sıkılaştırabilir (ör. bir ülkede soft opt-in'i kabul etmemek); gevşetme bayrağı yoktur (PC-40).
- Tabloda özel satırı olmayan ülkede `marketing` için güvenli varsayılan `explicit_opt_in`'dir (PC-41).
- Meşru istisnalar bayrakla değil veriyle karşılanır: alıcı türü tacir/esnaf, mevcut müşteri soft opt-in, B2B meşru menfaat (PC-42).
- Ülke, alıcının iletişim adresinden (telefon ülke kodu) ve profil ülkesinden belirlenir; çakışmada daha kısıtlayıcı satır uygulanır.
- Push, in-app ve WhatsApp `marketing` iletileri için Relay mevzuatın ya da platform kuralının öngörmediği ek izin şartı koymaz; kullanıcı tercihi (çıkış hakkı) geçerlidir. Platform kuralının istediği açık onay platform satırıyla uygulanır (§13.8.3) (PC-43).

#### 13.8.2 Hazır gelen satırlar

| Ülke / bölge | Kanal | Sınıf | Yeterli rıza | Alıcı türü | Ek koşul |
|---|---|---|---|---|---|
| TR | SMS, e-posta, ses | `marketing` | `explicit_opt_in` + İYS `ONAY` | bireysel | İYS kapısı fail-closed (§13.6); gönderen kimliği ve ret talimatı altbilgisi; SMS'te nitelik ibaresi mesaj başında (§11) |
| TR | SMS, e-posta, ses | `marketing` | `none` | tacir/esnaf | İYS RET kontrolü; altbilgi aynı |
| TR | push, in-app, WhatsApp | `marketing` | `none` | hepsi | Kullanıcı tercihi (çıkış hakkı); platform satırı ayrıca uygulanır (§13.8.3) |
| TR | hepsi | `transactional`, `operational` | `none` | hepsi | Bilgilendirme iletisi: tanıtım içeremez (sızma yasağı); İYS sorgusu yok |
| AB | e-posta, SMS | `marketing` | `explicit_opt_in` veya `soft_opt_in` | bireysel | Soft opt-in yalnız mevcut müşteri + kendi benzer ürünü + her iletide çıkış; gönderen kimliği gizlenemez |
| AB | e-posta, SMS | `marketing` | `legitimate_interest` | tüzel kişi | Ülke satırına bağlı |
| AB | push, in-app, WhatsApp | `marketing` | `none` | hepsi | Kullanıcı tercihi; platform satırı ayrıca uygulanır (§13.8.3) |
| ABD | e-posta | `marketing` | `none` (opt-out) | hepsi | Fiziksel posta adresi zorunlu altbilgi; çıkış ≥ 30 gün çalışır; reklam olduğu belirtilir (CAN-SPAM) |
| ABD | SMS, ses | `marketing` | `explicit_opt_in` (yazılı) | hepsi | 10DLC/TFV kayıtlı gönderici (§12.7.3); yasal pencere 08:00–21:00 alıcı yerel saati; STOP ailesi; ilk mesajda program adı, sıklık, HELP/STOP bilgisi |
| ABD | SMS | `transactional`, `security` | `explicit_opt_in` | hepsi | 10DLC kampanya kullanım durumu sınıfla uyumlu olmalı |
| Diğer | hepsi | `marketing` | `explicit_opt_in` | hepsi | Güvenli varsayılan |

Satırların hukuki içeriği değiştiğinde (ör. ABD rıza geri çekme kapsamı kuralının yürürlük durumu) tablo sürümü güncellenir ve değişiklik denetim kaydına girer (PC-44).

#### 13.8.3 Platform satırları

Platform kuralları (uygulama mağazası ve mesajlaşma platformu politikaları) uyum tablosunda ülkeden bağımsız **platform satırı** olarak tutulur; platform satırı ve ülke satırı birlikte uygulanır, çakışmada daha kısıtlayıcı olan geçerlidir (PC-54).

| Platform | Kanal | Sınıf | Yeterli rıza | Varsayılan | Dayanak |
|---|---|---|---|---|---|
| iOS | push (APNs) | `marketing` | `explicit_opt_in` (uygulama içi açık onay) | kapalı; kiracı açamaz | App Store İnceleme Kuralları 4.5.4 |
| WhatsApp | WhatsApp | `marketing` | `explicit_opt_in` | kapalı; kiracı açamaz | Meta WhatsApp Business politikası |
| Android | push (FCM, HMS) | `marketing` | `none` | kiracı seçer | Platform ek şart koymaz |
| — | in-app inbox | `marketing` | `none` | kiracı seçer | Platform ek şart koymaz |

- Platform satırı da veridir; platform politikası değiştiğinde tablo sürümü güncellenir ve değişiklik denetim kaydına girer (PC-54).
- Kiracı platform satırını yalnız sıkılaştırabilir (PC-40).

---

### 13.9 Sessiz saat, yasal pencere ve frekans tavanı

#### 13.9.1 Kullanıcı sessiz saati

- Sessiz saat bir kullanıcı tercihidir (gün × saat aralığı), alıcının saat diliminde hesaplanır. Saat dilimi kaynak zinciri ve hesap kuralları (yalnız uygulama katmanında, sabit tzdata, UTC saklama) §10'dadır.
- Sessiz saat varsayılan olarak yalnız anında kesen kanallara uygulanır: push, SMS, sesli arama, WhatsApp ve diğer mesajlaşma kanalları. E-posta ve in-app inbox varsayılan olarak hariçtir; inbox kaydı anında yazılır (PC-45).
- Kullanıcı tercih ekranında kanal bazında e-postayı da sessiz saate dahil edebilir (PC-45).
- Yasal gönderim pencereleri (§13.9.2) ve kiracının pazarlama saat kuralları sessiz saatten ayrıca ve her kanalda geçerlidir (PC-45).
- Sınıf davranışı (PC-45):

| Sınıf | Sessiz saatte |
|---|---|
| `security` | Gönderilir |
| `action_required` | Gönderilir (ertelenemez) |
| `transactional` | Pencere sonuna ertelenir; `expires_at` geçerse `expired` |
| `operational` | Pencere sonuna ertelenir |
| `social` | Pencere sonunda digest'e alınır |
| `marketing` | Pencere sonuna ertelenir; yasal pencere ve frekans tavanı ayrıca uygulanır; tavan doluysa düşer |
| `system` | Uygulanmaz |

- Ertelenen teslim çalışma anında kafesten yeniden geçer; saat dilimi değişikliği bir olaydır.
- Ertelenen teslim hiçbir koşulda sessiz saat içinde teslim edilmez ve erteleme sonludur: bir sonraki uygun anı hesaplayamayan erteleme (`expires_at` öncesinde uygun an yok) `expired` olur; "1 saat ekle, tekrar dene" döngüsü yoktur (PC-46).
- Sabah patlaması önleme: sessiz saat sonunda biriken `social` ve `marketing` teslimleri digest'lenir ve deterministik jitter ile yayılır (rastgelelik kaynağı yoktur, §10) (PC-46).

#### 13.9.2 Yasal pencere

- Yasal gönderim penceresi (`legal_window`, ör. ABD TCPA 08:00–21:00) kullanıcı sessiz saatinden ayrı bir mekanizmadır ve uyum tablosu satırından gelir. Kiracı yasal pencereyi kapatamaz ya da genişletemez (PC-47).
- Saat dilimi çıkarımla (cihaz, profil ülkesi, kiracı varsayılanı) bulunduysa yasal penceresi olan ülkelerde en kısıtlayıcı pencere uygulanır; telefon ülke kodu ve IP yalnız bu pencere seçiminde kullanılır (PC-47).
- Saat dilimi kiracı varsayılanından geldiyse `marketing` ve `social` teslimleri kiracı saat diliminde 10:00–18:00 aralığıyla sınırlanır; bu teslimler raporda ayrı sayılır (PC-48).
- Tabloda yasal pencere satırı olmayan ülkede yalnız kullanıcı sessiz saati uygulanır.

#### 13.9.3 `expires_at`

Her teslimin `expires_at`'i vardır: `security` sınıfında zorunludur ve göndereni verir; diğer sınıflarda kategori varsayılanı geçerlidir (başlangıç: `transactional` 6 saat, `operational` 24 saat, `social` 48 saat, `marketing` kampanya bitişi). Süresi geçen teslim `expired` (terminal) + `rule_id` olarak kaydedilir, sessizce silinmez (PC-49).

#### 13.9.4 Frekans tavanı

- Frekans tavanı kategori × kanal politikasıdır ve bir zamanlayıcıdır, kapı değildir (PC-50).
- Yalnız sistem inisiyatifli sınıflara uygulanır: `marketing`, `social`, `operational`. `security`, `action_required`, `transactional` ve `system` muaftır.
- Yalnız gönderilebilir teslimde sayılır (kapı/filtre ile düşen, iptal edilen sayılmaz).
- Kullanıcı başına global tavan her zaman tanımlıdır (başlangıç: kullanıcı başına günde 12 dış kanal teslimi, muaf sınıflar hariç); kiracı daha sıkı değer verebilir, kaldıramaz.
- Tavana takılanın kaderi kategori politikasında açıkça yazılır: `drop` (`marketing` varsayılanı), `defer` (`operational` varsayılanı), `digest` (`social` varsayılanı), `inbox_only` (dış kanal düşer, inbox kaydı yazılır).
- Sayaç okunamazsa frekans tavanı fail-open çalışır (zamanlayıcıdır; teslimi bloke etmez) ve bu durum metrik + alarm üretir. Sağlayıcı hız limitleri (§12.3.4) ve ajan tavanı (§17) bu kuralın dışındadır; onlar limitsiz duruma düşmez (PC-50).
- Throttle (workflow adımı) ve teslim hızı (kampanya/kanal akışı) frekans tavanından ayrı ayarlanır (§10).

---

### 13.10 OTP alt türleri ve iş bölümü

#### 13.10.1 İki alt tür

`security` sınıfında kod ve bağlantı taşıyan iletiler iki ayrı alt türdür; seçimi gönderen yapar (PC-51):

| Alt tür | Kullanım | İzinli kanallar | Yasak |
|---|---|---|---|
| `otp_oob` | İkinci faktör / ayrı kanal kodu | SMS, WhatsApp, sesli arama | E-posta; fallback zinciri de e-postaya düşmez |
| `email_verification` | E-postayla giriş, adres doğrulama, kurtarma | Yalnız e-posta | Bağlantı tıklamayla doğrudan tüketilmez: önce onay sayfası açılır (§12.6.10) |

- Gerekçe: e-posta out-of-band kimlik doğrulama kanalı değildir (NIST SP 800-63B-4); güvenlik tarayıcıları bağlantıyı teslimden önce açar.
- Hangi alt türün kullanılacağına ve güven seviyesine (AAL) gönderen karar verir; Relay seçilen alt türün kanal kurallarını uygular. Alt türün izin vermediği kanala giden teslim kapı 1e'de `rule_id: otp_channel_forbidden` ile durur.

#### 13.10.2 İş bölümü

| | Gönderen (ör. Access) | Relay |
|---|---|---|
| Kod | Üretir ve doğrular | Üretmez, sır tutmaz, doğrulama yapmaz |
| Limitler | Hesap/akış limitleri | Hedef korumaları: numara ve numara bloğu başına hız sınırı, ülke izin listesi, SMS pumping tespiti ve otomatik durdurma (§12.7.7) |
| Kanal seçimi | "Mobil uygulama aktif mi" (BDDK m.34/7) ve SIM değişikliği sinyalini değerlendirir; buna göre kanal/yöntem seçer ve izinli kanal kümesini istekte bildirir | Gönderenin izinli kanal kümesini aşmaz; bu küme içinde kanal fallback'ini OTP alt türü kurallarıyla uygular |
| Şerit | — | OTP şeridi: kampanyayla şerit, kuyruk ve sağlayıcı hesabı paylaşılmaz (§12.7.6) |

(PC-52)

#### 13.10.3 OTP teslim kuralları

- OTP kanal zinciri sabit bir sıra değil bir fonksiyondur: girdileri gönderenin izinli kanal kümesi, alıcı ülkesi, kanal erişilebilirliği ve sağlayıcı sağlığıdır. WhatsApp yalnız alıcının WhatsApp erişimi biliniyorsa birinci olur (PC-53).
- OTP hiç zamanlanmaz, sessiz saatten geçer, digest'lenmez, frekans tavanına ve içerik tekilleştirmesine girmez; `expires_at` zorunludur ve gönderenden gelir (PC-53).
- OTP ve doğrulama iletisinde render edilmiş içerik saklanmaz; yalnız içerik özeti ve şablon sürümü saklanır (§14) (PC-53).
- OTP iletisinde açılma/tıklama takibi ve bağlantı sarmalama yoktur (§12.6.9).
- Kod, push yükünde ve bildirim önizlemesinde taşınmaz (§12.5.7).

---

### 13.11 Karar register'ı

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| PC-1 | Yedi sabit üst sınıf: `security`, `action_required`, `transactional`, `operational`, `social`, `marketing`, `system`; kiracı kategorileri bunlardan birine bağlanır; sınıf kabul anında atanır ve değişmez. Sınıf davranış tablosu §13.1.1 | KANONİK DEĞİŞMEZ | Hukuki rejimler (6563, CAN-SPAM, ePrivacy), platform kategorileri (WhatsApp, HMS) ve şerit modeli sınıfa bağlı |
| PC-2 | Gönderen türü (`human / system / agent`) sınıftan ayrı alandır | FROZEN (teknik) | Ajan tavanı ve davranışı §17 |
| PC-3 | İşlemsel/bilgilendirme ve pazarlama şablonları birbirine dönüştürülemeyen ayrı tiplerdir; şablon sınıfı yayından sonra değişmez; sızma yasağı yayın kapısında uygulanır | KANONİK DEĞİŞMEZ | 6563 bilgilendirme iletisi tanıtım içeremez; WhatsApp "promosyonel" tanımı aynı ayrıma dayanır |
| PC-4 | Sağlayıcıya iletilen ticari ileti/muafiyet bayrağı sınıftan türetilir, sağlayıcı varsayılanına bırakılmaz, denetim kaydına girer | FROZEN (teknik) | Yönetmelik m.11/8: muafiyet beyanı hizmet sağlayıcının beyanıdır |
| PC-5 | Kategori kiracı tanımlı, tek sınıfa bağlı, kanaldan bağımsız birinci sınıf kavramdır; varsayılan rota, gönderen kimliği, `expires_at` ve frekans politikası taşır; `reason` alanı "neden sana" sorusunu cevaplar | FROZEN (teknik) | Bildirimin birincil amacı kanaldan bağımsızdır |
| PC-6 | `security` kategorileri her zaman kilitlidir; kiracı yalnız `transactional`, `operational`, `action_required` kategorilerini kilitleyebilir; `marketing` ve `social` kilitlenemez. Kilitte kanal değil kategori kilitlenir, en az bir kanal açık kalır | MERKEZİ KARAR | 6563 m.8 ret hakkı; kilidin yalnız gerçekten zorunlu iletilere uygulanması |
| PC-7 | Alt kiracı kategori varsayılanlarını miras alır, tanımladığı ayar ezer | FROZEN (teknik) | §18 alt kiracı modeli |
| PC-8 | Karar kafesi kapı → filtre → zamanlayıcıdır, sıra §13.3.2'deki gibidir; kapılar hiçbir bayrak, kategori ya da kilitle atlanamaz; kilit yalnız filtreleri atlar; kafes her denemede yeniden değerlendirilir | KANONİK DEĞİŞMEZ | "Güvenlik her şeyi ezer" kuralı hukuka aykırı sonuç üretir (ret bildirimini ezer) |
| PC-9 | Her karar `decision` + `rule_id` + `detail` ile kaydedilir; `rule_id` tek, sabit, belgelenmiş sözlükten; filtre kararında kapatan seviye yazılır | KANONİK DEĞİŞMEZ | "Neden almadım" sorusunun cevaplanabilirliği; sessiz kayıp yok |
| PC-10 | Kilitli kategoride bir kanal kapıdan geçemezse rotadaki sıradaki kanala geçilir; OTP alt türü kuralları korunur | FROZEN (teknik) | Zorunlu iletinin sessizce düşmemesi |
| PC-11 | Tercih delmenin tek yolu beyan edilmiş kilitli kategoridir; mesaj/workflow/istek düzeyinde tercih delme bayrağı yoktur | KANONİK DEĞİŞMEZ | Güvenliği/uyumu zayıflatan bayrak yok (Access TI-9 ile aynı ilke) |
| PC-12 | Tercih dört seviyelidir: kategori × kanal, bildirim türü (workflow), tek nesne sessize alma (`scope_key`), haftalık uygunluk programı; VE mantığı; koşullu tercih yoktur; `security` ve kilitli kategoriler kapatılamaz | MERKEZİ KARAR | VE modeli denetlenebilir ve yanlış tarafa hata yapar (göndermemek destek talebi, göndermek idari ceza); Knock modeli |
| PC-13 | Tercih değeri `opt_in / opt_out / unset`; `unset` kategori varsayılanına düşer | FROZEN (teknik) | Varsayılan değişikliği açık tercihleri ezmemeli |
| PC-14 | Sınıf varsayılan matrisi §13.4.2'deki gibidir; `marketing` varsayılanı ülke ve platform satırından türer: iOS push ve WhatsApp kapalı (kiracı açamaz), Android push ve in-app kiracı seçer, ülke satırı onay istiyorsa her zaman kapalı; `action_required` satırı push, e-posta, in-app açık | FROZEN (teknik) · PD (matris) | Ticari ileti önceden onay rejimi; App Store 4.5.4; Meta WhatsApp Business politikası |
| PC-15 | Kiracı kullanıcı adına yalnız kapatma yönünde tercih yazar; `marketing` için "açık" yazılamaz; kiracının seçtiği kategori varsayılanı kullanıcı adına tercih değildir; kullanıcı tercihi kiracı politikasını yalnız kısıtlar | FROZEN (teknik) | Kullanıcı adına onay yazılamaz |
| PC-16 | Tercih hesaba bağlıdır (cihaz/çerez değil); OS izni ve token silinmesi tercihi silmez | FROZEN (teknik) | Tek kanonik kayıt; izin geri açıldığında tercih korunur |
| PC-17 | Digest seçimi tercih değeridir; kapatma eyleminde üç seçenekli ara adım, önceden seçili seçenek yok | FROZEN (teknik) | Aldatıcı varsayılan yasağı |
| PC-18 | Tercih merkezi tek motor, üç yüzey (uygulama içi bileşen, girişsiz imzalı sayfa, bildirim içinden); barındırılan sayfa JS'siz; tık simetrisi, görsel eşdeğerlik, EDPB aldatıcı tasarım kalıpları yokluğu ve WCAG 2.2 AA otomatik kabul testidir | FROZEN (teknik) | GDPR m.7(3) geri çekme kolaylığı; EDPB aldatıcı tasarım rehberi; EAA |
| PC-19 | İzin ekranı her zaman atlanabilir; izin özellik erişimine bağlanamaz; aydınlatma ve açık rıza ayrı; `transactional`/`operational` için rıza sorulmaz | FROZEN (teknik) | KVKK açık rıza ilkeleri; gereksiz rıza da ihlal |
| PC-20 | İzin ve tercih ayrı kayıtlardır; kanıtsız onay yazılamaz; onay metni değişmez ve sürümlüdür | KANONİK DEĞİŞMEZ | Uzun yasal saklamanın tercih verisine bulaşmaması; ispat yükü hizmet sağlayıcıda |
| PC-21 | İzin durumları `NONE / PENDING / ACTIVE / REVOKED / EXPIRED`; `NONE ≠ REVOKED`; herhangi bir kaynakta RET → RET; TR ticari iletide ONAY yalnız İYS'de ONAY varsa | KANONİK DEĞİŞMEZ | İYS'de ilk kayıt RET olamaz; çoklu kaynakta güvenli birleştirme |
| PC-22 | Hukuki izin Access'te, bildirim tercihleri Relay'de; Relay izin kopyasını Access olaylarından tutar ve gönderimde Access'e sormaz; Access'siz kullanımda izni Relay tutar; bağlıyken tek "Tercihlerim" ekranı | MERKEZİ KARAR | Access IDP-37, Access E40 |
| PC-23 | Rıza türü alanı `explicit_opt_in / soft_opt_in / legitimate_interest / none`; yeterli tür uyum tablosundan gelir | FROZEN (teknik) | ePrivacy m.13 soft opt-in; ülke bazlı B2B kuralları |
| PC-24 | Alıcı türü `individual / merchant` tutulur; tacir/esnafa ticari iletide önceden onay gerekmez, ret İYS'ye kaydedilir ve uyulur, gönderimde İYS RET kontrolü yapılır | FROZEN (teknik) | 6563 Yönetmeliği m.6/1-c, m.6/6 |
| PC-25 | Ticari ileti onay ve gönderim kayıtları ayrı saklama sınıfıdır, Türkiye'de 10 yıl; saklama/silme Access OP-74 ve Access Ek C'ye tabidir; özne silmesinde yasal kanıt ayrı ve en az veriyle tutulur | FROZEN (teknik) | 6563 m.11/3 (7416 ile); Yönetmelik m.13/2'deki 3 yıl daha kısa olduğu için kanun süresi uygulanır |
| PC-26 | Access'siz kullanımda e-posta pazarlama onayı için çift onay kiracı seçeneğidir, varsayılan açık; bağlıyken onay akışı Access'in | POLICY DEFAULT | Yazım hatası/tuzak adres koruması, onay tarihi kanıtı |
| PC-27 | İYS kontrolü yalnız `marketing` sınıfında ve `ARAMA`/`MESAJ`/`EPOSTA` kanallarında; kapsam TR bölgesi ya da girilmiş İYS bilgisi; kapsamda İYS bilgisi yoksa gönderilmez (fail-closed); kapsam dışında İYS işlemi yok; push/in-app/WhatsApp İYS'ye girmez; bilgilendirme iletilerinde sıcak yolda İYS sorgusu yok | KANONİK DEĞİŞMEZ | İYS yalnız üç kanal tanır; Yönetmelik m.6/2 ve m.6/5; resmî İYS SSS (push bildirilmez) |
| PC-28 | Bir marka için İYS'ye tek yazıcı Relay'dir (onay/ret, pull, tek tık, SMS RET, şikâyet, kota, belirteç); Access İYS'ye doğrudan yazmaz; Relay yoksa kiracı olayı kendi entegratörüne iletir | MERKEZİ KARAR | İYS kota/belirteç limitleri ve aynı adres için eşzamanlı hareket çakışması tek yazıcı gerektirir; Access IDP-37 |
| PC-29 | İYS iki bağlanma modu: kiracının kendi erişimi ve kiracının yetkili entegratörü (250 bin adres altı); marka alt kiracıya/gönderen kimliğine bağlanır; entegratör kanal yetkileri düzenli yenilenir | FROZEN (teknik) | 250 bin adres altında doğrudan API erişimi yok; entegratör Tebliği |
| PC-30 | İYS yazma yolu outbox + alıcı × marka × kanal serileştirme + idempotent uç; PENDING_IYS → ACTIVE / EXPIRED; kalıcı hata operatör kuyruğuna; 3 iş günü üst sınır, hedef dakikalar; `200` sonrası geri okuma doğrulaması | KANONİK DEĞİŞMEZ | Yönetmelik m.7/11-12 (kaydedilmeyen onay geçersiz); aynı saniyedeki hareketlerin aynı işlem kimliğini üretmesi |
| PC-31 | İş günü/resmî tatil takvimi sürümlü veri tablosudur | FROZEN (teknik) · WATCH (güncelleme sahibi ve kaynağı) | Naif 72 saat hafta sonu ve tatilde yanlış |
| PC-32 | İYS ret alımı push + pull birlikte; pull en az saatlik (varsayılan 15 dk); 7 günlük pencere aşılırsa tam senkron; yerel önbellek gönderim kapısıdır, canlı sorgu yalnız tekil doğrulama; son 1 saatlik kör nokta operatöre gösterilir | FROZEN (teknik) | Değişiklik sorgusu 7 gün geriye bakar ve son 1 saati kapsamaz; sorgu limitleri |
| PC-33 | TR + `marketing` + bireysel alıcıda yerel İYS önbelleğinde ONAY yoksa ya da senkron bayatlık eşiğini aştıysa gönderilmez (fail-closed); başlangıç eşikleri 6 saat uyarı / 24 saat sayfalama ve durdurma | KANONİK DEĞİŞMEZ · EA (bayatlık eşikleri) | Ticari ileti onaysız gönderilemez; eşik ölçümle konur |
| PC-34 | İYS belirteci geçerlilik süresince önbelleklenir; hız/trafik kalitesi limitleri adaptör verisidir; istekler yerel doğrulamadan geçer; izin kotası izlenir ve alarm üretir; İYS olayları kiracıya webhook olarak gider | FROZEN (teknik) | Belirteç ucu limiti cezalandırıcı; başarısız istek oranı IP'nin izin listesinden çıkarılmasına yol açar; kota dolunca onay kaydı sessizce durur |
| PC-35 | RFC 8058 tek tık ve altbilgi bağlantısı alıcıyı o kategoriden çıkarır, tercih olarak kaydedilir, İYS'ye yazılmaz; POST, imzalı opak belirteç, yönlendirme/giriş/onay ekranı yok, GET durum değiştirmez, idempotent, anında, kanıt kaydı | KANONİK DEĞİŞMEZ | RFC 8058; Gmail/Yahoo toplu gönderici şartı |
| PC-36 | Çıkış sayfası "tercihleri yönet" ve "bu markadan hiç ticari e-posta istemiyorum" seçeneklerini sunar; ikincisi İYS'ye marka × EPOSTA RET yazar; çıkış yalnız ticari/toplu kategorilerde bulunur | MERKEZİ KARAR | Adım adım çıkış: kategori tercihi ile yasal ret ayrımı |
| PC-37 | SMS anahtar kelime işleyici sağlayıcıdan bağımsız ve çok dilli (TR ret seti + STOP ailesi + HELP + START/UNSTOP), Türkçe harf katlamalı; SMS RET kanal düzeyinde İYS RET'tir; ret sonrası tek pazarlamasız teyit; ARF şikâyeti pazarlama kategorilerinden çıkış + TR'de İYS EPOSTA RET + `complained` olayı; WhatsApp pazarlama çıkışı tercih kaydına yazılır | KANONİK DEĞİŞMEZ | 6563 m.8 (ret aynı kanalda, ücretsiz, kolay); FCC rıza geri çekme kuralı |
| PC-38 | Tercih merkezinden kanal kapatma tercihtir (İYS'ye yazılmaz); SMS RET, "markadan hiç" ve şikâyet ret bildirimidir (bastırma + İYS + kapı) | FROZEN (teknik) | Tek anahtara indirgemek iki yönde de yanlış sonuç verir |
| PC-39 | Ret anında uygulanır, yasal süreler üst sınırdır; geri çekme kapsamı veridir (`category / all_marketing / all_channel`) ve kaynağa göre varsayılanı §13.7.5'teki gibidir | FROZEN (teknik) · PD (kapsam varsayılanları) | 6563 3 iş günü; TCPA ve CAN-SPAM 10 iş günü |
| PC-40 | Uyum kuralları ülke × kanal × sınıf × rıza türü × alıcı türü veri tablosudur; her ülke için çalışır; yeni ülke satır eklenerek desteklenir; kiracı yalnız sıkılaştırır, gevşetme bayrağı yoktur | KANONİK DEĞİŞMEZ | Tek rıza modeli, yerel politika |
| PC-41 | Özel satırı olmayan ülkede `marketing` için güvenli varsayılan `explicit_opt_in` | KANONİK DEĞİŞMEZ | Bilinmeyen rejimde güvenli taraf |
| PC-42 | Meşru istisnalar (tacir/esnaf, soft opt-in, B2B meşru menfaat) bayrakla değil veriyle karşılanır | FROZEN (teknik) | Denetlenebilirlik |
| PC-43 | Push, in-app ve WhatsApp `marketing` için Relay mevzuatın ya da platform kuralının öngörmediği ek izin şartı koymaz; kullanıcı tercihi geçerlidir; platform kuralının istediği onay platform satırıyla uygulanır (PC-54) | MERKEZİ KARAR | İYS bu kanalları tanımaz; resmî İYS SSS (push bildirilmez) |
| PC-44 | Hazır gelen satırlar TR (6563/İYS), AB (GDPR/ePrivacy, soft opt-in) ve ABD (CAN-SPAM, TCPA saat penceresi, 10DLC) içindir (§13.8.2); satır içeriği değiştikçe tablo sürümü güncellenir | POLICY DEFAULT · WATCH (ABD rıza geri çekme kapsamı kuralının yürürlük durumu ⚠️) | Mevzuat değişiklikleri veriyle izlenir |
| PC-45 | Sessiz saat kullanıcı tercihidir; varsayılan olarak yalnız anında kesen kanallara (push, SMS, ses, WhatsApp, diğer mesajlaşma) uygulanır, e-posta ve inbox hariç; kullanıcı kanal bazında e-postayı dahil edebilir; yasal pencere ve kiracı pazarlama saat kuralları ayrıca geçerlidir; inbox kaydı anında yazılır; sınıf davranışı §13.9.1 tablosundaki gibidir (`security` ve `action_required` deler) | FROZEN (teknik) | `action_required` ertelenemez; inbox ve e-posta kendiliğinden kesmez; e-postanın sabah yığılması teslim edilebilirliği bozar |
| PC-46 | Ertelenen teslim çalışma anında yeniden değerlendirilir, sessiz saat içinde asla teslim edilmez, erteleme sonludur (uygun an yoksa `expired`); sabah patlaması digest + deterministik jitter ile önlenir | KANONİK DEĞİŞMEZ | Naif "1 saat ekle" sonsuz döngü üretir |
| PC-47 | Yasal pencere kullanıcı sessiz saatinden ayrı mekanizmadır, uyum tablosundan gelir, kiracı kapatamaz; saat dilimi çıkarımla bulunduysa en kısıtlayıcı pencere uygulanır, telefon ülke kodu ve IP yalnız bu seçimde kullanılır | KANONİK DEĞİŞMEZ | TCPA 08:00–21:00 alıcı yerel saati; eyalet kuralları daha dar olabilir |
| PC-48 | Saat dilimi kiracı varsayılanından geldiyse `marketing` ve `social` kiracı saat diliminde 10:00–18:00 ile sınırlanır ve raporda ayrı sayılır | POLICY DEFAULT | Saat dilimi hatası payında alıcının gece saatine düşmeme |
| PC-49 | `expires_at` `security`'de zorunlu ve göndericiden; diğer sınıflarda kategori varsayılanı (başlangıç: transactional 6 sa, operational 24 sa, social 48 sa, marketing kampanya bitişi); süresi geçen `expired` + `rule_id` | FROZEN (teknik) · PD (süreler) | Eskimiş bildirimin değeri yok |
| PC-50 | Frekans tavanı kategori × kanal politikası ve zamanlayıcıdır; yalnız `marketing`/`social`/`operational`; yalnız gönderilebilir teslim sayılır; global kullanıcı tavanı her zaman tanımlı (başlangıç günde 12); takılanın kaderi (`drop/defer/digest/inbox_only`) kategori politikasında yazılır; sayaç okunamazsa fail-open + alarm | FROZEN (teknik) · PD (değerler) | Tavan bir şekillendiricidir; insan müdahalesiz son savunma |
| PC-51 | `security` sınıfında iki alt tür: `otp_oob` yalnız SMS/WhatsApp/sesli arama, e-posta yasak ve fallback e-postaya düşmez; `email_verification` yalnız e-posta, bağlantı önce onay sayfası açar; alt türü ve AAL'yi gönderen seçer, Relay kanal kurallarını uygular | KANONİK DEĞİŞMEZ | NIST SP 800-63B-4 §3.1.3.1; güvenlik tarayıcılarının bağlantıyı önceden açması |
| PC-52 | OTP iş bölümü: gönderen kodu üretir/doğrular, hesap/akış limitlerini koyar, BDDK m.34/7 ve SIM değişikliği sinyalini değerlendirip izinli kanal kümesini bildirir; Relay hedef korumalarını (numara/blok hız sınırı, ülke izin listesi, pumping tespiti ve durdurma), alt tür kurallı fallback'i ve OTP şeridini uygular; kod üretmez, sır tutmaz, doğrulamaz | MERKEZİ KARAR | BDDK m.34/7-8, TCMB m.10; Access E40 |
| PC-53 | OTP zinciri bir fonksiyondur (WhatsApp yalnız erişim biliniyorsa birinci); OTP zamanlanmaz, sessiz saatten geçer, digest/frekans/içerik tekilleştirmesine girmez, `expires_at` zorunlu; render edilmiş içerik saklanmaz (özet + şablon sürümü); takip ve bağlantı sarmalama yok; kod push'ta taşınmaz | KANONİK DEĞİŞMEZ | OTP gecikmeye ve sızıntıya duyarlı |
| PC-54 | Uyum tablosunda ülkeden bağımsız platform satırları vardır (§13.8.3): iOS push ve WhatsApp `marketing` varsayılan kapalı, kullanıcı açıkça açarsa gönderilir; Android push ve in-app varsayılanı kiracı seçer; ülke satırıyla birlikte uygulanır, çakışmada kısıtlayıcı olan geçerlidir; kiracı yalnız sıkılaştırır | FROZEN (teknik) | App Store İnceleme Kuralları 4.5.4; Meta WhatsApp Business politikası |
