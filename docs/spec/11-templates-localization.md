## 11. Şablon ve yerelleştirme

**Bölüm notu.**

- **Kapsam.** Bu bölüm bildirim içeriğinin nasıl yazıldığını, doğrulandığını, render edildiğini ve yerelleştirildiğini yazar: şablon motoru ve güven sınırı, kanal varyant modeli, değişken sözleşmesi, kanal başına render kuralları, yerelleştirme ve çeviri, sürümleme ve yayın kapısı, layout ve marka, üretici sahipli şablonlar, önizleme, içerik saklama ve render hataları.
- **Başka bölümde yazılanlar.** Workflow ve adımlar §10'da, kanal ve sağlayıcı davranışı (segment faturası, collapse, öncelik eşlemesi) §12'de, ticari ileti sınıfı ve yasal altbilginin hukuki dayanağı §13'te, saklama süreleri §20'de ve Access Ek C'dedir.
- **Karar kimlikleri.** TP-1 … TP-44. Register §11.13'tedir.

### 11.1 Şablon nesnesi (TP-1)

1. **Tanım.** Şablon kanal × locale matrisidir ve sürümlüdür. Her kanal adımı bir şablona işaret eder (§10).
2. **Tip.** İşlemsel/bilgilendirme şablonları ile pazarlama şablonları birbirine dönüştürülemeyen ayrı tiplerdir. Şablonun tipi, bağlı olduğu kategorinin sınıfıyla uyumlu olmak zorundadır (§13).
3. **Sahip.** Şablon kiracıya, alt kiracıya ya da bir üretici ürüne (§11.9) aittir. Relay'in kendi ürün içi metinleri (panel, tercih sayfası, sistem e-postaları) aynı motoru kullanan sistem şablonlarıdır.

### 11.2 Motor ve güven sınırı (TP-2 … TP-8)

