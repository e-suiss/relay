## 6. Değişmezler

Statü: **KANONİK DEĞİŞMEZ**. Bu bölümdeki kurallar hiçbir yapılandırma, kiracı ayarı, istek alanı, operatör eylemi, ortam (`live`/`test`), kurulum türü (SaaS/self-host) veya bağlı ürün (Access var/yok) tarafından gevşetilemez. Bir değişmezin ihlali uygulama hatasıdır; değişmezi korumak için mimari değişir, değişmez değişmez (§3).

Değişmezler "INV-*n*" biçimindedir. Her değişmez en az bir kural testiyle (§19, §20) doğrulanır; mümkün olan her yerde veritabanı kısıtı, rol yetkisi veya CI lint'iyle yapısal olarak zorlanır. Metin içindeki kavramlar §5'te tanımlıdır (C-*n*).

**Access ile ilişki.** Relay, Access'in kendisini bağlayan değişmezlerini kendi tarafında karşılar: teslim yetki gerçeğini değiştirmez (Access EI-9), Relay cevabı onay değildir (Access EI-18), fiziksel silme yoktur (Access OP-73), fail-closed her yerde (Access MD-8, Access INV-26). Bu değişmezler Relay'de Access bağlı olmasa da geçerlidir.

### 6.1 Kayıp ve görünürlük

- **INV-1 Sessiz kayıp yoktur.** Gönderilmeyen her bildirim ve teslim (atlanan, bastırılan, ertelenip süresi dolan, iptal edilen, kill switch'e takılan, kapsam uyuşmazlığına düşen, render hatası alan, tekrar olarak düşürülen) bir karar kaydı (C-59) ve `rule_id` ile kaydedilir; panelde, giden olayda (`notification.suppressed` ya da ilgili olay) ve metrikte görünür. Kayıtsız düşürme yolu yoktur. Sessiz düzeltme de yasaktır: içeriği değiştiren her temizleme (geçersiz UTF-8, kanal kısıtı sanitizer'ı) kaydedilir.
- **INV-2 Kabul edilen kaybolmaz.** `202` ile kabul edilen her istek, kaydıyla ve kuyruk işiyle aynı transaction'da kalıcıdır. Kabul edilip kuyruğa girmeyen mesaj sayısı sıfırdır. Kalıcı yazılamayan istek kabul edilmez (`503`); sessizce düşmez. Outbox olmadan "veritabanına yaz + kuyruğa yayınla" yolu yoktur.
- **INV-3 Bekleyen içerik kaybolmaz.** Digest önce biriktirir, sonra planlar; biriken olayı süpürücü kurtarır. Erken gelen yanıt alıcının posta kutusunda tamponlanır ve bekleme noktası açılınca eşleşir. Ajan tavanını aşan bildirim kalıcı bekletilir, silinmez. Uç noktası çalışmayan müşterinin olayları DLQ'da ve replay tamponunda kalır. Kill switch'e takılan iş kayıtla durdurulur, silinmez.
- **INV-4 Ölü mektup görünürdür.** DLQ kimsenin bakmadığı bir yere yazılmaz: kalıcıdır, listelenebilir, filtrelenebilir ve yeniden oynatılabilir; kiracı "kaçırılan olaylar" listesini görür.
- **INV-5 Bilinmeyen dürüsttür.** Relay `delivered` ya da `failed` uydurmaz. Kesin kanıt yoksa durum `unknown_pending`, pencere sonunda `unknown`'dır. Kanıt sunmayan kanalda (push) `delivered` iddia edilmez; kanal başına teslim semantiği belgelenir (§14). Teslim yolunda olasılıksal yapı (Bloom filtresi, HyperLogLog) kullanılmaz; yanlış pozitif kaybolan bildirim demektir.

### 6.2 Teslim defteri ve monotonluk

- **INV-6 Defter tek doğruluk kaynağıdır.** Teslim olayları (C-32) append-only defterdedir; teslim durumu, etkileşim ve hata ekseni bu defterden türetilen projeksiyondur ve her an defterden yeniden kurulabilir. Defter satırı güncellenmez. Projeksiyon bütün denemelerin kanıtından türer; olay girişinde kanal ve sağlayıcı teslimden okunur, çağıran seçemez.
- **INV-7 Teslim monotondur.** Teslim ekseni geri gitmez. Geç gelen düşük durum (ör. `delivered` sonrası `sent`) deftere yazılır ama durumu geri almaz. Geç gelen kesin olay (`delivered`/`failed`) ne zaman gelirse gelsin kabul edilir ve `unknown`'ı yükseltir. Eski bir denemenin geç başarısı da yükseltir. Terminal deneme durumu ezilmez. Inbox'ta `seen` ve `read` monotondur; zaman damgalarını sunucu atar.
- **INV-8 Çelişki gizlenmez.** İki deneme de teslim olduysa `duplicate_delivered`, teslimden sonra çelişkili kanıt geldiyse çelişki işareti görünür kalır ve metrikte sayılır. Bunlar gizlenecek tutarsızlık değil, ölçülecek olaydır.
- **INV-9 Kendiliğinden yeniden gönderim yoktur.** `unknown` sonucu için ve mutabakat sonrası gönderilmiş sayılan mesaj için otomatik yeniden gönderim yapılmaz. Ücretli kanalda belirsiz sonuç kör retry edilmez; sağlayıcının idempotency beyanına göre davranılır (§12).
- **INV-10 Dış sözleşme sabittir.** İç teslim modeli (eksenler, olay kodları, eşleme tabloları) değişse de API ve giden olay projeksiyonu kırıcı biçimde değişmez; kırıcı değişiklik yalnız sürümlü sözleşme süreciyle olur (§9).

