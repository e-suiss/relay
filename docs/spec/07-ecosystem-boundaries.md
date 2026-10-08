## 7. Ekosistem sınırları

Relay'in ekosistemdeki yeri tek cümleyle: **Relay bir olayın ya da mesajın doğru kişiye, servise, cihaza ya da ajana nasıl ulaşacağına karar veren ve bunu kaydeden üründür; yetki, kimlik, iş durumu, yürütme ve para gerçeğinin sahibi değildir.** Bu bölüm her bilginin tek sahibini (§7.1), Relay'in Access ile ilişkisini (§7.2–§7.3) ve Work, Executor, ajan çatıları ve protokolleri, One, Pay, dış IdP'ler ve diğer dış sistemlerle sınırlarını (§7.4–§7.10) tanımlar.

Ekosistem kararları "E-*n*" biçimindedir. Access'e atıf "Access E40", "Access OP-74" biçimindedir. Kavramlar §5'te (C-*n*), değişmezler §6'dadır (INV-*n*).

**Okuma kuralı.**
1. Bir bilginin tek sahibi vardır; diğer her kopya gözlenen, önbelleklenmiş ya da yansıtılmış kopyadır ve sahibin kaydıyla çelişirse kopya yanlıştır.
2. Bu bölümdeki sınırlar hiçbir değişmezi (§6) gevşetemez. Özellikle "teslim yetki değildir" (INV-28) ve "Relay onay kapısı değildir" (INV-29) her komşu için geçerlidir.
3. Suiss ürünleri (Access, Work, Executor, One, Pay) Relay'i üçüncü taraflarla aynı sözleşmeyle kullanır. Suiss ürününe özel gizli bir API, ayrıcalıklı yazma yolu ya da sözleşme dışı davranış yoktur (E-3). Bir Suiss ürününün rolünü üçüncü taraf bir sistem ya da müşteri kodu aynı API ile üstlenebilir.

### 7.1 Sahiplik matrisi