1. **Tek motor.** Kiracı şablonları ve sistem şablonları Liquid ailesinden, kod çalıştırmayan bir motorla (Solid) render edilir. Elixir'in EEx/HEEx şablonları yalnız Relay'in derleme zamanı kodunda bulunabilir; kiracı verisi hiçbir koşulda EEx'e girmez (TP-2).
2. **Eval sınırı.** Kiracıdan gelen hiçbir dize kod değerlendiren, atom üreten ya da terim çözen bir yola ulaşamaz (Elixir'de `EEx.*`, `Code.eval_*`, `Code.string_to_quoted`, `String.to_atom`, `:erlang.binary_to_term`). Kural CI'da statik denetimle uygulanır; ihlal bir güvenlik olayıdır (TP-3).
3. **Daraltılmış dil.** `include` ve `render` etiketleri yoktur (motora dosya sistemi verilmez). Etiket kümesi daraltılmıştır; filtreler Relay'in tanımlı filtre setinden gelir (`sms_safe`, `plural`, `number`, `currency`, `datetime` vb.). Tanımsız değişken ve tanımsız filtre hatadır (`strict_variables`, `strict_filters`) (TP-4).
4. **Şablon bağlamı.** Şablona yalnız izin listesinden geçmiş düz veri verilir: olay verisi, şemada beyan edilmiş alıcı öznitelikleri, marka değişkenleri ve render yardımcıları. İç yapılar (kayıt nesneleri, kiracı kimliği, sırlar) bağlama giremez. İç içe erişim derinliği en fazla 5'tir; dizi indeksi uzunluk kontrolüyle okunur (TP-5).
5. **Statik limitler.** Yayın kapısında: şablon kaynağı en fazla 256 KB, döngü sayısı en fazla 10, iç içe döngü derinliği en fazla 2, toplam düğüm en fazla 5.000 (TP-6).
6. **Çalışma anı limiti.** Her render ayrı, zaman sınırlı bir süreçte çalışır: e-posta 50 ms, diğer kanallar 10 ms. Zaman bütçesi pazarlık konusu değildir, değeri ayarlanabilir. Kanal limitini aşan çıktı kesilmez, reddedilir. Her render çıktısı gönderilmeden önce ölçülür (uzunluk, kodlama, segment, bayt, boyut, eksik değişken, boş blok); sonuç bildirim kaydına yazılır ve kiracı panelinde toplanır (TP-7).
7. **Ağır iş yayında.** E-posta düzeni (MJML) yalnız yayında derlenir; gönderim yolunda derleme yapılmaz. Sıra: önce MJML düzeni, sonra Liquid değişkenleri. Derlenmemiş MJML sürümü yayımlanamaz. Gönderim yolunda yerel derlenmiş (NIF) kod çalışmaz; çünkü zaman sınırı NIF içinde takılan süreci durduramaz (TP-8).

### 11.3 Kanal varyant modeli (TP-9 … TP-12)

1. **Omurga + kanal katmanı** (TP-9):

| Katman | Alanlar |
|---|---|
| Ortak | Değişken şeması (workflow sürümünden), varsayılan locale, kategori, hassasiyet sınıfı (TP-21), layout bağı |
| Locale | Her locale için ayrı içerik |
| SMS | Gövde, kodlama politikası (TP-18) |
| Push | Başlık, gövde, alt başlık; `sensitive` sınıfında `lock_screen_body` ve `in_app_body` |
| E-posta | Konu, ön başlık (preheader), HTML gövdesi (MJML ya da `raw_html`), düz metin gövdesi |
| WhatsApp | Onaylı Meta şablon adı + parametre eşlemesi (TP-23) |
| Inbox | Başlık, gövde, eylem listesi, avatar |
| Webhook | Kısıtlı modda JSON gövde şablonu |

2. **İçerik kanal başına yazılır.** İçerik bir kanaldan ötekine otomatik türetilmez; tutarlılık şemadan gelir. Gerekçe: kanalların uzunluk rejimleri farklıdır (otomatik kısaltma Türkçe'de sondaki eki düşürür), bağlam ve hassasiyet farklıdır. Panelde "e-postadan SMS taslağı üret" yardımcısı vardır; ürettiği şey düzenlenebilir bir taslaktır, canlı bir bağ değildir (TP-10).
3. **Varyant yoksa.** Bir kanal için varyant yoksa o kanala gönderilmez ve `rule_id` ile kaydedilir; rota sıradaki kanala geçer (§10). Şablonun alıcının dil zincirinde hiçbir varyantı yoksa gönderim durur (TP-26) (TP-11).
4. **Sızma yasağı.** İşlemsel ya da operasyonel kategoriye bağlı şablona promosyon bloğu, indirim kodu ya da kampanya çağrısı eklenmesi yayın kapısında reddedilir (TP-12).

### 11.4 Değişken sözleşmesi (TP-13 … TP-17)

1. **Şema ve üç doğrulama noktası.** Kiracı olay şemaları JSON Schema 2020-12'dir ve workflow sürümüne aittir (§10). Doğrulama üç noktada zorunludur: yayında (şablon değişkenleri şemaya karşı), olay kabulünde (`data` şemaya karşı; geçersizse 422, kuyruğa girmez; §9) ve render'da (TP-13).
2. **Kritiklik sınıfları.** Her değişken bir sınıf taşır; varsayılan `required`'dır ("güvenli varsayılan gürültülü olandır"). Şemada beyan edilmemiş değişken yayında reddedilir (TP-14):

| Sınıf | Değişken yoksa | Örnek |
|---|---|---|
| `required` | Gönderim durur, retry yok, `notification.render_failed` (`missing_variable`); panelde toplu görünür | Kod, sipariş numarası |
| `fallback` | Tanımlı varsayılana düşülür (varsayılan tanımlı olmak zorunda) ve sayılır | Ad ("Değerli müşterimiz") |
| `optional` | Blok atlanır; değişken bir koşul bloğu içinde olmak zorunda | Sipariş notu |
| `decorative` | Boş bırakılır, sayılmaz | Rozet sayısı |

Belirleyici soru: "Bu değişken olmadan mesaj hâlâ doğru ve eyleme geçirilebilir mi?"

3. **En kötü durum uzunluğu.** String alanlarda `maxLength` zorunludur. Yayında en kötü durum uzunluğu hesaplanır ve kanal limitleriyle karşılaştırılır (SMS segment ve tahmini maliyet, push 1024 karakter, WhatsApp 1024/60/60/25, e-posta boyutu) (TP-15).
4. **Tip kuralları.** Para `{ "amount": "1234.50", "currency": "TRY" }` (string tutar, float değil); tarih-saat `format: date-time`, ISO 8601 UTC; boolean `type: boolean`; büyük sayılar `maximum` ile sınırlı; zorunlu diziler `minItems: 1`. Olay verisi ve şema örnekleri önceden biçimlendirilmiş değer içermez ("1.249,90 TRY" gibi); biçimlendirme render anında alıcının locale'inde yapılır (TP-16).
5. **Şema evrimi ve kullanım dizini.** Yeni isteğe bağlı alan serbesttir; yeni zorunlu alan ya da tip değişikliği yeni şema sürümüdür; alan kaldırma, o alanı kullanan şablon varsa engellenir; `maxLength` daraltma uyarı ve geçiş süresiyle yapılır. Yayında şablonun okuduğu değişken yolları statik olarak çıkarılır ("her zaman okunur" ile "koşullu okunur" ayrı) ve dizinlenir; "bu alanı hangi şablonlar kullanıyor" sorusu cevaplanabilir (TP-17).

### 11.5 Kanal başına render kuralları (TP-18 … TP-24)

1. **SMS kodlaması.** Şablon başına kodlama politikası: `transliterate`, `turkish_shift`, `ucs2`; varsayılan `turkish_shift`. Sağlayıcı kataloğunda `turkish_single_shift: verified | unverified` alanı tutulur; Türkçe tek kaydırma tablosunu desteklediği doğrulanmamış sağlayıcıya `ucs2` gönderilir. Kodlama parametresi sağlayıcıya her zaman açıkça verilir. Segment hesabı sağlayıcıdan bağımsız ve muhafazakârdır (16 bitlik birleştirme başlığı varsayılır; tek kaydırmada `Ç` de 2 septet sayılır) (TP-18).
2. **SMS içerik kuralları.** Emoji şablon metninde yasaktır; değişken değerinde bulunursa bayraklanır, segment yeniden hesaplanır ve kiracı politikasına göre ayıklanır ya da maliyeti kabul edilir; sessizce geçmez. Yasal zorunlu metin (ticaret unvanı, ret talimatı) şablonun düzenlenemez alt bölümündedir, transliterasyona uğramaz ve segment bütçesinden önce ayrılır. Kontrol karakterleri, sıfır genişlikli karakterler ve yön denetim karakterleri (U+202A–U+202E) SMS'ten çıkarılır (TP-19).
3. **Push.** Push sunucuda render edilir ve düz `title`/`body` taşır; APNs `loc-key` yalnız kiracı açıkça isterse kullanılır. Payload yalnız JSON kodlayıcıyla kurulur, dize birleştirmeyle kurulmaz. Render sonrası payload bayt olarak ölçülür (APNs 4096 bayt); aşarsa reddedilir. Geçersiz UTF-8 önden ayıklanır ve kaydedilir. Android metni 1024 karakterde sessizce kesildiği için en kötü durumda bu sınırı aşabilecek varyant yayımlanamaz. Görsel kesme için sabit sayı kodlanmaz; Türkçe için "önemli bilgi ilk satırda" kuralı lint'tedir (TP-34) (TP-20).
4. **Hassasiyet sınıfı.** Her şablon zorunlu bir hassasiyet sınıfı taşır: `public`, `personal`, `sensitive`. `sensitive` sınıfında push kilit ekranına nötr bir metin (`lock_screen_body`) gider, tam içerik uygulama açılınca çekilir (`in_app_body`); kilit ekranında açık metin yoktur. Yayın kapısı sabit metni ve değişken adlarını hassas terim sözlüğüne (TR + EN: tanı, reçete, borç, icra, bakiye, kimlik numarası, IBAN vb.) karşı tarar; eşleşmede kiracı sınıfı açıkça onaylamak zorundadır (TP-21).
5. **E-posta.** Varyant dört alandır: konu, ön başlık, HTML, düz metin. Düz metin gövdesi zorunludur ve ayrı alandır (HTML'den taslak üretilebilir, kiracı düzeltir). Konu satırına giren değişkenin uzunluğu denetlenir; konuda CR/LF kaldırılır ve gerekirse encoded-word kullanılır. Render edilmiş HTML 70 KB'ı aşarsa uyarı, 90 KB'ı aşarsa ret; ölçüm yayında ve değişken enjeksiyonundan sonra yeniden yapılır. Koyu mod için `color-scheme` meta etiketi şablon iskeletinde bulunur. AMP for Email desteklenmez (TP-22).
6. **WhatsApp.** Render sonrası, gönderimden önce parametre temizleyici çalışır: satır sonu ve sekme boşluğa çevrilir, art arda 4+ boşluk 3'e indirilir, kırpma grafem bazında yapılır; her değişiklik kaydedilir. WhatsApp varyantının ayrı yaşam döngüsü vardır: `pending_approval` → `approved` (Meta durumları `APPROVED`, `REJECTED`, `PAUSED`, `DISABLED`; `PAUSED` gönderilemez). Relay Meta şablonunu adıyla ve sürümüyle referanslar; yeni içerik yeni bir Meta şablon adıdır, eski sürüme dönüş eski ada dönmektir. Meta düzenleme kotası panelde neden ve ne zaman açılacağıyla gösterilir; red gerekçesi Meta'nın verdiği gerekçedir. Panelde WhatsApp önizlemesi Meta'da onaylanmış gerçek metni gösterir ve ayrışma varsa uyarır (TP-23).
7. **Kaçış ve ham HTML.** Kaçış bağlam üzerinde, kanal tipine göre yapılır; render fonksiyonu kanal tipini zorunlu parametre olarak alır ve aynı bağlam iki kanala verilmez. Kanal başına kaçış: e-posta HTML'de entity kaçışı, düz metinde CR/LF ayıklama, push ve webhook'ta JSON kodlayıcı, inbox'ta yapılandırılmış alan (HTML yok). Kurumsal kiracı `raw_html` şablon tipiyle kendi HTML'ini verebilir; `| raw` filtresi şablon düzeyinde bir izin bayrağı ister. İkisi de önizlemede yalnız sandbox içinde render edilir (TP-39) (TP-24).

### 11.6 Yerelleştirme (TP-25 … TP-30)

1. **Locale ve çözüm sırası.** Locale BCP 47'dir. Alıcının locale'i şu sırayla bulunur: profil → cihaz → (yalnız inbox ve web isteklerinde) `Accept-Language` → kiracı varsayılanı. `Accept-Language` ana gönderim yolunda kullanılmaz. Kiracı kurulumunda `default_locale` zorunludur; sistem varsayılanı yoktur (TP-25).
2. **Fallback zinciri.** `tr-TR` → `tr` → kiracı varsayılanı. Zincirde hiçbir varyant yoksa gönderim durur ve `rule_id` kaydedilir. Kiracı varsayılanına düşülen her gönderim `template_locale_missing` olarak sayılır ve kiracı panelinde gösterilir ("geçen hafta 4.312 alıcınıza Almanca yerine Türkçe gitti"). Çeviri anahtarı ya da boş dize kullanıcıya hiçbir koşulda gösterilmez (TP-26).
3. **Çoğul ve biçim.** Çoğul ve seçim ifadeleri ICU MessageFormat (klasik sözdizimi) ile yazılır; çoğul kategorileri CLDR'dan gelir ve şablon veri modeli altı kategoriye kadar destekler (Arapça). Sıfır durumu `=0` açık eşleşmesiyle yazılır. Gettext'in çoğul kuralı kullanılmaz (Türkçe `n > 1` kuralı sıfırı tekil sayar). Sayı, para, tarih ve saat render anında alıcının locale'i ve saat diliminde CLDR ile biçimlendirilir. Şablon editörü çoğul alanlarda dilin kategorilerini (`one`/`other`, Arapça'da altı) gösterir ve ICU'yu arka planda üretir (TP-27).
4. **Türkçe harf kuralları.** Büyük/küçük harf filtreleri locale'e duyarlıdır; `tr` locale'inde İ/i ve I/ı kuralı uygulanır (TP-28).
5. **Sağdan sola diller.** RTL locale'lerde şablona enjekte edilen değişkenler yön izolasyon karakterleriyle (U+2068 … U+2069) sarılır; bu kural push, e-posta, inbox ve WhatsApp'ta uygulanır, SMS'te uygulanmaz (kodlamayı UCS-2'ye zorlar). E-postada `dir="rtl"`, inbox payload'ında `locale` ve `dir` açıkça taşınır. Push metni işletim sistemince render edilir; Relay yalnız değişkenleri izole eder (TP-29).
6. **Çeviri akışları.** İki ayrı akış vardır: Relay'in kendi ürün metinleri (çeviri yönetim sistemi + CI denetimi: eksik çeviri, yer tutucu kümesi karşılaştırması, sözde yerelleştirme) ve kiracı şablonları (ürün içi locale matrisi). Kiracı şablonları dış çeviri sistemine itilmez. Ürün içi akışta: eksik hücreler matriste görünür; makine çevirisi `machine_translated` işaretli taslak üretir ve insan onayı olmadan yayımlanmaz; değişken yer tutucuları çeviri sırasında korunur ve locale'ler arası değişken kümesi farkı yayını engeller; eksik çeviri yayını kilitlemez, fallback zinciri geçerlidir. Çeviri birimi cümledir; dize birleştirmeyle cümle kurmak yasaktır (TP-30).

### 11.7 Sürümleme ve yayın kapısı (TP-31 … TP-34)

1. **Değişmez sürüm.** Yayımlanmış şablon sürümü hiçbir zaman değiştirilmez; düzenleme yeni bir taslak açar. Sürüm numarası monoton artar; aynı içeriğin iki kez yayımlanmasını `checksum` önler. Yaşam döngüsü `draft` → `published` → `archived`. Eski sürüme dönüş canlı sürüm işaretçisini değiştirir, yeni sürüm yaratmaz; dönüşten önce yayın doğrulaması (şema uyumu) yeniden çalışır, geçmezse dönüş engellenir. Her yayın ve dönüş `published_by`, zaman, `checksum` ve önceki sürümle farkıyla denetim kaydına girer (TP-31).
2. **Yayın kapısı.** Sert kapılar geçilmeden şablon yayımlanamaz; uyarı kapıları "uyarıyla yayımla" ile geçilebilir ve uyarı kayda geçer (TP-32):

| Kontrol | Düzey |
|---|---|
| Her locale × kanal ayrıştırılabiliyor ve statik limitler içinde (TP-6) | Sert |
| Değişkenler şemayla uyumlu; beyan edilmemiş değişken yok (TP-14) | Sert |
| E-postada düz metin gövdesi var | Sert |
| MJML derleniyor | Sert |
| Hassasiyet sınıfı seçilmiş; sözlük eşleşmesi açıkça onaylanmış (TP-21) | Sert |
| Push en kötü durumda 1024 karakteri ve 4096 baytı aşmıyor (TP-20) | Sert |
| Sızma yasağı (TP-12) | Sert |
| Zorunlu yasal altbilgi (TP-33) | Sert |
| Locale'ler arası değişken kümesi tutarlı | Uyarı |
| En kötü durum uzunlukları kanal limitlerinde (SMS segment, WhatsApp, e-posta boyutu) | Uyarı |
| Erişilebilirlik ve içerik lint'i (TP-34) | Uyarı |

Yayın kapısı önizlemesi otomatik sınır değer kümesini kullanır; "en kötü durum önizlemesi" kiracıya zorla gösterilir (TP-38).

3. **Zorunlu yasal altbilgi.** Ticari ileti şablonunda zorunlu altbilgi lint'i sert kapıdır: Türkiye için hizmet sağlayıcının unvanı, MERSİS numarası ya da iletişim bilgisi, ücretsiz ret talimatı ve iletinin ticari niteliğini belirten ibare; ABD için fiziksel posta adresi. Eksikse şablon yayımlanamaz. Ülke kuralları §13'teki uyum tablosundan gelir (TP-33).
4. **Erişilebilirlik ve içerik lint'i.** E-postada `lang` özniteliği, görsellerde alt metin, salt görselden oluşan e-posta uyarısı, düz metin varlığı ve kontrast; bildirimde anlamın ilk satırda olması (Türkçe'de "önemli bilgiyi öne al"); kilit ekranına düşebilecek alanlarda hassas veri olmaması. Bu kurallar uyarı düzeyindedir (TP-34).