### 6.3 Tekrar ve tekillik

- **INV-11 Değişiklik yapan her istek tekrar korumalıdır.** Değişiklik yapan her istek `Idempotency-Key` taşır; anahtarsız istek `400` ile reddedilir. Aynı anahtar + farklı gövde hiçbir koşulda eski yanıtı döndürmez (`422`). Idempotency kaydı dayanıklı depodadır; kaybı çift gönderim demektir.
- **INV-12 Tekillik garantisi veritabanı kısıtındadır.** `dedup_key`, teslim defteri anahtarı `(notification_id, recipient, channel)`, giden teslim anahtarı `(endpoint_id, event_id)` ve sağlayıcı olay makbuzu `UNIQUE` kısıtlarıyla korunur; bu tekillik zamana veya bölüme bağlı değildir. Kuyruk kütüphanesinin iş tekilliği yalnız ön filtredir, garanti sayılmaz.
- **INV-13 Tekrar koruması olmadan retry yoktur.** Her retry bir tekrar anahtarıyla (sağlayıcı idempotency anahtarı ya da Relay teslim anahtarı) yapılır. Sağlayıcı idempotency beyanı (`provider_idempotency_policy`) olmayan adaptör devreye alınmaz. Garanti dili "at-least-once teslim + kalıcı idempotency ile etkin exactly-once işlem"dir.
- **INV-14 Kalıcı hata retry edilmez.** `permanent_target` ve `permanent_content` sınıfındaki sonuçlar retry edilmez; kalıcı hata anında temizlik (adres bastırma, cihaz devre dışı bırakma) ve olay üretir. Diğer sınıfların retry davranışı hata sınıfı tablosundadır (§12). Retry yalnız tek katmanda (iş kuyruğu) yapılır; sağlayıcının `Retry-After`'ı her zaman dikkate alınır.

### 6.4 Kapılar, sınıf ve uyum

- **INV-15 Kapılar ezilemez.** Politika kafesinin kapıları (bastırma, ret, İYS onayının yokluğu, kill switch, ölü kanal, kapsam uyuşmazlığı; C-58) hiçbir bayrak, kategori, mesaj sınıfı, öncelik, istek alanı, ham sağlayıcı payload override'ı ya da operatör eylemiyle atlanamaz. `security` sınıfı tercihleri ve sessiz saati deler; kapıları delmez. Kafes sırası kapı → filtre → zamanlayıcıdır ve her denemede yeniden değerlendirilir.
- **INV-16 Sınıf değişmez; şerit yalnız sınıftan türer.** Mesaj sınıfı kabul anında atanır ve değişmez. Hiçbir istek alanı mesajı başka şeride taşıyamaz; `priority` sınıf tavanına indirilir. `critical` ve `time-sensitive` yalnız §12'deki kuralla açılır; istek başına ham sağlayıcı payload'ı (ör. `apns.payload`) interruption level, priority ve push type alanlarını ezemez.
- **INV-17 Kiracı yalnız sıkılaştırır.** Uyum kurallarında (C-64) gevşetme bayrağı yoktur. Kiracı yasal gönderim penceresini kapatamaz. Meşru istisnalar bayrakla değil veriyle (hukuki alıcı türü, mevcut müşteri ilişkisi) karşılanır. Kiracı kullanıcının pazarlama tercihini yalnız kapatma yönünde yazabilir.
- **INV-18 Ret anında uygulanır.** Ret (tek tık çıkış, SMS anahtar kelimesi, şikâyet, İYS reddi, tercih kapatma) alındığı an sonraki gönderimleri durdurur; mevzuattaki süreler hedef değil üst sınırdır. Ret yalnız yeni ve açık bir onayla kalkar; tercihi açmak onay sayılmaz. Kanıtsız onay yazılamaz; `none` ile `revoked` ayrıdır. İzin bir hizmet ya da özellik erişiminin koşulu yapılamaz.
- **INV-19 İYS kapsamında fail-closed.** İYS kontrolü yalnız `marketing` sınıfında ve İYS'nin tanıdığı kanallarda (ARAMA, MESAJ, E-POSTA) yapılır; kapsam, kiracının bölgesinin Türkiye olması ya da kiracının İYS bilgilerini girmiş olmasıdır. Bu kapsamda: kiracının İYS bilgisi yoksa bu kanallardan pazarlama iletisi gönderilmez; bireysel alıcıda yerel İYS kopyasında onay yoksa ya da kopya bayatlık eşiğini aştıysa gönderilmez; tacir/esnaf alıcıda İYS'de ret varsa gönderilmez. Herhangi bir kaynakta ret varsa ret geçerlidir. Kapsam dışında İYS işlemi yapılmaz.
- **INV-20 Kapatılamayanlar kapatılamaz.** `security` sınıfı ve kilitli kategoriler hiçbir tercih seviyesinden kapatılamaz. Kilitli kategoride en az bir kanal her zaman açık kalır. Kategori × kanal matrisinde tanımsız (boş/geçişli) hücre yoktur.
- **INV-21 Şablon tipi dönüşmez.** İşlemsel/bilgilendirme ve pazarlama şablonları birbirine dönüştürülemez. İşlemsel şablona promosyon içeriği yayın kapısında reddedilir. `security` sınıfının gönderim yolundan ticari içerik gönderilemez. Zorunlu yasal alt bilgisi eksik ticari şablon yayımlanamaz.

