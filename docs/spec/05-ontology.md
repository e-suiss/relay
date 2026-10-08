## 5. Ontoloji (kanonik kavramlar)

Bu bölüm Relay spec'inin bütün bölümlerinde kullanılan ortak terimleri tanımlar. Her kavramın bir Türkçe adı, bir kod adı (API, şema, olay ve kod içinde kullanılan ad) ve tek bir anlamı vardır. **Terim ve kod adlarında bu bölüm kanoniktir;** başka bir bölüm aynı kavrama farklı ad veremez, farklı anlam yükleyemez. Kavramların kuralları ve sayısal değerleri ilgili bölümdedir; burada yalnız anlam, kimlik, sahiplik ve diğer kavramlarla ilişki sabitlenir.

Ontoloji kararları "C-*n*" biçimindedir. C-1…C-8 ontoloji ilkeleridir (§5.1); C-9 ve sonrası kavram tanımlarıdır (§5.2–§5.13). Kayıt tablosu §5.16'dadır.

**Okuma kuralı.**
1. Bir kavramın tanımı ile o kavramı işleyen bölümün ayrıntısı çelişirse tanım (bu bölüm), kural ve değer ise ilgili bölüm kazanır.
2. Değişmezler (§6) ontolojinin üzerindedir: bir kavramın tanımı hiçbir değişmezi gevşetemez.
3. Kod adları İngilizce, `snake_case`'tir. Durum değerleri küçük harftir. Olay adları `noun.verb_past` biçimindedir (§5.14).

### 5.1 Ontoloji ilkeleri (C-1–C-8)

| ID | İlke | Açıklama |
|---|---|---|
| **C-1** | **Relay'in nesnesi mesaj ve teslimdir.** | Relay bir olayı ya da isteği alır, kime hangi kanaldan ne zaman gideceğine karar verir, teslim eder ve teslimin gerçekte ne olduğunu kaydeder. Olayın anlamı, içeriğin doğruluğu ve "kime, neden" üreticinindir (C-18). Relay bunları taşır, sahiplenmez. |
| **C-2** | **Kanonik olan append-only kayıtlardır; durumlar türetilir.** | Teslim defteri (C-32), bekleme kaydı (C-72), posta kutusu (C-68) ve denetim kaydı (C-87) yerinde değiştirilmez. Teslim durumu, sayaçlar, rozet ve raporlar bu kayıtlardan hesaplanır ve yeniden kurulabilir. Türetilmiş durum kayda baskın gelemez. |
| **C-3** | **Bildirim → teslim → deneme üç ayrı seviyedir.** | Bildirim (C-29) bir alıcı için mantıksal mesajdır ve bir kez oluşur. Teslim (C-30) o bildirimin bir kanal × hedef (adres ya da cihaz) için gönderimidir. Deneme (C-31) bir teslim için sağlayıcıya yapılan tek çağrıdır. Bu üç seviye hiçbir kayıtta birleşmez. "Gönderildi mi?" sorusu "sağlayıcı 200 döndü mü?" sorusu değildir. |
| **C-4** | **Karar hata değildir.** | Politika sonucu (atlandı, ertelendi, bastırıldı, süresi doldu) bir karardır (C-59); kabul edilmiş istekte senkron hata olarak dönmez, neden koduyla kaydedilir ve raporlanır. Senkron hata yalnız geçersiz istek, yetki, kota ve önizleme/test/dry-run uçlarında vardır. |
| **C-5** | **İzin tercih değildir.** | İzin (C-60) hukuki kayıttır: kaynak, kanıt, metin sürümü, zaman. Tercih (C-61) kullanıcının bildirim arzusudur. İkisi ayrı kayıtlarda tutulur ve birbirine dönüştürülmez: tercihi açmak izin vermek değildir, izni geri çekmek tercih kaydı değildir. |
| **C-6** | **Üç bağımsız eksen: sınıf, kategori, gönderen türü.** | Mesaj sınıfı (C-33) hukuk ve öncelik eksenidir, sabittir. Kategori (C-35) ürün eksenidir, kiracı tanımlar ve bir sınıfa bağlanır. Gönderen türü (C-24) bildirimi kimin ürettiğini söyler (insan, sistem, ajan). Hiçbiri öbüründen türetilmez. |
| **C-7** | **Teslim yetki değildir.** | Hiçbir Relay kaydı (teslim, ack, okundu, yanıt, bekleme çözümü) yetki durumu değildir ve yetki durumunu değiştirmez (Access EI-9, Access E30). Kanal üzerinden gelen yanıt onay değildir (Access EI-18). |
| **C-8** | **Bekleme bir kayıttır, çalışan iş değildir.** | Bekleme noktası (C-72), bekleme adımı, digest penceresi ve tekrar kuralı veritabanında bir satır + zamanlayıcıdır; kuyruk yuvası, süreç veya bellek tutmaz. Relay dayanıklı yürütme motoru değildir (§7.5). |

### 5.2 Kurulum, kiracılık ve kapsam

| ID | Türkçe ad | Kod adı | Tanım ve kurallar |
|---|---|---|---|
| **C-9** | Kurulum | `installation` | Tek bir Relay dağıtımı: bir SaaS bölgesi ya da bir self-host kurulumu. Kod ve paket her kurulumda aynıdır; fark yalnız işletimdedir. Her kurulumun bir kurulum operatörü (C-15) vardır. |
| **C-10** | Bölge | `region` | Verinin fiziksel olarak tutulduğu ve işlendiği bağımsız kurulum. SaaS bölgeleri `tr`, `eu`, `us`'tir. Her bölgenin kendi veritabanı, önbelleği ve anahtar altyapısı vardır; bölgeler arası veri akışı yoktur. Kiracı bölgeyi kayıtta seçer; verisi o bölgede kalır. |
| **C-11** | Kiracı | `tenant` | Relay'i kullanan müşteri hesabı: API anahtarları, ayarlar, sağlayıcı bağlantıları, şablonlar, workflow'lar, alıcılar ve bütün kayıtlar bir kiracıya aittir. İzolasyon birimi kiracıdır (§6.6). Kiracının zorunlu kurulum alanları `default_timezone` ve `default_locale`'dir; sistem varsayılanı yoktur. Kiracı durumu `active`, `suspended`'dır; `suspended` bütün giriş noktalarında etkilidir. |
| **C-12** | Alt kiracı | `sub_tenant` | Kiracının kendi müşterisini ya da markasını temsil eden, tek seviyeli, birinci sınıf nesne. Tuttukları: marka (logo, renk, şablon varyantı), gönderici kimlikleri (C-25), kanal kimlikleri (C-26), isteğe bağlı kendi sağlayıcı bağlantısı, tercih varsayılanları, inbox kapsamı. **Miras:** alt kiracının tanımlamadığı ayar için kiracınınki geçerlidir; tanımladığı ayar kiracınınkini ezer. Alt kiracının alt kiracısı yoktur. Eşleşmeyen ya da tanımsız alt kiracıya giden teslim kaybolmaz; `scope_mismatch` nedeniyle atlanır ve görünür. |
| **C-13** | Ortam | `environment` | Kiracı içindeki ayrı veri düzlemi: `live` ya da `test`. Ortam API anahtarında taşınır; istek gövdesiyle değiştirilemez. İki ortam aynı işleme hattını çalıştırır; `test` ortamında yalnız son adımda sahte sağlayıcı adaptörü çalışır ve sanal saat yalnız `test`'te vardır (§8, §9). |
| **C-14** | Operatör | `operator` | Relay paneline ya da yönetim API'sine giriş yapan insan. Kimliği bir OIDC IdP'den gelir (Access önerilir); roller ve yetkiler Relay içinde tutulur (§18). Operatörün her yönetim eylemi denetim kaydına girer. |
| **C-15** | Kurulum operatörü | `installation_operator` | Kurulumun kendisini yöneten taraf: SaaS'ta hizmeti işleten, self-host'ta kurumun kendi Relay yöneticisi. Kiracının tek başına açamadığı yetenekleri (ör. `critical` öncelik izni, §12) onaylar. Kod iki durumda aynıdır. |
| **C-16** | API anahtarı | `api_key` | Kiracı backend'inin Relay'e kimliğini kanıtladığı sır. Bir kiracıya ve bir ortama değişmez biçimde bağlıdır; kapsamları vardır (yayın ve okuma ayrı, §9). Sır yalnız oluşturma anında bir kez gösterilir. İstemci (tarayıcı, mobil) API anahtarı taşımaz. |
| **C-17** | Abone jetonu | `subscriber_token` | Son kullanıcı istemcisinin (tarayıcı, mobil, bileşen) yalnız kendi inbox'ına ve tercihlerine erişmesini sağlayan kısa ömürlü, dar kapsamlı jeton (`inbox:read`, `inbox:write`, `preferences`). Relay basar; kiracı backend'i ister ya da Access bağlıysa token exchange ile alınır (§7.3.6). İzinli realtime akışları jetonda yazılıdır. |
| **C-18** | Üretici | `producer` | Relay'e olay gönderen ve isteğe bağlı olarak üretici sahipli şablon (C-55) yayımlayan ürün ya da sistem (ör. Access, başka bir Suiss ürünü, entegre bir sistem). İçerik, "kime" ve "neden" üreticinindir. Access, Relay'de diğer kiracılardan yalıtılmış bir **platform kiracısı** olarak çalışır (kendi gönderen alan adı, ayrı izlenen itibar; Access E40). |