### 11.8 Layout, marka ve parçalar (TP-35, TP-36)

1. **Layout ve parçalar.** Kiracı ve alt kiracı başına sürümlü layout'lar vardır (üst kısım, logo, alt bilgi, stil); her şablon bir layout'a bağlanır. Marka değişkenleri (`brand.*`: logo, renk, adres, gönderen adı vb.) tek yerde tutulur. Kontrollü parçalar adlandırılmış, sürümlü bloklardır; bir parça başka bir parça çağıramaz (tek seviye, döngü imkânsız). Serbest `include` yoktur. Layout ve parça sürümleri gönderim başında sabitlenir; hangi mesajın hangi sürümle gittiği her zaman bellidir (§10) (TP-35).
2. **Alt kiracı mirası.** Alt kiracı marka, layout ve şablon varyantı tanımlayabilir. Alt kiracının tanımlamadığı ayar için kiracınınki geçerlidir: "yoksa üsttekini kullan, varsa ezme" (§18) (TP-36).

### 11.9 Üretici sahipli şablonlar (TP-37)

1. Bir üretici ürün (Access, başka bir Suiss ürünü ya da entegre bir sistem) şablonu API ile yayımlar. Metin ve çeviriler üreticinindir; kiracı değiştiremez (Access X35, Access X39).
2. Kiracı yalnız üreticinin izin verdiği marka alanlarını değiştirir: logo, renkler, gönderen adı, alt bilgi.
3. Kanala göre render Relay'indir: SMS segmenti, push başlık ve gövdesi (iki gövdeli push dahil), e-posta HTML + düz metin, WhatsApp onaylı şablon eşlemesi.
4. Üretici sahipli şablon da yayın kapısından geçer; üreticinin yeni sürüm yayımlaması kiracının marka ayarlarını korur.

