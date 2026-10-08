## 18. Kiracılık ve Güvenlik

**Bu bölümün kuralları.**
- Bu bölüm kiracı, alt kiracı, ortam ve bölge modelini; veri yalıtımını; operatör, API anahtarı ve abone kimliğini; sır ve anahtar yönetimini; kill switch'i; denetim kaydını; gürültülü komşu korumasını ve kriptografi kurallarını tanımlar.
- Kararlar TN-1–TN-62'dir. Statüler §3'teki sözlüğe uyar. Register §18.11'dedir.
- Veri modelinin genel kuralları, yazma yolları ve saklama §20'de; kuyruk, hız limiti ve şerit mekanizmaları §19'dadır. Bu bölüm yalnız bunların kiracılık ve güvenlik yüzünü bağlar.
- Access'e atıf "Access E40", "Access OP-74" biçimindedir.

---

### 18.1 Kiracı modeli

#### 18.1.1 Kiracı

**TN-1 — Relay'in kendi kiracı modeli vardır.** Kiracı, Relay'in en üst yalıtım birimidir. Verinin, sağlayıcı hesaplarının, API anahtarlarının, kotaların, kill switch kapsamlarının ve denetim kaydının sahibi kiracıdır. Relay Access olmadan tam çalışır: kiracılar, operatörler ve API anahtarları Relay'de tanımlanır. Access bağlıysa kiracılar otomatik eşlenir (TN-6, TN-20); model değişmez.

**TN-2 — Kiracı kurulumunda üç zorunlu alan vardır ve sistem varsayılanı yoktur.**