### 5.3 Alıcılar, adresler ve gönderenler

| ID | Türkçe ad | Kod adı | Tanım ve kurallar |
|---|---|---|---|
| **C-19** | Alıcı | `recipient` | Bir bildirimin hedefi olan varlık. Üst türdür; iki alt türü vardır: abone (C-20) ve ajan alıcı (C-21). Kiracı içinde kiracının verdiği dış kimlikle (`external_id`) tekildir. |
| **C-20** | Abone | `subscriber` | İnsan alıcı kaydı: profil, iletişim adresleri (C-22), cihazlar (C-23), saat dilimi ve yerel, hukuki tür (C-27), tercihler, izinler, inbox. Alıcı ilk gönderimde yoksa yalnız çağrı alıcı bilgisini açıkça taşıyorsa oluşturulur (açık upsert); yalnız kimlik verilmişse `recipient_not_found` döner, hayalet alıcı oluşturulmaz (§9). Yalnız inbox kullanan abone kimlikle açıkça oluşturulabilir; adresi kimliğinin kendisidir. Access bağlı kiracıda `external_id` Access'in kiracıya özgü (pairwise) `sub` değeridir. |
| **C-21** | Ajan alıcı | `agent` | Bildirim, olay ve yanıt alan yazılım ajanı kaydı: ad, teslim uçları, posta kutusu, topic abonelikleri, sahibi. Access bağlıysa Access'teki ajan kimliğine (Party/Instance) bağlanır; kimlik ve yetki doğruluğu Access'tedir (§7.3.8). Ajan alıcı bir insan abonenin yerine geçmez; ajan kutusu insanın iş/onay kuyruğu değildir. |
| **C-22** | Adres | `address` | Bir abonenin bir kanaldaki iletişim noktası: e-posta adresi, telefon numarası (E.164), mesajlaşma platformu kullanıcı kimliği. Adres kişisel veridir; şifreli saklanır, arama için anahtarlı özetle (kör indeks) bulunur. Bastırma (C-62) adres düzeyindedir. |
| **C-23** | Cihaz | `device` | Push hedefi: platform (APNs, FCM, Web Push), jeton, uygulama, OS bildirim izni durumu (`granted`, `denied`, `provisional`, `not_determined`), Android kanal önemi, son etkinlik. Jeton tek bir aboneye bağlıdır; aynı jeton iki abone adına kullanılmaz. Ölü jeton yumuşak silinir; jeton silinmesi ya da OS izninin kapanması tercihi silmez. |
| **C-24** | Gönderen türü | `sender_type` | Bildirimi kimin ürettiği: `human`, `system`, `agent`. Mesaj sınıfından ayrı bir alandır (C-6). `agent` türündeki bildirimler ajan tavanına (C-78) tabidir ve arayüzde ajan kaynaklı olarak gösterilir. |
| **C-25** | Gönderici kimliği | `sender_identity` | Kiracının ya da alt kiracının gönderen olarak görünen kimliği: e-posta gönderim alan adı ve adresi, SMS başlığı, WhatsApp işletme numarası. Tipi, ülkesi, kayıt/onay durumu ve doğrulama kuralları vardır. Onaysız gönderici kimliğiyle gönderim yapılmaz (§12). |
| **C-26** | Kanal kimliği | `channel_identity` | Kiracının ya da alt kiracının bir platformdaki uygulama kimliği: Apple team / bundle, Firebase projesi, VAPID anahtar çifti (her web uygulaması kendi anahtar çiftini taşır), mesajlaşma platformu uygulaması. Kimlik bilgileri sır arka ucunda tutulur, veritabanında yalnız referans durur. |
| **C-27** | Hukuki alıcı türü | `legal_type` | Alıcının ticari ileti mevzuatı karşısındaki türü: `individual` (bireysel) ya da `merchant` (tacir/esnaf). Uyum tablosunun girdisidir (C-64); tacir/esnafa ticari iletide önceden onay aranmaz, ret kaydedilir ve uyulur (§13). |

### 5.4 Giriş, bildirim ve mesaj semantiği