| Bilgi / sorumluluk | Tek sahibi | Relay'deki biçimi | Not |
|---|---|---|---|
| Yetki, onay, ajan yetkisi, kimlik doğruluğu | Access (ya da kiracının yetki sistemi) | Yok; yalnız referans (`access_aas_ref`) | INV-28, INV-29 |
| Olayın anlamı, içerik, "kime, neden", alıcı kümesi (eligible set) | Üretici (Access, Work, Pay, kiracı sistemi) | Taşınan veri | Relay kümeyi genişletmez, daraltmaz; yalnız kanal seçer (E-12) |
| Kanal, zamanlama, retry, fallback, sağlayıcı seçimi, teslim durumu | Relay | Kanonik (C-32, C-67) | Access E40 (2) |
| Pazarlama izni (hukuki kayıt, kanıt, geçmiş) | Access bağlıysa Access; değilse Relay | Access bağlıysa kopya | E-17, E-18 |
| Bildirim tercihleri (kategori × kanal, sessiz saat, digest seçimi) | Relay | Kanonik (C-61) | E-17 |
| İYS'ye yazma ve İYS'den çekme (bir marka için) | Relay bağlıysa Relay; değilse kiracının entegratörü | Kanonik İYS bağlantısı | Access İYS'ye hiçbir koşulda doğrudan yazmaz (E-21) |
| OTP kodu, doğrulama, güven seviyesi, OTP kanal/yöntem seçimi | Gönderen (Suiss'te Access) | Yok | INV-22, E-32 |
| OTP hedef korumaları (numara/blok hız sınırı, ülke izin listesi, pumping tespiti, kanal fallback'i, OTP şeridi) | Relay | Kanonik | E-33 |
| Bekleme noktası, korelasyon, yanıt toplama, "çözüldü" olayı | Relay | Kanonik (C-72) | E-45 |
| Yürütme durumu, checkpoint, pause, takeover, devam, iş etkisi ve telafisi | Bekleyen taraf (Executor, ajan çatısı, müşteri kodu) | Yok | E-46, Access E31 |
| İnsanın iş/onay kuyruğu, Gate alıcı seçimi | Work (ya da kiracının koordinatörü) | Yok; Relay teslim eder | Access XI-7; E-41 |
| Ajan posta kutusu | Relay | Kanonik (C-68) | E-42 |
| Ajan kaydı (ad, teslim uçları, posta kutusu, abonelikler) | Relay | Kanonik (C-21) | E-28 |
| Ajan kimliği ve yaşam döngüsü (askıya alma, silme) | Access bağlıysa Access | Bağ + olay | E-29 |
| Ajanın hafızası, planı, akıl yürütmesi | Ajan (Suiss'te One) | Yok | E-55 |
| Finansal durum, ödeme, iade, mutabakat | Pay (ve hesap sahibi sistem) | Yok; yalnız bildirim içeriği | E-58 |
| Operatör kimliği | Bağlı OIDC IdP (Access önerilir) | Oturum | E-26 |
| Operatör rolleri ve yetkileri | Relay | Kanonik | E-26 |
| Relay yönetim eylemlerinin denetim kaydı | Relay | Kanonik (C-87) | E-31 |
| Olayların müşteri tarafında üretim sırası ve doğruluğu | Müşteri | Yok | E-66 |
| Segment (öznitelik sorgulu kitle) hesabı | Kiracı / pazarlama otomasyonu ürünü | Liste ya da topic olarak girdi | E-67 |

### 7.2 Bağımsız çalışma ve sürtünmesizlik

- **E-1 Bağımsız çalışır, birlikte sürtünmesiz çalışır.** Relay ve Access birbirinden bağımsız ürünlerdir; her biri öbürü olmadan tam kurulup çalıştırılabilir. Birlikte kullanıldıklarında ek kod, ek altyapı ya da elle senkronizasyon gerekmez (Access E40).
- **E-2 Dört çalışma biçimi.** (1) Access, Relay olmadan: Access kendi mesajlarını yerleşik doğrudan gönderim moduyla yollar (Relay bu yolda yoktur). (2) Access, Relay ile: Access'in insana giden bütün mesajları Relay'den gider (§7.3.2). (3) Relay, Access olmadan: kendi API anahtarları, operatör girişi ve abone jetonuyla; başka bir IdP ile standart OIDC üzerinden çalışır (§7.9). (4) Relay, Access ile: operatör girişi ve step-up, abone jetonu, ajan kimliği ve pazarlama izni Access'ten gelir; denetim kayıtları bağlanır (§7.3).
- **E-3 Birinci taraf ayrıcalığı yoktur.** Suiss ürünleri Relay'in herkese açık sözleşmesini (§9, §16) kullanır. Bir Suiss ürününe özel davranış gerekiyorsa genel bir yetenek olarak tanımlanır ve her üreticiye açılır (ör. üretici sahipli şablon, C-55).
- **E-4 Sürtünmesizlik kuralları.** (a) İki ürün tek bir bağlantı ayarıyla bağlanır; uç noktalar ve anahtarlar otomatik keşfedilir. (b) Ortak webhook imza profili ve ortak olay biçimi (CloudEvents) kullanılır (§7.3.12). (c) Ortak kiracı eşlemesi vardır (§7.3.13). (d) Relay eklendiğinde ya da kaldırıldığında müşteri kodu değişmez; gönderim yolunu Access kendisi değiştirir.
- **E-5 Gerektiren özellik bunu söyler.** Hiçbir özellik öbür ürün yokken sessizce bozulmaz (INV-56). Access gerektiren her Relay özelliği (ör. token exchange ile abone jetonu, Access onay yüzeyine derin bağlantı, Access step-up) panelde, API belgesinde ve hata gövdesinde bunu açıkça belirtir ve Access'siz eşdeğerini gösterir.

### 7.3 Access sınırı

#### 7.3.1 Ortak ilkeler

- **E-6 Teslim yetki değildir.** Teslim, ack, okundu, yanıt ve bekleme çözümü hiçbir durumda Access yetki durumu değildir ve onu değiştirmez (Access E30, Access EI-9, Access INV-24). Relay'in cevabı onay değildir (Access EI-18).
- **E-7 Relay asla.** Relay Access'e karşı: (a) yetki, Gate ya da iş etkisi gerçeğinin kaynağı olmaz; (b) teslim edemediği bir olay yüzünden bir yetki değişikliğini geri almaz veya geciktirmez; (c) bir bildirimin yanıtını onay saymaz; (d) Access durumunu değiştiren hiçbir çağrı yapmaz. Teslim durumu Access'e yalnız bilgi olarak döner (Access §7.9.8.4).
- **E-8 Üç ack ayrı bilgidir.** Relay'in teslim ack'i (mesaj hedefe ulaştı), Work'ün anlamsal ack'i (kişi okudu/kabul etti) ve PEP'in yetki durumu ack'i (iptal uygulandı) ayrıdır; Relay yalnız birincisinin sahibidir ve hiçbiri yetki durumunu değiştirmez (Access §7.9.8.3).

#### 7.3.2 Access'in mesajları ve anlamsal olaylar

- **E-9 Access yalıtılmış bir platform kiracısıdır.** Access, Relay bağlıyken Relay'de diğer kiracılardan yalıtılmış bir kiracı olarak çalışır: kendi gönderen alan adı ve gönderici kimlikleri, diğer kiracılardan ayrı izlenen itibar ve devre kesicileri. Access'in itibarı başka kiracının davranışından etkilenmez.
- **E-10 İçerik Access'in, teslim Relay'in.** Mesaj içeriği, "kime" ve "neden" Access'indir; kanal, zamanlama, retry, fallback ve teslim durumu Relay'indir. Access mesajları üretici sahipli şablonlarla (§7.3.11) ya da Access'in gönderdiği içerikle render edilir.
- **E-11 Anlamsal olayın sınıfı.** Access anlamsal olayları (yetki iptali, oturum ve güvenlik uyarısı, hesap değişikliği vb.) `security` sınıfındadır; üretici olay başına başka bir sınıf beyan etmedikçe bu sınıf uygulanır. Bu olaylara digest, frekans tavanı ve içerik tekilleştirme uygulanmaz; idempotency (`Idempotency-Key`, `dedup_key`) uygulanır. Access her olayı kendi olay kimliğinden türetilmiş `dedup_key` ile gönderir.
- **E-12 Alıcı kümesi üreticinindir.** Access ve Work olaylarında alıcı kümesi (eligible set) üreticinindir. Relay kümeyi genişletmez ya da daraltmaz; yalnız her alıcı için kanal seçer. Kapı sonucu bir alıcıya teslim yapılamıyorsa bu bir karar kaydıdır (INV-1), kümenin değişmesi değildir.
- **E-13 Son kullanma ve süresi geçmiş güvenlik bildirimi.** Access anlamsal olayının "ne zamana kadar" alanı `expires_at`'e eşlenir. Süresi geçmiş güvenlik bildiriminin davranışını gönderen belirler: `on_expire: drop | inbox_only`. Gönderen belirtmezse varsayılan `drop`'tur (E-73).
- **E-14 Revocation taşıması.** Access yetki iptali ve diğer anlamsal olayların insanlara ve sistemlere taşınması Relay'in (ya da Access identity plane'in SSF/CAEP vericisinin) işidir. Her iki yolda da güvenlik teslimata dayanmaz; Relay'in gecikmesi ya da başarısızlığı hiçbir yetki kararını değiştirmez (Access E13, Access INV-24).

#### 7.3.3 CIBA ve onay

- **E-15 CIBA'da roller.** CIBA'da Access OP'dir; Relay davetin teslim kanalıdır (push, SMS, e-posta ve diğer kanallar; fallback dahil). Onay Access onay yüzeyinde verilir (Access E32). CIBA daveti `action_required` sınıfındadır. CIBA ping modunda Access'in istemciye yaptığı bildirim bir yetki protokolü mesajıdır ve Access'te kalır; Relay webhook teslimiyle taşınmaz. Relay yalnız kullanıcıya daveti taşır.
- **E-16 Relay yanıt toplayıcıdır, onay kapısı değildir.** Relay karar isteğini teslim eder, yanıtı (değer, yanıtlayan, kanal, kanal kanıt düzeyi, zaman) toplar ve sahibine iletir; "onay" kararı, risk kademesi ve uygulama sahibindedir. Access'li kurulumda yüksek riskli onaylar Access onay yüzeyine gider; onay türündeki inbox ya da bildirim öğesinde eylem yalnız Access onay yüzeyine derin bağlantıdır (Access XI-8, Access A-5). Access'siz kurulumda isteğe bağlı basit karar kaydı tutulur ve "kanal yanıtı, yetki kanıtı değil" diye etiketlenir (§17).

#### 7.3.4 Pazarlama izni ve bildirim tercihleri

- **E-17 Bölüşüm.** Hukuki izin (pazarlama onayı/ret, kanıt, geçmiş) Access'tedir (Access IDP-37); değişiklikte Access bir izin olayı yayınlar. Bildirim tercihleri (kategori × kanal, bildirim türü, sessiz saat, digest seçimi) Relay'dedir.
- **E-18 Kopya ve gönderim anı.** Relay izinlerin kopyasını Access izin olaylarından tutar; gönderim anında Access'e sormaz. Access'siz kullanımda izin kaydını Relay kendisi tutar (C-60); iki durumda da izin ve tercih ayrı kayıtlardır (C-5).
- **E-19 Tek "Tercihlerim" ekranı.** Access ve Relay bağlıyken son kullanıcı izinleri ve bildirim tercihlerini tek bir "Tercihlerim" ekranında görür. Relay'in tercih merkezi bileşeni Access ekranıyla birleşik görünür; her alanın yazıldığı yer sahibidir (izin Access'e, tercih Relay'e).

#### 7.3.5 İYS

- **E-20 İYS entegrasyonu tamamen Relay'dedir.** Bir marka için İYS'ye tek yazıcı Relay'dir: onay/ret yazma, değişiklik çekme, tek tık çıkış ve SMS "RET" yanıtından ret, spam şikâyetinden ret, kota ve jeton yönetimi tek yerdedir (Access B23).
- **E-21 Access'in rolü.** Access pazarlama iznini ve geçmişini kaydeder ve her değişiklikte İYS'nin istediği alanları eksiksiz taşıyan bir izin olayı yayınlar (izin tarihi, kaynak, kanal, alıcı, alıcı türü). Relay bağlıysa olayı alır ve İYS'ye yazar. Relay yoksa kiracı olayı kendi İYS entegratörüne iletir. Access İYS'ye hiçbir koşulda doğrudan yazmaz.
- **E-22 Bağlanma modları.** İYS adaptörü iki modu destekler: kiracının kendi İYS erişimi ve kiracının yetkili entegratörü. İYS'nin doğrudan bağlantı eşiğinin (250 bin adres) altındaki markalar için yetkili entegratör üzerinden bağlantı desteklenir. Entegratörlük statüsü ürün kararı değildir; ürün iki modu da aynı kalitede destekler.

#### 7.3.6 Abone jetonu

- **E-23 Varsayılan yol.** Relay kısa ömürlü, dar kapsamlı abone jetonu (C-17) basar; kiracı backend'i Relay API'sinden ister. Bu yol Access'siz ve her IdP ile çalışır.
- **E-24 Access ile token exchange.** Access'li kiracılarda istemci, Access jetonunu RFC 8693 token exchange ile Relay abone jetonuna çevirir; kiracı backend'ine kod gerekmez. Abone, Access'in kiracıya özgü (pairwise) `sub` değeriyle eşlenir ve abonenin `external_id`'si bu değerdir.
- **E-25 Access jetonu inbox anahtarı değildir.** Relay, Access jetonunu doğrudan inbox ya da tercih erişimi için kabul etmez; erişim her zaman Relay abone jetonuyla olur. Kiracı backend'inin Access servis jetonuyla sunucu API'sine erişmesi ayrı yoldur (§9 API-71).

#### 7.3.7 Operatör kimliği ve step-up

- **E-26 Operatör girişi.** Relay paneline ve yönetim API'sine giriş herhangi bir OIDC IdP ile yapılır; Access önerilir. Roller ve yetkiler Relay içinde tutulur. Access bağlıysa kiracılar ve organizasyonlar otomatik eşlenir ve operatör kullanıcıları Access'ten gelir.
- **E-27 Hassas işlemler.** Kill switch'i yeniden açma, sağlayıcı sırrı ya da anahtar rotasyonu, alıcı kişisel verisini açık gösterme, İYS ayarları, ajan bekleyenlerini serbest bırakma ve benzeri hassas işlemler: Access bağlıysa Access step-up ister; gerekiyorsa Access karar API'sine (AuthZEN) sorulur. Access yoksa bağlı IdP'den yeniden doğrulama (`max_age` / `acr`) istenir. Hassas işlem listesi §18'dedir. Step-up ya da karar alınamazsa işlem yapılmaz (INV-43'ün yönetim yüzeyindeki karşılığı).

#### 7.3.8 Ajan kimliği

- **E-28 Ajan kaydı Relay'dedir.** Ajan alıcı kaydı (ad, teslim uçları, posta kutusu, abonelikler) Relay'dedir (C-21).
- **E-29 Access bağı.** Access bağlıysa kayıt Access'teki ajan kimliğine (Party/Instance) bağlanır; ajan Relay'e Access jetonuyla kimliğini kanıtlar. Access'te ajanın askıya alınması ya da silinmesi olayıyla Relay o ajana teslimi durdurur; posta kutusundaki mesajlar saklama kuralına göre kalır (INV-47).
- **E-30 Access'siz ajan.** Access yoksa ajan Relay API anahtarı ya da başka bir IdP jetonuyla doğrulanır. Kimlik ve yetki doğruluğu her durumda kimliği veren sistemdedir; teslim yetkiyi değiştirmez (Access EI-9).

#### 7.3.9 Denetim kaydı

- **E-31 Bağlanmış denetim kayıtları.** Relay kendi kurcalanmaya dayanıklı denetim kaydını tutar (C-87); bütünlük modeli (periyodik imzalı Merkle kontrol noktası) ve biçimi Access'inkiyle aynıdır, müşteri iki ürünün kaydını tek doğrulayıcıyla kontrol eder. Access bağlıysa her kayıt eylemi yapanın Access kimliğini ve ilgili Access kayıt numarasını (ör. step-up ya da karar kaydı) taşır; iki ürünün kayıtları birbirine referansla bağlanır, birbirine kopyalanmaz. SIEM'e dışa aktarım ve saklama Access Ek C kurallarına göre yapılır (Access OP-74).

#### 7.3.10 OTP ve doğrulama mesajlarında iş bölümü

- **E-32 Access'in işi.** Access kodu üretir ve doğrular; hesap ve akış limitlerini koyar; "mobil uygulama aktif mi" (BDDK Bilgi Sistemleri Yönetmeliği m.34/7) ve SIM değişikliği sinyalini değerlendirir; kanal ve yöntem seçimini buna göre yapar; `otp_oob` ya da `email_verification` alt türünü ve güven seviyesini (AAL) seçer.
- **E-33 Relay'in işi.** Relay hedef korumalarını uygular: numara ve numara bloğu başına hız sınırı, ülke izin listesi, SMS pumping tespiti ve otomatik durdurma, seçilen alt türün kurallarıyla kanal fallback'i (INV-23), OTP şeridi. BDDK m.34/7 ve SIM değişikliği sinyali Access'ten geldiğinde Relay yönlendiricisinin girdisi olur; Relay bu sinyalleri kendisi üretmez.
- **E-34 Relay kodla iş yapmaz.** Relay kod üretmez, sır tutmaz, doğrulamaz (INV-22); OTP render içeriğini saklamaz (INV-26). "Kodu tekrar gönder" yeni bir istektir ve yeni anahtarla gelir.

#### 7.3.11 Korunan (üretici sahipli) şablonlar

- **E-35 Access şablonları korunur.** Access mesaj şablonlarını Relay'e üretici sahipli şablon (C-55) olarak API ile yayımlar. Metin ve çeviriler Access'indir; kiracı değiştiremez (Access X35, Access X39). Kiracı yalnız Access'in izin verdiği marka alanlarını (logo, renkler, gönderen adı, alt bilgi) değiştirir. Kanala göre render (SMS segmenti, push başlık/gövde, e-posta HTML + düz metin, WhatsApp onaylı şablon eşlemesi) Relay'indir. Aynı mekanizma her üreticiye açıktır (E-3).

#### 7.3.12 Ortak webhook profili ve olay biçimi

- **E-36 Ortak Suiss webhook profili.** Relay ve Access aynı webhook profilini kullanır (Access TN-136): aynı başlık seti, varsayılan imza `v1a` Ed25519 (`v1` HMAC yalnız uyumluluk için), çakışmalı anahtar rotasyonu, CloudEvents zarfı, `webhook-id` saklama önerisi. Bir alıcı iki ürünün olaylarını tek doğrulayıcıyla doğrular. Ayrıntı §16'dadır.
- **E-37 Ortak olay biçimi.** Access'ten Relay'e giden olaylar ve Relay'in giden olayları CloudEvents biçimindedir; `traceparent` iki ürün arasında taşınır.

#### 7.3.13 Kiracı eşlemesi, bağlantı ve bölge

- **E-38 Ortak kiracı eşlemesi.** Access ve Relay bağlandığında Access kiracısı Relay kiracısına, Access B2B organizasyonu Relay alt kiracısına (C-12) eşlenir. Access'te organizasyon açılınca ya da değişince Relay karşılığı otomatik oluşur ve güncellenir.
- **E-39 Aynı bölge.** Access ve Relay kullanan kiracının iki ürünü aynı bölgededir (INV-41); bölgeler arası bağlantı kurulmaz.
- **E-40 Tek bağlantı ayarı.** Bağlantı kiracı başına tek ayardır; keşif belgesinden uç noktalar, imza anahtarları ve desteklenen yetenekler otomatik alınır. Bağlantı kaldırıldığında Relay Access'siz çalışma biçimine döner; Access'ten gelen kopyalar (izin, eşleme) saklama kuralına göre kalır.

#### 7.3.14 Access spec'indeki karşılıklar

Bu bölümdeki kararların Access tarafındaki karşılıkları: Access E40 (bağımsızlık ve sürtünmesizlik), Access B23 (İYS Relay'de), Access IDP-37 (pazarlama izni Access'te, tercihler Relay'de), Access TN-136 (ortak webhook profili), Access T41 (SDK seti), Access §7.9.8 (Relay seam). Bu Access maddelerinin değişmesi Relay'de bu bölümün yeniden açılmasını gerektirir.

### 7.4 Work sınırı

- **E-41 Work alıcıyı seçer, Relay teslim eder.** Work Gate'lerinde ve dikkat bildirimlerinde alıcı kümesi Work'ündür (Access §7.9.8.2); Relay yalnız teslim eder (E-12).
- **E-42 İki kuyruk ayrıdır.** İnsanın iş ve onay kuyruğu Work'ündür (Access XI-7); Relay'in ajan posta kutusu (C-68) ajanın kutusudur. Relay insan için görev nesnesi üretmez; inbox öğesi bir bildirimdir, görev değildir.
- **E-43 Politika Work'ten, uygulama Relay'de.** Suiss'te eskalasyon politikası (C-47) Work'ten gelir, Relay uygular. Ajan tavanı aşıldığında (C-78) Suiss'te sahip Work'tür: "ajan tavanı aştı" olayı Work'e gider; hepsini gönder / iptal et / ajanı durdur kararı Work'te verilir ve Relay'e API ile iletilir. `waitpoint.expired` sonrası otomatik ret/kabul kararı Suiss'te Work ve Access'indir.
- **E-44 Work'süz kurulum.** Work kullanılmayan kurulumda aynı roller kiracının kendi koordinatörü ya da müşteri kodu tarafından aynı API ile üstlenilir (E-3).

### 7.5 Executor ve bekleyen taraflar

- **E-45 Bekleme Relay'in, yürütme bekleyenin.** Bekleme noktası, korelasyon ve teslim Relay'indir: Relay "şu anahtara yanıt bekleniyor, son tarih X" kaydını tutar, hangi kanaldan gelirse gelsin yanıtı eşleştirir ve bekleyen tarafa "çözüldü" olayını teslim eder.
- **E-46 Relay yürütme motoru değildir.** Checkpoint, pause, takeover, devam ettirme ve yürütme durumu bekleyen tarafındır (Executor, LangGraph ve benzeri ajan çatıları, müşteri kodu; Access E31). Relay ajan adımlarını çalıştırmaz, dayanıklı yürütme motoru değildir, iş etkisi telafisi (saga) yapmaz. Bekleme çözülünce Relay yalnız kendi adımlarını geri alır: eskalasyonu ve bekleyen teslimleri iptal eder.
- **E-47 Bekleme noktası herkese açıktır.** Bekleme noktası Executor'a özel değildir; her ajan sistemi ve müşteri kodu aynı API'yi kullanır. Bekleyen tarafın heartbeat'i (C-72) "bekleyen öldü" durumunu, toplam süre "insan geç kaldı" durumunu ayırır (INV-32).
- **E-48 Uzun iş bildirimi.** Executor'ın ve diğer bekleyenlerin uzun iş bitişi bildirimleri Standard Webhooks ile gönderilir ve Relay gelen ile giden için aynı doğrulayıcıyı kullanır.
- **E-49 Yanıt onay değildir.** Bekleme noktasına gelen yanıt onay değildir (Access EI-18, Access E32); gerçek onay gerekiyorsa Access onay yüzeyinde verilir ve bekleyen taraf onayı Access'ten doğrular (E-16).

### 7.6 Ajan protokolleri

- **E-50 Desteklenen protokoller.** Relay A2A, MCP ve AG-UI'yi destekler. Protokol sürümleri (A2A v1.0, MCP 2026-07-28) izlenir; yeni sürüme geçiş protokol değişiklik notlarına göre değerlendirilir (E-74).
- **E-51 A2A.** Relay A2A push bildirimlerini alır ve gönderir; görev yaşam döngüsü olaylarını taşır. A2A'nın tanımlamadığı retry, imza, DLQ ve SSRF koruması Relay'in teslim motorundan gelir. Gelen A2A olayları `(task, seq)` ile idempotent işlenir; durum gerekirse `GetTask` ile yeniden okunur (INV-35).
- **E-52 MCP.** Relay bir MCP sunucusu sunar: bildirim gönder, bekleme noktası aç, posta kutusu oku/ack ve benzeri araçlar. MCP Tasks `input_required` durumu bekleme noktasına eşlenir. MCP araçları HTTP API ile aynı yetki kapsamlarına ve aynı politika kafesine tabidir.
- **E-53 AG-UI.** AG-UI olayları realtime kanalda opak yük olarak taşınır; Relay yorumlamaz, içeriğini politika girdisi yapmaz.
- **E-54 Protokoller onay kapısını atlayamaz.** MCP ya da A2A üzerinden gelen yanıt Access onayı değildir (Access A-6, Access AG-33, Access EI-18). Protokol üzerinden taşınan her içerik yapılandırılmış mesaj kuralına (C-76, INV-30) tabidir. Bekleme durumları ile A2A, MCP Tasks ve yaygın ajan API'lerinin "yanıt bekliyor" durumları arasındaki eşleme tablosu §17'dedir.

### 7.7 One sınırı

- **E-55 One bir ajandır.** One, Relay için bir ajan alıcı (C-21) ve gönderen türü `agent` olan bir üreticidir; Relay'de özel statüsü yoktur. One'ın hafızası, planı, konuşması ve kişisel çıkarımları Relay'e girmez; Relay'e yalnız gönderilecek mesaj ve yapılandırılmış alanlar gelir.
- **E-56 One'ın bildirimleri ajan kurallarına tabidir.** One kaynaklı bildirimler ajan tavanına (C-78), kullanıcının tercihlerine ve politika kafesine tabidir; arayüzde ajan kaynaklı olarak gösterilir.
- **E-57 One içerikten yetki üretemez.** One'a teslim edilen bildirim, yanıt ya da posta kutusu mesajı One için yetki değildir (INV-28); One bir yetki gerektiren eylemi yalnız Access'teki kendi yetkisiyle yapabilir.

### 7.8 Pay sınırı

- **E-58 Pay bir üreticidir.** Pay, ödeme, iade ve benzeri olayları herkese açık olay API'siyle gönderen bir üreticidir. Finansal durum, ödeme durumu ve mutabakat Pay'indir; Relay bunları tutmaz, türetmez.
- **E-59 Teslim ödeme kanıtı değildir.** Relay'in teslim durumu bir ödemenin gerçekleştiğinin, onaylandığının ya da kullanıcının bilgilendirildiğine dair hukuki kanıtın yerine geçmez; kanıt Pay'in ve hesap sahibi sistemin kaydındadır. Ödeme onayı gerektiren yüksek sonuçlu işlemlerde Relay yalnız daveti teslim eder; onay Access onay yüzeyindedir (E-16).
- **E-60 Finansal veri biçimi.** Pay olaylarında tutarlar yapılandırılmış (`{amount, currency}`) gelir ve yerelleştirmeyi Relay şablonu yapar. Kilit ekranında hassas veri gösterilmemesi kuralı (§11) finansal bildirimlere de uygulanır.

### 7.9 Dış IdP'ler

- **E-61 Standart OIDC.** Access'siz kurulumda operatör girişi herhangi bir standart OIDC IdP ile yapılır; hassas işlemler için IdP'den `max_age` / `acr` ile yeniden doğrulama istenir (E-27).
- **E-62 Abone ve ajan kimliği.** Dış IdP kullanan kiracıda abone jetonu varsayılan yolla (E-23) alınır. Ajan, Relay API anahtarı ya da kiracının bağladığı IdP'nin jetonuyla doğrulanır (E-30).
- **E-63 Dış IdP yetki kaynağı değildir.** Dış IdP'den gelen kimlik iddiası yalnız Relay'e kimlik kanıtıdır; Relay'de roller Relay'in kendi kaydındadır.

### 7.10 Diğer dış sistemler

- **E-64 Kendi MTA'sını bağlama.** Kiracı kendi posta sunucusunu (Postfix, KumoMTA, Exchange vb.) standart SMTP adaptörüyle bağlayabilir; bounce işleme (VERP, DSN/ARF ayrıştırma, sınıflandırma) Relay'dedir. SaaS'ta Relay kendi MTA'sını işletmez; ticari ESP'ler kullanılır.
- **E-65 Analitik ve SIEM hedef olarak.** Relay içinde OLAP yoktur. ClickHouse benzeri analitik veritabanları ve SIEM yalnız teslim hedefi olarak bağlanır; anlamsal olaylar ve denetim kayıtları sürekli akıtılabilir, ham veri dışa aktarılabilir. Hedefteki kopya Relay kaydıyla çelişirse kopya yanlıştır.
- **E-66 Müşteri veritabanı bağlayıcısı kapsam dışıdır.** Müşteri veritabanını okuyan bağlayıcı yoktur. İsteyen Debezium, Sequin gibi araçları CloudEvents çıkışıyla Relay'e bağlar (belgelerde rehber). Olayların müşteri tarafında hangi sırayla ve nasıl üretildiği Relay'in sorumluluğu değildir; Relay gelen olayı sözleşmeye göre işler.
- **E-67 Segment motoru kapsam dışıdır.** Öznitelik sorgulu segmentasyon ve yolculuk kurgusu pazarlama otomasyonu ürünlerinindir. Kiracı segmenti kendi sisteminde hesaplar ve liste ya da topic olarak gönderir.
- **E-68 Kiracı kodu çalıştırılmaz.** Relay kiracının dönüştürme betiğini, çalışma anında müşteri sunucusuna çağrıyı (bridge) ya da veri çekme adımını çalıştırmaz. Dönüşüm alan beyaz listesi ve CloudEvents eşlemesiyle yapılır.
- **E-69 Edge çalışma ortamı kapsam dışıdır.** Relay edge çalışma ortamlarında (Cloudflare Workers benzeri) çalışmaz. CDN/WAF/DDoS ön katmanı isteğe bağlıdır ve bölgenin veri yerleşimi kurallarına uyar; regüle Türkiye kiracılarında TLS yurt dışında sonlandırılmaz.

### 7.11 Arıza sahipliği

| Arıza | Kim fark eder | Davranış | Sahibi |
|---|---|---|---|
| Access'e ulaşılamıyor | Relay | Gönderim sürer; izinler Relay'deki kopyadan okunur (E-18). Token exchange ile yeni abone jetonu alınamaz; Access jetonu yerine kabul edilmez (E-25). Step-up gerektiren yönetim işlemi yapılmaz (E-27) | Access (erişilebilirlik); Relay (görünür hata) |
| Access olayları gecikiyor | Relay | Kopyalar son bilinen durumda kalır. İYS kararları Relay'in kendi İYS kopyasıyla verilir (INV-19) | Access (olay teslimi) |
| Relay'e ulaşılamıyor ya da gecikiyor | Access, üretici | Hiçbir yetki ve güvenlik kararı Relay'e dayanmaz (E-6, E-14). Kabul edilmemiş istek üreticinin outbox'ında kalır ve aynı `dedup_key` ile yeniden gelir | Relay (teslim); semantik etkisi yok |
| Bekleyen taraf öldü (heartbeat kesildi) | Relay | Bekleme sahipsiz işaretlenir, `waitpoint.stalled` olayı gider, eskalasyon durur (INV-32) | Bekleyen taraf |
| Ajan tavanı sayacı okunamıyor | Relay | Ajan kaynaklı bildirimler bekletilir (INV-34) | Relay |
| Sağlayıcı arızası | Relay | Devre kesici, aktif-pasif ya da ağırlıklı sağlayıcı geçişi, kanal fallback'i (§12) | Relay (yönlendirme); sağlayıcı (arıza) |
| Müşteri uç noktası çalışmıyor | Relay | Retry takvimi, DLQ, replay; olay atılmaz (INV-3, INV-4) | Müşteri (uç); Relay (saklama) |
| İYS'ye ulaşılamıyor | Relay | Kapsamdaki ticari gönderim, kopya bayatlık eşiğini aşınca durur (INV-19); İYS'ye yazılamayan ret Relay'de anında uygulanır, İYS'ye yazım kuyrukta bekler | Relay (bağlantı); İYS (erişilebilirlik) |

### 7.12 Sınırlarda veri minimizasyonu

- **E-70 Gerekli olan kadarı geçer.** Access'ten Relay'e yalnız render ve teslim için gereken alanlar (içerik değişkenleri, adresleme ipuçları, `expires_at`, sınıf), izin olayının İYS alanları ve eşleme bilgisi geçer. Access kimlik bilgileri, sırlar ve yetki kayıtları Relay'e geçmez. Relay'den Access'e teslim durumu (bilgi olarak) ve denetim referansları geçer.
- **E-71 Ajan bağlamına giden.** Ajana yalnız yapılandırılmış mesaj gider; yanıt jetonu, bekleme kimliği bearer'ı ve başka alıcının verisi ajan bağlamına girmez (INV-33).
- **E-72 Gözlem verisi kişisel veri taşımaz.** İki ürün arasında taşınan trace bağlamı ve span'ler kişisel veri içermez; kiracı etiketi kardinalite kuralıyla kullanılır (§20).

### 7.13 Karar register'ı (E-1–E-74)

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| E-1 | Relay ve Access bağımsız çalışır, birlikte sürtünmesiz çalışır | MERKEZİ KARAR | Access E40 |
| E-2 | Dört çalışma biçimi | MERKEZİ KARAR | Access E40 (1)–(3) |
| E-3 | Birinci taraf ayrıcalığı yok; Suiss ürünleri herkese açık sözleşmeyi kullanır | FROZEN (ürün) | Access §7.9.16 (first-party neutrality) |
| E-4 | Tek bağlantı ayarı, ortak imza profili, CloudEvents, ortak kiracı eşlemesi; müşteri kodu değişmez | FROZEN (ürün) | Access E40 (4) |
| E-5 | Access gerektiren özellik bunu açıkça belirtir | FROZEN (ürün) | Access E40 (4); INV-56 |
| E-6 | Teslim ve ack yetki durumu değildir; Relay cevabı onay değildir | KANONİK DEĞİŞMEZ | Access E30, Access EI-9, Access EI-18 |
| E-7 | Relay asla listesi (Access tarafı) | KANONİK DEĞİŞMEZ | Access §7.9.8.4 |
| E-8 | Teslim ack, anlamsal ack ve yetki durumu ack ayrıdır | FROZEN (ürün) | Access §7.9.8.3 |
| E-9 | Access yalıtılmış platform kiracısı; ayrı itibar | FROZEN (ürün) | Access E40 (2) |
| E-10 | İçerik Access'in, teslim Relay'in | FROZEN (ürün) | Access E40 (2), §7.9.8.2 |
| E-11 | Access anlamsal olayları `security` sınıfı; digest/frekans/içerik dedup yok; idempotency var | FROZEN (ürün) | Güvenlik bildiriminin gecikmemesi ve birleştirilmemesi |
| E-12 | Alıcı kümesi üreticinindir; Relay yalnız kanal seçer | FROZEN (ürün) | Access §7.9.8.2 (eligible set) |
| E-13 | "Ne zamana kadar" → `expires_at`; `on_expire: drop \| inbox_only` | FROZEN (ürün) | — |
| E-14 | Revocation taşıması Relay ya da SSF/CAEP; güvenlik teslimata dayanmaz | KANONİK DEĞİŞMEZ | Access E13, Access INV-24 |
| E-15 | CIBA'da Access OP, Relay davet kanalı; onay Access onay yüzeyinde; ping istemci bildirimi Access'te kalır, Relay webhook'uyla taşınmaz | FROZEN (ürün) | OpenID CIBA Core; Access E32 |
| E-16 | Relay yanıt toplayıcıdır; onay türü öğede yalnız derin bağlantı; Access'siz basit karar kaydı etiketli | FROZEN (ürün) | Access E32, Access XI-8, Access A-5 |
| E-17 | Hukuki izin Access'te, bildirim tercihleri Relay'de | MERKEZİ KARAR | Access IDP-37 |
| E-18 | Relay izin kopyasını Access olaylarından tutar, gönderimde sormaz; Access'siz izni Relay tutar | FROZEN (ürün) | Gönderim yolunun Access erişilebilirliğine bağlanmaması |
| E-19 | Bağlıyken tek "Tercihlerim" ekranı | FROZEN (ürün) | Kullanıcıya tek tercih yüzeyi |
| E-20 | İYS entegrasyonu tamamen Relay'de; marka için tek yazıcı | MERKEZİ KARAR | Access B23; İYS çift yazıcı çakışması |
| E-21 | Access izin olayını İYS alanlarıyla yayınlar; Relay yoksa kiracı entegratörü; Access İYS'ye yazmaz | FROZEN (ürün) | Access B23, Access IDP-37 |
| E-22 | İYS bağlanma modları: kendi erişim ve yetkili entegratör; 250 bin adres altı entegratör desteği | FROZEN (ürün) | İYS doğrudan bağlantı eşiği ⚠️ (eşik değeri mevzuat değişikliğine karşı izlenir) |
| E-23 | Abone jetonu varsayılan yolu: Relay basar, kiracı backend'i ister | FROZEN (ürün) | Knock/Novu kullanıcı jetonu modeli |
| E-24 | Access'li kiracıda RFC 8693 token exchange; abone Access'in kiracıya özgü `sub`'ıyla eşlenir | FROZEN (ürün) | RFC 8693 |
| E-25 | Access jetonu inbox/tercih erişimi için kabul edilmez | FROZEN (ürün) | Jeton kapsamının daraltılması; audience ayrımı |
| E-26 | Operatör girişi OIDC, roller Relay'de; Access bağlıysa otomatik eşleme | FROZEN (ürün) | Access E40 (3)–(4) |
| E-27 | Hassas işlemlerde Access step-up/AuthZEN ya da IdP `max_age`/`acr`; alınamazsa işlem yok | FROZEN (ürün) | OpenID AuthZEN; OIDC `max_age`/`acr_values`; Access MD-8 |
| E-28 | Ajan kaydı Relay'de | FROZEN (ürün) | Teslim uçları ve posta kutusunun teslim sistemine ait olması |
| E-29 | Access bağı; Access jetonuyla kimlik kanıtı; askıya alma/silme olayıyla teslim durur | FROZEN (ürün) | Access EI-9; ajan kimliği yaşam döngüsünün tek sahibi |
| E-30 | Access'siz ajan: Relay API anahtarı ya da başka IdP jetonu | FROZEN (ürün) | Access E40 (3) |
| E-31 | Relay kendi Merkle kontrol noktalı denetim kaydı; Access modeli ve biçimi; kayıtlar referansla bağlanır | FROZEN (ürün) | Access §7.9.12.5; Access OP-74 |
| E-32 | OTP'de Access: kod, doğrulama, limitler, BDDK m.34/7, SIM değişikliği, alt tür ve AAL seçimi | MERKEZİ KARAR | BDDK Bilgi Sistemleri Yönetmeliği m.34/7; NIST SP 800-63B |
| E-33 | OTP'de Relay: hedef korumaları ve OTP şeridi | MERKEZİ KARAR | SMS pumping (yapay trafik) dolandırıcılığı |
| E-34 | Relay kod üretmez, saklamaz, doğrulamaz; yeniden gönderim yeni istek | KANONİK DEĞİŞMEZ | INV-22, INV-26 |
| E-35 | Access şablonları üretici sahipli; kiracı yalnız izinli marka alanlarını değiştirir; render Relay'in | FROZEN (ürün) | Access X35, Access X39 |
| E-36 | Ortak Suiss webhook profili; `v1a` Ed25519 varsayılan | FROZEN (ürün) | Access TN-136; Standard Webhooks |
| E-37 | Ortak olay biçimi CloudEvents; `traceparent` taşınır | FROZEN (ürün) | CloudEvents 1.0; W3C Trace Context |
| E-38 | Access kiracısı → Relay kiracısı, Access organizasyonu → Relay alt kiracısı; otomatik | FROZEN (ürün) | Access E40 (4) |
| E-39 | İki ürün aynı bölgede | FROZEN (ürün) | Veri yerleşimi; Access Ek C |
| E-40 | Tek bağlantı ayarı ve keşif; bağlantı kaldırılınca Access'siz biçime dönüş | FROZEN (ürün) | Access E40 (4) |
| E-41 | Work alıcıyı seçer, Relay teslim eder | FROZEN (ürün) | Access §7.9.8.2 |
| E-42 | İnsan iş/onay kuyruğu Work'ün; ajan posta kutusu Relay'in | FROZEN (ürün) | Access XI-7 |
| E-43 | Eskalasyon politikası, ajan tavanı kararı ve süre dolumu kararı Suiss'te Work'te; Relay uygular | FROZEN (ürün) | Relay'in yetki kaynağı olmaması |
| E-44 | Work'süz kurulumda aynı roller müşteri kodunda | FROZEN (ürün) | E-3 |
| E-45 | Bekleme noktası, korelasyon ve teslim Relay'in | MERKEZİ KARAR | Trigger.dev waitpoint, Knock `wait_for_event` |
| E-46 | Yürütme durumu bekleyenin; Relay yürütme motoru değil; saga yok | KAPSAM DIŞI | Access E31; dayanıklı yürütme motorlarının (Temporal benzeri) ayrı ürün sınıfı olması |
| E-47 | Bekleme noktası her bekleyene açık; heartbeat ≠ toplam süre | FROZEN (ürün) | Step Functions `HeartbeatSeconds` |
| E-48 | Uzun iş bitişi Standard Webhooks; tek doğrulayıcı | FROZEN (ürün) | OpenAI ve Anthropic arka plan işi bildirimlerinin Standard Webhooks kullanması |
| E-49 | Bekleme yanıtı onay değildir | KANONİK DEĞİŞMEZ | Access EI-18, Access E32 |
| E-50 | Desteklenen protokoller A2A, MCP, AG-UI | FROZEN (ürün) | A2A v1.0 (Linux Foundation); MCP |
| E-51 | A2A push alma/gönderme; retry/imza/DLQ/SSRF Relay'den; `(task, seq)` idempotent; `GetTask` uzlaştırma | FROZEN (ürün) | A2A'nın yalnız tek teslim denemesini garanti etmesi |
| E-52 | MCP sunucusu; Tasks `input_required` ↔ bekleme noktası; aynı kapsamlar ve kafes | FROZEN (ürün) | MCP Tasks uzantısı |
| E-53 | AG-UI olayları opak yük | FROZEN (ürün) | AG-UI olay modeli |
| E-54 | Protokoller onay kapısını atlayamaz; içerik yapılandırılmış mesaj kuralına tabi | KANONİK DEĞİŞMEZ | Access A-6, Access AG-33, Access EI-18 |
| E-55 | One bir ajan alıcı ve üreticidir; hafıza/plan Relay'e girmez | FROZEN (ürün) | Access §7.9.6 |
| E-56 | One bildirimleri ajan tavanı, tercih ve kafese tabi | FROZEN (ürün) | Gönderen türü `agent` kuralları |
| E-57 | One teslim içeriğinden yetki üretemez | KANONİK DEĞİŞMEZ | Access §7.9.6.3; INV-28 |
| E-58 | Pay bir üreticidir; finansal durum Pay'in | FROZEN (ürün) | Access §7.9.9 |
| E-59 | Teslim durumu ödeme kanıtı değildir; ödeme onayı Access onay yüzeyinde | FROZEN (ürün) | Access E32 |
| E-60 | Finansal tutarlar yapılandırılmış; kilit ekranı hassas veri kuralı | FROZEN (ürün) | ICU/CLDR para biçimlendirme; kilit ekranında veri sızıntısı |
| E-61 | Access'siz kurulumda standart OIDC; `max_age`/`acr` ile yeniden doğrulama | FROZEN (ürün) | OpenID Connect Core |
| E-62 | Dış IdP'li kiracıda abone jetonu varsayılan yolla; ajan API anahtarı ya da IdP jetonuyla | FROZEN (ürün) | E-23, E-30 |
| E-63 | Dış IdP kimlik iddiası yetki kaynağı değildir; roller Relay'de | FROZEN (ürün) | — |
| E-64 | Kendi MTA'sını SMTP ile bağlama; bounce işleme Relay'de; SaaS'ta MTA işletilmez | FROZEN (ürün) | MTA işletiminin itibar ve IP yönetimi yükü |
| E-65 | OLAP yok; analitik ve SIEM yalnız hedef | KAPSAM DIŞI | Postgres rollup'larının hazır raporlar için yeterliliği |
| E-66 | Müşteri veritabanı bağlayıcısı yok; Debezium/Sequin rehberi | KAPSAM DIŞI | CDC araçlarının olgunluğu; Relay'in müşteri veritabanına erişmemesi |
| E-67 | Segment motoru yok | KAPSAM DIŞI | Pazarlama otomasyonu ürün sınıfı |
| E-68 | Kiracı kodu, bridge ve veri çekme çalıştırılmaz | KAPSAM DIŞI | SSRF, deterministik tekrar oynatma |
| E-69 | Edge çalışma ortamı yok; ön katman isteğe bağlı ve veri yerleşimine uyar | KAPSAM DIŞI | Veri yerleşimi; TCMB/BDDK yurt içinde tutma |
| E-70 | Sınırda yalnız gerekli alanlar geçer | FROZEN (ürün) | KVKK veri minimizasyonu; Access §7.9.15 |
| E-71 | Ajan bağlamına yalnız yapılandırılmış mesaj | KANONİK DEĞİŞMEZ | INV-33 |
| E-72 | Trace ve span kişisel veri taşımaz | FROZEN (teknik) | OpenTelemetry semantik kuralları; KVKK |
| E-73 | `on_expire` varsayılanı `drop` | POLICY DEFAULT | Süresi geçmiş güvenlik uyarısının yanıltıcı olması |
| E-74 | Protokol sürümleri (A2A v1.0, MCP 2026-07-28) | WATCH | MCP'de Sampling/Roots/Logging kullanımdan kaldırma takvimi; A2A teslim semantiğinin gelişmesi |