### 11.10 Önizleme (TP-38, TP-39)

1. **Üç seviye.** (1) Anlık render: her değişiklikte örnek veriyle. (2) Kanala doğru görünüm: iOS kilit ekranı ve bildirim merkezi, Android daraltılmış/genişletilmiş, SMS balonu (segment sınırları, kodlama modu, tahmini maliyet, transliterasyon öncesi/sonrası), WhatsApp balonu, inbox satırı, e-posta (HTML boyutu, düz metin sekmesi, koyu mod, dar/geniş). (3) Gerçek cihaza test gönderimi (§9, `is_test`). Örnek veri kaynakları öncelik sırasıyla: şema `examples` alanı; son N gerçek olay, kişisel veri maskelenmiş ve gerçek uzunlukta (`"Mehmet Yılmaz"` → `"Xxxxxx Xxxxxx"`); otomatik sınır değerler (`maxLength` ve boş dize, dizilerde `minItems`/`maxItems`, sayılarda `minimum`/`maximum`, Türkçe karakterli ad, emoji, RTL) (TP-38).
2. **Sandbox.** Önizleme ayrı bir origin'de, CSP ile ve iframe `sandbox` özniteliğiyle render edilir; `raw_html` ve `| raw` çıktısı yalnız bu sandbox içinde görüntülenir (TP-39).

