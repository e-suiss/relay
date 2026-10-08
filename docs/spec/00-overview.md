## Kısaca Relay

Bu bölüm spec'in özetidir. Normatif metin numaralı bölümlerdedir; çelişkide onlar kazanır. Bu bölümde karar ID'si verilmez.

### Relay nedir?

Relay, Suiss'in **bildirim, mesajlaşma ve event orkestrasyon platformudur**. Bir ürün ya da sistem "şu oldu" dediğinde Relay bu olayı alır ve şunları yapar:

- kimin, hangi kanaldan, ne zaman haberdar edileceğine karar verir (workflow, rota, tercih, sessiz saat, saat dilimi);
- izin ve mevzuat kurallarını uygular (İYS, tek tıkla çıkış, ülke kuralları);
- mesajı doğru dilde ve kanala uygun biçimde hazırlar (şablon, yerelleştirme, marka);
- sağlayıcıya iletir, gerekirse yeniden dener ya da başka kanala geçer (push, e-posta, SMS, WhatsApp, in-app, webhook ve olay hedefleri);
- ne olduğunu kanıtıyla kaydeder: teslim edildi, başarısız oldu, bilinmiyor ya da **neden gönderilmedi**.

Relay insanlara, servislere, cihazlara ve yapay zekâ ajanlarına aynı motorla teslim eder. Ajanlar için ayrıca bir yanıt beklerken bekleme noktası, kalıcı posta kutusu ve standart ajan protokolleri (A2A, MCP, AG-UI) sunar.

Relay'in cevapladığı tek soru şudur (§1.5):

> **"Bu event veya mesaj doğru kişiye, servise, cihaza ya da ajana nasıl ulaştırılacak?"**

Relay açık kaynaktır (Apache-2.0). Aynı kod hem kurumun kendi kurduğu (self-host) hem de Suiss'in işlettiği (SaaS) biçimde çalışır; hiçbir özellik yalnız bulutta değildir (MD-4). Çalışma ortamı Elixir/OTP, zorunlu bileşenleri PostgreSQL ve Valkey'dir (MD-5, MD-6). Türkiye mevzuatı mimarinin girdisidir; AB ve ABD kuralları aynı veri tablosuna satır olarak eklenir (MD-17).

### Hangi problemi çözer?

Her ürün bildirim gönderir ve her ekip aynı işleri yeniden yazar: kanal seçimi, retry, sağlayıcı yedeği, tercih merkezi, İYS, sessiz saat, teslim takibi, inbox, webhook. Bunları her ürünün ayrı yazması üç sonuç doğurur:

| Sorun | Sonuç | Relay'in cevabı |
|---|---|---|
| Kurallar dağınık | Bir ürün sessiz saati uygular, öbürü uygulamaz; bir kanal İYS'yi atlar | Tek karar katmanı: kapılar bayrakla atlanamaz (MD-14) |
| "Gitti mi?" bilinmez | Kullanıcı "kod gelmedi" der, kimse nedenini bulamaz | Append-only teslim defteri; gönderilmeyen her mesaj neden koduyla görünür (MD-12, MD-15) |
| Ajan dünyası boşta kalır | Ajan insana soru sorar ama yanıt kaybolur, gecikir ya da kimin verdiği belli olmaz | Bekleme noktası, erken yanıt tamponu, kanal kanıt düzeyli yanıt (MD-3, MD-11) |

**Neden şimdi?** Ajanlar insanlardan ve birbirlerinden yanıt bekleyerek çalışır. Bugünkü bildirim platformları tek yönlü gönderir; dayanıklı yürütme motorları beklemeyi bilir ama insana ulaşmayı, eskalasyonu ve kanal kurallarını bilmez. Relay bu ikisinin arasındaki teslim ve yanıt katmanıdır (§4.4).

### Ne değildir?

