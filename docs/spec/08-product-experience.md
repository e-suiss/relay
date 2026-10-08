## 8. Ürün deneyimi

Bu bölüm Relay'in insanlara ve geliştiricilere görünen yüzlerini tanımlar: konsol (panel), görsel workflow editörü, "neden almadım" ekranı, son kullanıcı inbox'ı ve tercih merkezi, gömülebilir webhook portalı, test ortamı, SDK'lar ve hazır UI bileşenleri, CLI ve ilk bildirime giden yol.

Bölümün bağlayıcı ilkeleri:

1. **Her yüzey aynı gerçeği gösterir.** Panel, API, webhook ve metrik aynı defterden okur; bir yüzeyde görünen karar ötekinde aynı `rule_id` ve aynı cümleyle görünür (§14) (X-1).
2. **Sessiz kayıp yoktur, sessiz ekran da yoktur.** Gönderilmeyen her bildirim neden koduyla panelde görünür; bilinmeyen durum "bilinmiyor" olarak gösterilir, başarı gibi gösterilmez (X-1).
3. **Özellik eşitliği.** Bu bölümdeki her yüzey self-host kurulumda da eksiksiz gelir; hiçbiri "yalnız bulut" değildir (§2) (X-2).
4. **Yerel eşdeğer var, "geliştirme modu" yok.** Test ortamı ve yerel geliştirme gerçek hattın aynısını çalıştırır; güvenliği zayıflatan bayrak yoktur (Access OP-69 ile uyumlu).

### 8.1 Kullanıcılar ve yüzeyler

| Kullanıcı | Ana işi | Birincil yüzey |
|---|---|---|
| Kiracı geliştiricisi | Entegrasyon, olay gönderme, webhook alma | API, SDK, CLI, test ortamı |
| Kiracı ürün/içerik ekibi (kod bilmeyen) | Workflow, şablon, rota kurma | Görsel editör (panel) |
| Kiracı destek ekibi | "Bu kullanıcı neden almadı?" | "Neden almadım" ekranı |
| Kiracı yöneticisi | Sağlayıcılar, gönderici kimlikleri, roller, kill switch, saklama | Panel ayarları |
| Kurulum operatörü (SaaS'ta Suiss, self-host'ta kurumun Relay yöneticisi) | Platform sağlığı, kiracı yönetimi, `critical` açılımı, platform kill switch | Operatör paneli |
| Son kullanıcı (abone) | Bildirim okuma, tercih yönetme | Inbox ve tercih bileşenleri, tercih sayfası |
| Kiracının müşterisi (webhook alıcısı) | Uç nokta yönetimi, başarısız teslimi yeniden gönderme | Gömülebilir webhook portalı |
| Ajan | Gönderme, bekleme, posta kutusu okuma | API, MCP, SDK ajan yardımcıları (§17) |

### 8.2 Konsol (panel)

#### 8.2.1 Giriş, roller ve bağlam

- Konsola giriş herhangi bir OIDC IdP ile yapılır (Access önerilir); roller ve yetkiler Relay içinde tutulur (§18) (X-3).
- Hassas işlemler (kill switch'i yeniden açma, sağlayıcı sırrı/anahtar rotasyonu, alıcı PII'sini açık gösterme, ajan bekleyenlerini serbest bırakma) yeniden doğrulama ister: Access bağlıysa Access step-up, değilse bağlı IdP'den `max_age`/`acr` ile yeniden doğrulama (§18) (X-3).
- Panel her zaman tek kiracı bağlamındadır; ortam (`live`/`test`) ve alt kiracı seçimi her ekranda görünür. Çapraz kiracı sorgu yalnız operatör rolüyle ve denetim kaydıyla yapılır (X-4).
- PII varsayılan olarak maskelidir; "göster" eylemi yetki ister ve denetim kaydına girer. Panelden müşteri listesi toplu çekilemez; dışa aktarım ayrı, yetkili ve denetlenen bir işlemdir (§20) (X-5).

#### 8.2.2 Panel alanları