### 11.11 İçerik saklama ve render hataları (TP-40, TP-41)

1. **İçerik saklama.** Bildirim kaydı şablon sürüm kimliğini kalıcı olarak taşır. Render edilmiş içerik anlık görüntüsü saklama sınıfına göre tutulur (Access OP-74, Access Ek C) ve özne başına anahtarla şifrelidir; özne silme talebinde anahtar imha edilir (crypto-shredding), satır iskeleti kalır. OTP ve doğrulama alt türlerinde render edilmiş içerik hiç saklanmaz; yalnız özeti ve şablon sürümü tutulur. Diğer sınıflarda mesaj başına `retention: none` verilebilir (§9); in-app kanalıyla birleşimi reddedilir (§15) (TP-40).
2. **Render hatası ayrı olaydır.** Render hatası teslim hatasından ayrı bir olaydır: `notification.render_failed` + `failure_reason: missing_variable | render_timeout | output_too_large | schema_violation`. Render hatasında retry yoktur; kiracıya görünür gürültü üretilir (panelde toplu: "Son 24 saatte 4.312 bildirim `shipment.carrier` eksik olduğu için gönderilmedi"). Yalnız iç loga yazmak yeterli değildir (TP-41).

### 11.12 Bağımlılık disiplini ve içerik güvenliği (TP-42 … TP-44)