| Relay ... değildir | Bu işin sahibi | Relay'in o işteki rolü |
|---|---|---|
| Yetki ve onay kaynağı | Access | Onay davetini teslim eder, yanıtı toplar; yanıt yetki değildir (MD-2) |
| İş akışı / dayanıklı yürütme motoru (checkpoint, devam, telafi) | Executor, LangGraph, müşteri kodu | Bekleme noktasını tutar, yanıtı eşleştirir, "çözüldü" olayını teslim eder (MD-3) |
| İnsanın iş ve onay kuyruğu | Work | Work'ün eskalasyon politikasını uygular, kişiye ulaştırır |
| Kimlik sağlayıcı (IdP) | Access ya da başka bir OIDC IdP | Operatör ve abone kimliğini bağlı IdP'den alır |
| OTP kodu üreten ve doğrulayan sistem | Access ya da gönderen ürün | Kodu teslim eder; hedef korumalarını (numara hız sınırı, SMS pumping) uygular |
| Pazarlama otomasyonu (segment motoru, journey) | Kiracının kendi sistemi | Topic aboneliği ve liste ile gönderim sunar (F-5) |
| Taşıma katmanı (APNs, FCM, SMTP, SMS operatörü) | Platform ve sağlayıcılar | Onları kullanır; SaaS'ta kendi posta sunucusunu işletmez (F-3) |
| Analitik veritabanı (OLAP) | Kiracının veri ambarı | Hazır raporlar + olay akışını kiracının hedefine aktarma (F-7) |
| Müşteri kodu çalıştıran platform | — (yasak) | Özelleştirme veri, şablon ve beyaz listeyle yapılır (MD-16) |

Relay'de hiçbir zaman olmayacak şeylerin tam listesi §2.7'dedir. En önemlileri:

- **Teslim onay değildir.** Bir butona basılması, SMS yanıtı ya da "görüldü" hiçbir zaman yetki kanıtı değildir.
- **Sessiz kayıp yoktur.** Gönderilmeyen her bildirim neden koduyla kaydedilir ve panelde, webhook'ta, metrikte görünür.
- **Fiziksel silme yoktur.** Silme yumuşak silme ve crypto-shredding ile yapılır (Access OP-73, Access OP-74).
- **Ajana talimat yazılmaz.** Ajana giden şey tipli alanlı yapılandırılmış mesajdır; insan ya da dış kaynaklı metin "güvenilmez içerik" işaretiyle ayrı taşınır.

### En temel kavramlar

Kesin tanımlar §5'tedir.

