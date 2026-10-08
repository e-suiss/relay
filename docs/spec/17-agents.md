## 17. Ajanlar

Relay ajanlara iki yönde hizmet eder: ajanın insanlara, servislere ve başka ajanlara ulaşmasını sağlar; insandan ya da dış sistemden gelen yanıtı ajana dayanıklı biçimde geri taşır. Bu bölüm ajan alıcısını, bekleme noktasını, kalıcı ajan posta kutusunu, eskalasyonu, yanıt toplamayı, onay güvenliğini, ajana teslim edilen mesajın biçimini, ajan protokollerini ve ajan kaynaklı bildirim tavanını tanımlar.

Bölümün üç temel cümlesi:

1. **Relay bekler ve eşleştirir; yürütmez.** Bekleme noktası, korelasyon ve teslim Relay'indir; yürütme durumu ve devam ettirme bekleyen tarafındır (§17.1).
2. **Relay yanıt toplar; onay vermez.** Gelen yanıt bir kanal olgusudur, yetki kanıtı değildir (§17.8, §17.9).
3. **Ajana prompt değil, yapılandırılmış mesaj gider.** Kontrol bilgisi tipli alanlardadır; insan ya da dış sistem kaynaklı serbest metin "güvenilmez içerik" olarak işaretlidir (§17.11).

### 17.1 Kapsam ve sorumluluk sınırı