| Alan | İçerik | Kural kaynağı |
|---|---|---|
| Aktivite | Bildirim ve teslim listesi, deneme geçmişi, olay defteri, her satırda karar ve `rule_id` | §14 |
| Neden almadım | §8.4 | §8.4 |
| Workflow'lar | Görsel editör, sürümler, yayın geçmişi | §8.3, §10 |
| Şablonlar ve layout'lar | Kanal × locale matrisi, önizleme, yayın kapısı sonuçları, eksik locale ölçümü | §11 |
| Rotalar, eskalasyon politikaları | Tanım, kullanım yerleri, değişiklik etkisi | §10, §17 |
| Alıcılar, topic'ler, ajanlar | Profil, cihazlar, abonelikler, ajan kaydı ve posta kutusu durumu | §5, §17 |
| Bekleyen istekler | `open`/`stalled` bekleme noktaları, eskalasyon kademesi, kanıt düzeyi dağılımı | §17 |
| Ajan tavanı | Bekletilen ajan kaynaklı bildirimler; hepsini gönder / iptal / ajanı durdur | §17 |
| Kanallar ve sağlayıcılar | Sağlayıcı hesapları, doğrulama durumu, devre kesici durumu, "yurt dışına veri gönderir" uyarısı, adaptör kullanımdan kaldırma uyarısı | §12 |
| Gönderici kimlikleri ve alan adları | SMS başlıkları, alan adı doğrulama sihirbazı, ısınma planı | §12 |
| Uyum | İYS bağlantısı ve senkron durumu, ülke kuralları, kilitli kategoriler | §13 |
| Webhook'lar ve hedefler | Uç noktalar, teslim logu, DLQ, replay, uç sağlığı | §16 |
| Raporlar | Teslim hunisi, kanal/sağlayıcı oranları, etkileşim (insan/bot ayrımıyla), A/B sonuçları, maliyet, atlama nedeni dağılımı | §14 |
| Kill switch | Kapsam × hedef × sınıf × durum; yürürlüğe girme gecikmesi görünür | §18 |
| Denetim kaydı | Operatör ve yönetici eylemleri | §18 |
| Ayarlar | API anahtarları (kapsam, son kullanım), roller, saklama, `default_timezone`, `default_locale` | §9, §18, §20 |

#### 8.2.3 Dürüst gösterim kuralları (X-6)

- Durum dışa açılan projeksiyonla gösterilir (`queued`/`sent`/`delivered`/`failed`/`skipped`/`unknown_pending`/`unknown` …); push için "teslim edildi" iddia edilmez, kanal başına teslim semantiği yazılıdır (§14).
- Açılma pikseli açıldığında panel güvenilmezlik uyarısı gösterir; açılma oranı hiçbir panel kararında kullanılmaz. Tıklamalar "insan" ve "muhtemel bot" olarak ayrı gösterilir (§14).
- Yedek saat dilimiyle giden mesajlar raporda ayrı sayılır (§10).
- Ajan, insan ve sistem kaynaklı bildirimler gönderen türüyle etiketlenir.
- Durum yalnız renkle gösterilmez; her durumun metin karşılığı vardır.

#### 8.2.4 Operatör paneli

İş kuyruğu görünümü için Oban Web (Apache-2.0) ve oban_met kullanılır; bunların büyük tablolardaki sayım sorgu yükü izlenir ve sınırlanır (X-7). Operatöre özgü ekranlar (kiracı yönetimi, platform kill switch, `critical` açılımı, kiracı askıya alma, bölge sağlığı) Relay'in kendi panelindedir. Relay'in kendi olay bildirimi ve nöbet sayfalaması Relay'den geçmez (§20).

### 8.3 Görsel workflow editörü ve üç yazım yolu

#### 8.3.1 Üç eşit yol, tek tanım biçimi (X-8)

| Yol | Kimin için | Nasıl |
|---|---|---|
| **Görsel editör** | Kod bilmeyen kullanıcı (ana yol) | Panelde sürükle-bırak akış; taslak, test, yayın, tek tıkla eski sürüme dönüş |
| **Dosya** (YAML/JSON + JSON Schema) | Git ile çalışan ekip | Dosyalar git'te; CLI ile `pull`/`push`/`promote`; API aynı biçimi kabul eder |
| **SDK ile kod** | Geliştirici, kendi dilinde | Yayında aynı tanım biçimine derlenir; çalışma anında müşteri koduna çağrı yoktur |

Üç yol aynı tanım biçimini üretir; birinde kurulabilen her şey (adımlar, rotalar, eskalasyon politikaları, A/B varyantları, koşullar) ötekilerde de kurulabilir. Çalışma anında müşteri sunucusuna çağrı yapan köprü modeli yoktur.

#### 8.3.2 Tek yönetici kuralı (X-9)

- Her workflow'un tek yöneticisi vardır: "panelden" ya da "koddan" (dosya/SDK).
- Koddan yönetilen akışın yapısı panelde değiştirilemez; editör bunu açık bir uyarıyla gösterir. Metin ve kod tarafında işaretlenmiş kontrol alanları panelde düzenlenebilir.
- Yönetici değişikliği açık bir eylemdir ve denetim kaydına girer.

#### 8.3.3 Editörün davranışı (X-10)