| Kavram | Ne demek | Örnek |
|---|---|---|
| **Kiracı (tenant)** | Relay'i kullanan müşteri; kendi verisi, anahtarları, ayarları vardır | Bir e-ticaret şirketi |
| **Alt kiracı** | Kiracının içindeki tek seviyeli marka/müşteri birimi; ayarları kiracıdan miras alır | Bir B2B yazılımın her kurumsal müşterisi |
| **Ortam** | Kiracı başına ayrı `live` ve `test` veri düzlemi; işleme hattı aynıdır | Test anahtarıyla gönderilen bildirim gerçek kullanıcıya gitmez |
| **Alıcı (abone)** | Bildirimin ulaşacağı kişi; adresleri, cihazları, dili, saat dilimi vardır | Ayşe: e-posta, telefon, iki cihaz, `tr-TR`, `Europe/Istanbul` |
| **Ajan alıcısı** | Relay'de kayıtlı yapay zekâ ajanı; teslim uçları ve posta kutusu vardır | Bir satın alma ajanı |
| **Olay (event)** | Relay'e gelen "şu oldu" bilgisi; bir workflow'u tetikler | `order.shipped` |
| **Workflow** | Bir olay için atılacak adımların sürümlü tanımı | Push gönder → 1 saat bekle → görülmediyse e-posta |
| **Rota politikası** | Kanalların hangi sırayla ya da birlikte deneneceğini söyleyen adlandırılmış kural | "Önce push, başarısızsa SMS" |
| **Mesaj sınıfı** | Yedi sabit üst sınıftan biri; kuralların çoğu buna bağlıdır | `security`, `transactional`, `marketing`, `action_required` … |
| **Kategori** | Kiracının kendi tanımladığı bildirim türü; bir sınıfa bağlanır | "Kargo durumu" → `transactional` |
| **Şablon** | Kanal × dil matrisinde sürümlü içerik | Push başlığı + gövde, e-posta HTML + düz metin |
| **Tercih** | Alıcının bildirim isteği: kategori × kanal, sessiz saat, digest | "Kampanyaları SMS ile istemiyorum" |
| **İzin** | Ticari ileti için hukuki onay/ret kaydı; tercihten ayrıdır | İYS'de kayıtlı e-posta onayı |
| **Bildirim, teslim, deneme** | Bildirim mantıksal mesajdır; teslim belirli kanal ve hedefe gönderim niyetidir; deneme tek dış istektir | Bir bildirim → push ve e-posta teslimi → e-postada iki deneme |
| **Teslim defteri** | Her teslim olayının değiştirilemez kaydı; durum buradan türetilir | `sent` → `delivered` |
| **Atlama nedeni** | Gönderilmeyen bildirimin makinece okunur nedeni ve kuralı (`reason` + `rule_id`) | "Sessiz saat", "İYS reddi", "aynı içerik tekrarı" |
| **Bekleme noktası** | "Şu anahtara yanıt bekleniyor, son tarih X" kaydı | Ajanın "Bu siparişi onaylıyor musunuz?" sorusu |
| **Posta kutusu** | Alıcı başına sıra numaralı kalıcı mesaj kaydı; insan yüzü inbox, ajan yüzü lease/ack | Ajan uyanınca kaçırdıklarını sırayla okur |
| **Topic** | Abone olunabilen konu; fanout bunun üzerinden yapılır | "Proje X güncellemeleri" |
| **Olay hedefi** | Relay'in olayları teslim ettiği dış uç: HTTPS webhook, kuyruk, nesne deposu | Kiracının Kafka konusu |
| **Kill switch** | Kapsam × hedef × sınıf bazında gönderimi durduran tek mekanizma | "Bu kampanyanın SMS'ini durdur" |

### Temel ilkeler

1. **Bağımsız ama sürtünmesiz.** Relay, Access olmadan tek başına çalışır; Access bağlandığında tek ayarla birlikte çalışır ve müşteri kodu değişmez (MD-1).
2. **Relay yetki kaynağı değildir.** Teslim, ack, görüldü ve kanal yanıtı yetki ya da onay değildir (MD-2).
3. **Bekleme Relay'in, yürütme bekleyenin.** Relay bekleme noktasını ve teslimi tutar; checkpoint ve devam ettirme bekleyen taraftadır (MD-3).
4. **Sınıf kuralı belirler.** Mesaj sınıfı kabul anında atanır ve değişmez; şerit, öncelik tavanı, tercih ve uyum kuralları sınıftan türer (MD-8).
5. **Sessiz kayıp yok.** Her karar bir kural kimliğiyle kaydedilir (MD-12).
6. **Doğruluk Postgres'te.** Valkey, push, realtime ve webhook yalnız sinyal ve hızlandırıcıdır (MD-6, MD-15).
7. **Kapılar fail-closed.** Uyum ve güvenlik kapıları bayrakla atlanamaz; kiracı kuralı yalnız sıkılaştırır (MD-14).
8. **Fiziksel silme yok, bölgeler arası veri akışı yok** (MD-9, MD-10).

### Access ile ilişki

| Durum | Davranış |
|---|---|
| Access, Relay olmadan | Access kendi mesajlarını yerleşik doğrudan gönderim moduyla yollar (SMTP + tek HTTP SMS sağlayıcısı, basit retry) |
| Access, Relay ile | Access'in insana giden bütün mesajları Relay'den gider; Access Relay'de yalıtılmış platform kiracısıdır |
| Relay, Access olmadan | Kendi API anahtarları, operatör girişi, abone jetonu; başka bir IdP ile standart OIDC |
| Relay, Access ile | Operatör girişi ve step-up, abone jetonu, ajan kimliği ve pazarlama izni Access'ten gelir; denetim kayıtları bağlanır |

Ayrıntı: MD-1, §7, Access E40.