| ID | Türkçe ad | Kod adı | Tanım ve kurallar |
|---|---|---|---|
| **C-28** | Olay | `event` | Relay'e giren, "bir şey oldu" bilgisi. Relay API'si (`POST /v1/events`) ya da CloudEvents HTTP bağlamasıyla gelir. Olay türü (`event_type`) bir workflow'a eşlenir. Olay verisinin şeması (JSON Schema 2020-12) workflow sürümüne aittir. CloudEvents girişinde `(tenant, source, id)` tekrar kontrol anahtarıdır; `traceparent` uçtan uca taşınır. Olay verisi önceden biçimlendirilmiş değer taşımaz (`{amount, currency}`, ISO 8601). |
| **C-29** | Bildirim | `notification` | Bir olayın ya da doğrudan gönderim isteğinin bir alıcı için ürettiği mantıksal mesaj. Bir alıcı için bir kez oluşur. Oluşurken planı sabitlenir (C-46), `dedup_key`'i (C-80) donar, mesaj sınıfı atanır. Durumu `cancelled` olabilir; iptal tetiklemeyle aynı sıralı anahtardan işlenir. |
| **C-30** | Teslim | `delivery` | Bir bildirimin bir kanal × hedef (adres ya da cihaz) için gönderimi. Fallback zinciri yeni teslim açar; önceki teslime bağlıdır. Teslim tekilliği `(notification_id, recipient, channel)` defter anahtarıyla sağlanır (C-82). |
| **C-31** | Deneme | `attempt` | Bir teslim için sağlayıcıya yapılan tek çağrı. Durumları `pending`, `in_flight`, `succeeded`, `failed`, `unknown`'dır; `unknown` birinci sınıftır (istek gitti, sonuç gelmedi). Terminal deneme durumu ezilmez. |
| **C-32** | Teslim olayı | `delivery_event` | Teslim defterinin append-only satırı: kim (Relay, sağlayıcı API'si, sağlayıcı webhook'u, kullanıcı, istemci SDK'sı), ne (normalleştirilmiş olay + ham sağlayıcı kodu), ne zaman oldu (`occurred_at`), ne zaman alındı (`received_at`). Teslim durumu bu defterden türetilir (C-2). |
| **C-33** | Mesaj sınıfı | `message_class` | Yedi sabit üst sınıf: `security`, `transactional`, `operational`, `social`, `marketing`, `system`, `action_required`. Sınıf kabul anında atanır ve değişmez. Şerit, öncelik tavanı, digest/erteleme izni, tercih kapatılabilirliği, İYS kapsamı, takip izni ve saklama sınıfı ondan türer (§10, §13). `action_required` insandan yanıt bekleyen isteklerdir (ajan soruları, iş akışı yanıtları, CIBA daveti): digest'lenemez, ertelenemez, süresi dolar, bekleme noktasına bağlanır. `system` kullanıcıya görünmeyen teknik iletilerdir. |
| **C-34** | Güvenlik alt türü | `security_subtype` | `security` sınıfının OTP alt türleri: `otp_oob` (ikinci faktör / ayrı kanal kodu; yalnız SMS, WhatsApp, sesli arama) ve `email_verification` (e-postayla giriş, adres doğrulama, kurtarma; yalnız e-posta). Seçimi gönderen yapar; Relay seçilen alt türün kanal kurallarını uygular (§12). |
| **C-35** | Kategori | `category` | Kiracının tanımladığı ürün kategorisi (ör. "sipariş", "yorum", "kampanya"). Tam olarak bir mesaj sınıfına bağlanır ve sınıfı değiştirmez. Varsayılan rotası (C-42), tercih varsayılanları, frekans politikası, saklama süresi ve `locked` (kullanıcı kapatamaz) bayrağı vardır. Kilitli kategoride en az bir kanal açık kalır. |
| **C-36** | Şerit ve öncelik | `lane`, `priority` | Şerit, işin kuyrukta hangi kapasite bölümünden geçtiğidir ve yalnız mesaj sınıfından türer; hiçbir istek alanı mesajı başka şeride taşıyamaz. `priority: low \| normal \| high` yalnız şerit içinde ince ayardır ve sınıfın tavanına indirilir. Platform önceliği (iOS interruption level, Android kanal önemi, FCM priority, Web Push `Urgency`) sınıf + ince ayar ikilisinden tek bir eşleme tablosuyla türer (§12). |
| **C-37** | Konu | `subject` | Bildirimin ilgili olduğu iş nesnesi: `{type, id}` (ör. `{order, 123}`). Aynı konunun bildirimleri birbirini günceller (collapse, digest, inbox öğesi; C-69); giden olaylarda sıra numarası konu başınadır (§16). Collapse anahtarı `{tenant, subject.type, subject.id, message_class}` özetidir. |
| **C-38** | Kampanya | `campaign` | Büyük bir alıcı kümesine (liste ya da topic) tek seferde hazırlanıp tetiklenen gönderim. "Hazırla, sonra tetikle" modeli: hazırlıkta alıcı listesi dondurulur, render ve `dedup_key`'ler üretilir; tetikte yalnız gönderim yapılır. Hız sınırlı kampanya bir son teslim tarihi taşır (§10). Kill switch kapsamlarından biridir. |
| **C-39** | Son kullanma | `expires_at` | Bildirimin anlamını yitirdiği an. `security` OTP alt türlerinde zorunludur ve gönderenden gelir; diğer sınıflarda kategori varsayılanı geçerlidir. Kanal TTL'leri (APNs, FCM, Web Push, SMS geçerlilik süresi) `expires_at − now` ile türer. Süresi geçen bildirim `expired` (terminal) olur ve nedenle kaydedilir. |

### 5.5 Akış ve yönlendirme

| ID | Türkçe ad | Kod adı | Tanım ve kurallar |
|---|---|---|---|
| **C-40** | Workflow | `workflow` | Bir olay türünün bildirime nasıl dönüşeceğini tanımlayan sürümlü adım dizisi. "Bildirim türü" kullanıcıya görünen adıdır (tercih seviyelerinden biri, §13). Üç eşit yazım yolu (görsel editör, dosya, SDK) aynı tanım biçimine çıkar. Her workflow'un tek yöneticisi vardır: `managed_by: panel \| code`. Çalışma anında müşteri koduna çağrı yoktur. Yayınlanmış sürüm değişmez. |
| **C-41** | Adım | `step` | Workflow'un bir öğesi. Sekiz tür vardır: `channel` (kanal gönderimi; rota seçilebilir), `delay` (süre ya da saate kadar bekleme), `digest`, `throttle`, `condition` (basit kural dili), `wait_for_event` (süre sınırlı olay bekleme; bekleme noktasıyla aynı yapı taşı), `time_window` (zaman penceresi), `webhook`. Veri çekme, veri güncelleme ve başka workflow çağırma adımı yoktur (§10). |
| **C-42** | Rota politikası | `route` | Adlandırılmış, yeniden kullanılabilir kanal seçim politikası. İç içe `single` / `all` düğümlerinden oluşan bir ağaçtır. Stratejiler: `fallback` (sırayla dene), `fanout` (hepsine gönder), `last_active` (son aktif kanal ya da cihaz), `user_preference` (kullanıcı tercihi); isteğe bağlı "görülmezse yükselt" kuralı. Her kategori varsayılan bir rotaya bağlanır; adım başka rota seçebilir. Öncelik tek yönlüdür: adım > kategori. |
| **C-43** | Kanal | `channel` | Bir teslim türü: `push`, `email`, `sms`, `whatsapp`, `voice`, `in_app`, `webhook` ve mesajlaşma uygulaması kanalları. Kanal kataloğu, yetenek bayrakları ve kanal başına teslim semantiği §12'dedir. `webhook` kanalı kiracının kendi müşterilerine imzalı olay teslimidir (C-83). |
| **C-44** | Sağlayıcı | `provider` | Bir kanalın taşımasını yapan dış hizmet (ESP, SMS işletmecisi/toplayıcısı, APNs, FCM, WhatsApp Business Platform, kiracının kendi MTA'sı). Relay taşıma katmanının yerini almaz, onu kullanır. Sağlayıcı kataloğu, hata kodu eşlemesi, fiyat ve limit tabloları koddur değil veridir. |
| **C-45** | Sağlayıcı bağlantısı | `provider_account` | Bir kiracının (ya da alt kiracının) bir sağlayıcıya erişimi: kimlik bilgisi referansı, doğrulama durumu (gönderici kimliği tescilli mi, alan adı hizalı mı), veri yerleşimi ve aktarım meta verisi, sağlık durumu. Paylaşılan (kurulumun) ya da kiracının kendi hesabı olabilir. Yalnız doğrulanmış bağlantıya trafik gider. |
| **C-46** | Sabitlenmiş plan | `plan` | Bildirim oluşurken donan karar girdileri: şablon/layout/parça sürüm kümesi, adres çözümlemesi, deney varyantı, `dedup_key`. Kapılar (C-58) her denemede yeniden değerlendirilir; plan değişmez. Sabitlenmiş sürüm gönderilemiyorsa sessizce yeni sürüme geçilmez. |
| **C-47** | Eskalasyon politikası | `escalation_policy` | Süreye bağlı kademeler: her kademede yeni alıcı ve/veya daha müdahaleci kanal. Son kademe yalnız `waitpoint.expired` olayıdır; otomatik kabul/ret kararı sahibindedir. Kanal yükseltmesiyle aynı zamanlayıcı mekanizmasını paylaşır (§10, §17). |
| **C-48** | Digest | `digest` | Belirli bir pencerede biriken olayları tek bildirimde toplayan adım: `mode: fixed \| sliding \| scheduled`, `debounce`, `max_wait`, `schedule` (abone saat diliminde), `max_items`, `leading`. Önce biriktirir, sonra planlar; boş digest gönderilmez; tek olaylı digest olayın kendisidir (§10). |
| **C-49** | Throttle | `throttle` | Bir anahtar için pencere başına gönderim eşiği koyan adım. Anahtar kiracı genelidir; bu yüzden workflow'lar arası throttle mümkündür. |
| **C-50** | Frekans tavanı | `frequency_cap` | Kategori × kanal politikası olarak tanımlı kullanıcı başına gönderim tavanı; global kullanıcı tavanı her zaman tanımlıdır. Bir zamanlayıcıdır (C-58), kapı değildir; tavana takılanın kaderi (`drop`, `defer`, `digest`, `inbox_only`) politikada açıkça yazılır. Throttle, frekans tavanı ve teslim hızı ayrı kavramlardır. |
| **C-51** | Topic ve abonelik | `topic`, `subscription` | Topic adlandırılmış bir abone kümesidir; en fazla iki seviye hiyerarşisi vardır. Abonelik bir alıcının topic'e bağıdır. Fanout anında abone listesi dondurulur; aynı alıcı birden çok yoldan abone olsa da tek bildirim alır. Eşleşme joker ya da bağlam eşleşmesine dayanmaz. Topic ajan aboneliklerinin ve Access olay aboneliğinin de temelidir. Segment (öznitelik sorgulu kitle) Relay kavramı değildir. |
| **C-52** | Tekrar kuralı | `schedule` | Bir alıcı ya da topic için RRULE mantığıyla yazılmış, alıcının yerel saatine göre çalışan tekrar. Tanım olarak saklanır; her tekrar zamanı gelince o anki yayındaki sürümle oluşturulur. Her an iptal edilebilir. |
| **C-53** | Deney | `experiment`, `variant` | Gönderim adımında 2–10 ağırlıklı varyant. Bölme birimi kullanıcıdır ve deterministiktir. Seçilen varyant sabitlenmiş plana yazılır. |

### 5.6 İçerik ve yerelleştirme

| ID | Türkçe ad | Kod adı | Tanım ve kurallar |
|---|---|---|---|
| **C-54** | Şablon | `template` | Bir adımın işaret ettiği içerik: kanal × yerel matrisi, sürümlü, değişmez yayınlanmış sürümler. İki tipten biridir: `transactional` (işlemsel/bilgilendirme) ya da `marketing`; tipler birbirine dönüştürülemez. Değişkenleri yayında olay şemasına karşı doğrulanır. Bir kanalın varyantı yoksa o kanala gönderilmez. |
| **C-55** | Üretici sahipli şablon | `producer_template` | Bir üreticinin (C-18) API ile yayımladığı şablon. Metin ve çeviriler üreticinindir; kiracı yalnız üreticinin izin verdiği marka alanlarını (logo, renk, gönderen adı, alt bilgi) değiştirir (Access X35, Access X39). Kanala göre render Relay'indir. |
| **C-56** | Layout, parça, marka | `layout`, `partial`, `brand` | Layout kiracı ya da alt kiracı başına sürümlü çerçevedir (üst kısım, logo, alt bilgi, stil). Parça adlandırılmış, sürümlü bloktur; başka parça çağıramaz. Marka değişkenleri (`brand.*`) tek yerde tutulur ve alt kiracıda miras kuralına uyar. Sürümler gönderim başında sabitlenir. |
| **C-57** | Yerel ve saat dilimi | `locale`, `timezone` | Yerel BCP 47 etiketidir; saat dilimi IANA adıdır. İkisinin de çözüm zinciri vardır ve en sonda zorunlu kiracı varsayılanı bulunur; sistem varsayılanı yoktur (§10, §11). Veritabanı yalnız UTC saklar; yerel saat hesabı yalnız uygulamada yapılır. |

### 5.7 Politika ve karar

| ID | Türkçe ad | Kod adı | Tanım ve kurallar |
|---|---|---|---|
| **C-58** | Politika kafesi | `policy_lattice` | Her teslimin geçtiği sıralı değerlendirme: **kapı** (`gate`) → **filtre** (`filter`) → **zamanlayıcı** (`shaper`). Kapı mutlak engeldir (bastırma, ret, İYS onayı yok, kill switch, ölü kanal, kapsam uyuşmazlığı); hiçbir bayrak, kategori ya da istek alanıyla atlanamaz. Filtre tercihe ve politikaya göre eler (tercih kapalı, kanal varyantı yok, izin yok). Zamanlayıcı gönderimi kaydırır ya da birleştirir (sessiz saat, yasal pencere, frekans tavanı, jitter, hız limiti). Her sonuç bir karardır (C-59). |
| **C-59** | Karar ve karar nedeni | `decision`, `reason`, `rule_id` | Kafesin bir teslim için ürettiği sonuç (`send`, `skip`, `defer`, `digest`, `expire`, `cancel` vb.) ve onu üreten kuralın kimliği. Bütün nedenler tek bir `rule_id` sözlüğündedir. Gönderilmeyen her bildirim neden koduyla kaydedilir; panelde, giden olayda (`notification.suppressed`) ve metrikte görünür (§14). |
| **C-60** | İzin | `consent` | Ticari ileti için hukuki onay ya da ret kaydı: kanal, marka, kaynak, kanıt, metin sürümü, zaman. Durumlar `none`, `granted`, `revoked`'dır; `none` ≠ `revoked`. Kanıtsız onay yazılamaz. Access bağlıysa izin Access'te tutulur ve Relay olaylardan kopyasını alır (§7.3.4). İzin anahtarı `(marka, kanal, alıcı)`'dır; yalnız alıcı değildir. |
| **C-61** | Tercih | `preference` | Kullanıcının bildirim arzusu. Değeri üç durumludur: `opt_in`, `opt_out`, `unset` (`unset` kategori varsayılanına düşer). Dört seviyesi vardır: kategori × kanal, bildirim türü (workflow), tek nesne sessize alma (`scope_key`), haftalık uygunluk programı. Çakışmada VE mantığı geçerlidir. Koşullu tercih yoktur. |
| **C-62** | Bastırma | `suppression` | Bir adrese ya da cihaza gönderimi engelleyen kiracı düzeyindeki kayıt: hard bounce, şikâyet, geçersiz adres, tekrarlanan soft bounce, manuel. Kalıcı nedenler süre alamaz. Tanımlayıcının anahtarlı özeti olarak tutulur ve özne silmesinde imha edilmez (§13, §20). |
| **C-63** | Sessiz saat ve yasal pencere | `quiet_hours`, `legal_window` | Sessiz saat kullanıcının seçtiği gönderim dışı zamandır; yasal pencere bir ülkenin mevzuatının izin verdiği gönderim aralığıdır (ör. ABD TCPA 08:00–21:00). İkisi ayrıdır; kiracı yasal pencereyi kapatamaz. `security` sınıfı sessiz saati deler. |
| **C-64** | Uyum kuralı | `compliance_rule` | Ülke × kanal × mesaj sınıfı × rıza türü × hukuki alıcı türü satırlarından oluşan veri tablosu. Kiracı yalnız sıkılaştırabilir. Özel satırı olmayan ülkede pazarlama için "açık onay" uygulanır (§13). |
| **C-65** | Kill switch | `kill_switch` | Tek model: kapsam (platform, kiracı, alt kiracı, kampanya, workflow, API anahtarı, gönderici kimliği) × hedef (kanal, sağlayıcı, şablon) × mesaj sınıfı × durum (`on`, `off`, `canary`, `paused_until`). Engellenen iş `PAUSED` olur (silinmez, hata sayılmaz, otomatik yeniden denenmez); resume'da kafes yeniden çalışır; iptal ayrı, açık ve denetim kayıtlı operatör eylemidir. `reason` zorunludur. `security` varsayılan olarak durdurulmaz (§18). |
| **C-66** | Hata sınıfı | `failure_class` | Sağlayıcı sonucunun normalleştirilmiş sınıfı: `transient`, `permanent_target`, `permanent_content`, `policy`, `quota`, `auth`, `sender_config`, `unknown`. Retry, fallback, adres devre dışı bırakma ve devre kesici ağırlığı bu sınıftan türer. Eşleme sürümlü veridir; bilinmeyen kod `unknown` olur ve alarm üretir (§12). |
| **C-67** | Teslim durumu ve etkileşim | `delivery_status`, `engagement` | İçeride dört eksen vardır: deneme, teslim (monoton), hata türü, etkileşim; hepsi defterden hesaplanır. Dışarıya sade projeksiyon verilir: teslim durumu (`queued`, `sent`, `delivered`, `failed`, `skipped`, `unknown_pending`, `unknown`, `expired`, `cancelled`), etkileşim (`seen`, `read`, `clicked`, `archived`), neden (`reason` + `rule_id`). İç model değişse de dış sözleşme sabittir (§14). |

### 5.8 Posta kutusu, inbox ve realtime

| ID | Türkçe ad | Kod adı | Tanım ve kurallar |
|---|---|---|---|
| **C-68** | Posta kutusu | `mailbox` | Alıcı başına sıra numaralı kalıcı kayıt + cursor + outbox. İnsan inbox'ı ve ajan posta kutusu bu ortak çekirdeğin iki yüzüdür. **İnsan yüzü:** görüldü, okundu, arşiv, gizle. **Ajan yüzü:** kiralama (`lease`) → onay (`ack`); ack süresi içinde gelmezse yeniden teslim. Push, webhook ve A2A push yalnız "uyan" ipucudur; mesaj kutuda bekler. |
| **C-69** | Inbox öğesi | `inbox_item` | İnsan posta kutusundaki öğe; "konu + etkinlikler" modelindedir: aynı konudaki yeni etkinlik yeni öğe açmaz, mevcut öğeyi günceller (`activity_count`, son aktörler). Gönderildiği andaki render'ı gösterir. Kullanıcı öğeyi silemez; arşivler ya da gizler. Ek alanlar: erteleme (snooze), önem (`severity`), etiket/kategori. |
| **C-70** | Duyuru | `announcement` | Kiracı ya da alt kiracı geneline yayımlanan inbox içeriği. Kişi başına satır yazılmaz; okuma anında kişisel inbox ile birleştirilir. |
| **C-71** | Akış ve cursor | `stream`, `epoch`, `seq`, `cursor` | Sıralı olay akışı (inbox, posta kutusu, realtime yayın, giden olay). Her öğe `(stream, epoch, seq)` taşır; `seq` commit sırasına dayanır, akış başına monotondur. İstemci `since=seq` ile kaçırdıklarını alır. `epoch` değişirse istemci baştan senkronize olur. Garanti edilen teslim sırası değil okuma sırasıdır (§15). |

Rozet (`badge`) sunucuda hesaplanan, sürümlü, mutlak sayıdır; kiracı uygulama başına `unseen` (varsayılan) ya da `unread` saymayı seçer; sunucu iki sayacı da tutar. Rozet ayrı bir kavram değil posta kutusu projeksiyonudur (C-2).

### 5.9 Ajan tarafı ve bekleme

| ID | Türkçe ad | Kod adı | Tanım ve kurallar |
|---|---|---|---|
| **C-72** | Bekleme noktası | `waitpoint` | "Şu anahtara yanıt bekleniyor, son tarih X" kaydı. Alanları: bekleyen taraf, korelasyon anahtarı (C-73), beklenen yanıt şeması, son tarih (zorunlu; ilk kayıtta kalıcı), isteğe bağlı heartbeat süresi, isteğe bağlı beyan edilmiş varsayılan yanıt, isteğe bağlı eskalasyon politikası, durum. Durum kümesi en az açık, çözüldü, süresi doldu, iptal ve sahipsiz (heartbeat kesildi) ayrımını içerir (§17). Tek seferlik çözülür; çözülmüş bekleme değişmez. Executor'a özel değildir; her ajan sistemi ve müşteri kodu kullanır. |
| **C-73** | Korelasyon anahtarı | `correlation_key` | Bekleme noktasını gelen olay ya da yanıtla eşleyen anahtar. Eşleme iki aşamalıdır: kiracı + olay türü + korelasyon anahtarı ile birebir eşleşme, sonra isteğe bağlı ek koşul (workflow koşul adımıyla aynı kural dili). |
| **C-74** | Yanıt | `response` | Bir bekleme noktasını ya da karar isteğini çözen girdi: değer, yanıtlayan, kanal, kanal kanıt düzeyi, zaman, işin özetine bağ. Kanal kanıt düzeyi (`evidence_level`) `channel_claim` (yalnız kanal iddiası), `relay_session` (Relay abone oturumu) ya da `access_aas_ref` (Access onay yüzeyi kaydına referans) değerlerinden biridir. API'de alan adı `response` ya da `decision`'dır, `approval` değildir. Yanıt onay değildir (C-7). |
| **C-75** | Etkileşim türü | `interaction_kind` | Ajan ya da iş akışı kaynaklı bildirimin tipi: `notify` (bilgi; yanıt yok), `question` (belirsizlik giderme), `review` (eylem öncesi karar isteği). Yanıt beklentisi, son kullanma, yapılandırılmış eylemler ve kanıt paketi alanı türle birlikte tanımlanır (§17). Sonuç sınıfı ve risk kademesi Relay'de üretilmez, sahibinden etiket olarak gelir. |
| **C-76** | Yapılandırılmış mesaj | `agent_message` | Ajana teslim edilen birim. Kontrol bilgisi (tür, bekleme no, sonuç, yanıtlayan, kanal kanıt düzeyi, iş özeti) tipli alanlardadır. İnsan ya da dış sistem kaynaklı serbest metin ayrı alanda "güvenilmez içerik" işaretiyle ve kaynak bilgisiyle (yazan, doğrulandı mı, kanal) taşınır (A2A `parts[]`, MCP `annotations.audience`). CloudEvents yalnız dış zarftır. Mesaj prompt değildir. |
| **C-77** | Güven etiketi | `trust_label` | Gelen mesajın kaynağına dair etiket: `authenticated`, `unauthenticated`, `spam`, `blocked`. Ajan uyandırılmadan önce olay türünde görünür. |
| **C-78** | Ajan tavanı | `agent_cap` | Gönderen türü `agent` olan bildirimlere ajan başına uygulanan gönderim tavanı. Aşan bildirimler gönderilmez, silinmez, kalıcı bekletilir; sahibine olay gider (§17). |

### 5.10 Tekrar korumaları

Relay'de dört ayrı tekrar koruması vardır; birbirinin yerine geçmez, birbirinden türetilmez.

| ID | Türkçe ad | Kod adı | Neye karşı | Kapsam ve ömür |
|---|---|---|---|---|
| **C-79** | Idempotency anahtarı | `Idempotency-Key` | Aynı HTTP isteğinin kazara tekrarı | Değişiklik yapan her istekte zorunlu. Kapsam `(tenant, environment, endpoint, key)`; ömür 24 saat (sunucu politikası). Aynı anahtar + aynı gövde ilk yanıtı birebir döner; aynı anahtar + farklı gövde reddedilir. İçerikten türetilmez. |
| **C-80** | İş tekrar anahtarı | `dedup_key` | Aynı iş olayının saatler/günler sonra yeniden gelmesi (outbox retry) | Bildirim kaydında kiracı içinde benzersiz; bildirim saklandığı sürece geçerli. Kanal içermez. Üretici kendi olay kimliğinden türetir (ör. `access:password-changed:<event-id>`). |
| **C-81** | İçerik tekilleştirme | `content_dedup` | Aynı alıcıya aynı kanaldan aynı içeriğin kısa sürede tekrar gitmesi | İsteğe bağlı; workflow başına pencereyle açılır. Varsayılanı §10'dadır. Düşürülen mesaj nedenle kaydedilir. |
| **C-82** | Teslim tekilliği | — | Aynı bildirimin aynı alıcıya aynı kanaldan iki kez teslim açılması | Defter anahtarı `(notification_id, recipient, channel)`; veritabanı kısıtıdır. |

"Kodu tekrar gönder" gibi meşru yeni istek yeni anahtarla gelir; tekrar sayılmaz. Garanti dili "at-least-once teslim + kalıcı idempotency ile etkin exactly-once işlem"dir; "exactly-once" tek başına kullanılmaz (§6.3).

### 5.11 Event teslimi

| ID | Türkçe ad | Kod adı | Tanım ve kurallar |
|---|---|---|---|
| **C-83** | Event hedefi ve uç | `destination`, `endpoint` | Relay'in olay teslim ettiği yer. Türleri: HTTPS webhook ucu (imzalı), kuyruk/akış (Kafka, NATS JetStream, RabbitMQ, bulut kuyrukları), S3 uyumlu nesne deposu. Hepsi tek teslim motorunu kullanır (retry, DLQ, replay, SSRF koruması, uç sağlığı). Uç ortamı değiştirilemez. |
| **C-84** | Giden olay | `outbound_event` | Relay'in kendi ürettiği anlamsal olay (teslim, bounce, etkileşim, atlama nedeni, İYS reddi, bekleme çözümü, ajan tavanı vb.) ya da `webhook` kanalıyla kiracının müşterisine teslim edilen olay. Varsayılan ince olaydır (`type` + `id` + ilgili kimlikler); CloudEvents zarfındadır; konu başına monoton `seq` taşır (§16). |

### 5.12 Kayıt, saklama ve denetim

| ID | Türkçe ad | Kod adı | Tanım ve kurallar |
|---|---|---|---|
| **C-85** | Saklama sınıfı | `retention_class` | Kişisel verinin saklama ve imha birimi. Relay sınıfları: `recipient_profile` (alıcı profili ve iletişim adresleri), `notification_content` (bildirim içeriği), `delivery_records` (teslim kayıtları), `commercial_consent_records` (ticari ileti onay ve gönderim kayıtları), `preferences` (tercihler). Süre ve dayanak Access Ek C bölge × sektör tablosundan gelir (Access OP-74). |
| **C-86** | Veri öznesi ve özne anahtarı | `data_subject`, `dek` | Kişisel verisi tutulan kişi. Kişisel alanlar kişi × saklama sınıfı başına bir veri şifreleme anahtarıyla (DEK) şifrelidir. Silme talebi ve saklama sonu DEK imhasıyla (crypto-shredding) uygulanır; satır yumuşak silinir ve okunamaz kalır. Fiziksel silme yoktur (Access OP-73). |
| **C-87** | Denetim kaydı | `audit_log` | Operatör ve yönetici eylemlerinin kurcalanmaya dayanıklı, append-only kaydı; bütünlüğü periyodik imzalı Merkle kontrol noktasıyla sağlanır, kayıt başına hash zinciri yoktur. Bütünlük modeli ve biçimi Access'inkiyle aynıdır; Access bağlıysa eylemi yapanın Access kimliği ve ilgili Access kayıt numarası taşınır (§7.3.9). |
| **C-88** | Kullanım kaydı | `usage_record` | Faturalama ve kota için değişmez kullanım satırı. Faturalama metrikten değil bu kayıttan yapılır. Test gönderimleri ayrı satırdır. |
| **C-89** | Gönderim modu | `send_mode` | Bir workflow ya da kampanyanın çalışma biçimi: `live`, `shadow` (bütün karar hattı çalışır, gönderim yapılmaz), `dry_run` (yalnız karar ve önizleme), `off`. Ortamdan (C-13) ayrıdır. Canlı ortamdaki test gönderimi `is_test` işaretlidir: gerçek sağlayıcıya gider, faturalamada ve ürün metriklerinde ayrı satırdır. |

### 5.13 Access kavramlarıyla eşleme

Access ve Relay ortak bir kiracı eşlemesi kullanır (Access E40). Aşağıdaki tablo hangi Access kavramının Relay'de neye karşılık geldiğini sabitler. Eşleme bir kopya değildir: kimlik ve yetki doğruluğu Access'te kalır (§7).

| Access kavramı | Relay karşılığı | Not |
|---|---|---|
| Tenant (ticari hesap) | Kiracı (C-11) | Bağlantı kurulunca otomatik eşlenir. Access ve Relay kullanan kiracının iki ürünü aynı bölgededir |
| B2B organizasyon | Alt kiracı (C-12) | Access'te organizasyon açılınca/değişince Relay karşılığı otomatik oluşur ve güncellenir |
| Kullanıcı (identity plane) | Abone (C-20) ve/veya operatör (C-14) | Operatör girişi Access OIDC ile; abone jetonu Access jetonundan token exchange ile (§7.3.6). Token exchange'de Relay abonesi Access'in kiracıya özgü (pairwise) `sub` değeriyle eşlenir; abonenin `external_id`'si bu değerdir (§15) |
| Ajan Party / Instance | Ajan alıcı (C-21) | Relay kaydı Access kimliğine bağlanır; askıya alma/silme olayı Relay teslimini durdurur |
| Semantic event (derived) | Olay (C-28), sınıfı `security` ya da üreticinin beyan ettiği sınıf | İçerik ve alıcı kümesi Access'in; kanal ve teslim Relay'in (§7.3.2) |
| Pazarlama izni ve geçmişi (Access IDP-37) | İzin kopyası (C-60) | Relay kopyayı Access olaylarından tutar; gönderimde Access'e sormaz |
| Approval Surface / AAS | Yanıt kanıt düzeyi `access_aas_ref` (C-74) | Relay yalnız referansı taşır; onay Access'tedir |
| Denetim kaydı | Denetim kaydı (C-87) bağlantısı | Biçim aynı; kayıtlar birbirine referans verir |
| Korunan mesaj anahtarları (Access X35) | Üretici sahipli şablon (C-55) | Kiracı metni ezemez |

**Sektör terimleriyle eşleme (bilgi).** Belgelerde ve göç rehberlerinde aşağıdaki karşılıklar kullanılır; Relay kendi adlarını kullanır.

| Sektörde | Relay'de |
|---|---|
| Knock "tenant", Novu "tenant/context" | Alt kiracı (C-12) |
| "subscriber", "recipient", "user" | Abone (C-20) |
| "batch", "digest" | Digest (C-48) |
| "routing", "channel strategy", "fallback chain" | Rota politikası (C-42) |
| "workflow trigger", "event" | Olay (C-28) |
| "waitpoint token" (Trigger.dev), "awakeable" (Restate), `.waitForTaskToken` (Step Functions) | Bekleme noktası (C-72) |
| "send/recv with topic" (DBOS), "agent inbox" | Ajan posta kutusu (C-68) |
| "suppression list", "unsubscribe group" | Bastırma (C-62), tercih (C-61) |

### 5.14 Adlandırma kuralları

1. Ortam her yerde `live` / `test`'tir; iptal durumu her yerde `cancelled`'dır (tek `l` değil).
2. Olay adları `noun.verb_past` biçimindedir (`notification.suppressed`, `waitpoint.expired`, `webhook_endpoint.disabled`) ve tek bir olay sözlüğündedir (§16).
3. Dışa açık kimlik önekleri tek bir tabloda tanımlanır (§9). İstemci uçları da `/v1` altındadır.
4. Realtime akış adları, olay adları ve realtime zarfı (`{t, v, ts, d}` + her mesajda `counters`) tek takım olarak sözleşmede yazılır (§15).
5. Yanıt ve karar alanları `response` / `decision` adını taşır; `approval` adı Relay API'sinde kullanılmaz (C-74).
6. "Exactly-once" tek başına kullanılmaz (§5.10). Idempotency-Key için "yaygın pratik" denir; "standarda uyuyoruz" denmez.
7. Kuyruk kütüphanesinin aynı adı taşıyan ticari özelliğine belgelerde atıf yapılmaz; "Relay" adı yalnız bu ürünü anlatır.
8. Bir kavramın kullanıcı arayüzündeki Türkçe ve İngilizce adı bu bölümdeki Türkçe ad ve kod adından türetilir; bir dilde bir kavram için tek terim kullanılır.

### 5.15 Kavram olmayanlar, bilinçli olarak

| Aday | Neden kavram değil |
|---|---|
| Segment / kitle sorgusu | Öznitelik sorgulu segmentasyon pazarlama otomasyonu ürünüdür; kiracı segmenti kendi sisteminde hesaplar ve liste ya da topic olarak gönderir (kapsam dışı, §2) |
| Onay (approval) | Onay bir yetki eylemidir ve Access'tedir (Access EI-18, Access E32). Relay'de yalnız yanıt (C-74) vardır |
| Ajan yürütme durumu / checkpoint | Bekleyen tarafındır (Executor, ajan çatısı, müşteri kodu); Relay yalnız bekleme noktasını tutar (§7.5) |
| Koşullu tercih | İş kuralıdır; kiracı sistemi koşulu değerlendirip olayı gönderir (C-61) |
| Bridge / çalışma anında müşteri koduna çağrı | Yoktur; workflow tanımı yayında sabittir (C-40) |
| İnsan iş/onay kuyruğu | Work'ündür (Access XI-7); Relay'in ajan posta kutusu ondan ayrıdır (C-68) |
| Kod üretimi ve doğrulama (OTP) | Gönderenindir; Relay kod üretmez, sır tutmaz, doğrulamaz (§7.3.10) |
| Rozet | Posta kutusu projeksiyonudur (§5.8) |

### 5.16 Karar register'ı (C-1–C-89)

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| C-1 | Relay'in nesnesi mesaj ve teslimdir; içerik ve "kime, neden" üreticinindir | FROZEN (ürün) | Access §7.9.8 (Relay'in nesnesi mesaj/teslimattır); Access E40 |
| C-2 | Kanonik olan append-only kayıtlardır; durumlar türetilir ve yeniden kurulabilir | FROZEN (teknik) | Defterden yeniden kurma testi (§14); Access C2 ile aynı yapı |
| C-3 | Bildirim, teslim ve deneme üç ayrı seviyedir; tek kayıtta birleşmez | FROZEN (teknik) | Çok cihazlı alıcı ve fallback zincirinde raporlama; sonradan ayırmak bütün geçmişin göçü demektir |
| C-4 | Karar hata değildir; politika sonucu kabul sonrası kayıtla raporlanır | FROZEN (ürün) | Access OP-64 (decision ≠ error) |
| C-5 | İzin ve tercih ayrı kayıtlardır | FROZEN (ürün) | 6563 m.11/3 saklama yükünün tercih verisine bulaşmaması; KVKK ispat yükü |
| C-6 | Sınıf, kategori ve gönderen türü bağımsız eksenlerdir | FROZEN (ürün) | 6563 Yönetmelik m.6/2 (içerik ticari niteliği belirler); Meta şablon kategorileri |
| C-7 | Teslim, ack, okundu, yanıt ve bekleme çözümü yetki durumu değildir | KANONİK DEĞİŞMEZ | Access EI-9, Access EI-18, Access E30 |
| C-8 | Bekleme bir kayıt + zamanlayıcıdır; çalışan iş değildir | FROZEN (teknik) | Oban `wait_for` ve Step Functions modeli; kuyruk yuvası tutmama |
| C-9 | Kurulum tanımı; kod her kurulumda aynı | FROZEN (ürün) | Apache-2.0, open-core yok (Access D4 ile aynı yön) |
| C-10 | Bölge tanımı (`tr`, `eu`, `us`); bölgeler arası veri akışı yok | FROZEN (ürün) | Veri yerleşimi; Access Ek C |
| C-11 | Kiracı tanımı; `default_timezone` ve `default_locale` zorunlu; `suspended` her girişte etkili | FROZEN (ürün) | Sistem varsayılanının sessiz yanlış yerelleştirme üretmesi |
| C-12 | Alt kiracı: birinci sınıf, tek seviyeli, miras kuralı, eşleşmeyen teslim `scope_mismatch` | FROZEN (ürün) | Knock tenant modeli; B2B müşterinin kendi müşterisine gönderimi |
| C-13 | Ortam `live` / `test`; API anahtarında taşınır; aynı hat | FROZEN (ürün) | Stripe test modu modeli |
| C-14 | Operatör: OIDC ile giriş, roller Relay'de | FROZEN (ürün) | Access E40 (3)–(4) |
| C-15 | Kurulum operatörü: SaaS'ta işleten, self-host'ta kurum yöneticisi; kod aynı | FROZEN (ürün) | Özellik eşitliği |
| C-16 | API anahtarı kiracıya ve ortama değişmez biçimde bağlı; sır bir kez gösterilir | FROZEN (teknik) | Anahtar–kiracı bağının ezilmesi sızıntı yolu |
| C-17 | Abone jetonu kısa ömürlü ve dar kapsamlı (`inbox:read`, `inbox:write`, `preferences`) | FROZEN (ürün) | En az yetki; istemcide sır yok |
| C-18 | Üretici tanımı; Access yalıtılmış platform kiracısıdır | FROZEN (ürün) | Access E40 (2) |
| C-19 | Alıcı üst türü: abone + ajan alıcı | FROZEN (ürün) | İnsan ve ajan hedeflerinin tek teslim çekirdeğini paylaşması |
| C-20 | Abone tanımı; açık upsert, hayalet alıcı yok; Access bağlıyken `external_id` = Access pairwise `sub` | FROZEN (ürün) | Yanlış adrese gönderim riskinin kapatılması |
| C-21 | Ajan alıcı tanımı; Access bağı isteğe bağlı | FROZEN (ürün) | Access EI-9; ajan kimliği Access'te |
| C-22 | Adres tanımı; şifreli saklama, kör indeksle arama | FROZEN (teknik) | KVKK; Access OP-74 |
| C-23 | Cihaz tanımı; OS izin durumu; jeton/izin kaybı tercihi silmez | FROZEN (ürün) | APNs/FCM jeton yaşam döngüsü |
| C-24 | Gönderen türü `human` / `system` / `agent` sınıftan ayrı alandır | FROZEN (ürün) | Ajan tavanı ve arayüzde kaynak gösterimi |
| C-25 | Gönderici kimliği kiracı varlığıdır; onaysız kimlikle gönderim yok | FROZEN (ürün) | BTK SMS başlığı kuralları; SPF/DKIM hizalama |
| C-26 | Kanal kimliği tanımı; VAPID anahtarı kanal kimliği başına; sır yalnız referansla | FROZEN (teknik) | Sır hijyeni |
| C-27 | Hukuki alıcı türü `individual` / `merchant` | FROZEN (ürün) | 6563 tacir/esnaf istisnası |
| C-28 | Olay tanımı; `POST /v1/events` + CloudEvents; `(tenant, source, id)` tekrar anahtarı | FROZEN (ürün) | CloudEvents 1.0 HTTP bağlaması |
| C-29 | Bildirim tanımı; bir alıcı için bir kez; plan sabitlenir | FROZEN (teknik) | — |
| C-30 | Teslim tanımı; fallback yeni teslim açar | FROZEN (teknik) | — |
| C-31 | Deneme tanımı; `unknown` birinci sınıf; terminal durum ezilmez | FROZEN (teknik) | Ağ belirsizliğinin dürüst kaydı |
| C-32 | Teslim olayı: append-only defter satırı | FROZEN (teknik) | — |
| C-33 | Yedi sabit mesaj sınıfı; kabul anında atanır, değişmez | FROZEN (ürün) | Hukuk, öncelik ve saklama ekseninin tek kaynağı |
| C-34 | Güvenlik alt türleri `otp_oob` ve `email_verification` | FROZEN (ürün) | NIST SP 800-63B (e-posta OOB doğrulayıcı değildir) |
| C-35 | Kategori tek sınıfa bağlıdır; kilitli kategoride en az bir kanal açık | FROZEN (ürün) | Knock/Novu kategori modeli |
| C-36 | Şerit yalnız sınıftan; `priority` şerit içi ince ayar ve tavanlı | FROZEN (ürün) | OTP ile kampanyanın aynı şeride düşmemesi |
| C-37 | Konu `{type, id}`; collapse anahtarı `{tenant, konu türü, konu kimliği, sınıf}` özeti | FROZEN (ürün) | APNs `apns-collapse-id`, FCM collapse key sınırları |
| C-38 | Kampanya: hazırla, sonra tetikle; son teslim tarihi | FROZEN (ürün) | Tepe gönderimde sağlayıcı limiti |
| C-39 | `expires_at`; OTP'de zorunlu; kanal TTL'leri ondan türer | FROZEN (ürün) | Eskimiş OTP ve onay daveti zararı |
| C-40 | Workflow: sürümlü, üç eşit yazım yolu, tek yönetici, bridge yok | FROZEN (ürün) | Novu/Knock code-first ve panel modelleri |
| C-41 | Sekiz adım türü; fetch/update/çağır adımı yok | FROZEN (ürün) | SSRF yüzeyi, deterministik tekrar oynatma, döngü riski |
| C-42 | Rota politikası: `single`/`all` ağacı, dört strateji, adım > kategori | FROZEN (ürün) | Courier routing modeli |
| C-43 | Kanal kod adları | FROZEN (ürün) | — |
| C-44 | Sağlayıcı tanımı; katalog ve tablolar veridir | FROZEN (teknik) | Fiyat ve limitlerin sık değişmesi |
| C-45 | Sağlayıcı bağlantısı; yalnız doğrulanmış bağlantıya trafik | FROZEN (ürün) | Tescilsiz başlıkla SMS'in düşmesi; DMARC hizalama |
| C-46 | Sabitlenmiş plan; kapılar her denemede yeniden; sessiz sürüm geçişi yok | FROZEN (teknik) | Gönderim ortasında şablon değişiminin test edilememesi |
| C-47 | Eskalasyon politikası; son kademe yalnız olay | FROZEN (ürün) | Relay'in yetki kaynağı olmaması (Access E32) |
| C-48 | Digest pencere modeli | FROZEN (ürün) | Knock batch, Novu digest |
| C-49 | Throttle adımı; anahtar kiracı geneli | FROZEN (ürün) | — |
| C-50 | Frekans tavanı bir zamanlayıcıdır; global tavan her zaman tanımlı | FROZEN (ürün) | Braze/Iterable frekans politikaları |
| C-51 | Topic ≤ 2 seviye; fanout anında dondurma; segment yok | FROZEN (ürün) | Knock objects/subscriptions modeli |
| C-52 | Tekrar kuralı: RRULE, yerel saat, tanım olarak saklanır | FROZEN (ürün) | RFC 5545 RRULE |
| C-53 | Deney: 2–10 varyant, kullanıcı bazlı deterministik bölme | FROZEN (ürün) | — |
| C-54 | Şablon: kanal × yerel, sürümlü; `transactional` / `marketing` dönüştürülemez | FROZEN (ürün) | 6563 Yönetmelik m.6/2; Meta utility→marketing yeniden kategorilendirme |
| C-55 | Üretici sahipli şablon; kiracı yalnız izinli marka alanlarını değiştirir | FROZEN (ürün) | Access X35, Access X39 |
| C-56 | Layout, parça (tek seviye), marka değişkenleri; sürümler sabitlenir | FROZEN (ürün) | Serbest `include` döngü ve sızıntı riski |
| C-57 | Yerel BCP 47, saat dilimi IANA; zorunlu kiracı varsayılanı; DB yalnız UTC | FROZEN (teknik) | BCP 47; IANA tzdata |
| C-58 | Politika kafesi: kapı → filtre → zamanlayıcı | FROZEN (ürün) | Kapıların sıralı ve atlanamaz olması |
| C-59 | Karar + tek `rule_id` sözlüğü; her atlama görünür | FROZEN (ürün) | "Neden almadım" sorusunun yanıtlanabilmesi |
| C-60 | İzin: `none`/`granted`/`revoked`, kanıt zorunlu, anahtar `(marka, kanal, alıcı)` | FROZEN (ürün) | İYS veri modeli; çapraz marka izin kullanımının yasaklığı |
| C-61 | Tercih: üç durumlu değer, dört seviye, VE mantığı, koşullu tercih yok | FROZEN (ürün) | Knock/SuprSend tercih modelleri |
| C-62 | Bastırma: kiracı düzeyinde; kalıcı neden süre almaz; anahtarlı özet olarak kalır | FROZEN (ürün) | ESP bastırma pratikleri; Access OP-74 bastırma kayıtları |
| C-63 | Sessiz saat ≠ yasal pencere; kiracı yasal pencereyi kapatamaz | FROZEN (ürün) | ABD TCPA |
| C-64 | Uyum kuralı veri tablosudur; kiracı yalnız sıkılaştırır | FROZEN (ürün) | 6563/İYS, GDPR/ePrivacy, CAN-SPAM/TCPA |
| C-65 | Kill switch tek modeli; engellenen iş duraklatılır, iptal ayrı eylem | FROZEN (ürün) | Kesinti müdahalesinde tek kontrol noktası |
| C-66 | Hata sınıfı sözlüğü; eşleme sürümlü veri | FROZEN (teknik) | Sağlayıcı kodlarının çeşitliliği |
| C-67 | İç dört eksen + dış sade projeksiyon; dış sözleşme sabit | FROZEN (ürün) | Sağlayıcı semantiklerinin farklılığı |
| C-68 | Posta kutusu: ortak çekirdek, insan ve ajan yüzü; push yalnız ipucu | FROZEN (ürün) | DBOS send/recv, Signal uyandırma modeli |
| C-69 | Inbox öğesi: konu + etkinlikler; kullanıcı silemez | FROZEN (ürün) | Knock/MagicBell inbox modelleri; fiziksel silme yok |
| C-70 | Duyuru okuma anında birleştirilir | FROZEN (teknik) | Kiracı geneli duyuruda yazma patlaması |
| C-71 | Akış `(stream, epoch, seq)`; `seq` commit sırasına dayanır; okuma sırası garantili | FROZEN (teknik) | SSE `Last-Event-ID`; Ably/MCP resume modeli |
| C-72 | Bekleme noktası tanımı; son tarih zorunlu; tek seferlik çözüm | FROZEN (ürün) | Trigger.dev waitpoint, Restate awakeable, Step Functions task token |
| C-73 | Korelasyon anahtarı; iki aşamalı eşleme | FROZEN (ürün) | Knock `wait_for_event`, Inngest `waitForEvent` |
| C-74 | Yanıt ve kanal kanıt düzeyi; alan adı `approval` değil | FROZEN (ürün) | Access EI-18; CIBA `binding_message` |
| C-75 | Etkileşim türü `notify` / `question` / `review`; risk kademesi sahibinden | FROZEN (ürün) | Ajan bildirim kalıpları; Access AG-33 |
| C-76 | Ajana teslim edilen şey yapılandırılmış mesajdır, prompt değildir | KANONİK DEĞİŞMEZ | A2A `parts[]`, MCP `annotations.audience`; OWASP LLM01 |
| C-77 | Güven etiketi dört değerli | FROZEN (ürün) | AgentMail `message.unauthenticated` modeli |
| C-78 | Ajan tavanı; aşan bekletilir | FROZEN (ürün) | Kaçak ajan döngüsünün kullanıcıya ulaşmaması |
| C-79 | Idempotency-Key: zorunlu, 24 saat, kapsam `(tenant, environment, endpoint, key)` | FROZEN (teknik) | Access OP-63; Stripe idempotency modeli |
| C-80 | `dedup_key`: bildirim ömrü boyunca benzersiz, kanal içermez | FROZEN (teknik) | Outbox retry'larının saatler sonra gelmesi |
| C-81 | İçerik tekilleştirme isteğe bağlı ve ayrı | FROZEN (ürün) | — |
| C-82 | Teslim tekilliği `(notification_id, recipient, channel)` DB kısıtı | FROZEN (teknik) | Kuyruk tekilliği garanti değildir |
| C-83 | Event hedefi türleri ve tek teslim motoru | FROZEN (ürün) | Svix/Hookdeck modeli; CloudEvents |
| C-84 | Giden olay: ince olay varsayılanı, CloudEvents zarfı, konu başına `seq` | FROZEN (ürün) | Standard Webhooks |
| C-85 | Beş Relay saklama sınıfı; süre Access Ek C'den | FROZEN (teknik) | Access OP-74 |
| C-86 | Kişi × sınıf DEK; silme = crypto-shredding; fiziksel silme yok | FROZEN (teknik) | Access OP-73, Access OP-74 |
| C-87 | Denetim kaydı append-only, periyodik imzalı Merkle kontrol noktalı, Access modeli ve biçiminde | FROZEN (ürün) | Access §7.9.12.5 |
| C-88 | Kullanım kaydı değişmez; faturalama metrikten yapılmaz | FROZEN (teknik) | Metrik örneklemesi faturalama kanıtı değildir |
| C-89 | Gönderim modu `live` / `shadow` / `dry_run` / `off`; `is_test` | FROZEN (ürün) | Göçte gölge mod; önizleme |