- Adım paleti §10'daki sekiz adımla sınırlıdır: kanal, bekle, digest, throttle, koşul, olay bekle, zaman penceresi, webhook.
- Koşul adımı ve olay bekle adımının ikinci aşama koşulu aynı basit kural diliyle, listelerden seçilerek kurulur (§10, §17).
- Editör yayın kapısının sonuçlarını (şema doğrulaması, eksik değişken, kanal varyantı eksikliği, işlemsel şablona promosyon sızıntısı, yasal altbilgi, erişilebilirlik uyarıları) yayından önce gösterir; sert kapı geçilmeden yayın düğmesi çalışmaz (§11).
- Her yayın değişmez bir sürüm üretir; "eski sürüme dön" yeni bir sürüm olarak yayımlanır. Hangi bildirimin hangi sürümle gittiği her zaman görünür.
- Workflow Mermaid biçiminde dışa aktarılabilir (X-11).

### 8.4 "Neden almadım" ekranı (X-12)

Operatör yüzünün birincil hedefi "bu kullanıcı neden almadı?" sorusunu 30 saniyede cevaplamaktır (X-13).

| Bölüm | İçerik |
|---|---|
| Giriş | Telefon, e-posta ya da alıcı kimliği |
| İzin ve tercih durumu | Kanal × izin (onay/ret, kaynak, tarih); tercih seviyeleri (kategori × kanal, workflow, tek nesne, haftalık program) |
| Kararlar | Son 30 günün bütün kararları, gönderilmeyenler dahil; her satırda `rule_id` ve sözlükten gelen tek cümle; tercihle atlananlarda kapatan seviye |
| Teslim ayrıntısı | Denemeler, sağlayıcı ham yanıtı, bastırma kaydı, cihaz izin durumu |
| Gizlilik | PII maskeli; "göster" yetki ister ve denetlenir; müşteri listesi çekilemez |

Atlama nedenleri tek `rule_id` sözlüğünden gelir (§14); ekran kendi metnini üretmez. Aynı kayıt `notification.suppressed` webhook'unda ve metrikte de görünür.

### 8.5 Önizleme, test gönderimi ve gönderim modları

- **Önizleme:** her kanal için render; SMS segment sayısı ve kodlama; e-posta HTML ve düz metin. Önizleme ayrı origin'de, CSP ve iframe `sandbox` ile render edilir (§11).
- **Test gönderimi:** `is_test` işaretlidir; gerçek sağlayıcıya gider, faturalamada ve ürün metriklerinde ayrı satırdır, kotası ayrı ve küçüktür, geçmişte görünür (§11).
- **Kitle önizlemesi:** gönderimden önce kaç alıcıya gideceği, hangi `rule_id` ile kaçının düşeceği ve tahmini maliyet gösterilir (X-14).
- **Gönderim modu** workflow başına seçilir (X-15):

| Mod | Davranış |
|---|---|
| `live` | Normal gönderim |
| `shadow` | Bütün hat çalışır ve kararlar kaydedilir; son adımda gönderim yapılmaz. Yeni bir workflow'u gerçek trafikle doğrulamak içindir |
| `dry_run` | Kafes çalışır ve karar döner; kayıt ve gönderim yoktur. Önizleme/test uçlarında kullanılır |
| `off` | İstek kabul edilir, gönderilmez; her bildirim `skipped` + `send_mode_off` olarak kaydedilir (§9). `off` bir yapılandırma modudur; acil durdurma aracı kill switch'tir (§18) ve `off` onun yerine kullanılmaz |

Senkron karar hatası yalnız önizleme, test ve `dry_run` uçlarında döner; normal gönderimde politika sonucu `202` sonrası `suppressed` + `rule_id` olarak raporlanır (§9).

### 8.6 Son kullanıcı inbox'ı

Inbox'ın veri modeli, okundu semantiği ve realtime kuralları §15'tedir. Bu alt bölüm görünen davranışı bağlar.

- **Bileşen:** zil, rozet, liste; okundu/okunmadı, arşiv, gizle. "Gizle" arayüzde "sil" etiketiyle gösterilebilir; kullanıcıya "gizlendi" denir, kayıt saklama süresi boyunca kalır (X-16).
- **Rozet:** sunucuda hesaplanan, sürümlü mutlak sayıdır; kiracı uygulama başına `unseen` (varsayılan) ya da `unread` seçer. Bütün cihazlar aynı sayıyı görür.
- **"Tümünü okundu işaretle":** yalnız o anki filtreli görünümü etkiler; kesme noktası düğmeye basılma anıdır; arşivlemez; kısa bir "geri al" penceresi sunar; arayüz iyimserdir (rozet anında güncellenir) (X-17).
- **Sekmeler ve filtreler:** kategori/etiket sekmeleri, önem (severity) gösterimi, erteleme (snooze) (X-16).
- **Eylemler:** öğe eylemleri yapılandırılmış aksiyonlardır. Onay türündeki öğede eylem yalnız Access onay yüzeyine derin bağlantıdır; inbox butonu onay değildir (§17).
- **Yanıt bekleyen öğe:** "işleniyor → yanıtlandı (kim, ne zaman)" olarak güncellenir; süre dolunca "artık yanıt beklenmiyor" gösterilir (§17).
- **Kısayol:** her bildirim ilgili kategori tercihine doğrudan bağlantı taşır (X-16).