### 6.5 Güvenlik sınıfı ve tek kullanımlık kodlar

- **INV-22 Relay kod üretmez, sır tutmaz, doğrulamaz.** OTP ve doğrulama kodunu gönderen üretir ve doğrular; güven seviyesi (AAL) gönderenin işidir. Relay yalnız seçilen alt türün kanal kurallarını ve hedef korumalarını uygular.
- **INV-23 `otp_oob` e-postaya gitmez.** `otp_oob` yalnız SMS, WhatsApp ve sesli aramadan gider; fallback zinciri de e-postaya düşmez. `email_verification` yalnız e-postadan gider.
- **INV-24 OTP beklemez.** `security` sınıfının OTP alt türleri zamanlanmaz, digest'lenmez, geciktirilmez, collapse edilmez ve yük atmayla düşürülmez; yalnız gönderenin `expires_at`'i ile eskir. OTP hiçbir kiracının kampanya hacmini beklemez.
- **INV-25 Güvenlik iletisinde takip yoktur.** `security` sınıfında ve OTP/doğrulama e-postalarında açılma pikseli ve link sarmalama hiçbir koşulda açılamaz. Tek kullanımlık bağlantı GET ile tüketilmez: GET yalnız onay sayfasını gösterir, durum değişikliği POST ile yapılır.
- **INV-26 OTP içeriği saklanmaz.** OTP/doğrulama alt türlerinde render edilmiş içerik saklanmaz; yalnız özet ve şablon sürümü tutulur.
- **INV-27 Güvenilmez sinyal karar üretmez.** E-posta açılma verisi Relay'in hiçbir kararında kullanılmaz. Etkileşime bağlı kararları (görülmezse yükselt, digest iptali) yalnız kanal başına tanımlı güvenilir kanıt ve insan tıklaması tetikler; "muhtemel bot" tıklaması tetiklemez.

### 6.6 Ajan, yanıt ve yetki

- **INV-28 Bildirim içeriği yetki değildir.** Relay'in teslim ettiği, aldığı ya da taşıdığı hiçbir içerik, yanıt, ack, okundu, bekleme çözümü veya protokol mesajı yetki üretmez, onay sayılmaz, yetki durumunu değiştirmez. Uyandırma serbesttir; yetki Access'tedir (Access EI-9, Access EI-18). Relay teslim edemediği bir olay yüzünden hiçbir yetki değişikliğini geri almaz veya geciktirmez.
- **INV-29 Relay onay kapısı değildir.** Inbox eylem butonu, push eylemi, kilit ekranı yanıtı, SMS yanıtı, mesajlaşma uygulaması butonu, MCP ya da A2A üzerinden gelen yanıt hiçbir zaman onay değildir; protokoller onay kapısını atlayamaz. Onay türündeki öğede eylem yalnız Access onay yüzeyine (ya da sahibin onay yüzeyine) derin bağlantıdır. Eskalasyonun son kademesi yalnız `waitpoint.expired` olayıdır; otomatik kabul/ret kararını sahibi verir.
- **INV-30 Ajana talimat yazılmaz.** Ajana teslim edilen şey yapılandırılmış mesajdır (C-76), prompt değildir. Kontrol bilgisi tipli alanlardadır; insan ya da dış sistem kaynaklı serbest metin ayrı alanda "güvenilmez içerik" işaretiyle ve kaynak bilgisiyle taşınır. Relay ajana hiçbir zaman serbest metin talimat yazmaz. Bildirim içeriği hiçbir ayrıcalıklı bağlama girmez.
- **INV-31 Bekleme değişmezleri veritabanı kısıtıdır.** Yanıtlayan bekleyen değildir; bekleme noktasını başlatan bağlam ile tamamlayan bağlam doğrulanır. Süresi geçmiş bekleme çözülemez; süresi geçmiş yanıt reddedilir. Çözülmüş bekleme ve kaydedilmiş yanıt değişmez. Şemaya uymayan yanıt kaydedilmez (önce doğrulama, sonra kayıt). Yanıt işin özetine bağlanır; başka bir işin yanıtı olarak kullanılamaz.
- **INV-32 Her bekleme sonludur.** Bekleme noktası, olay bekleme adımı, bekleme adımı ve digest penceresi bir son tarih taşır; son tarih ilk kayıtta kalıcı hâle gelir ve retry'larda korunur. Sonsuz varsayılan yoktur. Süre dolumu `waitpoint.expired`, heartbeat kesilmesi `waitpoint.stalled` olayı üretir; heartbeat kesilen bekleme sahipsiz işaretlenir ve eskalasyonu durur.
- **INV-33 Yanıt yetkisi ajanın elinde değildir.** Yanıt jetonu ya da bekleme kimliği ajanın bağlamına girmez. Callback yetkisi varsayılan olarak kimliğe bağlıdır; bearer gerekiyorsa tek kullanımlık, kısa ömürlü, tek bekleme noktasına kapsamlıdır ve süre dolunca döndürülür. Karar isteği metni işin yapılandırılmış alanlarından sunucuda üretilir; ajanın serbest metni ayrı alanda "ajanın iddiası" etiketiyle, Markdown/HTML kapalı gösterilir.
- **INV-34 Ajan tavanı fail-closed çalışır.** Ajan tavanını aşan bildirim gönderilmez ve silinmez; kalıcı bekletilir ve sahibine olay gider. Tavan sayacı okunamazsa ajan kaynaklı bildirimler bekletilir. İnsan ve sistem kaynaklı bildirimler bundan etkilenmez.
- **INV-35 Push ipucudur, durum kaynaktır.** Uyandırma sinyali (push, webhook, A2A push, realtime ping) kayıt sistemi değildir; mesaj posta kutusunda, bekleme durumu bekleme satırında durur. Sinyal ya da yanıt payload'ı durumun kanıtı sayılmaz; gelen ajan bildiriminde `(görev, seq)` ile tekrar ayıklanır ve durum yeniden okunarak uzlaştırılır. Relay iş etkisi telafisi yapmaz; yalnız kendi adımlarını geri alır.

