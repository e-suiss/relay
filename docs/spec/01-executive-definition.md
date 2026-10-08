## 1. Executive Definition

### 1.1 Tek cümlelik tanım

> **Relay, bir olayı ya da mesajı doğru kişiye, servise, cihaza veya ajana; doğru kanaldan, doğru zamanda, izin ve mevzuat kurallarına uyarak ulaştıran, yanıt bekleniyorsa yanıtı toplayıp sahibine ileten ve ne olduğunu kanıtıyla kaydeden açık kaynak orkestrasyon platformudur; yetki, onay ve iş yürütme sahiplerinde kalır.**
>
> *(Relay is Suiss's open-source notification, messaging and event orchestration platform: it delivers an event or message to the right person, service, device or agent, over the right channel, at the right time and within consent and regulatory rules, collects responses where one is awaited and hands them to their owner, and records what actually happened with evidence, while authority, approval and execution remain with their owners.)*

Tanımın taşıyıcı seçimleri:

| Öğe | Anlamı |
|---|---|
| "kişiye, servise, cihaza veya ajana" | Dört alıcı türü aynı motordan geçer; ajan ayrı bir ürün değildir (F-4) |
| "doğru kanaldan, doğru zamanda" | Workflow, rota politikası, sessiz saat, saat dilimi ve hız sınırı Relay'indir (§10, §13) |
| "izin ve mevzuat kurallarına uyarak" | Uyum kapıları mimarinin parçasıdır, sonradan eklenen katman değildir (MD-14, MD-17) |
| "yanıtı toplayıp sahibine ileten" | Relay yanıt toplayıcıdır; onay kapısı değildir (MD-2, MD-3) |
| "ne olduğunu kanıtıyla kaydeden" | Teslim durumu append-only defterden türetilir; gönderilmeyen mesaj da kayıttır (MD-12, MD-15) |
| "açık kaynak" | Kodun tamamı Apache-2.0; SaaS ile self-host arasında özellik farkı yoktur (MD-4) |
| Son clause | Relay'in nerede durduğu tanımın parçasıdır: yetki Access'te, yürütme bekleyen tarafta, iş kuyruğu Work'tedir |

### 1.2 Tek paragraflık tanım

Relay, ürünlerin ve sistemlerin ürettiği olayları kendi API'si ya da CloudEvents ile alır, her olayı sürümlü bir workflow'a bağlar ve workflow adımlarını (kanal, bekle, digest, throttle, koşul, olay bekle, zaman penceresi, webhook) çalıştırır. Her teslimden önce aynı karar katmanından geçer: mesaj sınıfı, alıcı tercihleri, hukuki izin ve İYS, ülke kuralları, sessiz saat, frekans tavanı ve kill switch. Mesajı alıcının diline ve kanala göre render eder, doğrulanmış sağlayıcılar arasında yedekleme ve hız sınırıyla iletir, sağlayıcı geri bildirimlerini normalleştirir ve teslim durumunu değiştirilemez bir defterden türetir. İnsanlar için kalıcı inbox ve realtime akış, servisler için imzalı webhook ve olay hedefleri, ajanlar için bekleme noktası, kalıcı posta kutusu ve A2A/MCP/AG-UI uyumu sunar. Çok kiracılıdır; kiracı ve tek seviyeli alt kiracı modeli, kiracı başına `live`/`test` düzlemleri ve bölge başına bağımsız kurulum vardır. Access'ten bağımsız çalışır; Access bağlandığında kimlik, step-up, abone jetonu, ajan kimliği ve pazarlama izni Access'ten gelir. Relay hiçbir zaman yetki ya da onay kaynağı değildir, iş yürütmez ve müşteri kodu çalıştırmaz.

### 1.3 Temel problem

> **Bir olayın ya da mesajın, ulaşması gereken alıcıya, alıcının istediği ve mevzuatın izin verdiği kanaldan ve zamanda, ulaşıp ulaşmadığı kanıtlanabilir biçimde iletilmesi; yanıt bekleniyorsa yanıtın kaybolmadan, kimden ve hangi kanaldan geldiği bilinerek sahibine döndürülmesi.**

Problemin altı parçası:

| # | Soru | Relay'in cevabı | Ayrıntı |
|---|---|---|---|
| 1 | **Kime?** | Üreticinin verdiği alıcı ya da alıcı kümesi; topic aboneleri; ajan kaydı. Relay alıcı kümesini kendisi hesaplamaz | §10, §17 |
| 2 | **Hangi kanaldan?** | Rota politikası, kanal tercihi, cihaz durumu, sınıfın kanal kuralları (ör. `otp_oob` e-postaya düşmez) | §10, §12 |
| 3 | **Ne zaman?** | Alıcının yerel saati, sessiz saat, yasal pencere, digest, throttle, `expires_at` | §10, §13 |
| 4 | **Hangi kurallarla?** | Mesaj sınıfı, izin, İYS, ülke tablosu, tercih, kill switch; hepsi kayıtlı kararla | §13, §18 |
| 5 | **Ne oldu?** | Append-only teslim defteri; normalleştirilmiş durum; atlama nedeni | §14 |
| 6 | **Yanıt nasıl döner?** | Bekleme noktası, korelasyon, posta kutusu; yanıt değer + yanıtlayan + kanal kanıt düzeyiyle taşınır | §17 |

**Bu ürünü ne gereksiz kılardı?** Her kanalın ve her sağlayıcının teslimi garanti ettiği, kuralları kendisinin uyguladığı ve sonucu güvenilir biçimde bildirdiği bir dünya. Bugün öyle değildir: APNs teslim makbuzu vermez, SMS DLR'ı hiç gelmeyebilir, e-posta açılma verisi güvenilmez, sağlayıcılar bastırılmış alıcıya gönderimi "başarılı" gösterebilir, ajan protokollerinde retry ve imza tanımsızdır (§4).

### 1.4 Temel ürün vaadi

Relay'i kullanan bir ürün şunları alır:

| # | Vaat | Ne demek |
|---|---|---|
| 1 | **Tek giriş** | Tek API ya da CloudEvents ile olay gönderilir; tekrar korumaları (MD-20) kazara çift gönderimi engeller |
| 2 | **Doğru kanal ve zaman** | Kanal sırası, fallback, eskalasyon, sessiz saat ve saat dilimi ürün kodu yazılmadan uygulanır |
| 3 | **Uyum** | İzin, İYS, tek tıkla çıkış, ülke kuralları gönderim yolunda zorunlu olarak uygulanır |
| 4 | **Kanıt** | Her bildirimin ne olduğu ve neden gönderilmediği defterden görülür ("neden almadım") |
| 5 | **Kalıcı erişim** | Push kaybolsa da mesaj inbox'ta ya da posta kutusunda kalır; kopan bağlantı kayıp üretmez |
| 6 | **Yanıt toplama** | Bir insana ya da ajana sorulan sorunun yanıtı, hangi kanaldan gelirse gelsin eşleştirilir ve sahibine iletilir |
| 7 | **Dışa akış** | Relay'in kendi olayları ve kiracının müşterilerine giden olaylar imzalı, retry'lı, replay edilebilir biçimde teslim edilir |

Relay'in **vaat etmedikleri** de vaadin parçasıdır:

| Vaat edilmeyen | Neden |
|---|---|
| Push'un cihaza ulaştığı | Platformlar teslim makbuzu vermez; push için "delivered" iddia edilmez (§14) |
| Bir yanıtın onay olduğu | Kanal yanıtı yetki kanıtı değildir (MD-2) |
| Tek başına "exactly-once" teslim | Garanti dili "at-least-once teslim + kalıcı idempotency ile etkin exactly-once işlem"dir (MD-15) |
| Sağlayıcının bildirmediği sonucun bilinmesi | Pencere sonunda durum `unknown` olur; otomatik yeniden gönderim yapılmaz (§14) |
| İş etkisinin geri alınması | Relay yalnız kendi adımlarını geri alır; iş etkisinin telafisi sahibindedir (MD-3) |

### 1.5 Relay'in tek sorusu

> **"Bu event veya mesaj doğru kişiye, servise, cihaza ya da ajana nasıl ulaştırılacak?"**
>
> *(How does this event or message reach the right person, service, device or agent?)*

| Soru | Sahip |
|---|---|
| Bu iş dünyada geçerli mi, kim etkileniyor? (*is / who is affected*) | Domain ürünü (üretici) |
| Bu aktör bunu şimdi yapabilir mi, bu onay geçerli mi? (*may*) | Access |
| Bu iş üzerinde anlaşıldı mı, kimin onayı gerekiyor? (*should / when*) | Work |
| İş yürütüldü mü, nerede kaldı, nasıl devam eder? (*did / resume*) | Executor, ajan çerçevesi, müşteri kodu |
| **Doğru taraf haberdar oldu mu, yanıtı ne? (*was told / replied*)** | **Relay** |
| Ajan ne düşünüyor, neyi hatırlıyor? (*thinks*) | One |

Relay'in "yanıtı ne?" sorusuna cevabı yanıtın kendisidir (değer, yanıtlayan, kanal, kanal kanıt düzeyi, zaman). Yanıtın yetki ya da onay olarak geçerli olup olmadığı Access'in sorusudur (MD-2).

### 1.6 Birincil aktörler

| Rol | Örnek |
|---|---|
| Üretici (olay gönderen) | Kiracının backend'i, Access, diğer Suiss ürünleri, entegre sistemler |
| Kiracı geliştiricisi | API, SDK, CLI, dosya tabanlı workflow ile çalışan ekip |
| Kiracı operatörü | Panelde workflow, şablon, rota, kill switch yöneten kişi; roller Relay'de tutulur |
| Kurulum operatörü | SaaS'ta Suiss, self-host'ta kurumun Relay yöneticisi; platform kapsamlı işlemler (ör. `critical` öncelik onayı) |
| Alıcı / son kullanıcı | Bildirimi alan kişi; inbox ve tercih merkezini kullanır |
| Ajan alıcısı | Relay'de kayıtlı ajan; posta kutusunu okur, ack verir, uyandırılır |
| Servis alıcısı | Webhook ya da olay hedefi üzerinden olay alan sistem |
| Kiracının müşterisi | Kiracının gömülebilir webhook portalında uç nokta yöneten üçüncü taraf |
| Bekleyen taraf | Bekleme noktası açan Executor, ajan çerçevesi (LangGraph vb.) ya da müşteri kodu |
| Yanıtlayan | Bekleme noktasına kanal üzerinden yanıt veren insan ya da sistem; bekleyenle aynı olamaz |
| Üretici ürün (korunan şablon sahibi) | Metni kiracının değiştiremediği şablonları yayımlayan ürün (ör. Access) |
| Denetçi | Denetim kaydını ve teslim kanıtını inceleyen iç denetim, regülatör, kiracı uyum ekibi |

### 1.7 Merkezi kararlar (MD-1…MD-20)

Merkezi kararlar bütün bölümleri bağlayan kararlardır. Diğer bölümler bunları ayrıntılandırır, gevşetemez. Statü: **MERKEZİ KARAR** (§3.1); yeniden açma koşulu §3.2.

**MD-1 — Bağımsız ürün, Access ile sürtünmesiz.** Relay ve Access birbirinden bağımsız çalışır, birlikte sürtünmesiz çalışır (Access E40).
1. **Access, Relay olmadan:** Access kendi mesajlarını yerleşik doğrudan gönderim moduyla yollar (SMTP + tek genel HTTP SMS sağlayıcısı, basit retry). Bu modda fallback, sağlayıcı yedeği, tercih merkezi ve sessiz saat yoktur.
2. **Access, Relay ile:** Access'in insana giden bütün mesajları Relay'den gider. Access, Relay'de yalıtılmış bir platform kiracısıdır (kendi gönderen alan adı, ayrı izlenen itibar). İçerik ve "kime, neden" Access'indir; kanal, zamanlama, retry, fallback ve teslim durumu Relay'indir. CIBA'da Access OP'dir; Relay davetin teslim kanalıdır; onay Access onay yüzeyinde verilir.
3. **Relay, Access olmadan:** kendi API anahtarları, operatör girişi ve abone jetonuyla çalışır; başka bir IdP ile standart OIDC kullanır.
4. **Relay, Access ile:** operatör girişi ve step-up, abone jetonu, ajan kimliği ve pazarlama izni Access'ten gelir; denetim kayıtları birbirine bağlanır.
5. **Sürtünmesizlik:** tek bağlantı ayarı ve otomatik keşif; ortak webhook imza profili, CloudEvents, ortak kiracı eşlemesi. Relay eklenince ya da kaldırılınca müşteri kodu değişmez. Hiçbir özellik öbür ürün yokken sessizce bozulmaz; öbür ürünü gerektiren özellik bunu açıkça belirtir.
Ayrıntı: §7.

**MD-2 — Relay yetki ve onay kaynağı değildir.**
1. Teslim, ack, görüldü, tıklama ve kanal yanıtı hiçbir zaman yetki durumu değildir; Relay'in cevabı onay değildir (Access E40 (5), Access EI-18).
2. Inbox eylem butonu, push eylemi, kilit ekranı yanıtı, SMS yanıtı ve sohbet butonu hiçbir zaman onay değildir. Onay türündeki öğede eylem yalnız Access onay yüzeyine derin bağlantıdır.
3. Relay yanıt toplayıcıdır: karar isteğini teslim eder; yanıtı (değer, yanıtlayan, kanal, kanal kanıt düzeyi, zaman) toplar ve sahibine iletir. "Onay" kararı, risk kademesi ve uygulama sahibindedir; sonuç sınıfı ve risk kademesi Relay'de üretilmez, sahibinden etiket olarak gelir.
4. Eskalasyonun son kademesi yalnız olay üretir; otomatik kabul/ret kararını Relay vermez.
5. Access ve Work olaylarında alıcı kümesi üreticinindir; Relay yalnız kanal seçer, kümeyi genişletmez ya da daraltmaz. Teslim durumu Access'e yalnız bilgi olarak döner; Access durumunu değiştiren hiçbir çağrı yoktur.
6. Bildirim içeriği yetki değildir: bir ajanı uyandırmak serbesttir, ajanın ne yapabileceği Access'te belirlenir.
Ayrıntı: §7, §17.

**MD-3 — Bekleme Relay'in, yürütme bekleyenin.**
1. Bekleme noktası ("şu anahtara yanıt bekleniyor, son tarih X"), korelasyon ve teslim Relay'indir. Relay yanıtı hangi kanaldan gelirse gelsin eşleştirir ve bekleyen tarafa "çözüldü" olayını teslim eder.
2. Checkpoint, pause, takeover ve devam ettirme Relay'in değildir (Access E31: Executor'ün). Relay ajan adımlarını çalıştırmaz; dayanıklı yürütme motoru değildir.
3. Relay iş etkisi telafisi (saga) yapmaz; yalnız kendi adımlarını geri alır (bekleme çözülünce eskalasyonu ve bekleyen teslimleri iptal eder).
4. Bekleme noktası belirli bir yürütücüye özel değildir; her ajan sistemi ve müşteri kodu kullanabilir.
5. Uzun beklemeler bir kayıt + zamanlayıcıdır; kuyruk slotu ve süreç tutmaz.
Ayrıntı: §10, §17.