### 8.7 Tercih merkezi ve tercih UX'i

Tercih ve izin kuralları §13'tedir. Görünen davranış:

- **İki biçim:** sunucu tarafında JS'siz çalışan barındırılan sayfa ve gömülebilir bileşen. İkisi aynı kaynaktan render edilir; cihazlar arası tutarlıdır (X-18).
- **Birleşik görünüm:** Access + Relay bağlıyken kullanıcı tek "Tercihlerim" ekranı görür; pazarlama izinleri (Access) ve bildirim tercihleri (Relay) birlikte, kaynakları ayrı kalarak gösterilir (X-19).
- **Kilitli kategoriler** açıkça gösterilir ve neden kapatılamadıkları yazılır; gizlenmez (X-22).
- **Tık simetrisi:** bir izni vermek N tıksa geri almak en fazla N tıktır. Kabul ve ret görsel olarak eşdeğerdir (boyut, kontrast, konum, etiket ağırlığı); utandırıcı ret metni yoktur. Bu kurallar ve EDPB karanlık kalıp yasakları otomatik kabul testidir (X-20).
- **KVKK kaynaklı üç yasak:** izin ekranı her zaman atlanabilir; kiracı izni özellik erişimine bağlayamaz; aydınlatma ile açık rıza ayrı ekranda ve ayrı işaretlenebilir. `transactional` ve `operational` sınıflar rıza sormaz (X-21).
- **Toplu seçenekler:** sütun/satır toplu kapatma vardır; farklı amaçlar tek düğmede karıştırılmaz (X-22).
- **Kendini açıklayan adresler:** barındırılan sayfa yolları amaç bildirir (ör. `/bildirim-tercihleri`, `/abonelik-iptali`) (X-22).
- **Tek tık çıkış sayfası:** "çıkış yapıldı" der ve iki seçenek sunar: tercihleri yönet; "bu markadan hiç ticari e-posta almak istemiyorum" (§13).
- Tercih seviyeleri (kategori × kanal, workflow, tek nesne sessize alma, haftalık uygunluk programı) ve sessiz saat bu ekranda yönetilir. Sessiz saat varsayılan olarak yalnız anında kesen kanallara uygulanır; kullanıcı e-postayı kanal bazında sessiz saate dahil edebilir (§13.9.1).

### 8.8 Gömülebilir webhook portalı (X-23)

Kiracının kendi müşterileri için gömülebilen portal; ortak teslim motorunun yüzüdür (§16).

| Yetenek | Not |
|---|---|
| Uç nokta ekleme, düzenleme, devre dışı bırakma | SSRF kayıt kontrolü anında geri bildirim verir (§16) |
| Olay türü seçimi | Kiracının yayımladığı katalogdan |
| Teslim logu | Deneme başına istek/yanıt özeti, durum, sonraki deneme zamanı |
| Başarısız teslimleri görme ve yeniden gönderme | Tekil ve filtreli toplu; manuel yeniden gönderim ile otomatik retry etkileşimi §16'daki kurala uyar |
| İmza sırrı/anahtarı döndürme | Çakışmalı rotasyon (§16) |
| Test olayı gönderme | Sahte olay, aynı imza ve teslim hattı |
| Uç sağlığı ve devre dışı kalma nedeni | `webhook_endpoint.disabled` / `recovered` |

Portal kiracının markasıyla (alt kiracı markası dahil) temalanır, yerelleştirilir ve kiracı uygulamasına gömülür; erişim kiracının bastığı dar kapsamlı jetonla yapılır.

### 8.9 Test ortamı ve sanal saat