### 6.7 Kiracı izolasyonu

- **INV-36 Kiracı bağlamı olmadan sorgu çalışmaz.** Kiracı verisi taşıyan her tabloda satır düzeyi güvenlik zorunlu ve zorlanmıştır (FORCE). Uygulama rolü süper kullanıcı değildir, RLS'i atlayamaz, tablo sahibi değildir; değilse uygulama başlamaz. Kiracı bağlamı transaction'a yereldir.
- **INV-37 Kiracılar arası bağ yapısal olarak imkânsızdır.** Kiracı A'nın kaydı kiracı B'nin kaydına bağlanamaz (kiracıyla bileşik yabancı anahtar). Kiracı kimliği boş satır ve yetim satır yoktur. Kiracılar arası benzersizlik kısıtı yoktur; her benzersizlik kiracıyla bileşiktir.
- **INV-38 Çapraz kiracı erişimi varlık sızdırmaz.** Başka kiracının (ya da başka ortamın) kaynağına her erişim `404` döner.
- **INV-39 Kiracı ve ortam istemciden alınmaz.** API anahtarının kiracısı ve ortamı ezilemez; ortam gövdeyle değiştirilemez; `test` anahtarı canlı veriye erişemez; giden uç noktanın ortamı değiştirilemez. Realtime'da istemci yayın yapamaz, kendi isteğiyle abone olamaz; izinli akışlar jetonda yazılıdır; kiracı kimliği istemcinin görebileceği alanda bulunmaz. Olay girişi (`POST /v1/events`) istemciye açılmaz.
- **INV-40 Gürültülü komşu öbürünü durduramaz.** Bir kiracının sağlayıcı arızası ve devre kesicisi başka kiracıyı etkilemez. Kampanya hacmi OTP şeridinin kapasitesine dokunamaz. Farklı kiracıların APNs jetonları aynı bağlantıda taşınmaz. İzin anahtarı marka bazlıdır; çapraz marka izin kullanımı yoktur.
- **INV-41 Veri bölgesinde kalır.** Bir bölgenin kiracı verisi başka bölgeye akmaz. Access + Relay kullanan kiracının iki ürünü aynı bölgededir.
- **INV-42 Askıya alma her girişte etkilidir.** Askıya alınmış kiracı, alt kiracı, gönderici kimliği veya abone için API, kampanya, workflow ve giden olay girişlerinin hepsi durur; açık realtime bağlantıları sunucudan kesilir ve yeniden bağlanma yetkiyi baştan kontrol eder. Her askıya alma denetim kaydı bırakır.

### 6.8 Fail-closed, fail-safe ve sessiz varsayılan

- **INV-43 Belirsizlik gönderim üretmez.** Bir kapının girdisi okunamıyorsa sonuç "gönderme"dir: kill switch durumu bilinmiyorsa gönderim yapılmaz ve kill switch kesintide kendiliğinden açılmaz; İYS kopyası bayatsa ticari gönderim yapılmaz; doğrulanmamış sağlayıcı bağlantısı trafik almaz; itibar devresi kendiliğinden kapanmaz. İzin yokluğunda varsayılan "gönderme"dir.
- **INV-44 Limit asla "limitsiz"e düşmez.** Hız limiti ve sayaç arka ucu (Valkey) erişilemezse sinyaller kısa aralıklı yoklamaya, hız limiti Postgres yedek limitleyicisine düşer. Geçiş penceresinde iki sayaç birlikte kontrol edilir ve daha katı olan uygulanır. Hiçbir giden sağlayıcı limiti aşılmaz; Relay'in limiti sağlayıcınınkinden katıdır.
- **INV-45 Fail-open yalnız adıyla sayılan zamanlayıcılarda vardır.** Frekans tavanı (C-50) bir zamanlayıcıdır; sayacı okunamazsa gönderimi durdurmaz. Bu, kapı ve ajan tavanı için geçerli değildir. Bu değişmezde adı geçmeyen hiçbir kural fail-open çalışmaz.
- **INV-46 Sessiz varsayılan yoktur.** Tanınmayan yapılandırma ya da rol açılışta hata verir. Bilinmeyen istek alanı veya override anahtarı sessizce yok sayılmaz (`422`). Eksik zorunlu şablon değişkeni gönderimi durdurur, retry edilmez ve kiracıya görünür. Kanal limitini aşan çıktı kesilmez, reddedilir. Şablonun gönderilecek varyantı yoksa gönderim durur. Çeviri anahtarı ya da boş dizge kullanıcıya gösterilmez. Tanımsız tercih `true` ya da `false` olarak uydurulmaz. Bilinmeyen sağlayıcı kodu `unknown` sınıfına düşer ve alarm üretir.