**MD-4 — Açık kaynak, tam özellik eşitliği.**
1. Kodun tamamı Apache-2.0'dır. Hiçbir özellik "yalnız bulut" ya da lisans bayrağıyla kilitlenmez; self-host kuran her özelliği alır (kill switch, inbox, webhook replay, tercih merkezi, SSO/RBAC'li panel, aktivite takibi, ajan özellikleri dahil).
2. SaaS'ın ek değeri hizmettir, özellik değildir: paylaşılan sağlayıcı hesapları ve hazır gönderici itibarı, çok bölgeli işletim ve SLA, yönetilen İYS bağlantısı, yedekleme, güncelleme, nöbet.
3. Open-core yoktur (Access D4 ile aynı yön).
Ayrıntı: §2, §19.

**MD-5 — Çalışma ortamı Elixir/OTP.** Relay Elixir/OTP üzerinde yazılır; HTTP API, realtime ve operatör paneli Phoenix ile sunulur. Ayrı realtime sunucusu yoktur. Relay edge çalışma ortamlarında (Cloudflare Workers vb.) çalışmaz.
- *Yeniden değerlendirme koşulu:* Relay'in kendi workflow ya da bekleme bileşeni çok adımlı, telafili iş yürütmek zorunda kalırsa (MD-3'ün değişmesi) ya da Postgres üstü zamanlayıcı ölçümde yetmezse dil kararı yeniden değerlendirilir.
Ayrıntı: §19.