- Kiracı başına `live` ve `test` ayrı veri düzlemleridir. Ayrı API anahtarları ve veriler vardır; test anahtarı canlı veriye erişemez. Ortam API anahtarında taşınır, istek gövdesinde değil (X-24).
- Bütün hat aynıdır: doğrulama, idempotency, tercihler, İYS, rota, şablon, kill switch. Yalnız son adımda sahte sağlayıcı adaptörü çalışır. Test ve canlı aynı `rule_id`'leri üretir (X-25).
- **Sahte sağlayıcı:** belirli adreslere belirli sonuçlar üretir (hard bounce, teslim edilmedi, gecikmeli teslim, APNs 410, hız sınırı …). Adres ve sonuç tablosu belgelenir ve kodla aynı kaynaktan yayımlanır (X-26).
- **Test inbox'ı:** test düzleminde gönderilen her mesaj panelde render edilmiş hâliyle görüntülenir (X-26).
- **Tohum alıcılar:** test düzleminde hazır alıcı profilleri bulunur ("izinsiz", "ret vermiş", "sessiz saatte", "tavanı dolmuş") (X-26).
- **Sanal saat:** yalnız test düzleminde vardır; zamanı ileri sararak eskalasyon, bekleme noktası, digest, throttle, tekrar kuralı ve süre dolumu test edilir. Sanal saat canlı düzlemde hiçbir koşulda yoktur (X-27).
- Test düzleminde alıcı davranışı canlıyla aynıdır (açık upsert; yalnız kimlikle bilinmeyen alıcı `recipient_not_found`) (X-25).

### 8.10 SDK'lar ve hazır UI bileşenleri

#### 8.10.1 SDK seti (X-28)

| Tür | Diller / platformlar |
|---|---|
| Sunucu | TypeScript/Node, Python, Go, Java, .NET, Elixir, PHP, Ruby |
| İstemci | Tarayıcı JS + React bileşenleri (diğer çatılar web components ile), iOS (Swift), Android (Kotlin), React Native, Flutter |

Bütün SDK'lar OpenAPI 3.1 ve AsyncAPI belgelerinden üretilir; üstüne ince, el yazımı bir kullanım katmanı eklenir (§9).

#### 8.10.2 Her sunucu SDK'sında zorunlu olanlar (X-29)

1. Otomatik Idempotency-Key üretimi; retry'larda aynı anahtar korunur.
2. Yalnız `retryable: true` hatalarda üstel geri çekilme + jitter ile retry; `Retry-After`'a uyum.
3. Yazılı hata hiyerarşisi (kimlik, doğrulama, hız/kota, idempotency, sunucu).
4. Ham gövde üzerinden webhook doğrulayıcı (Suiss webhook profili; Access ile ortak).

SDK sürümü API sürümüne sabittir; paket güncellemesi davranış değiştirmez. Sayfalama tembel yineleyiciyle yapılır.

**Ajan yardımcıları:** bekleme noktası oluştur/bekle, posta kutusu oku/ack, "akışı aç + geçmişi listele + kimlikle tekilleştir" kalıbı (§17) (X-30).

#### 8.10.3 Mobil SDK sınırı (X-31)

Mobil SDK'lar push jeton kaydı ve yenilemesi (`devices:write` kapsamıyla, §9), içerik taşımayan push için iOS bildirim servis eklentisi ve Android data mesajı işleyicisi (§12), OS izin durumu bildirimi, Android kanal oluşturma, gösterildi/tıklandı makbuzu, diğer cihazdan bildirimi kaldırma, inbox ve tercih bileşenleri ile realtime bağlantıyı taşır. Mobil SDK olay tetiklemez, abone profili ya da izin yazmaz, gizli anahtar tutmaz.

#### 8.10.4 Hazır UI bileşenleri (X-32)

- React birinci sınıf bileşenlerdir; Vue, Angular, Svelte, LiveView ve düz HTML web components ile desteklenir; altta headless JS SDK vardır. Model Access'in bileşen modeliyle aynıdır (Access T41, Access TN-133).
- Bileşenler: inbox (zil, rozet, liste; okundu/arşiv/gizle), toast, tercih merkezi, webhook portalı.
- Mobil: iOS, Android, React Native ve Flutter için yerel inbox ve tercih bileşenleri.
- Tema ve marka (alt kiracı markası dahil), yerelleştirme ve WCAG 2.2 AA erişilebilirlik her bileşende zorunludur.
- İstemci bileşenleri yalnız dar kapsamlı abone jetonuyla çalışır (§15); gizli anahtar istemciye hiçbir koşulda girmez.

### 8.11 CLI (X-33)

| Komut | İş |
|---|---|
| `relay listen --forward-to <url>` | Yerel geliştirme tüneli: kiracının webhook olaylarını yerel adrese iletir |
| `relay trigger <workflow>` | Test olayı tetikler |
| `relay pull` / `push` / `promote` | Dosya tabanlı workflow, şablon ve rota tanımlarını çeker, gönderir, ortamlar arası yükseltir |
| `relay preview <workflow>` | Yerel veriyle render önizlemesi |
| `relay logs` | Aktivite ve teslim logunu izler |