1. **Golden-file regresyonu.** Şablon motoru, MJML derleyicisi, CLDR verisi, tzdata ve Relay'in filtre modülü pinlenir. Yükseltmede golden-file testleri çalışır; beklenmeyen bir fark yükseltmeyi durdurur (TP-42).
2. **Soğuk başlangıç.** CLDR verisi açılışta ısıtılır; ilk gönderim soğuk yükleme yüzünden render zaman aşımına düşmez. tzdata otomatik güncellemesi kapalıdır (§10) (TP-43).
3. **İçerik veridir.** Bildirim içeriği bir ajana ya da dil modeline verildiğinde veri olarak gider, talimat olarak değil. İçerik ayrıcalıklı bağlama girmez; insan ya da dış sistem kaynaklı serbest metin ayrı alanda "güvenilmez içerik" işaretiyle taşınır (§17) (TP-44).

### 11.13 Karar register'ı

| ID | Karar | Statü | Gerekçe/kaynak |
|---|---|---|---|
| TP-1 | Şablon kanal × locale matrisidir, sürümlüdür; işlemsel ve pazarlama şablonları dönüştürülemeyen ayrı tiplerdir | FROZEN (teknik) | 6563 ve CAN-SPAM: iletinin birincil amacı belirler; tip sistemi yanlış sınıflandırmayı engeller |
| TP-2 | Kiracı ve sistem şablonları için tek motor: Liquid (Solid); EEx yalnız derleme zamanı kodunda | FROZEN (teknik) | EEx keyfi kod çalıştırır (SSTI = RCE) ve atom tablosunu doldurur |
| TP-3 | Kiracı dizesi eval/atom/terim çözme yoluna ulaşamaz; CI statik denetimi; ihlal güvenlik olayı | FROZEN (teknik) | Güvenlik sınırı mimariden gelir, filtrelemeden değil |
| TP-4 | `include`/`render` yok; daraltılmış etiket seti; tanımlı filtre seti; katı değişken ve filtre | FROZEN (teknik) | Dosya sistemi erişimi yol geçişi açar |
| TP-5 | Bağlamda yalnız izin listeli düz veri; iç yapılar, kiracı kimliği, sırlar girmez; derinlik ≤ 5 | FROZEN (teknik) | Yapı nesnesi verilirse iç alanlar şablondan okunabilir |
| TP-6 | Statik limitler: 256 KB, 10 döngü, derinlik 2, 5.000 düğüm | POLICY DEFAULT | Yayında ölçülür, çalışma anı maliyeti yok |
| TP-7 | Render ayrı, zaman sınırlı süreçte (e-posta 50 ms, diğer 10 ms); aşan çıktı reddedilir, kesilmez; her çıktı ölçülür ve kaydedilir | FROZEN (teknik) · PD (süreler) | ntfy şablon CPU DoS olayı; ⚠️ tipik render süreleri (SMS/push ~30–150 µs, e-posta ~0,5–3 ms) ölçülmedi |
| TP-8 | MJML yalnız yayında derlenir; gönderim yolunda NIF yok; derlenmemiş sürüm yayımlanamaz | FROZEN (teknik) | Zaman sınırı NIF içinde takılan süreci durduramaz; scheduler bütünlüğü |
| TP-9 | Omurga + kanal katmanı varyant modeli | FROZEN (teknik) | Novu ve Knock kanal başına içerik modeli |
| TP-10 | İçerik kanal başına elle yazılır; otomatik türetme yok; taslak yardımcısı yalnız arayüzde | FROZEN (teknik) | Courier Elemental modelinin reddi: uzunluk rejimleri ve Türkçe ek yapısı |
| TP-11 | Varyant yoksa o kanala gönderilmez + `rule_id`; hiç varyant yoksa gönderim durur | FROZEN (teknik) | Boş mesaj sessiz hatadır |
| TP-12 | İşlemsel/operasyonel şablona promosyon sızması yayın kapısında reddedilir | FROZEN (teknik) | Bilgilendirme iletisi tanıtım içeremez (6563); tercih merkezinden önemli kontrol |
| TP-13 | Olay şeması JSON Schema 2020-12, workflow sürümüne ait; yayın, kabul ve render'da doğrulama zorunlu | FROZEN (teknik) | Draft 4 araçları `prefixItems`, `unevaluatedProperties` desteklemez |
| TP-14 | Değişken kritiklik sınıfları (`required` varsayılan, `fallback`, `optional`, `decorative`); beyan edilmemiş değişken reddedilir | FROZEN (teknik) | Güvenli varsayılan gürültülü olandır |
| TP-15 | `maxLength` zorunlu; yayında en kötü durum uzunluğu kanal limitleriyle karşılaştırılır | FROZEN (teknik) | 60 satırlık liste 40 KB'lık e-postayı 150 KB yapabilir |
| TP-16 | Para string tutar + para birimi; ISO 8601 UTC tarih; önceden biçimlendirilmiş değer yok | FROZEN (teknik) | Ön biçimlendirme locale'i üreticiye kaçırır, çok dilli gönderimi imkânsız kılar |
| TP-17 | Şema evrimi kuralları; statik değişken çıkarımı ve kullanım dizini | FROZEN (teknik) | Alan kaldırmanın etkisi önceden görülür |
| TP-18 | SMS kodlama politikası (`transliterate`/`turkish_shift`/`ucs2`, varsayılan `turkish_shift`); katalogda `turkish_single_shift: verified\|unverified`; doğrulanmamış sağlayıcıya `ucs2`; kodlama açıkça verilir; muhafazakâr segment | FROZEN (teknik) · PD (varsayılan politika) | 3GPP TS 23.038 Annex A.2.1 Türkçe tek kaydırma: 155 / 148–149 karakter; ⚠️ sağlayıcı desteği tek tek doğrulanmadı |
| TP-19 | SMS'te emoji şablonda yasak, değişkende bayraklı; yasal metin transliterasyonsuz ve bütçeden önce; kontrol, sıfır genişlik ve yön karakterleri ayıklanır | FROZEN (teknik) | Tek emoji mesajı UCS-2'ye zorlar; Trojan Source sınıfı |
| TP-20 | Push sunucuda render, `loc-key` yalnız açık istekle; JSON kodlayıcı; 4096 bayt ölçümü; Android 1024 karakter en kötü durum kapısı | FROZEN (teknik) | `loc-key` çeviriyi uygulama sürümüne kilitler; AOSP `MAX_CHARSEQUENCE_LENGTH = 1024` |
| TP-21 | Zorunlu hassasiyet sınıfı; `sensitive`'de nötr kilit ekranı metni + uygulama içi tam içerik; hassas terim taraması ve açık onay | FROZEN (teknik) | "Bu ekranı bir yabancı görürse sorun olur mu?" testi |
| TP-22 | E-posta: konu + ön başlık + HTML + düz metin (zorunlu); konu denetimi; 70 KB uyarı / 90 KB ret, enjeksiyondan sonra yeniden ölçüm; koyu mod meta | FROZEN (teknik) · PD (eşikler) | `MIME_HTML_ONLY` spam cezası; ⚠️ Gmail ~102 KB kırpma eşiği resmî değil, topluluk ölçümü |
| TP-23 | WhatsApp: kaydedilen parametre temizleyici; ayrı yaşam döngüsü; yeni içerik = yeni Meta şablon adı; dönüş = eski ad; kota ve red gerekçesi panelde | FROZEN (teknik) | Meta: onaylı şablon 30 günde 10, 24 saatte 1 düzenleme; dönüş de düzenleme sayılır; ⚠️ parametre biçim kuralları birincil kaynaktan doğrulanamadı |
| TP-24 | Kanal tipine göre kaçış; render kanal tipini zorunlu alır; aynı bağlam iki kanala verilmez; `raw_html` ve `\| raw` izinli ve yalnız sandbox önizlemede | FROZEN (teknik) | Liquid otomatik HTML kaçışı yapmaz |
| TP-25 | Locale BCP 47; profil → cihaz → (yalnız inbox/web) `Accept-Language` → kiracı varsayılanı; `default_locale` zorunlu, sistem varsayılanı yok | FROZEN (teknik) | Novu `en_US` zorunluluğu dersi; sabit varsayılan AB/ABD kiracısında yanlış |
| TP-26 | Fallback `tr-TR → tr → kiracı varsayılanı`; varyant yoksa dur + `rule_id`; `template_locale_missing` panelde; anahtar ya da boş dize asla gösterilmez | FROZEN (teknik) | En görünür başarısızlık biçimi çeviri anahtarının kullanıcıya düşmesidir |
| TP-27 | ICU MessageFormat (klasik sözdizimi); CLDR çoğul (≤ 6 kategori), `=0`; Gettext çoğulu yok; CLDR biçimlendirme render anında | FROZEN (teknik) | Gettext Türkçe `n > 1` kuralı "0 mesaj" için tekil üretir; Türkçe CLDR `one`/`other` |
| TP-28 | Büyük/küçük harf filtreleri locale'e duyarlı (`tr`'de İ/ı) | FROZEN (teknik) | Naif dönüşüm Türkçe'de yanlış harf üretir |
| TP-29 | RTL'de değişkenler yön izolasyon karakterleriyle sarılır (SMS hariç); `dir` açıkça taşınır | FROZEN (teknik) | Unicode bidi; ⚠️ izolasyon karakterlerinin push'taki etkisi doğrulanmadı |
| TP-30 | İki çeviri akışı (ürün metinleri / kiracı şablonları); makine çevirisi insan onayı olmadan yayımlanmaz; yer tutucu koruma ve tutarlılık; çeviri birimi cümle | FROZEN (teknik) | Kiracı şablonunu dış çeviri sistemine itmek veri koruma sorunudur |
| TP-31 | Yayımlanmış sürüm değişmez; monoton sürüm + `checksum`; dönüş = işaretçi + yeniden doğrulama; denetim kaydı | FROZEN (teknik) | Değişmez sürüm önbellek anahtarıdır ve tekrar oynatmayı mümkün kılar |
| TP-32 | Yayın kapısı: sert ve uyarı kontrolleri tablosu; en kötü durum önizlemesi zorunlu | FROZEN (teknik) | Sorun gönderimde değil yayında yakalanır |
| TP-33 | Ticari ileti zorunlu yasal altbilgisi sert kapı (TR: unvan, MERSİS/iletişim, ret talimatı, nitelik ibaresi; ABD: fiziksel adres) | FROZEN (teknik) | 6563 ve Ticari İletişim Yönetmeliği; CAN-SPAM |
| TP-34 | Erişilebilirlik ve içerik lint'i uyarı düzeyinde | FROZEN (teknik) | EAA / EN 301 549; Apple Intelligence özetlemesi ilk cümleyi kullanır |
| TP-35 | Kiracı ve alt kiracı başına sürümlü layout + `brand.*` + tek seviyeli kontrollü parçalar; serbest `include` yok; sürümler gönderim başında sabit | FROZEN (teknik) | Ortak altbilgi değişikliği tek yerden; güvenlik yüzeyi açılmaz |
| TP-36 | Alt kiracı marka/layout/varyant mirası: "yoksa üsttekini kullan, varsa ezme" | FROZEN (teknik) | §18 alt kiracı modeli |
| TP-37 | Üretici sahipli şablon: metin ve çeviri üreticinin, kiracı yalnız izinli marka alanlarını değiştirir, kanal render'ı Relay'in | FROZEN (teknik) | Access X35 korunan mesaj anahtarları, Access X39 |
| TP-38 | Üç seviyeli önizleme; örnek veri kaynakları (şema örnekleri, maskeli gerçek olay, sınır değerler) | FROZEN (teknik) | Gerçek uzunlukta maskeleme taşmayı görünür kılar |
| TP-39 | Önizleme ayrı origin + CSP + iframe sandbox; ham HTML yalnız orada | FROZEN (teknik) | Listmonk önizleme stored XSS olayı |
| TP-40 | Sürüm kimliği kalıcı; içerik anlık görüntüsü saklama sınıfına göre ve özne anahtarıyla şifreli; OTP/doğrulamada içerik yok (özet + sürüm); `retention: none` (in-app ile birleşimi reddedilir) | FROZEN (teknik) | Access OP-73, Access OP-74, Access Ek C; onay ve OTP içeriğinin saklanmaması |
| TP-41 | `notification.render_failed` + `failure_reason` sözlüğü; retry yok; panelde toplu görünür | FROZEN (teknik) | SES `RenderingFailure`, SparkPost üretim hatası ayrımı |
| TP-42 | Motor, MJML, CLDR, tzdata ve filtreler pinli; beklenmeyen golden-file farkı yükseltmeyi durdurur | FROZEN (teknik) | Bağımlılık yükseltmesi içerik değişikliğidir |
| TP-43 | CLDR verisi açılışta ısıtılır; tzdata otomatik güncellemesi kapalı | FROZEN (teknik) | Soğuk yükleme ilk gönderimi zaman aşımına düşürür |
| TP-44 | Bildirim içeriği ajana veri olarak gider, talimat olarak değil; güvenilmez metin ayrı ve işaretli | FROZEN (teknik) | OWASP LLM01 dolaylı prompt injection; §17 |
