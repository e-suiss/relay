## 3. Decision Status System

### 3.1 Statüler

Her karar tam olarak bir statü taşır (F-20). Statü, kararın ne kadar bağlayıcı olduğunu ve hangi koşulla değişebileceğini söyler.

| Statü | Anlam | Tipik aileler | Değişim koşulu |
|---|---|---|---|
| **KANONİK DEĞİŞMEZ** | Asla ihlal edilmez; implementasyon bunu korumak zorundadır ve mümkünse veritabanı kısıtı, tip ya da CI kuralıyla zorlar | INV (§6) ve bölümlerin değişmez satırları | §3.2 (1)–(3) |
| **MERKEZİ KARAR** | Bütün bölümleri bağlayan karar; bölümler ayrıntılandırır, gevşetemez | MD-1–MD-20 (§1.7) | §3.2 (1)–(4) |
| **FROZEN (ürün)** | Bağlayıcı ürün kararı: kapsam, sahiplik, davranış, deneyim | F, C, E, X ve bölüm ailelerinin ürün satırları | §3.2 (1)–(4) |
| **FROZEN (teknik)** | Bağlayıcı mimari ve teknoloji kararı | API, WF, TP, CH, PC, DS, IN, WH, AG, TN, T, OP ailelerinin teknik satırları | §3.2 (1)–(4); ayrıca ölçümle kanıtlanmış sınır |
| **FROZEN (landscape)** | Sektörden benimsenen ya da bilerek kaçınılan kalıp | L, MKT'nin kural satırları (§4) | Yeni karşı örnek ya da atıf yapılan standardın statüsünün değişmesi |
| **POLICY DEFAULT** | Ayarlanabilir varsayılan değer; semantik değildir. Kim, hangi sınır içinde ve hangi yönde değiştirebileceği satırda yazılır | Bölüm ailelerinin PD satırları | Kalibrasyon ya da ölçüm; uyum değerlerinde yalnız sıkılaştırma (§3.5) |
| **ENGINEERING ASSUMPTION** | Ölçülecek sayı ya da varsayım; ürün iddiası değildir | Gecikme, verim, kapasite hedefleri | Ölçüm; benchmark alt koşulu §3.1c |
| **WATCH** | Dış dünyaya (standart, platform, sağlayıcı, mevzuat, pazar) bağlı, izlenen bilgi; fikir kaynağıdır, bağımlılık değildir | Farklılaşma iddiaları (§4.4), platform ve fiyat bilgileri, yürürlüğü izlenen mevzuat değerleri | Standart, pazar ya da mevzuat durumunun değişmesi |
| **KAPSAM DIŞI** | Relay'in bilerek yapmadığı şey; gerekçesi ve işin sahibi satırda yazılır | Her bölümün kapsam dışı satırları | §3.2 (1)–(4); "rakipte var" tek başına gerekçe değildir |

Kurallar:
- Bir kararın kuralı bağlayıcı, parametre değerleri ise ayarlanabilir, ölçülecek ya da dış dünyaya bağlıysa register satırı kuralın statüsünü taşır ve değerleri nitelikle belirtir: `· PD (…)`, `· EA (…)`, `· WATCH (…)` (ör. `FROZEN (teknik) · PD (eşikler)`). Nitelik ikinci bir statü değildir; belirttiği değerler POLICY DEFAULT (§3.5), ENGINEERING ASSUMPTION (§3.1c) ya da WATCH kurallarına tabidir. İki ayrı karar tek satırda birleştirilmez; ayrı ID alır.
- POLICY DEFAULT ile ENGINEERING ASSUMPTION karıştırılmaz. PD bir tercihtir (ör. `unknown_pending` penceresi). EA bir tahmindir (ör. Postgres tek satır hız limiti verimi).
- Değeri henüz verilmemiş bir POLICY DEFAULT "PD (değer ölçümle)" olarak yazılır. Değer, bağlı özellik yapım sırasına girerken ölçüm ya da plan kararıyla konur; değeri olmayan PD'ye dayanan özellik, değer konmadan yayımlanmaz (F-28). Bu PD'lerin listesi §22'deki OQ-27 kapanış kaydındadır.
- KAPSAM DIŞI bir faz etiketi değildir: "sonra yapılacak" anlamına gelmez. Yapılacak bir işin sırası yapım sırası ekinde belirlenir, statüsü değişmez.