**MD-6 — Zorunlu bileşenler PostgreSQL ve Valkey.**
1. Zorunlu bileşenler PostgreSQL ve Valkey'dir (Redis protokolüyle tam uyumlu). NATS, analitik veritabanı ve S3 uyumlu depo isteğe bağlıdır; yalnız teslim hedefi ya da kaynak adaptörüdür.
2. **Doğruluk Postgres'tedir.** Valkey asla asıl kayıt tutmaz; yalnız düğümler arası sinyal (pub/sub; yalnız "yeni bir şey var" + sıra no), hız limiti ve frekans sayaçları ve kısa ömürlü kayıtlar tutar. Postgres LISTEN/NOTIFY kullanılmaz.
3. Kaçırılan sinyal Postgres cursor'uyla telafi edilir. Valkey erişilemezse sinyaller kısa aralıklı yoklamaya, hız limiti Postgres yedek limitleyicisine düşer; "limitsiz" duruma asla düşülmez. Geçiş penceresinde iki sayaç birlikte kontrol edilir, daha katı olan uygulanır.
4. Hız limiti ve sayaçlar için tek davranış test seti hem Valkey hem Postgres arka ucunda koşar.
5. Erlang distribution isteğe bağlıdır; açılırsa yalnız TLS + sertifika kimliğiyle. Tekil sorumluluk (lider, zamanlayıcı sahibi) veritabanı tabanlıdır; BEAM kümesine bağlanmaz.
Ayrıntı: §19, §20.