| Alan | Kural | Değişebilir mi |
|---|---|---|
| `region` | Kayıtta seçilir (TN-55); verinin yaşadığı bölgedir | Hayır. Bölge değişikliği yeni bölgede yeni kiracı + dışa/içe aktarmadır |
| `default_timezone` | IANA bölge kimliği; saat dilimi zincirinin son halkası (§10'daki saat dilimi kuralları) | Evet (denetim kaydıyla) |
| `default_locale` | BCP 47; yerel ayar zincirinin son halkası (§11'deki yerelleştirme kuralları) | Evet (denetim kaydıyla) |

Gerekçe: varsayılan saat dilimi ya da dil "sessiz yanlış davranış" üretir. Zorunlu alan, yanlışı kurulum anında görünür kılar.

**TN-10 — Kiracı ve gönderici askıya alma çekirdektedir.** Kiracı durumu `active | suspended | closed`'dır. `suspended` bütün giriş noktalarında aynı anda etkilidir: API, kampanya başlatma, gelen webhook, zamanlanmış gönderim, tekrar kuralı, realtime bağlantı. Askıya alınan kiracının açık realtime bağlantıları sunucudan kesilir; yeniden bağlanma yetkiyi baştan kontrol eder. Bekleyen işler silinmez; `PAUSED` durumuna alınır (TN-40 ile aynı mekanizma). Askıya alma ve kaldırma denetim kaydına girer (TN-46). Gönderici kimliği (e-posta alan adı, SMS başlığı) ayrıca askıya alınabilir. Hukuki süreç değerleri (bildirim süresi, itiraz penceresi) POLICY DEFAULT'tur ve hukuk onayıyla doldurulur.

#### 18.1.2 Alt kiracı

**TN-3 — Alt kiracı birinci sınıf, tek seviyeli bir nesnedir ve ücretsiz çekirdektedir.** Alt kiracı şunları tutar: marka (logo, renk, şablon varyantı), gönderici kimlikleri (e-posta alan adı, SMS başlığı), isteğe bağlı kendi sağlayıcı hesabı, tercih varsayılanları, kanal kimlikleri, inbox kapsamı. Alt kiracının alt kiracısı yoktur. Alt kiracı ayrı bir yalıtım birimi değildir: verisi kiracının `tenant_id`'si altında ve `subtenant_id` ile tutulur; kiracının operatörleri alt kiracıları görür.

**TN-4 — Miras kuralı: "yoksa üsttekini kullan, varsa ezme".** Alt kiracının tanımlamadığı her ayar için kiracınınki geçerlidir. Alt kiracıda tanımlı ayar kiracı değişikliğiyle ezilmez. Çözüm sırası tektir: alt kiracı → kiracı. Marka değişkenleri ve layout'lar da bu kuralla çözülür (§11'deki marka kuralları).

**TN-5 — Eşleşmeyen alt kiracıya giden teslim kaybolmaz.** İstek tanımsız ya da kiracıya ait olmayan bir alt kiracıyı gösterirse teslim gönderilmez, `skip: scope_mismatch` neden koduyla kaydedilir; panelde, webhook olayında ve metrikte görünür. Genel ilke: gönderilmeyen her bildirim bir neden koduyla kaydedilir; sessiz kayıp yoktur (§14'teki atlama neden sözlüğü).

**TN-6 — Access ile kiracı eşlemesi otomatiktir.** Access bağlıysa Access kiracısı Relay kiracısına, Access'in B2B organizasyonu Relay alt kiracısına eşlenir. Access'te organizasyon açılınca veya değişince Relay'deki karşılığı olay üzerinden oluşur ve güncellenir; Relay tarafında elle eşleme gerekmez. Eşleme bağlantı ayarıyla bir kez kurulur (Access E40 madde 4).

#### 18.1.3 Ortam

**TN-7 — Her kiracının `live` ve `test` olmak üzere iki ayrı veri düzlemi vardır; işleme hattı aynıdır.** Ortam API anahtarında taşınır; istek gövdesinde ortam alanı yoktur. Test anahtarı canlı veriye erişemez, canlı anahtar test verisine erişemez; ortam, her tabloda `tenant_id` ile birlikte kapsam sütunudur (TN-12). Doğrulama, idempotency, tercih, İYS, rota, şablon, kill switch ve kota hattın tamamı aynı kodla çalışır. Yalnız son adımda `test` düzleminde sahte sağlayıcı adaptörü çalışır ve belirli adreslere belirli sonuçlar üretir (bounce, teslim edilmedi, gecikmeli teslim vb.; ayrıntı §8'deki test ortamı).

**TN-8 — Sanal saat yalnız `test` düzleminde vardır; güvenliği zayıflatan bayrak yoktur.** Zamanı ileri sarma (eskalasyon, bekleme, digest testleri için) yalnız test düzleminde açılır; canlı düzlemde saat her zaman gerçek saattir. "Geliştirme modu", imza doğrulamasını kapatma, RLS'i kapatma gibi bayraklar yoktur (Access OP-69 ile aynı yön). Geliştirme makinesinde yerel eşdeğerler kullanılır (§19.10).

#### 18.1.4 Platform kiracısı

**TN-9 — Access, Relay'de yalıtılmış bir platform kiracısıdır.** Access'in insana giden mesajları Relay'den gittiğinde Access kendi kiracısıdır: kendi gönderen alan adı, kendi gönderici kimlikleri ve diğer kiracılardan ayrı izlenen itibar. Platform kiracısı veri yalıtımında ayrıcalık taşımaz; diğer kiracılarla aynı kurallara tabidir. Mesaj içeriği ve "kime, neden" Access'indir; kanal, zamanlama, retry, fallback ve teslim durumu Relay'indir (Access E40 madde 2). Aynı kural, Relay'e bağlanan diğer üretici ürünler için de geçerlidir.

---

### 18.2 Veri yalıtımı

**TN-11 — Yalıtım modeli "pool"dur.** Tek şema, her satırda kiracı ayırıcı sütun, ikinci savunma hattı olarak RLS. Kiracı başına şema ve kiracı başına veritabanı kullanılmaz. Gerekçe: şema başına kiracı modelinde katalog, yedekleme ve göç maliyeti kiracı sayısıyla doğrusal büyür ve iş kuyruğu tek örnekte kalamaz; pool modelinin zaafları aşağıdaki katmanlarla kapatılır. Ayrı altyapı isteyen kurum, aynı paketin ayrı kurulumunu (self-host ya da ayrı bölge kurulumu) kullanır; kod ve şema aynıdır.

**TN-12 — Kapsam sütunları, bileşik benzersizlik ve bileşik FK zorunludur.**
1. Her kiracı tablosunda `tenant_id NOT NULL` ve `environment NOT NULL` bulunur. Kapsam sütunları birincil anahtarın önekidir.
2. Her benzersizlik kısıtı kapsam sütunlarıyla bileşiktir (ör. `UNIQUE (tenant_id, environment, device_token_bidx)`). Kiracılar arası global UNIQUE yoktur. Gerekçe: global UNIQUE, RLS'i atlayan referans bütünlüğü üzerinden kiracılar arası yan kanal açar.
3. Referans verilen her tabloda `UNIQUE (tenant_id, environment, id)` bulunur; her FK `(tenant_id, environment, x_id) → parent(tenant_id, environment, id)` biçimindedir. Böylece kiracı A'nın kaydı kiracı B'nin kaydına yapısal olarak bağlanamaz. FK kontrolleri RLS'i atladığı için aynı kiracı garantisini RLS değil bileşik FK verir.
4. FK'nin bilerek kurulmadığı tablo (yazma maliyeti ölçümle gerekçelendirilmiş) şema güvenlik testlerinde açıkça listelenir ve gecelik yetim kayıt denetimine girer (§20.7).

**TN-13 — RLS her tabloda açık ve FORCE'tur; kiracı bağlamı yalnız transaction'a yereldir.**
1. Her kiracı tablosunda `ENABLE` ve `FORCE ROW LEVEL SECURITY` vardır. Politika `USING` ve `WITH CHECK` içerir; bağlam okuması `(select current_setting('relay.tenant_id'))` biçiminde sarılır (sorgu başına bir kez değerlendirilir).
2. Bağlam yalnız transaction içinde `set_config('relay.tenant_id', $1, true)` ile kurulur. Oturum düzeyinde `SET` ve bağlantı açılışında bağlam kurma yasaktır (havuzlu bağlantıda sonraki isteğe sızar).
3. `current_setting(…, missing_ok => true)` kullanılmaz. Bağlamsız sorgu boş sonuç değil hata üretir.
4. Veri erişim katmanı kiracı bağlamı olmadan sorgu çalıştırmaz; çalıştırmaya kalkışan kod yolu hatayla durur. Kiracılar arası iş yapan bakım görevleri (partition bakımı, arşiv) ayrı rolle ve gerekçesi kodda yazılı, grep'lenebilir bir kaçış kapısıyla çalışır.
5. Kiracı bağlamı her iş, süreç ve görev sınırında yeniden kurulur; çağıran süreçten devralındığı varsayılmaz.
6. Uygulama katmanı birincil, RLS ikincil savunmadır. RLS tek başına yeterli sayılmaz: yanlış rol RLS'i sessizce kapatır, bağlam kurmayı unutan arka plan işi boş sonuç alır. RLS yine de kurulur; unutulan filtre veri sızıntısını "boş liste hatasına" indirir.

**TN-14 — Uygulama veritabanına yanlış rolle bağlanmayı reddeder.** Açılışta şunlar doğrulanır: rol superuser değildir, `BYPASSRLS` taşımaz, hiçbir tablonun sahibi değildir, `DELETE`/`TRUNCATE` yetkisi yoktur. Biri tutmazsa düğüm başlamaz. Rol tablosu ve yazma yolları §20.2'dedir.

**TN-15 — Kiracılar arası erişim 404 döner.** Başka kiracıya ait bir kaynağa erişim 403 değil 404'tür; kaynağın varlığı sızdırılmaz. Aynı kural ortamlar arası erişimde de geçerlidir.

**TN-16 — Yalıtım altı sızıntı testi ve bir imha kapsamı testiyle korunur.**

| # | Test | Ne zaman |
|---|---|---|
| 1 | API uç listesinden otomatik üretilen negatif testler: A kiracısının anahtarıyla B'nin her kaynağına istek → 404 | Her PR |
| 2 | Özellik tabanlı test: kiracı A'nın hiçbir sorgusu B'nin `tenant_id`'sini taşıyan satır döndürmez | Her PR |
| 3 | Test ortamında veri erişim çıktısı denetimi: dönen her satırın kapsamı bağlamla eşleşir | Her PR |
| 4 | RLS açıklık testi: `relrowsecurity` ya da `relforcerowsecurity` false olan kiracı tablosu yoktur | Her PR |
| 5 | Uygulama rolü açılış doğrulaması (TN-14) | Her açılış |
| 6 | Üretimde periyodik denetim: `tenant_id IS NULL` satır yok, yetim satır yok, bileşik FK yerinde | Gecelik |
| 7 | İmha kapsamı testi: `tenant_id` sütunu ya da kişisel alan taşıyan her tablo, kiracı kapatma ve özne silme kapsam listesinde yer alır; yer almıyorsa test kırılır (§20.4) | Her PR |

**TN-17 — Valkey anahtarları, önbellekler ve süreç adları kiracı kapsamlıdır; kiracı verisinden sembol üretilmez.** Valkey'deki her anahtar kiracı ve ortam önekini taşır. Düğüm içi önbellekler kiracı + ortam anahtarlıdır. Kiracı kimliğinden atom üretilmez, süreç adı kaydedilmez (atom tablosu sınırsız büyümez; §19.9).

**TN-18 — Kiracı verisi kiracılar arası kullanılmaz.** SaaS'ta Relay kiracı verisinin işleyenidir. Bir kiracının verisi başka kiracı için analitik, model eğitimi ya da ürün geliştirme amacıyla kullanılmaz. Platform düzeyindeki işletim metrikleri kişisel veri ve içerik taşımaz (§20.6 kardinalite kuralı).

---

### 18.3 Kimlik: operatör, kurulum operatörü, API anahtarı, abone, ajan

#### 18.3.1 Operatör

**TN-19 — Konsola giriş herhangi bir OIDC IdP ile yapılır; roller ve yetkiler Relay'de tutulur.** Access önerilen IdP'dir ama zorunlu değildir. Relay'in yerleşik kullanıcı/parola deposu yalnız ilk kurulum yöneticisi içindir ve IdP bağlanınca devre dışı bırakılabilir. Rol tabanlı yetki (RBAC) Relay'dedir ve self-host'ta da tam olarak bulunur.

**TN-20 — Access bağlıyken operatörler Access'ten gelir.** Kullanıcı yaşam döngüsü (açma, askıya alma, silme) Access olaylarıyla Relay'e yansır; Relay'de askıya alınan Access kullanıcısının oturumları ve API anahtarları geçersizleşir. Roller Relay'de kalır.

**TN-21 — Hassas işlemler yeniden doğrulama (step-up) ister.**

| Hassas işlem | Ek kural |
|---|---|
| Kill switch'i yeniden açma, gevşetme, `security` sınıfını durdurma | TN-41, TN-42 |
| Sağlayıcı sırrı veya anahtar rotasyonu, sağlayıcı hesabı ekleme/silme | TN-26 |
| Alıcı PII'sini açık gösterme | Her gösterim ayrı denetim kaydı (`pii.revealed`) |
| İYS bağlantı ayarları | §13'teki İYS kuralları |
| Ajan tavanı aşan bekletilmiş bildirimleri serbest bırakma | §17'deki ajan tavanı kuralları |
| Saklama, dava saklaması, okunabilir çıkarma, dışa aktarma | Okunabilir çıkarma iki kişilik onay (Access OP-74 madde 5) |
| `critical` öncelik açılımını onaylama | TN-23 |
| Kiracı askıya alma/kaldırma, takedown | TN-10, TN-60 |
| Rol ve yetki değişikliği, API anahtarı oluşturma | — |

Access bağlıysa step-up Access'ten istenir; gerekirse Access karar API'sine (AuthZEN) sorulur. Access yoksa bağlı IdP'den yeniden doğrulama `max_age` ve `acr` parametreleriyle istenir. Step-up sonucu denetim kaydına işlemle birlikte yazılır.

**TN-22 — Gevşetme, sıkılaştırmadan daha yüksek yetki ister.** Durdurma, kısma, askıya alma ve kota düşürme düşük yetkiyle anında yapılabilir; yeniden açma, gevşetme ve kota artırma daha yüksek yetki ve step-up ister. Gerekçe: durdurmada tereddüt zararı büyütür; açmada acele zararı tekrarlatır.

#### 18.3.2 Kurulum operatörü

**TN-23 — Kurulum operatörü, kiracıların üstündeki tek roldür ve kod iki dağıtımda aynıdır.** SaaS'ta kurulum operatörü Relay'i işleten taraftır; self-host'ta kurumun kendi Relay yöneticisidir. Kurulum operatörü şunları yapar: platform düzeyi kill switch, kiracı askıya alma, `critical` öncelik açılımının kiracı başına onayı (kiracı platform izninin kanıtını sunar, kritik şablonlar baştan beyan edilir, her kullanım denetim kaydına girer; ayrıntı §12'deki öncelik kuralları), paylaşılan sağlayıcı hesaplarının yönetimi. Kurulum operatörü kiracı verisini RLS'i atlayarak okuyamaz; destek amaçlı erişim kiracı adına, süreli ve denetimli bir yetki devriyle yapılır.

#### 18.3.3 API anahtarı

**TN-24 — API anahtarı ortamı ve kapsamı taşır; düz metin saklanmaz.**
1. Anahtar tek bir kiracı, tek bir ortam (`live`/`test`) ve isteğe bağlı olarak tek bir alt kiracıya bağlıdır. Önek ortamı gösterir (önek tablosu §9'daki adlandırma kurallarında).
2. Yayın (gönderim, tetikleme) ve okuma (durum, log, rapor) kapsamları ayrı anahtarlardır. Okuma anahtarı gönderim yapamaz.
3. Anahtar yalnız oluşturulduğu anda bir kez gösterilir; sunucuda anahtarlı özeti saklanır. Kaybolan anahtar geri getirilmez, yenisi oluşturulur.
4. Rotasyon çakışmalıdır: yeni anahtar oluşturulur, eski anahtar tanımlı bir süre (POLICY DEFAULT) birlikte geçerli kalır, sonra iptal edilir.
5. Kill switch kapsamlarından biri API anahtarıdır (TN-36). Sızan anahtar anında iptal edilebilir; iptal tüm düğümlere kill switch ile aynı yayılım yolundan gider.

#### 18.3.4 Abone ve ajan kimliği

**TN-25 — Abone jetonu ve ajan kimliği bu bölümün yalıtım kurallarına bağlanır.** Abone jetonu kısa ömürlüdür, dar kapsamlıdır (`inbox:read`, `inbox:write`, `preferences`, `devices:write`) ve yalnız o abonenin inbox'ına, tercihlerine ve kendi cihaz kaydına dokunur; Access'li kiracılarda RFC 8693 token exchange ile Access jetonundan üretilir, Access jetonu doğrudan inbox erişimi için kabul edilmez (ayrıntı §15). Ajan kaydı Relay'dedir, Access bağlıysa Access ajan kimliğine bağlanır (ayrıntı §17). Her iki jeton da kiracı ve ortam kapsamını taşır; kiracı kimliği istemcinin görebileceği alana yazılmaz.

---

### 18.4 Sır ve anahtar yönetimi

#### 18.4.1 Sır deposu

**TN-26 — Sır arka ucu bir port'tur; veritabanında yalnız referans durur.**
1. Desteklenen arka uçlar: bulut KMS, OpenBao, SoftHSM (yerel eşdeğer), yerel `age` dosyası (küçük self-host). Arka uç seçimi kurulum yapılandırmasıdır; ürün davranışı aynıdır.
2. Veritabanında sağlayıcı kimlik bilgisi, webhook imza sırrı ve benzeri değerler için yalnız referans + sürüm tutulur (`secret_ref`). Düz sır veritabanına, iş argümanına, log'a ve trace'e yazılmaz.
3. Çözülmüş sır paylaşılan bellek yapılarında (ETS, `persistent_term`) tutulmaz; yalnız onu kullanan sürecin içinde ve kısa süre tutulur (§19.9 sır hijyeni).
4. Self-host yapılandırmasında sağlayıcı bağlantıları dosya ya da ortam değişkeniyle verilir. Sırlar yalnız referansla geçer (`${VAR}` ya da sır referansı); bağlantı URI'sine düz sır yazılmaz; yapılandırma yükleyicisi URI içinde parola gördüğünde başlamayı reddeder.
5. Sır rotasyonu step-up ister (TN-21), denetim kaydına girer ve süreç yeniden başlatılmadan uygulanır (sıcak değişim).

**TN-27 — Kiracı sırları zarf şifrelemeyle korunur.** Her bölgenin kendi KMS/HSM'i vardır (TN-55). Bölge anahtarı (KEK) kiracı başına veri anahtarlarını sarar; sırlar kiracı veri anahtarıyla şifrelenir. Çözülmüş veri anahtarı süreli bellek önbelleğinde tutulur (POLICY DEFAULT 5–15 dk); KMS çağrısı mesaj başına değil sır başına ve önbellek süresinde birdir. Kiracı başına ayrı KMS anahtarı (kendi anahtarını getir) bir seçenektir; özellik olarak self-host'ta da vardır.

#### 18.4.2 Sağlayıcı imza anahtarları

**TN-28 — Uzun ömürlü sağlayıcı imza anahtarları uygulama belleğine girmez; imza KMS/HSM'de atılır.** APNs `.p8` anahtarı, VAPID kimlik anahtarı ve FCM servis hesabı anahtarı (kullanılıyorsa) KMS/HSM'e içe aktarılır; JWT/assertion imzası orada atılır. Gerekçe: BEAM sırları bellekten güvenle silemez; imza sıklığı düşük olduğu için (anahtar başına saatte birkaç imza) KMS gecikmesi ve maliyeti görünmezdir. KMS'in döndürdüğü DER ECDSA imzası JWS'in sabit 64 baytlık `R‖S` biçimine çevrilir; dönüştürücü kısa-R ve kısa-S test vektörleriyle doğrulanır (yanlış dolgu yaklaşık her 256 imzada bir aralıklı reddedilme üretir).

**TN-29 — APNs JWT 20–60 dakika aralığında yenilenir; hedef yaklaşık 40 dakikadır.** Son geçerli JWT önbellekte tutulur; aynı bağlantıda 20 dakikadan sık yeni JWT kullanılmaz. KMS kesintisinde son JWT'nin ömrü kadar pist vardır; kesinti başlar başlamaz alarm üretilir. `.p8` anahtarının mühürlü, çevrimdışı bir felaket kopyası tutulur (içe aktarılmış anahtar materyali KMS'te süresi dolunca yeniden aynı materyalle içe aktarılmak zorundadır). Kimlik bilgisi sıcak değişir: yeni anahtar yüklenir, ilgili HTTP/2 bağlantıları kapatılıp yeniden kurulur, süreç yeniden başlamaz. Rotasyon iki takım anahtarıyla sıfır kesintilidir: yeni anahtar üret → yan yana yükle → geçiş → teslimi doğrula → eskiyi iptal et.

**TN-30 — FCM kimliği için iş yükü kimliği federasyonu tercih edilir.** Servis hesabı anahtarı yerine Workload Identity Federation kullanılır. Federasyon kurulamıyorsa servis hesabının RSA anahtarı KMS'te tutulur ve RS256 assertion orada imzalanır. OAuth erişim jetonu proje başına ömrü boyunca (yaklaşık bir saat) önbellekte tutulur.

**TN-31 — VAPID kimlik anahtarı kanal kimliği (uygulama) başınadır ve KMS'tedir; mesaj şifreleme anahtarı efemeraldir; rotasyon çift anahtarla yapılır.** Bir kiracının ya da alt kiracının birden çok web uygulaması ayrı VAPID anahtarı taşır (C-26); kiracı başına ya da kurulum başına paylaşılan anahtar yoktur, böylece rotasyonun etkisi tek uygulamayla sınırlı kalır. RFC 8291 mesaj anahtarı her mesajda bellekte taze üretilir ve uzun vadeli değeri yoktur; mesaj başına KMS ECDH kullanılmaz (hacimde KMS kotasını aşar). VAPID JWT'si push servisi başına 24 saate kadar önbellekte tutulur. VAPID anahtarı değişirse mevcut bütün Web Push abonelikleri geçersizleşir; bu yüzden rotasyon çift anahtarla yapılır: eski anahtar mevcut aboneliklere hizmet etmeye devam eder, yeni abonelikler yeni anahtarı alır, istemciler zamanla yeniden abone olur.

**TN-32 — Webhook imzası Suiss webhook profiline uyar.** Varsayılan imza `v1a` Ed25519'dur; `v1` HMAC yalnız uyumluluk içindir. Anahtar rotasyonu çakışmalıdır: geçiş süresince iki imza birlikte gönderilir. Profil Access ile ortaktır (Access TN-136); ayrıntı §16'dadır. Yüksek hacimli webhook imza anahtarları kiracı veri anahtarıyla şifreli saklanır ve yalnız imzalayan süreçte çözülür; TN-28'deki KMS imza kuralı düşük hacimli, yüksek değerli anahtarlar içindir.

#### 18.4.3 Veri şifreleme

**TN-33 — Kişisel alanlar özne × saklama sınıfı başına anahtarla şifrelenir; arama anahtarlı kör indeksle yapılır.**
1. Alıcı adresleri, profil alanları, bildirim içeriği ve diğer kişisel alanlar özne × saklama sınıfı başına DEK ile AES-256-GCM sınıfında şifrelenir. Silme talebinde ilgili DEK imha edilir (crypto-shredding; §20.4, Access OP-74).
2. Push token'ları ve adresler düz metin saklanmaz. Eşitlik araması (ör. sağlayıcı "geçersiz token" yanıtında satırı bulmak, bastırma kontrolü) HMAC tabanlı kör indeksle yapılır; HMAC anahtarı veritabanı dışında, sır deposundadır. Anahtarsız özet kör indeks sayılmaz.
3. Kör indeks anahtarı seyrek döner; rotasyon için iki sütunlu okuma yolu baştan tasarlanır.
4. Disk şifrelemesi tek başına kontrol sayılmaz. Veritabanı içi şifreleme fonksiyonları (anahtarın SQL metnine ve log'a düştüğü yollar) kullanılmaz.

**TN-34 — HSM politikası: varsayılan bulut KMS'tir; tek kiracılı HSM yalnız denetim şartıysa.** Bulut KMS anahtarları doğrulanmış HSM'lerde tutulur ve özel anahtar düz metin dışarı çıkmaz. Tek kiracılı HSM, içe aktarma yolunu kısıtlayabildiği ve işletim yükü getirdiği için yalnız denetçi ya da regülasyon açıkça istediğinde kurulur. Port soyutlaması (TN-26) bu geçişi kod değişmeden mümkün kılar.

---

### 18.5 Kill switch

#### 18.5.1 Model

**TN-36 — Kill switch tek modeldir ve beş boyutlu anahtar taşır.**

| Boyut | Değerler |
|---|---|
| Kapsam | `platform`, `tenant`, `subtenant`, `campaign`, `workflow`, `api_key`, `sender` (gönderici kimliği) |
| Kanal | bütün kanallar ya da tek kanal |
| Hedef | bütün hedefler, sağlayıcı (sağlayıcı hesabı), şablon |
| Mesaj sınıfı | bütün sınıflar ya da tek sınıf (§13'teki yedi mesaj sınıfı) |
| Durum | `on`, `off`, `canary` (yüzde), `paused_until` (zaman) |

Her kayıt `reason`, `created_by`, `expires_at` (TTL) ve isteğe bağlı bilet bağlantısı taşır. Kill switch kendi özelliğidir: sağlayıcı devre kesicisi (§19.6), itibar devresi (§12) ve ajan tavanı (§17) ayrı mekanizmalardır ama hepsi aynı `PAUSED` ve `rule_id` sonuç dilini kullanır. Hangi kapsamda olursa olsun engellenen iş duraklatılır, iptal edilmez; iptal ayrı operatör eylemidir (TN-40).

**TN-37 — Öncelik: en kısıtlayıcı kayıt kazanır.** Platform `off` iken kiracı `on` olamaz. `canary` ile `paused_until` çakışırsa duraklatma kazanır. Değerlendirme saf bir fonksiyondur ve kendi test tablosuyla doğrulanır.

**TN-38 — Kill switch fail-safe'tir.** Durum okunamıyorsa son bilinen durum uygulanır. Düğüm açılışında durum hiç okunamıyorsa (veritabanına ulaşılamıyor ve yerel durum yok) o düğüm gönderim yapmaz. Kesinti hiçbir durumda bir kill switch'i kendiliğinden açmaz.

**TN-39 — Doğruluk Postgres'te, yayılım Valkey sinyaliyle, okuma düğüm içi önbellekten yapılır.** Kill switch kayıtları Postgres'te tutulur (doğruluk ve denetim). Değişiklik Valkey pub/sub ile "yeniden yükle" sinyali olarak yayılır; her düğüm tam seti okur ve tek bir değişmez yapı olarak sabit zamanlı okuma önbelleğine koyar. Valkey'e ulaşılamıyorsa düğümler kısa aralıklı yoklamaya geçer. Küme genelinde yayılım hedefi < 2 sn'dir (ENGINEERING ASSUMPTION; oyun gününde ölçülür).

#### 18.5.2 Durdurma davranışı

**TN-40 — Üç durdurma noktası vardır; engellenen iş hata olarak yeniden denenmez, bekletilir.**
1. **Kabul:** istek kabul edilir; eşleşen kill switch varsa teslim işi açılmaz, karar `rule_id` ile kaydedilir (karar ≠ hata; §9'daki yanıt kuralları). Platform düzeyi tam durdurmada API ayrıca `503` + `Retry-After` dönebilir.
2. **Kuyruk:** eşleşen kuyruklar duraklatılır; bekleyen işler `PAUSED` durumuna alınır.
3. **Uçuşta:** her teslim işinin ilk adımı kill switch kontrolüdür. Engellenen iş hata döndürmez (aksi hâlde retry olur ve switch kalkınca kendiliğinden gider); `PAUSED` olur.

Varsayılan davranış duraklatmadır; iptal ayrı bir eylemdir. `PAUSED` iş silinmez, hata sayılmaz ve otomatik olarak yeniden denenmez. Yeniden açma (resume) açık bir operatör eylemidir; switch'in TTL ile kalkması `PAUSED` işleri kendiliğinden göndermez. Resume'da her mesaj politika kafesinden (tercih, İYS, sessiz saat, frekans, kota) baştan geçer. Duraklatma sırasında `expires_at`'i dolan mesaj gönderilmez, `expired` (süresi doldu) olarak kapanır. Operatör `PAUSED` kümeyi topluca iptal edebilir; toplu iptal açık ve denetim kayıtlı bir eylemdir (TN-47) ve her mesaj için `cancelled` + `rule_id` kaydı üretir. Her engelleme bir `rule_id` atlaması üretir; panelde, webhook olayında ve metrikte görünür.

**TN-41 — Her kill switch kaydında TTL ve gerekçe zorunludur.** `reason` boş olamaz (uygulama ve veritabanı kısıtı). TTL zorunludur; süresiz kayıt ayrı ve açık onay ister. Açma ve gevşetme, kapamadan daha yüksek yetki ve step-up ister (TN-22). Kapsama göre yetki: kampanya ve workflow → kiracı operatörü; kiracı × kanal → kiracı yöneticisi; platform → kurulum operatörü. Her değişiklik (iki yön) denetim kaydına girer ve işletim kanalına bildirilir. Aktif kill switch'ler panelde her zaman görünür.

**TN-42 — `security` sınıfı varsayılan olarak durdurulmaz.** Kapsamı "bütün sınıflar" olan bir kill switch bile `security` sınıfını içermez. `security` sınıfını durdurmak ayrı, açık bir seçim ve ayrı onay ister. Gerekçe: OTP'yi yanlışlıkla durdurmak bütün kullanıcıları sisteme giremez hâle getirir. Access'in güvenlik olayları böyle açık bir seçimle durdurulursa bu, alıcı kümesinin daraltılması değildir (MD-2): her engellenen teslim `rule_id` ile kaydedilir ve teslim durumu Access'e bilgi olayı olarak döner (§7).

**TN-43 — Ölü adam anahtarı: anormal hacim otomatik duraklatır.** Kiracı, kampanya ya da workflow kapsamında gönderim hızı tanımlı bir eşiği aşarsa (POLICY DEFAULT: kapsamın son 1 saatlik ortalamasının 10 katı) ilgili kapsam otomatik olarak `paused_until` durumuna alınır ve kiracı ile işletim kanalı uyarılır. Otomatik duraklatma `security` sınıfına uygulanmaz. Yeniden açma insan kararıdır (TN-41). Gerekçe: kimsenin izlemediği saatte oluşan toplu yanlış gönderimi yakalayan tek mekanizma budur.

**TN-44 — Yürürlüğe girme gecikmesi ölçülür ve gösterilir.** "Durdur" ile son mesajın çıkışı arasındaki süre bir SLO'dur ve arayüzde gösterilir (ör. "son 90 saniyede kuyruktaki 412 iş duraklatıldı").

**TN-45 — Kill switch'e üç bağımsız erişim yolu vardır.** Panel/operatör API'si, CLI ve belgelenmiş acil durum prosedürü (doğrudan veritabanı kaydı + yeniden yükleme sinyali). Üçü de aynı kaydı yazar ve aynı denetim kaydını üretir. Kill switch oyun günlerinde düzenli olarak çekilir (§20.8).

---

### 18.6 Denetim kaydı

**TN-46 — Relay kendi kurcalanmaya dayanıklı denetim kaydını tutar; bütünlük modeli ve biçimi Access'inkiyle aynıdır.** Kayıt düz append-only tablodur; kayıt başına hash zinciri yoktur. Ayrı bir arka plan işi yeni kayıtları periyodik olarak Merkle ağacına bağlar ve imzalı bir kontrol noktası üretir; ekleme yolu imza beklemez. Kontrol noktası dışarı yayımlanır (nesne kilitli depo, SIEM, isteğe bağlı müşteri hedefi); yayımlanmayan bütünlük iddiası boştur. Kontrol noktası aralığı dışarıya beyan edilen bir parametredir (OP-63). Tek bir kaydın varlığı, diğer kayıtlar açılmadan Merkle kapsama kanıtıyla kanıtlanabilir. Kayıt kodlaması, alan adları, kontrol noktası biçimi ve özet alanı ayrımı Access denetim kaydıyla aynıdır (Access OP-37, Access OP-38); müşteri iki ürünün kaydını tek doğrulayıcıyla doğrular. Yayımlanmış kontrol noktasından önceki değişiklik tespit edilir; henüz kontrol noktasına girmemiş penceredeki veritabanı düzeyi değişiklik tespit edilmeyebilir (Access'teki sınırla aynı).

**TN-47 — Kapsam: insan ve yönetici eylemleri.** Teslim defteri "sisteme ne oldu"yu, denetim kaydı "insanlar ne yaptı"yı tutar; ikisi ayrıdır.

| Olay ailesi | Örnekler |
|---|---|
| Kill switch | `killswitch.engaged`, `killswitch.released`, `killswitch.auto_paused` (kapsam, hedef, gerekçe, TTL) |
| Sır ve anahtar | sağlayıcı sırrı/anahtar rotasyonu, KMS anahtarı değişikliği, webhook imza anahtarı rotasyonu |
| PII | `pii.revealed` (operatör, abone, alan) |
| İYS ve uyum | İYS bağlantı ayarları, uyum politikası sıkılaştırması, gönderici kimliği onayı |
| Ajan | tavanı aşan bekletilmiş bildirimlerin serbest bırakılması / iptali, ajan durdurma |
| Saklama ve veri | dava saklaması başlatma/kaldırma, okunabilir çıkarma, dışa aktarma, kiracı kapatma, takedown |
| Yayın ve kampanya | şablon/workflow yayını ve geri dönüş, kampanya başlatma/durdurma (kitle tanımı, tahmini boyut) |
| Kimlik ve yetki | rol değişikliği, API anahtarı oluşturma/iptal, step-up sonucu, destek erişimi devri |
| Öncelik | `critical` açılımının onayı ve her kullanımı; kiracı başına yüksek öncelikli gönderim oranı eşiğinin aşılması |
| Kiracı | askıya alma/kaldırma, kiracı ayarlarının değişmesi (özellikle tercih varsayılanları), bölge dışı veri gönderen sağlayıcının etkinleştirilmesi |

**TN-48 — Access bağlıysa kayıtlar bağlanır.** Her denetim kaydı eylemi yapanın Access kimliğini ve ilgili Access kayıt numarasını (step-up, karar, oturum) taşır. Access yoksa eylemi yapanın IdP kimliği (`iss` + `sub`) taşınır.

**TN-49 — Denetim kaydı SIEM'e aktarılır; saklama Access Ek C'ye göredir.** Kayıtlar sürekli akış ya da toplu dosya olarak SIEM'e aktarılabilir. Genel varsayılan saklama 400 gündür; sektör şablonları uzatır (Access OP-74, Access Ek C). Fiziksel silme yoktur (Access OP-73).

**TN-50 — Denetim kaydına yazma ve erişim kısıtlıdır.** Uygulama rolü denetim tablosuna yalnız yazma fonksiyonu üzerinden ekleme yapar; `UPDATE`/`DELETE`/`TRUNCATE` yetkisi yoktur. Denetim kaydını okumak da bir denetim olayıdır (sorgu başına bir kayıt). Operatör kimliği ("kimin adına") her kayıtta zorunludur.

---

### 18.7 Gürültülü komşu ve kota

**TN-51 — Kuyruk topolojisi şerit × kanaldır; kiracı başına kuyruk yoktur.** Kuyruk sayısı mesaj sınıfından türeyen şerit ile kanal çarpımıdır (§19.7). Kiracı başına kuyruk reddedilir: binlerce kiracıda binlerce üretici ve yoklama sorgusu üretir, statik yapılandırmayı imkânsız kılar. Kiracı adaleti kuyruğun içinde, kendi DRR bileşenimizle sağlanır (§19.6).

**TN-52 — Kota senkron reddedilir, hız limiti asenkron yavaşlatır.** Günlük/aylık gönderim kotası aşılırsa istek girişte `429 quota_exhausted` ile reddedilir; bu hata `retryable` değildir ve hangi kotanın aşıldığını söyler. Hız limiti ise işi reddetmez; kuyrukta yavaşlatır (iş kaybolmaz). API istek hızı aşımı `429` + `Retry-After`'dır ve `retryable`'dır. `security` sınıfı ve toplu gönderim ayrı kota kovalarındadır; toplu gönderim `security` kovasını tüketemez. Kova sınırları kiracı yapılandırmasının verisidir.
1. **`security` için sınırlı ek pay.** Kota tükendiğinde `security` sınıfı için kotanın üstünde sınırlı bir ek pay açılır; oran kiracı ayarıdır (POLICY DEFAULT: kotanın %10'u). Ek pay açıldığı anda kiracı ve kurulum operatörü uyarılır. Ek pay da tükenirse `security` de `429 quota_exhausted` ile reddedilir. Diğer sınıflara ek pay yoktur.
2. **Önce hedef korumaları.** SMS pumping tespiti ve hedef korumaları (numara/blok hız sınırı, ülke izin listesi; §13.10) ek paydan önce uygulanır; ek pay bu korumaları atlatmaz.
3. **Sınıf başına kota payı.** Kiracı sınıf başına kota payı tanımlayabilir (ör. `marketing` kotanın en fazla %80'i); payını dolduran sınıf, toplam kota dolmasa da aynı hatayla reddedilir.

**TN-53 — Paylaşılan sağlayıcı hesabında kiracılar adil pay alır; formül tektir.** Paylaşılan hesapta (SaaS'ın hazır sağlayıcı hesapları; FCM proje kotası, WhatsApp portföy limiti gibi kiracılar arası paylaşılan kotalar) kiracı başına adil pay ağırlıklı DRR ile ve şerit tavanlarıyla sağlanır. Kiracının kendi hesabında limit kiracıya göre uygulanır. İki durumda da formül aynıdır: kümülatif şerit tavanı (§19.7). Kiracı kendi sağlayıcı hesabını getirdiğinde paylaşılan kotadan çıkar.

**TN-54 — Kiracı başına eşzamanlılık, bekleme ve üretim hızı sınırlıdır.** Kiracı başına uçuştaki teslim, eşzamanlı bekleme noktası ve kuyruktaki iş sayısı küme geneli sayaçlarla sınırlanır (§19.6). Büyük alıcı listeleri ve kampanya fan-out'u sayfalı üretilir; üretim hızı kiracı kotasına bağlıdır, liste belleğe tek seferde alınmaz ve iptal ucuzdur.

**TN-62 — Gürültülü komşu gözlenir.** Tek bir kiracının bir kuyruktaki işlerin yarısından fazlasını oluşturması, kiracı bazlı işlenen iş dağılımındaki dengesizlik ve tek API anahtarının baskınlığı işaretlenir ve işletim panelinde görünür. Metriklerde kiracı etiketi kardinalite kuralıyla kullanılır (§20.6).

---

### 18.8 Bölge ve veri yerleşimi

**TN-55 — SaaS bölge başına bağımsız kurulumdur; bölgeler arası veri akışı yoktur.** Bölgeler: Türkiye, AB, ABD. Her bölgenin kendi Postgres'i, Valkey'i ve KMS/HSM'i vardır. Kiracı kayıtta bölge seçer ve verisi orada kalır. Bölgeler arası replikasyon, yedek kopyalama ve işletim verisi kopyalama yapılmaz; bölgeler arası görünüm gereken yerde bölge içi sistemlere sorgu yapılır, veri taşınmaz. Felaket kurtarma bölge içindedir (§20.5). Bölgelerin açılış sırası yapım sırasında belirlenir. Kurulum adımları §20.10'dadır.

**TN-56 — Türkiye bölgesi yurt içinde çalışır.** Türkiye bölgesi yurt içi veri merkezinde ya da yerli bulutta çalışır (TCMB/BDDK yurt içinde tutma kuralları; Access Ek C). Yedekleri ve anahtar yedekleri de yurt içindedir.

**TN-57 — Access ve Relay'i birlikte kullanan kiracının iki ürünü aynı bölgededir.** Bağlantı ayarı farklı bölgedeki iki kurulumu bağlamayı reddeder.

**TN-58 — Kanal sağlayıcısı kaydı veri yerleşimi meta verisi taşır.** Her sağlayıcı kaydında işleme ülkesi, aktarım dayanağı ve (varsa) standart sözleşme bildirim tarihi bulunur. Bölge dışına veri gönderen sağlayıcı panelde "bu kanal yurt dışına veri gönderir" uyarısıyla gösterilir; etkinleştirilmesi denetim kaydına girer. Kiracı isteğe bağlı "yalnız yurt içi" politikası açabilir; bu politika açıkken bölge dışına veri gönderen sağlayıcı rotaya giremez (§12'deki doğrulanmış rota kuralıyla aynı yerde uygulanır).

**TN-59 — Lisanslı kiracı için dağıtım rehberi yazılır.** Bankacılık, ödeme ve e-para gibi yurt içinde tutma yükümlülüğü olan kiracılar için önerilen dağıtım: Türkiye bölgesi ya da self-host + yerli sağlayıcılar (yurt içi SMS işletmecisi, yurt içi ya da kendi MTA'sı). Rehber, APNs'siz bir iOS push yolu olmadığını açıkça belirtir. Kiracının lisans durumunun değerlendirilmesi kiracının işidir; Relay bunu teknik seçeneklerle destekler.

**Ön katman.** CDN/WAF/DDoS ön katmanı ve TLS sonlandırma kuralları §20.10'dadır: ön katman bölgenin veri yerleşimi kurallarına uyar; regüle Türkiye kiracılarında TLS yurt dışında sonlandırılmaz.

---

### 18.9 Takedown, erişim logu ve tedarik zinciri

**TN-60 — Takedown API'si ve yapılandırılabilir trafik/erişim logu saklaması vardır.** Kurulum operatörü bir mesajın, şablonun ya da gönderici kimliğinin içerik erişimini kapatabilir (inbox öğesi gizlenir, bekleyen gönderimler `PAUSED`/`cancelled` olur, şablon yayından kalkar); her takedown denetim kaydına girer. Trafik ve erişim logu (IP, port, zaman) ayrı saklama sınıfıdır (`traffic`, Access Ek C); süreler POLICY DEFAULT'tur, değerleri bağlı özellik yapım sırasına girerken konur (F-28); azami süreli satırlarda süreden uzun saklama yapılmaz.

**TN-61 — Tedarik zinciri kuralları Access ile aynıdır.** Her sürüm SBOM ile, imzalı ve provenance kanıtıyla yayımlanır. SaaS alan adında RFC 9116 `security.txt` bulunur. Bağımlılık, derleme ve depo güvenliği kuralları Access §14.7 F-1…F-18 ile aynıdır.

---

### 18.10 Kriptografi kuralları

**TN-35 — Kriptografik seçimler tablodadır; kendi primitifimiz yoktur.**

| Kullanım | Algoritma | Kural |
|---|---|---|
| Giden webhook imzası | Ed25519 (`v1a`); HMAC-SHA256 (`v1`, uyumluluk) | Suiss webhook profili (TN-32); imza ve doğrulama ham bayt üzerinde |
| Gelen sağlayıcı webhook doğrulaması | Sağlayıcının şeması (HMAC-SHA256, Ed25519, imzalı JWT) | Ham bayt üzerinde; sabit zamanlı karşılaştırma; zaman damgası toleransı uygulanır |
| APNs sağlayıcı jetonu | ES256 (P-256) | KMS imzası; DER → `R‖S` dönüşümü test vektörlü (TN-28) |
| VAPID | ES256 | KMS imzası (TN-31) |
| Web Push içerik şifrelemesi | RFC 8291 `aes128gcm` (ECDH P-256 + HKDF-SHA256 + AES-128-GCM) | Protokolün sabit seçimi; efemeral anahtar; eskimiş `aesgcm` biçimi kullanılmaz |
| FCM assertion | RS256 | Federasyon yoksa KMS imzası (TN-30) |
| Saklanan kişisel veri | AES-256-GCM | Özne × saklama sınıfı DEK'i (TN-33) |
| Kör indeks | HMAC-SHA256 | Anahtar veritabanı dışında (TN-33) |
| Abone jetonu ve imzalı bağlantılar (tek tık çıkış, tercih bağlantısı) | EdDSA ya da ES256 imzalı opak belirteç | Kısa ömür; amaç ve kapsam belirteçte |
| Taşıma | TLS 1.2+ (tercihen 1.3) | Sağlayıcı bağlantılarında sertifika doğrulaması kapatılamaz |

Kurallar:
1. Primitifler platform kriptografi kütüphanesinden (OpenSSL tabanlı `:crypto`) gelir; tek atımlık (one-shot) API'ler tercih edilir. Kendi kriptografik primitifimiz yazılmaz. RFC 8291 gibi protokol birleştirmeleri kendi kodumuzdur ve RFC test vektörleriyle doğrulanır.
2. Sır ve imza karşılaştırmaları sabit zamanlıdır.
3. İmza doğrulaması her zaman ham gövde baytları üzerindedir; ayrıştırıp yeniden serileştirilmiş gövde doğrulanmaz.
4. İmzalanan ya da özeti alınan yapılar kanonik serileştirmeyle üretilir; eşleme sırası belirsiz yapı (ör. büyük map'in varsayılan JSON kodlaması) imzaya ve tekilleştirme anahtarına girmez.
5. Push yükü yalnız "içerik taşımıyor" biçiminde tanımlanabilir; "sıfır bilgi" ifadesi kullanılmaz (sağlayıcı token'ı, zamanlamayı, boyutu ve başlıkları görür).

---

### 18.11 TN karar register'ı (TN-1–TN-62)

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| TN-1 | Relay'in kendi kiracı modeli; kiracı en üst yalıtım birimi; Access olmadan tam çalışır | MERKEZİ KARAR | Bağımsız ürün; Access E40 madde 3 |
| TN-2 | Kiracı kurulumunda `region` (değişmez), `default_timezone`, `default_locale` zorunlu; sistem varsayılanı yok | FROZEN (teknik) | Sessiz yanlış davranışı önler; bölge değişmezliği veri yerleşimi kuralından |
| TN-3 | Alt kiracı birinci sınıf, tek seviyeli, ücretsiz çekirdekte; marka, gönderici kimliği, sağlayıcı hesabı, tercih varsayılanı, kanal kimliği, inbox kapsamı | MERKEZİ KARAR | Sektörde Enterprise kilidinin (Knock) tersi; SuprSend kiracı modeli |
| TN-4 | Miras: "yoksa üsttekini kullan, varsa ezme"; çözüm sırası alt kiracı → kiracı | FROZEN (teknik) | Kazara ezmeye karşı (Novu bağlam dersi) |
| TN-5 | Eşleşmeyen alt kiracı → `skip: scope_mismatch`, görünür; sessiz kayıp yok | KANONİK DEĞİŞMEZ | Novu bağlam tam eşleşmesinde sessiz kayıp |
| TN-6 | Access org ↔ alt kiracı, Access kiracısı ↔ Relay kiracısı otomatik eşleme | FROZEN (teknik) | Access E40 madde 4 (ortak kiracı eşlemesi) |
| TN-7 | Kiracı başına `live`/`test` ayrı veri düzlemleri; ortam API anahtarında; aynı işleme hattı, son adımda sahte sağlayıcı | MERKEZİ KARAR | Test ile canlı arasında davranış farkı olmaması |
| TN-8 | Sanal saat yalnız `test`; güvenliği zayıflatan bayrak yok | FROZEN (teknik) | Access OP-69 ile aynı yön |
| TN-9 | Access (ve diğer üretici ürünler) yalıtılmış platform kiracısıdır; ayrı gönderen alan adı ve itibar; ayrıcalık yok | FROZEN (teknik) | Access E40 madde 2 |
| TN-10 | Kiracı/gönderici askıya alma çekirdekte; bütün giriş noktalarında etkili; bağlantılar kesilir; işler `PAUSED`; hukuki süre değerleri PD | FROZEN (teknik) · PD (süreler) | Spam/dolandırıcılık müdahalesi; DSA notice-and-action |
| TN-11 | Pool yalıtım modeli; şema/DB başına kiracı yok; ayrı altyapı = aynı paketin ayrı kurulumu | FROZEN (teknik) | Şema modelinde katalog/yedek/göç maliyeti doğrusal büyür ⚠️ (pg_dump ölçümleri PG18'de doğrulanmadı) |
| TN-12 | `tenant_id` + `environment` her tabloda PK öneki; bileşik UNIQUE; bileşik FK | KANONİK DEĞİŞMEZ | PG RLS dokümanı: referans bütünlüğü RLS'i atlar |
| TN-13 | FORCE RLS; transaction-yerel bağlam; `missing_ok` yok; bağlamsız sorgu hata; uygulama katmanı birincil | FROZEN (teknik) | Yanlış rol RLS'i sessizce kapatır; havuzda oturum değişkeni sızar |
| TN-14 | Uygulama yanlış rolle (superuser, BYPASSRLS, tablo sahibi, DELETE yetkisi) başlamayı reddeder | FROZEN (teknik) | En ucuz ve en etkili yalıtım kontrolü |
| TN-15 | Kiracılar ve ortamlar arası erişim 404 | FROZEN (teknik) | 403 kaynağın varlığını sızdırır |
| TN-16 | Altı sızıntı testi + imha kapsamı testi | FROZEN (teknik) | Yalıtımın kural testleriyle sürekli doğrulanması |
| TN-17 | Valkey anahtarları ve önbellekler kiracı + ortam önekli; kiracı verisinden atom/süreç adı yok | FROZEN (teknik) | Atom tablosu sınırsız büyümez |
| TN-18 | Kiracı verisi kiracılar arası analitik, model eğitimi veya ürün geliştirme için kullanılmaz | FROZEN (teknik) | Relay SaaS'ta veri işleyendir; aksi veri sorumluluğu doğurur |
| TN-19 | Konsol girişi herhangi bir OIDC IdP; roller Relay'de; RBAC self-host'ta da tam | MERKEZİ KARAR | Access E40 madde 3; özellik eşitliği |
| TN-20 | Access bağlıyken operatör yaşam döngüsü Access olaylarından | FROZEN (teknik) | Tek kimlik |
| TN-21 | Hassas işlemler listesi step-up ister; Access'te step-up + AuthZEN, Access yoksa `max_age`/`acr` | MERKEZİ KARAR | Hassas işlemde oturum yükseltme (Gotify v3 deseni; Access) |
| TN-22 | Gevşetme sıkılaştırmadan daha yüksek yetki ister | FROZEN (teknik) | Durdurmada tereddüt, açmada acele zararı büyütür |
| TN-23 | Kurulum operatörü rolü (SaaS'ta işletmeci, self-host'ta kurum yöneticisi; kod aynı); `critical` onayı; RLS'i atlayan okuma yok, destek erişimi süreli devirle | FROZEN (teknik) | Kontrollü `critical` açılımı; özellik eşitliği |
| TN-24 | API anahtarı tek kiracı + tek ortam; yayın/okuma kapsamları ayrı; özet saklama; çakışmalı rotasyon; anında iptal | FROZEN (teknik) · PD (çakışma süresi) | Yayın ve okuma yetkisi ayrımı (Gotify) |
| TN-25 | Abone jetonu dar kapsamlı ve kısa ömürlü; ajan kimliği Relay kaydı + Access bağı; kiracı kimliği istemciye görünmez alanda değil | FROZEN (teknik) | §15 ve §17'deki kimlik kuralları; Access jetonu doğrudan inbox'a girmez |
| TN-26 | Sır arka ucu port (KMS/OpenBao/SoftHSM/age); DB'de yalnız referans; çözülmüş sır paylaşılan bellekte yok; URI'de düz sır yok; sıcak rotasyon | FROZEN (teknik) | BEAM iç gözlem yolları (crash dump, durum okuma) sırrı sızdırır |
| TN-27 | Zarf şifreleme: bölge KEK → kiracı veri anahtarı; önbellek 5–15 dk; kendi anahtarını getir seçeneği | FROZEN (teknik) · PD (önbellek süresi) | Mesaj başına KMS çağrısı maliyet ve kota olarak imkânsız ⚠️ (AWS fiyat hesabı) |
| TN-28 | APNs/VAPID/FCM imza anahtarları uygulama belleğine girmez; KMS imzası; DER→`R‖S` test vektörlü | FROZEN (teknik) | BEAM sır silemez; yanlış dolgu aralıklı `InvalidProviderToken` üretir |
| TN-29 | APNs JWT 20–60 dk (hedef ~40); son iyi JWT önbellekte; KMS kesinti alarmı; çevrimdışı DR kopyası; sıcak değişim; iki anahtarla rotasyon | FROZEN (teknik) | Apple: 20 dk'dan sık / 60 dk'dan seyrek yenileme reddedilir |
| TN-30 | FCM için iş yükü kimliği federasyonu; yoksa KMS'te RS256; OAuth jetonu proje başına önbellekte | FROZEN (teknik) | Servis hesabı anahtarı riski; Google org politikası anahtar yüklemeyi kapatabilir ⚠️ |
| TN-31 | VAPID kimlik anahtarı kanal kimliği (uygulama) başına ve KMS'te, mesaj anahtarı efemeral; rotasyon çift anahtarla | FROZEN (teknik) | RFC 8292: VAPID değişince abonelikler geçersizleşir |
| TN-32 | Webhook imzası Suiss profili: `v1a` Ed25519 varsayılan, `v1` HMAC uyumluluk; çakışmalı rotasyon | MERKEZİ KARAR | Access TN-136 ile ortak profil |
| TN-33 | Kişisel alanlar özne × sınıf DEK'iyle AES-256-GCM; token/adres düz metin yok; HMAC kör indeks, anahtar DB dışında; DB içi şifreleme fonksiyonu yok | FROZEN (teknik) | Access OP-74 madde 6; crypto-shredding önkoşulu |
| TN-34 | Varsayılan bulut KMS; tek kiracılı HSM yalnız denetim/regülasyon istediğinde | WATCH | Tek kiracılı HSM ihtiyacı denetçi görüşüne bağlı |
| TN-35 | Kriptografi tablosu; platform kripto, one-shot API, kendi primitif yok, sabit zamanlı karşılaştırma, ham bayt doğrulama, kanonik serileştirme; "sıfır bilgi" iddia edilmez | FROZEN (teknik) | RUSTSEC-2026-0071 (yeniden kullanılabilir bağlamda nonce sarması) dersi: one-shot API |
| TN-36 | Kill switch tek model, beş boyut: kapsam × kanal × hedef × mesaj sınıfı × durum; her kapsamda engellenen iş duraklatılır (TN-40) | MERKEZİ KARAR | Sektördeki aktif/pasif düzeyinin ötesinde tek model |
| TN-37 | En kısıtlayıcı kayıt kazanır | KANONİK DEĞİŞMEZ | Global durdurma kiracı ayarıyla delinemez |
| TN-38 | Fail-safe: okunamazsa son bilinen durum; açılışta durum yoksa gönderim yok; kesinti switch açmaz | KANONİK DEĞİŞMEZ | Kesinti sırasında kazara açılmayı önler |
| TN-39 | Doğruluk Postgres, yayılım Valkey sinyali, okuma düğüm önbelleği; Valkey yoksa yoklama; yayılım < 2 sn | FROZEN (teknik) · EA (< 2 sn) | Her kontrolde DB sorgusu ve yalnız bellek seçenekleri reddedildi |
| TN-40 | Üç durdurma noktası; varsayılan duraklatma: engellenen iş `PAUSED`, silinmez, hata sayılmaz, otomatik yeniden denenmez; resume açık eylem, her mesaj kafesten baştan (tercih, İYS, sessiz saat, frekans, kota); `expires_at` dolan `expired`; toplu iptal ayrı, açık, denetim kayıtlı eylem; her engelleme `rule_id` | KANONİK DEĞİŞMEZ | "Durdurayım mı, veri kaybeder miyim" tereddüdünü kaldırır; bayat mesaj gönderilmez |
| TN-41 | TTL ve `reason` zorunlu; açma daha yüksek yetki + step-up; kapsama göre yetki; her değişiklik denetimde | FROZEN (teknik) | Postmortem'in tek güvenilir kaynağı gerekçe alanıdır |
| TN-42 | `security` sınıfı varsayılan olarak durdurulmaz; durdurmak ayrı açık onay | KANONİK DEĞİŞMEZ | OTP durması bütün girişleri kilitler |
| TN-43 | Ölü adam anahtarı: anormal hacim (1 saatlik ortalamanın 10 katı) otomatik duraklatır; `security` hariç; açma insan kararı | FROZEN (teknik) · PD (eşik) | İzlenmeyen saatteki toplu kazayı yakalar |
| TN-44 | Yürürlüğe girme gecikmesi SLO'dur ve arayüzde gösterilir | FROZEN (teknik) | Operatör durdurmanın işlediğini görmelidir |
| TN-45 | Kill switch'e üç bağımsız erişim yolu (panel/API, CLI, acil DB prosedürü) | FROZEN (teknik) | Panel düştüğünde de durdurabilmek |
| TN-46 | Kendi denetim kaydı; düz append-only, kayıt başına hash zinciri yok; periyodik imzalı Merkle kontrol noktası dışarı yayımlanır; tek kaydın varlığı diğerleri açılmadan kanıtlanır; model ve biçim Access ile aynı | MERKEZİ KARAR | Tek doğrulayıcıyla iki ürünün kaydı; Access OP-37, Access OP-38; yayımlanmayan bütünlük iddiası boş |
| TN-47 | Kapsam: insan ve yönetici eylemleri (tablo); teslim defterinden ayrı | FROZEN (teknik) | KVKK ve 6563 açısından "kim ne yaptı" kaydı |
| TN-48 | Access bağlıysa eylemi yapanın Access kimliği + Access kayıt numarası; yoksa IdP `iss` + `sub` | FROZEN (teknik) | Denetim kayıtlarının bağlanması (Access E40) |
| TN-49 | SIEM'e aktarım; saklama varsayılanı 400 gün, sektör şablonu uzatır | POLICY DEFAULT | Access OP-74, Access Ek C |
| TN-50 | Denetim tablosuna yalnız yazma fonksiyonuyla ekleme; değiştirme/silme yetkisi yok; okuma da denetlenir; operatör kimliği zorunlu | FROZEN (teknik) | Append-only garantisi rol yetkisiyle |
| TN-51 | Kuyruk topolojisi şerit × kanal; kiracı başına kuyruk yok; adalet kuyruk içinde | FROZEN (teknik) | Kiracı başına kuyruk binlerce üretici ve yoklama üretir |
| TN-52 | Kota senkron `429 quota_exhausted` (retryable değil); hız limiti asenkron yavaşlatır; `security` ve toplu ayrı kovalar; kota tükenince yalnız `security` için sınırlı ek pay (kiracı ayarı), anında uyarı, ek pay bitince red; hedef korumaları ek paydan önce; kiracı sınıf başına kota payı tanımlayabilir | FROZEN (teknik) · PD (ek pay %10) | İş kaybolmaz; toplu gönderim OTP'yi aç bırakamaz; OTP'nin kota yüzünden durması bütün kullanıcıları kilitler, sınırsız muafiyet kötüye kullanıma açık |
| TN-53 | Paylaşılan hesapta ağırlıklı DRR + şerit tavanı; kendi hesabında kiracı limiti; tek formül: kümülatif şerit tavanı | FROZEN (teknik) | FCM proje kotası ve WhatsApp portföy limiti kiracılar arası paylaşılır |
| TN-54 | Kiracı başına uçuştaki iş, eşzamanlı bekleme ve kuyruk sayısı sınırlı; fan-out sayfalı ve kotaya bağlı | FROZEN (teknik) | Tek kiracının paylaşılan işçileri işgali |
| TN-55 | Bölge başına bağımsız kurulum (TR/AB/ABD); kendi Postgres/Valkey/KMS; bölgeler arası veri akışı yok; DR bölge içinde | MERKEZİ KARAR | Veri yerleşimi; KVKK m.9 yurt dışı aktarım rejimi |
| TN-56 | Türkiye bölgesi yurt içi veri merkezi ya da yerli bulut; yedekler de yurt içinde | MERKEZİ KARAR | TCMB/BDDK yurt içinde tutma (Access Ek C) |
| TN-57 | Access + Relay kullanan kiracının iki ürünü aynı bölgede | FROZEN (teknik) | Bölgeler arası veri akışı yasağı |
| TN-58 | Sağlayıcı kaydında veri yerleşimi meta verisi; "yurt dışına veri gönderir" uyarısı; isteğe bağlı "yalnız yurt içi" politikası | FROZEN (teknik) | FCM/APNs, Twilio, SES, Meta yurt dışı aktarımdır |
| TN-59 | Lisanslı kiracı dağıtım rehberi: TR bölgesi ya da self-host + yerli sağlayıcılar; APNs'siz iOS push yolu yok | POLICY DEFAULT | BDDK m.25, TCMB m.21 yurt içinde tutma |
| TN-60 | Takedown API + `traffic` saklama sınıfı; süreler PD (değer yapım sırasında konur, F-28) | FROZEN (teknik) · PD (süreler, değer ölçümle) | 5651, DSA |
| TN-61 | SBOM, imzalı sürüm ve provenance, `security.txt`; Access §14.7 F-1…F-18 | FROZEN (teknik) | Ortak tedarik zinciri kuralları |
| TN-62 | Gürültülü komşu işaretleri (kuyruk payı > %50, dengesiz dağılım, tek anahtar baskınlığı) panelde | POLICY DEFAULT | Erken tespit |