### 6.9 Veri, saklama ve değişmezlik

- **INV-47 Fiziksel silme yoktur.** Relay, Access OP-73'ü aynen uygular: uygulama rolünde `DELETE`/`TRUNCATE`/veri `DROP` yetkisi yoktur ve CI lint'i bunu yakalar. Silme yumuşak silmedir (durum + `deleted_at` + tombstone). Kişisel veri silme talebi crypto-shredding'dir (C-86). Saklama sonu yumuşak silme + crypto-shredding'dir; eski bölümler soğuk arşive taşınır, imha edilmez. Taşıma şudur: bölüm değiştirilemez (WORM) nesne deposu kopyasına aktarılır, kopya doğrulanır, sıcak kopya ancak sonra ve yalnız arşiv rolüyle kaldırılır. Tek istisna yalnız kimlik taşıyan iş kuyruğu tablolarıdır: işin sonucu kalıcı kayda yazıldıktan sonra kuyruk satırı temizlenebilir; kayıt tablolarına istisna yoktur. Kullanıcı inbox'ta yalnız arşivler ya da gizler. Saklama ve silme Access OP-74 ve Access Ek C'ye tabidir.
- **INV-48 Yayınlanmış sürüm değişmez.** Yayınlanmış workflow, şablon, layout ve parça sürümü yerinde değiştirilmez. Gönderilmiş ya da planlanmış bildirimin içeriği sonradan yayınlanan sürümden etkilenmez; inbox öğesi gönderildiği andaki render'ı gösterir.
- **INV-49 Kanıt kayıtları değişmez.** Denetim kaydı append-only'dir ve periyodik imzalı Merkle kontrol noktasıyla mühürlenir (TN-46); uygulama rolünde güncelleme/silme yetkisi yoktur; eylemi yapanın kimliği zorunludur; kill switch değişikliğinde gerekçe boş geçilemez. Kullanım kaydı değişmezdir. İzin kayıtları append-only'dir ve kanıtlıdır. Bastırma kaydı tanımlayıcının anahtarlı özeti olarak kalır ve özne silmesinde imha edilmez.
- **INV-50 Zamanın tek otoritesi vardır.** Veritabanı yalnız UTC saklar; yerel saat hesabı yalnız uygulamada, tek ve sürümü izlenen bir tzdata kaynağıyla yapılır; SQL'de `AT TIME ZONE` kullanılmaz. Hız limiti ve sayaç kararlarında uygulama düğümünün duvar saati kullanılmaz.
- **INV-51 Sırlar geri okunmaz.** API anahtarı, webhook imza sırrı, sağlayıcı kimlik bilgisi ve cihaz jetonu oluşturma anından sonra açık olarak geri okunmaz (yalnız parmak izi). Veritabanında sır değil sır referansı durur. Çözülmüş sır paylaşılan bellek yapılarında tutulmaz ve loglanmaz.

### 6.10 Doğruluk kaynağı ve sinyal

- **INV-52 Doğruluk Postgres'tedir.** Asıl kayıt yalnız PostgreSQL'dedir. Valkey asla asıl kayıt tutmaz; yalnız kısa ömürlü sayaç ve sinyal taşır. Düğümler arası sinyal yalnız "yeni bir şey var" bilgisi + sıra numarası taşır; veri Postgres'ten okunur. Kaçırılan sinyal Postgres cursor'uyla telafi edilir.
- **INV-53 Yayın commit'i izler.** Realtime ve giden yayın commit'ten sonra çıkar (hayalet bildirim yok); commit olan her değişikliğin yayını er geç çıkar. Yayın yazma yolunu bloklamaz. Realtime geçmişi otoriter değildir; bağlantı kopması kayıp üretmez; istemci cursor'la tamamlar.
- **INV-54 Sayaçlar sunucuda ve mutlaktır.** Rozet ve inbox sayaçları sunucuda hesaplanır, sürümlüdür ve mutlak değer olarak gönderilir; artış olarak gönderilmez, istemcide hesaplanmaz. İstemci daha küçük sürümlü sayacı uygulamaz. Çevrimdışı cihazın eski niyeti başka cihazdaki daha yeni eylemi ezemez.
- **INV-55 Dış çağrı transaction içinde yapılmaz; iş uzun sürmez.** Sağlayıcıya, uç noktaya veya başka bir hizmete yapılan hiçbir ağ çağrısı veritabanı transaction'ı içinde yapılmaz. Hiçbir iş bir saati aşmaz; uzun beklemeler bir satır + zamanlayıcıdır (C-8).