**MD-7 — Yalnız açık kaynak Oban; eksikler Relay'in kendi kodu.**
1. Yalnız açık kaynak Oban (Apache-2.0) kullanılır; Oban Pro ne çekirdekte ne SaaS'ta kullanılır.
2. Oban'dan alınanlar: işin kayıtla aynı transaction'da yazılması, retry/backoff, ileri tarihli çalıştırma ve cron, kuyruk ayrımı, iş benzersizliği (yalnız ön filtre), duraklatma/sürdürme, `suspended` durumu, telemetri.
3. Relay'in kendi Apache-2.0 kodu olarak yazılanlar: küme genelinde hız limiti (GCRA, sağlayıcının `Retry-After`'ına uyumlu), kiracı adaleti (DRR; mesaj sınıfına göre öncelik; OTP asla beklemez), global eşzamanlılık sınırı, batch ve workflow takibi, bekleme noktası tablosu.
4. Kuyruk tekilliği bir optimizasyondur; garanti Relay tablolarındaki veritabanı kısıtındadır.
5. Bu bileşenler yarış koşulu, adalet ve sınır kural testleriyle doğrulanır.
Ayrıntı: §19.

**MD-8 — Yedi sabit mesaj sınıfı; şerit sınıftan türer.**
1. Sınıflar: `security` (alt türler `otp_oob` ve `email_verification`; kapatılamaz, sessiz saati deler), `transactional`, `operational`, `social` (digest'lenebilir), `marketing` (ticari ileti), `system` (kullanıcıya görünmeyen teknik iletiler), `action_required` (insandan yanıt bekleyen istekler; digest'lenemez, ertelenemez, süresi dolar, bekleme noktasına bağlanır).
2. Kiracı kategorileri bu sınıflardan birine bağlanır. Sınıf kabul anında atanır ve değişmez.
3. Şerit yalnız mesaj sınıfından türer; istekteki `priority` yalnız şerit içinde ince ayardır ve her sınıfın tavanına indirilir. Mesaj hiçbir alanla başka şeride geçemez.
4. Gönderen türü (insan / sistem / ajan) sınıftan ayrı bir alandır.
5. İşlemsel/bilgilendirme ve pazarlama şablonları birbirine dönüştürülemeyen ayrı tiplerdir.
Ayrıntı: §5, §10, §13.