- Geliştirme tüneli API sözleşmesinde değil CLI'dadır. API'de müşteri tanımlı köprü URL'si yoktur (X-34).
- Her komut ajan dostu `--json` çıktısı ve belgelenmiş, kararlı çıkış kodları sunar.
- CLI test ve canlı anahtarı ayırt eder; canlı düzlemi değiştiren komutlar açık onay ister.

### 8.12 İlk bildirime giden yol ve geliştirici belgeleri

**Hedef: 5 dakikada ilk bildirim (X-35).** Hedefin karşılandığı varsayımdır; onboarding kabul testiyle ölçülür (X-36).

1. Hesap açılışında kiracı `default_timezone` ve `default_locale`'i seçer (zorunlu; sistem varsayılanı yoktur) ve test anahtarını alır.
2. Test düzleminde hazır bir örnek workflow (in-app + e-posta) bulunur; sahte sağlayıcı sayesinde kimlik bilgisi gerekmez.
3. Tek bir `curl` ile alıcı bilgisi istekte verilerek (`to: {id, email}`) bildirim gönderilir; alıcı açık upsert ile oluşur.
4. Mesaj panelin test inbox'ında ve inbox bileşeninde görünür; aynı ekranda karar ve `rule_id` görünür.

**Belgeler:**

- Belgelerdeki her `curl` ve dil örneği CI'da test ortamına karşı çalıştırılır; çalışmayan örnek build'i kırar (X-37).
- "Limitler, retry takvimleri, garantiler" sayfası kodla aynı kaynaktan üretilir; hata gövdesi hangi limitin aşıldığını söyler (X-37).
- Garanti dili tek ve sabittir: "en az bir kez teslim + kalıcı idempotency ile etkin tek seferlik işlem" (§9) (X-38).
- MCP sunucusu ve ajanlar için "skills" paketi belgelerin parçasıdır (§17) (X-39).
- Veritabanı okuyan bağlayıcı yerine Debezium/Sequin gibi araçları CloudEvents çıkışıyla bağlama rehberi bulunur (§9).

**Yerel geliştirme:** resmî `docker compose` dosyasıyla tek komut; yerel eşdeğerler Mailpit, APNs mock, FCM mock ve hata enjeksiyonu için ağ vekili. "Geliştirme modu" yoktur (X-40).

### 8.13 Kapsam dışı (X-41)

| Konu | Gerekçe |
|---|---|
| Çalışma anında müşteri koduna çağıran köprü (bridge) | SSRF yüzeyi, deterministik tekrar oynatmanın bozulması; tanım yayında derlenir |
| Yalnız bulutta sunulan panel/UI özelliği | Özellik eşitliği (§2) |
| Segment/journey kurucu (öznitelik sorgulu kitle editörü) | Pazarlama otomasyonu ürünüdür; kiracı listeyi kendi sisteminde hesaplar (§10) |
| Kiracı betiği çalıştıran dönüşüm editörü | Kiracı kodu çalıştırılmaz; alan beyaz listesi ve CloudEvents eşlemesi kullanılır (§16) |
| Canlı düzlemde sanal saat ya da test kısayolu | Güvenliği zayıflatan bayrak yoktur |