#### 3.1a DAY-1 niteliği

**DAY-1** bir statü değildir; statüye dik bir niteliktir. Anlamı: sonradan değiştirmek ya uygulanabilir değildir ya da bütün kurulumları durduran bir veri göçü gerektirir. Bu yüzden karar implementasyondan önce kilitlenir (F-21). Register satırında statünün yanında yazılır ("MERKEZİ KARAR · DAY-1").

DAY-1 taşıyan merkezi kararlar: MD-6 (doğruluk Postgres'te), MD-8 (sınıf kabulde atanır), MD-9 (fiziksel silme yok, özne başına DEK), MD-10 (bölge başına kurulum), MD-16 (müşteri kodu yok), MD-18 (kiracı ve ortam modeli). Bölüm kararlarından DAY-1 taşıyanlar ilgili bölümde işaretlenir.

#### 3.1b Karar kaydı alanları

Her FROZEN (teknik) karar ve her MKT kural satırı, register'daki kısa satıra ek olarak bölüm metninde şu alanları taşır:

| Alan | İçerik |
|---|---|
| Kimlik | Kararlı ID |
| Statü | §3.1'deki tek statü (+ varsa DAY-1) |
| Karar | Normatif metin |
| Gerekçe | 1–3 cümle; standart, ürün ya da mevzuat adıyla |
| Reddedilenler | Alternatifler ve neden |
| Kabul testi | Kararı sabitleyen kural testi ya da test dosyası |
| Geçersiz kılacak karşı örnek | Kararı yeniden açtıracak somut gözlem ya da test sonucu |

Kabul testi ve karşı örnek alanları henüz dolmamış kararlar register'da "doldurulacak" olarak işaretlenir (F-22). Bu alanların sonradan doldurulması yeniden açma değildir.

#### 3.1c Benchmark alt koşulu (F-23)

ENGINEERING ASSUMPTION olan her performans sayısı şu kurallara uyar:
- Kod, ham çıktı ve koşum komutu repoda bulunana kadar **"yeniden üretim bekliyor"** etiketi taşır.
- Ölçüm ortamı (donanım, yazılım sürümü, bağlantı sayısı, süre) sayının yanında yazılır.
- Mutlak değerler ürün iddiası değildir; kapasite, maliyet ya da rakip karşılaştırması için kullanılamaz.
- Yük üreteci açık döngüdür; gecikme planlanan başlangıçtan ölçülür (coordinated omission önlemi).

### 3.2 Yeniden açma koşulları (F-24)

KANONİK DEĞİŞMEZ ya da FROZEN bir karar yalnız şu durumlardan biriyle yeniden açılır:

1. **Gerçek çelişki:** başka bir değişmez ya da frozen kararla aynı olgu için iki sahip, aynı adın iki anlamı ya da iki doğruluk kaynağı.
2. **Semantik veya fiziksel imkânsızlık:** karar, fiziksel olarak sağlanamayan bir garanti vaat ediyor (ör. platformun vermediği teslim makbuzunu vaat etmek).
3. **Ölçülmüş güçlü kanıt:** kararın dayandığı varsayımın yanlış olduğunu gösteren somut, ölçülmüş kanıt.

MERKEZİ KARAR ve FROZEN kararlar için dördüncü koşul da geçerlidir:

4. **Zorunlu model açığı:** sonraki katmanda (sözleşme, şema, implementasyon) kararın modelinin karşılayamadığı zorunlu bir gereksinimin ortaya çıkması.

"Başka türlü de yapılabilir", "rakip farklı yapıyor", "implementasyon zor" ve fiyat baskısı yeniden açma gerekçesi değildir. Bir merkezi karar kendi metninde ayrıca yeniden değerlendirme koşulu taşıyabilir (ör. MD-5); bu koşul (3) ya da (4)'ün somut biçimidir.

Yeniden açılan karar eski ID'sini korur; değişiklik aynı satıra tarih ve gerekçeyle yazılır. Bir ID hiçbir zaman başka bir karar için yeniden kullanılmaz; emekli ID register'da "emekli → yerine geçen ID" olarak kalır.

### 3.3 Garanti sınıfları (F-25)

Relay'in davranış ve teslim iddiaları için aşağıdaki sınıflar kullanılabilir. Garanti sınıfı statüden ayrıdır: statü kararın bağlayıcılığını, garanti sınıfı iddianın neye dayandığını söyler.

| Sınıf | Kısa | Anlam | Örnek |
|---|---|---|---|
| ANLAMDAN GARANTİ | BS | Kayıtların ve kuralların tanımından çıkar; operasyonel koşula bağlı değildir | Gönderilmeyen bildirim neden koduyla kaydedilir (MD-12) |
| BEYANLI KOŞULLA GARANTİ | UDC | Yalnız beyan edilmiş bir yetenek, yapılandırma ya da POLICY DEFAULT varken geçerlidir; koşul satırda yazılır | Sağlayıcı DLR gönderiyorsa `delivered` durumu kesindir |
| GARANTİ EDİLMEZ | NG | Relay vaat etmez; ürün dili bunu garanti diliyle söyleyemez | Push'un cihaza ulaşması; sağlayıcının sonucu bildirmesi |
| FİZİKSEL OLARAK SAĞLANAMAZ | PU | Hiçbir mimari sağlayamaz | Ağ ve sağlayıcı katmanında tek başına exactly-once teslim |

#### 3.3a İddia dili

| Konu | İzin verilen | İzin verilmeyen |
|---|---|---|
| Teslim garantisi | "At-least-once teslim + kalıcı idempotency ile etkin exactly-once işlem." | "Exactly-once teslim." |
| Push | "Sağlayıcı kabul etti"; "cihaz SDK'sı gösterildi makbuzu gönderdi" | "Push teslim edildi" (makbuz yokken) |
| Okunma | "İnsan tıklaması", "görüldü (in-app)" | "E-posta okundu" (açılma pikseline dayanarak) |
| Onay | "Yanıt alındı: değer, yanıtlayan, kanal, kanal kanıt düzeyi" | "Onaylandı" (Access onayı yokken) |
| Uyum | "Relay İYS kontrolünü fail-closed uygular; kanıt kaydı tutar." | "Relay kullanmak mevzuata uyumu garanti eder." |
| Idempotency-Key | "Yaygın pratik (Stripe, IETF taslağı)" | "IETF standardı" |
| Silme | "Kişisel veri crypto-shredding ile okunamaz hâle getirilir; satır yumuşak silinir." | "Veri kalıcı olarak silindi." |

### 3.4 Hipotez → değişmez sızıntısı kontrolü (F-26)

Şu öğeler değişmez dilinde yazılmaz:
- WATCH satırları: platform kuralları, sağlayıcı fiyat ve limitleri, standart statüleri, yürürlüğü izlenen mevzuat süreleri.
- POLICY DEFAULT değerleri ve ENGINEERING ASSUMPTION sayıları.
- Farklılaşma iddiaları (§4.4).

**"Örnek bulunamadı ≠ ilk biz" kuralı.** "İncelenen ürünlerde bulunamadı" ifadesi "Relay bunu yapan ilk ürün" sonucuna dönüştürülmez. Bir farklılaşma iddiası her zaman üç şeyi beyan eder: karşılaştırma kümesi, karşılaştırma tarihi ve geçersiz kılacak karşı örnek (§4.4).

**⚠️ işareti.** Birincil kaynakta doğrulanmamış sayısal ya da olgusal bilgi ⚠️ ile işaretlenir. ⚠️'li bilgi karar metnine girmez; yalnız gerekçe sütununda ve WATCH satırlarında bulunur. "doğrulanmadı" ifadesi aynı anlamdadır.

### 3.5 POLICY DEFAULT değişim yönü

Her POLICY DEFAULT satırı şu üç şeyi yazar: değeri kim değiştirebilir (kurulum operatörü, kiracı, alt kiracı, alıcı), hangi sınırlar içinde (alt ve üst sınır) ve hangi yönde (F-27).

| Değer türü | Değişim yönü |
|---|---|
| Uyum ve güvenlik değerleri (yasal pencere, izin kuralı, İYS bayatlık eşiği, sınıf kanal kuralları) | Kiracı yalnız sıkılaştırabilir (MD-14) |
| Operasyonel varsayılanlar (retry takvimi, teslim raporu pencereleri, saklama süreleri) | Kiracı tanımlı alt/üst sınır içinde iki yönde değiştirebilir |
| Sabit sunucu politikaları (ör. Idempotency-Key saklama süresi) | Değiştirilemez; PD değil FROZEN olarak yazılır |

### 3.6 Açık sorular

"Açık" ertelenmiş değil, kanıtı henüz bulunmamış ya da kararı henüz verilmemiş anlamındadır. Açık sorular §22'dedir ve her biri "implementasyonu bloklar mı?" sütununu doldurur. Spec'te belirsiz, çelişkili ya da sessiz bir konu varsa implementasyon karar vermez; konu §22'ye yazılır ve karar yeni bir ID ile spec'e girdikten sonra uygulanır (F-29).

### 3.7 Register ve ID kuralları (F-30)

- Her bölüm kendi kararlarını bölüm sonundaki register'da toplar: `| ID | Karar | Statü | Gerekçe/kaynak |`.
- ID aileleri ve bölümleri §0.4'tedir; birleşik register §21, aile listesi Ek A'dadır.
- Bir bölüm başka bir bölümün ailesinden ID vermez; başka bölümün konusuna "§n" ile atıf yapar.
- Access spec'ine atıf "Access E40", "Access OP-74" biçimindedir. Access kararı Relay'de tekrar yazılmaz; Relay kararı ona atıf yapar.
- Spec kararlarını değiştiren her değişiklik yeni ya da güncellenmiş bir ID ile register'a girer; ayrı karar belgesi (ADR) tutulmaz.

### 3.8 Karar register'ı

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| F-20 | Statü seti §3.1'deki dokuz statüdür; her karar tam olarak bir statü taşır; parametre değerleri `· PD/EA/WATCH (…)` niteliğiyle belirtilir | FROZEN (ürün) | Tek statü, kararın bağlayıcılığını ve değişim koşulunu belirsizliksiz kılar |
| F-21 | DAY-1 statü değil statüye dik niteliktir; DAY-1 kararlar implementasyondan önce kilitlenir | FROZEN (ürün) | Sonradan değiştirmesi göç gerektiren kararlar (silme modeli, bölge, sınıf) |
| F-22 | FROZEN (teknik) ve MKT kural satırları kabul testi ve karşı örnek alanlarını taşır; boş alan "doldurulacak" olarak işaretlenir | FROZEN (ürün) | Bir kararın yanlış çıktığı yer tipik olarak karşı örneği tanımlanmamış yerdir |
| F-23 | ENGINEERING ASSUMPTION sayıları "yeniden üretim bekliyor" etiketi, ölçüm ortamı ve açık döngü yük ölçümü kuralına tabidir; mutlak değerler ürün iddiası değildir | FROZEN (ürün) | Coordinated omission ve tekrar üretilemeyen ölçüm riski |
| F-24 | Yeniden açma yalnız §3.2'deki koşullarla; ID'ler yeniden kullanılmaz | FROZEN (ürün) | Pazar baskısının ve zorluğun kararı açmaması |
| F-25 | Garanti sınıfları (BS, UDC, NG, PU) ve §3.3a iddia dili ürün ve belge dilini bağlar | FROZEN (ürün) | Teslim garantilerinin abartılması (push "delivered", tek başına "exactly-once") |
| F-26 | WATCH, PD ve EA öğeleri değişmez diline sızmaz; "örnek bulunamadı ≠ ilk biz"; doğrulanmamış bilgi ⚠️ ile yalnız gerekçe sütununda | FROZEN (ürün) | Eskiyen platform, fiyat ve standart bilgisinin karar metnine girmesi |
| F-27 | Her POLICY DEFAULT değiştiren rolü, sınırları ve yönü yazar; uyum ve güvenlik değerlerinde yalnız sıkılaştırma | FROZEN (ürün) | MD-14 |
| F-28 | Değeri verilmemiş PD "PD (değer ölçümle)" olarak yazılır; değer, bağlı özellik yapım sırasına girerken ölçüm ya da plan kararıyla konur; değer konmadan bağlı özellik yayımlanmaz | FROZEN (ürün) | Değersiz varsayılanın implementasyonda sessizce seçilmesi |
| F-29 | Spec belirsiz, çelişkili ya da sessizse implementasyon karar vermez; karar yeni ID ile spec'e girer, sonra uygulanır | FROZEN (ürün) | Spec'in tek karar kaydı olması |
| F-30 | Register biçimi, ID ailesi sınırları ve Access atıf biçimi §3.7'deki gibidir; ayrı ADR tutulmaz | FROZEN (ürün) | Access OP-70 ile aynı dokümantasyon modeli |