### 6.11 Ürün bütünlüğü

- **INV-56 Öbür ürün yokken hiçbir şey sessizce bozulmaz.** Access bağlı değilken Relay'in her özelliği ya Relay'in kendi mekanizmasıyla çalışır ya da Access gerektirdiğini açıkça belirtir; sessizce devre dışı kalan, yarım çalışan özellik yoktur (Access E40 (4)). Relay eklenince ya da kaldırılınca müşteri kodu değişmez.
- **INV-57 Özellik kilidi yoktur.** Hiçbir özellik lisans bayrağıyla, "yalnız bulut" olarak veya kurulum türüne göre kilitlenmez. SaaS'ın farkı işletilen hizmettir.
- **INV-58 Test ve canlı aynı hattır.** `test` ortamı, önizleme ve gönderim modları canlı ile aynı doğrulama, idempotency, tercih, uyum, rota, şablon ve kill switch hattını çalıştırır; `rule_id`'ler özdeştir. Güvenliği zayıflatan bayrak ya da "geliştirme modu" yoktur (Access OP-69 ile uyumlu).
- **INV-59 Relay kendi kesintisini kendisiyle duyurmaz.** Relay'in kendi olay bildirimi, durum sayfası ve nöbet sayfalaması Relay'den geçmez ve Relay'e bağımlı değildir.

### 6.12 Garanti dürüstlüğü

- **INV-60 Relay vermediği garantiyi iddia etmez.** Belgeler, panel, API yanıtları ve pazarlama metni aşağıdakileri iddia etmez:
  - Hiçbir kanalda teslim garantisi yoktur; sağlayıcı kabulü teslim değildir, teslim gösterim değildir.
  - Teslim sırası garanti edilmez; garanti edilen, akış başına okuma sırasıdır (C-71). Giden olaylar at-least-once'tır; tekrar olabilir.
  - "Exactly-once teslim" yoktur; etkin exactly-once işlem idempotency ile sağlanır.
  - İptal yalnız sağlayıcıya henüz gönderilmemiş bildirimi çeker; gönderilmiş SMS, e-posta ve push geri alınamaz (in-app hariç).
  - E-posta açılma verisi güvenilir değildir; inbox'ın açılması belirli bir push'un ulaştığını, inbox'ta okunması SMS'in teslimini kanıtlamaz.
  - İYS izin durumu yapısal olarak bayatlık eşiği kadar eski olabilir.
  - `priority` bir kanal SLA'sı değildir; "anında gönderim" büyük kitlelerde iddia edilmez.
  - Idempotency-Key ve hız limiti başlıkları için "standarda uyuyoruz" denmez.
  - Push metadata'sı (uygulama, zaman, hesap) platform sağlayıcısına görünür; yalnız içerik taşımayan uyandırma modeli bunu azaltır, ortadan kaldırmaz.