### 8.14 Karar register'ı

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| X-1 | Panel, API, webhook ve metrik aynı defterden okur; aynı karar her yüzeyde aynı `rule_id` ve cümleyle görünür; sessiz kayıp ve sessiz ekran yoktur | KANONİK DEĞİŞMEZ | §14 |
| X-2 | Bu bölümdeki bütün yüzeyler self-host'ta eksiksizdir; hiçbir yüzey lisans bayrağıyla kilitlenmez | MERKEZİ KARAR | §2 özellik eşitliği |
| X-3 | Konsol girişi herhangi bir OIDC IdP ile (Access önerilen); roller Relay'de; hassas işlemler Access step-up ya da IdP yeniden doğrulaması ister | FROZEN (ürün) | Access E40; §18 |
| X-4 | Panel her zaman tek kiracı bağlamındadır; çapraz kiracı sorgu yalnız operatör rolü + denetim kaydı; ortam ve alt kiracı her ekranda görünür | FROZEN (ürün) | §18 |
| X-5 | PII varsayılan maskeli; "göster" yetkili ve denetlenen eylem; panelden müşteri listesi toplu çekilemez | KANONİK DEĞİŞMEZ | KVKK veri minimizasyonu |
| X-6 | Panel dürüst gösterim kuralları: dış projeksiyon durumu, push'ta "teslim edildi" iddiası yok, açılma pikseli uyarısı, insan/bot tıklama ayrımı, yedek saat dilimi ayrı sayım, gönderen türü etiketi, durum yalnız renkle gösterilmez | FROZEN (ürün) | Apple Mail Privacy Protection; §14 |
| X-7 | Operatör paneli iş kuyruğu görünümü için Oban Web + oban_met; büyük tablolardaki sayım sorgu yükü izlenir ve sınırlanır | FROZEN (teknik) | Apache-2.0 |
| X-8 | Üç eşit yazım yolu (görsel editör, dosya YAML/JSON + JSON Schema, SDK ile kod), tek tanım biçimi; çalışma anında müşteri koduna çağrı yok | MERKEZİ KARAR | Knock GitOps, Novu code-first dersleri |
| X-9 | Her workflow'un tek yöneticisi vardır (panel ya da kod); koddan yönetilen akışın yapısı panelde değiştirilemez, uyarı gösterilir; metin ve işaretli kontrol alanları panelde düzenlenebilir; yönetici değişikliği denetlenir | FROZEN (ürün) | §8.3.2 |
| X-10 | Görsel editör: taslak, test, yayın, tek tıkla eski sürüme dönüş (yeni sürüm olarak); adım paleti §10'daki sekiz adım; koşullar listelerle kurulur; yayın kapısı sonuçları yayından önce gösterilir | FROZEN (ürün) | §10, §11 |
| X-11 | Workflow Mermaid dışa aktarımı | FROZEN (ürün) | Oban `to_mermaid` |
| X-12 | "Neden almadım" ekranı: giriş telefon/e-posta/alıcı kimliği; izin ve tercih durumu; son 30 gün bütün kararlar (gönderilmeyenler dahil) `rule_id` + sözlük cümlesiyle; kapatan tercih seviyesi; sağlayıcı ham yanıtı ayrıntıda; PII maskeli | FROZEN (ürün) | §8.4 |
| X-13 | "Neden almadım" sorusunu 30 saniyede cevaplama hedefi | ENGINEERING ASSUMPTION | Kullanılabilirlik testiyle ölçülür |
| X-14 | Kitle önizlemesi: alıcı sayısı, `rule_id` kırılımlı düşüş, tahmini maliyet | FROZEN (ürün) | §8.5 |
| X-15 | Gönderim modu `live \| shadow \| dry_run \| off` workflow başına; senkron karar hatası yalnız önizleme/test/`dry_run` uçlarında | FROZEN (ürün) | §9 karar ≠ hata |
| X-16 | Inbox bileşeni: zil, rozet, liste; okundu/arşiv/gizle ("sil" etiketi kullanılabilir, kayıt kalır); kategori sekmeleri, önem, erteleme; her bildirimde ilgili tercihe kısayol | FROZEN (ürün) | §15 |
| X-17 | "Tümünü okundu işaretle" yalnız filtreli görünüm, kesme noktası basılma anı, arşivlemez, geri al penceresi, iyimser rozet | FROZEN (ürün) | §8.6 |
| X-18 | Tercih merkezi: JS'siz barındırılan sayfa + gömülebilir bileşen, aynı kaynaktan render | FROZEN (ürün) | EDPB cihazlar arası tutarlılık |
| X-19 | Access + Relay bağlıyken tek "Tercihlerim" ekranı (izinler + bildirim tercihleri), kaynaklar ayrı kalır | FROZEN (ürün) | Access ile birleşik deneyim; §13 |
| X-20 | Tık simetrisi, kabul/ret görsel eşdeğerliği, utandırıcı ret metni yasağı ve EDPB karanlık kalıp yasakları otomatik kabul testidir | KANONİK DEĞİŞMEZ | EDPB 03/2022 |
| X-21 | KVKK kaynaklı üç yasak: izin ekranı atlanabilir; izin özellik erişimine bağlanamaz; aydınlatma ve açık rıza ayrı; `transactional`/`operational` rıza sormaz | KANONİK DEĞİŞMEZ | KVKK; Kurul kararı 2021/389 |
| X-22 | Kilitli kategoriler gerekçesiyle görünür; toplu seçenekler amaç karıştırmaz; barındırılan sayfa yolları kendini açıklar | FROZEN (ürün) | EDPB en iyi uygulamaları |
| X-23 | Gömülebilir webhook portalı: uç nokta ekleme, olay türü seçimi, teslim logu, başarısız teslimi görme ve yeniden gönderme, imza sırrı döndürme, test olayı, uç sağlığı; kiracı markasıyla temalı, dar kapsamlı jetonla | FROZEN (ürün) | Svix App Portal modeli; §16 |
| X-24 | Kiracı başına `live`/`test` ayrı veri düzlemleri; ayrı anahtar ve veri; test anahtarı canlı veriye erişemez; ortam anahtarda taşınır, gövdede değil | KANONİK DEĞİŞMEZ | Gövde alanıyla ortam seçimi sınıfının en tehlikeli hatasıdır |
| X-25 | Test düzleminde bütün hat aynıdır; yalnız son adımda sahte sağlayıcı; test ve canlı aynı `rule_id`'leri üretir; alıcı davranışı aynı | KANONİK DEĞİŞMEZ | Ayrı kod yolu test edilmemiş kod yoludur |
| X-26 | Sahte sağlayıcı belirli adreslere belirli sonuçlar üretir; tablo kodla aynı kaynaktan yayımlanır; test inbox'ı ve tohum alıcılar | FROZEN (ürün) | §8.9 |
| X-27 | Sanal saat yalnız test düzleminde; canlıda hiçbir koşulda yok | KANONİK DEĞİŞMEZ | Güvenliği zayıflatan bayrak yok (Access OP-69 ile uyumlu) |
| X-28 | SDK seti: sunucu TS/Node, Python, Go, Java, .NET, Elixir, PHP, Ruby; istemci tarayıcı JS + React, iOS, Android, React Native, Flutter; OpenAPI/AsyncAPI'den üretim + ince el yazımı katman | MERKEZİ KARAR | Access T41 ile aynı set |
| X-29 | Her sunucu SDK'sında dört zorunlu: otomatik idempotency anahtarı, yalnız `retryable: true`'da üstel + jitter retry ve `Retry-After`, yazılı hata hiyerarşisi, ham gövde webhook doğrulayıcı; SDK sürümü API sürümüne sabit; tembel sayfalama | FROZEN (teknik) | Stripe SDK sürüm sabitleme |
| X-30 | SDK ajan yardımcıları: bekleme noktası oluştur/bekle, posta kutusu oku/ack, "akışı aç + geçmişi listele + kimlikle tekilleştir" | FROZEN (ürün) | §17 |
| X-31 | Mobil SDK sınırı: olay tetiklemez, profil/izin yazmaz, gizli anahtar tutmaz; jeton kaydı, izin durumu, makbuz, diğer cihazdan kaldırma taşır | KANONİK DEĞİŞMEZ | Profil yazımı hesap ele geçirme vektörüdür |
| X-32 | Hazır UI bileşenleri: React birinci sınıf, diğer çatılar web components, altta headless JS SDK; inbox, toast, tercih merkezi, webhook portalı; mobil yerel inbox ve tercih bileşenleri; tema/marka (alt kiracı dahil), yerelleştirme, WCAG 2.2 AA | MERKEZİ KARAR | Access T41, Access TN-133 ile aynı model |
| X-33 | CLI komut seti: `listen --forward-to`, `trigger`, `pull`/`push`/`promote`, `preview`, `logs`; ajan dostu `--json` ve kararlı çıkış kodları; canlıyı değiştiren komut açık onay ister | FROZEN (ürün) | Stripe CLI, Knock CLI |
| X-34 | Geliştirme tüneli CLI'dadır; API'de müşteri tanımlı köprü URL'si yoktur | KANONİK DEĞİŞMEZ | SSRF yüzeyi |
| X-35 | İlk bildirim hedefi 5 dakika: zorunlu kiracı varsayılanları, test düzleminde hazır örnek workflow, kimlik bilgisiz sahte sağlayıcı, tek `curl` ile açık upsert gönderimi | FROZEN (ürün) | ntfy tek `curl` girişi |
| X-36 | 5 dakika hedefinin karşılandığı | ENGINEERING ASSUMPTION | Onboarding kabul testiyle ölçülür |
| X-37 | Belgelerdeki her `curl` ve dil örneği CI'da test ortamına karşı çalışır; limitler/retry takvimleri/garantiler sayfası kodla aynı kaynaktan üretilir; hata gövdesi aşılan limiti söyler | FROZEN (ürün) | Eksik limit sayfası dersi |
| X-38 | Garanti dili: "en az bir kez teslim + kalıcı idempotency ile etkin tek seferlik işlem"; "exactly-once" tek başına kullanılmaz | KANONİK DEĞİŞMEZ | §9 |
| X-39 | MCP sunucusu ve ajan "skills" paketi ürünün ve belgelerin parçasıdır | FROZEN (ürün) | §17 |
| X-40 | Yerel geliştirme resmî `docker compose` ile tek komut; Mailpit, APNs/FCM mock, hata enjeksiyonu vekili; "geliştirme modu" yok | FROZEN (teknik) | Access OP-69 |
| X-41 | Kapsam dışı: çalışma anı köprüsü, yalnız bulut UI, segment/journey kurucu, kiracı betiği çalıştıran dönüşüm editörü, canlıda sanal saat | KAPSAM DIŞI | §8.13 |