**MD-9 — Fiziksel silme yoktur; saklama Access modelindedir.**
1. Relay, Access OP-73 (fiziksel silme yok) ve Access OP-74'ü (saklama ve silme modeli) aynen uygular. Veritabanında `DELETE`, `TRUNCATE` ve veri `DROP` yoktur (uygulama rolünde yetki yok + CI lint; arşiv taşıması ve iş kuyruğu istisnası madde 3'te); silme = yumuşak silme (durum + `deleted_at` + tombstone).
2. KVKK silme talebi crypto-shredding ile karşılanır: kişisel alanlar özne × saklama sınıfı başına DEK ile şifrelidir; talepte DEK imha edilir, satırlar okunamaz olarak kalır.
3. Süre ve dayanaklar Access Ek C'deki bölge × sektör tablosundan gelir. Saklama sonu yumuşak silme + crypto-shred'dir; eski bölümler soğuk arşive taşınır, imha edilmez: bölüm değiştirilemez (WORM) kopyaya aktarılır, kopya doğrulanır, sıcak kopya ancak sonra ve yalnız arşiv rolüyle kaldırılır. Tek istisna yalnız kimlik taşıyan iş kuyruğu tablolarıdır; işin sonucu kalıcı kayda yazıldıktan sonra temizlenebilir.
4. Kullanıcı yalnız arşivler ya da gizler.
Ayrıntı: §20.

**MD-10 — Bölge başına bağımsız kurulum.**
1. SaaS bölgeleri Türkiye, AB ve ABD'dir. Her bölgenin kendi Postgres'i, Valkey'i ve KMS/HSM'i vardır. Kiracı kayıtta bölge seçer; veri orada kalır. Bölgeler arası veri akışı yoktur.
2. Türkiye bölgesi yurt içi veri merkezinde ya da yerli bulutta çalışır. Regüle Türkiye kiracılarında TLS yurt dışında sonlandırılmaz.
3. Access + Relay kullanan kiracının iki ürünü aynı bölgededir.
4. Her bölge self-host paketiyle aynı paketle kurulur.
Ayrıntı: §18, §20.

**MD-11 — Ajana teslim edilen şey yapılandırılmış mesajdır.** Ajana teslim edilen şey prompt değil, yapılandırılmış mesajdır. Kontrol bilgisi (tür, bekleme no, sonuç, yanıtlayan, kanal kanıt düzeyi, iş özeti) tipli alanlarda taşınır. İnsan ya da dış sistem kaynaklı serbest metin ayrı alanda "güvenilmez içerik" işaretiyle (A2A `parts[]`, MCP `annotations.audience`) ve kaynak bilgisiyle (yazan, doğrulandı mı, kanal) taşınır. Relay ajana hiçbir zaman serbest metin talimat yazmaz.
Ayrıntı: §17.