| Konu | Relay'in | Bekleyen tarafın (Executor, LangGraph, müşteri kodu) | Access'in | Work'ün (Suiss'te) |
|---|---|---|---|---|
| Bekleme kaydı ("şu anahtara yanıt bekleniyor, son tarih X") | ✓ | – | – | – |
| Yanıtın hangi kanaldan gelirse gelsin eşleştirilmesi | ✓ | – | – | – |
| "Çözüldü / süresi doldu / sahipsiz" olayının bekleyene teslimi | ✓ | – | – | – |
| Checkpoint, pause, takeover, devam ettirme | – | ✓ (Access E31: Executor) | – | – |
| Ajan adımlarını çalıştırma, telafi (saga) | – | ✓ | – | – |
| Onay kararı, risk kademesi, sonuç sınıfı | – | ✓ / sahibi | yüksek riskte ✓ (Access E32, Access EI-18) | ✓ (onay politikası) |
| Eskalasyon politikasının içeriği | uygular | dışarıda tanımlar | – | ✓ (Suiss'te kaynak) |
| İnsanın iş/onay kuyruğu | – | – | – (Access XI-7) | ✓ |
| Ajanın kalıcı posta kutusu | ✓ | okur ve ack'ler | – | – |

Kurallar:

- Relay dayanıklı yürütme motoru değildir. Bekleme noktası bir veritabanı satırı ve bir zamanlayıcıdır; kuyruk slotu, süreç ya da bellek tutmaz (§19'daki "hiçbir iş 1 saati aşmaz" kuralı) (AG-1, AG-4).
- Bekleme noktası Executor'a özel değildir; her ajan sistemi ve müşteri kodu aynı API'yi kullanır (AG-1).
- Relay iş etkisini telafi etmez. Yalnız kendi adımlarını geri alır: bekleme çözülünce ya da iptal edilince bekleyen eskalasyon adımlarını ve henüz yapılmamış teslimleri iptal eder. İş etkisinin telafisi Executor'ün ve domain'indir (AG-3).
- Teslim, ack ve yanıt hiçbir koşulda yetki durumu değildir (Access EI-9, Access E30). Bildirim içeriği yetki değildir: bir ajanı uyandırmak serbesttir; uyanan ajanın ne yapabileceği Access'te belirlenir (AG-2).

### 17.2 Ajan alıcı kaydı ve Access bağı

Ajan, Relay'de birinci sınıf bir alıcı türüdür (insan alıcının ve servis hedefinin yanında).

| Alan | Anlam |
|---|---|
| `id`, `name` | Kiracı içinde benzersiz kimlik ve görünen ad |
| Teslim uçları | Uyandırma ipucunun gideceği yerler: imzalı webhook, A2A push yapılandırması, realtime bağlantı (§17.13, §16) |
| Posta kutusu | Ajan başına tek kalıcı, sıra numaralı kutu (§17.6) |
| Abonelikler | Ajanın abone olduğu topic'ler (§10'daki kitle/topic modeli) |
| Sahip | Ajanın sorumlusu (kiracı; Suiss'te Work). Tavan aşımı ve sessiz bekleme olayları buraya gider (§17.14, §17.15) |
| Access bağı (isteğe bağlı) | Access'teki ajan kimliği (Party/Instance) referansı |
| Durum | `active` / `suspended` / `deleted` (yumuşak silme, §20) |

Kimlik doğrulama:

- **Access bağlıysa:** kayıt Access'teki ajan kimliğine bağlanır; ajan Relay'e Access jetonuyla kimliğini kanıtlar. Access'te ajan askıya alındığında ya da silindiğinde gelen olayla Relay o ajana teslimi ve ajan kaynaklı gönderimi durdurur; posta kutusu silinmez, saklama kuralları geçerlidir (AG-5).
- **Access yoksa:** ajan Relay API anahtarıyla ya da kiracının bağladığı başka bir IdP'nin jetonuyla (standart OIDC) doğrulanır (AG-5).
- Kimlik ve yetki doğruluğu Access'tedir. Relay'deki kayıt teslim içindir; ajanın yetkisini genişletmez ya da daraltmaz (Access EI-9).
- Ajan anahtarlarının kapsamları dardır ve ayrıdır: gönderim, bekleme noktası açma, posta kutusu okuma/ack. Tek "her şey" kapsamı yoktur (§18) (AG-6).

### 17.3 Üç bekleme biçimi (AG-7)

| İhtiyaç | Yapı taşı | Kardinalite | Örnek |
|---|---|---|---|
| Tek cevaplık bekleme | **Bekleme noktası** (§17.4) | Bir kez çözülür | "Bu iadeyi onaylıyor musun?" |
| Çok mesaj | **Posta kutusu** (§17.6) | Sınırsız, sıralı | Uzun işin ilerleme mesajları, başka ajandan gelen görev güncellemeleri |
| Birden çok okuyucu | **Topic aboneliği** (§10) | Bir yayın, çok alıcı | Adlandırılmış sonuç: "rapor hazır" olayını üç ajan bekler |

Workflow'daki "olay bekle" adımı (§10) bekleme noktasıyla aynı yapı taşıdır; aynı eşleme, son tarih ve olay kuralları geçerlidir.

Ajan bildirim tipolojisi gönderim isteğinde açıkça seçilir (AG-8):

| Tür | Yanıt beklentisi | Mesaj sınıfı | Bekleme noktası |
|---|---|---|---|
| **Notify** | Yok | İçeriğe göre (`operational`, `transactional` …) | Yok |
| **Question** | Tek yanıt, şemaya uyan | `action_required` | Zorunlu |
| **Review** | Yapılandırılmış aksiyonlardan biri + kanıt paketi incelemesi | `action_required` | Zorunlu |

Question ve Review öğeleri son kullanma tarihi, yapılandırılmış aksiyon listesi ve (Review'da) kanıt paketi alanı taşır. Kanıt paketi gönderenin yapılandırılmış alanlarıdır (kaynak, beklenen sonuç, yanlışsa zarar); hassas değerler pakette değerle değil özetle (hash) taşınır (AG-8). `action_required` sınıfının digest'lenmezlik, ertelenmezlik ve süre dolumu kuralları §13'tedir.

### 17.4 Bekleme noktası

#### 17.4.1 Nesne

| Alan | Zorunlu | Anlam |
|---|---|---|
| `id` | ✓ | Sunucunun ürettiği kimlik. Kimlik bir yetki bilgisi değildir; bilen yanıtlayamaz (§17.4.3) |
| `waiter` | ✓ | Bekleyen kimlik (ajan alıcısı ya da API anahtarı sahibi) |
| `match` | ✓ | Olay türü + korelasyon anahtarı (§17.4.5) |
| `condition` | – | İkinci aşama koşulu (§17.4.5) |
| `response_schema` | Question/Review'da ✓ | Kabul edilen yanıtın JSON Schema'sı (2020-12) |
| `responders` | Question/Review'da ✓ | Yanıt verebilecek alıcı kümesi. Küme üreticinindir; Relay genişletmez ya da daraltmaz (AG-12) |
| `expires_at` | ✓ | Toplam son tarih; ≤ 30 gün (§10'daki sert süre limitleri) |
| `heartbeat_interval` | – | Bekleyenin canlılık aralığı (§17.4.6) |
| `escalation_policy` | – | Eskalasyon politikası referansı (§17.5) |
| `default_response` | – | Süre dolunca bekleyene iletilecek, baştan beyan edilmiş varsayılan yanıt (§17.5) |
| `subject_digest` | Question/Review'da ✓ | İşin yapılandırılmış alanlarının özeti; yanıt buna bağlanır (Suiss'te Access intent digest) |
| `content` | Question/Review'da ✓ | İnsana gösterilecek isteğin tipli alanları (eylem türü, hedef, tutar, kaynak …) |
| `claim_text` | – | Ajanın serbest açıklaması; "ajanın iddiası" olarak ayrı gösterilir (§17.9) |
| `deliver_to` | ✓ | Sonuç olayının gideceği yer: bekleyenin posta kutusu (varsayılan), ek olarak topic |
| `tags` | – | Listeleme ve filtre için |
| `state`, `resolution` | sunucu | §17.4.2, §17.8 |

Oluşturma isteği diğer bütün değişiklik istekleri gibi Idempotency-Key ister (§9). Son tarih ilk kayıt anında kalıcı hâle gelir; tekrar denemeler aynı son tarihi korur. Sonsuz ya da örtük varsayılan son tarih yoktur (AG-9).

#### 17.4.2 Durumlar

| Durum | Anlam | Terminal |
|---|---|---|
| `open` | Yanıt bekleniyor | Hayır |
| `stalled` | Bekleyenin heartbeat'i kesildi; bekleme sahipsiz işaretlendi, eskalasyon durdu | Hayır |
| `resolved` | Geçerli bir yanıt kaydedildi | Evet |
| `expired` | Toplam son tarih doldu | Evet |
| `cancelled` | Bekleyen ya da yetkili operatör iptal etti | Evet |

Geçişler: `open → resolved | expired | cancelled | stalled`; `stalled → open` (heartbeat geri gelince; eskalasyon kaldığı kademeden sürer) `| resolved | expired | cancelled`. `stalled` durumundaki bekleme yanıt kabul etmeye devam eder ve toplam son tarih işlemeye devam eder; yanıt kaybolmaz, bekleyen döndüğünde posta kutusundan okur (AG-10).

Bekleme listelenebilir, sorgulanabilir ve iptal edilebilir. "Hangi istekler yanıt bekliyor" sorgusu (`open` ve `stalled`) her kiracıya ve her bekleyene açıktır (AG-46).

#### 17.4.3 Değişmezler

Aşağıdakiler veritabanı kısıtı olarak uygulanır; uygulama kodunun doğru davranmasına bırakılmaz (AG-11):

1. **Yanıtlayan ≠ bekleyen.** Bekleyen kimlik kendi bekleme noktasını çözemez.
2. **Yanıtlayan, `responders` kümesindedir;** isteği açan oturumun kimliği ile yanıtı gönderen kimlik aynıdır (başlatan = tamamlayan).
3. **Süresi geçmiş bekleme çözülemez;** son tarihten sonra gelen yanıt reddedilir ve reddedildiği kaydedilir.
4. **Çözülmüş bekleme değişmez;** yanıt sonradan düzeltilemez, geri alınamaz, ikinci yanıt kabul edilmez.
5. **Şemaya uymayan yanıt kaydedilmez.** Doğrulama kayıttan önce yapılır; geçersiz yanıt hiç yazılmaz, yanıtlayana senkron hata döner.
6. **Yanıt işin özetine bağlıdır.** Yanıt kaydı `subject_digest`'i taşır; X için verilen yanıt Y için kullanılamaz.
7. **Durum bekleme satırındadır.** Sinyal, uyandırma ipucu ya da yanıt payload'ı kayıt sistemi değildir.

#### 17.4.4 Erken gelen yanıt

Yanıt (ya da beklenen olay) bekleme noktası açılmadan önce gelebilir. Erken yanıt bekleyenin kalıcı posta kutusunda korelasyon anahtarıyla tamponlanır. Bekleme noktası açıldığında önce kutuya bakılır; eşleşen kayıt varsa bekleme o anda çözülür. Erken yanıt hiçbir koşulda kaybolmaz; "yalnız beklemeden sonra gelen olay sayılır" penceresi yoktur (AG-13). Tampondaki kayıt posta kutusunun saklama kurallarına tabidir (§17.6).

#### 17.4.5 İki aşamalı eşleme

1. **Birinci aşama — birebir anahtar:** `(kiracı, ortam, olay türü, korelasyon anahtarı)` tek bir indeksle eşleşir. Erken ve sırasız gelen olaylar dahil bütün eşleme buradan geçer.
2. **İkinci aşama — isteğe bağlı koşul:** yalnız birinci aşamada eşleşen bekleyenlerde değerlendirilir. Koşul dili workflow koşul adımının basit kural dilidir (§10); görsel editörde aynı listelerle kurulur (§8).

Joker, önek ya da serbest metin eşlemesi yoktur (AG-14). Eşleşmeyen olay `rule_id` ile kaydedilir ve görünür kalır.

#### 17.4.6 İki zaman aşımı

| Zaman aşımı | Soru | Sonuç |
|---|---|---|
| Toplam süre (`expires_at`) | İnsan geç mi kaldı? | `expired` + `waitpoint.expired` olayı |
| Heartbeat (`heartbeat_interval`) | Bekleyen öldü mü? | `stalled` + `waitpoint.stalled` olayı; eskalasyon durur |

İki süre ayrı ayarlanır ve ayrı olay üretir (AG-15). Heartbeat ayarlanmamışsa yalnız toplam süre geçerlidir.

#### 17.4.7 Olaylar

`waitpoint.created`, `waitpoint.escalated`, `waitpoint.resolved`, `waitpoint.expired`, `waitpoint.cancelled`, `waitpoint.stalled`, `waitpoint.response_rejected`. Olaylar §16'daki ortak teslim motoruyla ve bekleyenin posta kutusuna gider; adlar ve şemalar AsyncAPI olay kataloğunda tanımlıdır (§9) (AG-16).

### 17.5 Eskalasyon zinciri

Eskalasyon politikası adlandırılmış, sürümlü ve yeniden kullanılabilir bir tanımdır; panelde, dosyada ve SDK'da yazılır (§8, §10) (AG-17).

- **Kademe:** süre → yeni alıcı ve/veya daha müdahaleci kanal. Örnek: "A 2 saatte yanıtlamazsa A'ya SMS ve B'ye push; 8 saatte C" (AG-17).
- **Son kademe yalnız olay üretir:** `waitpoint.expired`. Relay otomatik ret ya da otomatik kabul kararı vermez. Bu karar sahibindedir: Suiss'te Work/Access, dışarıda müşteri kodu ya da bekleme noktasında baştan beyan edilmiş `default_response`. Varsayılan yanıt `expired` olayının içinde bekleyene iletilir; Relay onu bir yanıt olarak kaydetmez ve `resolution` alanına yazmaz (AG-18).
- **Suiss'te** eskalasyon politikası Work'ten gelir; Relay uygular (AG-17).
- **Durma:** bekleme `resolved`, `cancelled` ya da `stalled` olduğunda bekleyen kademeler iptal edilir (AG-19).
- **Ortak zamanlayıcı:** eskalasyon ile "görülmezse yükselt" kanal yükseltmesi (§10) aynı zamanlayıcı mekanizmasını kullanır. Kanal yükseltmesi aynı kişiye başka kanal; eskalasyon başka kişi ve son eylemdir (AG-19).
- Eklenen her yeni alıcı da `responders` kümesinde olmak zorundadır; eskalasyon alıcı kümesini politikanın dışına genişletemez (AG-12).

### 17.6 Kalıcı ajan posta kutusu

Posta kutusu, inbox ile aynı kalıcı kayıt çekirdeğinin ajan yüzüdür (§15) (AG-20).

| Özellik | Kural |
|---|---|
| Çekirdek | Alıcı başına sıra numaralı kalıcı kayıt + cursor + outbox |
| İnsan yüzü | görüldü / okundu / arşiv / gizle (§15) |
| Ajan yüzü | **lease → ack.** Ajan bir ya da daha fazla mesajı lease ile alır; ack süresi içinde gelmezse mesaj yeniden teslim edilir |
| Uyanma | Ajan uyanınca son ack'lediği sıra numarasından itibaren kaçırdıklarını sırayla alır |
| Uyandırma ipucu | Push, webhook ve A2A push yalnız "uyan" ipucudur; mesaj kutuda bekler. İpucunun kaybolması mesajı kaybettirmez (AG-21) |
| Teslim garantisi | En az bir kez; ajan mesaj kimliğiyle tekilleştirir |
| İçerik | Yapılandırılmış mesaj (§17.11) |
| Saklama | Fiziksel silme yoktur; saklama ve silme Access OP-73/Access OP-74 ve Access Ek C'ye tabidir (§20) (AG-23) |
| Sahiplik | Bu kutu ajanın kutusudur. İnsanın iş/onay kuyruğu Work'ündür (Access XI-7) (AG-23) |

Lease süresi ve yeniden teslim sayısı kiracı ayarıdır; üst sınırları vardır. Yeniden teslim sayısını aşan mesaj kutunun ölü mektup görünümüne alınır, silinmez ve sahibine olay gider (AG-22).

Push her zaman ipucudur, durum kaynaktır: her teslim dayanıklı bir handle ve sorgu ucu taşır (AG-21). İstemci ve ajan SDK'ları "önce akışı aç, sonra geçmişi listele, kimlikle tekilleştir" kalıbını gömülü taşır (§8).

### 17.7 Sıra garantisi (AG-24)

- Teslim sırası garanti edilmez. Garanti edilen **okuma sırasıdır.**
- Her posta kutusu ve her akış monoton bir sıra numarası taşır. Sıra numarası commit sırasına dayanır, kimlik sırasına değil.
- Alıcı boşluğu görür ve `since=seq` ile tamamlar; yeniden bağlanan alıcı kaldığı numaradan sırayla okur.
- Kafka gibi bölümlü hedeflerde sıra anahtarı hedefin bölüm anahtarına eşlenir (§16).

### 17.8 Yanıt toplayıcı rolü ve kanıt düzeyi

Relay yanıt toplayıcıdır, onay kapısı değildir. Karar isteğini teslim eder, yanıtı toplar ve sahibine iletir. "Onay" kararı, risk kademesi ve uygulama sahibindedir. Sonuç sınıfı ve risk kademesi Relay'de üretilmez; sahibinden etiket olarak gelir (AG-25).

Yanıt kaydı (`resolution`):

| Alan | Anlam |
|---|---|
| `value` | Şemaya uyan yanıt değeri |
| `responder` | Yanıtlayan kimlik |
| `channel` | Yanıtın geldiği kanal (inbox, push aksiyonu, SMS, e-posta, mesajlaşma kanalı, API) |
| `evidence_level` | Kanal kanıt düzeyi (aşağıda) |
| `responded_at` | Sunucu zamanı |
| `subject_digest` | Yanıtın bağlandığı iş özeti |

Kanıt düzeyleri (AG-26):

| Düzey | Anlam | Örnek |
|---|---|---|
| `channel_claim` | Kanalın beyanı; kimlik kanal kimliğine dayanır | SMS yanıtı, e-posta yanıtı, mesajlaşma kanalı butonu |
| `relay_session` | Relay abone jetonuyla doğrulanmış oturumda verilen yanıt | Inbox bileşeninde verilen yanıt |
| `access_aas_ref` | Access onay yüzeyinde verilmiş kararın referansı | CIBA daveti sonrası Access onayı |

API'de alan adı `response` ya da `decision`dır; "approval" adı kullanılmaz (AG-26).

- **Access'siz kurulum:** isteğe bağlı basit karar kaydı tutulur ve "kanal yanıtı, yetki kanıtı değil" diye etiketlenir (AG-27).
- **Access'li kurulum:** yüksek riskli onaylar Access onay yüzeyine (CIBA) gider. Access OP'dir; Relay daveti `action_required` sınıfında teslim eder. Onay Access'te verilir; Relay Access'ten gelen sonuç olayıyla bekleme noktasını `access_aas_ref` düzeyinde kapatır (Access E32, Access EI-18, Access E40) (AG-27).
- Ajan onayı oturuma/göreve aittir: istek kullanıcının bütün cihazlarına ve kanallarına gider ve bir kez çözülür (AG-28).

### 17.9 Onay güvenliği

| # | Kural | Neyi önler |
|---|---|---|
| 1 | İnsana gösterilen istek metni işin yapılandırılmış alanlarından (`content`) sunucuda üretilir. Ajanın serbest metni (`claim_text`) ayrı alanda, "ajanın iddiası" etiketiyle, render edilmeden gösterilir; Markdown ve HTML kapalıdır (AG-29) | Onay diyaloğu sahteciliği (Lies-in-the-Loop) |
| 2 | Yanıt jetonu ve yanıt bağlantısı ajanın bağlamına girmez: bekleyene dönen hiçbir API yanıtında, olayda ya da posta kutusu mesajında bulunmaz; yalnız insan kanallarına teslim edilir (AG-30) | Ajanın kendi isteğini onaylaması |
| 3 | Yanıtlayan ≠ bekleyen; başlatan = tamamlayan (§17.4.3) | Kendi kendine onay, oltalama ile başkasına onaylatma |
| 4 | Callback yetkisi varsayılan olarak kimliğe bağlıdır. Bearer jeton gerekiyorsa tek kullanımlık, kısa ömürlü ve tek bekleme noktasına kapsamlıdır; son tarih dolunca ya da yeniden gönderimde döndürülür (AG-31) | Bilen tamamlar saldırısı, geç gelen eski bağlantının yeni bekleyeni uyandırması |
| 5 | Süresi geçmiş yanıt reddedilir; yanıt değişmez; yanıt işin özetine bağlıdır | Geç onay, yeniden oynatma, X'i onaylatıp Y'yi çalıştırma |
| 6 | Inbox eylem butonu, push aksiyonu, kilit ekranı yanıtı, SMS yanıtı ve mesajlaşma kanalı butonu hiçbir zaman onay değildir. Onay türündeki öğede eylem yalnız Access onay yüzeyine derin bağlantıdır (Access EI-18, Access XI-8) (AG-32) | Kanal yanıtının yetki sanılması |
| 7 | Mobilde kilit ekranından yanıt yoktur; iOS'ta aksiyonlar `authenticationRequired` taşır. Yüksek sonuçlu sınıfta bildirim yalnız davettir; satır içi yanıta hangi sınıfın izin verdiğini sahibi belirler (AG-33) | Kilitli cihazdan başkasının yanıtlaması |
| 8 | Bildirimi kimin gönderdiği (insan / sistem / ajan) her yüzeyde görünür (AG-34) | Ajan mesajının insan mesajı sanılması |

**Kanal üstü yanıt deneyimi.** Yanıt anında ack'lenir, asenkron işlenir. Kart ya da öğe "işleniyor → yanıtlandı (kim, ne zaman)" olarak güncellenir; tekrar tıklama idempotenttir; yanıt bütün cihaz ve kanallardaki kopyalara yansır (AG-35). Bekleme çözülünce ya da süresi dolunca diğer kopyalar "artık yanıt beklenmiyor" durumuna geçer.

### 17.10 Uzun iş bitişi ve gelen ajan olayları

- Uzun iş bitişi bildirimi Standard Webhooks ile gönderilir; gelen uzun iş bildirimleri (ör. model sağlayıcılarının arka plan iş webhook'ları) aynı doğrulayıcıyla doğrulanır (§16) (AG-36).
- Gelen ajan bildiriminde `(görev, seq)` ile tekilleştirme yapılır; sırasız gelen bildirim yenisini ezmez. Bildirim "durumu yeniden oku" ipucudur; gerektiğinde durum kaynaktan yeniden okunarak mutabakat yapılır (AG-37).
- Gelen mesaja güven etiketi verilir: `authenticated | unauthenticated | spam | blocked`. Etiket olay türünde görünür; ajan uyandırılmadan önce ajanın (ya da yönlendirme kuralının) etikete göre karar vermesi mümkündür. `spam` ve `blocked` etiketli mesajlarla uyandırma açık abonelik ister (AG-38).

### 17.11 Yapılandırılmış mesaj ilkesi ve güvenilmez içerik işareti

Ajana teslim edilen şey prompt değil, yapılandırılmış mesajdır. Relay ajana hiçbir zaman serbest metin talimat yazmaz (AG-39).

| Katman | İçerik |
|---|---|
| Dış zarf | CloudEvents (yalnız dış zarf); zarf kiracı anahtarıyla imzalıdır (AG-40) |
| Kontrol alanları (tipli) | Mesaj türü, bekleme noktası kimliği, sonuç, yanıtlayan, kanal, kanal kanıt düzeyi, iş özeti, sıra numarası, güven etiketi |
| İçerik parçaları | A2A `parts[]` biçimi: `TextPart` / `DataPart`, `mediaType`; her parçada `audience` (MCP `annotations.audience` karşılığı) |
| Güvenilmez içerik | İnsan ya da dış sistem kaynaklı serbest metin ayrı parçada, "güvenilmez içerik" işaretiyle ve kaynak bilgisiyle: yazan, doğrulandı mı, kanal |

Kurallar:

- Güvenilmez metin sınır işaretleriyle çevrilir; işaret metnin içinde geçiyorsa kaçırılır (AG-40).
- Güvenilmez metin ajana görünür metne normalleştirilmiş olarak verilir: gizli HTML, görünmez karakterler ve görsel olarak saklanan metin ayıklanır; ham içerik gerekiyorsa ayrı bir referansla, aynı işaretle alınır (AG-40).
- Kontrol alanlarına serbest metin girmez; serbest metin kontrol alanı yerine geçemez.
- Mesajdaki bağlantılar doğrulanmadan açılacak ham URL değildir; eylem bağlantıları kiracının izin listesindeki hedeflere gider (§12).

### 17.12 Prompt injection savunmaları

Bildirim akışı yapısı gereği güvenilmez içerik taşır. Savunmanın ilkesi filtreleme değil ayrıcalık ayrımıdır (AG-41).

| Tehdit | Relay'in savunması | Ajan tarafına bırakılan (rehberde belgelenir) |
|---|---|---|
| Gelen metnin talimat gibi okunması | §17.11 yapılandırılmış mesaj, güvenilmez içerik işareti, kaynak bilgisi | Güvenilmez içeriği ayrıcalıksız bağlamda işlemek (ör. çift model deseni) |
| Sahte bildirimle ajanı yönlendirme | Kiracı anahtarıyla imzalı zarf; gelen mesaja güven etiketi | İmzayı doğrulamadan işlem yapmamak |
| Onay diyaloğunun manipülasyonu | Sunucu tarafı render, `claim_text` ayrımı, Markdown/HTML kapalı (§17.9) | – |
| Ajanın kendi onayını üretmesi | Jeton ajana girmez, yanıtlayan ≠ bekleyen (§17.9) | – |
| Bildirimle yetki kazanma | Bildirim içeriği yetki değildir; yetki Access'te (Access EI-9) | Her eylemden önce yetki kararı almak |
| Gizli metinle veri sızdırma | Görünür metne normalleştirme; bağlantı izin listesi | Dış çağrı yeteneği ile güvenilmez içerik ve özel veriyi aynı bağlamda birleştirmemek |
| Protokol üzerinden kapı atlatma | MCP/A2A yanıtı onay değildir; protokoller onay kapısını atlayamaz (§17.13) | – |

### 17.13 Ajan protokolleri

#### 17.13.1 A2A

- A2A v1.0 push bildirimlerini **alma** ve **gönderme** desteklenir; görev yaşam döngüsü olayları taşınır (AG-42).
- A2A'nın tanımlamadığı retry, imza (Standard Webhooks profili, §16), DLQ, replay ve SSRF koruması Relay'in ortak teslim motorundan gelir (AG-42).
- Gelen A2A olayları `(task, seq)` ile idempotent işlenir; durum gerekirse `GetTask` ile yeniden okunur (AG-42).
- Push yapılandırması okunurken saklanan kimlik bilgileri her zaman redakte edilir (AG-42).
- `A2A-Version` başlığı gönderilir ve doğrulanır.

#### 17.13.2 MCP

- Relay bir MCP sunucusu sunar. Araçlar: bildirim gönder, bekleme noktası aç, bekleme durumunu oku, yanıt bekleyen istekleri listele, posta kutusunu oku, ack'le, topic'e abone ol (AG-43).
- Sunucu MCP 2026-07-28 sürümüne göre durumsuzdur ve yalnız araç çağrısı sunar; sunucunun istemciden girdi istediği akışlar (`sampling`, form ile kimlik bilgisi isteme) kullanılmaz (AG-43).
- MCP Tasks `input_required` durumu bekleme noktasına eşlenir (AG-43).
- Araç kataloğu çağıranın anahtar kapsamına göre daralır; yetkisiz çağrı ayrıca reddedilir. İnsana yönelik bekleme noktasını yanıtlayan bir araç yoktur (AG-43).
- MCP sunucusu ile birlikte ajanlar için bir "skills" paketi yayımlanır (§8) (AG-43).

#### 17.13.3 AG-UI

AG-UI olayları realtime kanalda (§15) opak yük olarak taşınır; Relay yorumlamaz, değiştirmez, sıralama ve kurtarma kurallarını (`since` cursor) aynen uygular (AG-44).

#### 17.13.4 Ortak kurallar

- MCP ya da A2A üzerinden gelen yanıt Access onayı değildir (Access A-6, Access AG-33, Access EI-18). Protokoller onay kapısını atlayamaz; içerik §17.11'e tabidir (AG-45).
- Protokol sürümü değişse de Relay'in iç bekleme modeli değişmez; protokol yalnız eşleme tablosunda değişir (AG-47).

#### 17.13.5 Durum eşleme tablosu (AG-46)

| Relay bekleme durumu | A2A | MCP Tasks | Anthropic Managed Agents |
|---|---|---|---|
| `open` (Question/Review) | `INPUT_REQUIRED` | `input_required` | `requires_action` (bekleyen olay kimlikleri listesiyle) |
| `open` (Access onay daveti) | `AUTH_REQUIRED` | `input_required` | `requires_action` |
| `stalled` | değişmez; sahibine `waitpoint.stalled` | değişmez | değişmez |
| `resolved` | bekleyen sürdürür (`WORKING`) | `working` | `running` |
| `expired` / `cancelled` | sahibin kararı; Relay yalnız olayı iletir | sahibin kararı | sahibin kararı |

Görev durumunun kendisi bekleyen tarafındır; tablo Relay'in bekleme noktasını protokolün diline kayıpsız çevirir.

### 17.14 Ajan kaynaklı bildirim ve tavan

- Gönderen türü (insan / sistem / ajan) mesaj sınıfından ayrı bir alandır (§13). Ajan kaynaklı bildirim, gönderen türü `agent` olan bildirimdir.
- Gönderen türü `agent` olan bildirimler ajan başına tavana tabidir. Tavan, frekans tavanından (§13) ve throttle'dan (§10) ayrıdır (AG-48). Ajan başına tavan değeri politika varsayılanıdır; bağlı özellik yapım sırasına girerken ölçümle konur (F-28) (AG-51).
- **Tavan aşılınca:** bildirimler gönderilmez ve silinmez; kalıcı olarak bekletilir. Sahibine (kiracı; Suiss'te Work) `agent.ceiling_exceeded` olayı gider. Sahibi bekletilen örnekleri görür ve üç karardan birini verir: hepsini gönder / iptal et / ajanı durdur. Karar denetim kaydına girer (§18) (AG-49).
- **Fail-closed:** tavan sayacı Valkey'de okunamazsa Postgres yedek sayacına düşülür (§19); yedek de okunamıyorsa ajan kaynaklı bildirimler bekletilir. İnsan ve sistem kaynaklı bildirimler bundan etkilenmez; onların frekans tavanı kendi (fail-open) kuralıyla çalışır (AG-50).
- Bekletilen bildirimler kendi `expires_at` değerlerini korur; serbest bırakıldıklarında süresi geçmiş olanlar `expired` olur, gönderilmez (AG-49).
- Ajanın uzun iş ilerlemesi için Live Activities ve Android ProgressStyle yüzeyleri kullanılır; bunlar konu bazlı collapse modeline eşlenir (§12) (AG-52).

### 17.15 Kaynak sınırları ve operasyon alarmları

**Kaynak sınırları.** Aşağıdakiler yayımlanmış limitler sayfasında (§8) ve hata gövdesinde görünür; sayısal değerler ölçümle konur, üst sınırlar §10'daki sert süre limitlerindedir (AG-53):

| Sınır | Not |
|---|---|
| Bekleme noktası başına mesaj ve eskalasyon kademesi sayısı | – |
| Yanıt ve mesaj payload boyutu | Aşan güvenilmez içerik referansla taşınır |
| Azami bekleme süresi | ≤ 30 gün |
| Kiracı ve bekleyen başına eşzamanlı açık bekleme | – |
| Posta kutusu lease süresi ve yeniden teslim sayısı | Kiracı ayarı, üst sınırlı |

**Operasyon alarmları.**

- Sessiz bekleme ve sessiz görev sayımla alarm üretir: sessizliğin hata sinyali olmadığı için alarm hata sayacına değil, belirli süredir durumu değişmeyen bekleme ve görev sayısına bakar (AG-54).
- Yanıt oranı düşerken bekleme hacmi artarsa ya da yanıt süresi anormal kısalırsa ("otomatik kabul makinesi" belirtisi) alarm üretilir (AG-54).
- `stalled` bekleme sayısı, eskalasyonla çözülen bekleme oranı ve kanıt düzeyi dağılımı panelde görünür (§8, §14).

### 17.16 Kapsam dışı (AG-55)

| Konu | Gerekçe |
|---|---|
| Dayanıklı yürütme, checkpoint, saga/telafi | Bekleyen tarafın işidir (Access E31); Relay bekler ve eşleştirir |
| Onay kapısı olmak, risk kademesi üretmek | Yetki Access'te, onay politikası sahibindedir |
| Otomatik ret/kabul kararı vermek | Sahibinin kararıdır; Relay yalnız `waitpoint.expired` üretir |
| Ajana serbest metin talimat yazmak, LLM ile içerik üretmek | Prompt injection yüzeyi; Relay yapılandırılmış mesaj taşır |
| İnsan iş/onay kuyruğu | Work'ündür (Access XI-7) |
| Sohbet/konuşma yönetimi (çok kanallı ajan sohbet ürünü) | Relay teslim ve bekleme katmanıdır; konuşma durumu ajan sisteminindir |

### 17.17 Karar register'ı

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| AG-1 | Bekleme noktası, korelasyon ve teslim Relay'in; yürütme durumu, checkpoint, pause, takeover ve devam bekleyen tarafın. Relay dayanıklı yürütme motoru değildir; bekleme noktası her ajan sistemine ve müşteri koduna açıktır | MERKEZİ KARAR | Access E31; §17.1 |
| AG-2 | Teslim, ack ve yanıt yetki durumu değildir; bildirim içeriği yetki değildir, uyandırma serbest, yetki Access'te | KANONİK DEĞİŞMEZ | Access EI-9, Access E30, Access E40 |
| AG-3 | Relay iş etkisini telafi etmez; yalnız kendi adımlarını (eskalasyon, bekleyen teslimler) geri alır | FROZEN (ürün) | §17.1 |
| AG-4 | Bekleme noktası satır + zamanlayıcıdır; kuyruk slotu ve süreç tutmaz | FROZEN (teknik) | §19 iş süresi kuralı |
| AG-5 | Ajan kaydı Relay'dedir (ad, teslim uçları, posta kutusu, abonelikler, sahip); Access bağlıysa Party/Instance'a bağlanır, ajan Access jetonuyla doğrulanır, Access askı/silme olayıyla teslim durur; Access yoksa API anahtarı ya da başka IdP jetonu | FROZEN (ürün) | Access E40; §17.2 |
| AG-6 | Ajan anahtar kapsamları dar ve ayrıdır (gönder, bekleme aç, posta kutusu oku/ack); tek "her şey" kapsamı yok | FROZEN (teknik) | En az yetki |
| AG-7 | Üç bekleme biçimi: tek seferlik bekleme noktası, çok mesajlı posta kutusu, çok okuyuculu topic aboneliği | FROZEN (ürün) | §17.3 |
| AG-8 | Ajan bildirim tipolojisi Notify / Question / Review; Question ve Review `action_required` sınıfındadır ve bekleme noktası zorunludur; kanıt paketinde hassas değerler özetle | FROZEN (ürün) | §17.3 |
| AG-9 | Her bekleme sonludur: `expires_at` zorunlu, ≤ 30 gün, ilk kayıtta kalıcılaşır; örtük sonsuz varsayılan yok | KANONİK DEĞİŞMEZ | §10 sert süre limitleri |
| AG-10 | Bekleme durumları `open`, `stalled`, `resolved`, `expired`, `cancelled`; `stalled` yanıt kabul eder, toplam süre işler, heartbeat dönünce `open`'a geçer ve eskalasyon kaldığı kademeden sürer | FROZEN (ürün) | §17.4.2 |
| AG-11 | Bekleme değişmezleri DB kısıtıdır: yanıtlayan ≠ bekleyen; yanıtlayan `responders` kümesinde ve başlatan = tamamlayan; süresi geçmiş bekleme çözülemez; çözülmüş bekleme değişmez; şemaya uymayan yanıt kaydedilmez (önce doğrulama); yanıt `subject_digest`'e bağlı; durum satırda, payload kayıt sistemi değil | KANONİK DEĞİŞMEZ | MCP URL elicitation oltalama dersi; CIBA `binding_message` |
| AG-12 | Alıcı kümesi üreticinindir; Relay ne bekleme noktasında ne eskalasyonda kümeyi genişletir ya da daraltır | KANONİK DEĞİŞMEZ | Access §7.9.8.2 |
| AG-13 | Erken gelen yanıt bekleyenin kalıcı posta kutusunda tamponlanır; bekleme açılınca önce kutuya bakılır; erken yanıt hiçbir koşulda kaybolmaz | KANONİK DEĞİŞMEZ | DBOS/Temporal modeli; Inngest pencere hatasından kaçınma |
| AG-14 | İki aşamalı eşleme: (kiracı, ortam, olay türü, korelasyon anahtarı) birebir tek indeks; isteğe bağlı koşul yalnız eşleşenlerde, workflow koşul diliyle; joker eşleme yok | FROZEN (teknik) | §10 koşul dili |
| AG-15 | İki zaman aşımı: toplam süre (`expired`) ve heartbeat (`stalled`, eskalasyon durur); ayrı ayarlanır, ayrı olay üretir | FROZEN (ürün) | AWS Step Functions `HeartbeatSeconds` modeli |
| AG-16 | Bekleme olay seti: `waitpoint.created/escalated/resolved/expired/cancelled/stalled/response_rejected`; AsyncAPI kataloğunda | FROZEN (ürün) | §9 |
| AG-17 | Yerleşik eskalasyon politikası: kademe = süre → yeni alıcı ve/veya daha müdahaleci kanal; panel/dosya/SDK; Suiss'te politika Work'ten | FROZEN (ürün) | Sektörde yerleşik eskalasyon sunan bekle/devam motoru yok |
| AG-18 | Son kademe yalnız `waitpoint.expired` üretir; otomatik ret/kabul sahibindedir; `default_response` olayla iletilir, yanıt olarak kaydedilmez | KANONİK DEĞİŞMEZ | Relay yetki kaynağı olmaz |
| AG-19 | Eskalasyon ve kanal yükseltmesi aynı zamanlayıcıyı paylaşır; bekleme çözülünce/iptal/sahipsiz olunca bekleyen kademeler iptal edilir | FROZEN (teknik) | §10 |
| AG-20 | Kalıcı ajan posta kutusu: alıcı başına sıra numaralı kayıt + cursor + outbox; insan yüzü görüldü/okundu/arşiv/gizle, ajan yüzü lease → ack, süresinde ack yoksa yeniden teslim; uyanınca son ack'lenen numaradan sırayla | FROZEN (ürün) | §15 ortak çekirdek |
| AG-21 | Push, webhook ve A2A push yalnız uyandırma ipucudur; mesaj kutuda bekler; her teslim dayanıklı handle + sorgu ucu taşır | KANONİK DEĞİŞMEZ | MCP ve A2A teslim garantisi vermez |
| AG-22 | Lease süresi ve yeniden teslim sayısı kiracı ayarıdır, üst sınırlıdır; aşan mesaj ölü mektup görünümüne alınır, silinmez, sahibine olay gider | POLICY DEFAULT | Değerler ölçümle konur |
| AG-23 | Posta kutusu saklaması fiziksel silmesizdir; Access OP-73/Access OP-74 ve Access Ek C'ye tabidir. Posta kutusu ajanındır; insan iş kuyruğu Work'ündür | KANONİK DEĞİŞMEZ | Access OP-73, Access OP-74, Access XI-7 |
| AG-24 | Teslim sırası garanti edilmez; posta kutusu/akış başına commit sırasına dayalı monoton sıra numarası; garanti okuma sırasıdır; `since=seq` ile boşluk tamamlanır; bölümlü hedefte sıra anahtarı bölüm anahtarına eşlenir | FROZEN (teknik) | §16, §15 |
| AG-25 | Relay yanıt toplayıcıdır, onay kapısı değildir; yanıt kaydı değer, yanıtlayan, kanal, kanal kanıt düzeyi, zaman ve iş özeti taşır; sonuç sınıfı ve risk kademesi sahibinden etiket olarak gelir | MERKEZİ KARAR | Access EI-18, Access E32 |
| AG-26 | Kanal kanıt düzeyleri `channel_claim` / `relay_session` / `access_aas_ref`; API alan adı `response`/`decision`, "approval" değil | FROZEN (ürün) | §17.8 |
| AG-27 | Access'siz kurulumda isteğe bağlı basit karar kaydı "kanal yanıtı, yetki kanıtı değil" etiketiyle; Access'li kurulumda yüksek riskli onay Access onay yüzeyinde (CIBA), Relay daveti teslim eder ve sonucu `access_aas_ref` ile kaydeder | FROZEN (ürün) | Access E32, Access E40, Access EI-18 |
| AG-28 | Ajan onayı oturuma/göreve aittir: istek kullanıcının bütün cihazlarına gider, bir kez çözülür | FROZEN (ürün) | §17.8 |
| AG-29 | İstek metni yapılandırılmış alanlardan sunucuda render edilir; ajan metni "ajanın iddiası" olarak ayrı ve render'sız; Markdown/HTML kapalı | KANONİK DEĞİŞMEZ | Lies-in-the-Loop; Access A-6, Access XI-8 |
| AG-30 | Yanıt jetonu ve bağlantısı ajanın bağlamına girmez; yalnız insan kanallarına teslim edilir | KANONİK DEĞİŞMEZ | MCP URL modu ilkesi |
| AG-31 | Callback yetkisi kimliğe bağlıdır; bearer gerekiyorsa tek kullanımlık, kısa ömürlü, tek bekleme kapsamlı, son tarihte/yeniden gönderimde döndürülür | FROZEN (teknik) | AWS Step Functions token rotasyonu; Trigger.dev waitpoint token |
| AG-32 | Inbox butonu, push aksiyonu, kilit ekranı, SMS ve mesajlaşma kanalı yanıtı onay değildir; onay öğesinde eylem yalnız Access onay yüzeyine derin bağlantıdır | KANONİK DEĞİŞMEZ | Access EI-18, Access XI-8, Access A-5 |
| AG-33 | Mobilde kilit ekranından yanıt yok, iOS `authenticationRequired`; yüksek sonuçlu sınıfta bildirim yalnız davet; satır içi yanıt izni sahibinde | FROZEN (ürün) | §17.9 |
| AG-34 | Gönderen türü (insan/sistem/ajan) her yüzeyde görünür | FROZEN (ürün) | §17.9 |
| AG-35 | Kanal üstü yanıt: anında ack, asenkron işleme, "işleniyor → yanıtlandı (kim, ne zaman)", tekrar tıklama idempotent, yanıt bütün kopyalara yansır | FROZEN (ürün) | Slack 3 sn ack, Teams Universal Actions |
| AG-36 | Uzun iş bitişi Standard Webhooks ile gönderilir; gelen uzun iş bildirimleri aynı doğrulayıcıyla doğrulanır | FROZEN (teknik) | OpenAI ve Anthropic aynı şemayı kullanır |
| AG-37 | Gelen ajan bildiriminde `(görev, seq)` tekilleştirme ve kaynaktan yeniden okuyarak mutabakat | FROZEN (teknik) | A2A retry/sıra tanımsız |
| AG-38 | Gelen mesaja güven etiketi `authenticated \| unauthenticated \| spam \| blocked`; etiket uyandırmadan önce olay türünde görünür; spam/blocked ile uyandırma açık abonelik ister | FROZEN (ürün) | AgentMail olay modeli |
| AG-39 | Ajana prompt değil yapılandırılmış mesaj teslim edilir; kontrol bilgisi tipli alanlarda; insan/dış sistem kaynaklı serbest metin ayrı parçada "güvenilmez içerik" işareti ve kaynak bilgisiyle; Relay ajana serbest metin talimat yazmaz | KANONİK DEĞİŞMEZ | A2A `parts[]`, MCP `annotations.audience` |
| AG-40 | Ajan mesaj zarfı: CloudEvents yalnız dış zarf, A2A parts + `audience`, kiracı anahtarıyla imzalı; güvenilmez metin sınır işaretli, işaret kaçırılır, görünür metne normalleştirilir | FROZEN (teknik) | Spotlighting; gizli metinle sızdırma olayları |
| AG-41 | Prompt injection savunmasının ilkesi ayrıcalık ayrımıdır; Relay'in savunmaları §17.12'dedir, ajan tarafı sorumlulukları rehberde belgelenir | FROZEN (ürün) | OWASP Agentic Top 10 (ASI01, ASI09) |
| AG-42 | A2A v1.0 push alma ve gönderme; retry, imza, DLQ, replay, SSRF ortak motordan; gelen olay `(task, seq)` idempotent, gerekirse `GetTask`; push yapılandırmasındaki kimlik bilgileri okumada redakte | FROZEN (teknik) | A2A v1.0; A2A push yapılandırması kimlik bilgisi sızıntısı |
| AG-43 | MCP sunucusu: durumsuz, yalnız araçlar (gönder, bekleme aç/oku, bekleyenleri listele, posta kutusu oku/ack, abone ol); MCP Tasks `input_required` bekleme noktasına eşlenir; katalog anahtar kapsamına göre daralır; insana yönelik beklemeyi yanıtlayan araç yok; skills paketiyle yayımlanır | FROZEN (teknik) | MCP 2026-07-28 |
| AG-44 | AG-UI olayları realtime kanalda opak yük; Relay yorumlamaz | FROZEN (teknik) | §15 |
| AG-45 | MCP/A2A üzerinden gelen yanıt Access onayı değildir; protokoller onay kapısını atlayamaz | KANONİK DEĞİŞMEZ | Access A-6, Access AG-33, Access EI-18 |
| AG-46 | Durum eşleme tablosu (Relay ↔ A2A ↔ MCP Tasks ↔ Anthropic `requires_action`) ve "yanıt bekleyen istekler" listesi | FROZEN (ürün) | §17.13.5 |
| AG-47 | Ajan protokol sürümleri hızla değişir; protokol değişikliği yalnız eşleme katmanını etkiler | WATCH | MCP ve A2A revizyon takvimi |
| AG-48 | Gönderen türü `agent` olan bildirimler ajan başına tavana tabidir; tavan frekans tavanı ve throttle'dan ayrıdır | FROZEN (ürün) | §13, §10 |
| AG-49 | Tavan aşılınca gönderme, silme; kalıcı beklet; sahibine `agent.ceiling_exceeded`; sahibi hepsini gönder / iptal / ajanı durdur; karar denetim kaydında; bekletilen bildirim `expires_at`'ini korur | FROZEN (ürün) | §18 denetim kaydı |
| AG-50 | Tavan sayacı okunamazsa ajan kaynaklı bildirimler bekletilir (fail-closed); insan ve sistem kaynaklı bildirimler etkilenmez | KANONİK DEĞİŞMEZ | Otonom üretici sayaç düşükken sınırsız üretebilir |
| AG-51 | Ajan başına tavan değeri | POLICY DEFAULT | Değer yapım sırasında ölçümle konur (F-28) |
| AG-52 | Live Activities / Android ProgressStyle ajanın uzun iş ilerleme yüzeyidir; konu bazlı collapse modeline eşlenir | FROZEN (ürün) | §12 |
| AG-53 | Kaynak sınırları sayfası: bekleme başına mesaj/kademe, payload boyutu, azami bekleme (≤ 30 gün), eşzamanlı bekleme, lease/yeniden teslim; sayısal değerler | ENGINEERING ASSUMPTION | Temporal ve MCP limit belgeleme pratiği; değerler ölçümle |
| AG-54 | Operasyon alarmları: sessiz bekleme/görev sayımla; yanıt oranı düşerken hacim artışı ya da anormal kısa yanıt süresi ("otomatik kabul makinesi") | FROZEN (ürün) | Onaylayan yorgunluğu |
| AG-55 | Kapsam dışı: dayanıklı yürütme/saga, onay kapısı ve risk kademesi, otomatik ret/kabul, ajana serbest metin talimat ve LLM içerik üretimi, insan iş kuyruğu, ajan sohbet ürünü | KAPSAM DIŞI | §17.16 |