### 6.13 Karar register'ı (INV-1–INV-60)

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| INV-1 | Sessiz kayıp yok; her atlama neden koduyla kayıtlı ve görünür | KANONİK DEĞİŞMEZ | "Neden almadım" sorusu; sağlayıcıların sessiz kayıp örnekleri (APNs Stored/Discarded, FCM pasif jeton, SMS bakiye) |
| INV-2 | Kabul edilen kaybolmaz; aynı transaction, outbox | KANONİK DEĞİŞMEZ | Transactional outbox deseni; Access OP-63 |
| INV-3 | Digest, erken yanıt, ajan tavanı, DLQ ve kill switch içerik kaybetmez | KANONİK DEĞİŞMEZ | DBOS/Temporal erken mesaj tamponu; Inngest lookback penceresi hatası |
| INV-4 | DLQ kalıcı, listelenebilir, yeniden oynatılabilir | KANONİK DEĞİŞMEZ | Svix/Hookdeck kurtarma modeli |
| INV-5 | `delivered`/`failed` uydurulmaz; push için `delivered` iddia edilmez; teslim yolunda olasılıksal yapı yok | KANONİK DEĞİŞMEZ | Apple'ın üretimde teslim logu vermemesi |
| INV-6 | Append-only defter tek doğruluk kaynağı; projeksiyon yeniden kurulabilir | KANONİK DEĞİŞMEZ | C-2 |
| INV-7 | Teslim monoton; geç kesin olay yükseltir; terminal deneme ezilmez | KANONİK DEĞİŞMEZ | Sağlayıcı DLR'larının sırasız ve geç gelmesi |
| INV-8 | `duplicate_delivered` ve çelişki görünür | KANONİK DEĞİŞMEZ | Çift teslimin ölçülebilir kalması |
| INV-9 | `unknown` ve mutabakat sonrası otomatik yeniden gönderim yok | KANONİK DEĞİŞMEZ | Ücretli kanalda çift gönderim maliyeti ve kullanıcı zararı |
| INV-10 | Dış sözleşme iç model değişiminden etkilenmez | KANONİK DEĞİŞMEZ | Sözleşme öncelikli geliştirme (§9) |
| INV-11 | Değişiklik yapan her istekte Idempotency-Key; farklı gövde → `422` | KANONİK DEĞİŞMEZ | Access OP-63; Stripe idempotency modeli |
| INV-12 | Tekillik DB kısıtında; kuyruk tekilliği ön filtre | KANONİK DEĞİŞMEZ | Oban iş tekilliğinin advisory lock'a dayanması ve yarış koşulları |
| INV-13 | Tekrar koruması olmadan retry yok; idempotency beyanı olmayan adaptör devreye alınmaz | KANONİK DEĞİŞMEZ | Sağlayıcı idempotency desteğinin operasyon ve API sürümüne bağlı olması |
| INV-14 | Kalıcı hata retry edilmez; tek katman retry; `Retry-After`'a uyulur | KANONİK DEĞİŞMEZ | RFC 9110 `Retry-After`; APNs 410, FCM `UNREGISTERED` |
| INV-15 | Kapılar hiçbir şeyle atlanamaz; `security` tercihi deler, kapıyı delmez | KANONİK DEĞİŞMEZ | Access TI-9 (güvenliği zayıflatan bayrak yok) |
| INV-16 | Sınıf değişmez; şerit yalnız sınıftan; payload override politika alanını ezemez | KANONİK DEĞİŞMEZ | OTP'nin kampanya kuyruğunda beklememesi; Apple `critical` entitlement |
| INV-17 | Kiracı yalnız sıkılaştırır; gevşetme bayrağı yok | KANONİK DEĞİŞMEZ | 6563, GDPR/ePrivacy, TCPA |
| INV-18 | Ret anında uygulanır; ret yalnız yeni açık onayla kalkar; kanıtsız onay yok | KANONİK DEĞİŞMEZ | 6563 ve Ticari İletişim Yönetmeliği ret süreleri (üst sınır); KVKK ispat yükü |
| INV-19 | İYS kapsamında fail-closed; kapsam dışında İYS işlemi yok | KANONİK DEĞİŞMEZ | 6563 m.6–7; İYS |
| INV-20 | `security` ve kilitli kategori kapatılamaz; matriste tanımsız hücre yok | KANONİK DEĞİŞMEZ | Güvenlik uyarısının kullanıcı tarafından kapatılamaması |
| INV-21 | Şablon tipi dönüşmez; promosyon sızıntısı ve eksik yasal alt bilgi yayında reddedilir | KANONİK DEĞİŞMEZ | 6563 Yönetmelik m.6/2; CAN-SPAM fiziksel adres |
| INV-22 | Relay kod üretmez, sır tutmaz, doğrulamaz | KANONİK DEĞİŞMEZ | Access ile OTP iş bölümü (§7.3.10) |
| INV-23 | `otp_oob` e-postaya ve e-postaya düşen fallback'e gitmez | KANONİK DEĞİŞMEZ | NIST SP 800-63B |
| INV-24 | OTP zamanlanmaz, digest'lenmez, geciktirilmez, collapse edilmez, yük atmayla düşürülmez | KANONİK DEĞİŞMEZ | OTP'nin saniyeler içinde anlamını yitirmesi |
| INV-25 | Güvenlik iletisinde takip yok; tek kullanımlık link GET ile tüketilmez | KANONİK DEĞİŞMEZ | Güvenlik tarayıcılarının linkleri önceden açması |
| INV-26 | OTP render içeriği saklanmaz | KANONİK DEĞİŞMEZ | Kod sızıntısı yüzeyinin kapatılması |
| INV-27 | Açılma verisi karar girdisi değildir; yalnız güvenilir kanıt ve insan tıklaması | KANONİK DEĞİŞMEZ | Apple Mail Privacy Protection |
| INV-28 | Bildirim içeriği yetki değildir; teslim yetki değişikliğini geri almaz/geciktirmez | KANONİK DEĞİŞMEZ | Access EI-9, Access EI-18, Access E30, Access §7.9.8.4 |
| INV-29 | Hiçbir kanal/protokol yanıtı onay değildir; son kademe yalnız olay | KANONİK DEĞİŞMEZ | Access EI-18, Access E32, Access XI-8, Access A-5 |
| INV-30 | Ajana yapılandırılmış mesaj; serbest metin talimat yok | KANONİK DEĞİŞMEZ | OWASP LLM01 (prompt injection); A2A, MCP |
| INV-31 | Bekleme değişmezleri DB kısıtı | KANONİK DEĞİŞMEZ | Temporal Update validator; CIBA `binding_message`, RFC 9396 |
| INV-32 | Her bekleme sonlu; heartbeat ≠ toplam süre | KANONİK DEĞİŞMEZ | Step Functions `HeartbeatSeconds`; sonsuz bekleyen iş birikimi |
| INV-33 | Yanıt jetonu ajan bağlamına girmez; karar metni sunucuda üretilir | KANONİK DEĞİŞMEZ | "Lies-in-the-loop" saldırıları; MCP URL elicitation ilkesi |
| INV-34 | Ajan tavanı fail-closed; aşan bekletilir | KANONİK DEĞİŞMEZ | Kaçak ajan döngüsü |
| INV-35 | Push ipucudur; durum posta kutusu ve bekleme satırında; saga yok | KANONİK DEĞİŞMEZ | A2A `GetTask` uzlaştırması; Signal uyandırma modeli |
| INV-36 | Kiracı bağlamı olmadan sorgu yok; FORCE RLS; ayrıcalıksız uygulama rolü | KANONİK DEĞİŞMEZ | Access §12/Access §17 izolasyon kuralları |
| INV-37 | Kiracılar arası bağ yapısal olarak imkânsız | KANONİK DEĞİŞMEZ | Yanlış kişiye bildirim riski |
| INV-38 | Çapraz kiracı/ortam erişimi `404` | KANONİK DEĞİŞMEZ | Varlık numaralandırma |
| INV-39 | Kiracı ve ortam istemciden alınmaz; istemci yayın yapamaz, kendi abone olamaz | KANONİK DEĞİŞMEZ | Realtime kanal ele geçirme örnekleri |
| INV-40 | Gürültülü komşu izolasyonu | KANONİK DEĞİŞMEZ | Paylaşılan sağlayıcı hesabında adalet |
| INV-41 | Veri bölgesinde kalır | KANONİK DEĞİŞMEZ | Veri yerleşimi; Access Ek C |
| INV-42 | Askıya alma her girişte etkili; bağlantılar kesilir | KANONİK DEĞİŞMEZ | Kötüye kullanım müdahalesi |
| INV-43 | Kapı girdisi okunamıyorsa gönderme | KANONİK DEĞİŞMEZ | Access MD-8, Access INV-26 |
| INV-44 | Limit "limitsiz"e düşmez; Relay limiti sağlayıcınınkinden katı | KANONİK DEĞİŞMEZ | SES aşımda düşürme; Twilio kuyruk süresi aşımı |
| INV-45 | Fail-open yalnız frekans tavanında | KANONİK DEĞİŞMEZ | Frekans tavanı kullanıcı deneyimi aracıdır, hukuki kapı değildir |
| INV-46 | Sessiz varsayılan yok; gürültülü hata | KANONİK DEĞİŞMEZ | Eksik değişkenle bozuk mesaj gönderimi örnekleri |
| INV-47 | Fiziksel silme yok; silme = yumuşak silme + crypto-shredding; soğuk arşive taşıma = doğrulanmış WORM kopya + sıcak kopyanın arşiv rolüyle kaldırılması; tek istisna yalnız kimlik taşıyan iş kuyruğu tabloları (sonuç kalıcı kayda yazıldıktan sonra) | KANONİK DEĞİŞMEZ | Access OP-73, Access OP-74, Access Ek C |
| INV-48 | Yayınlanmış sürüm değişmez; gönderilmiş içerik geriye dönük değişmez | KANONİK DEĞİŞMEZ | Sürüm sabitleme; denetlenebilirlik |
| INV-49 | Denetim, kullanım, izin ve bastırma kayıtları değişmez | KANONİK DEĞİŞMEZ | 6563 m.11/3 ispat; Access §7.9.12.5 |
| INV-50 | DB yalnız UTC; tek tzdata kaynağı; duvar saati limit kararına girmez | KANONİK DEĞİŞMEZ | Saat dilimi ve saat kayması hataları |
| INV-51 | Sırlar geri okunmaz; DB'de yalnız referans; bellek ve log hijyeni | KANONİK DEĞİŞMEZ | BEAM'de bellekten sır silinememesi; Access §14.7 |
| INV-52 | Doğruluk Postgres'te; Valkey asıl kayıt tutmaz; sinyal yalnız sıra no | KANONİK DEĞİŞMEZ | Tek zorunlu kayıt sistemi |
| INV-53 | Yayın commit'i izler; yazma yolunu bloklamaz; realtime geçmişi otoriter değil | KANONİK DEĞİŞMEZ | Hayalet bildirim ve kayıp yayın örnekleri |
| INV-54 | Sayaçlar sunucuda, mutlak, sürümlü | KANONİK DEĞİŞMEZ | Rozet yarışları |
| INV-55 | Ağ çağrısı transaction içinde değil; iş ≤ 1 saat | KANONİK DEĞİŞMEZ | Bağlantı havuzu tükenmesi; uzun işin yeniden başlatma maliyeti |
| INV-56 | Öbür ürün yokken sessiz bozulma yok | KANONİK DEĞİŞMEZ | Access E40 (4) |
| INV-57 | Lisans bayrağı ve "yalnız bulut" özellik yok | KANONİK DEĞİŞMEZ | Apache-2.0; open-core yok |
| INV-58 | Test ve canlı aynı hat; güvenliği zayıflatan bayrak yok | KANONİK DEĞİŞMEZ | Access OP-69, Access TI-9 |
| INV-59 | Relay'in kendi olay bildirimi Relay'den geçmez | KANONİK DEĞİŞMEZ | Ortak arıza noktası |
| INV-60 | Verilmeyen garanti iddia edilmez | KANONİK DEĞİŞMEZ | Sağlayıcı ve protokol semantikleri (APNs, FCM, A2A, MCP); süresi dolmuş Idempotency-Key taslağı |