**MD-12 — Sessiz kayıp yoktur; karar hata değildir.**
1. Gönderilmeyen her bildirim neden koduyla (`reason` + `rule_id`) kaydedilir; panelde, webhook olayında ve metrikte görünür. Kapsam uyuşmazlığı, kill switch, İYS reddi, sessiz saat, içerik tekrarı dahil her atlama bir kayıt açar.
2. Bastırma ve atlama nedenleri tek sözlüktedir.
3. Politika sonuçları kabulden (`202`) sonra karar olarak raporlanır; senkron hata yalnız doğrulama, önizleme, test ve dry-run uçlarındadır.
Ayrıntı: §9, §14.

**MD-13 — Önce sözleşme.**
1. OpenAPI 3.1 (HTTP API) ve AsyncAPI 3.x (webhook, realtime, ajan olayları) elle yazılır ve onaylanır; bağımlı kod onaydan sonra yazılır.
2. Sunucu her CI koşumunda bu belgelere karşı sözleşme testinden geçer; uyuşmazlık build'i kırar.
3. SDK'lar bu belgelerden üretilir; üstüne ince, el yazımı kullanım katmanı eklenir.
Ayrıntı: §9.

**MD-14 — Kapılar fail-closed; gevşetme bayrağı yoktur.**
1. Uyum ve güvenlik kapıları (izin, İYS, ülke kuralı, kill switch, sınıf kanal kuralları) hiçbir bayrak, kategori, öncelik ya da mesaj başına alanla (ör. ham sağlayıcı payload override'ı) atlanamaz.
2. Bir kapının girdisi doğrulanamıyorsa gönderim yapılmaz (fail-closed).
3. Uyum kurallarında kiracı yalnız sıkılaştırabilir; gevşetme bayrağı yoktur.
4. Güvenliği zayıflatan bayrak ve "dev mode" yoktur (Access OP-69 ile uyumlu).
5. Kapı ile zamanlayıcı ayrı kavramlardır: frekans tavanı gibi zamanlayıcıların davranışı ilgili bölümde ayrıca tanımlanır.
Ayrıntı: §13, §18.

**MD-15 — Doğruluk kalıcı kayıttadır; taşıma sinyaldir.**
1. Teslim durumu append-only olay defterinden hesaplanır ve yeniden kurulabilir. İç model değişse de dış sözleşme sabit kalır.
2. Push, realtime, webhook ve A2A push yalnız sinyal ve uyandırma yoludur; mesaj kalıcı kayıtta bekler. Bağlantı kopması kayıp üretmez.
3. Sıra numarası commit sırasına dayanır; teslim sırası değil okuma sırası garanti edilir.
4. Garanti dili: "at-least-once teslim + kalıcı idempotency ile etkin exactly-once işlem". "Exactly-once" ifadesi tek başına kullanılmaz.
Ayrıntı: §14, §15, §16.

**MD-16 — Müşteri kodu Relay içinde çalışmaz.**
1. Çalışma anında müşteri sunucusuna çağrı yapan bridge modeli yoktur.
2. Veri çek (fetch), veri güncelle ve başka workflow çağır adımları yoktur; gereken veri olayla gelir.
3. Kiracı dönüşüm betiği çalıştırılmaz; dönüşüm alan beyaz listesi ve CloudEvents eşlemesiyle yapılır.
4. Kiracı ve sistem şablonları Liquid ile yazılır; Elixir kodu çalıştıran şablon dili kiracı verisinde asla kullanılmaz. Koşul ve eşleme dili basit, döngüsüz bir kural dilidir.
Ayrıntı: §10, §11, §16.

**MD-17 — Türkiye birinci sınıf; uyum kuralları veridir.**
1. Uyum kuralları veri tablosudur (ülke × kanal × mesaj sınıfı × rıza türü × alıcı türü) ve her ülke için çalışır. Türkiye (6563/İYS), AB (GDPR/ePrivacy) ve ABD (CAN-SPAM, TCPA, 10DLC) satırları hazır gelir; yeni ülke satır eklenerek desteklenir. Özel satırı olmayan ülkede pazarlama için "açık onay" kuralı uygulanır. Platform kuralları (uygulama mağazası, mesajlaşma platformu) aynı tabloda ülkeden bağımsız platform satırı olarak tutulur; Relay mevzuatın ya da platform kuralının istemediği izin şartı koymaz.
2. İYS kontrolü yalnız `marketing` sınıfında ve İYS'nin tanıdığı kanallarda yapılır; kapsam kiracının bölgesi Türkiye ise ya da kiracı İYS bilgilerini girmişse geçerlidir.
3. Bir marka için İYS'ye tek yazıcı Relay'dir. Access İYS'ye hiçbir koşulda doğrudan yazmaz.
4. Hukuki izin Access bağlıyken Access'tedir; bildirim tercihleri Relay'dedir. Relay izinlerin kopyasını Access olaylarından tutar ve gönderimde Access'e sormaz.
Ayrıntı: §13.

**MD-18 — Kiracı, tek seviyeli alt kiracı ve ayrı test düzlemi çekirdektedir.**
1. Relay'in kendi kiracı modeli vardır. Alt kiracı birinci sınıf ve tek seviyelidir; tanımlamadığı ayar için kiracınınki geçerlidir ("yoksa üsttekini kullan, varsa ezme"). Bu model ücretsiz çekirdektedir.
2. Eşleşmeyen ya da tanımsız alt kiracıya giden teslim kaybolmaz; atlama olarak kaydedilir (MD-12).
3. Kiracı başına `live` ve `test` ayrı veri düzlemleridir; ortam API anahtarında taşınır; test anahtarı canlı veriye erişemez. İşleme hattının tamamı iki düzlemde aynıdır; yalnız son adımda sahte sağlayıcı adaptörü çalışır.
4. Access bağlıysa Access'in B2B organizasyonu Relay alt kiracısına otomatik eşlenir.
Ayrıntı: §18.

**MD-19 — Kimlik herhangi bir OIDC IdP'den; denetim kaydı Relay'in.**
1. Konsola giriş herhangi bir OIDC IdP ile yapılır (Access önerilir); roller ve yetkiler Relay içinde tutulur.
2. Hassas işlemler (kill switch'i yeniden açma, sağlayıcı sırrı ve anahtar rotasyonu, alıcı PII'sini açık gösterme vb.) Access bağlıysa Access step-up ister; Access yoksa bağlı IdP'den yeniden doğrulama (`max_age`/`acr`) istenir.
3. Relay kendi kurcalanmaya dayanıklı denetim kaydını (periyodik imzalı Merkle kontrol noktası) tutar; bütünlük modeli ve biçimi Access'inkiyle aynıdır. Access bağlıysa kayıtlar bağlanır.
4. Abone ve ajan jetonları dar kapsamlıdır; Relay, Access jetonunu doğrudan inbox erişimi için kabul etmez.
Ayrıntı: §17, §18.

**MD-20 — Üç ayrı tekrar koruması.**
1. **Idempotency-Key:** değişiklik yapan her istekte zorunludur; anahtarsız istek `400` ile reddedilir. Aynı HTTP isteğinin kazara tekrarına karşıdır. Relay anahtarı içerikten türetmez; SDK'lar anahtarı otomatik üretir.
2. **`dedup_key` (iş anahtarı):** bildirim kaydında benzersizdir ve bildirim saklandığı sürece geçerlidir; saatler ya da günler sonra gelen outbox retry'larını yakalar.
3. **İçerik tekilleştirme:** ayrı ve isteğe bağlı bir özelliktir.
4. Üç koruma birbirinin yerine geçmez; meşru yeni istek ("kodu tekrar gönder") yeni anahtarla gelir.
Ayrıntı: §9, §10.

### 1.8 Karar register'ı

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| MD-1 | Relay ve Access bağımsız çalışır, birlikte sürtünmesiz çalışır; dört kullanım durumu ve sürtünmesizlik kuralları | MERKEZİ KARAR | Access E40 ile aynı karar; iki ürünün ayrı kurulabilmesi ve birlikte tek ürün gibi çalışması |
| MD-2 | Relay yetki ve onay kaynağı değildir; yanıt toplayıcıdır; alıcı kümesi üreticinindir | MERKEZİ KARAR | Access E30, Access E32, Access EI-9, Access EI-18; kanal kimliği kurumsal kimlik değildir (Slack/Teams örneği) |
| MD-3 | Bekleme noktası, korelasyon ve teslim Relay'in; yürütme, checkpoint, devam ve iş telafisi bekleyenin | MERKEZİ KARAR | Access E31; dayanıklı yürütme motorlarıyla rekabet yerine onların insana ulaşma katmanı olmak |
| MD-4 | Apache-2.0; tam özellik eşitliği; SaaS farkı hizmettir; open-core yok | MERKEZİ KARAR | Access D4 ile aynı yön; sektörde güvenilirlik ayarlarının paralı katmana konması (§4.3) |
| MD-5 | Elixir/OTP + Phoenix; ayrı realtime sunucusu yok; edge çalışma ortamı yok | MERKEZİ KARAR | BEAM süreç yalıtımı ve Phoenix Channels; yeniden değerlendirme koşulu karar metninde |
| MD-6 | Zorunlu bileşenler PostgreSQL + Valkey; Valkey asıl kayıt tutmaz; düşüşte limitsize düşülmez | MERKEZİ KARAR · DAY-1 | Tek doğruluk kaynağı; çok bileşenli bağımlılık yığınından kaçınma (§4.3) |
| MD-7 | Yalnız Oban OSS; hız limiti, adalet, eşzamanlılık, batch/workflow takibi, bekleme tablosu kendi kodumuz | MERKEZİ KARAR | Açık kaynak eşitliği (MD-4); Oban unique'in veritabanı kısıtına dayanmaması |
| MD-8 | Yedi sabit mesaj sınıfı; kabulde atanır, değişmez; şerit yalnız sınıftan türer | MERKEZİ KARAR · DAY-1 | 6563, Gmail/Yahoo, TCPA, WhatsApp kategori fiyatlaması sınıfa bağlıdır |
| MD-9 | Fiziksel silme yok; crypto-shredding; saklama Access OP-73/Access OP-74 ve Access Ek C | MERKEZİ KARAR · DAY-1 | Suiss ortak kuralı (Access OP-73); 6563 m.11/3 kanıt saklama yükümlülüğü |
| MD-10 | Bölge başına bağımsız kurulum (TR, AB, ABD); bölgeler arası veri akışı yok | MERKEZİ KARAR · DAY-1 | Veri yerleşimi (KVKK, GDPR, TCMB/BDDK yurt içinde tutma; Access Ek C) |
| MD-11 | Ajana yapılandırılmış mesaj teslim edilir; güvenilmez metin ayrı alanda; serbest metin talimat yok | MERKEZİ KARAR | Dolaylı prompt injection ve onay diyaloğu sahteciliği (OWASP; Lies-in-the-Loop) |
| MD-12 | Sessiz kayıp yok; tek atlama sözlüğü; karar ≠ hata | MERKEZİ KARAR | Bağlam tam eşleşmesinin sessiz kayıp üretmesi (Novu); skip nedeni olaylarının sektörde nadirliği |
| MD-13 | OpenAPI 3.1 + AsyncAPI 3.x önce yazılır ve onaylanır; CI sözleşme testi; SDK'lar üretilir | MERKEZİ KARAR | Access ile aynı süreç (contracts first) |
| MD-14 | Uyum ve güvenlik kapıları fail-closed; bayrakla atlanamaz; kiracı yalnız sıkılaştırır; dev mode yok | MERKEZİ KARAR | 6563 ispat yükü; Access OP-69 ve Access TI-9 ile aynı ilke |
| MD-15 | Doğruluk append-only kayıtta; taşıma sinyal; okuma sırası garantisi; dürüst garanti dili | MERKEZİ KARAR | Pub/Sub exactly-once sınırları, outbox ID sırası ≠ commit sırası (§4.3) |
| MD-16 | Müşteri kodu çalışmaz: bridge, fetch/update/invoke adımı, dönüşüm betiği, kod çalıştıran şablon yok | MERKEZİ KARAR · DAY-1 | SSRF, deterministik tekrar oynatma, döngü ve RCE riski; Access F23 ile aynı ilke |
| MD-17 | Uyum kuralları ülke ve platform satırlı tablo; İYS yalnız `marketing` ve kapsamda; İYS'ye tek yazıcı Relay; izin Access'te, tercih Relay'de | MERKEZİ KARAR | 6563 ve İYS mevzuatı; Access IDP-37 ve Access B23 ile birlikte |
| MD-18 | Kendi kiracı modeli; tek seviyeli alt kiracı çekirdekte; `live`/`test` ayrı düzlem, aynı hat | MERKEZİ KARAR · DAY-1 | Kiracı özelliklerinin rakiplerde paralı katmanda olması (Knock Enterprise) |
| MD-19 | Operatör girişi herhangi bir OIDC IdP; roller Relay'de; hassas işlemde step-up; Merkle kontrol noktalı denetim kaydı | MERKEZİ KARAR | MD-1 bağımsızlık; Access denetim kaydı biçimiyle uyum |
| MD-20 | Idempotency-Key zorunlu; `dedup_key` bildirim ömrü boyunca; içerik tekilleştirme ayrı | MERKEZİ KARAR | Access OP-63 ile aynı kural; kısa dedup pencerelerinin uzun retry'larla tutarsızlığı (Ably, NATS) |
