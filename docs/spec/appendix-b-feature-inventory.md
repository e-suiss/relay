## Ek B. Özellik envanteri ve yapım sırası (normatif değil)

Bu ek, spec'te tanımlı bütün yetenekleri, kuralları ve davranışları yapım sırasına göre dizer; proje bu sırayla yapıldığında hiçbir karar atlanmamış olur. **Normatif değildir:** normatif metin numaralı spec bölümleridir; her maddenin kaynağı `_Kaynak:_` alanında § ve ID olarak verilir, çelişkide spec bölümleri kazanır. Sıra T-54'ün iki kısıtına uyar: ürün yüzeyi (HTTP API, CLI, operatör aracı) ve kendi akış kontrolü bileşenleri erken aşamadadır.

**Nasıl kullanılır**
- Aşamalar sırayla yapılır; her aşama öncekilerin üstüne kurulur.
- Her aşamanın başında **spec dışı ön koşullar** vardır: spec'te yazmayan ama o aşamayı yapabilmek için gereken kararlar, değerler ve altyapı. "(Adem kararı)" işaretli olanlar karar gerektirir; karar spec'e yeni bir ID ile yazılır. Bir aşamanın spec dışı ön koşulları kapanmadan özelliklerine başlanmaz.
- Her madde bir onay kutusudur (`- [ ]`). Kutu yalnız kod + kaynak gösterdiği kuralların testleri + belgeler bitince işaretlenir (`- [x]`).
- Sözleşmeler (OpenAPI/AsyncAPI, SQL şeması ve DB fonksiyonları, test vektörleri) bağımlı koddan önce yazılır ve onaylanır.
- Her aşamanın sonundaki **doğrulanacak sınırlar**, o aşamada testle kanıtlanması gereken değişmez ve kural ID'leridir.
- Sondaki **bilinçli olarak olmayanlar** listesi KAPSAM DIŞI kararlardır; hiçbir aşamada yapılmaz.

**Aşama özeti**

| Aşama | Ad | Amaç | Madde |
|---|---|---|---|
| 0 | Proje temeli | Depo, CI kapıları, yerel ortam, test, performans ve tedarik zinciri altyapısı. | 43 |
| 1 | Veri ve kiracılık temeli | Şema, kiracı yalıtımı (RLS), defter iskeleti, outbox, idempotency, saklama, denetim kaydı, Valkey ve Oban. | 59 |
| 2 | Platform bileşenleri | Hız limiti, adalet, şeritler, devre kesici, retry/DLQ, kill switch, posta kutusu ve bekleme noktası çekirdeği. | 39 |
| 3 | Giriş, API ve operatör yüzeyi | Sözleşmeler, sunucu ve operatör kimliği, `POST /v1/events`, workflow iskeleti, hatalar, kota, CLI. | 86 |
| 4 | Karar çekirdeği | Sınıflar, kategoriler, kapı → filtre → zamanlayıcı kafesi, tercih, izin, bastırma, sessiz saat. | 42 |
| 5 | Şablon ve render | Şablon motoru, kanal varyantları, değişken sözleşmesi, yerelleştirme, layout, sürüm ve önizleme. | 48 |
| 6 | Kanallar ve sağlayıcılar | Adaptör sözleşmesi, kanal kanıt tablosu ve devreye alma kapısı, hata sınıfları, failover, kanal adaptörleri. | 74 |
| 7 | Teslim durumu ve gözlem | Dört eksenli model, dış projeksiyon, DLR pencereleri, mutabakat, etkileşim, analitik, telemetri ve SLO. | 53 |
| 8 | Workflow ve yönlendirme | Gelişmiş adımlar, rota, yükseltme ve eskalasyon, digest, throttle, zamanlama, topic, A/B ve kampanya. | 43 |
| 9 | Inbox ve realtime | Inbox öğeleri ve durumları, rozet, WebSocket/SSE, abone jetonu, cihazlar arası yayılım, saklama. | 44 |
| 10 | Webhook ve olay teslimi | Tek teslim motoru, Suiss imza profili, retry/DLQ/replay, uç sağlığı, SSRF, ek hedefler ve portal. | 55 |
| 11 | Uyum ve Türkiye | Ülke × kanal × sınıf tablosu, İYS, ret ve tek tık çıkış, BTK SMS kuralları, OTP hedef korumaları. | 35 |
| 12 | Ajanlar | Ajan alıcı, bekleme noktasının ajan yüzü, posta kutusu lease/ack, yanıt toplama, onay güvenliği, A2A/MCP/AG-UI. | 55 |
| 13 | Access entegrasyonu | Bağlantı ve keşif, platform kiracısı, eşleme, operatör kimliği, token exchange, izin olayları, CIBA. | 26 |
| 14 | Deneyim ve SDK'lar | Panel, görsel editör, "neden almadım" ekranı, UI bileşenleri, SDK'lar, test düzlemi deneyimi, belge sitesi. | 52 |
| 15 | İşletim ve dayanıklılık | Bölgeler, HA/DR, arşiv ve silme işletimi, runbook ve olay müdahalesi, göç, kapasite, kaos. | 41 |

**Toplam:** 795 madde, 73 spec dışı ön koşul, 38 kapsam dışı karar.

---

### Aşama 0 — Proje temeli

Depo, tek Mix uygulaması ve `boundary` sınırları, kod kalitesi ve güvenlik CI kapıları, tek komutlu yerel ortam, test ve performans altyapısı, tedarik zinciri ve dokümantasyon altyapısı kurulur; spec'in yorum çerçevesi ve karar kuralları burada sabitlenir. Hiçbir aşamaya dayanmaz; bütün aşamalar buna dayanır.

#### Spec dışı ön koşullar
- [ ] **İddia dili denetim mekanizması** — F-25/INV-60 izinli/yasak ifade tablosunu veriyor; belge, panel ve API metinlerinde nasıl denetleneceği (lint, inceleme listesi) tanımlı değil. (Adem kararı)
- [ ] **Kabul testi alanlarının doldurulması** — F-22 gereği "doldurulacak" işaretli FROZEN (teknik)/MKT satırlarının kabul testleri, bağlı aşamanın özellik kodundan önce yazılıp onaylanmalı. (Adem kararı)
- [ ] **OQ-27 PD değerleri** — F-28 gereği "PD (değer ölçümle)" değerleri, bağlı özellik yapım sırasına girerken konmalı; spec'te değer yok. (Adem kararı)
- [ ] **SQL lint aracı** — WF-47 `AT TIME ZONE` yasağı ve INV-47/OP-9 `DELETE`/`TRUNCATE`/`DROP` yasağı SQL dosyalarını tarayan bir lint adımı ister; araç ve adım tanımlı değil. (Adem kararı)
- [ ] **İYS taklidi ve sandbox erişimi** — PC-34 İYS sandbox sözleşme testi ister; §19 taklit listesinde İYS yok; sandbox hesabı da yapım ön koşulu. (Adem kararı)
- [ ] **Eksik kanal taklitleri (HMS, Web Push uç noktası, ses, Slack/Teams/Telegram/Discord)** — §19 `conformance/` listesinde yoklar; CH-2/CH-3 test vektörlü adaptör ister. (Adem kararı)

#### Yorum çerçevesi ve karar kuralları
- [ ] **Kural/tanım: ürün tanımı ve tez** — Relay'in tanımı, temel problemi, tek sorusu, tezi ve nesnesi (mesaj ve teslim; içerik ve "kime, neden" üreticinin); kod yazdırmaz, tüm aşamaların yorum çerçevesidir. _Kaynak:_ §1.1–§1.6, §2.1, §5.1; F-1, F-2, C-1.
- [ ] **Kural/tanım: karar statü sistemi ve register kuralları** — Dokuz statü, DAY-1 niteliği, karar kaydı alanları, yeniden açma koşulları, WATCH/PD/EA sızıntı yasağı, PD değişim yönü, belirsizlikte implementasyonun karar vermemesi, register/ID/Access atıf biçimi, ADR yok; farklılaşma iddiası kuralı. _Kaynak:_ §3.1–§3.7, §4.4.2; F-20, F-21, F-24, F-26, F-27, F-29, F-30, MKT-1.
- [ ] **Kural/tanım: farklılaşma iddiaları (WATCH)** — Pazar karşılaştırması; kod işi değil, karşılık gelen yetenekler ilgili aşamalarda. _Kaynak:_ §4.4.2; MKT-2, MKT-3, MKT-4, MKT-5, MKT-6, MKT-7, MKT-8, MKT-9, MKT-10, MKT-11, MKT-12, MKT-13, MKT-14, MKT-15, MKT-16, MKT-17, MKT-18.
- [ ] **Kural/tanım: kanal ve platform çalkantısı (WATCH)** — WhatsApp, BTK, Türkçe SMS kodlaması, push, sohbet, e-posta, ABD, ajan protokolü ve lisans gözlemleri; bilgi karar metnine girmez, yalnız "veri olarak tut" kuralları ilgili aşamalarda uygulanır. _Kaynak:_ §4.5.
- [ ] **Olgun standart seti** — Yeni taşıma ya da imza biçimi icat edilmez; CloudEvents 1.0, Standard Webhooks, RFC 8058, RFC 8291/8292, OpenAPI 3.1, AsyncAPI 3.x, A2A, MCP, OIDC, RFC 8693 kullanılır (yetenekler ilgili aşamalarda). _Kaynak:_ §4.1, §4.2; L-1.
- [ ] **Terim ve adlandırma sözlüğü** — Ontoloji kanonik: kod adları İngilizce `snake_case`, durumlar küçük harf, olay adları `noun.verb_past`, `live`/`test`, `cancelled`; UI terimleri ontolojiden türer; terim tablosu tek yerde. _Kaynak:_ §5 okuma kuralı, §5.14; L-50.
- [ ] **İddia dili ve garanti sınıfları** — Belge, panel, API yanıtı ve pazarlama metni BS/UDC/NG/PU sınıflarına ve izinli ifade tablosuna uyar ("exactly-once teslim", "push teslim edildi", "IETF standardı" yasak). _Kaynak:_ §3.3, §3.3a, §5.14, §6.12; F-25, INV-60, MD-15.
- [ ] **Kabul testi ve karşı örnek alanları** — FROZEN (teknik) ve MKT kural satırlarının kabul testi/karşı örnek alanlarını tutan ve "doldurulacak" olanları raporlayan doküman yapısı. _Kaynak:_ §3.1b; F-22.
- [ ] **PD değer kapısı** — "PD (değer ölçümle)" olan varsayılana dayanan özellik değer konmadan yayımlanmaz; sürüm kontrol listesinde OQ-27 listesi denetlenir. _Kaynak:_ §3.1; F-28.

#### Çalışma zamanı ve uygulama iskeleti
- [ ] **Elixir/OTP + Phoenix çalışma zamanı** — Sunucu Elixir/OTP üzerinde; HTTP API, realtime ve panel Phoenix ile tek uygulamada; ayrı realtime sunucusu ve edge hedefi yok; bilinen zayıflıklar (TLS verimi, bellekten sır silinememesi, FIPS yok) belgelenir. _Kaynak:_ §1.7, §19.1; MD-5, T-1.
- [ ] **WATCH: dil kararının yeniden değerlendirme koşulları** — Telafili saga zorunluluğu, PG üstü zamanlayıcı/bekleme tablosunun ölçümde yetmemesi ve FIPS zorunluluğu izlenir; tetiklenirse dil kararı yeniden açılır. _Kaynak:_ §19.1, §22.2; T-2, MD-5, OQ-30.
- [ ] **Tek lisans ve özellik eşitliği** — Bütün kod Apache-2.0; lisans bayrağı, "yalnız bulut" ya da kurulum türüne göre özellik kilidi yok; SaaS ve self-host aynı kod (kurulum = işletim farkı). _Kaynak:_ §1.7, §4.3.1, §5.2; MD-4, INV-57, L-33, L-34, C-9, C-15, MKT-4, F-11.
- [ ] **Depo ve klasör yapısı, `boundary` sınırları** — Tek depo, tek Mix uygulaması (umbrella yok), §19.13.1 klasör yapısı; bağlamlar arası izinli yön `boundary` ile derleme anında; panel React/TS, aynı paketten statik. _Kaynak:_ §19.13.1; T-56, T-57 (madde 6).
- [ ] **Kod içi mimari: saf çekirdek ve behaviour sınırı** — Karar kodu saf fonksiyon (`{:send, …}`/`{:skip, reason, rule_id}`), yan etki kenarda; sağlayıcı, Valkey, KMS, İYS ve dış HTTP behaviour arkasında, testte Mox; süreç yalnız çalışma zamanı aracı. _Kaynak:_ §19.13.2; T-57 (madde 1, 2, 5, 7).
- [ ] **Tek uygulama, tek imaj, rol yapılandırması** — `api`/`worker`/`socket` rolleri aynı paketten yapılandırmayla seçilir; küçük kurulumda üçü tek düğümde; "yalnız bulut" kod yolu ya da lisans bayrağı yok. _Kaynak:_ §19.2; T-3.
- [ ] **Sıkı yapılandırma yükleme** — Tanınmayan yapılandırma anahtarı ya da rol uygulama açılışında hata verir; sessiz varsayılan yok. _Kaynak:_ §6.8; INV-46.
- [ ] **Konteyner giriş noktası ve göç adımı** — Exec biçimli giriş noktası; şema göçleri ayrı init/release komutunda, düğüm açılışında göç yok. _Kaynak:_ §19.2; T-5 (madde 1, 3).
- [ ] **Erlang distribution varsayılan kapalı** — Distribution kapalıyken bütün özellikler çalışır; teşhis pod içinden; açılırsa yalnız TLS + karşılıklı sertifika, çerez sır deposundan, sabit port, iç EPMD. _Kaynak:_ §19.4; T-13.
- [ ] **VM bayrak disiplini** — Zamanlayıcı sayısı açılışta loglanır; bayraklar yalnız `msacc` ölçümüyle değişir; meşgul bekleme yalnız ölçülmüş throttling'de kapanır; yığın sınırı gözlem modunda; bellek tavanı ~%75; önyüklemede bellek/topoloji bayrağı yok. _Kaynak:_ §19.9; T-44.
- [ ] **Süreç ve bellek kodlama kuralları** — Posta kutusu yerleşimi süreç başına; refc binary oyun kitabı; bilinçli restart bütçeleri; geri basınç uygulama kodunda; ETS/`persistent_term` kuralları, kiracı başına ETS yok; durumlu kiracı süreçleri tembel ve boşta sonlanır. _Kaynak:_ §19.9; T-45.
- [ ] **NIF istisna kapısı** — Saf Elixir → Port → Rustler NIF → servis merdiveni yalnız ölçüm kanıtıyla; 1 ms kuralı; önceden derlenmiş ikili + sağlama toplamı, musl dahil hedefler; tek izinli NIF listesi register'da; kriptografi için NIF yok. _Kaynak:_ §19.11; T-53.

#### Kod kalitesi ve statik denetimler
- [ ] **Kod kalitesi kapıları** — İngilizce kod; `mix format`; `--warnings-as-errors` (yerleşik tip denetleyicisi dahil); Dialyzer + zorunlu `@spec`; Credo katı + Relay kuralları (saat/rastgelelik portu, SQL yalnız veri katmanında, `IO.inspect`/`dbg` yok, korelasyon kimliği); Sobelow. _Kaynak:_ §19.13.3; T-58 (madde 1–4).
- [ ] **Hata ≠ karar, gizli veri tipleri, spec atfı, TODO ve belge kuralları** — `{:ok, _}`/`{:error, %Relay.Error{}}`; gönderilmeme `{:skip, reason, rule_id}` ve hata metriğine girmez; maskeli tipler (`Redacted`); `# INV-n:` yorumları; `TODO(#n)` dışı TODO reddi; `@moduledoc`/`@doc` zorunlu. _Kaynak:_ §19.13.3; T-58 (madde 5, 7–10).
- [ ] **Güvensiz dönüşüm ve bağlamsız süreç CI kuralları** — CI, kiracı/dış veriyi `EEx.*`, `Code.eval_*`, `Code.string_to_quoted`, `String.to_atom`, `keys: :atoms` JSON çözme ve güvensiz `:erlang.binary_to_term` yollarından reddeder (ihlal güvenlik olayı); iz bağlamı taşımayan çıplak `Task`/`spawn`/iş başlatmayı yakalar, bağlam ve korelasyon kimliği açık taşınır. _Kaynak:_ §11.2, §14.8.1, §19.9; TP-3, DS-40, T-47, OP-34.
- [ ] **Fiziksel silme CI lint'i** — Kodda/migration'da `DELETE`, `TRUNCATE`, veri `DROP` yakalayan lint (iş kuyruğu temizliği ve arşiv rolü istisnaları açıkça listeli). _Kaynak:_ §1.7, §6.9; MD-9, INV-47.
- [ ] **tzdata sabitleme ve `AT TIME ZONE` lint'i** — tzdata imaja sabitlenir, çalışma anında indirilmez/otomatik güncellenmez; SQL'de `AT TIME ZONE` lint ile yasak; düğümler arası tzdata sürüm eşitliği izlenir; golden testlerle doğrulanır. _Kaynak:_ §10.10, §11.12, §19.10; WF-47, TP-43, T-51 (madde 4).
- [ ] **Sır hijyeni** — Hassas süreç bayrağı, sıfır argümanlı kapanışta sır, `Inspect only:` izin listesi (sürüm derlemesinde doğrulanır), durum biçimlendirmede gizleme, yığın izinde argüman budama, crash dump kapalı/şifreli, özel ETS, genişletilmiş HTTP parametre filtresi. _Kaynak:_ §19.9; T-46.
- [ ] **Log ve korelasyon kuralları** — Yapılandırılmış JSON log; ortak alanlar (`request_id`, `correlation_id`, opak `tenant_id`, kaynak kimlikleri, `env`, `role`); kalıcı korelasyon kimliği süreç sınırında; PII/sır loglanmaz. _Kaynak:_ §19.13.8; T-63 (madde 2, 3).

#### Geliştirme ortamı
- [ ] **Dev mode yok, güvenliği zayıflatan bayrak yok** — "Geliştirme modu", imza doğrulamasını ya da RLS'i kapatan bayrak yoktur; geliştirme yerel eşdeğerlerle (Mailpit, SoftHSM, emülatörler) yapılır. _Kaynak:_ §1.7, §4.2, §6.11, §18.1.3; MD-14, INV-58, L-30, TN-8.
- [ ] **Yerel eşdeğer servislerle compose ortamı** — Resmî `docker compose`: Postgres, Valkey, Mailpit, APNs mock, FCM mock (WireMock HTTP/2), hata enjeksiyonu için toxiproxy; KMS yerine SoftHSM/`age`; test ve yerel geliştirme gerçek hattın aynısını çalıştırır. _Kaynak:_ §8 ilke 4, §8.12, §19.10; X-40, T-52.
- [ ] **`just` komutları ve tek komutlu yerel ortam** — `just dev` (PG 18, Valkey, Mailpit, sağlayıcı taklitleri, toxiproxy, örnek veri, hazır test düzlemi), `just test`, `just check`, `just gen`; asdf/mise. _Kaynak:_ §19.13.10; T-65.

#### Test ve performans altyapısı
- [ ] **Test katmanları ve değişmez kural testleri** — İlk günden birim/özellik (StreamData), sözleşme, gerçek PG + Valkey entegrasyon ve uçtan uca taklit katmanları; her INV/must-never maddesi ve kural kararı spec ID'li en az bir teste izlenebilir bağlanır, mümkünse DB kısıtı/rol yetkisi/CI lint'iyle yapısal zorlanır; satır kapsamı hedef değil; PR paketi ≤ 10 dk; kararsız test karantina, sürüm çıkmaz. _Kaynak:_ §2.7, §6 giriş, §19.13.6; F-11, T-61 (madde 1, 2, 4, 5).
- [ ] **CI sözleşme testi aşaması** — Sunucu her CI koşumunda OpenAPI/AsyncAPI belgelerine karşı sözleşme testinden geçer; uyuşmazlık build'i kırar. _Kaynak:_ §1.7; MD-13.
- [ ] **Benchmark altyapısı** — EA sayıları için repoda kod + ham çıktı + koşum komutu, ölçüm ortamı kaydı, "yeniden üretim bekliyor" etiketi, açık döngü yük üreteci (coordinated omission önlemi). _Kaynak:_ §3.1c; F-23.
- [ ] **Performans disiplini altyapısı** — Benchee sıcak yol benchmark iskeleti; PR'da reduksiyon sayısı tabanlı gerileme kapısı; gece ayrılmış makinede gerçek süre benchmark'ları; istek türü başına bütçe ve aşım alarmı; ölçümsüz optimizasyon reddi. _Kaynak:_ §19.13.13; T-68.

#### Tedarik zinciri, sürüm ve depo süreci
- [ ] **Lisans disiplini ve yasak çerçeveler** — AGPL/GPL projelerden kod kopyalanmaz; bağımlılık lisans değişikliği (OSI dışı lisanslar dahil) CI'da izlenir; Ash ve Commanded/EventStore çekirdekte yok. _Kaynak:_ §4.5 (Lisanslar), §19.10; T-51 (madde 1, 2).
- [ ] **Tedarik zinciri ve depo güvenliği** — `mix.lock`, `.tool-versions`, digest'li imaj; `mix hex.audit` + `mix_audit`; yalnız izin verici lisans (AGPL/GPL CI reddi); yeni bağımlılık gerekçeli, tek bakımcılı kritik bağımlılığın testleri CI'da; her sürüm SBOM, cosign imzası, SLSA provenance, NIF sağlama toplamıyla; gizli bilgi taraması, push koruması, SECURITY.md, CODEOWNERS, imzalı commit; Access §14.7 F-1…F-18 ile aynı. _Kaynak:_ §18.9, §19.13.7; TN-61, T-62.
- [ ] **Bağımlılık sabitleme ve altın dosya regresyonu** — Kilit dosyası sağlama toplamlı; başlangıç sürümleri (Finch 0.24.0, Phoenix 1.8.15, Swoosh 1.28.1, Oban 2.24.1, oban_web 2.13.0); altın dosya regresyon altyapısı beklenmeyen farkta yükseltmeyi durdurur; sürüm PR'ı changelog okunduğunu kaydeder. _Kaynak:_ §19.10; T-50.
- [ ] **OTP yama takibi ve araç zinciri sabitleme** — OTP/Elixir sürümü imajda sabit; güvenlik bildirimleri izlenir, kritik yama hızlandırılmış sürümle; SSH sunucusu ve `inets` başlatılmaz. _Kaynak:_ §19.9; T-49.
- [ ] **`security.txt`** — SaaS alan adında RFC 9116 `security.txt` yayımlanır. _Kaynak:_ §18.9; TN-61.
- [ ] **Sürümleme, CI aşamaları ve yayın hattı** — Ürün SemVer, API tarihli; Conventional Commits + üretilen CHANGELOG; PR (≤ 10 dk), gece ve yayın aşamaları; `mix release`, minimal imaj, imza/SBOM/provenance, Helm chart; self-host ve SaaS aynı imaj ve chart. _Kaynak:_ §19.13.9; T-64 (madde 1–4, SDK yayını hariç).
- [ ] **Süreç ve katkı kuralları** — Trunk-based, doğrusal `main`, force push/dal silme yasak, imzalı commit; `main`'e doğrudan gönderim, dış katkı PR + squash; CONTRIBUTING, SECURITY, CoC, şablonlar, CODEOWNERS; özel güvenlik bildirimi. _Kaynak:_ §19.13.12; T-67.
- [ ] **Dokümantasyon altyapısı** — Spec `docs/spec/`; ADR yok, register'lar karar kaydı, `decision` etiketi; Mermaid C4 `docs/architecture/`; ExDoc; runbook şablonu `docs/runbooks/`; kamu API belgeleri sözleşmeden üretilir. _Kaynak:_ §19.13.11; T-66.

#### Bu aşamada doğrulanacak sınırlar
- **INV-46** — tanınmayan yapılandırma anahtarı/rol açılışta hata.
- **INV-47** — fiziksel silme lint'i (istisnalar listeli).
- **INV-57, INV-58, TN-8** — tek lisans/özellik eşitliği; dev mode ve güvenliği zayıflatan bayrak yok.
- **X-40** — yerel ortam gerçek hattın aynısı.
- **TP-3, T-47** — kiracı verisi eval/atom/terim çözme yollarına ulaşamaz; çıplak süreç başlatma yok.
- **WF-47, TP-43** — tzdata sabit, SQL'de `AT TIME ZONE` yok.
- **TN-61, T-62** — SBOM/imza/provenance, tedarik zinciri kapıları.
- **T-53** — NIF yalnız ölçüm kanıtıyla, izinli listede.
- **T-56, T-57 (6, 7)** — `boundary` bağımlılık yönü; güvenliği zayıflatan yapılandırma yok.
- **T-58** — kod kalitesi kapıları, hata ≠ karar.
- **T-61** — test katmanları, kural kapsamı, PR ≤ 10 dk.

---

### Aşama 1 — Veri ve kiracılık temeli

PostgreSQL şeması, kiracı/alt kiracı/ortam modeli, `tenant_id` + bileşik FK + FORCE RLS, DB rolleri ve yazma fonksiyonları, append-only defter iskeleti, outbox, idempotency deposu, saklama sınıfları ve crypto-shredding, sır deposu, denetim kaydı ve Merkle kontrol noktası, Valkey bağlantısı, Oban OSS ve Valkey bildiricisi, saat/rastgelelik portu kurulur. A0'a dayanır.

#### Spec dışı ön koşullar
- [ ] **Çekirdek tablo ve yazma fonksiyonu sözleşmesi (SQL şeması)** — OP-8 fonksiyon imzalarını "API sözleşmesinin veritabanı yüzü" sayıyor ama imza/sonuç kodu listesi yalnız örnek; feature kodundan önce yazılıp onaylanmalı. (Adem kararı)
- [ ] **Sürümlü veri tablosu mekanizması** — §12/§13/§14 onlarca tabloyu "deploy gerektirmeyen, denetimli sürümlü veri" sayar (CH-18, PC-40, PC-44, PC-54, PC-31); depolama, sürüm etkinleştirme, teslimin hangi sürüme çivilendiği ve doğrulama mekanizması hiçbir bölümde tanımlı değil. (Adem kararı)
- [ ] **Access denetim kaydı biçimi ve test vektörleri** — TN-46/OP-63 kodlama, alan adları ve kontrol noktası biçiminin Access OP-37/OP-38 ile aynı olmasını ister; Relay spec'inde biçim yok, Access'ten test vektörleriyle içe alınmalı.
- [ ] **Denetim kontrol noktası aralığı değeri** — OP-63 aralığın Access OP-38 beyanıyla aynı olacağını söyler; değer Access tarafında kesinleşmeli (PD). (Adem kararı)
- [ ] **Partition aralıkları ve ön oluşturma ufku başlangıç değerleri** — OP-13 tablo başına veri diyor ve "hacim ölçüldükten sonra kesinleşir"; ilk göçler için başlangıç değeri yok. (Adem kararı)
- [ ] **PD değerleri** — TN-10 hukuki süreler (hukuk onayı), TN-24 rotasyon çakışma süresi, TN-60 `traffic` saklama süreleri (F-28) değersiz. (Adem kararı)

#### Zorunlu bileşenler ve şema kuralları
- [ ] **Zorunlu bileşenler: PostgreSQL 18 + Valkey** — Yalnız PG ve Valkey zorunlu; NATS/Kafka, analitik DB ve S3 isteğe bağlı adaptör; PG ≥ 18, beta ana sürüm dağıtılmaz; Valkey referans, Redis uyumlu, Dragonfly test edilmez. _Kaynak:_ §19.3; T-7, T-8.
- [ ] **Kimlik, tip ve şema kuralları** — uuidv7 + `created_at` sıralama; `tenant_id` + `environment` PK öneki; yalnız `timestamptz`/UTC, `AT TIME ZONE` yasağı; `bigint` mikro para + ISO; `ENUM` yok; E.164 `CHECK` (`+900…` red); normalize e-posta, `citext` yok; `bigint` sayaç; `jsonb` kuralı, `json` yok; yük boyutu sert `CHECK`. _Kaynak:_ §20.1; OP-1.
- [ ] **Opak, önekli, tipli kimlikler** — `evt_`, `ntf_`, `dlv_`, `rcp_`, `sub_`, `wfl_`, `tpl_`, `wp_` vb. türe göre önekli UUIDv7 kimlikler; önek kod içinde doğrulanır; önek tablosu (anahtar önekleri dahil) tek yerde, OpenAPI ekinde. _Kaynak:_ §9.3, §19.13.3; API-9, T-58 (madde 6), T-60 (madde 7).
- [ ] **Veri katmanı kod kuralları** — Ecto şeması yalnız eşleme; Repo/SQL yalnız `*.Store`; kritik sorgu planları testle sabit; `CHECK`'li text durum, sınırlı JSONB, `timestamptz` UTC, SQL'de saat dilimi dönüşümü yok. _Kaynak:_ §19.13.5; T-60 (madde 1, 7).
- [ ] **Göç kuralları ve sıfır kesintili şema değişikliği** — Zaman damgalı, commitlenince değişmez göçler; expand/contract; oturum `lock_timeout` 3 sn + retry, `NOT VALID` + `VALIDATE`, ayrı dosyada `CONCURRENTLY` indeks, beş adımlı tip değişikliği; CI kilitleyen indeksi, varsayılanlı sütun eklemeyi, tablo yeniden yazmayı, tek adım yeniden adlandırmayı ve geçersiz indeksi reddeder; gecelik üretim şeklinde veriyle göç tekrarı. _Kaynak:_ §19.13.5, §20.9.4; T-60 (madde 4), OP-57.
- [ ] **Gerçek veritabanıyla test altyapısı** — Gerçek PG 18 + Valkey (Ecto SQL sandbox, testcontainers); taklit DB yok; üretim verisi geliştirme/testte yok. _Kaynak:_ §19.13.5; T-60 (madde 6).
- [ ] **Saat ve rastgelelik portu, yalnız UTC** — `Relay.Clock` ve enjekte üreteç; `DateTime.utc_now/0` ve `:rand` doğrudan çağrısı Credo ile yasak; DB yalnız UTC, yerel saat yalnız uygulamada tek, sürümü izlenen tzdata ile; hız limiti/sayaç kararında düğüm duvar saati kullanılmaz. _Kaynak:_ §5.6, §6.9, §19.13.2; INV-50, C-57, T-57 (madde 3).

#### Kiracı, alt kiracı ve ortam
- [ ] **Kiracı nesnesi ve durumu** — Kiracı en üst yalıtım birimi; veri, sağlayıcı hesabı, API anahtarı, kota, kill switch kapsamı ve denetim kaydının sahibi; kiracı, operatör ve API anahtarı Relay'de tanımlanır, Access olmadan tam çalışır; durum `active | suspended | closed`, gönderici kimliği ayrıca askıya alınabilir; kiracı özellikleri ücretsiz çekirdekte. _Kaynak:_ §1.7, §2.2, §5.2, §18.1.1; MD-18, C-11, F-9, MKT-10, TN-1, TN-10.
- [ ] **Kiracı kurulum zorunlu alanları** — `region` (değişmez; değişiklik = yeni kiracı + dışa/içe aktarma), `default_timezone` (IANA kimliği, ofset değil), `default_locale` (BCP 47) zorunlu; sistem varsayılanı yok; tz/locale değişikliği denetim kaydıyla. _Kaynak:_ §10.10, §11.6, §18.1.1; TN-2, WF-45, WF-47, TP-25.
- [ ] **Kiracı bölgesi ve veri yerleşimi** — Kiracı bölgeyi (`tr`/`eu`/`us`) kayıtta seçer; veri orada kalır; bölgeler arası veri akışı yolu yok. _Kaynak:_ §1.7, §5.2; MD-10, C-10, INV-41, F-11.
- [ ] **Tek seviyeli alt kiracı nesnesi** — Birinci sınıf, tek seviyeli (alt kiracının alt kiracısı yok), ücretsiz çekirdekte; ayrı yalıtım birimi değil, veri `tenant_id` altında `subtenant_id` ile; marka, gönderici/kanal kimliği, sağlayıcı bağlantısı, tercih varsayılanı, inbox kapsamı taşır; kiracı operatörleri alt kiracıları görür. _Kaynak:_ §1.7, §5.2, §18.1.2; MD-18, C-12, TN-3.
- [ ] **Ayar mirası çözücüsü** — "Yoksa üsttekini kullan, varsa ezme"; tek çözüm sırası alt kiracı → kiracı; kiracı değişikliği alt kiracı ayarını ezmez (marka/layout da bu çözücüyü kullanır). _Kaynak:_ §5.2, §18.1.2; C-12, TN-4.
- [ ] **`live`/`test` ayrı veri düzlemleri** — Kiracı başına iki ayrı veri düzlemi; `environment` her tabloda `tenant_id` ile kapsam sütunu; ortam API anahtarına bağlı, gövdeyle değişmez; test ↔ canlı erişimi yapısal olarak imkânsız. _Kaynak:_ §1.7, §5.2, §8.9, §18.1.3; MD-18, C-13, X-24, TN-7, TN-12.

#### Yalıtım: kapsam, FK ve RLS
- [ ] **Pool yalıtım modeli** — Tek şema, her satırda kiracı ayırıcı, RLS ikinci hat; kiracı başına şema/DB yok; ayrı altyapı isteyen = aynı paketin ayrı kurulumu. _Kaynak:_ §18.2; TN-11.
- [ ] **Kapsam sütunları, bileşik anahtar ve FK** — Her kiracı tablosunda `tenant_id NOT NULL`, `environment NOT NULL` PK öneki; her UNIQUE kapsamla bileşik, global UNIQUE yok; referans tablolarda `UNIQUE (tenant_id, environment, id)` ve bileşik FK; kiracılar arası bağ ve yetim satır yapısal olarak imkânsız. _Kaynak:_ §6.7, §18.2; INV-37, TN-12.
- [ ] **FK'siz tablo istisna listesi** — FK'nin bilerek kurulmadığı tablolar (ölçümle gerekçeli) şema güvenlik testlerinde açıkça listelenir ve yetim kayıt denetimine girer. _Kaynak:_ §18.2; TN-12.
- [ ] **FORCE RLS politikaları ve transaction-yerel kiracı bağlamı** — Her kiracı tablosunda `ENABLE` + `FORCE ROW LEVEL SECURITY`, `USING` + `WITH CHECK`, bağlam `(select current_setting('relay.tenant_id'))`, `missing_ok` yok; bağlam yalnız `set_config(..., true)` ile transaction içinde, oturum `SET` yasak; veri erişim katmanı bağlamsız sorguyu hatayla durdurur, bağlam her iş/süreç/görev sınırında yeniden kurulur. _Kaynak:_ §6.7, §18.2; INV-36, TN-13.
- [ ] **Uygulama rolü açılış doğrulaması** — Uygulama rolü superuser, `BYPASSRLS`, tablo sahibi ya da `DELETE`/`TRUNCATE` yetkili ise düğüm başlamaz. _Kaynak:_ §6.7, §18.2; INV-36, TN-14, TN-16.
- [ ] **Kiracılar arası bakım kaçış kapısı** — Partition bakımı, arşiv gibi kiracılar arası görevler ayrı rolle ve kodda gerekçeli, grep'lenebilir kaçış kapısıyla çalışır. _Kaynak:_ §18.2; TN-13.
- [ ] **Şema güvenlik testleri (CI)** — Her tabloda `tenant_id` önekli PK, RLS FORCE, bileşik FK `(tenant_id, id)`, append-only tablolarda UPDATE/DELETE engeli ve uygulama rolü yetki listesi otomatik doğrulanır. _Kaynak:_ §19.13.5; T-60 (madde 3, 5).
- [ ] **Yalıtım kural testleri (veri katmanı)** — Özellik tabanlı test (A'nın sorgusu B satırı döndürmez), test ortamında veri erişim çıktısı kapsam denetimi, RLS açıklık testi (`relrowsecurity`/`relforcerowsecurity`); her PR'da. _Kaynak:_ §18.2; TN-16.
- [ ] **Gece yetim kayıt ve bileşik FK denetimi** — `tenant_id IS NULL` yok, yetim yok, FK yerinde; partition ufku her bakım çalışmasında kontrol edilir. _Kaynak:_ §20.7; OP-42 (yetim/FK ve partition ufku satırları).

#### Roller, yazma fonksiyonları ve silmesiz model
- [ ] **Veritabanı rolleri ve fiziksel silmesiz model** — `relay_migrator`, `relay_app` (BYPASSRLS yok), `relay_queue`, `relay_archive`, `relay_report`; kayıt tablolarında hiçbir rolde `DELETE`/`TRUNCATE`/`DROP`; silme = durum + `deleted_at` + tombstone, kullanıcı yalnız arşivler/gizler. _Kaynak:_ §1.7, §6.9, §20.2; MD-9, INV-47, F-11, OP-9.
- [ ] **İş kuyruğu tablosu temizlik istisnası** — Kuyruk satırı yalnız kimlik/işletim durumu taşır; sonucu kalıcı kayda yazılmış iş satırı yalnız `relay_queue` ile temizlenir; kayıt tablolarına istisna yok; uyum kanıtı kuyrukta tutulmaz. _Kaynak:_ §1.7, §6.9, §20.2; MD-9, INV-47, OP-12, T-15 (madde 7).
- [ ] **Çekirdek yazma fonksiyonları (SECURITY DEFINER)** — Uygulama rolünün çekirdek tablolarda doğrudan DML'i yok; kabul, plan sabitleme, teslim/deneme açma, olay alma, bastırma, inbox işaretleme, bekleme çözme fonksiyonları; sabit `search_path`, kapsam doğrulama, sonuç kodları; imzalar şema testiyle korunur. _Kaynak:_ §20.2; OP-8, T-60 (madde 2).
- [ ] **Kritik yazmalarda senkron commit** — İzin, tercih, bastırma, denetim kaydı ve kill switch yazmaları senkron commit; defter toplu alımında gevşetme yalnız ölçümle. _Kaynak:_ §20.2; OP-10.
- [ ] **Rol başına sorgu ve işlem süre sınırları** — `statement_timeout` rol başına (API 5 sn, işçi 30 sn, rapor 5 dk ⚠️), global ayar yok; `idle_in_transaction_session_timeout`, `transaction_timeout`; sorgu istatistikleri; sık sorgu planı CI'da. _Kaynak:_ §20.2; OP-11.

#### Çekirdek kayıt şeması ve tekillik
- [ ] **Bildirim → teslim → deneme → defter olayı çekirdek şeması** — `notifications` (alıcı başına iş olayı, kanal sayısından bağımsız, partition'sız), `deliveries` (kanal × hedef niyeti; fallback `fallback_of` ile yeni teslim; engellenen hedef de teslim açar; aynı bildirim × kanal × hedefte tek canlı teslim DB kısıtıyla), `delivery_attempts` (tek dış istek; `pending`/`in_flight`/`succeeded`/`failed`/`unknown`, terminal durum ezilmez; retry aynı teslimde yeni deneme), `delivery_events`, `webhook_receipts`; düzeyler hiçbir kayıtta birleşmez. _Kaynak:_ §5.1, §5.4, §10.1, §14.1.1, §20.1; C-3, C-29, C-30, C-31, WF-1, DS-1, OP-2.
- [ ] **Append-only teslim defteri iskeleti** — `delivery_events` satırı (kim, ne: normalleştirilmiş + ham kod, `occurred_at`, `received_at`) yalnız eklenir, DB rol/izin düzeyinde güncellenemez/silinemez; teslim durumları defterden türetilen projeksiyondur. _Kaynak:_ §5.1, §5.4, §6.2, §14.1.2, §20.1; C-2, C-32, INV-6, DS-2, OP-3.
- [ ] **Kesin tekillik DB kısıtları** — `(tenant_id, environment, dedup_key)` (bildirim saklandığı sürece, kanal içermez), defter anahtarı `(notification_id, recipient, channel)`, giden teslim `(endpoint_id, event_id)`, sağlayıcı olay makbuzu `(tenant, provider, provider_event_id)`, digest ve bekleme tekillik indeksleri `UNIQUE`; zamana/bölüme bağlı değil; Oban unique yalnız ön filtre; teslim yolunda Bloom/HLL yok. _Kaynak:_ §1.7, §4.3.1, §5.10, §6.3, §9.4, §19.5; INV-12, MD-7, MD-20, C-80, C-82, L-41, API-16, T-16, OP-6 (madde 3).
- [ ] **Commit sırasına dayalı sıra numarası ve okuyucu cursor'u** — Akış başına monoton `seq` commit sırasına dayanır (ID sırasına değil); inbox, posta kutusu, olay akışı ve outbox okuyucuları `id > son_id` değil durum + `SKIP LOCKED` ya da xid8 su çizgisiyle okur; A2'deki posta kutusu kaydı ve akış modeli bu altyapı üzerine kurulur. _Kaynak:_ §1.7, §4.3.1, §5.8, §20.1; MD-15, L-42, C-71, OP-5.
- [ ] **Kullanım kaydı** — Faturalama/kota için değişmez kullanım satırı; faturalama metrikten yapılmaz; test gönderimleri ayrı satır. _Kaynak:_ §5.12; C-88, INV-49.
- [ ] **Sürümlü veri tabloları deposu** — Hata eşleme, backoff, devre kesici, fiyat, limit, yetenek bayrağı, öncelik eşleme, toplu gönderici kuralları gibi tablolar kod değil sürümlü veridir; değişiklik deploy gerektirmez ve denetim kaydına girer. _Kaynak:_ §12 kuralları, §12.3.5; CH-18.

#### Outbox, idempotency ve transaction sınırları
- [ ] **Tek transaction: kayıt + iş + outbox** — `202` ile kabul edilen istek kaydı, kuyruk satırı ve outbox olayı aynı `Ecto.Multi`'de kalıcı; outbox'sız "yaz + yayınla" yolu yok; kalıcı yazılamazsa `503`. _Kaynak:_ §1.7, §6.1, §19.13.2; INV-2, MD-7, T-57 (madde 4).
- [ ] **Dayanıklı idempotency deposu (PostgreSQL)** — Kapsam `(tenant, environment, endpoint, key)`; "ilk giren kazanır" tek atomik `ON CONFLICT DO NOTHING`; anahtar 8–255 (DB'de de); ömür 24 saat sabit sunucu politikası; gövde özeti ve ilk yanıt saklanır; Valkey'de tutulmaz; süresi dolan kayıt silinmez, partition arşiviyle çıkar; kaybı çift gönderimdir. _Kaynak:_ §1.7, §5.10, §6.3, §9.4, §20.1; MD-20, C-79, INV-11, API-11, API-15, OP-6 (madde 1).
- [ ] **Transaction sınırı ve iş kuralları** — Hiçbir ağ çağrısı DB transaction'ı içinde yapılmaz; iş argümanı yalnız kimlik; insert yalnız ilgili kaydın transaction'ında; hiçbir iş 1 saati aşmaz, uzun bekleme satır + zamanlayıcı; Lifeline eşiği iş süresinin üstünde. _Kaynak:_ §6.10, §19.5; INV-55, T-15 (madde 1–4, 6, 7).

#### Saklama, şifreleme ve sırlar
- [ ] **Sır deposu portu ve referans modeli** — Arka uçlar bulut KMS, OpenBao, SoftHSM, `age` dosyası; DB'de yalnız `secret_ref` + sürüm; API anahtarı, imza sırrı, sağlayıcı kimliği, cihaz jetonu oluşturmadan sonra açık okunmaz (yalnız parmak izi); düz sır DB/iş argümanı/log/trace'e yazılmaz, çözülmüş sır ETS/`persistent_term`'de tutulmaz. _Kaynak:_ §5.2, §5.3, §6.9, §18.4.1; INV-51, C-16, C-26, TN-26.
- [ ] **Yapılandırma yükleyicisi sır kuralı** — Self-host bağlantıları dosya/ortam değişkeniyle, sırlar yalnız referansla (`${VAR}`/sır referansı); URI içinde parola görülürse başlama reddedilir. _Kaynak:_ §18.4.1; TN-26.
- [ ] **Zarf şifreleme** — Bölge KEK'i kiracı veri anahtarlarını sarar; sırlar kiracı veri anahtarıyla şifreli; çözülmüş veri anahtarı süreli bellek önbelleğinde (PD 5–15 dk); KMS çağrısı sır başına. _Kaynak:_ §18.4.1; TN-27.
- [ ] **Kriptografi kuralları** — Primitifler OpenSSL tabanlı `:crypto`'dan, one-shot API tercihli, kendi primitif yok; sır/imza karşılaştırmaları sabit zamanlı; imza doğrulaması ham bayt üzerinde; imzalanan/özeti alınan yapılar kanonik serileştirmeli. _Kaynak:_ §18.10; TN-35.
- [ ] **Saklama sınıfları ve Access Ek C eşlemesi** — Relay sınıfları (`recipient_profile`, `notification_content`, `delivery_records`, `commercial_consent_records`, `preferences`, denetim, `traffic`, bastırma) Access Ek C sınıflarına eşlenir, süre ve dayanak bölge × sektör tablosundan; `traffic` (IP, port, zaman) ayrı sınıf, süreleri PD, azami süreli satırlarda süreden uzun saklama yok. _Kaynak:_ §1.7, §5.12, §18.9, §20.4; MD-9, C-85, TN-60, OP-18.
- [ ] **Özne × sınıf DEK ve crypto-shredding** — Kişisel alanlar (adres, profil, içerik) özne × saklama sınıfı DEK'iyle AES-256-GCM şifreli; silme talebi ve saklama sonu DEK'in bütün kopyalarının imhası + yumuşak silme, şifreli artık arşivde kalır; yükümlülüksüz sınıfın DEK'i hemen imha, yükümlü sınıf normal işlemde kullanılamaz; dava/regülatör saklaması imhayı durdurur; kuyruk, zamanlanmış gönderim, digest tamponu ve inbox dahil; Access OP-73/OP-74 aynen. _Kaynak:_ §1.7, §5.12, §18.4.3, §20.4; MD-9, C-86, MKT-13, TN-33, OP-17, OP-18.
- [ ] **Kişisel alan şifrelemesi ve HMAC kör indeks** — Token/adres düz metin saklanmaz; eşitlik araması HMAC-SHA256 kör indeksle, anahtar DB dışında sır deposunda; anahtarsız özet kör indeks sayılmaz; rotasyon için iki sütunlu okuma yolu baştan. _Kaynak:_ §5.3, §18.4.3; C-22, TN-33, TN-35.
- [ ] **DB içi şifreleme fonksiyonu yasağı** — Disk şifrelemesi tek başına kontrol değildir; anahtarın SQL/log'a düştüğü DB içi şifreleme fonksiyonları kullanılmaz. _Kaynak:_ §18.4.3; TN-33.
- [ ] **Kişisel veri kopyaları kapsam listesi ve imha kapsamı testi** — Adres/token'ın bulunabileceği her yer sütun sütun, şifreleme ve imha kuralıyla listelenir; kuyruk/log/trace'te PII yok, DLQ ve analitikte kör indeks; `tenant_id` ya da kişisel alan taşıyan ve kiracı kapatma/özne silme listesinde olmayan tablo testi kırar. _Kaynak:_ §18.2, §20.4; TN-16, OP-25.
- [ ] **WATCH: tek kiracılı HSM** — Varsayılan bulut KMS; denetim ya da regülasyon tek kiracılı HSM isterse açılır. _Kaynak:_ §22.2; TN-34, OQ-31.

#### Partition ve saklama işletimi
- [ ] **Partition bakım görevi** — Uygulama içi tekil, DB liderlikli ön oluşturma; dış araç ve DEFAULT partition yok; "en ileri sınır < now + N gün" alarmı (PD N = 3); aralık ve ufuk tablo başına veri; UTC + açık ofset sınırlar. _Kaynak:_ §20.3; OP-13.
- [ ] **Kilitsiz partition DDL'i** — `LIKE … INCLUDING ALL` + `CHECK` + `ATTACH`; `ON ONLY` + eş zamanlı indeks + bağlama; yaprak başına depolama parametreleri; üst tablo günlük ANALYZE; kısa `lock_timeout`/`statement_timeout`, zaman aşımında erteleme; toplu içe aktarma `COPY` + bağlama. _Kaynak:_ §20.3; OP-14.
- [ ] **Kiracı bazlı saklama: yumuşak silme + crypto-shred** — Partition en uzun saklamaya göre tutulur; kısa saklamalı kiracının satırları yumuşak silinir, DEK imha edilir; kiracı × zaman iki seviyeli partition yok. _Kaynak:_ §20.3; OP-16.

#### Denetim kaydı
- [ ] **Denetim kaydı ve Merkle kontrol noktası** — Operatör/yönetici eylemleri düz append-only tabloda, kayıt başına hash zinciri yok; tekil arka plan işi yeni kayıtları Merkle ağacına bağlar, kökü KMS ile imzalar (ekleme imza beklemez) ve en az bir Relay'den bağımsız hedefe yayımlar; aralık beyan edilir ve Access OP-38 ile aynı, aşım sayfalar; yayımlanmış kökler periyodik karşılaştırılır, uyuşmazlık güvenlik olayı; tek kayıt için kapsama kanıtı; biçim Access OP-37/OP-38 ile aynı, iki ürün tek doğrulayıcıyla kontrol edilir. _Kaynak:_ §1.7, §5.12, §6.9, §7.3.9, §18.6, §20.7; MD-19, C-87, C-14, INV-49, E-31, TN-46, OP-63, OP-42 (kontrol noktası satırı).
- [ ] **Denetim tablosu yazma/okuma kısıtı** — Uygulama rolü yalnız yazma fonksiyonuyla ekler, `UPDATE`/`DELETE`/`TRUNCATE` yok; denetim kaydını okumak sorgu başına bir denetim olayıdır; eylemi yapanın/operatörün kimliği ("kimin adına") zorunlu. _Kaynak:_ §18.6; TN-50.
- [ ] **Denetim kaydı saklaması** — Varsayılan 400 gün, sektör şablonu uzatır (Access OP-74, Ek C); fiziksel silme yok (Access OP-73). _Kaynak:_ §18.6, §20.4; TN-49, OP-21.

#### Valkey, sinyal ve tekil sorumluluk
- [ ] **Valkey bağlantısı ve sinyal modeli** — Valkey asıl kayıt tutmaz; yalnız pub/sub sinyali ("yeni var" + seq; veri PG'den), sayaç ve kısa ömürlü kayıt; `noeviction`, önbellek ayrı; LISTEN/NOTIFY yok; sinyal kaybı yalnız gecikme, Postgres cursor'uyla telafi; Valkey yoksa kısa aralıklı yoklama. _Kaynak:_ §1.7, §6.10, §19.3; MD-6, INV-52, F-11, T-9 (madde 1, 2, 6, 7), T-10.
- [ ] **Kiracı kapsamlı Valkey anahtarları ve önbellekler** — Her Valkey anahtarı kiracı + ortam önekli ve TTL'li; düğüm içi önbellekler kiracı + ortam anahtarlı; kiracı verisinden atom/süreç adı üretilmez. _Kaynak:_ §18.2; TN-17.
- [ ] **Yayın commit'i izler** — Realtime ve giden yayın commit'ten sonra çıkar; commit olan her değişikliğin yayını er geç çıkar; yayın yazma yolunu bloklamaz. _Kaynak:_ §6.10; INV-53.
- [ ] **DB tabanlı liderlik ve tekil görevler** — Zamanlayıcı lideri, partition bakımı, DRR dağıtıcısı, mutabakat tetikleyicisi advisory lock/Oban peer ile, durum DB'de (BEAM kayıt defterine bağlanmaz); liderlik tablosu bütünlük testi; lidersiz kalma alarmı; Erlang distribution isteğe bağlı, açılırsa yalnız TLS + sertifika kimliği. _Kaynak:_ §1.7, §4.3.1, §19.3; MD-6, L-54, T-12.

#### İş kuyruğu (Oban OSS)
- [ ] **Oban OSS kurulumu** — Yalnız Apache-2.0 Oban (Pro yok); işlemsel insert, retry/snooze/cancel, ileri tarih/cron, kuyruk ayrımı, duraklatma, `suspended`, `discarded`, öncelik, Lifeline, peer, telemetri; belgelerde ticari eklenti atfı yok. _Kaynak:_ §1.7, §19.5; MD-7, T-14.
- [ ] **Oban işletim kuralları** — Oban tabloları ayrı şemada; göç sürümü sabit, kuyruk şeması göçü uygulamadan önce; bildirici koptuğunda yoklama + alarm; Oban Web + oban_met, panel sayım sorgusu yükü izlenir ve sınırlanır. _Kaynak:_ §19.5; T-17, OP-40 (panel sayım yükü), OP-57 (madde 6).
- [ ] **Relay Valkey kuyruk bildiricisi** — Oban notifier arayüzünü uygulayan kendi Apache-2.0 bileşeni; Valkey yoksa yoklama; LISTEN/NOTIFY ve `:pg` bildiricisi yok; kesinti ve yeniden bağlanma kural testleri. _Kaynak:_ §19.5; T-55.

#### Bu aşamada doğrulanacak sınırlar
- **INV-2, T-57 (4)** — kabul, iş ve outbox aynı transaction'da; outbox'sız yayın yok.
- **INV-6, DS-2, OP-3** — teslim defteri append-only, güncellenemez/silinemez.
- **INV-11, API-11, API-15, OP-6 (1)** — idempotency deposu kapsamı, atomik ilk-giren, 8–255 anahtar, 24 saat.
- **INV-12, API-16, T-16, OP-6 (3)** — kesin tekillik yalnız DB `UNIQUE` kısıtlarında.
- **DS-1, WF-1, OP-2** — dört düzeyli şema; kanal başına tek canlı teslim kısıtı.
- **INV-36, INV-37, TN-11, TN-12, TN-13, TN-14, TN-16 (#2, #3, #4, #5, #7)** — FORCE RLS, bileşik FK, transaction-yerel bağlam, rol açılış doğrulaması, yalıtım ve imha kapsamı testleri.
- **TN-17** — Valkey anahtarları ve önbellekler kiracı + ortam kapsamlı.
- **INV-41** — bölgeler arası veri akışı yolu yok.
- **INV-47, OP-9, OP-12** — fiziksel silme yok; yalnız iki listeli istisna.
- **INV-49, E-31, TN-46, TN-49, TN-50, OP-63** — denetim kaydı append-only, Merkle kontrol noktası Access biçiminde, 400 gün, okuma da denetlenir.
- **INV-50, T-57 (3), WF-45, TP-25** — DB yalnız UTC, saat/rastgelelik portu, zorunlu IANA tz ve locale.
- **INV-51, TN-26, TN-27, TN-35 (kurallar 1–4)** — sır yalnız referans; zarf şifreleme; kriptografi kuralları.
- **TN-33, OP-16, OP-17, OP-18, OP-25** — crypto-shredding, kör indeks, kişisel veri kopyaları kapsamı.
- **INV-52, INV-53, T-9 (1, 6, 7), T-10, T-55** — Valkey asıl kayıt değil; yayın commit'i izler; LISTEN/NOTIFY yok.
- **INV-55, T-15** — transaction içinde ağ çağrısı yok; iş ≤ 1 saat.
- **TN-2, TN-3, TN-4, TN-7, X-24** — kurulum zorunlu alanları, tek seviyeli alt kiracı, miras çözücü, `live`/`test` yapısal ayrımı.
- **CH-18** — kanal/uyum tabloları sürümlü veri, deploy gerektirmez.
- **T-12, T-17** — DB tabanlı liderlik; Oban işletim kuralları.
- **T-60, OP-1, OP-5, OP-8, OP-10, OP-13, OP-14, OP-57** — şema/tip kuralları, commit sıralı cursor, yazma fonksiyonları, senkron commit, partition bakımı ve kilitsiz DDL, sıfır kesintili göç.

---

### Aşama 2 — Platform bileşenleri

Relay'in kendi akış kontrolü bileşenleri kurulur: GCRA hız limiti (Valkey + PG yedek), DRR kiracı adaleti, küme geneli eşzamanlılık, dört şerit ve yük atma, devre kesici, retry/backoff ve DLQ, kill switch, fan-out/batch takibi, sanal saat, ortak kalıcı kayıt (posta kutusu) çekirdeği ve bekleme noktası çekirdeği. A0 ve A1'e (şema, roller, commit sıralı `seq`, Valkey, Oban, saat portu) dayanır; inbox (A9) ve ajan yüzü (A12) bu çekirdeklerin üzerine kurulur.

#### Spec dışı ön koşullar
- [ ] **Kanal tablosu şeması ve başlangıç verisi** — T-25, T-26, T-27, T-33 parametreleri "kanal tablosunda veri"; tablo şeması ve kanal/şerit başına başlangıç satırları tanımlı değil (A1 sürümlü veri tablosu mekanizmasına bağlı). (Adem kararı)
- [ ] **Kill switch resume ile politika kafesinin bağı** — TN-40 resume'da her mesaj kafesten (tercih, İYS, sessiz saat, frekans, kota) geçer; kafes A4/A11'de. A2'de resume'un hangi kontrollerle çalışacağı (ör. kafes gelene kadar resume'u kapalı tutmak) belirlenmeli. (Adem kararı)
- [ ] **Kill switch yetki modeli** — TN-41/TN-22 kapsam yetkisi ve step-up A3'teki RBAC/step-up'a dayanır; A2'de hangi geçici yetki modeliyle çalışacağı belirlenmeli. (Adem kararı)
- [ ] **Ajan olmayan bekleyenin posta kutusu** — `waiter` API anahtarı sahibi olabilir ve `deliver_to` varsayılanı "bekleyenin posta kutusu"dur (§17.4.1), ama posta kutusu yalnız ajan alıcısı için tanımlı (§17.2, §17.6); API anahtarı sahibinin kutusu ve erken yanıt tamponunun yeri tanımsız. Bekleme noktası çekirdeği ve A12'yi etkiler. (Adem kararı)
- [ ] **Fan-out ve yük atma eşiklerinin ölçüm planı** — T-23 dilim/eşik sayıları ve T-34 şerit parametreleri ⚠️ ölçülmemiş; yük testi altyapısı (A15) gelmeden başlangıç değerleriyle çalışılır, ölçüm planı gerekir. (Adem kararı)

#### Ortak ilkeler ve zaman
- [ ] **Relay'in kendi akış kontrolü bileşenleri (erken, ayrı bütçeli)** — Hız limiti, DRR, global eşzamanlılık, batch/fan-out takibi, bekleme tablosu, devre kesici, retry/DLQ ve Valkey bildiricisi Apache-2.0 kendi kodumuz ve kural testli; limitleyici testleri bilinen hatalardan (kesirli dolum, başlatma yarışı, `retry-after`, CAS yarışı) türetilir. _Kaynak:_ §19.6; T-18, T-54 (madde 2).
- [ ] **Tek saat otoritesi** — Limit, kota ve süre kararlarında zaman karar veren arka ucun saatinden (Valkey `TIME`, PG `clock_timestamp()`); `tat = max(saklanan, now)`; süre ölçümleri monotonik. _Kaynak:_ §19.3; T-11.
- [ ] **Deterministik jitter** — Zamanlama yayılımı, sessiz saat serbest bırakma, tekrar tetikleme ve retry jitter'ı `phash2` sınıfı özetle alıcı/zaman/deneme kimliğinden; `rand` yok. _Kaynak:_ §19.6.6; T-30.
- [ ] **Sanal saat yalnız `test` düzleminde** — Zamanı ileri saran sanal saat (eskalasyon, bekleme noktası, digest, throttle, tekrar kuralı, süre dolumu testleri için) yalnız `test` düzleminde vardır; canlı düzlemde hiçbir koşulda bulunmaz, canlı anahtarla görünmez, saat her zaman gerçektir. _Kaynak:_ §2.2, §5.2, §8.9, §8.13, §18.1.3; F-10, C-13, X-27, TN-8.

#### Hız limiti
- [ ] **Hız limiti algoritma matrisi** — GCRA varsayılan; uzun kaba kotalarda sabit pencere; orta pencerede kayan sayaç `L_eff = 0,90·L`; küçük `L` alıcı kapaklarında kayan kayıt; kanal sayım birimleri (alıcı, segment, benzersiz alıcı, mesaj); anahtara göre pencere ofseti. _Kaynak:_ §19.6.1; T-19.
- [ ] **GCRA küme geneli hız limiti: Valkey birincil, PG yedek** — Tek atomik Valkey betiği; PG'de tek `INSERT … ON CONFLICT DO UPDATE … RETURNING` kilitsiz GCRA (boş RETURNING = red); sayaç okunamazsa otomatik yedeğe düşme, asla "limitsiz"; `Retry-After`'a uyum + %20'ye kadar jitter; Relay limiti sağlayıcınınkinden katı; anahtar kanal × hesap × kiracı × hedef, global anahtarsız limitleyici yok. _Kaynak:_ §1.7, §6.8, §12.3.4, §19.6.1; MD-6, MD-7, INV-44, F-11, CH-17, T-20 (madde 1–4, 6).
- [ ] **Valkey yedek davranışı ve çift arka uç test seti** — Valkey erişilemezse sinyaller kısa yoklamaya, limit/sayaçlar PG yedeğine geçer; geçiş penceresinde iki sayaç birlikte, katı olan uygulanır; tek test seti iki arka uçta aynı kararı üretir, bilinen hata listesinden (başlatma yarışı, kesirli refill, sabit retry-after, CAS yarışı) türetilir; Valkey kaybı veri kaybı değil. _Kaynak:_ §1.7, §4.3.1, §19.3; MD-6, MD-7, L-55, T-9 (madde 3–5), OP-29.
- [ ] **Kredi bloğu kiralama** — Burst dostu kanallarda düğümler merkezden kredi kiralar (global aşım ≤ (N−1)·k); SMS gibi katı saniye limitli kanallarda kiralama yok. _Kaynak:_ §19.6.1; T-20 (madde 5).

#### Şeritler, adalet ve eşzamanlılık
- [ ] **Dört öncelik şeridi, yalnız sınıftan** — L0 `security`, L1 `transactional`+`action_required`, L2 `operational`+`system`+`social`, L3 `marketing`; şerit yalnız mesaj sınıfından türer, hiçbir istek alanı başka şeride taşıyamaz; kampanya hacmi OTP şeridine dokunamaz; `priority` yalnız şerit içi. _Kaynak:_ §1.7, §5.4, §6.4, §6.5, §19.7; MD-8, C-36, INV-16, INV-24, T-31.
- [ ] **Fiziksel şerit ayrımı ve kuyruk topolojisi** — Şerit × kanal ayrı kuyruk ve eşzamanlılık bütçesi, kiracı başına kuyruk yok (kiracı adaleti kuyruk içinde DRR ile); kritik/toplu ayrı HTTP istemci ve havuzları; OLTP ve toplu yazma için ayrı DB havuzları; ölçekte ayrı düğüm havuzu; fan-out insert'leri küçük parçalar. _Kaynak:_ §18.7, §19.7; TN-51, T-32.
- [ ] **Şerit içi öncelik haritası** — 0–9 haritası (ilk deneme, retry, zamanlanmış, digest, kampanya dilimleri); DLQ oynatma ve bakım ayrı kuyruklarda. _Kaynak:_ §19.7; T-36.
- [ ] **DRR kiracı adaleti** — Toplu şeritlerde kiracı bekleme tablosu + tekil dağıtıcı, `ağırlık × kuantum` açık, kuantum ≥ en büyük iş birimi, boşalan açık sıfırlanır; ağırlıklar veri; iptal bekleme tablosunda `cancelled`; `security` şeridinde bekleme tablosu yok, OTP asla beklemez; öncelik yaşlandırma yok; yarış ve adalet kural testleri. _Kaynak:_ §1.7, §19.6.2; MD-7, T-21.
- [ ] **Küme geneli eşzamanlılık sınırları** — Kiracı × kanal, sağlayıcı hesabı ve kiracı başına uçuştaki teslim, eşzamanlı bekleme noktası ve kuyruktaki iş sayısı Valkey sayacıyla (PG yedekli) sınırlanır; düğüm başına sınır tek başına yok; aşımda snooze. _Kaynak:_ §1.7, §18.7, §19.6.2; MD-7, TN-54, T-22.
- [ ] **Kümülatif şerit tavanı** — Paylaşılan sağlayıcı limit anahtarında L3 %60, L2 %80, L1 %95, L0 %100 (PD); eşik üstü iş GCRA `retry_after` kadar snooze. _Kaynak:_ §19.7; T-33.

#### Aşırı yük ve yük atma
- [ ] **Kuyruk gecikmesiyle yük atma** — CoDel tetiği, şerit parametreleri PD (L0 500 ms/5 sn, L1 5 sn/30 sn, L2 60 sn/5 dk, L3 30 dk/30 dk ⚠️); sıra L3 (kampanya duraklat) → L2 (digest uzat/ertele) → L1 (son çare), L0/OTP asla düşürülmez; L0 TTL + FIFO; her karar `rule_id`'li. _Kaynak:_ §1.7, §6.5, §19.7; MD-8, INV-24, T-34.
- [ ] **Aşırı yükte sınıf duyarlı kabul kontrolü** — Aşırı yük `503` döner (429 değil); kabul kontrolü yalnız ertelenebilir sınıfları reddeder, `security` reddedilmez; OTP ve toplu gönderim ayrı kovalardadır. _Kaynak:_ §9.10; API-51.

#### Devre kesici, retry ve DLQ
- [ ] **İki seviyeli, kiracı yalıtımlı devre kesici** — Relay'in kendi modülü; `{tenant, provider}` (auth/sender_config) ve `{provider}` (taşıma/5xx/zaman aşımı) seviyeleri, bir kiracının arızası başka kiracıyı etkilemez; gerçek half-open (sınırlı eşzamanlı prob, ardışık başarı); kayan pencerede oran + asgari hacim, hata sınıfı ağırlığı, p99 gecikme eşiği; 4xx uygulama reddi açmaz; açık kalma süresine deterministik jitter, monotonik saat; PD parametreler (30 sn, 20, 0,5, 30 sn + %30, 3, 3) kanal tablosunda; sıcak yolda düğüm içi atomik sayaç. _Kaynak:_ §6.7, §12.3.3, §19.6.4; INV-40, CH-15, T-25 (madde 1–7, 9).
- [ ] **Üç katmanlı zaman aşımı ve `Retry-After`** — Mesaj `expires_at`, kanal ve sağlayıcı çağrı zaman aşımlarından önce dolan uygulanır; `Retry-After` her zaman uygulanır, yerel backoff kısaltamaz, üstüne deterministik `jitter(0, %20)` eklenir. _Kaynak:_ §12.2.3; CH-9.
- [ ] **Tek retry otoritesi ve tam jitter backoff** — Retry yalnız iş kuyruğu katmanında, HTTP istemcisi/adaptör retry'ı kapalı, her retry tekrar anahtarıyla; `sleep = random(0, min(cap, base·2^a))` deterministik jitter kaynağıyla; `base`/`cap`/`max_attempts` kanal tablosunda veri; toplam beklenen bekleme `expires_at − now`'u aşan deneme planlanmaz, süresi geçen `expired`; retry önceliği düşer. _Kaynak:_ §4.3.1, §6.3, §12.2.6, §19.6.5; INV-13, INV-14, L-43, CH-12, T-26.
- [ ] **Retry bütçesi** — Kanal başına kayan 60 sn'de retry/toplam > %10 (asgari taban korunarak) olunca yeni retry ertelenir ve `budget_denied` ile DLQ'ya gider (PD). _Kaynak:_ §19.6.5; T-27.
- [ ] **Sınıflandırılmış DLQ tablosu ve yeniden oynatma** — Kayıt tablosu, temizlenmez; kiracı, kanal, sağlayıcı, sınıf (`permanent|quality_alarm|exhausted|budget_denied`), kod, deneme, zamanlar, kör indeks; oynatma kuralları (geçersizleştiren asla, `quality_alarm` insan onayı, ömür kontrolü, ayrı hız sınırlı kuyruk, derinlik ≤ 1, türetilmiş yeni anahtar); devre kapanınca son 30 dk `exhausted` otomatik oynatma (PD). _Kaynak:_ §19.6.5; T-29.

#### Kill switch
- [ ] **Kill switch modeli** — Tek model, beş boyut: kapsam (`platform`/`tenant`/`subtenant`/`campaign`/`workflow`/`api_key`/`sender`) × kanal × hedef (sağlayıcı hesabı, şablon) × mesaj sınıfı × durum (`on`/`off`/`canary`/`paused_until`); her kayıt `reason`, `created_by`, `expires_at`, isteğe bağlı bilet; devre kesici/itibar/ajan tavanıyla aynı `PAUSED` + `rule_id` sonuç dili. _Kaynak:_ §5.7, §6.1, §6.9, §18.5.1; C-65, INV-3, INV-49, MD-14, TN-36.
- [ ] **Kill switch değerlendirme fonksiyonu** — En kısıtlayıcı kayıt kazanır (platform `off` iken kiracı `on` olamaz; `canary` × `paused_until` → duraklatma); saf fonksiyon, kendi test tablosuyla. _Kaynak:_ §18.5.1; TN-37.
- [ ] **Kill switch TTL ve gerekçe zorunluluğu** — `reason` boş olamaz (uygulama + DB kısıtı); TTL zorunlu, süresiz kayıt ayrı açık onay ister. _Kaynak:_ §18.5.2; TN-41.
- [ ] **`security` sınıfı varsayılan durdurulmaz** — "Bütün sınıflar" kapsamı `security`'yi içermez; `security`'yi durdurmak ayrı açık seçim ve ayrı onay. _Kaynak:_ §5.7, §18.5.2; C-65, TN-42.
- [ ] **Kill switch fail-safe** — Durum okunamıyorsa son bilinen durum; açılışta hiç durum yoksa düğüm gönderim yapmaz; kesinti switch'i kendiliğinden açmaz. _Kaynak:_ §6.8, §18.5.1; INV-43, TN-38.
- [ ] **Kill switch yayılımı** — Doğruluk Postgres'te; değişiklik Valkey pub/sub "yeniden yükle" sinyali; düğüm tam seti değişmez yapı olarak sabit zamanlı önbelleğe alır; Valkey yoksa kısa aralıklı yoklama; hedef < 2 sn (EA, oyun gününde ölçülür). _Kaynak:_ §18.5.1; TN-39.
- [ ] **Kill switch ve iptal ilk adım kontrolü; `PAUSED`** — Eşleşen kuyruklar duraklatılır; her işin ilk adımı kill switch ve iptal kontrolü; engellenen iş hata döndürmez, `PAUSED` olur, silinmez, otomatik yeniden denenmez; TTL dolması `PAUSED` işleri göndermez, `expires_at` dolan `expired`; iptal teslim kaydında işaretlenir, iş işlem yapmadan biter; her engelleme `rule_id` atlaması. _Kaynak:_ §18.5.2, §19.5; TN-40, TN-36, T-15 (madde 5).
- [ ] **Resume ve toplu iptal** — Resume açık operatör eylemidir ve her mesaj politika kafesinden (tercih, İYS, sessiz saat, frekans, kota) baştan geçer; `PAUSED` kümenin toplu iptali ayrı, açık, denetim kayıtlı eylem, her mesaj için `cancelled` + `rule_id`. _Kaynak:_ §5.7, §18.5.2; C-65, TN-40, TN-47.
- [ ] **Ölü adam anahtarı** — Kiracı/kampanya/workflow kapsamında gönderim hızı eşiği (PD: son 1 saat ortalamasının 10 katı) aşarsa kapsam otomatik `paused_until`, kiracı ve işletim kanalı uyarılır; `security` hariç; açma insan kararı. _Kaynak:_ §18.5.2; TN-43.

#### Fan-out ve batch
- [ ] **Fan-out dilimleme ve batch takibi** — Kendi kodumuz (Oban Pro yok); alıcı başına iş yok, liste belleğe tek seferde alınmaz; dilim 5.000 / alt-parti 200 ⚠️, hız kiracı kotasına bağlı; keyset aralığı, kontrol noktası, retry kaldığı yerden; ilerleme tablosu `pending|running|paused|completed|partial|cancelled`, `partial` kapanışta olay; iptal ucuz, her alt-partiden önce kontrol. _Kaynak:_ §1.7, §18.7, §19.6.3; MD-7, TN-54, T-23 (madde 1, 3, 4).

#### Ortak kalıcı kayıt (posta kutusu) çekirdeği
- [ ] **Ortak kalıcı kayıt çekirdeği** — Alıcı başına sıra numaralı kayıt + cursor + outbox; insan yüzü (inbox, A9) ve ajan yüzü (posta kutusu, A12) aynı yapı taşı; her değişiklik akışta sıra numaralı olay; push/webhook/A2A push yalnız ipucu, durum kayıtta; dört alıcı türü aynı motoru kullanır. _Kaynak:_ §1.7, §2.1, §2.4.1, §4.2, §5.8, §15.1.1; C-68, F-4, MD-15, L-18, L-20, INV-35, IN-1.
- [ ] **Akış modeli ve `since` cursor** — `(stream, epoch, seq)`; her posta kutusu/akış A1'deki commit sıralı `seq` altyapısını (C-71, OP-5) kullanır; teslim sırası değil okuma sırası garanti; alıcı boşluğu `since=seq` ile tamamlar, yeniden bağlanan kaldığı numaradan okur; `epoch` değişince tam senkron (`stream.resync_required`); replay üst sınırı. _Kaynak:_ §1.7, §4.2, §4.3.1, §5.8, §15.4.1, §17.7; L-19, L-43, MD-15, IN-22, AG-24.

#### Bekleme noktası çekirdeği
- [ ] **Bekleme noktası tablosu altyapısı** — Bekle adımı, digest penceresi, bekleme noktası ve ileri tarihli gönderim kalıcı satır + zamanlayıcıdır, kuyruk slotu/süreç/bellek tutmaz ve "hiçbir iş 1 saati aşmaz" kuralına uyar; son tarih ilk parkta kalıcı, sonsuz bekleme yok; toplam süre ve heartbeat iki zamanlayıcı; yükseltme/eskalasyon aynı mekanizma; değişmezler (yanıtlayan ≠ bekleyen, süresi geçmiş çözülemez, çözülmüş değişmez) DB kısıtı. _Kaynak:_ §1.7, §4.3.1, §5.1, §10.10, §17.1, §19.6.3; MD-3, MD-7, C-8, L-53, WF-43, T-24, AG-4.
- [ ] **Bekleme noktası kaydı ve oluşturma** — Nesne alanları `waiter`, `match`, `condition`, `response_schema`, `responders`, `expires_at`, `heartbeat_interval`, `escalation_policy`, `default_response`, `subject_digest`, `content`, `claim_text`, `deliver_to`, `tags`; durum açık/çözüldü/süresi doldu/iptal/sahipsiz; Idempotency-Key zorunlu; `expires_at` zorunlu, ≤ 30 gün, ilk kayıtta kalıcı, tekrar denemede korunur, örtük/sonsuz varsayılan yok; tek seferlik çözülür, listelenir, iptal edilir; yürütücüye özel değil. _Kaynak:_ §1.7, §4.2, §5.9, §17.4.1; C-72, MD-3, L-25, AG-9.
- [ ] **İki aşamalı korelasyon ve birinci aşama eşleme** — Önce `(kiracı, ortam, olay türü, korelasyon anahtarı)` tek indeksle birebir eşleşir (erken/sırasız olay dahil), sonra isteğe bağlı ek koşul (koşul dili ve workflow "olay bekle" adımı A8'de); joker/önek/serbest metin yok; eşleşmeyen olay `rule_id` ile görünür kaydedilir. _Kaynak:_ §5.9, §17.4.5; C-73, AG-14.
- [ ] **Erken yanıt tamponu** — Bekleme açılmadan gelen yanıt/olay bekleyenin posta kutusunda korelasyon anahtarıyla tamponlanır; bekleme açılınca önce kutuya bakılır; erken yanıt hiçbir koşulda kaybolmaz; tampon kutu saklama kurallarına tabi. _Kaynak:_ §4.2, §4.3.1, §6.1, §17.4.4; L-26, L-35, INV-3, MKT-11, AG-13.
- [ ] **Yanıt eşleştirme ve "çözüldü" olayı** — Relay "şu anahtara yanıt bekleniyor, son tarih X" kaydını tutar, yanıtı hangi kanaldan gelirse eşleştirir ve bekleyen tarafa "çözüldü" olayını teslim eder; API her ajan sistemine ve müşteri koduna açıktır. _Kaynak:_ §7.1, §7.5; E-45, E-47.

#### Test altyapısı
- [ ] **Gerçek motorla eşzamanlılık testleri ve sanal saat akış testleri** — Benzersizlik, hız limiti, adalet ve bekleme yarışları gerçek kuyruk motoru + gerçek DB ile; test düzlemi sanal saatiyle akış testleri. _Kaynak:_ §19.13.6; T-61 (madde 1 akış katmanı, madde 3), T-57 (madde 3 sanal saat).

#### Bu aşamada doğrulanacak sınırlar
- **INV-44, CH-17, T-20, T-9 (3–5), OP-29** — hız limiti asla "limitsiz"e düşmez; iki arka uç aynı kararı verir, geçişte katı olan.
- **T-11, T-19, T-30** — tek saat otoritesi; algoritma matrisi; deterministik jitter.
- **INV-16, INV-24, T-31, T-32, T-33, T-34, T-36, TN-51** — şerit yalnız sınıftan; OTP/L0 yük atmayla düşmez; fiziksel şerit ayrımı ve tavanlar.
- **API-51** — aşırı yükte `503`, `security` reddedilmez.
- **T-21, T-22, TN-54** — DRR adaleti; küme geneli eşzamanlılık sınırları.
- **INV-40, CH-15, T-25** — devre kesici kiracı yalıtımlı, 4xx açmaz, gerçek half-open.
- **INV-13, INV-14, CH-9, CH-12, T-26, T-27, T-29** — tek retry katmanı, `Retry-After` her zaman, `expires_at` sınırı, retry bütçesi, DLQ oynatma kuralları.
- **INV-3, INV-43, TN-36, TN-37, TN-38, TN-39, TN-40, TN-41, TN-42, TN-43** — kill switch modeli, en kısıtlayıcı kazanır, fail-safe, `PAUSED`, gerekçe/TTL, `security` istisnası, ölü adam anahtarı.
- **T-23, T-24, WF-43, AG-4** — sayfalı fan-out; uzun bekleme satır + zamanlayıcı, bekleme değişmezleri DB kısıtı.
- **INV-35, IN-22, AG-24** — durum kayıtta, ipucu kaybı kayıp üretmez; okuma sırası `seq` ile garanti, `since` boşluk tamamlar, `epoch` değişiminde tam senkron.
- **AG-9, AG-13, AG-14** — son tarih zorunlu ve kalıcı; erken yanıt kaybolmaz; birinci aşama eşleme birebir, eşleşmeyen olay `rule_id` ile kaydedilir.
- **X-27, TN-8** — sanal saat yalnız `test` düzleminde.
- **T-18, T-61 (3)** — kendi bileşenler kural testli; yarışlar gerçek motor + DB ile.

---

### Aşama 3 — Giriş, API ve operatör yüzeyi

Dış dünyanın Relay'e girdiği bütün kapılar: sözleşmeler, sunucu ve operatör kimliği, `POST /v1/events` ve CloudEvents girişi, alıcı upsert, batch, hatalar, sürümleme, sayfalama, iptal, `live`/`test` düzlemleri, kota ve hız limiti, CLI ve operatör aracı (T-54: erken). A1 (kiracılık, idempotency deposu, outbox, denetim kaydı) ve A2'ye (GCRA, kill switch, yük atma, sanal saat) dayanır; workflow iskeleti (kayıt, sürümleme, olay şeması, tek kanallı basit yayımlanmış workflow) de bu aşamadadır.

#### Spec dışı ön koşullar
- [ ] **Hata `type` URL tabanı** — API-36 çözülebilir URL ister; belge alan adı ve yol şeması tanımlı değil. (Adem kararı)
- [ ] **Kimlik ve anahtar önek tablosu** — API-9/API-41 tablonun OpenAPI ekinde olacağını söyler; tam önek listesi ve anahtar tür × ortam öneki spec'te yok. (Adem kararı)
- [ ] **Kapsam listesinin tam adları** — API-43 "kaba taneli, kısa liste" der; yalnız `publish`, `read` ve abone kapsamları adlandırılmış, yönetim kapsamları yok. (Adem kararı)
- [ ] **CLI çıkış kodu tablosu** — X-33 "belgelenmiş, kararlı çıkış kodları" ister; kod listesi yok. (Adem kararı)
- [ ] **Operatör API'si/CLI sözleşme dosyası** — T-54 ve OP-44 azaltmaların operatör API/CLI eylemi olmasını ister; T-59'daki operatör API ailesi için sözleşme dosyası tanımlı değil.
- [ ] **Çapraz ortam erişiminde 403 mü 404 mü** — API-42 `test` anahtarıyla `live` veriye erişimde `403 auth_environment_mismatch` der; MD-18/TN-15 başka kiracı veya ortamın kaynağına erişimde 404 der. Hangisinin ne zaman uygulanacağı netleşmeli. (Adem kararı)
- [ ] **Değeri verilmemiş POLICY DEFAULT'lar** — API anahtarı çakışma penceresi (API-44, 0–30 gün, değer yok; TN-24) ve kiracı başına anahtar üst sınırı; "uzun süre kullanılmayan anahtar" eşiği (API-44); IP başına geçersiz anahtar denemesi sınırı (API-47); API hız limiti değerleri ve uç ağırlıkları ("orta", "sabit yüksek"), değer konmadan yayımlanmaz (API-50); kiracı/gönderici askıya alma hukuki süreleri, özellik bu aşamaya girerken değer konur (F-28). _Kaynak:_ §22.3; OQ-27, API-44, API-47, API-50, TN-10. (Adem kararı)

#### Sözleşmeler ve API geliştirme kuralları
- [ ] **OpenAPI 3.1 ve AsyncAPI 3.x sözleşmeleri** — HTTP API OpenAPI 3.1, olay yüzeyi (webhook, realtime, ajan olayları) AsyncAPI 3.1, gövde/olay şemaları JSON Schema 2020-12; elle yazılır, Adem onaylar, bağımlı kod onaydan sonra yazılır. _Kaynak:_ §1.7, §9.1; MD-13, API-1.
- [ ] **CI sözleşme testi** — Sunucu her CI çalışmasında belgelere karşı test edilir; belge–davranış ve belge–DB kısıtı kayması build'i kırar. _Kaynak:_ §9.1; API-2.
- [ ] **API geliştirme kuralları** — Aileler ayrı sözleşmelerde (sunucu, abone, realtime, giden olaylar/AsyncAPI, ajan, operatör); sürüm içinde yalnız ekleme; PR'da OpenAPI/AsyncAPI kırıcı fark kapısı; mikro para + ISO 4217, BCP 47, önekli opak kimlik, `ETag`/`If-Match`, `Request-Id`, `RateLimit-*`, `Retry-After`. _Kaynak:_ §19.13.4; T-59 (madde 1–7).
- [ ] **Uç aileleri, `/v1` yol düzeni ve adlandırma** — Gönderim, yönetim, sorgu, istemci, ajan, gelen sağlayıcı olayları ve operatör aileleri `/v1` altında; ayrı `/api` öneki yok; her kavram için tek yol, kanal başına gönderim ucu yok, workflow kimliği slug; kimlik önekleri tek tabloda; yanıt alanları `response`/`decision` (`approval` yok). _Kaynak:_ §5.14, §9.2; L-50, C-74, API-6.
- [ ] **Ortak istek/yanıt kuralları ve bilinmeyen alan reddi** — JSON utf-8, problem+json, `snake_case`, `null` = temizle / yokluk = dokunma, RFC 3339 UTC, ISO 8601 süre, tutar/büyük sayı string, yalnız HTTPS TLS ≥ 1.2 + HSTS, her yanıtta `Request-Id`, tekil kaynakta `object`; bilinmeyen alan (iç içe ve `overrides` dahil) `422 unknown_field`, sessizce yok sayılmaz. _Kaynak:_ §6.8, §9.3; API-8, INV-46.
- [ ] **Tek olay kataloğu** — Bütün olay adları `noun.verb_past`, tek sözlükte; aynı kavram iki adla yayımlanmaz (`cancelled` tek yazım); katalog portal, SDK ve doğrulayıcıları besler. _Kaynak:_ §9.1, §9.13; API-3, API-59.
- [ ] **Limitlerin tek kaynağı ve hata gövdesinde limit** — Limitler kodla aynı kaynaktan tanımlanır; limit/kota hatasında RFC 9457 gövdesi hangi limitin aşıldığını `limit` ve `actual` ile söyler. _Kaynak:_ §8.12, §9.1; X-37, API-4.
- [ ] **API garanti dili** — Belgelerde "en az bir kez teslim + kalıcı idempotency ile etkin bir kez işlem"; "exactly-once" tek başına yok; `Idempotency-Key` "yaygın pratik" olarak anılır. _Kaynak:_ §9.4; API-18.
- [ ] **Birinci taraf ayrıcalığı yok** — Suiss ürünleri (Access, Work, Executor, One, Pay) Relay'i üçüncü taraflarla aynı herkese açık API ile kullanır; gizli API veya ayrıcalıklı yazma yolu yok, özel ihtiyaç genel yetenek olarak her üreticiye açılır. _Kaynak:_ §7 okuma kuralı 3, §7.2; E-3.
- [ ] **API'de müşteri tanımlı köprü URL'si yok** — Sözleşmede çalışma anında müşteri sunucusuna çağrı yapan köprü URL'si alanı yoktur; geliştirme tüneli yalnız CLI'dadır. _Kaynak:_ §8.11, §9.15; X-34, API-64.

#### Sürümleme
- [ ] **Dış sözleşme ve projeksiyon kararlılığı** — İç model, eksen veya kanıt tablosu değişse de API ve giden olay projeksiyonu kırıcı değişmez; projeksiyon şeması OpenAPI/AsyncAPI'de yazılır; `status` kümesine ekleme ve kırıcı değişiklik yalnız sürümlü sözleşme süreciyle. _Kaynak:_ §1.7, §6.2, §14.3.3; INV-10, MD-15, DS-15.
- [ ] **Tarihli sürümleme** — Kalıcı `/v1` + `Relay-Version: YYYY-MM-DD`; başlık yoksa kiracının sabit sürümü; yeni hesapta ilk başarılı istekte otomatik sabitleme; en güncel varsayılan değil; geçersiz değer `400 unsupported_api_version` + liste. _Kaynak:_ §9.11; API-52.
- [ ] **Kırıcı değişiklik sınıflandırması** — Kırıcı/kırıcı olmayan tablosu sözleşme incelemesinde uygulanır (ör. CI'da OpenAPI fark denetimi). _Kaynak:_ §9.11; API-53.
- [ ] **Sürüm destek ve kaldırma** — Tarihli sürüm ≥ 24 ay; kaldırma ≥ 12 ay önce duyurulur (e-posta, panel bandı, değişiklik günlüğü, `Deprecation`, `Sunset`, `Link rel="deprecation"`); 90 gün kullanılmayan erken kaldırılabilir; tek iç model + sürüm başına dönüştürücü zinciri. _Kaynak:_ §9.11; API-54.
- [ ] **Beta özellik başlığı** — `Relay-Beta: <özellik>` ile açılır, sürüm sözleşmesi dışında, yanıtta `"beta": true`. _Kaynak:_ §9.11; API-55.

#### Sunucu kimliği ve ortamlar
- [ ] **API anahtarı modeli** — Tek kiracı + tek ortam + isteğe bağlı tek alt kiracıya değişmez bağlı Bearer anahtar; tür × ortam önekli (secret scanning); yayın ve okuma kapsamları ayrı anahtarlar; sır yalnız oluşturmada bir kez gösterilir, anahtarlı özet saklanır, panelde son 4 karakter; istemci API anahtarı taşımaz. _Kaynak:_ §5.2, §9.9, §18.3.3; C-16, INV-39, INV-51, API-41, TN-24, TN-35.
- [ ] **API anahtarı yaşam döngüsü** — `roll` ile çakışmalı rotasyon, anında iptal (kill switch ile aynı yayılım yolundan tüm düğümlere), `last_used_at`/`last_used_ip`, kullanılmayan anahtar uyarısı, kiracı başına anahtar üst sınırı. _Kaynak:_ §9.9, §18.3.3; API-44, TN-24, TN-36.
- [ ] **Kaba kapsam modeli** — `publish` ve `read` ayrı, yönetim kapsamları; anahtar/kimlik yönetimi hiçbir API kimliğine verilmez (yalnız operatör oturumu + yeniden doğrulama); eksik kapsam `403 auth_insufficient_scope` + `required_scope`/`granted_scopes`. _Kaynak:_ §9.9; API-43, API-48.
- [ ] **OAuth2 client credentials** — Kiracı IdP'si ortam başına kayıtlı (issuer, JWKS, `aud`, kapsam eşleme); kısa ömürlü JWT, her istekte imza + `iss`/`aud`/`exp`/`nbf`; izinli algoritma listesi, imzasız red; eşlenmeyen kapsam yetki vermez. Üç sunucu kimliği yolu aynı kapsam, ortam, hata ve askı kurallarına uyar. _Kaynak:_ §9.9; API-48, API-70.
- [ ] **mTLS ek katmanı** — Kurumsal kiracı için RFC 8705 sertifikaya bağlı mTLS; API anahtarı, OAuth2 ve Access servis jetonuyla birlikte ek katman. _Kaynak:_ §9.9; API-41, API-48.
- [ ] **Kimlik hata sözleşmesi** — 401'de `WWW-Authenticate: Bearer` + `auth_*`; geçersiz anahtar denemesi IP başına sınırlı; sabit süreli karşılaştırma. _Kaynak:_ §9.9; API-47.
- [ ] **`live`/`test` düzlemleri** — Ortam yalnız API anahtarından çözülür, gövdede ortam alanı yok, değiştirilemez; ayrı anahtar setleri, alıcılar, workflow yayınları, webhook uçları, idempotency uzayı ve kotalar; `test` anahtarı canlı veriye erişemez (`403 auth_environment_mismatch`); webhook ucunun ortamı sabit. _Kaynak:_ §1.7, §8.9, §9.9, §18.1.3; MD-18, INV-38, INV-39, X-24, API-42, TN-7.
- [ ] **Başka kiracı veya ortamın kaynağı 404** — Varlık sızdırmamak için çapraz kiracı/ortam erişimi 403 değil 404 döner. _Kaynak:_ §1.7, §6.7, §9.3, §18.2; MD-18, INV-38, API-9, TN-15.
- [ ] **Uç listesinden negatif yalıtım testleri** — A kiracısının anahtarıyla B'nin her kaynağına istek → 404; testler uç listesinden otomatik üretilir ve her PR'da koşar. _Kaynak:_ §18.2; TN-16.
- [ ] **Alt kiracı seçimi** — `tenant` alanı API anahtarının kiracısı içindeki alt kiracıyı seçer; anahtarın kiracısı istekle ezilemez. _Kaynak:_ §9.5; API-25.

#### Operatör kimliği, yetki ve denetim
- [ ] **Relay'in Access'siz tam çalışması** — Relay kendi API anahtarları, operatör girişi ve abone jetonuyla Access olmadan tam kurulur; Access-li ve Access-siz dört çalışma biçimi aynı ürünle desteklenir. _Kaynak:_ §7.2; E-1, E-2.
- [ ] **Operatör OIDC girişi ve RBAC** — Panel ve yönetim API'sine giriş herhangi bir OIDC IdP ile (Access önerilir); roller ve yetkiler Relay'in kaydında, self-host'ta tam; dış IdP iddiası yalnız kimlik kanıtı, yetki kaynağı değil; yerleşik kullanıcı/parola deposu yalnız ilk kurulum yöneticisi için, IdP bağlanınca kapatılabilir; her yönetim eylemi denetimde. _Kaynak:_ §1.6, §1.7, §5.2, §7.3.7, §7.9, §8.2.1, §18.3.1; MD-19, MD-1, C-14, E-26, E-61, E-63, X-3, TN-19.
- [ ] **Hassas işlemlerde yeniden doğrulama (fail-closed)** — Kill switch açma/gevşetme/`security` durdurma, sır/anahtar rotasyonu ve sağlayıcı hesabı, PII gösterme, İYS ayarları, ajan tavanı/bekleyenlerini serbest bırakma, saklama/çıkarma/dışa aktarma, `critical` onayı, askıya alma/takedown, rol ve API anahtarı işlemleri bağlı IdP'den `max_age`/`acr` ile yeniden doğrulama ister; alınamazsa işlem yapılmaz; sonuç işlemle birlikte denetime yazılır (Access bağlıysa step-up A13'te). _Kaynak:_ §1.7, §7.3.7, §7.9, §8.2.1, §18.3.1; MD-19, E-27, E-61, X-3, TN-21.
- [ ] **Gevşetme daha yüksek yetki** — Durdurma/kısma/askıya alma/kota düşürme düşük yetkiyle anında; yeniden açma/gevşetme/kota artırma daha yüksek yetki + yeniden doğrulama. _Kaynak:_ §18.3.1; TN-22.
- [ ] **Kurulum operatörü rolü** — Kiracıların üstündeki tek rol (SaaS'ta işletmeci, self-host'ta kurum yöneticisi, kod aynı): platform kill switch, kiracı askıya alma, paylaşılan sağlayıcı hesapları, `critical` öncelik onayı; RLS'i atlayarak kiracı verisi okuyamaz. _Kaynak:_ §1.6, §5.2, §18.3.2; C-15, TN-23.
- [ ] **Destek erişimi devri** — Kurulum operatörünün destek erişimi kiracı adına, süreli ve denetimli yetki devriyle; devir denetimde. _Kaynak:_ §18.3.2; TN-23, TN-47.
- [ ] **Çapraz kiracı sorgu kısıtı** — Çapraz kiracı sorgu yalnız operatör rolüyle ve her biri denetimde; kiracı kullanıcıları her zaman tek kiracı bağlamında. _Kaynak:_ §8.2.1; X-4.
- [ ] **PII maskeleme ve denetimli gösterme** — PII varsayılan maskeli; açık gösterme yetki + yeniden doğrulama ister ve her gösterim ayrı `pii.revealed` denetim kaydı (operatör, abone, alan); müşteri listesi toplu çekilemez, dışa aktarım ayrı, yetkili ve denetlenen işlem. _Kaynak:_ §8.2.1, §8.4, §18.3.1; X-5, TN-21, TN-47.
- [ ] **Denetim olay kataloğu** — Kill switch, sır/anahtar, PII, İYS/uyum, ajan, saklama/veri, yayın/kampanya, kimlik/yetki, öncelik, kiracı aileleri; teslim defterinden ayrı ("insanlar ne yaptı"); aileler ilgili özellik aşamasında doldurulur. _Kaynak:_ §18.6; TN-47.
- [ ] **Denetimde aktör kimliği (Access'siz)** — Eylemi yapanın IdP kimliği (`iss` + `sub`) her denetim kaydında. _Kaynak:_ §18.6; TN-48.

#### Workflow iskeleti
- [ ] **Workflow kaydı ve değişmez sürümler** — Workflow sürümlü adım listesidir ve bildirim akışıdır (iş süreci değil); yayınlanmış sürüm değişmez; tanım veridir: çalışma anında müşteri koduna çağrı yok, bridge yok, SDK ile yazılan workflow veriye derlenir (tanım biçimi ayrıntıları, `managed_by` ve görsel editör A8/A14'te). _Kaynak:_ §1.7, §2.8, §4.3.1, §5.5, §10.1, §10.2; C-40, MD-16, F-6, L-32, INV-48, MKT-19, WF-1, WF-5.
- [ ] **Olay türü → workflow, olay şeması ve olay doğrulaması** — `event_type` bir workflow'a eşlenir; olay veri şeması (JSON Schema 2020-12) workflow sürümüne aittir ve gelen olay buna göre doğrulanır. _Kaynak:_ §5.4, §10.1; C-28, WF-1.
- [ ] **Kanal adımı (tek kanal)** — Kanal adımı bir şablona işaret eder ve tek kanala gönderir; yayımlanmış workflow bu basit adımla uçtan uca çalışır (rota politikasına gönderme, A/B varyantları ve yükseltme A8'de). _Kaynak:_ §10.1, §10.3; WF-1, WF-8.
- [ ] **Workflow yaşam döngüsü ve geri dönüş** — Taslak → test → yayın (`202`, yayın kapısı); her yayın değişmez sürüm; "eski sürüme dön" tek işlemle yeni sürüm olarak yayımlanır; çalışan koşular başladıkları sürümde biter; her bildirimin hangi sürümle gittiği kaydedilir; `test` → `live` CLI `promote` (Mermaid dışa aktarımı A8'de). _Kaynak:_ §8.3.3, §10.2; X-10, WF-6.
- [ ] **Workflow yönetim uçları** — `GET/POST /v1/workflows`, `GET/PUT /v1/workflows/{key}` (PUT yeni taslak), `POST .../publish` (202), sürüm listesi, `POST .../versions/{n}/promote` (rota, topic/abonelik, tekrar kuralı, throttle sıfırlama uçları A8'de). _Kaynak:_ §9.16; API-69.
- [ ] **Bildirim anında sürüm sabitleme** — Şablon sürüm kümesi (kanal × locale + fallback), layout/parça sürümleri, adres çözümlemesi, `dedup_key`, deney varyantı bildirim anında donar; kapılar her denemede yeniden değerlendirilir; sabit sürüm gönderilemiyorsa sessiz yükseltme yok, sonuç + `rule_id`. _Kaynak:_ §10.2; WF-7.

#### Gönderim girişi (`POST /v1/events`)
- [ ] **Karar ≠ hata yanıt modeli** — Politika sonucu `202` sonrası karar olarak raporlanır; senkron hata yalnız doğrulama, yetki, kota ve önizleme/test/dry-run uçlarında. _Kaynak:_ §1.7, §5.1; MD-12, C-4.
- [ ] **`Idempotency-Key` zorunluluğu ve biçimi** — POST/PUT/PATCH/DELETE'te zorunlu, yoksa `400 idempotency_key_missing`; GET'te yok sayılır; 8–255 karakter, tırnak soyulur; içerikten türetilmez; ömür 24 saat sabit. _Kaynak:_ §1.7, §4.2, §5.10, §6.3, §9.4; MD-20, L-5, C-79, INV-11, API-10, API-11, API-12.
- [ ] **Idempotency semantiği** — SHA-256 ham gövde parmak izi; aynı anahtar + gövde ilk yanıtı durum kodu dahil birebir `Idempotency-Replayed: true` ile döner; farklı gövde `422 idempotency_key_reuse`; işleniyor `409 idempotency_key_in_progress` + `Retry-After: 1`. _Kaynak:_ §9.4, §20.1; API-13, OP-6 (madde 1, 2).
- [ ] **Idempotency önbellek politikası** — Yalnız iş mantığı başladıktan sonraki yanıtlar saklanır; 400/401/403/429 saklanmaz; 5xx yalnız kısmi yürütmede saklanır, yan etkisiz arıza `retryable: true`. _Kaynak:_ §9.4; API-14.
- [ ] **Tek transaction kabul yolu** — Idempotency → bildirim → teslimler → açılış olayları → kuyruk işi ve dış olay outbox'ı tek transaction'da; "kabul edildi ama kuyruğa girmedi" = 0 (huni tamlığının ön şartı). _Kaynak:_ §14.7.2, §20.2; DS-36, OP-7.
- [ ] **`POST /v1/events` kabul ucu** — `202 Accepted`, `Location`, `Request-Id`; gövdede `workflow {key, version}`, `recipient_count`, alıcı başına `notification_id` hemen döner; senkron teslim yok; veri önceden biçimlenmiş değer taşımaz; istemciye açılmaz. _Kaynak:_ §4.2, §5.4, §9.5; L-6, C-28, INV-39, API-19.
- [ ] **Gönderim isteği alanları** — `workflow` (yayımlanmamışsa `422 workflow_not_published`), `to` (1–100), `actor`, `tenant`, `data` (≤ 256 kB), `dedup_key`, `channels` (yalnız daraltır), `overrides`, `send_at`, `expires_at`, `priority`, `security_subtype`, `on_expire`, `cancellation_key`, `retention`, `metadata` (≤ 16 anahtar, ≤ 512 karakter, olay/webhook'ta geri döner) sözleşmesi ve doğrulaması. _Kaynak:_ §9.5; API-20.
- [ ] **Kabulde olay şeması doğrulaması** — `data` workflow'un yayındaki sürümünün JSON Schema Draft 2020-12 şemasına karşı doğrulanır; geçersizse `422 validation_failed`, kuyruğa girmez. _Kaynak:_ §9.5, §11.4, §19.10; API-27, TP-13, T-51 (madde 4 JSON Schema).
- [ ] **`dedup_key` ile olay tekrarı** — Aynı `dedup_key` yeni bildirim açmaz; mevcut bildirim kimliği + `duplicate_of` döner, tekrar kayda geçer; anahtar bildirim saklandığı sürece geçerli; meşru yeni istek yeni anahtarla gelir. _Kaynak:_ §9.4, §20.1; API-16, API-17, OP-6.

#### Alıcılar
- [ ] **Alıcı upsert'i (gönderimde ve test düzleminde)** — Alıcı kiracı içinde `external_id` ile tekil; iletişim bilgisi varsa açık upsert, yalnız kimlik + alıcı yoksa `422 recipient_not_found` (hayalet alıcı yok); `{id}` nesnesi yalnız inbox abonesi açar, düz string bu anlamı taşımaz; telefon E.164; `test` davranışı `live` ile aynı. _Kaynak:_ §5.3, §8.9, §9.5; C-19, C-20, X-25, API-21.
- [ ] **Zorunlu kiracı varsayılanları ve tek `curl` ile gönderim** — Hesap açılışında `default_timezone` ve `default_locale` zorunlu seçilir (sistem varsayılanı yok) ve test anahtarı verilir; `to: {id, email}` ile tek `curl` bildirim gönderir ve alıcıyı oluşturur. _Kaynak:_ §8.12; X-35.
- [ ] **Alıcı kaynak uçları** — `POST /v1/subscribers` (çakışma 409), `PUT` upsert (ilk oluşturmada 201), `PATCH`, `GET`, liste, toplu upsert (207); yanıtta `channels.*.reachable` + neden. _Kaynak:_ §9.16; API-66.
- [ ] **Alıcı silme talebi** — `DELETE` `202` + silme talebi; kuyruk işleri, zamanlanmış gönderimler, digest tamponları ve inbox'a uygulanır; kişisel alanlar crypto-shredding, fiziksel silme yok. _Kaynak:_ §9.16; API-66.

#### CloudEvents ve toplu giriş
- [ ] **CloudEvents girişi** — Binary (`ce-*`), structured ve batch biçimleri aynı girişte; gelen ve giden olaylar CloudEvents zarfında; `type` → workflow eşleme tablosu (kiracı tanımlı); `(tenant, source, id)` = `dedup_key`; W3C `traceparent` üretici ile Relay arasında (Access dahil) uçtan uca taşınır. _Kaynak:_ §4.2, §7.3.12, §9.6; L-6, C-28, E-37, API-28.
- [ ] **Alan beyaz listesi ve CloudEvents eşlemesi** — Dönüşüm betiği yerine alan beyaz listesi ve eşleme. _Kaynak:_ §1.7; MD-16.
- [ ] **Eşlenmemiş CloudEvents türü** — Eşlemesi olmayan `type` senkron `422 event_type_not_mapped`. _Kaynak:_ §9.6; API-29.
- [ ] **CloudEvents idempotency istisnası** — Yalnız CloudEvents girişinde başlıksız istekte idempotency anahtarı `(tenant, source, id)`'den türetilir; başlık varsa başlık geçerli; diğer uçlarda istisna yok. _Kaynak:_ §9.6; API-10, API-31.
- [ ] **Broadway ingest konnektörleri** — Müşterinin Kafka/SQS/outbox kaynağından olay alımı Broadway ile; Broadway hız sınırlaması sağlayıcı limitinde kullanılmaz. _Kaynak:_ §19.8; T-41 (ingest).
- [ ] **`POST /v1/events/batch`** — Satır bazlı sonuç: 202/207/422/400/413, 401/403/429 bütün istek için; `ref` (≤ 128) veya `index`; satır başına RFC 9457; `summary` zorunlu; tekil ve toplu uç aynı hata işleyicisi. _Kaynak:_ §9.7; API-32.
- [ ] **Batch limitleri** — 500 olay, olay başına 100 alıcı, 5 MB gövde, satır `data` 256 kB; `Relay-Batch-Max-Events`, `Relay-Batch-Max-Recipients-Per-Event` başlıkları; aşımda `413 batch_too_large`. _Kaynak:_ §9.7; API-33.
- [ ] **Batch idempotency ve sıra** — Tek `Idempotency-Key` bütün partiyi kapsar, `ref` idempotency birimi değil; parti atomik/sıralı değil, `results` girdi sırasında; hız limiti/kotadan satır sayısı kadar tüketir. _Kaynak:_ §9.7; API-34.

#### Hata modeli
- [ ] **RFC 9457 problem nesnesi** — API kenarında `%Relay.Error{}` problem details'e çevrilir; zorunlu `type` (çözülebilir URL, `about:blank` yok), `title`, `status`, `code`, `retryable`; uzantılar `request_id`, `errors`, `retry_after`, `limit`/`actual`, `required_scope`/`granted_scopes`, `policy`; `instance` istek yolu. _Kaynak:_ §9.8, §19.13.3; API-36, T-58 (madde 5 API kenarı).
- [ ] **Alan hataları JSON Pointer ve toplu rapor** — RFC 6901 işaretçi; alt kodlar `required`, `invalid_format`, `too_long`, `too_short`, `not_found`, `not_allowed`, `conflict`, `unsupported_value`; ilk hatada durmadan toplu rapor. _Kaynak:_ §9.8; API-37.
- [ ] **`retryable` tablosu ve `Retry-After`** — Her hata `retryable` taşır; `true` ise `Retry-After` delta-saniye; durum → retryable varsayılan tablosu; tam başarısızlık hiçbir uçta 2xx dönmez. _Kaynak:_ §9.8; API-38, API-39.
- [ ] **Hata kodu aileleri** — `auth_*`, `request_*`, `idempotency_*`, `workflow_*`, `recipient_*`, `channel_*`, `quota_*`, `platform_*` sözlüğü; politika sonuçları bu tabloda yok. _Kaynak:_ §9.8; API-40.

#### Sayfalama ve iptal
- [ ] **Opak imleçli sayfalama** — `limit` 1–100 (vars. 50), `starting_after`, `ending_before`; `{object: list, data, has_more, next_cursor}`; imleç imzalı ve kiracı (istemcide kiracı + abone) kapsamlı; `expand` yalnız tekil kaynakta. _Kaynak:_ §9.12; API-56.
- [ ] **İptal uçları** — `POST /v1/events/{id}/cancel`, `/v1/notifications/{id}/cancel`, `/v1/events/cancel_by_key` (benzersiz olmayan `cancellation_key` + alıcı/kanal filtresi); önceden anahtar gerekmez; `200` + `cancelled`/`already_sent`/`not_found`/`details[]`, 204 yok. _Kaynak:_ §9.13; API-57.
- [ ] **İptal sırası, tombstone ve sınırı** — İptal tetiklemeyle aynı sıralı anahtardan işlenir; koşu yoksa tombstone yazılır, sonradan gelen koşu `cancelled` olur; zamanlanmış her iş (`send_at`, bekle, digest, tekrar, kampanya) iptal edilebilir; yalnız sağlayıcıya verilmemiş teslim durur, gönderilmiş SMS/e-posta/push geri alınamaz ve bu belgede yazılır. _Kaynak:_ §4.2, §5.4, §9.13; L-7, C-29, INV-60, API-58, API-59.

#### Hız limiti, kota ve aşırı yük
- [ ] **Hammer düğüm-yerel API koruması** — Hammer yalnız dağıtık limitin önünde ucuz ilk filtre. _Kaynak:_ §19.8; T-42.
- [ ] **İki katmanlı API hız limiti ve ağırlık** — Kiracı kapsamı burst + sustained, kısıtlayıcı olan raporlanır; anahtar başına alt limit; ağırlık: GET 1, tekil olay 1, batch satır sayısı, kampanya sabit yüksek, şablon yazma/önizleme orta. _Kaynak:_ §9.10; API-50.
- [ ] **Hız limiti başlıkları** — `RateLimit`, `RateLimit-Policy` + `X-RateLimit-Limit/Remaining/Reset`; `Retry-After` her zaman delta-saniye. _Kaynak:_ §9.10; API-49.
- [ ] **Kota ≠ hız limiti** — Kota aşımı girişte `429 quota_exhausted` (retryable değil, `Retry-After` yok, hangi kota aşıldığını söyler), eşiklerde kiracıya olay; hız aşımı `429 rate_limited` + `Retry-After` (retryable); hız limiti işi reddetmez, kuyrukta yavaşlatır; sağlayıcı limitleri müşteriye 429 olarak yansımaz. _Kaynak:_ §9.10, §18.7; API-51, TN-52.
- [ ] **Kota kovaları ve sınıf payı** — `security` ve toplu gönderim ayrı kovalar (toplu `security`'yi tüketemez); kova sınırları kiracı yapılandırması verisi; kiracı sınıf başına kota payı tanımlar, payını dolduran sınıf aynı hatayla reddedilir, gövde kotayı ve sınıfı söyler. _Kaynak:_ §9.10, §18.7; API-51, TN-52.
- [ ] **`security` ek payı** — Kota tükenince yalnız `security` için sınırlı ek pay (PD %10, kiracı ayarı); açıldığında kiracı ve kurulum operatörü uyarılır; ek pay bitince `security` de `429 quota_exhausted`. _Kaynak:_ §9.10, §18.7; API-51, TN-52.
- [ ] **Girişte kabul kontrolü** — Aşırı yükte L2/L3 için `429` + `Retry-After`, kanal devresi açıkken `marketing` için `503`; `L_max = μ·W_max` üstü red; ρ hedefi 0,7; zincirde sınırlı tamponlar, tek sınırsız tampon kalıcı kuyruk (derinlik/yaş alarmı); AIMD giriş hızı; DB havuzu doygunsa `503`. _Kaynak:_ §19.7; T-35.

#### Askıya alma, kill switch ve gönderim modu
- [ ] **Kiracı/gönderici askıya alma (giriş noktaları)** — Askıya alınmış kiracı, alt kiracı, gönderici kimliği veya abone için API, kampanya başlatma, CloudEvents, gelen webhook, ajan, zamanlanmış gönderim, tekrar kuralı ve giden olay girişleri aynı anda durur (`403 auth_tenant_suspended`); bekleyen işler `PAUSED`; gönderici kimliği ayrı askıya alınabilir; askıya alma/kaldırma denetimde. _Kaynak:_ §5.2, §6.7, §9.9, §18.1.1; C-11, INV-42, API-47, TN-10.
- [ ] **Kill switch kabul noktası** — Eşleşen kill switch varsa istek kabul edilir, teslim işi açılmaz, karar `rule_id` ile kaydedilir (karar ≠ hata); platform tam durdurmada `503` + `Retry-After`. _Kaynak:_ §18.5.2; TN-40.
- [ ] **Kill switch kapsam yetkisi** — Kampanya/workflow → kiracı operatörü; kiracı × kanal → kiracı yöneticisi; platform → kurulum operatörü; açma/gevşetme yeniden doğrulama ister; her değişiklik denetime ve işletim kanalına. _Kaynak:_ §18.5.2; TN-41, TN-22.
- [ ] **Kill switch API ve CLI erişim yolları** — Operatör API'si ve CLI aynı kaydı yazar, aynı denetim kaydını üretir. _Kaynak:_ §18.5.2; TN-45.
- [ ] **Gönderim modu kavramı ve çözümü** — `live|shadow|dry_run|off`, sevk sınırında uygulanır; çözüm sırası istek (yalnız test düzlemi/önizleme; canlıda red) → `(tenant, category, channel)` → `(tenant, channel)` → `(tenant)` → kurulum; `off` `skipped` + `send_mode_off`, kill switch yerine geçmez; değişiklik denetimli. _Kaynak:_ §20.9.1; OP-51.

#### Test düzlemi
- [ ] **`test` düzlemi aynı hat** — Doğrulama, idempotency, tercih, İYS, rota, şablon, kill switch `test`'te de çalışır; sanal saat API'de yalnız `test` anahtarıyla görünür; güvenliği zayıflatan bayrak yok. _Kaynak:_ §9.14; API-63.

#### CLI ve operatör aracı
- [ ] **Erken ürün yüzeyi** — HTTP API, CLI ve operatör aracı erken aşamada gelir; her yeni yetenek hemen denenebilir. _Kaynak:_ §19.12; T-54 (madde 1).
- [ ] **CLI temeli ve `relay trigger`** — `listen`, `trigger`, `pull`/`push`/`promote`; test ve canlı anahtarı ayırt eder, canlı düzlemi değiştiren komutlar açık onay ister; her komut `--json` çıktısı ve belgelenmiş, kararlı çıkış kodları sunar; `relay trigger <workflow>` test olayı tetikler; tek `curl` ile ilk bildirim hedefi. _Kaynak:_ §4.2, §8.11, §9.15; L-30, X-33, API-64.
- [ ] **Operatör iş kuyruğu görünümü** — Oban Web (Apache-2.0) ve oban_met ile; büyük tablolardaki sayım sorgu yükü izlenir ve sınırlanır. _Kaynak:_ §8.2.4; X-7.
- [ ] **Sağlık uçları** — Ayrı canlılık ve hazırlık uçları; hazırlık rolün bağımlılıklarını (PG, Valkey, KMS) kontrol eder. _Kaynak:_ §19.13.8; T-63 (madde 6).

#### Bu aşamada doğrulanacak sınırlar
- **INV-10, INV-46, API-2, API-8, API-53, DS-15** — Dış sözleşme kararlılığı; bilinmeyen alan `422`; belge–davranış kayması build'i kırar.
- **INV-11, API-10, API-11, API-12, API-13, API-14, API-31, OP-6 (1, 2)** — Idempotency zorunluluğu, replay, reuse `422`, in-progress `409`, saklama politikası, CloudEvents istisnası.
- **API-16, API-17** — `dedup_key` yeni bildirim açmaz, `duplicate_of` döner.
- **DS-36, OP-7** — Kabul ile kuyruk kaydı aynı transaction; kabul edilip kuyruğa girmeyen = 0.
- **API-19, API-20, API-27, API-29** — Kabul ucu yanıtı, alan doğrulaması, şema doğrulaması, eşlenmemiş tür.
- **API-21, X-25, API-66** — Hayalet alıcı yok; `test` = `live` alıcı davranışı; alıcı uçları ve silme talebi.
- **API-32, API-33, API-34** — Batch satır sonuçları, limitler, tek idempotency.
- **API-36, API-37, API-38, API-39, API-40, API-4, X-37** — Problem nesnesi, alan hataları, `retryable`, tam başarısızlıkta 2xx yok, limit gövdede.
- **INV-38, INV-39, X-24, API-42, API-9, TN-15, TN-16 (#1)** — Ortam yalnız anahtarda; çapraz kiracı/ortam erişimi reddi; uç listesinden negatif yalıtım testleri.
- **API-25** — Anahtarın kiracısı istekle ezilemez.
- **API-41, API-43, API-44, API-47, API-48, API-70, TN-24** — Anahtar modeli, kapsamlar, yaşam döngüsü, kimlik hataları, OAuth2 doğrulama.
- **E-3, X-34, API-64** — Ayrıcalıklı birinci taraf yolu yok; köprü URL'si yok.
- **E-27, E-63, X-4, X-5, TN-19, TN-21, TN-22, TN-23, TN-47, TN-48** — Roller Relay'de; yeniden doğrulama fail-closed; gevşetme yüksek yetki; operatör RLS'i atlayamaz; PII gösterimi ve aktör kimliği denetimde.
- **INV-42, TN-10** — Askıya alma bütün girişlerde aynı anda etkili.
- **INV-2 (`503`), TN-40 (kabul noktası), TN-41, TN-45** — Kill switch kabulde karar olarak kaydedilir, platform durdurmada `503`; kapsam yetkisi; API ve CLI aynı kaydı yazar.
- **API-49, API-50, API-51, TN-52, T-35** — Hız limiti başlıkları ve ağırlıkları, kota ≠ hız, kovalar ve `security` ek payı, girişte kabul kontrolü.
- **API-52** — Tarihli sürüm sabitleme ve geçersiz sürüm.
- **API-56** — İmleç imzalı ve kiracı kapsamlı.
- **INV-60, API-57, API-58, API-59** — İptal aynı sıralı anahtar, tombstone, yalnız sağlayıcıya gitmemiş teslimi durdurur.
- **API-63** — `test` düzleminde aynı hat, güvenliği zayıflatan bayrak yok.
- **OP-51** — Gönderim modu çözüm sırası; `off` kill switch yerine geçmez.
- **T-59** — Sürüm içinde yalnız ekleme; kırıcı fark kapısı.
- **INV-48, WF-5, WF-6, WF-7, X-10** — Yayınlanmış workflow sürümü değişmez, tanım veridir (çalışma anında müşteri koduna çağrı yok); geri dönüş yeni sürümdür; bildirim anında sürüm sabitlenir, sessiz yükseltme yok.

---

### Aşama 4 — Karar çekirdeği

Her teslim için "gönderilir mi, ne zaman, neden değil" kararını veren çekirdek: mesaj sınıfları ve kategoriler, kapı → filtre → zamanlayıcı kafesi, tercihler, izin ve bastırma kayıtları, sessiz saat, saat dilimi, frekans tavanı ve `reason` + `rule_id` kayıtları. A1 (defter, saklama sınıfları), A2 (kill switch, hız limiti) ve A3'e (kabul yolu, workflow iskeleti) dayanır.

#### Spec dışı ön koşullar
- [ ] **`rule_id` sözlüğünün somut kural kimlikleri** — DS-25 neden ailelerini verir; kimlik biçimi ve başlangıç kayıtları yok. (Adem kararı)

#### Sınıflar, gönderen türü ve kategoriler
- [ ] **Yedi mesaj sınıfı ve kabulde atanması** — `security` (`otp_oob`, `email_verification`), `action_required`, `transactional`, `operational`, `social`, `marketing`, `system`; workflow kategoriye, kategori tek sınıfa bağlı; sınıf kabul anında atanır ve değişmez; alt türü gönderen seçer; sınıf davranış tablosu (kapatılabilirlik, sessiz saat, digest, tavan, İYS kapsamı). _Kaynak:_ §1.7, §2.4.2, §5.4, §6.4, §9.5, §10.1, §13.1.1; MD-8, C-33, C-34, INV-16, F-11, PC-1, WF-2, API-20.
- [ ] **Gönderen türü alanı** — `human`/`system`/`agent` sınıftan ayrı alan; ajan kaynaklı = `agent`; sınıf, kategori ve gönderen türü bağımsız eksenler (ajan davranışı A12). _Kaynak:_ §1.7, §5.1, §5.3, §13.1.1, §17.14; MD-8, C-6, C-24, PC-2, AG-48, AG-34.
- [ ] **Kategori** — Kiracı tanımlı, tek sınıfa bağlı, kanaldan bağımsız; varsayılan rota, kanal başına gönderen kimliği, tercih varsayılanı, varsayılan `expires_at`, frekans politikası, saklama süresi, `locked` taşır; ayrı `reason` alanı ("neden sana"). _Kaynak:_ §5.4, §13.2; C-35, INV-20, PC-5.
- [ ] **Kilitli kategori** — `security` hep kilitli; kiracı yalnız `transactional/operational/action_required` kilitler, `marketing/social` kilitlenemez; kanal değil kategori kilitlenir, kilitli kategoride en az bir kanal açık kalır (son kanalı kapatma engellenir); kilit beyanı denetimde. _Kaynak:_ §5.4, §13.2.1, §13.3.5; C-35, INV-20, PC-6, PC-11.
- [ ] **Alt kiracı kategori mirası** — Alt kiracı varsayılanları miras alır, kendi ayarı ezer. _Kaynak:_ §13.2; PC-7.
- [ ] **Öncelik tavanı ve şerit** — Şerit yalnız sınıftan türer; `priority: low|normal|high` yalnız şerit içi ince ayar, başka şeride taşıyamaz; sınıf tavanını aşan değer indirilir, `priority_clamped` uyarısı döner ve kaydedilir; `priority` kanal SLA'sı değildir. _Kaynak:_ §1.7, §5.4, §9.5, §12.4.1; MD-8, C-36, INV-16, API-22, CH-19.
- [ ] **Alıcı kümesi üreticinindir; Relay yalnız kanal seçer** — Relay alıcı kümesini hesaplamaz; üreticinin verdiği küme (Access ve Work olayları dahil) genişletilmez ya da daraltılmaz; Relay her alıcı için yalnız kanal seçer; kapı sonucu teslim edilemeyen alıcı bir karar kaydıdır (INV-1), küme değişikliği değil. _Kaynak:_ §1.3, §1.7, §2.7, §7.1, §7.3.2, §7.4, §10.4; MD-2, F-11, E-12, E-41, WF-19.

#### Karar kafesi
- [ ] **Karar kafesi motoru (kapı → muafiyet → filtre → zamanlayıcı)** — Sıra kesin; her denemede ve `PAUSED`/ertelenmiş işte çalışma anında yeniden değerlendirme; kapılar (bastırma, ret, İYS yok, kill switch, ölü kanal, kapsam uyuşmazlığı, sınıf kanal kuralı) hiçbir bayrak, kategori, kilit, sınıf, öncelik, alan, ham payload override ya da operatör eylemiyle atlanamaz; kilit yalnız filtreleri atlar; `security` tercih ve sessiz saati deler, kapıyı delmez; kapı/filtre terminal. Diğer kapılar kendi aşamalarında takılır. _Kaynak:_ §1.7, §5.7, §6.4, §13.3.1–13.3.2; C-58, MD-14, INV-15, F-11, PC-8.
- [ ] **Kapı 1e: kanal teknik durumu** — Adres/token devre dışı, OS izni yok kapı olarak; kilitli kategoride kanal kapıdan geçemezse sessizce bırakılmaz (rotada sıradaki kanala geçiş A8'de). _Kaynak:_ §13.3.2, §13.3.4; PC-8, PC-10.
- [ ] **Fail-closed kapı girdisi** — Kapı girdisi okunamıyor/doğrulanamıyorsa gönderme; izin yokluğunda varsayılan gönderme. _Kaynak:_ §1.7, §6.8; MD-14, INV-43.
- [ ] **Fail-open yalnız frekans tavanı** — Frekans tavanı sayacı okunamazsa gönderim durmaz; başka hiçbir kural fail-open değildir. _Kaynak:_ §1.7, §6.8; INV-45, MD-14.
- [ ] **Tercih delme bayrağı yok** — Mesaj/workflow/istek düzeyinde `send_to_unsubscribed` benzeri bayrak yok; uyum kuralları gevşetilemez. _Kaynak:_ §13 kuralları, §13.3.5; PC-11.
- [ ] **Kapsam uyuşmazlığı atlaması** — Tanımsız, eşleşmeyen ya da kiracıya ait olmayan alt kiracıya giden teslim gönderilmez, `skipped` + `scope_mismatch` (kapı 1f); panelde, webhook olayında ve metrikte görünür. _Kaynak:_ §1.7, §5.2, §9.5, §10.4, §18.1.2; MD-18, C-12, API-25, WF-20, TN-5.

#### Karar kayıtları
- [ ] **Karar ≠ hata** — İzin yokluğu, tercih, sessiz saat, frekans, kill switch, İYS reddi API hatası değil; `202` sonrası `suppressed`/`skipped` + `decision` + `rule_id` + `detail` teslim kaydında ve `notification.suppressed` olayında; senkron karar yalnız önizleme/test/`dry_run`'da. _Kaynak:_ §9.8, §13 kuralları, §13.3.3, §14.5.1a; API-39, PC-9, DS-26.
- [ ] **Atlama kaydı (sessiz kayıp yok)** — Gönderilmeyen her bildirim/teslim (atlama, bastırma, süre dolumu, iptal, kill switch, kapsam uyuşmazlığı, İYS reddi, render hatası, tekrar, sessiz saatte düşürme) kuyrukta değil teslim tablosunda `reason` + `rule_id` ile satır açar; kayıtsız düşürme yolu yok; eşleşmeyen tetikleme de kaydedilir. _Kaynak:_ §1.7, §4.2, §4.3.1, §5.7, §6.1, §14.5.1, §20.1; MD-12, C-59, INV-1, L-11, L-31, F-11, MKT-6, DS-24, DS-1, OP-2 (engellenen hedef).
- [ ] **Tek `rule_id` sözlüğü** — Bütün atlama/erteleme/engelleme kararları sürümlü, sabit, belgelenmiş tek sözlükten, serbest metin yok; her kural `reason` ailesine ve bölümüne bağlı; ek alanlar (filtrede kapatan seviye `category_channel|workflow|scope_key|schedule|tenant`, izin/bastırma referansı, yerel saat vb.) `detail`'da. _Kaynak:_ §13.3.3, §14.5.2; PC-9, DS-25, DS-46.
- [ ] **Erteleme kaydı** — Sessiz saat, frekans `defer`, hız limiti, zaman penceresi ertelemesi defterde `deferred` (`reason`, `rule_id`, `deferred_until`); projeksiyon `queued` + `deferred_until`. _Kaynak:_ §14.5.3; DS-27.

#### Sınıf kuralları ve süre dolumu
- [ ] **Sınıf kanal kuralları** — `otp_oob` yalnız SMS/WhatsApp/sesli arama, fallback zinciri de e-postaya düşmez; `email_verification` yalnız e-posta; `security` yolundan ticari içerik gönderilmez. _Kaynak:_ §5.4, §6.4, §6.5; C-34, INV-23, INV-21, F-11.
- [ ] **OTP beklemez** — OTP alt türleri zamanlanmaz (doğrudan çalıştırılabilir iş), sessiz saatten geçer, digest'lenmez, geciktirilmez, collapse edilmez; yalnız gönderenin `expires_at`'i ile eskir. _Kaynak:_ §6.5, §10.10; INV-24, WF-40.
- [ ] **`expires_at` ve `expired`** — `security`/OTP'de zorunlu ve göndericiden; diğerlerinde kategori varsayılanı (6 sa / 24 sa / 48 sa / kampanya bitişi, PD); süresi geçen bildirim `expired` (terminal) + `rule_id`, sessizce silinmez. _Kaynak:_ §5.4, §13.9.3; C-39, PC-49.
- [ ] **`on_expire` ve Access semantik olayları** — Üreticinin "ne zamana kadar" alanı `expires_at`'e eşlenir; Access semantik olayları `security` sınıfında, digest/frekans/içerik dedup uygulanmaz, idempotency uygulanır; süresi geçmiş güvenlik bildiriminde `on_expire: drop|inbox_only`, varsayılan `drop`. _Kaynak:_ §7.3.2, §13.1.1; E-13, E-73, PC-1.
- [ ] **`transactional`/`operational` sınıflar rıza sormaz** — Bu iki sınıf için izin kontrolü/rıza adımı uygulanmaz; rıza yalnız ilgili sınıflarda istenir. _Kaynak:_ §8.7; X-21.

#### Tercihler
- [ ] **Bildirim tercihleri Relay'de kanonik** — Kategori × kanal, bildirim türü, sessiz saat ve digest seçimi Relay'in kanonik kaydıdır; izin ve tercih ayrı kayıtlardır. _Kaynak:_ §7.1, §7.3.4; E-17.
- [ ] **Dört seviyeli tercih** — Kategori × kanal, workflow/bildirim türü, `scope_key` ile nesne sessize alma (en spesifik kazanır), haftalık uygunluk programı (alıcı saat diliminde, teslim anında); çakışmada VE; genel kanal anahtarı; koşullu tercih yok; tanımsız tercih uydurulmaz, matriste tanımsız hücre yok; `security` ve kilitli kategoriler kapatılamaz. _Kaynak:_ §2.7, §5.7, §6.4, §6.8, §13.4.1; C-61, INV-20, INV-46, F-11, PC-12.
- [ ] **Tercih değeri ve sınıf varsayılan matrisi** — `opt_in|opt_out|unset`, `unset` kategori varsayılanına düşer; kiracı kategori × kanal matrisi yoksa sınıf matrisi (PD); `marketing` güvenli kapalı varsayılanla başlar (ülke/platform türetimi A11). _Kaynak:_ §13.4.2; PC-13, PC-14.
- [ ] **Kiracı adına tercih yalnız kapatma yönünde** — Kiracı kullanıcının `marketing` tercihini yalnız kapatma yönünde yazabilir; kiracı varsayılanı kullanıcı tercihi değildir; kullanıcı tercihi kiracı politikasını yalnız kısıtlar. _Kaynak:_ §6.4, §13.4.2; INV-17, PC-15.
- [ ] **Tercih hesaba bağlı tek kayıt** — Cihaz/çerez değil; OS izni ve token silinmesi tercihi silmez. _Kaynak:_ §13.4.3; PC-16.
- [ ] **Digest seçimi tercih değeri** — `social` ve izinli `operational` kategorilerinde anında/özet tercih değeri. _Kaynak:_ §13.4.1; PC-17.

#### İzin ve bastırma
- [ ] **İzin kaydı (Relay'in kendi)** — Access bağlı değilse pazarlama izni Relay'in kaydında; anahtar `(marka, kanal, alıcı)`, çapraz marka yok; append-only; kanıtsız onay yazılamaz (kaynak, zaman, kanal, onay metni sürüm özeti, IP/cihaz, İYS işlem kimliği); onay metni değişmez ve sürümlü; izin ve tercih ayrı kayıt, birbirine dönüşmez; izin hizmet koşulu yapılamaz. _Kaynak:_ §5.1, §5.7, §6.4, §6.7, §6.9, §7.1, §7.3.4, §13.5.1; C-5, C-60, INV-18, INV-40, INV-49, E-18, PC-20.
- [ ] **İzin durumları ve güvenli birleştirme** — `NONE|PENDING|ACTIVE|REVOKED|EXPIRED`, `NONE ≠ REVOKED`; herhangi bir kaynakta RET → RET. _Kaynak:_ §13.5.1; PC-21.
- [ ] **Ret anında uygulanır** — Ret alındığı an sonraki gönderimleri durdurur; yalnız yeni açık onayla kalkar; tercihi açmak onay sayılmaz. _Kaynak:_ §6.4; INV-18.
- [ ] **Rıza türü ve alıcı türü alanları** — `explicit_opt_in|soft_opt_in|legitimate_interest|none`; `individual|merchant`. _Kaynak:_ §13.5.3; PC-23, PC-24.
- [ ] **Ticari ileti onay/gönderim kayıtları saklama sınıfı** — Ayrı saklama sınıfı, TR'de 10 yıl; Access OP-74/Ek C'ye tabi; özne silmesinde yasal kanıt ayrı ve en az veriyle tutulur. _Kaynak:_ §13.5.4; PC-25.
- [ ] **Bastırma kaydı** — Adres/cihaz düzeyinde kiracı kaydı (hard bounce, şikâyet, geçersiz, tekrarlı soft bounce, manuel); kalıcı neden süre almaz; tanımlayıcının anahtarlı özeti olarak tutulur, yalnız bastırma kontrolünde kullanılır, özne silmesinde imha edilmez. _Kaynak:_ §5.3, §5.7, §6.9, §20.4; C-62, INV-49, OP-20.
- [ ] **E-posta bastırması** — Hard bounce ve şikâyet anında süresiz; soft bounce pencerede N denemeden sonra süreli (72 saatte 3, PD); kalıcı bounce süreli olamaz; kiracı bazlı; anahtarlı özet, crypto-shredding'de imha edilmez; bastırılmışa gönderim denenmez, `suppressed` + `rule_id`. _Kaynak:_ §12.6.6; CH-40.

#### Zamanlama
- [ ] **Saat dilimi çözümü** — IANA saat dilimi; zincir açık seçim → cihaz → profil ülkesi → zorunlu kiracı varsayılanı; sistem varsayılanı yok; hesap yalnız uygulama katmanında. _Kaynak:_ §5.6, §10.10; C-57, C-11, WF-45, WF-47.
- [ ] **Kullanıcı sessiz saati** — Gün × saat aralığı alıcı saat diliminde, yasal pencereden ayrı; varsayılan yalnız anında kesen kanallar (push, SMS, ses, WhatsApp, mesajlaşma), e-posta ve inbox hariç (inbox kaydı anında), kullanıcı e-postayı kanal bazında dahil edebilir; `security`/`action_required` deler. _Kaynak:_ §1.7, §5.7, §8.7, §13.9.1; C-63, MD-8, X-18, PC-45.
- [ ] **Sonlu erteleme** — Ertelenen teslim çalışma anında yeniden değerlendirilir, sessiz saatte asla teslim edilmez; uygun an `expires_at` öncesinde yoksa `expired`; "1 saat ekle" döngüsü yok; saat dilimi değişikliği olaydır. _Kaynak:_ §13.9.1; PC-46.
- [ ] **Kiracı varsayılan saat diliminde 10:00–18:00 sınırı** — Saat dilimi kiracı varsayılanından geldiyse `marketing`/`social` 10:00–18:00 ile sınırlanır, raporda ayrı sayılır. _Kaynak:_ §13.9.2; PC-48.
- [ ] **Frekans tavanı** — Kategori × kanal kullanıcı başına politika, yalnız `marketing/social/operational`; zamanlayıcıdır, kapı değil; yalnız gönderilebilir teslim sayılır; global kullanıcı tavanı her zaman tanımlı (günde 12, PD), kiracı sıkılaştırır; kader `drop|defer|digest|inbox_only` politikada açık (digest A8, inbox_only A9 ile tamamlanır); throttle ve teslim hızından ayrı; sayaç okunamazsa fail-open + metrik + alarm. _Kaynak:_ §4.2, §4.3.1, §5.5, §13.9.4; C-50, L-10, L-49, PC-50.
- [ ] **Zamanlama kural sırası** — Sınıf geçişi → açık zamanlama → yerel saat → sessiz saat/yasal pencere → DND (`dnd_until`) → frekans tavanı → deterministik jitter → hız limiti; ertelenmiş iş kapıları çalışma anında yeniden değerlendirir; kafes kapıları hiçbir workflow ayarıyla atlanamaz. _Kaynak:_ §10.10, §10.14; WF-41.
- [ ] **Zamanlamada deterministik yayma** — Bütün yayma özet fonksiyonuyla (`özet(alıcı, yerel_saat) mod yayılım`), rastgele sayı yok; aynı dakikaya yığılan tekil zamanlanmış işlere de; `strict` açık seçimle; sessiz saat çıkışı jitter'lı. _Kaynak:_ §10.10; WF-42.

#### Bu aşamada doğrulanacak sınırlar
- **INV-16, PC-1, WF-2, API-22, CH-19** — Sınıf kabulde atanır, değişmez; şerit yalnız sınıftan; öncelik tavana indirilir.
- **AG-48** — Gönderen türü sınıftan ayrı alan.
- **INV-20, PC-6** — Kilitli kategori ve `security` kapatılamaz, son kanal kapatılamaz.
- **E-12, WF-19, INV-1** — Alıcı kümesi değiştirilmez; teslim edilemeyen alıcı karar kaydıdır.
- **INV-15, PC-8, PC-11, WF-41** — Kapılar hiçbir bayrak, kilit, workflow ayarı veya operatör eylemiyle atlanamaz; her denemede yeniden değerlendirme.
- **INV-43, INV-45** — Kapı girdisi fail-closed; yalnız frekans tavanı fail-open.
- **API-25, WF-20, TN-5** — Kapsam uyuşmazlığı `scope_mismatch` ile görünür atlanır.
- **API-39, PC-9, DS-26** — Karar ≠ hata; senkron karar yalnız önizleme/test/dry-run.
- **DS-24, DS-25, DS-27** — Sessiz kayıp yok; tek `rule_id` sözlüğü; erteleme `deferred` olarak defterde.
- **INV-21, INV-23** — Sınıf kanal kuralları; `security` yolundan ticari içerik yok.
- **INV-24, WF-40** — OTP zamanlanmaz, digest'lenmez, geciktirilmez.
- **PC-49, E-13, E-73** — `expires_at` dolunca `expired` + `rule_id`; `on_expire` varsayılanı `drop`.
- **X-21** — `transactional`/`operational` rıza sormaz.
- **INV-46, PC-12, PC-13, PC-15, INV-17, PC-16** — Tanımsız tercih uydurulmaz; VE mantığı; kiracı yalnız kapatma yönünde yazar; tercih hesaba bağlı.
- **INV-18, INV-49, E-18, PC-20, PC-21, OP-20** — Kanıtsız onay yok; `NONE ≠ REVOKED`; ret anında ve kalıcı; bastırma özeti silinmez.
- **CH-40** — hard bounce/şikâyet süresiz bastırılır, kalıcı bounce süreli olamaz; bastırılmışa gönderim denenmez.
- **PC-45, PC-46** — Sessiz saatte teslim yok; sonlu erteleme.
- **PC-50** — Frekans tavanı kuralları ve fail-open davranışı.
- **WF-42, WF-45** — Deterministik jitter; saat dilimi zinciri.

---

### Aşama 5 — Şablon ve render

Bildirimin içeriğini güvenli, ölçülü ve yerelleştirilmiş biçimde üreten katman: Liquid (Solid) motoru, şablon nesnesi ve kanal varyantları, değişken sözleşmesi, yerelleştirme, layout/marka/parçalar, sürüm sabitleme ve yayın kapısı, kanal başına render (SMS kodlama dahil), önizleme ve üretici sahipli şablonlar. A1 (saklama sınıfları, crypto-shredding), A3 (workflow iskeleti ve olay şeması, yönetim API kuralları) ve A4'e (sınıflar, kategoriler, `rule_id` sözlüğü) dayanır.

#### Spec dışı ön koşullar
- [ ] **Daraltılmış Solid etiket listesi ve tam filtre seti** — TP-4 "daraltılmış etiket seti" ve "vb." ile filtre listesi verir; izinli etiketlerin ve filtrelerin tam listesi yok. (Adem kararı)
- [ ] **Hassas terim sözlüğü içeriği** — TP-21 TR + EN sözlük ister; yalnız örnek terimler var. (Adem kararı)
- [ ] **Maskeli gerçek olay örneklemi için N** — TP-38 "son N gerçek olay" der; N tanımsız. (Adem kararı)

#### Şablon motoru ve güvenli render
- [ ] **Tek şablon motoru: Liquid (Solid)** — Kiracı ve sistem şablonları kod çalıştırmayan Solid ile; Elixir kodu çalıştıran şablon dili yok; EEx/HEEx yalnız derleme zamanı kodunda, kiracı verisi EEx'e girmez; yerelleştirme ex_cldr + ICU MessageFormat. _Kaynak:_ §1.7, §4.2, §11.2, §19.10; MD-16, L-29, F-11, TP-2, T-51 (madde 3, 4 ex_cldr).
- [ ] **Daraltılmış şablon dili** — `include`/`render` yok, dosya sistemi verilmez; daraltılmış etiket seti; Relay filtre seti (`sms_safe`, `plural`, `number`, `currency`, `datetime` …); `strict_variables`, `strict_filters`. _Kaynak:_ §11.2; TP-4.
- [ ] **İzin listeli şablon bağlamı** — Yalnız olay verisi, şemada beyan edilmiş alıcı öznitelikleri, marka değişkenleri, render yardımcıları; iç yapılar/kiracı kimliği/sırlar giremez; derinlik ≤ 5; dizi indeksi uzunluk kontrollü. _Kaynak:_ §11.2; TP-5.
- [ ] **Statik şablon limitleri** — Yayında: kaynak ≤ 256 KB, ≤ 10 döngü, iç içe döngü derinliği ≤ 2, ≤ 5.000 düğüm. _Kaynak:_ §11.2; TP-6.
- [ ] **Zaman ve bellek sınırlı izole render** — Her render ayrı süreçte; e-posta 50 ms, diğer 10 ms (ayarlanabilir); bellek ve çıktı sınırlı; her çıktı ölçülür (uzunluk, kodlama, segment, bayt, eksik değişken, boş blok) ve bildirim kaydına yazılır. _Kaynak:_ §4.2, §11.2; L-29, TP-7.
- [ ] **Kanal tipine göre kaçış ve ham HTML** — Render kanal tipini zorunlu alır, aynı bağlam iki kanala verilmez; e-posta HTML entity, düz metin CR/LF ayıklama, push/webhook JSON, inbox yapılandırılmış alan; `raw_html` tipi (kurumsal) ve `| raw` şablon düzeyi izin bayrağı ister. _Kaynak:_ §11.5; TP-24.
- [ ] **MJML yalnız yayında** — MJML önce, Liquid sonra; derlenmemiş sürüm yayımlanamaz; MJML derleyici NIF'i başlangıç izinli NIF listesinin tek üyesi, yalnız yayın anında çalışır, gönderim yolunda derleme ve NIF yok. _Kaynak:_ §11.2, §19.11; TP-8, T-53 (madde 4).

#### Şablon nesnesi ve tipler
- [ ] **Şablon nesnesi** — Kanal × locale matrisi, sürümlü; sahip kiracı/alt kiracı/üretici; tip kategori sınıfıyla uyumlu olmak zorunda; Relay'in kendi metinleri aynı motoru kullanan sistem şablonları. _Kaynak:_ §11.1; TP-1.
- [ ] **İşlemsel/pazarlama tip ayrımı ve promosyon sızma yasağı** — `transactional` ve `marketing` tipleri birbirine dönüştürülemez, sınıf yayından sonra değişmez; işlemsel/operasyonel şablona promosyon bloğu, indirim kodu, kampanya çağrısı ve zorunlu yasal alt bilgisi eksik ticari şablon yayın kapısında reddedilir. _Kaynak:_ §1.7, §5.6, §6.4, §11.3, §13.1.2; MD-8, C-54, INV-21, TP-12, PC-3.
- [ ] **Şablon/layout/parça yönetim uçları** — Ortak API kurallarına uyar; dosya biçimiyle aynı tanımı kabul eder. _Kaynak:_ §9.16; API-69.

#### Kanal varyantları
- [ ] **Omurga + kanal katmanı varyant modeli** — Ortak (şema, varsayılan locale, kategori, hassasiyet, layout), locale, SMS, push, e-posta, WhatsApp, inbox, webhook (kısıtlı JSON gövde) katmanları. _Kaynak:_ §11.3; TP-9.
- [ ] **Kanal başına içerik** — İçerik kanaldan kanala otomatik türetilmez; tutarlılık şemadan gelir. _Kaynak:_ §11.3; TP-10.
- [ ] **Eksik varyant davranışı** — Kanal varyantı yoksa o kanala gönderilmez + `rule_id` ("boş push" yok), `single` rotada sıradakine geçilir; alıcının dil zincirinde hiç varyant yoksa gönderim durur. _Kaynak:_ §5.6, §10.4, §11.3; C-54, TP-11, WF-16.

#### Değişken sözleşmesi
- [ ] **Şablon değişkenlerinin şemaya karşı doğrulanması** — Yayında şablon değişkenleri workflow sürümünün JSON Schema 2020-12 şemasına, render'da veriye karşı doğrulanır. _Kaynak:_ §10.1, §11.4; TP-13, WF-1.
- [ ] **Değişken kritiklik sınıfları** — `required` (varsayılan; yoksa gönderim durur, retry yok, `render_failed`), `fallback` (tanımlı varsayılan, sayılır), `optional` (koşul bloğunda zorunlu, blok atlanır), `decorative`; beyan edilmemiş değişken yayında reddedilir. _Kaynak:_ §11.4; TP-14.
- [ ] **Değişken tip kuralları** — Para string tutar + para birimi; `date-time` ISO 8601 UTC; boolean; büyük sayılarda `maximum`; zorunlu dizilerde `minItems: 1`; önceden biçimlendirilmiş değer yok, biçimlendirme render'da alıcı locale'inde. _Kaynak:_ §11.4; TP-16.
- [ ] **En kötü durum uzunluğu** — String alanlarda `maxLength` zorunlu; yayında en kötü durum uzunluğu kanal limitleriyle (SMS segment/maliyet, push 1024, WhatsApp 1024/60/60/25, e-posta boyutu) karşılaştırılır. _Kaynak:_ §11.4; TP-15.
- [ ] **Şema evrimi ve değişken kullanım dizini** — Yeni isteğe bağlı alan serbest; yeni zorunlu/tip değişikliği yeni şema sürümü; kullanılan alan kaldırılamaz; `maxLength` daraltma uyarı + geçiş süresi; okunan değişken yolları statik çıkarılır ("her zaman"/"koşullu") ve dizinlenir. _Kaynak:_ §11.4; TP-17.

#### Yerelleştirme
- [ ] **Locale çözümü** — BCP 47; profil → cihaz → (yalnız inbox/web) `Accept-Language` → kiracı varsayılanı; ana gönderim yolunda `Accept-Language` yok. _Kaynak:_ §11.6; TP-25.
- [ ] **Locale fallback zinciri** — `tr-TR` → `tr` → kiracı varsayılanı, sistem varsayılanı yok; hiç varyant yoksa dur + `rule_id`; varsayılana düşüş `template_locale_missing` sayılır ve kiracıya gösterilir; çeviri anahtarı/boş dize asla gösterilmez. _Kaynak:_ §4.3.1, §5.6, §11.6; L-51, C-57, TP-26.
- [ ] **ICU MessageFormat ve CLDR biçimlendirme** — Klasik ICU sözdizimi; CLDR çoğul (≤ 6 kategori), `=0` açık eşleşme; Gettext çoğulu yok; sayı/para/tarih/saat render anında alıcı locale ve saat diliminde CLDR ile. _Kaynak:_ §11.6; TP-27.
- [ ] **Yapılandırılmış tutar ve kilit ekranı hassas veri kuralı** — Finansal olaylarda tutarlar `{amount, currency}` olarak gelir ve şablon yerelleştirir (ICU/CLDR); kilit ekranında hassas veri gösterilmemesi kuralı finansal bildirimlere de uygulanır. _Kaynak:_ §7.8; E-60.
- [ ] **Türkçe harf kuralları** — Büyük/küçük harf filtreleri locale duyarlı; `tr`'de İ/i, I/ı. _Kaynak:_ §11.6; TP-28.
- [ ] **RTL yön izolasyonu** — RTL locale'de değişkenler U+2068…U+2069 ile sarılır (push, e-posta, inbox, WhatsApp; SMS hariç); e-postada `dir="rtl"`, inbox payload'ında `locale` ve `dir`. _Kaynak:_ §11.6; TP-29.
- [ ] **Kiracı şablon çeviri matrisi** — Eksik hücreler görünür; makine çevirisi `machine_translated` taslak, insan onayı olmadan yayımlanmaz; yer tutucular korunur, locale'ler arası değişken kümesi farkı yayını engeller; eksik çeviri yayını kilitlemez; çeviri birimi cümle, dize birleştirme yasak; kiracı şablonu dış TMS'e itilmez. _Kaynak:_ §11.6; TP-30.

#### Layout, marka ve üretici şablonları
- [ ] **Layout, marka ve parçalar** — Kiracı/alt kiracı başına sürümlü layout; `brand.*` tek yerde; tek seviyeli adlandırılmış sürümlü parçalar (parça parça çağıramaz), serbest `include` yok; layout ve parçalar paylaşılır; sürümler gönderim başında sabitlenir. _Kaynak:_ §4.3.1, §5.6, §11.8; C-56, L-52, TP-35.
- [ ] **Alt kiracı mirası** — Marka, layout ve şablon varyantı için "yoksa üsttekini kullan, varsa ez". _Kaynak:_ §11.8; TP-36.
- [ ] **Üretici sahipli (korunan) şablonlar** — Üretici şablonunu API ile yayımlar; metin ve çeviri üreticinin, kiracı yalnız izinli marka alanlarını (logo, renk, gönderen adı, altbilgi) değiştirir; kanal render'ı Relay'in; yayın kapısından geçer, yeni sürüm kiracı markasını korur; mekanizma her üreticiye açıktır. _Kaynak:_ §5.6, §7.2, §7.3.11, §11.9; C-55, E-3, E-35, TP-37.

#### Kanal başına render
- [ ] **SMS kodlama politikası ve segment hesabı** — Şablon başına `transliterate`/`turkish_shift`/`ucs2` (vars. `turkish_shift`); sağlayıcı kataloğunda `turkish_single_shift` `verified`/`unverified`, doğrulanmamışa `ucs2`; kodlama sağlayıcıya açıkça verilir; muhafazakâr, septet bazlı, sağlayıcıdan bağımsız segment hesabı (GSM-7 160/153, `GSM7_TR` 155/149, UCS-2 70/67, çift septetli karakterler, başlıklı TR SMS önek kaybı); yayında/önizlemede "N segment, kodlama X", UCS-2'ye düşüren karakterlere uyarı ve isteğe bağlı normalize. _Kaynak:_ §4.5, §11.5, §12.7.1; TP-18, CH-48.
- [ ] **SMS transliterasyon politikası** — OTP/`security` transliterasyon yapılır; yasal zorunlu metin yapılmaz; diğerlerinde şablon bayrağı, varsayılan kapalı. _Kaynak:_ §12.7.2; CH-49.
- [ ] **SMS içerik kuralları** — Şablonda emoji yasak, değişkende bayraklanır, segment yeniden hesaplanır, politikaya göre ayıklanır/kabul edilir; yasal metin düzenlenemez alt bölümde, transliterasyonsuz, bütçeden önce ayrılır; kontrol, sıfır genişlik ve U+202A–U+202E ayıklanır. _Kaynak:_ §11.5; TP-19.
- [ ] **Push render** — Sunucuda düz `title`/`body`; `loc-key` yalnız açık istekle; payload yalnız JSON kodlayıcıyla; bayt ölçümü (APNs 4096) aşarsa red; geçersiz UTF-8 ayıklanır ve kaydedilir; en kötü durumda 1024 karakteri aşabilecek varyant yayımlanamaz. _Kaynak:_ §11.5; TP-20.
- [ ] **Hassasiyet sınıfı** — Zorunlu `public`/`personal`/`sensitive`; `sensitive`'de push `lock_screen_body` nötr + `in_app_body`; yayın kapısında hassas terim sözlüğü (TR+EN) taraması, eşleşmede açık onay. _Kaynak:_ §11.5; TP-21.
- [ ] **E-posta render** — Konu, ön başlık, HTML, zorunlu ayrı düz metin; konu değişken uzunluğu denetimi, CR/LF kaldırma, encoded-word; HTML 70 KB uyarı / 90 KB ret (enjeksiyondan sonra yeniden ölçüm); `color-scheme` meta; AMP yok. _Kaynak:_ §11.5; TP-22.
- [ ] **WhatsApp parametre temizleyici** — Satır sonu/sekme → boşluk, 4+ boşluk → 3, grafem bazında kırpma; her değişiklik kaydedilir. _Kaynak:_ §11.5; TP-23.
- [ ] **Sanitizer kaydı** — İçeriği değiştiren her temizleme (geçersiz UTF-8, kanal sanitizer'ı) kaydedilir; sessiz düzeltme yok. _Kaynak:_ §6.1; INV-1.

#### Sürümler ve yayın kapısı
- [ ] **Değişmez şablon sürümleri** — Yayımlanmış sürüm değişmez; monoton sürüm + `checksum`; `draft` → `published` → `archived`; değişkenler yayında olay şemasına karşı doğrulanır; dönüş canlı işaretçiyi değiştirir, öncesinde şema uyumu yeniden doğrulanır; yayın/dönüş `published_by`, zaman, `checksum`, fark ile denetimde. _Kaynak:_ §5.6, §6.9, §11.7; C-54, INV-48, TP-31.
- [ ] **Yayın kapısı** — Sert kapılar (ayrıştırma/limit, şema uyumu, düz metin, MJML, hassasiyet onayı, push 1024/4096, sızma, yasal altbilgi) ve uyarı kapıları (locale değişken tutarlılığı, en kötü durum uzunlukları, lint) "uyarıyla yayımla" + kayıt; en kötü durum önizlemesi zorunlu gösterilir. _Kaynak:_ §11.7; TP-32.
- [ ] **Erişilebilirlik ve içerik lint'i** — `lang`, alt metin, salt görsel uyarısı, düz metin, kontrast, anlam ilk satırda, kilit ekranında hassas veri yok; uyarı düzeyi. _Kaynak:_ §11.7; TP-34.

#### Sabitlenmiş plan, saklama ve render hataları
- [ ] **Sabitlenmiş plan** — Bildirim oluşurken şablon/layout/parça sürümleri, adres çözümü, deney varyantı ve `dedup_key` donar; kapılar her denemede yeniden; sabit sürüm gönderilemezse sessizce yeni sürüme geçilmez; gönderilmiş içerik sonradan etkilenmez. _Kaynak:_ §4.2, §5.5, §6.9; C-46, L-3, INV-48.
- [ ] **Render içerik saklama ve OTP istisnası** — Bildirim kaydı şablon sürüm kimliğini kalıcı taşır; içerik anlık görüntüsü saklama sınıfına göre, özne anahtarıyla şifreli (crypto-shredding); OTP/doğrulama alt türlerinde render içeriği hiç saklanmaz (özet + şablon sürümü); diğer sınıflarda mesaj başına `retention: none` (`security` dışı, in-app ile birleşimi doğrulama hatası); içeriksiz mesaj da defter ve kanıt alanlarına girer. _Kaynak:_ §6.5, §9.5, §11.11, §20.4; INV-26, TP-40, API-26, OP-23.
- [ ] **Gürültülü render hataları ve ayrı olay** — Render hatası atlama değildir: eksik zorunlu değişken gönderimi durdurur, retry edilmez; kanal limitini aşan çıktı kesilmez, reddedilir; `notification.render_failed` + `failure_reason: missing_variable | render_timeout | output_too_large | schema_violation`; kiracıya toplu görünür, yalnız iç log yetmez. _Kaynak:_ §6.8, §11.11, §14.5.2/3; INV-46, TP-41, DS-25.

#### Önizleme
- [ ] **Yalıtılmış önizleme (kanal başına)** — Her kanal için render önizlemesi, SMS segment sayısı ve kodlaması, e-posta HTML + düz metin; ayrı origin + CSP + iframe `sandbox`; önizleme ucu senkron hata dönebilir. _Kaynak:_ §4.2, §5.1, §8.5; L-29, C-4.
- [ ] **Anlık önizleme ve örnek veri kaynakları** — Her değişiklikte render; örnek veri: şema `examples` → son N gerçek olay (kişisel veri gerçek uzunlukta maskeli) → otomatik sınır değerler (`maxLength`, boş dize, `minItems`/`maxItems`, `minimum`/`maximum`, Türkçe karakter, emoji, RTL). _Kaynak:_ §11.10; TP-38.
- [ ] **Önizleme uçları** — `POST /v1/workflows/{key}/preview`, `/v1/templates/{key}/preview` senkron 200: adım başına `would_send`, `rule_id`, render, uyarılar (`missing_variable`), SMS `encoding`/`segments`/`characters`; taslak veya yayın sürümü. _Kaynak:_ §9.14; API-60.
- [ ] **`relay preview` komutu** — Yerel veriyle workflow/şablon render önizlemesi CLI'dan. _Kaynak:_ §8.11; X-33.

#### Bağımlılık sabitleme
- [ ] **Golden-file regresyonu** — Motor, MJML derleyici, CLDR, tzdata ve filtre modülü pinli; yükseltmede beklenmeyen golden fark yükseltmeyi durdurur. _Kaynak:_ §11.12; TP-42.
- [ ] **CLDR ısıtma** — CLDR verisi açılışta ısıtılır; ilk gönderim soğuk yükleme yüzünden zaman aşımına düşmez. _Kaynak:_ §11.12; TP-43.

#### Bu aşamada doğrulanacak sınırlar
- **TP-1, TP-2, T-51 (3)** — Tek motor; kod çalıştıran şablon dili yok; kiracı verisi EEx'e girmez.
- **TP-4, TP-5, TP-6, TP-7, TP-8, TP-24** — Daraltılmış dil, izin listeli bağlam, statik limitler, süre sınırlı izole render, MJML yalnız yayında, kanal tipine göre kaçış.
- **INV-21, TP-12, PC-3** — Tip dönüştürülemez; promosyon sızması ve eksik yasal altbilgi yayında reddedilir.
- **TP-11, WF-16** — Eksik kanal varyantında gönderim yok + `rule_id`.
- **TP-13, TP-14, TP-15, TP-16, TP-17** — Şema doğrulaması, kritiklik sınıfları, en kötü durum uzunluğu, tip kuralları, şema evrimi.
- **TP-25, TP-26, TP-27, TP-28, TP-29, TP-30** — Locale çözümü ve fallback, çeviri anahtarı gösterilmez, ICU/CLDR, Türkçe harf, RTL, çeviri matrisi kuralları.
- **E-35, TP-35, TP-36, TP-37** — Parça parça çağıramaz; miras; üretici metnini kiracı değiştiremez.
- **E-60** — Tutar yapılandırılmış gelir, kilit ekranında hassas veri yok.
- **TP-18, TP-19, TP-20, TP-21, TP-22, TP-23, CH-48, CH-49** — SMS kodlama/segment, SMS içerik, push bayt sınırı, hassasiyet, e-posta, WhatsApp temizleyici, transliterasyon.
- **INV-1** — İçeriği değiştiren her temizleme kaydedilir.
- **INV-48, TP-31, TP-32** — Yayımlanmış sürüm değişmez, sabit sürümden sessiz geçiş yok; yayın kapıları.
- **INV-26, TP-40, API-26, OP-23** — OTP içeriği saklanmaz; içerik crypto-shredding ile şifreli; `retention: none` kuralları.
- **INV-46, TP-41** — Render hatası gürültülü, retry yok, ayrı olay.
- **API-60** — Önizleme ucu senkron karar ve render çıktısı.
- **TP-42** — Beklenmeyen golden fark yükseltmeyi durdurur.

---

### Aşama 6 — Kanallar ve sağlayıcılar

Karar çekirdeğinin (A4) ve render'ın (A5) ürettiği mesajı gerçek taşıyıcılara (push, e-posta, SMS, WhatsApp, mesajlaşma, ses) güvenli, idempotent ve doğrulanmış rotalarla ulaştırmak; her adaptör kanal kanıt tablosu satırları ve test vektörleriyle devreye alınır. A1 (defter, outbox, sır portu), A2 (devre kesici, retry/backoff, hız limiti, şeritler), A3 (API, test düzlemi, workflow iskeleti), A4 (bastırma kaydı, kanal kapıları) ve A5'e dayanır.

#### Spec dışı ön koşullar
- [ ] **Kanal kanıt tablosunun başlangıç verisi** — DS-10/DS-11 her sağlayıcı kodu için satır + test vektörü ister; sağlayıcı bazlı satırlar ve vektörler spec'te yok, adaptör başına derlenip sözleşme olarak onaylanmalı.
- [ ] **Sahte sağlayıcı adres→sonuç tablosunun içeriği** — X-26 tablonun kodla aynı kaynaktan yayımlanmasını istiyor; spec yalnız örnek sonuçlar veriyor, adres kalıpları ve tam liste yok. (Adem kararı)
- [ ] **`send_mode` kurulum varsayılanı** — API-62 çözüm zincirinin sonu "kurulum varsayılanı"; değer yazılı değil. (Adem kararı)
- [ ] **Abone başına aktif cihaz üst sınırı** — API-67 POLICY DEFAULT, değer yok. (Adem kararı)
- [ ] **SMS Türkçe single shift doğrulaması ve BTK önek kuralı** — CH-48: sağlayıcı desteği ölçülmedi, BTK DK-YED/211 birincil kaynaktan alınamadı; `turkish_single_shift` başlangıç değerleri ve önek kaybı kuralı için gerekli. (Adem kararı)
- [ ] **`email_verification` onay sayfasının sahibi** — CH-44/PC-51 "GET yalnız onay sayfası, durum POST" der; sayfayı Access mi Relay mi barındırır, spec sessiz. (Adem kararı)
- [ ] **Gerçek DSN/ARF test vektörü derlemi** — CH-39 gerçek bounce/şikâyet vektörleri ister; kaynak/derlem spec'te yok.
- [ ] **Platform test cihazı ölçüm düzeni** — CH-19 öncelik tablosu hücreleri test cihazlarında ölçülerek kesinleşecek (EA); cihaz seti ve ölçüm yöntemi tanımlı değil.

#### Kanal kataloğu ve adaptör sözleşmesi
- [ ] **Kanal kataloğu ve kanal kümesi** — Kanal kod adları (`push`, `email`, `sms`, `whatsapp`, `voice`, `in_app`, `webhook`, mesajlaşma) ve yetenek bayrakları; push (APNs, FCM HTTP v1, HMS, UnifiedPush), Web Push, e-posta (ESP + kendi MTA), SMS, ses, WhatsApp, Slack/Teams/Telegram/Discord. Fallback (kanal değişimi) ile failover (aynı kanalda sağlayıcı) ayrı kavramlardır; yeni kanal yalnız port beyanlarıyla eklenir. _Kaynak:_ §2.2, §5.5, §12.1.1; C-43, CH-1.
- [ ] **Ortak adaptör portu, zorunlu beyanlar ve veri sözlükleri** — Relay taşımayı kullanır, yerine geçmez. Yetenek bayrakları, `channel_event_evidence`, `provider_idempotency_policy`, hata eşleme tablosu + test vektörleri, fiyat/limit, veri yerleşimi ve gelen webhook doğrulama beyanı referans tablolarında sürümlü veridir; beyanı eksik adaptör kayıtlı görünür ama trafik almaz. _Kaynak:_ §4.5, §5.5, §12.1.2, §20.1; C-44, CH-2, OP-1 (sözlükler satırı).
- [ ] **Sağlayıcı idempotency beyanı ve belirsiz sonuç politikası** — `provider_idempotency_policy` olmayan adaptör devreye alınmaz; bağlantı kurulamadıysa retry, istek gidip yanıt yoksa sağlayıcı idempotency anahtarıyla ya da beyanlı politikayla (`wait_and_query`, `retry_accepting_duplicate_risk`, `no_auto_retry`). Retry kanıta dayanır, "sağlayıcıya gönderildi" outbox'ta; durum ucu yoksa sonuç `unknown`, ücretli kanalda ≤ 1 retry + `delivery_uncertain`, kör ikinci gönderim yok; anahtar mantıksal gönderim boyunca sabit. _Kaynak:_ §6.2, §6.3, §12.2.4, §19.6.5; INV-9, INV-13, CH-10, T-28, OP-6 (madde 4).
- [ ] **İnce adaptör yapım kuralları** — SMS/WhatsApp/mesajlaşma/İYS adaptörleri Req/Finch üzerinde ince ve test vektörlü; resmî SDK ve bakımsız istemci kütüphanesi yok. Gelen imza doğrulaması Relay kodu (Standard Webhooks ortak doğrulayıcı), ham gövdede, ayrıştırmadan önce, sabit zamanlı. _Kaynak:_ §12.1.3, §19.8; CH-3, T-40.
- [ ] **Adaptör sürümlemesi ve kullanımdan kaldırma uyarısı** — Slack/Teams dahil adaptörler sürümlü; sağlayıcı API'si kalkınca panelde kiracıya uyarı. _Kaynak:_ §4.5, §12.1.3; CH-4.
- [ ] **Self-host'ta hesapsız çekirdek kanallar** — Genel SMTP, Web Push/VAPID ve in-app çekirdekle gelir; diğerleri kiracının kimlik bilgisiyle; iOS'ta APNs dışı yol olmadığı belgelenir. _Kaynak:_ §12.1.1, §12.1.4; CH-5.

#### Kanal kanıt tablosu ve devreye alma kapısı
- [ ] **Kanal kanıt tablosu `channel_event_evidence`: şema ve kanal başına satırlar** — Kanal × olay kodu için `effect_kind`, `sets_delivery`, `sets_failure`, `attempt_effect`, `after_delivered`, `projection_effect`, `side_effect` (cihaz pasifleştirme, bastırma ekleme), `scope`, `decision_grade`; tanımsız olay kodu reddedilir. _Kaynak:_ §12.1.2, §14.2.1; DS-10, DS-46, CH-2.
- [ ] **Kanal teslim semantiği tablosu** — E-posta, SMS, WhatsApp, push, in-app, webhook, sesli arama için `sent`/`delivered`/etkileşim/karar sinyali normatif tablosu veri olarak; müşteri dokümantasyonu buradan üretilir; tablosuz kanal devreye girmez. _Kaynak:_ §1.4, §14.2.3; INV-5, DS-12.
- [ ] **Adaptör kanıt sözleşmesi kapısı** — Kanıt satırları + her sağlayıcı kodu için test vektörü + sağlayıcı idempotency beyanı olmadan adaptör devreye alınmaz (CI/kayıt kapısı). _Kaynak:_ §12.1.2, §14.2.2; DS-11, CH-2.

#### Sağlayıcı bağlantısı, kimlikler ve sırlar
- [ ] **Sağlayıcı bağlantısı ve doğrulama** — Paylaşılan ya da kiracının kendi hesabı; kimlik referansı, doğrulama, veri yerleşimi, sağlık; yalnız doğrulanmış bağlantıya trafik. _Kaynak:_ §1.7, §5.5, §6.8; C-45, INV-43, MD-4.
- [ ] **Gönderici ve kanal kimlikleri** — Gönderici kimliği (alan adı/adres, SMS başlığı, WA numarası) tip/ülke/onay durumlu, onaysızla gönderim yok; kanal kimliği (Apple team/bundle, Firebase, uygulama başına VAPID) sır arka ucunda. _Kaynak:_ §5.3; C-25, C-26.
- [ ] **Veri yerleşimi ve "yalnız yurt içi" politikası** — Sağlayıcı kaydı işleme ülkesi, aktarım dayanağı, SCC bildirim tarihini taşır; panelde "yurt dışına veri gönderir" uyarısı, etkinleştirme denetimde; "yalnız yurt içi" politikasında yurt dışı sağlayıcı listede görünür ama doğrulanmış rotaya girmez. _Kaynak:_ §12.1.4, §18.8; CH-6, TN-58, TN-47.
- [ ] **KMS/HSM'de sağlayıcı imzası** — APNs `.p8`, VAPID, FCM servis hesabı anahtarları uygulama belleğine girmez, KMS/HSM'de imzalanır; DER ECDSA → 64 baytlık `R‖S` dönüştürücüsü kısa-R/kısa-S test vektörleriyle. _Kaynak:_ §18.4.2; TN-28, TN-35.
- [ ] **Sağlayıcı sırrı sıcak rotasyonu** — Sır/anahtar rotasyonu ve sağlayıcı hesabı ekleme/silme step-up ister, denetime girer, süreç yeniden başlatılmadan uygulanır. _Kaynak:_ §18.4.1; TN-26, TN-21, TN-47.
- [ ] **Gelen webhook doğrulaması ve giden TLS** — Sağlayıcı şemasıyla (HMAC/Ed25519/JWT) ham bayt üzerinde, sabit zamanlı, zaman damgası toleranslı doğrulama; TLS 1.2+ (tercihen 1.3), giden bağlantıda sertifika doğrulaması kapatılamaz, kök sertifika değişiklikleri izlenir. _Kaynak:_ §18.10, §19.8; TN-35, T-43 (giden).

#### Test düzlemi ve gönderim modları
- [ ] **Sahte sağlayıcı adaptörü** — Test düzleminde bütün hat (doğrulama, idempotency, tercihler, İYS, rota, şablon, kill switch) aynı kodla çalışır; yalnız son adımda sahte adaptör devreye girer; test ve canlı aynı `rule_id`'leri üretir. _Kaynak:_ §8.9, §9.14, §18.1.3; X-25, API-63, TN-7.
- [ ] **Sahte sağlayıcı sonuç tablosu** — Belirli adreslere belirli sonuçlar (hard bounce, teslim edilmedi, gecikmeli teslim, APNs 410, hız sınırı …); adres→sonuç tablosu kodla aynı kaynaktan yayımlanır. _Kaynak:_ §8.9; X-26.
- [ ] **`send_mode`** — `live`/`shadow` (son adımda gönderilmez, doğrulanır ve kaydedilir)/`dry_run` (karar + render senkron, kuyruk/teslim kaydı yok)/`off` (`skipped` + `send_mode_off`); `(tenant, category, channel)` → `(tenant, channel)` → `(tenant)` → kurulum çözümü; istek başına mod yalnız `test` düzleminde. _Kaynak:_ §9.14; API-62.
- [ ] **Test gönderimi (`is_test`)** — `POST /v1/workflows/{key}/test` `live`'da gerçek sağlayıcıya, doğrulanmış test alıcı listesinden ≤ 5 kişi/cihaz; `is_test` işaretli, faturalama ve metrikte ayrı satır, ayrı küçük kota, geçmişte/loglarda süzülebilir; önizlemenin gerçek cihaz seviyesi. _Kaynak:_ §8.5, §9.14, §11.10; API-61, TP-38.

#### Hata sınıfları, retry ve zaman aşımları
- [ ] **Sekiz hata sınıfı, grup + ayrıntı kaydı** — Her sağlayıcı yanıtı `transient|permanent_target|permanent_content|policy|quota|auth|sender_config|unknown`'a eşlenir; retry, fallback tetiği, adres devre dışı, bastırma ve devre kesici ağırlığı yalnız sınıftan türer. Normalleştirilmiş sınıf + ham kod append-only defterde, eşleme sürümlü ve test vektörlü; eşlemesiz kod `unknown` + `provider.unknown_code` + alarm, sessiz tahmin yok; bastırılmış alıcıya "başarılı" ayrı normalleştirilir. _Kaynak:_ §4.2, §4.3.1, §5.7, §6.8, §12.2.1, §12.2.2, §19.6.5; C-66, L-12, L-46, INV-46, CH-7, CH-8, T-26 (hata sınıfı).
- [ ] **Kalıcı hatada adres/token temizliği** — `permanent_target`/`permanent_content` retry edilmez; anında yumuşak silme/devre dışı (durum + `deleted_at`) ve `device.unregistered`/`address.disabled` olayı; APNs 410 `timestamp` son kayıttan eskiyse token silinmez; yumuşak devre dışı bırakma üst sınır parametresi olmadan çalışmaz. _Kaynak:_ §6.3, §12.2.5, §20.8; INV-14, CH-11, OP-44 (ölü token).
- [ ] **`sender_config` sınıfı** — Gönderici kimlik doğrulama hatası aboneyi bastırmaz; alan adı/kiracı düzeyinde olay ve devre kesici. _Kaynak:_ §4.3.1; L-48, MKT-17.
- [ ] **Üç katmanlı zaman aşımı** — Mesaj (`expires_at`), kanal ve sağlayıcı zaman aşımı + `Retry-After` çekirdekte. _Kaynak:_ §4.2; L-13.
- [ ] **Kanal TTL türetimi** — APNs `apns-expiration`, FCM `ttl`, Web Push `TTL`, SMS geçerlilik süresi `expires_at − now` ile türetilir. _Kaynak:_ §4.5, §5.4, §10.10, §12.2.3; C-39, WF-38, CH-9.
- [ ] **Kanal × sınıf backoff tablosu** — Başlangıç tablosu (APNs, FCM, ESP, WhatsApp, SMS, `security`) veri olarak; ölçümle ayarlanır (ENGINEERING ASSUMPTION). _Kaynak:_ §12.2.6; CH-12.

#### Failover, doğrulanmış rota ve limitler
- [ ] **Doğrulanmış rota kuralı** — Yalnız önceden doğrulanmış sağlayıcıya trafik (SMS başlık tescili/BTK/10DLC-TFV, e-posta SPF+DKIM hizası ve return-path, WhatsApp numara+şablon onayı, push kimlik + test gönderimi); doğrulanmamış listede "doğrulanmadı" görünür, devre açıkken bile geçilmez; yedek yoksa sınıfa göre ertele + neden kodu. _Kaynak:_ §12.3.2; CH-14.
- [ ] **İki failover modu ve sağlayıcı arızasında yönlendirme** — Kanal başına birincil + yedek; aktif-pasif (varsayılan, devre kesiciyle geçiş ve geri dönüş) ve ağırlıklı/maliyet tabanlı (sabit oran ya da sağlık + teslim oranı + fiyat); iki seviyeli devre kesici; arıza Relay tarafından fark edilir, kanal fallback'iyle birlikte uygulanır. _Kaynak:_ §4.2, §4.3.2, §7.11, §12.3.1, §19.6.4; L-14, L-56, MKT-16, CH-13, T-25 (madde 9 failover).
- [ ] **Kanal başına devre kesici parametreleri** — Ortak (`min_throughput` 20, prob 3/3, jitter %0–30) ve APNs/FCM/ESP/WhatsApp/SMS oran, pencere, open süresi tablosu veri olarak. _Kaynak:_ §12.3.3; CH-16.
- [ ] **Üç katmanlı sağlayıcı limitleri ve AIMD** — Hesap/proje, gönderici, alıcı/çift kovaları kanal birimiyle (SMS segment, e-posta alıcı; WhatsApp gelen mesaj da düşer); Relay limiti sağlayıcınınkinden katı; 429'da AIMD uyarlanabilir throttle, `Retry-After` öncelikli; e-postada alıcı alan adı başına kova. _Kaynak:_ §12.3.4; CH-17.
- [ ] **Paylaşılan sağlayıcı hesabında adil pay** — Paylaşılan hesap/kotada (FCM proje kotası, WhatsApp portföy limiti) ağırlıklı DRR + kümülatif şerit tavanı; kendi hesabında kiracı limiti; kendi hesabını getiren kiracı paylaşılan kotadan çıkar. _Kaynak:_ §18.7; TN-53.
- [ ] **Fiyat ve limit tabloları** — Birim, ülke × kategori fiyatı, kademeler, limitler sürümlü veri; WhatsApp fiyat kartı çeyreklik yenilenir, "pencere içi ücretsiz" varsayımı yok; teslim olayındaki ham fiyat nesnesi (WhatsApp `pricing`) saklanır. _Kaynak:_ §12.3.5; CH-18, CH-58.
- [ ] **Kanal anahtarlı overrides** — `overrides.<kanal>.provider` yalnız doğrulanmış sağlayıcılar arasında daraltır; öncelik istek > adım > workflow > kiracı; ham blok yalnız push ve WhatsApp; politika alanları ezilemez (`422 policy_field_not_overridable`); `overrides.email.from` yalnız doğrulanmış alan adı (`403 channel_not_configured`). _Kaynak:_ §9.5; API-23.
- [ ] **Sağlayıcı panel ayarı sağlık kontrolü** — API semantiğini ezen sağlayıcı panel ayarları düzenli doğrulanır; uyuşmazlık `sender_config` olayı üretir ve doğrulanmış rotadan düşürür. _Kaynak:_ §12.7.5; CH-52.

#### Push: öncelik, collapse ve politika
- [ ] **Platform öncelik eşleme tablosu** — Sınıf + ince ayardan APNs priority/interruption-level, FCM priority, Android kanal önemi, Web Push `Urgency` tek veri tablosundan; kiracı yalnız düşürebilir; hücreler test cihazlarında ölçülerek kesinleşir (EA). _Kaynak:_ §5.4, §9.5, §12.4.2; C-36, INV-16, API-22, CH-19.
- [ ] **Politika alanı override koruması** — Ham `apns.payload`/FCM `android` override'ı interruption-level, priority, push-type, FCM priority, Android kanalı ezemez; istek reddedilmez, politika değeri uygulanır, `override_ignored` kaydedilir. _Kaynak:_ §12.4.3; CH-21, INV-16.
- [ ] **`critical` ve `time-sensitive`** — `critical` varsayılan kapalı; kurulum operatörü kiracı başına onaylar (platform izni kanıtı, baştan beyanlı kritik şablon, step-up), her kullanım denetimde; `time-sensitive` yalnız `security`/`action_required`'da otomatik açık. _Kaynak:_ §12.4.3, §18.3.2; CH-20, TN-23, TN-21, TN-47.
- [ ] **Yüksek öncelik oranı izleme** — Kiracı başına yüksek öncelikli gönderim oranı izlenir; eşik aşımında uyarı + denetim kaydı (POLICY DEFAULT eşik). _Kaynak:_ §12.4.3; CH-22.
- [ ] **Konu bazlı collapse anahtarı** — `{tenant, subject.type, subject.id, message_class}` özeti; platform sınırları otomatik: APNs 64 bayt, FCM sınıf başına sabit anahtar + payload ayrıntısı, Web Push `Topic` 32 karakter, Slack/Teams/Telegram mesaj güncelleme eşlemesi, Live Activities/ProgressStyle kimliği. _Kaynak:_ §4.5, §5.4, §12.4.4; C-37, CH-23.

#### Push: istemciler ve kimlik
- [ ] **Kendi APNs/FCM HTTP/2 istemcisi** — Finch/Mint; bağlantı başına semafor + sınırlı kuyruk, SETTINGS beklemesi, `too_many_concurrent_requests` geçici; kiracı ve `(ortam × anahtar)` başına bağlantı, farklı kiracıların jetonları aynı bağlantıda taşınmaz; tembel açılış, boşta kapatma, jitter'lı yenileme, ping, GOAWAY; bütün `apns-push-type`, broadcast, push-to-start, yalnız FCM HTTP v1; `apns-id` teslim kimliğinden; mock, vektör, sandbox ve farklılık testi. _Kaynak:_ §4.5, §6.7, §12.5.1, §19.8; INV-40, CH-24, T-37.
- [ ] **APNs token auth ve JWT yaşam döngüsü** — .p8 ile JWT 20–60 dk'da bir (~40), aynı bağlantıda 20 dk'dan sık değil; imza KMS/HSM'de, son iyi JWT önbellekte, KMS kesintisinde anında alarm; `.p8` mühürlü çevrimdışı DR kopyası; sıcak değişim ve iki anahtarla sıfır kesintili rotasyon. _Kaynak:_ §12.5.2, §18.4.2; CH-25, TN-29.
- [ ] **FCM kimliği** — Workload Identity Federation tercih; yoksa RSA anahtarı KMS'te, RS256 assertion orada; OAuth jetonu proje başına ömrü boyunca önbellekte. _Kaynak:_ §18.4.2; TN-30, TN-35.
- [ ] **Web Push istemcisi ve içerik şifrelemesi (RFC 8030/8291/8292)** — Kendi `aes128gcm` + VAPID (`:crypto` + JOSE), RFC 8291 Ek A vektörleri; mesaj başına bellekte efemeral anahtar, mesaj başına KMS ECDH yok; `aesgcm` yalnız geriye uyum okuma; 4.096 bayt sınır; Declarative Web Push; `system` sınıfı gönderilmez; `pushsubscriptionchange` ve 404/410 yaşam döngüsü. _Kaynak:_ §12.1.3, §12.5.3, §18.4.2, §18.10, §19.8; CH-3, CH-26, T-38, TN-31, TN-35.
- [ ] **VAPID anahtar yönetimi** — Kanal kimliği (uygulama) başına ayrı VAPID anahtarı KMS'te, paylaşılan anahtar yok; VAPID JWT `exp` ≤ 24 sa, push servisi başına önbellek; rotasyon yalnız açık operatör eylemi + uyarı, çift anahtarla (eski anahtar mevcut aboneliklere hizmet eder; değişince abonelikler geçersizleşir). _Kaynak:_ §4.5, §5.3, §12.5.3, §18.4.2; C-26, CH-26, TN-31, TN-35.
- [ ] **HMS ve UnifiedPush** — Relay sınıfı HMS kategorisine sabit tabloyla eşlenir, kiracıya bırakılmaz; UnifiedPush Web Push modülünü paylaşır. _Kaynak:_ §12.5.4; CH-1, CH-27.

#### Push: cihazlar ve içerik
- [ ] **Cihaz kaydı ve OS izni** — Platform, jeton, uygulama, OS izin durumu (`granted|denied|provisional|not_determined`), Android kanal önemi, son etkinlik; jeton tek aboneye bağlı; kayıt ucu kimlik doğrulamalı; izinsiz cihaza push yok, rota ilerler (`skipped: no_permission`); jeton/izin kaybı tercihi silmez. _Kaynak:_ §5.3, §12.5.5; C-23, CH-28.
- [ ] **Cihaz uçları** — `POST/GET /v1/subscribers/{id}/devices`, `DELETE .../devices/{device_id}`, `DELETE /v1/devices/by-token`; jeton geri okunmaz (parmak izi döner); yeniden kayıt idempotent + `last_seen_at`; başka aboneye aitse yeniden bağlanır + `device.reassigned`; `apns_environment` ayrı alan; abone başına aktif cihaz üst sınırı. _Kaynak:_ §9.16; API-67.
- [ ] **Token yaşam döngüsü** — Her açılışta yeniden gönderim, `onNewToken`/`pushsubscriptionchange` güncellemesi, logout'ta devre dışı, bayat işaretleme ve 270 gün hareketsizde devre dışı (POLICY DEFAULT), yumuşak silme, tercihi silmez, loglarda kısaltılmış özet. _Kaynak:_ §12.5.6; CH-31.
- [ ] **İçerik taşımayan push ve push yükü yasakları** — OTP kodu, sır, kimlik doğrulama bağlantısı hiçbir push yükünde yok; opak kimlik + TLS ile içerik çekme ucu; TR bölgesi ve "yalnız yurt içi" kiracılarda, her bölgede `security`/`sensitive` şablonlarda varsayılan açık; içerik çekilemezse genel metin. Metadata'nın platforma görünürlüğü belgelenir; "sıfır bilgi" değil "içerik taşımıyor" ifadesi kullanılır. _Kaynak:_ §6.12, §12.5.7, §18.10; INV-60, CH-33, TN-35.

#### E-posta: taşıma ve kimlik
- [ ] **E-posta çekirdeği: ESP adaptörleri ve kendi MTA'nı SMTP ile bağla** — Swoosh ≥ 1.26.3 çekirdek (Bamboo yok); failover, itibar ve bounce normalizasyonu Relay katmanında; SaaS'ta Relay MTA işletmez, ticari ESP kullanır; kiracı Postfix/KumoMTA/Exchange'ini SMTP adaptörüyle bağlar. SMTP istemcisi TLS 1.2/1.3, `verify_peer`, CA, SNI, host adı kontrolü; 465 ve STARTTLS ayrı test, doğrulamasız TLS yok. _Kaynak:_ §2.3, §2.8, §7.10, §12.6.1, §19.8; F-3, E-64, CH-34, T-39.
- [ ] **ESP olaylarını dayanıklı ara kuyrukla alma** — Örn. SNS → SQS; kısa ömürlü doğrudan HTTP aboneliği yok. _Kaynak:_ §12.6.1; CH-47.
- [ ] **E-posta akış ayrımı ve gönderen kimliği** — İşlemsel ve pazarlama/toplu ayrı stream, IP havuzu, kuyruk; kategori başına gönderen adresi/alt alan adı; pazarlama için ayrı organizasyonel alan adı önerisi; platform kiracıları kendi alan adı ve ayrı itibarla. _Kaynak:_ §4.2, §12.6.2; L-15, CH-35.
- [ ] **Alan adı doğrulama sihirbazı (arka uç)** — SPF mekanizma/void lookup sayımı ve akış başına alt alan adı, return-path CNAME (VERP), DKIM 2048 bit / `rsa-sha1` yok / akış başına selector / ≤ 6 ayda iki selector'lı rotasyon / anahtar KMS-HSM / çok parçalı TXT, DMARCbis tree walk (PSL yazılmaz), `np=reject` önerisi, `p=reject`'te DKIM zorunlu; sonuç doğrulanmış rotayı besler. _Kaynak:_ §4.5, §6.8, §12.6.3; INV-43, CH-36.
- [ ] **Toplu gönderici kuralları tablosu** — Gmail/Yahoo/Microsoft/iCloud kuralları sürümlü veri; sihirbaz ve itibar panosu bununla çalışır. _Kaynak:_ §12.6.4; CH-37.
- [ ] **Zorunlu e-posta başlıkları** — Pazarlama/toplu e-postaya `List-Unsubscribe` (HTTPS + mailto) ve `List-Unsubscribe-Post` otomatik, DKIM `h=` kapsamında, işlemselde yok; her e-postada VERP return-path ve `Feedback-ID`. _Kaynak:_ §12.6.4; CH-38.
- [ ] **SMTPUTF8 desteği** — SMTPUTF8 adresleri reddedilmez; sağlayıcı desteklemiyorsa `permanent_content` açık hata. _Kaynak:_ §12.6.11; CH-45.
- [ ] **Gelen posta için MTA-STS ve TLS-RPT** — Relay gelen posta kabul ediyorsa (mailto çıkışı, yanıt toplama) MTA-STS ve TLS-RPT zorunlu. _Kaynak:_ §12.6.11; CH-46.
- [ ] **Takip varsayılan kapalı, güvenlik e-postalarında hiç yok** — Açılma pikseli ve link sarmalama varsayılan kapalı; `security` (dahil `email_verification`) ve OTP e-postalarında sarmalama, takip, yönlendirme zinciri açılamaz; Relay'in tek kullanımlık bağlantıları GET ile tüketilmez (GET onay sayfası, POST değişiklik). _Kaynak:_ §2.7, §4.3.1, §6.5, §12.6.10; INV-25, L-47, F-11, CH-44.

#### E-posta: bounce ve itibar
- [ ] **Bounce sınıfları ve DSN/ARF ayrıştırıcıları** — Hard/soft/şikâyet/`sender_config`/politika; VERP, RFC 3464 DSN + sağlayıcı lehçeleri, RFC 5965 ARF, gerçek test vektörleri; `sender_config` aboneyi bastırmaz, alan adı/kiracı olayı + devre kesici. Bastırma kaydına yazım A4'teki kayda yapılır. _Kaynak:_ §7.10, §12.6.5; E-64, CH-39.
- [ ] **İtibar devresi** — Kiracı × gönderim alan adı (ve × kanal) bounce/şikâyet oranı kayan pencerede; uyarıda olay, durdurmada akış duraklar; kendiliğinden kapanmaz, açık eylem + denetim; başlangıç %2/%0,05 uyarı, %4/%0,08 durdurma, 6 sa (PD). _Kaynak:_ §4.2, §12.6.7, §19.6.4; L-15, CH-41, T-25 (madde 8).
- [ ] **Isınma planı** — Yeni alan adı/IP için günlük tavan + alıcı alan adı başına hız, veri olarak, sağlayıcı kurallarıyla birleşir; plan dışı hacim ertelenir. _Kaynak:_ §12.6.8; CH-42.

#### SMS ve ses
- [ ] **SMS kodlamasını açık belirtme** — Her gönderimde `GSM7|GSM7_TR|UCS2` açık; sağlayıcı kataloğunda `turkish_single_shift: verified|unverified`, doğrulanmamışa Türkçe metin UCS2. _Kaynak:_ §11.5, §12.7.1; TP-18, CH-48.
- [ ] **SMS gönderici kimliği varlığı** — Kiracı/alt kiracı varlığı: tip, ülke, sağlayıcı başına onay durumu, doğrulama kuralları; ABD 10DLC brand/campaign/kullanım durumu ve TFV/BRN; sınıf–kampanya uyuşmazlığında ret (`rule_id`); onaysız kimlikle gönderim yok. _Kaynak:_ §12.7.3; CH-50.
- [ ] **OTP için ayrı sağlayıcı hesabı/ürün eşlemesi** — OTP ve kampanya aynı kuyruk, sağlayıcı hesabı ya da kredi havuzunu paylaşmaz; sağlayıcının OTP ürünü varsa `security` ona eşlenir (şerit ayrımı A2'de). _Kaynak:_ §12.7.6; CH-53.
- [ ] **Markalı alan adıyla SMS bağlantı kısaltma** — Yalnız kiracının markalı alan adı; paylaşılan kısaltıcı yok. _Kaynak:_ §12.7.8; CH-55.
- [ ] **Ses kanalı adaptörü** — Yerel operatör/aggregator sesli arama adaptörleri, `otp_oob` kanalı; faturalama birimi (cevaplanan çağrı, süre) fiyat tablosunda; ticari sesli iletide gönderen kimliği metni ticaret unvanıdır, şablon linter'ında kanal başına kural olarak denetlenir. _Kaynak:_ §12.8; CH-56.

#### WhatsApp
- [ ] **WhatsApp şablonları: onay yaşam döngüsü ve kategori eşlemesi** — Değişmez ad-sürümlü şablonlar; `pending_approval` → `approved` (Meta `APPROVED`/`REJECTED`/`PAUSED`/`DISABLED`; onay bekleyen ve `PAUSED` gönderilemez); yeni içerik yeni Meta adı, düzenleme kotası ve red gerekçesi yüzeye çıkar, önizleme Meta'da onaylı metni gösterir. Sınıf → authentication/utility/marketing sabit; `template_category_update` kayması kiracıya olay + maliyet güncellemesi, Relay sınıfı değişmez; `account_update`, `user_preferences` abonelikleri. _Kaynak:_ §11.5, §12.9.1; TP-23, CH-57.
- [ ] **WhatsApp CSW pencere modeli** — Alıcı × numara pencere durumu gelen her mesajla yenilenir; açıkta serbest mesaj, kapalıda şablon; pencere içi ücretsiz varsayılmaz. _Kaynak:_ §12.9.2; CH-58.
- [ ] **WhatsApp hata kuralları** — `131026`/`131050` asla retry, `131049` ≥ 24 sa, `131047` şablonla yeniden planla, `130429`/`131056` transient (çift kovası yavaşlar), `132015`/`135000` quota, `131042` sender_config. _Kaynak:_ §12.9.3; CH-59.
- [ ] **WhatsApp tekilleştirme ve webhook** — Kendi outbox/tekilleştirme, korelasyon `biz_opaque_callback_data`; webhook anahtarı `wamid + status + timestamp`, mükerrer/sırasız beklenir, monoton geçiş; `X-Hub-Signature-256` ham gövde; `pricing` nesnesi tam saklanır; sıra gerekiyorsa önceki `delivered` beklenir. _Kaynak:_ §12.9.4; CH-60.
- [ ] **WhatsApp limitleri** — Kademe, numara throughput, şablon Graph API kotası limit verisi; 24 sa benzersiz alıcı üyelik kümesiyle, %90'da uyarı; throughput yükseltmesi olay, işler ertelenir. _Kaynak:_ §12.9.5; CH-61.
- [ ] **WhatsApp pazarlamada ek izin şartı yok** — Mevzuatın öngörmediği ek izin koyulmaz, çıkış hakkı geçerli; gelen pazarlama çıkışı tercih kaydına yazılır. _Kaynak:_ §12.9.6; PC-43, CH-57.

#### Mesajlaşma kanalları
- [ ] **Slack, Teams, Telegram, Discord adaptörleri** — Bot/uygulama kimliği, çalışma alanı başına kurulum/OAuth; Teams bot + `conversationReference` deposu (O365 Connectors yok); teslim/okundu bilgisi vermez (yetenek bayrağı); Telegram 403 blocked `permanent_target`; gelen etkileşimler hızlı 2xx + imza (`X-Slack-Signature` v0, Telegram secret token) + kuyruk + olay kimliğiyle tekilleştirme. _Kaynak:_ §12.10; CH-62.
- [ ] **Kart butonu onay değildir** — Kart butonu/satır içi yanıt hiçbir zaman onay sayılmaz; onay türünde eylem yalnız Access onay yüzeyine derin bağlantı. _Kaynak:_ §12.10; CH-62.
- [ ] **WATCH: RCS** — Türkiye'de RBM sunan operatör yok; operatör ve CPaaS bölge listeleri yıllık izlenir (yapım yok, izleme maddesi). _Kaynak:_ §22.2; CH-63, OQ-32.

#### Bu aşamada doğrulanacak sınırlar
- **INV-9, INV-13, CH-10, T-28, OP-6 (madde 4)** — beyansız adaptör yok; belirsiz sonuçta kör retry yok, ücretli kanalda ≤ 1 retry.
- **INV-46, CH-7, CH-8** — her yanıt sekiz sınıftan birine; eylemler yalnız sınıftan; eşlemesiz kod `unknown` + alarm.
- **INV-14, CH-11** — kalıcı hatada retry yok, anında yumuşak devre dışı; eski APNs 410 token silmez.
- **INV-43, CH-14, TN-58** — yalnız doğrulanmış sağlayıcıya trafik; devre açıkken de doğrulanmamışa geçiş yok; "yalnız yurt içi" uygulanır.
- **CH-2, CH-3, T-40** — beyanı eksik adaptör trafik almaz; gelen imza ham gövdede, sabit zamanlı.
- **DS-10, DS-11, DS-12, INV-5** — tanımsız olay kodu reddedilir; kanıt satırı, test vektörü ve idempotency beyanı olmadan adaptör canlıya alınamaz; teslim semantiği tablosu olmayan kanal devreye girmez.
- **TN-35, T-43** — gelen webhook doğrulaması; giden TLS doğrulaması kapatılamaz; RFC 8291 vektörleri.
- **TN-26, TN-28, TN-29, TN-30, TN-31** — sırlar uygulama belleğine girmez; sıcak rotasyon kesintisiz; `R‖S` vektörleri.
- **INV-16, CH-20, CH-21** — politika alanları ham payload ile ezilemez; `critical` onaysız açılamaz.
- **INV-40, CH-24, T-37** — kiracı jetonları aynı APNs bağlantısında taşınmaz; HTTP/2 kabul kontrolü.
- **CH-25, CH-26, T-38** — APNs JWT yenileme; Web Push şifreleme/VAPID kuralları.
- **CH-23** — collapse anahtarı platform sınırlarına uyar.
- **CH-28** — izinsiz cihaza push yok, tercih silinmez.
- **INV-60, CH-33** — push yükünde OTP/sır/kimlik bağlantısı yok.
- **INV-25, CH-44** — güvenlik e-postalarında takip yok; tek kullanımlık bağlantı GET ile tüketilmez.
- **CH-34, CH-38, CH-39, CH-41** — SMTP TLS doğrulaması; zorunlu başlıklar; `sender_config` aboneyi bastırmaz; itibar devresi kendiliğinden kapanmaz.
- **CH-53** — OTP ve kampanya aynı hesabı/havuzu paylaşmaz.
- **CH-57, CH-59, CH-60, CH-61** — WhatsApp şablon onayı, hata kuralları, webhook monotonluğu, limitler.
- **CH-62** — kart butonu onay sayılmaz; gelen etkileşim imzalı ve tekil.
- **TN-53** — paylaşılan hesapta adil pay.
- **X-25, X-26, API-63, TN-7, E-64** — test düzleminde aynı hat ve aynı `rule_id`'ler; sahte sonuç tablosu.
- **API-22, API-23, API-61, API-62, API-67, WF-38** — öncelik/override kuralları, test gönderimi, `send_mode`, cihaz uçları, TTL türetimi.

---

### Aşama 7 — Teslim durumu ve gözlem

Her gönderimin ne olduğunu append-only defterden dürüstçe söylemek: dört eksenli iç model, kanıt tablosunun projeksiyona uygulanması, sabit dış projeksiyon, DLR pencereleri ve `unknown`, mutabakat, etkileşim (insan/bot), analitik, kullanım kayıtları, metrik/iz/SLO. A1 (defter iskeleti, saklama, Postgres), A2 (kill switch, şeritler, sanal saat), A3 (API, CLI) ve A6 (adaptörler, hata sınıfları, kanal kanıt tablosu ve adaptör devreye alma kapısı, gelen webhook doğrulaması) üzerine kurulur.

#### Spec dışı ön koşullar
- [ ] **Sağlayıcı mutabakat sıklığı** — DS-22/OP-42 "varsayılan değer ölçümle konur", PD değersiz; değer konmadan yayımlanmaz. _Kaynak:_ §22.3; OQ-27, DS-22, OP-42. (Adem kararı)
- [ ] **Mesaj sınıfı başına SLO değerleri ve bağlı alarm eşikleri** — DS-42/OP-36 tablo yapısını verir, hedefler PD değersiz; "kanıtlı teslim oranında düşüş" alarmı da bunlara bağlı; değer konmadan yayımlanmaz (F-28). _Kaynak:_ §20.6, §22.3; OQ-27, OP-36, DS-42. (Adem kararı)
- [ ] **Kanal × sağlayıcı ve kiracı pencere üst sınırları** — DS-18 "üst sınır içinde ayarlanır" der; sınır değeri yok. (Adem kararı)
- [ ] **WhatsApp uzun penceresi ve sesli arama pencerelerinin doğrulanması** — DS-19 değerleri ⚠️ doğrulanmadı/ölçülmedi. (Adem kararı)
- [ ] **Bot tıklama sinyal listesi ve eşikleri** — DS-30 bunları sürümlü veri sayar; başlangıç listesi (tarayıcı IP blokları, saniye eşiği vb.) spec'te yok. (Adem kararı)
- [ ] **`usage_records` şeması ve faturalanabilir olay tanımı** — DS-38/OP-38 ilkeyi ve boyutları verir; hangi olayın faturalanabilir olduğu tanımlı değil. (Adem kararı)

#### Defter ve iç model
- [ ] **Dört eksenli iç model ve defterden projeksiyon** — Deneme, teslim (monoton `none<accepted<delivered`), hata türü (+ sınıf, `reason`, `rule_id`) ve etkileşim (ayrı damga/kaynak) ayrı alanlarda; hepsi defterden, her an yeniden kurulabilir; kanal/sağlayıcı teslimden okunur, çağıran seçemez. _Kaynak:_ §1.7, §5.7, §6.2, §14.1.3; C-67, INV-6, C-2, MD-15, DS-3.
- [ ] **Olay kaynağı sözlüğü** — `actor` = `relay`, `provider_api`, `provider_webhook`, `client_sdk`, `user`; `client_sdk` ile `user` karıştırılmaz. _Kaynak:_ §14.1.8; DS-8.
- [ ] **Ücretli kanallarda senkron defter yazımı** — SMS/WhatsApp'ta teslim defteri gönderimden önce senkron yazılır; push'ta toplu yazım bilinçli takas. _Kaynak:_ §20.1; OP-6 (son paragraf).
- [ ] **Teslim raporu batcher'ı** — Sağlayıcı teslim raporu yağmuru Broadway batcher ile toplu yazılır. _Kaynak:_ §19.8; T-41 (batcher).
- [ ] **Monoton koşullu güncelleme ve olay indirgeme** — `UPDATE … WHERE rank < $yeni RETURNING`; teslim geri gitmez, sıfır satır = geç olay (deftere yazılır, metrikte sayılır); indirgeme sırası deneme no → sağlayıcı sırası → `occurred_at`/`received_at` → kaynak önceliği; `occurred_at ≤ received_at + 1 sa`, gelecek zamanlı olay yok; terminal durumda damga zorunlu DB kısıtı. _Kaynak:_ §4.2, §6.2, §14.1.4, §20.1; INV-7, L-16, DS-4, OP-4.
- [ ] **Sonucun tüm denemelerden türetilmesi ve çift teslim** — Herhangi denemenin `delivered` kanıtı teslimi `delivered` yapar, yalnız aynı denemenin hatasını geçersiz kılar; `duplicate_delivered` bayrağı ve `has_conflict` görünür, metrikte sayılır. _Kaynak:_ §6.2, §14.1.5; INV-8, DS-5.
- [ ] **Teslimden sonra hata tablosu** — Kanal başına `after_delivered` = `valid`/`stale`/`conflict` davranışı. _Kaynak:_ §14.1.6; DS-6.
- [ ] **Okuma kaynağı ve kanal sınırı** — Okuma olayı `inbox_action`/`provider_signal`/`client_sdk` kaynağı taşır; yalnız kendi kanalının teslimini kanıtlar ve onu `delivered`'a yükseltir. _Kaynak:_ §14.1.7; DS-7.
- [ ] **Teslim ack'i yalnız teslim bilgisidir** — Relay yalnız teslim ack'inin sahibidir; Work'ün anlamsal ack'i ve PEP yetki ack'i ayrıdır; teslim durumu ödeme, onay ya da hukuki bilgilendirme kanıtı değildir; Relay finansal durumu tutmaz/türetmez. _Kaynak:_ §7.3.1, §7.8; E-8, E-58, E-59.
- [ ] **Teslim kayıtları saklama sınıfı** — Defter/deneme/projeksiyon saklama sınıfı; fiziksel silme yok, PII özne × sınıf DEK'iyle şifreli, saklama sonu yumuşak silme + crypto-shredding; süreler Access Ek C'den. _Kaynak:_ §14.9.1; DS-44.
- [ ] **İçerik minimizasyonu** — Teslim kaydı render içerik değil özet + şablon/layout/parça sürümlerini saklar; kiracı içerik saklamayı ayrı sınıfta açabilir, OTP/doğrulamada asla; `retention: none` içerik saklamayı kapatır; ham sağlayıcı yanıtının PII alanları içerik sınıfı anahtarıyla şifreli. _Kaynak:_ §14.9.2; DS-45.

#### Kanıt sınırları ve tablo denetimi
- [ ] **Bilinmeyen sağlayıcı kodu** — Eşlemesiz kod projeksiyonu değiştirmez; `unknown_provider_code` olayı + alarm; ham kod ve DSN alanları defterde ("grup + ayrıntı"); kod→olay eşlemesi dağıtımsız güncellenen veri. _Kaynak:_ §14.2.1; DS-10, DS-46.
- [ ] **Push teslim iddiası yok, SDK makbuzu ayrı kanıt** — Sağlayıcı kabulü `delivered` sayılmaz; push uyandırma sinyalidir, kayıt inbox'tadır; yalnız mobil SDK "gösterildi/tıklandı" makbuzu ayrı kanıt düzeyidir; push'a DLR penceresi yok, `unknown`'a düşmez; raporda kabul oranı ile makbuzlu teslim oranı ayrı. _Kaynak:_ §12.5.7, §14.2.4; CH-32, DS-13.
- [ ] **Bölüm tablolarının sürümlü veri ve denetimi** — Kanıt, pencere, neden sözlüğü, bot sinyal tabloları dağıtımsız değişir; her değişiklik denetim kaydına girer. _Kaynak:_ §14 kuralları; DS-46.

#### Gelen olaylar, DLR pencereleri ve mutabakat
- [ ] **Gelen sağlayıcı webhook kabulü ve kalıcı tekilleştirme** — Önce kalıcı makbuz, sonra hızlı 2xx, işleme kuyruktan; sağlayıcı başına ham gövde + sabit zamanlı imza doğrulama (Standard Webhooks ortak doğrulayıcı); `(tenant, provider, provider_event_id)` tekil `webhook_receipts` makbuzu, tekrar sayılır; kanıt tablosuyla deftere. _Kaynak:_ §4.2, §6.3, §14.4.5, §16.10.1; L-17, INV-12, DS-22, WH-49.
- [ ] **İki aşamalı DLR penceresi** — `sent` → kısa pencere → `unknown_pending` → uzun pencere → `unknown`; pencereler kanal başına veri, kanal × sağlayıcı ve kiracı düzeyinde üst sınır içinde ayarlanır; kesin olay uydurulmaz; teslim yolunda olasılıksal yapı yok. _Kaynak:_ §1.4, §4.2, §6.1, §14.4.1; INV-5, L-16, F-11, DS-18.
- [ ] **Varsayılan pencere değerleri** — SMS 6 sa/72 sa, e-posta 24 sa/72 sa, WhatsApp 36 sa/7 gün, sesli arama 1 sa/24 sa; push/in-app/webhook'a uygulanmaz. _Kaynak:_ §14.4.2; DS-19.
- [ ] **Geç kesin olayın kabulü** — Geç `delivered`/`failed` ve eski denemenin geç başarısı her zaman deftere yazılır ve `unknown*`'ı yükseltir; saklaması dolmuş kayıtta yalnız deftere yazılır ve sayılır. _Kaynak:_ §4.2, §14.1.2, §14.4.3; L-16, DS-20, DS-2.
- [ ] **Dürüst mutabakat: otomatik yeniden gönderim yok** — `delivered`/`failed` uydurulmaz; `unknown` ve mutabakatın "teslim edilmedi" sonucu otomatik yeniden gönderim/fallback tetiklemez; yeniden gönderim yeni istekle insan/kiracı kararıdır. _Kaynak:_ §6.2, §14.4.4, §20.7; INV-9, L-16, DS-21, OP-41.
- [ ] **Periyodik kanal mutabakatı** — Açık teslimler için kanal başına sağlayıcı durum/olay API'si ve raporlarından çekme, sayım karşılaştırması; sıklık kanal tablosunda; `actor = provider_api` defter olayı, aynı monotonluk kuralları. _Kaynak:_ §4.2, §6.3, §14.4.5, §20.7; L-17, INV-12, DS-22, OP-42 (ilgili satırlar).
- [ ] **Defterden yeniden kurma testi** — Haftalık olarak projeksiyon defterden yeniden hesaplanan değerle karşılaştırılır; fark varsa alarm. _Kaynak:_ §14.1.2, §20.7; DS-2, OP-3 (yeniden kurma testi).
- [ ] **Test düzleminde teslim simülasyonu** — Sahte sağlayıcı test adreslerine anında/gecikmeli teslim, bounce, DLR yok, geç DLR, mükerrer teslim üretir; sanal saatle pencere akışları test edilir. _Kaynak:_ §14.4.6; DS-23.

#### Dış projeksiyon ve sorgu yüzeyi
- [ ] **Dış projeksiyon** — `status` dokuz değer (`queued`…`cancelled`), `engagement` damgaları (`seen`/`read`/`clicked`/`archived`, tıklamada insan/bot), `reason`/`rule_id` (skipped/failed/expired/cancelled ve ertelemede), `failure` (`kind`, `class`, kod, `retryable`); iç model değişse de sabit. _Kaynak:_ §5.7, §14.3.1; C-67, INV-10, DS-14.
- [ ] **Projeksiyon türetme kuralı** — `delivered` (+ geçerli hata yoksa) → `delivered`; geçerli kesin hata → `failed` (`delivered_at` korunur); kesin olay yoksa pencere kuralı; `skipped`/`expired`/`cancelled` kesin terminal. _Kaynak:_ §14.3.2; DS-17.
- [ ] **Bildirim düzeyi görünüm** — Bildirim için uydurma durum yok; teslim listesi + durum başına sayım; workflow çalışma durumu ayrı alan. _Kaynak:_ §14.1.9; DS-9.
- [ ] **Tek defter, tek `rule_id` sözlüğü, her yüzeyde aynı cümle** — Panel, API, webhook ve metrik aynı defterden okur; bir karar her yüzeyde aynı `rule_id` ve sözlük cümlesiyle görünür; gönderilmeyen her bildirim neden koduyla kaydedilir, bilinmeyen durum "bilinmiyor" raporlanır. _Kaynak:_ §8 ilke 1–2, §8.4; X-1.
- [ ] **Sorgu uçları ve deneme geçmişi** — `GET /v1/events/{id}`, `GET /v1/notifications/{id}` (`expand=deliveries`), `GET /v1/notifications` (abone, workflow, durum, zaman filtresi), `.../deliveries`; deneme geçmişi + olay defteri ayrı uçta: zaman, sağlayıcı, normalleştirilmiş sonuç, ham kod, kapsam yetkisine göre sağlayıcı yanıtı; PII maskeli, açık gösterme hassas işlem. _Kaynak:_ §9.16, §14.3.4; API-68, DS-16.
- [ ] **"Neden almadım" sorgu API'si** — Alıcı + zaman aralığı için karar zinciri (geçilen kapılar, durduran/erteleyen kural ve seviye, kanal sonuçları) defter ve karar kayıtlarından. _Kaynak:_ §14.5.4; DS-28.
- [ ] **`relay logs` komutu** — Aktivite ve teslim logunu CLI'dan izler. _Kaynak:_ §8.11; X-33.

#### Etkileşim
- [ ] **Açılma/tıklama takibi varsayılanları** — Piksel ve link sarmalama varsayılan kapalı, kiracı kategori/şablon düzeyinde açar; `security` ve OTP/doğrulama e-postalarında hiçbir koşulda açılamaz; piksel açıkken güvenilmezlik uyarısı. _Kaynak:_ §12.6.9, §14.6.1; CH-43, DS-29.
- [ ] **İnsan/bot tıklama sınıflandırması** — `human`/`likely_bot` (zamanlama, toplu tıklama, tarayıcı IP blokları, istek biçimi); sinyal listesi ve eşikleri sürümlü veri; sonuç ve karar veren sinyal olayda saklanır; raporlarda ayrı, birleşik sayı yok. _Kaynak:_ §12.6.9, §14.6.2; CH-43, DS-30, DS-46.
- [ ] **Açılma verisi kararsız ve kanıtsız** — Açılma hiçbir kararda/kanıtta kullanılmaz, `machine_open` bayrağıyla metrik ayrıştırılır; etkileşime bağlı kararları yalnız güvenilir kanıt ve insan tıklaması tetikler, "muhtemel bot" tetiklemez. _Kaynak:_ §2.7, §4.3.1, §6.5, §14.6.4; INV-27, L-47, F-11, DS-32.
- [ ] **İnsan tıklaması e-posta teslim kanıtı** — İnsan tıklaması teslimi `delivered`'a yükseltir (`actor = user`); bot tıklaması ve açılma kanıt değildir; teslim oranı buna göre. _Kaynak:_ §14.6.3a; DS-34.
- [ ] **Etkileşim ekseninin bağımsızlığı** — Etkileşim olayı teslim sonucundan bağımsız kaydedilir; güvenilir etkileşim kendi teslimini DS-7/DS-34'e göre yükseltir. _Kaynak:_ §14.6.5; DS-33.
- [ ] **Şikâyet oranı doğru paydayla** — Şikâyet oranı gelen kutusuna teslim edilmiş posta paydasıyla hesaplanır (itibar panosu). _Kaynak:_ §12.6.4; CH-37.
- [ ] **DMARC aggregate ve TLS-RPT rapor alımı** — Desteklenen yetenek olarak raporların alınması ve işlenmesi. _Kaynak:_ §12.6.11; CH-46.

#### Analitik, maliyet ve kullanım
- [ ] **Kesin sayaçlar** — Deneme/teslim/kullanım sayaçları Postgres'te kesin; teslim yolunda Bloom/HLL yok, yalnız operatör metriklerinde. _Kaynak:_ §14.7.5; DS-39.
- [ ] **Değişmez kullanım kayıtları** — `usage_records` faturalanabilir olayla aynı transaction'da, günlük `(tenant, environment, day, channel, provider)` idempotent ve değişmez, arşivde de kalır; ölçüm boyutları (ülke/operatör, segment, WhatsApp kategori, sonuç, deneme); faturalama metriklerden yapılmaz; fatura mutabakatı ve sapma uyarısı; `is_test` ayrı satır. _Kaynak:_ §14.7.4, §20.6; DS-38, OP-38, OP-42 (kullanım ↔ fatura).
- [ ] **Postgres rollup raporları, olay akışı ve dışa aktarım** — Defterden yeniden hesaplanabilir rollup'lar: huni, kanal/sağlayıcı oranları, etkileşim (insan/bot, `machine_open`), A/B varyant, maliyet, atlama dağılımı, yedek saat dilimi sayısı; `is_test` ve test düzlemi ayrı satır; Relay içinde OLAP yok; kiracı hedefine sürekli anlamsal olay akışı; CSV/Parquet ham veri dışa aktarımı; `relay_report` rolü OLTP havuzu dışında. _Kaynak:_ §2.3, §2.8, §4.3.2, §14.7.1, §14.7.3, §20.6; F-7, L-57, DS-35, DS-37, OP-39.
- [ ] **Maliyet raporları** — Fiyat tablosu ve teslim olayı fiyat nesnesinden beslenir; fatura karşılaştırması için ham fiyat nesnesi. _Kaynak:_ §12.3.5; CH-18.
- [ ] **Kiracı verisi kiracılar arası kullanılmaz** — Bir kiracının verisi başka kiracı için analitik, model eğitimi, ürün geliştirmede kullanılmaz; platform işletim metrikleri kişisel veri/içerik taşımaz. _Kaynak:_ §18.2; TN-18.

#### Telemetri: sinyaller, iz ve metrikler
- [ ] **Üç sinyal ve toplayıcı** — Trace OTel, metrik Prometheus kazıma (Telemetry), log `trace_id`/`span_id`'li; OTLP dönüşümü ve kardinalite sınırı Collector'da; gözlem verisi bölgede. _Kaynak:_ §20.6; OP-32, T-63 (madde 1).
- [ ] **Uçtan uca tek iz** — `traceparent` HTTP, iş meta verisi, webhook/olay hedefleri ve teslim defterinde; geç sağlayıcı webhook'u yeni trace + span link ile bağlanır; korelasyon kimliği log/iş/span'de; ürünler arası trace ve span'lerde kişisel veri yok. _Kaynak:_ §7.12, §14.8.1, §20.6; E-72, DS-40, OP-34, T-63 (madde 2).
- [ ] **Metrik kardinalite kuralı** — Temel `channel × provider × status` + exemplar; histogramda kiracı yok; sayaçta ilk N kiracı (PD 20) + `other`; yasak etiketler; kiracı SLO'su olay verisinden tabloya, Prometheus'a yalnız ihlal sayacı. _Kaynak:_ §20.6; OP-35, T-63 (madde 4).
- [ ] **Huni tamlığı birincil sağlık metriği** — `accepted → enqueued → dispatched → provider_accepted → delivered → engaged`; aşama boşlukları ölçülür, `accepted − enqueued` > 0 en ağır alarm (veri kaybı); push hunisi kabulde biter, SDK makbuzu ayrı satır; huni ve SLO defterden, alıcı hunisi defter sorgusu. _Kaynak:_ §14.7.2, §20.6; DS-36, OP-33, T-63 (madde 5).
- [ ] **Atlama metrikleri** — Her atlama nedeni (neden koduyla) metrikte görünür. _Kaynak:_ §1.7, §6.1, §14.5.1; MD-12, INV-1, DS-24.
- [ ] **Gizlenmeyen teslim metrikleri** — `duplicate_delivered`, çakışma, geç olay, kanal × sağlayıcı `unknown_pending`/`unknown` oranı, `unknown_provider_code`, huni boşlukları, mutabakat gecikmesi, DLR gecikme dağılımı, bot tıklama oranı. _Kaynak:_ §14.8.2; DS-41.
- [ ] **Gürültülü komşu gözlemi** — Kuyruktaki işlerin > %50'si tek kiracı, kiracı bazlı dağılım dengesizliği ve tek API anahtarı baskınlığı işaretlenir; kiracı etiketi kardinalite kuralıyla. _Kaynak:_ §18.7; TN-62.
- [ ] **Kendi VM sistem monitörü** — Uzun GC/zamanlama, büyük yığın, uzun posta kutusu, meşgul port telemetriye; etikette kayıtlı ad; yüksek öncelikli, yığın dışı monitör; periyodik VM metrikleri; atom eğimi alarmı; kirli zamanlayıcı kuyruk enstrümantasyonu. _Kaynak:_ §19.9; T-48, T-53 (madde 2).

#### SLO ve alarmlar
- [ ] **Mesaj sınıfı başına SLO tablosu ve alarmları** — Kabul gecikmesi, sağlayıcıya gönderim gecikmesi, erişilebilirlik; kabul temelli eşik SLI, kabul sonrası teslim ayrı bilgilendirici SLO; çok pencereli yanma oranı (14,4 / 6 / 1); SLO etiketi `channel × provider`; "kanıtlı teslim oranında 1 saatte %40 düşüş" alarmı; tek kaynak bu tablo, değerler ölçülene kadar boş. _Kaynak:_ §14.8.3, §20.6; DS-42, OP-36.
- [ ] **Kill switch yürürlük gecikmesi SLO'su** — "Durdur" ile son mesaj çıkışı arası süre ölçülür ve gösterilir (ör. "son 90 sn'de 412 iş duraklatıldı"). _Kaynak:_ §18.5.2; TN-44.
- [ ] **ESP teslim olayı gecikmesi alarmı** — Alarm API hatasına değil teslim olayı gecikmesine kurulur. _Kaynak:_ §12.6.1; CH-47.
- [ ] **Alarm hijyeni** — Kuyruk alarmı en eski iş yaşı; sağlayıcı alarmı kesici durumu; sınıf eşikleri, gece `marketing` sayfası yok; türetilmiş metrik; sağlayıcı olayı birleştirme; her alarmda `runbook_url` (CI doğrular); ek alarm seti (`rule_id` atlama sıçraması, bilinmeyen kod, sessiz saat ihlali, mükerrer, boş digest, kampanya 1,5×, ajan sessiz bekleme); uyandırma bütçesi. _Kaynak:_ §20.6; OP-37, T-6 (alarm sinyali).

#### Bu aşamada doğrulanacak sınırlar
- **INV-6, C-67, DS-3, DS-2, OP-3** — projeksiyon her an defterden yeniden kurulabilir; haftalık yeniden kurma testi fark üretmez.
- **INV-7, DS-4, OP-4** — teslim monoton; geç düşük durum geri almaz, sıfır satır geç olay olarak sayılır; gelecek zamanlı olay yok.
- **INV-8, DS-5, DS-6, DS-7, DS-34** — çok denemeli türetme, çift teslim/çelişki görünürlüğü, teslim sonrası hata, okuma ve insan tıklaması kanıt sınırları.
- **INV-5, DS-13, DS-17, DS-18, DS-20** — kanıtsız `delivered`/`failed` yok; push'ta teslim iddiası yok; pencere ve geç kesin olay kuralları.
- **INV-9, DS-21, OP-41** — `unknown`/"teslim edilmedi" otomatik yeniden gönderim üretmez.
- **INV-10, X-1** — dış projeksiyon sabit; her yüzeyde aynı `rule_id` ve cümle; sessiz kayıp yok.
- **INV-12, DS-22, WH-49, OP-42** — sağlayıcı olayları kalıcı tekil makbuzla; mutabakat aynı monotonluk kurallarıyla.
- **DS-10, DS-46** — eşlemesiz sağlayıcı kodu projeksiyonu değiştirmez, alarm üretir; tablo değişiklikleri denetimde.
- **INV-27, DS-29, DS-32, CH-43** — takip varsayılan kapalı, güvenlik e-postalarında açılamaz; açılma ve bot tıklaması karar tetiklemez.
- **CH-37** — şikâyet oranı doğru paydayla.
- **DS-39, OP-38** — kesin sayaçlar; kullanım kayıtları değişmez ve idempotent.
- **DS-45** — içerik minimizasyonu; OTP/doğrulamada içerik saklanmaz.
- **E-8, E-59** — teslim ack'i yalnız teslim bilgisidir.
- **E-72, OP-34, OP-35** — span'lerde PII yok; trace bağlamı her sınırda; kardinalite kuralı.
- **OP-33, OP-36** — huni tamlığı ve SLO tablosu defterden.
- **API-68** — sorgu uçlarında dış projeksiyon sabit.
- **TN-18, TN-44, TN-62** — kiracılar arası veri kullanımı yok; kill switch gecikmesi ölçülür; gürültülü komşu işaretlenir.

---

### Aşama 8 — Workflow ve yönlendirme

A3'te kurulan workflow iskeletinin (kayıt, sürümleme, olay şeması, tek kanallı yayımlanmış workflow) üstüne gelişmiş adımları, rota politikalarını, yükseltme/eskalasyonu, digest/throttle/içerik tekilleştirmesini, zamanlamayı, topic ve kampanyayı ekler. A2'nin bekleme noktası çekirdeğine ve zamanlayıcısına, A3'ün workflow iskeletine, A4'ün bastırma kaydı ve sınıf kanal kapılarına dayanır.

#### Spec dışı ön koşullar
- [ ] **Workflow dosya biçimi JSON Schema'sı** — WF-3 tek tanım biçimini ister; biçimin kendisi (sözleşme) yazılmamış. A3 iskeleti için asgari bir alt küme yeterli, tam biçim (rota, deney, eskalasyon politikası) bu aşamada gerekir. (Adem kararı)
- [ ] **Koşul dili grameri ve sayısal sınırları** — WF-10 ifade boyutu ve derinliği "sınırlıdır" der; gramer ve sayısal sınırlar yok. (Adem kararı)
- [ ] **RRULE alt kümesi ve tekrar kuralı üst sınırı** — WF-48/WF-49: desteklenen RRULE kısmı ve kiracı başına üst sınırın (PD) değeri yok. (Adem kararı)
- [ ] **Kategori varsayılan `expires_at` değerleri** — WF-38 diğer sınıflarda "kategori varsayılanı" der; değerler tanımsız. (Adem kararı)
- [ ] **Deterministik jitter yayılım parametresi** — WF-42 `mod yayılım` der; yayılım süresi tanımsız. (Adem kararı)

#### Tanım biçimi ve yönetim
- [ ] **Ortak workflow tanım biçimi ve dosya yolu** — Görsel editör, dosya (YAML/JSON + JSON Schema) ve SDK aynı tanım biçimini üretir; her yapı (adım, rota, eskalasyon politikası, A/B, koşul) her yolda kurulabilir; API dosya biçimini kabul eder. CLI `relay pull`/`push`/`promote` workflow, şablon ve rota tanımlarını çeker, gönderir ve ortamlar arası yükseltir. _Kaynak:_ §1.7, §2.8, §8.3.1, §8.11, §10.2; C-40, MD-16, X-8, X-33, WF-3.
- [ ] **Workflow tek yönetici kuralı** — `managed_by: panel|code`; koddan yönetilen akışın yapısı panelden değiştirilemez, yalnız metin ve işaretli kontrol alanları düzenlenebilir; yönetici değişikliği açık eylemdir ve denetlenir. _Kaynak:_ §1.7, §8.3.2, §10.2; C-40, X-9, WF-4.
- [ ] **Mermaid dışa aktarımı** — Workflow tanımı Mermaid biçiminde dışa aktarılabilir. _Kaynak:_ §8.3.3, §10.2; X-11, WF-6.
- [ ] **Rota, topic, tekrar kuralı ve throttle yönetim uçları** — Rota, topic/abonelik, tekrar kuralı ve throttle sıfırlama uçları ortak API kurallarıyla. _Kaynak:_ §9.16; API-69.

#### Adım türleri ve koşul dili
- [ ] **Sekiz adım türü** — `channel`, `delay`, `digest`, `throttle`, `condition`, `wait_for_event`, `time_window`, `webhook`; fetch/update/invoke adımı yok. _Kaynak:_ §1.2, §1.7, §5.5, §10.3; C-41, MD-16, WF-8.
- [ ] **Koşul adımı ve kural dili** — Olay verisi, beyan edilmiş alıcı öznitelikleri ve önceki adım sonuçları üzerinde karşılaştırma + mantıksal birleşim; döngüsüz, kod/dış çağrı yok; zaman yalnız olay/koşu damgasından; ifade boyutu ve derinliği sınırlı; workflow koşulu ve korelasyon/bekleme noktası ek koşulu aynı dil. _Kaynak:_ §1.7, §5.9, §10.3; MD-16, C-73, WF-8, WF-10.
- [ ] **Bekle adımı** — Belirli süre ya da saate kadar bekler; ≤ 90 gün. _Kaynak:_ §10.3; WF-8, WF-37.
- [ ] **Zaman penceresi adımı** — Gönderimi tanımlı pencereye (ör. iş saatleri, alıcı saat diliminde) erteler. _Kaynak:_ §10.3; WF-8.
- [ ] **Workflow "olay bekle" adımı** — A2'deki bekleme noktasıyla aynı yapı taşıdır: son tarih zorunlu, ≤ 30 gün; iki aşamalı eşleme (kiracı + olay türü + korelasyon anahtarı, sonra isteğe bağlı koşul; ikinci aşama koşulu yalnız birinci aşamada eşleşenlerde workflow koşul diliyle değerlendirilir); erken yanıt posta kutusunda tamponlanır; zaman aşımı dalı. _Kaynak:_ §10.3, §17.3, §17.4.5; WF-8, WF-12, AG-7, AG-14.

#### Yönlendirme
- [ ] **Adlandırılmış rota ağacı** — İç içe `single` (sırayla dene, ilk başarıda dur) / `all` (fan out) ağacı; stratejiler: `fallback`, `fanout`, `last_active`, `user_preference`, yalnız son aktif cihaz, görülmezse yükselt. Kanal adımı tek kanal yerine rota politikasına gönderebilir. _Kaynak:_ §4.2, §5.5, §10.3, §10.4; L-2, C-42, WF-8, WF-13.
- [ ] **Kategori varsayılan rotası** — Her kategori varsayılan rotaya bağlı; adım başka rota seçebilir (adım > kategori); rotalar yeniden kullanılır, değişiklik hepsine uygulanır. _Kaynak:_ §4.2, §5.5, §10.4; L-2, C-42, WF-14.
- [ ] **Fallback tetiği** — Varsayılan `on_failure` (kalıcı hata veya tükenmiş deneme bütçesi); geçici hata ilerletmez; `after_delay` isteğe bağlı, sıfır gecikme reddedilir; retry kanal başına ve teslim raporuna dayalı. _Kaynak:_ §10.4; WF-15.
- [ ] **Kilitli kategoride sıradaki kanala geçiş** — A4 kapısından geçemeyen kanal yerine rotadaki sıradaki kanal denenir; OTP alt türü kuralları korunur. _Kaynak:_ §13.3.4; PC-10.
- [ ] **Segment girdisi liste/topic olarak** — Kiracı segmenti kendi sisteminde hesaplar ve Relay'e liste ya da topic olarak verir; Relay öznitelik sorgusu çalıştırmaz. _Kaynak:_ §7.1, §7.10; E-67.

#### Yükseltme ve eskalasyon
- [ ] **Görülmezse yükselt** — `escalate_unless(seen | read | clicked | event)`, basamak başına süre; durdurma koşulunda kalan basamaklar iptal; varsayılan geçiş yalnız kalıcı hatada. _Kaynak:_ §4.2, §6.5, §10.5; L-4, INV-27, MKT-8, WF-21.
- [ ] **Yükseltme sinyali kanıta bağlı** — Durdurma yalnız `decision_grade = reliable` kanıtla: in-app görüldü, e-postada yalnız `human` tıklaması, push SDK makbuzu, müşteri olayı; açılma pikseli asla. Zaman tabanlı yükseltme ve eskalasyon zamanlayıcıları `unknown` durumundan bağımsız işler. _Kaynak:_ §10.5, §14.4.4, §14.6.3; WF-22, DS-21, DS-10, DS-31.
- [ ] **Eskalasyon politikası kademeleri** — Kademe = süre + yeni alıcı ve/veya daha müdahaleci kanal; panel/dosya/SDK'da tanımlanır; Suiss'te politika Work'ten gelir, Relay uygular; son kademe yalnız `waitpoint.expired` olayı, otomatik kabul/ret yok; kanal yükseltmesiyle aynı zamanlayıcı. _Kaynak:_ §1.7, §5.5, §6.6, §10.6; C-47, MD-2, INV-29, MKT-2, WF-23.

#### Digest
- [ ] **Digest pencere modeli** — `key` (alıcı her zaman parça), `mode` (`fixed`/`sliding`/`scheduled`), `debounce`, `max_wait`, `schedule`, `max_items`, `leading` (`immediate`/`none`); ateşleme `min(son+debounce, ilk+max_wait)`; render `total_activities`, `total_actors`, ilk/son N. _Kaynak:_ §4.2, §5.5, §10.7; C-48, L-8, MKT-21, WF-8, WF-26.
- [ ] **Digest değişmezleri** — Önce biriktirme tablosuna yaz sonra planla, süpürücü kurtarır; içerik DB'de, iş argümanında değil; okundu sinyali bekleyen pencereyi iptal eder; boş digest yok; tek olaylı digest tekil şablonla olayın kendisi; çıktı kafesten geçer; son tarihli, ≤ 31 gün. _Kaynak:_ §6.1, §6.6, §10.7; INV-3, INV-32, WF-27, WF-37.
- [ ] **Digest ve tekrar muafiyetleri** — `security`, `transactional`, `action_required` (Access semantik olayları dahil) digest'lenmez; `security` sınıfı ayrıca frekans tavanı ve içerik tekilleştirmesinden muaftır; `Idempotency-Key` ve `dedup_key` uygulanır. _Kaynak:_ §7.3.2, §10.7, §10.9; E-11, WF-28, WF-36.
- [ ] **Kümülatif digest güncellemesi** — Aynı collapse anahtarıyla ikinci digest birincinin yerini alır ve toplamı anlatır. _Kaynak:_ §10.7; WF-29.
- [ ] **Yoğunluk eşiği** — İsteğe bağlı alıcı/cihaz başına eşik aşılınca aynı kategorideki sonraki olaylar otomatik digest penceresine girer. _Kaynak:_ §10.7; WF-30.
- [ ] **Varsayılan digest pencereleri** — Doğrudan mesaj, grup, anma, yorum/inceleme, günlük/haftalık özet için varsayılan tablo (POLICY DEFAULT, ölçümle ayarlanır). _Kaynak:_ §10.7; WF-31.
- [ ] **Sabah patlaması önleme** — Sessiz saat sonunda biriken `social`/`marketing` digest'lenir ve deterministik jitter ile yayılır. _Kaynak:_ §13.9.1; PC-46.

#### Throttle ve tekrar korumaları
- [ ] **Throttle adımı** — Anahtar kiracı genelinde (workflow'lar arası), eşik, sabit ya da `throttle_until` pencere, alıcı tz'sinde dinamik pencere; aktif throttle API ile sıfırlanabilir; ≤ 31 gün; aşan olay `skipped` + throttle `rule_id`. _Kaynak:_ §4.2, §4.3.1, §5.5, §10.8; C-49, L-10, L-52, WF-8, WF-32, WF-37.
- [ ] **Throttle / frekans tavanı / teslim hızı ayrımı** — Üçü ayrı ayarlanır, birbirinin yerine kullanılmaz. _Kaynak:_ §4.2, §10.8; C-49, WF-33.
- [ ] **İçerik tekilleştirmesi** — Varsayılan kapalı; workflow başına `content_dedup: { window }`; `operational`'da alıcı+kanal+içerik 5 dk (PD) varsayılan açık; düşürülen "aynı içerik tekrarı" `rule_id`'siyle kaydedilir. _Kaynak:_ §1.7, §4.2, §5.10, §10.9; MD-20, L-9, C-81, MKT-7, WF-35.
- [ ] **Ayrı tekrar korumaları** — `Idempotency-Key`, `dedup_key` ve içerik tekilleştirmesi ayrı mekanizmalardır; teslim defteri `(notification, recipient, channel)` iç korumadır. _Kaynak:_ §5.10, §9.4, §10.9; C-81, WF-36.

#### Zamanlama ve süre
- [ ] **Sert süre limitleri** — `send_at` ≤ 90 gün (geçmiş tarih 422), bekle ≤ 90 gün, digest/batch ≤ 31 gün, throttle ≤ 31 gün, olay bekle/bekleme noktası ≤ 30 gün; aşan istek doğrulama hatası. _Kaynak:_ §2.4.4, §9.5, §10.10; F-16, WF-37, API-20.
- [ ] **İleri tarihli gönderim** — `send_at` kalıcı satır + zamanlayıcıyla, açık zamanlama tabanı olarak. _Kaynak:_ §9.5, §10.10; WF-37, WF-41, API-20.
- [ ] **`expires_at` ve `expired` terminal durumu** — OTP/doğrulamada zorunlu ve göndericiden; diğerlerinde kategori varsayılanı; süresi geçen mesaj `expired` + `rule_id`, sessizce silinmez. _Kaynak:_ §10.10; WF-38.
- [ ] **`on_expire`** — Süresi geçen güvenlik bildirimi için `drop` (varsayılan) / `inbox_only`; Access "ne zamana kadar" → `expires_at`. _Kaynak:_ §9.5, §10.10; WF-39, API-20.
- [ ] **Tekrar kuralları** — Alıcı ya da topic için RRULE mantığıyla, alıcı yerel saatinde; tanım olarak saklanır, her tekrar zamanında o anki yayın sürümüyle oluşur; kiracı başına üst sınır (PD); her an iptal. _Kaynak:_ §5.5, §10.11; C-52, WF-48, WF-49.
- [ ] **Patlama yumuşatma** — Saat başı zamanlamalarda deterministik jitter; okuma yolu yazma kuyruğunu beklemez. _Kaynak:_ §4.3.1, §10.11; L-43, WF-49.

#### Topic, deney ve gönderim modları
- [ ] **Topic ve abonelik** — Nesne + abonelik modeli, en fazla iki seviye; olay topic'e gönderilir; segment yok; topic ajan aboneliklerinin ve Access olay aboneliğinin ortak fanout temeli; koşu başı alıcı dondurma ve alıcı başına koşu kaydı. _Kaynak:_ §2.4.3, §4.2, §5.5, §10.13; C-51, L-3, L-31, F-5, MKT-21, WF-51, WF-55.
- [ ] **Topic fanout** — Fanout anında abone listesi donar; çok yoldan abone tek bildirim alır; liste ile gönderimde alıcılar istekte. _Kaynak:_ §10.13; L-31, F-5, WF-52.
- [ ] **Açık topic eşleşmesi** — Joker/bağlam tam eşleşmesi yok, gizli bağlam koşulu yok; aboneye ulaşmayan tetikleme `rule_id` ile kaydedilir. _Kaynak:_ §10.13; WF-53.
- [ ] **A/B deneyleri** — Kanal adımında 2–10 ağırlıklı varyant; kullanıcı bazlı deterministik bölme; varyant bildirim kaydına/plana yazılır; varyant başına gönderim/teslim/görülme/tıklama (insan/bot ayrımlı) raporu; üç yazım yolunda tanımlanır. _Kaynak:_ §5.5, §10.12; C-53, MKT-21, WF-50.
- [ ] **Gönderim modları `live | shadow | dry_run | off`** — Workflow başına, ortamdan ayrı; `shadow` hattı çalıştırıp kaydeder ama göndermez, `dry_run` kafesi çalıştırıp karar döner, `off` her bildirimi `skipped` + `send_mode_off` kaydeder (kill switch'in yerine geçmez); senkron karar hatası yalnız önizleme/test/`dry_run` uçlarında, normalde `202` sonrası `suppressed` + `rule_id`; canlıdaki test gönderimi `is_test` (gerçek sağlayıcı, ayrı faturalama/metrik satırı). _Kaynak:_ §5.12, §8.5; C-89, X-15.

#### Kampanya
- [ ] **Kampanya: hazırla, sonra tetikle** — Ayrı kampanya ucu; kitle büyüklüğüne göre model (normal / toplu kuyruk + şekillendirme / kampanya modu: zamanlanmış, oran bütçeli, ilerleme takipli, iptal edilebilir); hazırlıkta alıcı listesi (liste ya da topic) dondurulur, render ve `dedup_key` üretilir, tetikte yalnız gönderim; havuzlar önceden ısıtılır; teslim hızı ayarı ve kill switch kapsamı; "anında" iddiası yok, ilerleme arayüzü; öznitelik sorgulu segment yok. _Kaynak:_ §4.2, §5.4, §9.7, §10.10, §19.6.3; C-38, L-10, API-35, WF-44, T-23.
- [ ] **Toplu gönderim son teslim tarihi** — Hız sınırlı toplu gönderim/kampanya son tarih taşır; hız sağlayıcı limitini aşacak şekilde artırılmaz; kalanlar sayımla `expired` + kiracıya olay. _Kaynak:_ §4.2, §10.8; C-38, WF-34.
- [ ] **Kitle önizlemesi** — Gönderimden önce kaç alıcıya gideceği, hangi `rule_id` ile kaçının düşeceği ve tahmini maliyet gösterilir. _Kaynak:_ §8.5; X-14.
- [ ] **Kampanya güvenlikleri** — Rastgele örnek alıcıyla render önizlemesi ve onay; beklenenin çok üstü kitlede insan onayı; büyük kampanyada küçük yüzdeyle başlangıç. _Kaynak:_ §20.8; OP-47.

#### Bu aşamada doğrulanacak sınırlar
- **INV-3, INV-32, WF-27** — boş digest yok, tek olaylı digest olayın kendisi, önce biriktir sonra planla, süpürücü kurtarır.
- **INV-27, WF-21, WF-22, DS-21, DS-31** — yükseltme yalnız güvenilir sinyalle durur; açılma pikseli ve bot tıklaması sayılmaz; zamanlayıcılar `unknown`'dan bağımsız.
- **INV-29** — eskalasyonun son kademesi yalnız `waitpoint.expired`; otomatik kabul/ret yok.
- **X-8, X-9, WF-4** — her yapı üç yazım yolunda kurulabilir; koddan yönetilen akışın yapısı panelden değişmez.
- **X-15** — gönderim modlarının davranışı; `off` kill switch değildir.
- **E-11, WF-28, WF-36** — `security`/Access semantik olayları digest, frekans tavanı ve içerik tekilleştirmesinden muaf; idempotency uygulanır.
- **WF-10** — koşul dili döngüsüz, dış çağrısız, sınırlı boyut/derinlik.
- **WF-13, WF-14, WF-15** — rota ağacı semantiği, adım > kategori, fallback yalnız kalıcı hata/tükenmiş bütçede, sıfır gecikme reddi.
- **WF-26, WF-29** — digest ateşleme formülü; kümülatif güncelleme.
- **WF-32, WF-34** — throttle anahtarı workflow'lar arası; toplu gönderim son tarihi sağlayıcı limitini aşmaz, kalanlar `expired`.
- **WF-35** — içerik tekilleştirmesi varsayılan kapalı, `operational`'da 5 dk açık, düşürme `rule_id`'li.
- **WF-37, WF-38, WF-39** — sert süre limitleri; `expired` terminal durumu, sessiz silme yok; `on_expire`.
- **WF-44** — kampanyada dondurma hazırlıkta, tetikte yalnız gönderim.
- **WF-49** — tekrar kuralı kiracı üst sınırı ve deterministik jitter.
- **WF-50** — deterministik varyant bölmesi.
- **WF-52, WF-53** — fanout anında dondurma, çok yoldan tek bildirim; joker eşleşme yok.
- **PC-10, PC-46** — kilitli kategoride sıradaki kanal; sabah patlaması jitter'ı.
- **AG-14, WF-12** — ikinci aşama koşulu yalnız birinci aşamada eşleşenlerde; olay bekle adımında son tarih zorunlu ve zaman aşımı dalı.

---

### Aşama 9 — Inbox ve realtime

A2'deki ortak kalıcı kayıt çekirdeğinin (alıcı başına sıra numaralı kayıt, cursor, `since`) insan yüzünü kurar: inbox deposu ve öğe modeli, durumlar ve niyet protokolü, sayaçlar ve rozet, WebSocket/SSE realtime, abone jetonu, cihazlar arası yayılım ve saklama. A2 (kayıt çekirdeği, outbox), A3 (API ve istemci yüzeyi) ve A8'e (digest, `on_expire`, cihaz stratejisi seçimi) dayanır; ajan yüzü A12'dedir.

#### Spec dışı ön koşullar
- [ ] **Inbox alan boyut sınırları ve `item_created` boyut eşiği** — IN-4/IN-27 sınırların yayımlanmasını ister; değerler yok. (Adem kararı)
- [ ] **"Tümünü okundu" ilk mekanizması** — IN-14 mekanizmayı ölçüme bağlar (ENGINEERING ASSUMPTION); API semantiği sabit, ilk uygulama seçimi gerekir. (Adem kararı)
- [ ] **Abone jetonu imza algoritması** — IN-42 "algoritmalar §18" der; TN-35 EdDSA/ES256 verir; varsayılanın hangisi olduğu ve anahtar rotasyonu yazılmamış. (Adem kararı)
- [ ] **Bağlantı kabul hızı, snapshot hız sınırı, sessiz push kısma değerleri** — IN-34/IN-35 sınır ister, değer yok. (Adem kararı)

#### Inbox deposu ve öğe modeli
- [ ] **Ayrı inbox deposu** — Teslim tablolarından ayrı; alıcıya göre hash bölümleme; keyset; sayaç tablosu öğe yazımıyla aynı transaction; in-app teslim kaydı öğeye işaret eder, `delivered` kanıtı öğenin commit'idir. _Kaynak:_ §15.1.2; IN-2.
- [ ] **Inbox kapsamı** — Kiracı × ortam × isteğe bağlı alt kiracı; kapsam başına sayaç; kapsam dışı öğe listelenmez. _Kaynak:_ §15.1.7; IN-7.
- [ ] **Yalnız inbox alıcısı** — `to: {id}` ile açık oluşturma, adres = kimlik; hayalet alıcı yok. _Kaynak:_ §15.1.8; IN-8.
- [ ] **Öğe modeli (konu + aktiviteler)** — Aynı konu mevcut öğeyi günceller; digest yeni öğe açmaz, `activity_count` ve son aktör/zamanı günceller; alanlar başlık, gövde, yapılandırılmış içerik, kategori, etiket, `severity`, `group_key`, `expires_at`, `snoozed_until`, `state_version`, `locale`, `dir`; gönderildiği andaki render saklanır, şablon yeniden çalışmaz; alan boyut sınırları yayımlanır. _Kaynak:_ §1.7, §4.2, §5.4, §5.8, §10.7, §15.1.4; C-69, C-37, L-8, MD-9, INV-47, WF-29, IN-4.
- [ ] **Tekil ve idempotent öğe** — Alıcı × bildirim başına en fazla bir öğe; tekrar işleme mevcut öğeyi döndürür; kimlik ve `state_version` API'de birlikte. _Kaynak:_ §15.1.5; IN-5.
- [ ] **Kişisel kayıt ve duyuru** — Kişisel inbox yazma anında yayılır; kiracı/alt kiracı/liste duyurusu ayrı kayıt, kişi başına satır yok, okuma anında birleşir; duyuru durumu yalnız eylemde alıcı başına yazılır; sayaçlar birleşik görünümü sayar; kiracı geneli duyuru bu kayıtla yapılır. _Kaynak:_ §5.8, §9.7, §15.1.3; C-70, API-35, IN-3.
- [ ] **Inbox öğesi bildirimdir, görev değildir** — Relay insan için görev/iş kuyruğu nesnesi üretmez; insan iş ve onay kuyruğu Work'ün (ya da kiracının) işidir. _Kaynak:_ §7.4; E-42.
- [ ] **Eylem butonu onay değildir** — Inbox butonu hiçbir zaman onay kaydı üretmez. _Kaynak:_ §15.1.6; IN-6.

#### Durumlar ve niyetler
- [ ] **Öğe durumları ve eylemleri** — Görüldü, okundu/okunmadı, arşivle/çıkar, gizle, ertele: `seen` (monoton), `read`⇄`unread`, `archived`⇄`unarchived`, `hidden` (kullanıcı için terminal; arayüzde "sil" etiketiyle gösterilebilir, satır saklama süresince kalır), `snoozed` (`snoozed_until` sonra geri gelir); `read` `seen`'i getirir. Kategori/etiket sekmeleri, önem ve her bildirimde ilgili kategori tercihine kısayol. _Kaynak:_ §8.6, §15.1.1, §15.2.1; X-16, IN-1, IN-9.
- [ ] **Görüldü/okundu iki eksen** — Görüldü rozetin varsayılan kaynağı, okundu liste görünümü; tek bayrağa indirgenmez. _Kaynak:_ §15.2.2; IN-10.
- [ ] **İki monoton sunucu damgası** — `seen`/`read` monoton; `read_at`/`unread_marked_at`, `archived_at`/`unarchived_at`, etkin durum daha yeni damga; damga sunucuda, istemci saati yalnız teşhis; gelecek zaman yok; her değişiklik `state_version`++. _Kaynak:_ §6.2, §15.2.3; INV-7, IN-11.
- [ ] **Niyet protokolü** — `{op, item_id, client_seq, base_state_version}`; monoton işlemler koşulsuz eşgüçlü; `unread`/`unarchive` iyimser eşzamanlılık, bayat sürümde `409` + güncel durum. _Kaynak:_ §15.2.4; IN-12.
- [ ] **Eski ters niyetin reddi** — Daha büyük `state_version` görülmüşse ters yöndeki eski niyet uygulanmaz; monoton niyet uygulanır. _Kaynak:_ §15.2.5; IN-13.
- [ ] **"Tümünü okundu işaretle"** — Tüm inbox ya da kategori/o anki filtreli görünüm; kesme noktası basılma anı; okunmamış sayacı sıfırı + okundu işareti tek işlemde; arşivlemez; kısa geri al penceresi; rozet iyimser güncellenir; mekanizma ölçüme bağlı, API semantiği bağımsız. _Kaynak:_ §8.6, §15.2.6; X-17, IN-14.
- [ ] **Asenkron parçalı toplu işlemler** — Keyfi filtreli toplu işlem, toplu arşiv/gizle asenkron, parçalı, ilerleme bilgisiyle. _Kaynak:_ §15.2.6; IN-14.
- [ ] **Geri çekme** — Bildirim iptali ya da kiracı geri çekmesinde teslim edilmiş öğe `retracted` olarak gizlenir, sayaçlar güncellenir, realtime yayımlanır. _Kaynak:_ §9.13, §15.2.8; API-59, IN-16.
- [ ] **Süre sonu** — `expires_at`'i geçen öğe listeden ve sayaçlardan düşer, kayıt saklanır. _Kaynak:_ §15.2.9; IN-17.
- [ ] **`on_expire: inbox_only`** — Süresi geçmiş güvenlik bildirimi gönderen isterse yalnız inbox'a yazılır, dış kanala gitmez. _Kaynak:_ §7.3.2; E-13.

#### Sayaçlar ve rozet
- [ ] **Üç sayaç** — `unseen_count`, `unread_count`, `total_count` öğe yazımıyla aynı transaction'da. _Kaynak:_ §15.3.1; IN-18.
- [ ] **Sunucu tarafı sürümlü mutlak rozet** — Rozet sunucuda hesaplanan mutlak sayıdır, +1 yok; kaynak uygulama başına `unseen` (varsayılan) ya da `unread`, ikisi de tutulur; `counters.version` her değişiklikte artar, istemci küçük sürümü yok sayar; çevrimdışı eski niyet yeniyi ezemez; bütün cihazlar aynı sayıyı görür. _Kaynak:_ §5.8, §8.6, §15.3.1, §15.3.2; INV-54, X-16, IN-18, IN-19.
- [ ] **Platform rozet eşlemesi** — iOS `aps.badge = min(sayı, 999)`, emin değilse alan yok; Android `notification_count`; Web `setAppBadge` (PWA); UI tavanı `99+`; push sayısı sayaç işleminin kendi sonucundan. _Kaynak:_ §15.3.3; IN-20.
- [ ] **Gecelik sayaç uzlaştırması** — Son 24 saatte değişen alıcıların sayaçları kayıtlarla karşılaştırılır, yalnız sapanlar düzeltilir; sapma metriği alarm eşikli. _Kaynak:_ §15.3.1, §20.7; IN-18, OP-42.
- [ ] **Tutarsızlık raporu ucu** — İstemci tutarsızlık bildirince o alıcı için anında uzlaştırma; tutarsızlık oranı metriği. _Kaynak:_ §15.3.4; IN-21.

#### Realtime yayın ve senkron
- [ ] **Outbox yayın yolu** — Öğe + sayaç + yayın kaydı tek transaction; yayın commit sonrası, en az bir kez; yazma yolunu bloklamaz. _Kaynak:_ §15.4.4; IN-25.
- [ ] **WebSocket ve SSE taşımaları** — Relay (Phoenix) içinde; Phoenix Channels ve SSE (`Last-Event-ID`) eşit sınıf, long-poll/periyodik yoklama son yedek; ayrı realtime sunucusu yok; yalnız sinyal, realtime geçmişi otoriter değil, kopma kayıp üretmez; fanout uygulama katmanında (WAL değil). _Kaynak:_ §1.7, §4.2, §4.3.1, §6.10, §15.4.2, §19.2; MD-5, L-18, L-45, INV-53, IN-23, T-4.
- [ ] **Doğruluk Postgres'te, Valkey sinyal** — Düğümler arası Valkey pub/sub yalnız "yeni var + seq"; veri Postgres'ten; kaçırılan sinyal cursor ile tamamlanır; Valkey yoksa kısa aralıklı yoklama; realtime yokken HTTP ile doğru veri. _Kaynak:_ §15.4.3; IN-24.
- [ ] **Zarf ve olay türleri** — `{t, v, ts, d}` + her mesajda `counters`; `inbox.item_created`, `inbox.item_updated`, `inbox.items_bulk_updated`, `inbox.counters_changed`, `stream.resync_required`; AsyncAPI'de tek takım. _Kaynak:_ §5.14, §15.4.5; L-45, IN-26.
- [ ] **Kendine yeterli, sürümlü yayın** — `item_created` tam öğe taşır (sınır içinde, aşarsa ince özet); her yayın `state_version`/`counters.version` taşır. _Kaynak:_ §15.4.6; IN-27.
- [ ] **Soğuk ve delta senkron** — Soğuk: ilk sayfa + sayaçlar; delta `changes?since=` → oluşan/güncellenen/gizlenen + yeni cursor; en fazla 500 değişiklik, aşımda `truncated`; replay üst sınırı. _Kaynak:_ §15.4.8; IN-29.
- [ ] **Keyset sayfalama** — Opak cursor; offset ve toplam sayfa yok; offset yalnız destek/yönetim uçlarında ayrı limitle. _Kaynak:_ §15.4.9; IN-30.
- [ ] **Yazmalar yalnız REST** — Durum niyetleri, toplu işlemler, görüntüleme bildirimi REST'ten; realtime üzerinden yazma/yayın yok. _Kaynak:_ §15.4.10; IN-31.

#### Abone jetonu ve istemci yüzeyi
- [ ] **Abone jetonu basımı** — Kiracı backend'i API anahtarıyla `POST /v1/subscribers/{id}/tokens` üzerinden kısa ömürlü jeton ister, Relay basar; kapsamlar `inbox:read`, `inbox:write`, `preferences`, `devices:write`; Access'siz ve her IdP (dış IdP dahil) ile çalışır; Access jetonu inbox erişimi için doğrudan kabul edilmez. _Kaynak:_ §1.7, §5.2, §7.3.6, §7.9, §9.9, §15.6.1; C-17, MD-19, E-23, E-62, API-45, IN-41.
- [ ] **Jeton biçimi ve yalıtımı** — Asimetrik imzalı (EdDSA/ES256) opak belirteç; `aud` inbox/realtime yüzeyi; kiracı + ortam kapsamı ve izinli topic'ler jetonda; varsayılan 15 dk ömür; yalnız o abonenin inbox/tercih/cihazına dokunur; kiracı kimliği istemcinin göreceği alana yazılmaz. _Kaynak:_ §15.6.2, §18.3.4, §18.10; INV-39, IN-42, TN-25, TN-35.
- [ ] **İstemci yüzeyi izin listesi** — İstemci gizli anahtar tutmaz; abone jetonu yalnız izin listesindeki uçlarda geçerli; `POST /v1/events` istemciye kapalı; mobil SDK olay tetiklemez, profil/izin yazmaz. _Kaynak:_ §9.9, §15.6.3; API-45, IN-43.
- [ ] **`devices:write` kapsamı** — Mobil SDK yalnız kendi cihazını kaydeder/günceller/kaldırır; başka aboneye bağlayamaz, jetonu geri okuyamaz. _Kaynak:_ §9.9; API-46.
- [ ] **Sunucu tarafı abonelik** — İzinli topic'ler jetonda; istemci yayın yapamaz, kendisi başka topic'e abone olamaz; kiracı kimliği topic/zarfta yok; geçmiş realtime'dan sorgulanamaz, yalnız yetkili REST. _Kaynak:_ §1.7, §5.2, §15.4.11; C-17, MD-19, IN-32.
- [ ] **Yetki sürekliliği** — Abone/kiracı askısı ya da jeton iptalinde açık realtime bağlantılar sunucudan kesilir; yeniden bağlanma ve kurtarma yetkiyi baştan kontrol eder. _Kaynak:_ §4.3.1, §6.7, §9.9, §15.4.12, §18.1.1; L-44, INV-42, API-45, IN-33, IN-42, TN-10.
- [ ] **Yeniden bağlanma dalgası savunması** — Düğüm başına bağlantı kabul hızı sınırı; anlık görüntü ucu alıcı ve kiracı başına hız sınırlı. _Kaynak:_ §15.4.13; IN-34.

#### Cihazlar arası yayılım
- [ ] **Cihazlar arası yayılım** — Varsayılan bütün aktif cihazlar; bir cihazda okununca diğerlerinde okundu ve gösterilen bildirim sessiz push/collapse ile kaldırılır (iOS'ta SDK ile). _Kaynak:_ §10.4, §15.5.1; WF-17, IN-38.
- [ ] **"Yalnız son aktif cihaz" stratejisi** — Workflow adımı/rotada seçilebilir cihaz stratejisi. _Kaynak:_ §10.4, §15.5.2; WF-17, IN-39.
- [ ] **Aktif bağlantılı cihaza push yok** — Aktif realtime bağlantısı olan cihaza aynı bildirim için push gitmez; varlık sinyali kendi bağlantı kaydı + görüntüleme bildiriminden kısa ömürlü kayıt; push kararı realtime'a senkron sorgu yapmaz. _Kaynak:_ §10.4, §15.5.3; WF-17, IN-40.
- [ ] **Mobil senkron sinyali** — iOS sessiz push yalnız `{sync, counter_version}`, alıcı başına kısılır; Android senkron sinyali normal öncelik + kısa TTL, görünür bildirim yüksek öncelik. _Kaynak:_ §15.4.14; IN-35.

#### Saklama
- [ ] **Inbox saklama modeli** — Fiziksel silme yok, yalnız arşiv/gizle durumu; KVKK silmesi crypto-shredding; saklama sonu yumuşak silme + crypto-shred; varsayılan görünür son 1.000 öğe / aktif 90 gün / arşiv 1 yıl (PD), Ek C sınırları içinde kiracı ayarı; teslim saklamasından ayrı. _Kaynak:_ §1.7, §15.7.1, §20.4; C-69, IN-44, OP-22.
- [ ] **`retention: none` + in-app reddi** — Birleşim kabul anında doğrulama hatasıyla reddedilir. _Kaynak:_ §14.9.2, §15.7.3; IN-46, DS-45.

#### Bu aşamada doğrulanacak sınırlar
- **INV-7, IN-9, IN-10, IN-11** — `seen`/`read` monoton, damgalar sunucuda, iki eksen tek bayrağa inmez.
- **INV-47, IN-4, IN-5** — öğe gönderildiği andaki render'ı taşır; alıcı × bildirim başına tek öğe, tekrar işleme idempotent.
- **IN-2, IN-25** — sayaç ve yayın kaydı öğeyle aynı transaction; `delivered` kanıtı öğenin commit'i.
- **IN-6, E-42** — inbox butonu onay kaydı üretmez; inbox görev kuyruğu değildir.
- **IN-12, IN-13, INV-54** — niyet protokolü; bayat ters niyet uygulanmaz, `409`.
- **X-17** — "tümünü okundu" yalnız filtreli görünüm, kesme noktası basılma anı, arşivlemez.
- **INV-54, IN-19** — rozet mutlak ve sürümlü; küçük sürüm yok sayılır.
- **INV-53, IN-24, IN-27, IN-29** — realtime yalnız sinyal; doğruluk Postgres'te; kopma kayıp üretmez; delta senkron sınırı ve `truncated`.
- **IN-31, IN-32** — realtime üzerinden yazma/yayın yok; istemci kendi abone olamaz, kiracı kimliği zarfta yok.
- **INV-39, IN-43, API-45, API-46, TN-25, E-23** — abone jetonu dar kapsamlı; Access jetonu kabul edilmez; istemci olay tetikleyemez; `devices:write` yalnız kendi cihazı.
- **INV-42, IN-33, TN-10** — askı/iptalde bağlantılar kesilir, yeniden bağlanmada yetki baştan kontrol.
- **IN-40, WF-17** — aktif realtime bağlı cihaza push yok; cihazlar arası okundu yayılımı.
- **API-59** — teslim edilmiş öğe geri çekilebilir.
- **IN-44, OP-22, IN-46** — fiziksel silme yok; saklama varsayılanları; `retention: none` + in-app reddi.

---

### Aşama 10 — Webhook ve olay teslimi

Relay'in kendi olaylarını ve `webhook` kanalını tek, dayanıklı bir teslim motoruyla kiracı hedeflerine (HTTPS, kuyruk/akış, nesne deposu) imzalı, kurtarılabilir ve SSRF'e karşı korumalı biçimde ulaştırmak. A1 (outbox, saklama sınıfları, denetim kaydı), A2 (retry/backoff, DLQ politikası, devre kesici, hız limiti, adalet), A3 (API, sözleşmeler, CLI, test düzlemi), A4 (atlama kayıtları) ve A7 (teslim olayları) üzerine kurulur.

#### Spec dışı ön koşullar
- [ ] **Değeri verilmemiş PD'ler** — tüketici başına uç sınırı (WH-16), nesne deposu parti eşikleri (WH-21), yük boyutu sert sınırı (WH-29), teslim günlüğü saklaması (WH-30); kiracı retry takvimi ayarının alt/üst sınırları (WH-22 ⚠️). OQ-27: değer konmadan özellik yayımlanmaz. (Adem kararı)
- [ ] **Kesin olay adı listesi** — WH-14 sözleşme-önce AsyncAPI 3.1 + JSON Schema 2020-12 ister; WH-15 yalnız aileleri sayar, olay adları yazılı değil. Katalog yazılıp onaylanmadan olay üreten kod yazılmaz. (Adem kararı)
- [ ] **Bulut metadata adres listesi** — WH-41 "bulut sağlayıcılarının metadata adresleri" der, somut liste (veri dosyası) yok. (Adem kararı)
- [ ] **Devre kesici eşikleri** — WH-35 "art arda hata/zaman aşımı" der; açılma eşiği, açık süre ve yarı açık yoklama parametreleri yok. (Adem kararı)
- [ ] **İşletim e-postasının göndericisi** — WH-34 kiracıya e-posta bildirimi ister; Relay'in kendi operasyon e-postasının hangi gönderici/alan adıyla gideceği tanımsız. (Adem kararı)

#### Teslim motoru çekirdeği
- [ ] **Tek teslim motoru, iki kullanım** — Relay olayları ve workflow `webhook` kanalı (event destination) aynı retry, imza, DLQ, replay, SSRF ve uç sağlığı yolunu kullanır; bütün hedef türleri (HTTPS, kuyruk/akış, S3 uyumlu depo) bu motorun arkasındadır. _Kaynak:_ §1.7, §5.11, §16.1.1; C-83, INV-39, MKT-5, WH-1.
- [ ] **Kavram modeli ve tekillik** — Olay türü / tüketici / uç / mesaj / deneme tabloları; `(endpoint_id, event_id)` için zamandan bağımsız DB tekillik kısıtı (kuyruk tekilliği yalnız ön filtre). _Kaynak:_ §4.3.1, §6.3, §16.1.2; L-41, INV-12, WH-2.
- [ ] **Giden olay garanti dili** — Giden olaylar en az bir kez, tekrar olabilir, sıra garantisi yok; dokümantasyon ve API metinlerinde "exactly-once" denmez, verilmeyen garanti iddia edilmez. _Kaynak:_ §6.12, §16.1.3; WH-3, INV-60.
- [ ] **Hedef portu ve HTTPS hedefi** — Ortak hedef arayüzü; ilk hedef HTTPS + Suiss imzası, isteğe bağlı mTLS ya da OAuth2 client credentials. _Kaynak:_ §16.4.1; WH-17.
- [ ] **Hedef türüne göre başarı** — HTTPS 2xx, kuyruk/akış kalıcı yazım onayı, nesne deposu yazım onayı; hepsinde en az bir kez. _Kaynak:_ §16.4.2; WH-18.
- [ ] **Hedef kimlik bilgileri sır referansı** — DB'de yalnız sır referansı; URL/bağlantı dizgesinde, loglarda ve deneme günlüğünde düz sır yok. _Kaynak:_ §16.4.3; WH-19.
- [ ] **Deneme günlüğü** — Her deneme için gövde özeti, imza, hedef IP, durum, süre ve yanıtın ilk 8 kB'ı; teslim günlüğü saklama sınıfında. _Kaynak:_ §16.2.7; WH-10.

#### Suiss webhook profili
- [ ] **Profil imzası** — Standard Webhooks başlıkları (`webhook-id`/`-timestamp`/`-signature`), imzalanan `{id}.{ts}.{gövde}` ham bayt üzerinde; varsayılan `v1a` Ed25519, `v1` HMAC-SHA256 yalnız uç başına uyumluluk. Yüksek hacimli imza anahtarları kiracı veri anahtarıyla şifreli, yalnız imzalayan süreçte çözülür. _Kaynak:_ §4.2, §16.2.1, §18.4.2; L-21, WH-4, TN-32, TN-35.
- [ ] **Uç başına imza anahtarı** — Uçlar arasında paylaşılmayan anahtar; Ed25519 özel anahtar KMS/HSM'de, açık anahtar okunur/yayımlanır; HMAC sırrı yalnız oluşturmada bir kez gösterilir. _Kaynak:_ §16.2.2; WH-5.
- [ ] **Çakışmalı anahtar rotasyonu** — Pencerede iki imza birlikte; varsayılan 24 sa (0–168 sa); pencere sonunda eski anahtar devre dışı; rotasyon denetim kaydına girer. _Kaynak:_ §16.2.3, §18.4.2; WH-6, TN-47.
- [ ] **Denemede yenilenen zaman damgası ve tüketici kuralları** — `webhook-timestamp` her denemede yeni, oluşma zamanı gövdede `time`; yayımlanan doğrulama kuralları: ham gövde, sabit zamanlı karşılaştırma, 5 dk tolerans, `webhook-id` ≥ 96 sa saklama. _Kaynak:_ §16.2.4; WH-7.
- [ ] **İmzasız başlıklar güvenlik dışı** — Olay türü/deneme no gibi imzasız başlıklara güvenlik kararı dayanmaz; dokümantasyonda yazılı. _Kaynak:_ §16.2.6; WH-9.
- [ ] **CloudEvents zarfı** — Structured JSON (`id` = `webhook-id`, sürümlü `dataschema`); `seq`, `traceparent`, ortam uzantıları; kuyruklarda bağlamaya göre structured/binary; B kullanımında iç kiracı kimliği yok, `source` kiracı tanımlı. _Kaynak:_ §16.2.5; WH-8.

#### Olay sözleşmesi ve katalog
- [ ] **Olay kataloğu** — `noun.verb_past` tek sözlük; AsyncAPI 3.1 + JSON Schema 2020-12, sürümlü şemalar, sözleşme önce; kiracı olay türleri kiracı kapsamında aynı yapıda, şema + örnek yükle. _Kaynak:_ §16.3.4; WH-14.
- [ ] **Relay olay aileleri ve atlama olayı** — Teslim projeksiyonu, atlama/render hatası, etkileşim, bounce/şikâyet, izin/uyum, abone/cihaz/tercih, kota, bekleme noktası/ajan, webhook işletimi aileleri katalogda; her atlama `notification.suppressed` olayıyla `reason` + `rule_id` taşıyarak kiracıya bildirilir. _Kaynak:_ §14.5.1, §16.3.5; WH-15, DS-24, L-11.
- [ ] **İnce olay varsayılanı** — `type` + `id` + ilgili kimlikler, PII yok; ayrıntı yetkili API'den okunur. _Kaynak:_ §4.2, §5.11, §16.3.1; L-22, C-84, WH-11.
- [ ] **Uç bazında snapshot** — Beyaz listeli alanlar; uç sürümüne sabit, liste değişikliği yeni uç sürümü; PII alanı açık seçim + uyarı. _Kaynak:_ §16.3.2; WH-12.
- [ ] **Webhook payload sürümü ayrı** — Uç oluşturulurken sabitlenir; API sürümü yükseltmesi webhook payload'ını değiştirmez. _Kaynak:_ §9.11; API-55.
- [ ] **Abonelik filtresi ve uç sınırı** — Uç yalnız seçtiği türleri alır, boş seçim hiçbir şey; `*` açık seçim + uyarı; kiracı başına (20) ve tüketici başına uç sınırı; aynı URL'ye birden çok uç. _Kaynak:_ §16.3.6, §22.3; WH-16, OQ-27.
- [ ] **Sıra: `seq` ve bölüm anahtarı** — Sıra garantisi yok; konu başına monoton `seq`; Kafka gibi bölümlü hedeflerde sıra anahtarı = bölüm anahtarı. _Kaynak:_ §16.4.4, §17.7; WH-20, AG-24.

#### Yeniden deneme ve terminal durumlar
- [ ] **Yeniden deneme takvimi** — 10 deneme ~76 sa; mesaj kimliğinden deterministik ±%20 jitter; kiracı uç başına sınırlar içinde değiştirir; sonsuz retry yok. _Kaynak:_ §16.5.1; WH-22.
- [ ] **Zaman aşımları** — Bağlantı 5 sn, toplam 20 sn, yanıtın en fazla 8 kB'ı okunur. _Kaynak:_ §16.5.3; WH-24.
- [ ] **Durum kodu tablosu** — 2xx başarı; 3xx izlenmez → `failed_permanent` (`redirect_not_followed`) + sağlık uyarısı; 410 kalıcı + uç devre dışı; 401/407/409/429/5xx ve bağlantı/zaman aşımı/TLS retry; diğer 4xx kalıcı. _Kaynak:_ §16.5.2; WH-23.
- [ ] **`Retry-After` işleme** — 429/503'te takvim ile `Retry-After`'ın uzunu; sayaç tüketmez; mesaj başına en fazla 3 kez. _Kaynak:_ §16.5.4; WH-25.
- [ ] **Tüketici iptal sinyali** — `webhook-delivery: abort-message` → `failed_permanent` (`aborted_by_consumer`). _Kaynak:_ §16.5.5; WH-26.
- [ ] **Ayrık terminal durumlar** — `delivered`, `failed_permanent`, `exhausted`, `expired`, `window_exceeded`, `dead_lettered`, `cancelled`; `delivered` dışındakiler DLQ'da kalıcı. _Kaynak:_ §16.5.6; WH-27.
- [ ] **Birikme yaşı ve pencere aşımı** — Uç başına en eski bekleyen mesaj yaşı metriği; hedef hız sınırı × retry penceresi etkileşimi; "pencere doldu" ayrı terminal durum `window_exceeded` + kiracı alarmı. _Kaynak:_ §4.3.1, §16.5.7; L-39, WH-28.
- [ ] **Yük boyutu sert sınırı** — Aşan olay `dead_lettered` (`payload_too_large`) ve kaydedilir; ince olay hedefi < 20 kB. _Kaynak:_ §16.5.8, §22.3; WH-29, OQ-27.

#### Dayanıklı log ve kurtarma
- [ ] **Dayanıklı log, DLQ ve kaçırılan olaylar** — Kalıcı, listelenebilir, filtrelenebilir DLQ; uç + zaman aralığıyla "kaçırılan olaylar" (DLQ + devre dışıyken denenmemiş); teslim günlüğü API'si; saklama kiracı politikası parametresi. Müşteri ucu çalışmıyorsa retry, DLQ ve replay uygulanır, olay atılmaz, tamponda kalır. _Kaynak:_ §4.2, §4.3.1, §6.1, §7.11, §16.6.1, §22.3; L-23, L-38, INV-3, INV-4, WH-30, OQ-27.
- [ ] **Kurtarma API'si** — Tek mesaj yeniden gönder, `recover`, filtreli toplu retry, başka uca replay, pause/resume (birikir, atılmaz), planlanmış retry iptali. _Kaynak:_ §16.6.2; WH-31.
- [ ] **Elle gönderim × otomatik retry kuralları** — Takvimdeyken elle deneme sayaç tüketmez, başarıda bekleyenler iptal; terminalde tek deneme, başarısızsa durum korunur; toplu/recover takvimi baştan başlatır; aynı anda tek deneme. _Kaynak:_ §4.3.1, §16.6.3; L-40, WH-32.
- [ ] **Kurtarmada kimlik koruma ve adil hız** — Yeniden gönderim/recover/replay `webhook-id`'yi korur, deneme no artar; uç hız sınırı içinde, kiracılar arası adil, canlı trafiği bastırmadan. _Kaynak:_ §16.6.4; WH-33.

#### Uç sağlığı ve izolasyon
- [ ] **Uç izolasyonu ve adalet** — Uç başına eşzamanlılık ve hız sınırı (kiracı ayarlı); yavaş uç diğerlerini bloklamaz; kiracı başına kuyruk yok, adalet kuyruk içinde. _Kaynak:_ §16.7.4; WH-38.
- [ ] **Uç devre kesicisi** — Art arda hata/zaman aşımıyla açılır; açıkken olay bekletilir; yarı açıkta sınırlı yoklama; açık süre sayaç tüketmez, pencere işler. _Kaynak:_ §16.7.1; WH-35.
- [ ] **Otomatik devre dışı bırakma** — 5 gün kesintisiz hata (başlatma: 24 sa içinde çoklu hata ve ilk–son ≥ 12 sa); tek başarı sıfırlar; 410 anında; 72. saatte uyarı; uç başına kapatılabilir. _Kaynak:_ §16.7.2; WH-36.
- [ ] **Devre dışı uçta veri kaybı yok** — Yeni olaylar denenmez, "kaçırılan olaylar"a yazılır ve saklanır; yeniden etkinleştirmede `recover`. _Kaynak:_ §16.7.3; WH-37.
- [ ] **Uç sağlık verisi ve bildirimi** — Başarı oranı, gecikme dağılımı, son başarı, birikme yaşı, kesici durumu, devre dışı nedeni, son hatalar; yanıt vermeyen uç için otomatik kiracı bildirimi. _Kaynak:_ §16.7.5; WH-39.
- [ ] **Webhook işletim olayları** — `webhook.attempt_exhausted`, `webhook_endpoint.disabled`, `webhook_endpoint.recovered`; diğer uçlara, panele, e-postaya; devre dışı uç kendi olayını almaz. _Kaynak:_ §16.6.5; WH-34.

#### SSRF ve ağ güvenliği
- [ ] **Uç kayıt kuralları** — Yalnız `https://` (test dahil), port 443 (+ kurulum izin listesi), userinfo reddi, kayıtta A/AAAA erken kontrolü (güvenlik sınırı değil). _Kaynak:_ §16.8.1; WH-40.
- [ ] **Bağlanma anında IP doğrulama** — Çöz, doğrula, doğrulanmış IP'ye bağlan (SNI/`Host` özgün ad); IPv4-mapped indirgeme; özel/metadata IP reddi; engelli aralıklar ve bulut metadata adresleri veri. _Kaynak:_ §4.2, §16.8.2; L-24, WH-41.
- [ ] **Ağ izolasyonu ve yönlendirme yasağı** — Teslim işçileri iç servislere erişimsiz ayrı ağ bölümünden çıkar; isteğe bağlı IP filtreli çıkış proxy'si; yönlendirme izlenmez. _Kaynak:_ §16.8.3; WH-42.
- [ ] **SSRF kapsamı** — Kurallar HTTPS uçları, workflow `webhook` adımı, A2A push, kuyruk/aracı adresleri ve OAuth2 token uçlarında; `webhook` adımı yalnız kayıtlı uca, hesaplanan URL yok, yanıt workflow'a veri dönmez. _Kaynak:_ §16.8.4; WH-43.
- [ ] **Self-host iç ağ izin listesi** — Varsayılan kapalı; yalnız kurulum operatörü CIDR/ana makine izin listesi, kiracı açamaz; değişiklik denetim kaydında; bağlanma anı doğrulaması sürer; metadata ve geri döngü eklenemez; SaaS'ta yok. _Kaynak:_ §16.8.5; WH-44.
- [ ] **Uç ortamı ve test olayı** — Uç ortamına bağlı ve değiştirilemez (ortam istemciden alınmaz); test düzlemi aynı SSRF kuralları; her uç için sahte olay gönderen test işlemi. _Kaynak:_ §16.8.6; WH-45.

#### Ek hedef türleri
- [ ] **Aracı hedefleri: Kafka, NATS JetStream, RabbitMQ** — SASL/TLS istemci sertifikası/kullanıcı kimlik bilgisiyle. _Kaynak:_ §16.4.1; WH-17.
- [ ] **Bulut hedefleri: SQS/SNS/EventBridge, Pub/Sub, Service Bus/Event Grid** — IAM/servis hesabı/bağlantı ya da yönetilen kimlikle. _Kaynak:_ §16.4.1; WH-17.
- [ ] **S3 uyumlu nesne deposu hedefi** — Süre/boyut eşiğiyle parti, CloudEvents JSON satırları, parti kimliğinden türetilen idempotent dosya adı. _Kaynak:_ §16.4.1, §16.4.5, §22.3; WH-17, WH-21, OQ-27.

#### Kiracı kullanımları ve yüzeyler
- [ ] **Webhook adımı** — Workflow `webhook` kanalı kiracının olay hedefine ortak motorla imzalı olay teslim eder; teslim sonucu sonraki koşulda kullanılabilir, yanıt gövdesi veri olmaz. _Kaynak:_ §10.3; WF-8, WF-11.
- [ ] **`webhook` kanalı yükü ve dönüşüm** — Kiracı olay türü şeması (JSON Schema 2020-12); varsayılan kimlikler; ek alan beyaz listeli ve sürüme sabit; dönüşüm kiracı betiği yerine yalnız alan beyaz listesi + CloudEvents öznitelik eşlemesi, veri çekme adımı yok. _Kaynak:_ §7.10, §16.3.3; E-68, WH-13.
- [ ] **Anlamsal olay akışı ve analitik/SIEM hedefleri** — Teslim geçişleri, etkileşimler, atlamalar, kararlar ve denetim kayıtları kiracı hedefine (S3, Kafka, kuyruklar, webhook) bu motorla sürekli akıtılır; ClickHouse benzeri DB ve SIEM yalnız hedeftir, kopya Relay kaydıyla çelişirse kopya yanlıştır. _Kaynak:_ §7.10, §14.7.3; E-65, E-31, DS-37.
- [ ] **Uzun iş bitişi bildirimi (giden ve gelen)** — Dışa aktarım vb. bitişler Suiss profiliyle gönderilir; Executor ve diğer bekleyenlerin bitiş bildirimleri Standard Webhooks ile alınır; iki yönde aynı doğrulayıcı. _Kaynak:_ §7.5, §16.10.2; E-48, WH-50.
- [ ] **Portal API'si ve portal jetonu** — Kiracı backend'inin bastığı tek tüketiciye kapsamlı kısa ömürlü jeton; tüketici yalnız kendi uç ve mesajlarını görür; portal yeteneklerinin backend uçları (uç yönetimi, tür seçimi, katalog, günlük, yeniden gönder, `recover`, rotasyon, test olayı, sağlık). _Kaynak:_ §16.9.1–2; WH-46, WH-47.
- [ ] **Gömülebilir webhook portalı ve olay kataloğu** — Kiracının müşterisi için uç ekleme/düzenleme/devre dışı (SSRF kayıt kontrolüne anında geri bildirim), katalogdan tür seçimi, teslim logu, tekil/filtreli toplu yeniden gönderme, çakışmalı sır döndürme, test olayı, uç sağlığı; kiracı/alt kiracı markasıyla temalı, yerelleştirilmiş, dar kapsamlı jetonla. _Kaynak:_ §1.6, §4.4.3, §8.8; MKT-22, X-23.
- [ ] **Uç/anahtar/kurtarma denetimi** — Uç ekleme/silme, anahtar rotasyonu, otomatik devre dışıyı kapatma, toplu kurtarma denetim kaydına. _Kaynak:_ §16.9.3; WH-48.
- [ ] **`relay listen --forward-to` geliştirme tüneli** — Kiracının webhook olaylarını yerel adrese ileten tünel yalnız CLI'dadır; API'de müşteri tanımlı köprü URL'si yok. _Kaynak:_ §8.11, §9.15, §16.8.6; X-33, X-34, API-64, WH-45.

#### Bu aşamada doğrulanacak sınırlar
- **INV-3, INV-4, WH-30, WH-37** — DLQ ve devre dışı uçta içerik kaybolmaz; DLQ kalıcı, listelenebilir, yeniden oynatılabilir.
- **INV-12, WH-2** — `(endpoint_id, event_id)` tekilliği DB kısıtında.
- **INV-39, WH-45** — uç ortamı istemciden alınmaz, değiştirilemez; test düzleminde aynı SSRF kuralları.
- **WH-3, INV-60** — en az bir kez; "exactly-once" iddiası yok.
- **WH-5, WH-9, WH-19, TN-32** — anahtar paylaşılmaz, özel anahtar KMS/HSM'de; imzasız başlığa güvenlik kararı yok; düz sır yok; imza ham bayt üzerinde.
- **WH-22, WH-23, WH-25, WH-27** — deterministik jitter, sonsuz retry yok; durum kodu tablosu; `Retry-After` sınırı; ayrık terminal durumlar.
- **WH-32, WH-33** — elle × otomatik retry etkileşimi; kurtarmada `webhook-id` korunur, adil hız.
- **WH-35, WH-38** — kesici davranışı; yavaş uç diğerlerini bloklamaz.
- **WH-40, WH-41, WH-43, WH-44, X-34** — kayıt kuralları, bağlanma anı IP doğrulaması, SSRF kapsamı, self-host izin listesi sınırları, API'de köprü URL'si yok.
- **AG-24** — bölümlü hedefte sıra anahtarı = bölüm anahtarı.
- **API-55** — API sürümü yükseltmesi webhook payload'ını değiştirmez.
- **WF-11** — `webhook` adımının yanıt gövdesi workflow verisi olmaz.
- **E-48, E-65, E-68, X-23** — gelen/giden tek doğrulayıcı; analitik yalnız hedef; dönüşüm yalnız beyaz liste + eşleme; portal dar kapsamlı jetonla.

---

### Aşama 11 — Uyum ve Türkiye

Ülke × kanal × sınıf uyum tablosunu, İYS entegrasyonunu (tek yazıcı, okuma/yazma/senkron), ret ve tek tık çıkış yollarını, BTK SMS kurallarını ve OTP alt türleriyle hedef korumalarını fail-closed kapılar olarak devreye almak. A1 (saklama sınıfları, denetim kaydı, outbox), A3 (API, operatör aracı), A4 (karar kafesi, tercihler, izin kaydı, bastırma kaydı, sessiz saat ve saat dilimi), A5 (şablon), A6 (kanal adaptörleri, SMS rotaları) ve A10 (kiracı olayları) üzerine kurulur.

#### Spec dışı ön koşullar
- [ ] **İş günü / resmî tatil takviminin kaynağı ve güncelleme sahibi** — PC-31 WATCH, OQ-34 açık; İYS 3 iş günü hesabı buna bağlı. (Adem kararı)
- [ ] **ABD rıza geri çekme kapsamı kuralının yürürlük durumu** — PC-44 WATCH ⚠️, OQ-33; ABD satırının içeriği buna bağlı. (Adem kararı)
- [ ] **İYS 250 bin adres eşiğinin izlenmesi** — E-22 eşiği ⚠️ mevzuata karşı izlenir; izleme sorumlusu ve kaynağı tanımlı değil. (Adem kararı)

#### Uyum tablosu ve ülke satırları
- [ ] **Uyum tablosu (kapı 1d)** — Ülke × kanal × sınıf × rıza türü × hukuki alıcı türü → koşul ve yükümlülük veri tablosu; her ülkede çalışır, yeni ülke satırla eklenir; mevzuatın istemediği şart yok; kiracı yalnız sıkılaştırır, gevşetme bayrağı yok, kapılar fail-closed; ülke telefon kodu + profil ülkesinden, çakışmada kısıtlayıcı satır. _Kaynak:_ §1.7, §2.2, §5.7, §6.4, §13.8.1; MD-17, C-64, F-8, INV-17, MD-14, PC-40.
- [ ] **Özel satırsız ülkede `explicit_opt_in`** — Satırı olmayan ülkede pazarlama için açık onay güvenli varsayılandır. _Kaynak:_ §13.8.1; PC-41.
- [ ] **Meşru istisnalar veriyle** — Tacir/esnaf, soft opt-in, B2B meşru menfaat bayrakla değil tablo satırıyla. _Kaynak:_ §13.8.1; PC-42.
- [ ] **Hazır ülke satırları (TR, AB, ABD, Diğer)** — §13.8.2 tablosu sürümlü veri; hukuki içerik değişince yeni sürüm + denetim kaydı; ABD TCPA rıza geri çekme kapsamı veri olarak tutulur (WATCH). _Kaynak:_ §4.5, §13.8.2, §22.2; PC-44, OQ-33.
- [ ] **Platform satırları ve `marketing` varsayılan türetimi** — iOS push ve WhatsApp `marketing` kapalı (kiracı açamaz), Android ve in-app kiracı seçer; push/in-app/WhatsApp pazarlamada ek izin şartı yok, platformun istediği onay platform satırıyla; ülke satırı onay istiyorsa e-posta/SMS/ses her zaman kapalı; ülke ve platform satırı birlikte, kısıtlayıcı kazanır. _Kaynak:_ §13.4.2, §13.8.1, §13.8.3; PC-14, PC-43, PC-54.
- [ ] **Hukuki alıcı türü** — `individual`/`merchant`; tacir/esnafa önceden onay aranmaz, ret İYS'ye kaydedilir ve uyulur, gönderimde İYS RET kontrolü yapılır. _Kaynak:_ §5.3, §13.5.3; C-27, PC-24.
- [ ] **Yasal gönderim penceresi** — Ülke yasal aralığı (ör. TCPA 08:00–21:00) uyum tablosundan, sessiz saatten ayrı, her kanalda; kiracı kapatamaz/genişletemez; tz çıkarımla bulunduysa olası tz'ler arasında en dar pencere, telefon kodu ve IP yalnız bu seçimde; yedek tz ile gidenler raporda ayrı; satırı yoksa yalnız sessiz saat. _Kaynak:_ §5.7, §6.4, §10.10, §13.9.2; C-63, INV-17, WF-46, PC-45, PC-47.
- [ ] **Zorunlu yasal altbilgi kapısı** — Ticari ileti şablonunda sert kapı: TR unvan, MERSİS/iletişim, ücretsiz ret talimatı, ticari nitelik ibaresi; ABD fiziksel posta adresi; ülke kuralları uyum tablosundan. _Kaynak:_ §11.7; TP-33.

#### İYS
- [ ] **İYS kapsamı ve kapısı** — Yalnız `marketing` ve İYS kanalları (ARAMA, MESAJ, EPOSTA); kapsam TR bölgesi ya da girilmiş İYS bilgisi; kapsamda bilgi yoksa fail-closed `iys_not_configured`; herhangi kaynaktaki ret geçerli; kapsam dışında İYS işlemi yok, push/in-app/WhatsApp girmez; bilgilendirme iletisinde sıcak yolda sorgu yok. _Kaynak:_ §1.7, §6.4, §6.8, §13.6.1; MD-17, INV-19, INV-43, MKT-9, PC-27.
- [ ] **İYS tek yazıcı** — Bir marka için İYS'ye tek yazıcı Relay: onay/ret yazma, değişiklik çekme, tek tık çıkış, SMS RET, şikâyet reddi, kota ve belirteç yönetimi tek yerde; Access hiçbir koşulda doğrudan yazmaz. _Kaynak:_ §1.7, §7.1, §7.3.5, §13.6.2; MD-17, E-20, PC-28.
- [ ] **İYS bağlanma modları ve marka modeli** — Kiracının kendi erişimi ve yetkili entegratör modu aynı kalitede; 250 bin adres eşiği altı entegratörle (eşik ⚠️ izlenir); `(iysCode) → (brandCode, kanal) → izin`; marka alt kiracıya/gönderen kimliğine bağlı, SMS başlığıyla eşleşir; entegratör kanal yetkileri düzenli yenilenir. _Kaynak:_ §7.3.5, §13.6.3; E-22, PC-29.
- [ ] **İş günü / resmî tatil takvimi** — Sürümlü veri tablosu, naif 72 saat yok; güncelleme sahibi ve kaynağı WATCH. _Kaynak:_ §13.6.4, §22.2; PC-31, OQ-34.
- [ ] **İYS yazma yolu** — `PENDING_IYS` → outbox yükleme işi (alıcı × marka × kanal serileştirme, v2 idempotent uç) → `ACTIVE` (+ işlem kimliği) / kalıcı hata operatör kuyruğu + kiracı olayı / 3 iş günü aşımında `EXPIRED`; `200` sonrası geri okuma; ret yazımı öncelikli ve Relay'de önce uygulanır. _Kaynak:_ §13.6.4; PC-30.
- [ ] **İYS okuma yolu, yerel önbellek ve mutabakat** — Ret push ucu + cursor'lı pull (≥ saatlik, varsayılan 15 dk), 7 gün aşımında tam senkron; mutabakat işi en az saatlik; gönderim kapısı önbelleği okur, canlı sorgu yalnız tekil doğrulama; son 1 saat kör noktası operatöre gösterilir. _Kaynak:_ §13.6.5, §20.7; PC-32, OP-42.
- [ ] **İYS bayatlık kapısı ve erişilemezlik davranışı** — TR + `marketing` + bireysel alıcıda önbellekte ONAY yoksa ya da senkron bayatsa fail-closed `iys_stale`; 6 sa uyarı / 24 sa sayfalama + durdurma; tacir/esnafta yalnız RET kontrolü. İYS'ye yazılamayan ret Relay'de anında uygulanır, yazım kuyrukta bekler; Access olayları gecikirse kararlar Relay'in kendi İYS kopyasıyla verilir. _Kaynak:_ §7.11, §13.6.5; INV-19, PC-33, PC-24.
- [ ] **TR ticari iletide ONAY yalnız İYS'den** — İYS'de ONAY yoksa geçersiz; İYS RET varken uygulamada anahtar açmak yeni onay sayılmaz, ayrı kanıtlı akış gerekir. _Kaynak:_ §13.5.1; PC-21.
- [ ] **İYS işletim kuralları** — Belirteç geçerlilik süresince önbellek; hız/trafik kalitesi limitleri adaptör verisi; istekler yerel doğrulamadan geçer (E.164, tarih, alıcı sayısı); `consentLimit` izleme, uyarı ve dolunca operatör kuyruğu; İYS olayları kiracıya webhook; resmî OpenAPI'ye karşı istemci + sandbox sözleşme testi; rıza kaynağı İYS `source` eşlemesi. _Kaynak:_ §13.5.3, §13.6.6; PC-34.
- [ ] **Ticari ileti/muafiyet bayrağı sağlayıcıya sınıftan** — Sağlayıcının İYS filtresi gibi bayraklar mesaj sınıfından türer, sağlayıcı varsayılanına bırakılmaz, denetim kaydına girer. _Kaynak:_ §13.1.2; PC-4.
- [ ] **Ticari sesli ileti İYS `ARAMA`** — Ticari sesli ileti İYS `ARAMA` kanalına tabidir. _Kaynak:_ §12.8; CH-56.

#### Ret ve çıkış yolları
- [ ] **RFC 8058 tek tık çıkış ucu** — Otomatik `List-Unsubscribe` + `List-Unsubscribe-Post`; POST `List-Unsubscribe=One-Click`, GET durum değiştirmez, yönlendirme/giriş/onay ekranı yok, `200/204`; EdDSA/ES256 imzalı opak, iptal edilebilir belirteç `(tenant, alıcı, kategori, kanal)`, amaç ve kapsam belirteçte; idempotent, anında; kanıt (zaman, IP, UA, `rfc8058`); kategoriden çıkış tercih olarak, İYS'ye yazılmaz; mailto çıkışı aynı sonuç. _Kaynak:_ §4.2, §6.4, §13.7.1, §18.10; L-15, INV-18, PC-35, TN-35.
- [ ] **Çıkış sayfası** — "Çıkış yapıldı" + "tercihlerimi yönet" + "bu markadan hiç ticari e-posta almak istemiyorum" (İYS marka × EPOSTA RET + bütün marketing e-posta kategorileri); yalnız ticari/toplu kategorilerde; yolu kendini açıklar (ör. `/abonelik-iptali`); bağlantılar ≥ 30 gün (pratikte süresiz). _Kaynak:_ §8.7, §13.7.2, §13.7.5; X-22, PC-36.
- [ ] **Gelen SMS anahtar kelime işleyicisi** — Sağlayıcıdan bağımsız, çok dilli (TR ret seti, STOP ailesi, HELP/YARDIM, START/UNSTOP), Türkçe harf katlamalı, boşluk/harf duyarsız; RET kanal düzeyinde bastırma + TR'de İYS `MESAJ` RET, anında; START yeni kanıtlı onay, İYS RET'i kaldırmaz; ret sonrası tek pazarlamasız teyit; sağlayıcı STOP senkronu. _Kaynak:_ §13.7.3; PC-37.
- [ ] **ARF şikâyeti ve WhatsApp pazarlama çıkışı** — ARF/FBL pazarlama kategorilerinden çıkış + TR'de İYS `EPOSTA` RET + `complained` olayı; WhatsApp `user_preferences`/`131050` WhatsApp'ta marketing çıkışı. _Kaynak:_ §13.7.3; PC-37.
- [ ] **Kapı 1c: ret bildirimi ≠ tercih** — Tercih merkezinden kanal kapatma tercihtir (İYS yok); SMS RET, "markadan hiç", şikâyet ret bildirimidir (bastırma + İYS + kapı 1c); tek anahtara indirgenmez. _Kaynak:_ §13.7.4; PC-38.
- [ ] **Ret zamanlaması ve kapsamı** — Ret anında uygulanır, yasal süreler yalnız üst sınır; kapsam `category|all_marketing|all_channel` veri, kaynağa göre varsayılan (PD). _Kaynak:_ §13.7.5; PC-39.
- [ ] **Çift onay (Access'siz)** — E-posta pazarlama onayında kiracı seçeneği, varsayılan açık; `PENDING` adres kapı 1d'den geçmez; Access bağlıyken akış Access'indir. _Kaynak:_ §13.5.5; PC-26.

#### Türkiye SMS (BTK)
- [ ] **TR SMS rotası** — +90 hedefe yalnız BTK yetkili işletmeci/aggregator adaptörleri; "yurt dışı rota + URL" birleşimi reddedilir; TR rotası yoksa `rule_id` ile durur. _Kaynak:_ §4.5, §12.7.4; MKT-9, CH-51.
- [ ] **TR gönderici kimliği kuralları** — Alfanümerik 3–11, yalnız rakam olamaz, yalnız kendi ad/marka, genel adlar yasak, İYS kaydı önkoşul; marka ↔ başlık ↔ İYS `brandCode`. _Kaynak:_ §12.7.3; CH-50.

#### OTP ve `security` sınıfı
- [ ] **OTP iş bölümü** — Relay kod üretmez, saklamaz, doğrulamaz, sır tutmaz; "kodu tekrar gönder" yeni anahtarla yeni istektir; göndericinin izinli kanal kümesini aşmaz, küme içinde alt tür kurallı fallback; hedef korumaları ve OTP şeridi Relay'de (must-never listesi bağlayıcı). _Kaynak:_ §2.3, §6.5, §7.3.10, §13.10.2; INV-22, F-11, E-34, PC-52.
- [ ] **OTP alt türleri** — `security_subtype` (`otp_oob`/`email_verification`) ve AAL göndericiden; `expires_at` zorunlu; `otp_oob` yalnız SMS/WhatsApp/ses, e-posta içeren rota yayında reddedilir, çalışmada fallback e-postaya düşmez; `email_verification` yalnız e-posta, bağlantı önce onay sayfası; ihlal kapı 1e `otp_channel_forbidden`. _Kaynak:_ §9.5, §10.4, §13.10.1; API-24, WF-18, PC-51.
- [ ] **OTP teslim kuralları** — Zincir girdilerin fonksiyonu (izinli küme, ülke, erişilebilirlik, sağlayıcı sağlığı; WhatsApp yalnız erişim biliniyorsa birinci); zamanlanmaz, sessiz saati deler, digest/frekans/içerik dedup yok; render içeriği saklanmaz (özet + şablon sürümü); takip/sarmalama yok; kod push'ta ve önizlemede yok. _Kaynak:_ §13.10.3; PC-53, INV-26.
- [ ] **`security` SMS hedef korumaları (pumping)** — Numara ve önek/blok başına hız sınırı, kiracı başına ülke izin listesi (varsayılan bölge + eklenenler), pumping tespiti ve önek/ülke otomatik durdurma + kiracı olayı, kaldırma açık eylem + denetim; korumalar `security` ek payından önce uygulanır, ek pay bunları atlatmaz; BDDK m.34/7 ve SIM değişikliği sinyali gönderenden gelirse yönlendirici girdisi olur. _Kaynak:_ §7.1, §7.3.10, §12.7.7, §18.7; E-32, E-33, INV-23, CH-54, TN-52.

#### Kayıtlar ve hukuki talepler
- [ ] **Ticari ileti kayıt sınıfı (10 yıl)** — Ticari ileti onay, gönderim ve teslim kayıtları `message_log` içinde ayrı saklama sınıfında, TR'de 10 yıl (6563 m.11/3); kiracı yalnız uzatır. _Kaynak:_ §14.9.1, §20.4; DS-44, OP-19.
- [ ] **Özne silme API'si** — Bekleyen teslimler (`cancelled` + `rule_id`), zamanlanmış gönderimler, tekrar kuralları, digest tamponları ve inbox'ı kapsar; yasal kanıt ayrı ve en az veriyle; talep/yanıt `dsr_log`, `erasure_log` sınıflarında. _Kaynak:_ §20.4; OP-24.
- [ ] **Takedown API** — Kurulum operatörü mesaj/şablon/gönderici kimliği içerik erişimini kapatır (inbox öğesi gizlenir, bekleyenler `PAUSED`/`cancelled`, şablon yayından kalkar); step-up ister; her takedown denetim kaydında. _Kaynak:_ §18.9; TN-60, TN-21, TN-47.

#### Bu aşamada doğrulanacak sınırlar
- **INV-17, PC-40, PC-41, PC-47, PC-54** — uyum tablosu ve platform satırları; kiracı yalnız sıkılaştırır; satırsız ülkede açık onay; yasal pencere kapatılamaz, çıkarımlı tz'de en dar pencere.
- **INV-19, INV-43, PC-27, PC-33** — İYS kapsamı; bilgi yoksa/kopya bayatsa gönderme (fail-closed).
- **E-20, PC-28, PC-30** — İYS'ye tek yazıcı Relay; yazma yolu durumları, ret önce Relay'de.
- **PC-24** — tacir/esnafta onay aranmaz, RET kontrol edilir.
- **INV-18, PC-35, PC-37, PC-38, PC-39** — tek tık çıkış ucu kuralları; SMS anahtar kelimeleri; ret ≠ tercih; ret anında.
- **CH-51** — TR hedefte yurt dışı rota + URL reddi, TR rotası yoksa dur.
- **INV-22, INV-23, INV-26, E-33, E-34, API-24, WF-18, PC-51, PC-52, PC-53** — Relay kod üretmez/saklamaz/doğrulamaz; alt tür kanal kuralları ve fallback; OTP render içeriği saklanmaz.
- **CH-54, TN-52** — pumping korumaları; hedef koruması `security` ek payından önce.
- **WF-46, TP-33, PC-4** — çıkarımlı tz yasal penceresi; yasal altbilgi sert kapısı; sağlayıcı bayrağı sınıftan.
- **TN-60** — takedown step-up ve denetim.
- **OP-19, OP-24** — ticari kayıt 10 yıl, kiracı kısaltamaz; özne silmenin kapsamı.

---

### Aşama 12 — Ajanlar

Ajanları birinci sınıf alıcı yapar: ajan kaydı, bekleme noktasının ajan yüzü (heartbeat, eskalasyon zinciri, yanıt toplama ve kanıt düzeyi), posta kutusunun lease/ack yüzü, onay güvenliği, yapılandırılmış mesaj ilkesi, A2A/MCP/AG-UI ve ajan bildirim tavanı. A2'deki bekleme noktası çekirdeğine (kayıt, korelasyon, son tarih, erken yanıt tamponu) ve ortak kalıcı kayıt çekirdeğine (sıra numaralı kayıt, cursor, `since`), A3 API'sine, A4 karar kafesine, A8 eskalasyon zamanlayıcısına, A9 inbox/realtime'a ve A10 teslim motoruna dayanır.

#### Spec dışı ön koşullar
- [ ] **Sözleşmeler** — `waitpoint.*` ve `agent.ceiling_exceeded` AsyncAPI şemaları, ajan mesaj zarfı şeması (AG-40), MCP araç şemaları (AG-43), heartbeat ve lease/ack uçlarının OpenAPI tanımı yazılıp onaylanmalı. (Adem kararı)
- [ ] **Güvenilmez içerik sınır işareti ve normalleştirme algoritması** — AG-40 işaret biçimi, kaçırma kuralı, ayıklanacak görünmez karakter/gizli HTML listesi tanımlı değil; test vektörü gerekir. (Adem kararı)
- [ ] **Güven etiketi atama kuralları** — AG-38 `authenticated/unauthenticated/spam/blocked` etiketinin hangi koşulda verileceği tanımsız. (Adem kararı)
- [ ] **PD/EA değerleri** — AG-51 ajan başına tavan, AG-22 lease süresi ve yeniden teslim üst sınırı, AG-53 kaynak sınırı değerleri (bekleme başına mesaj/kademe, payload, eşzamanlı bekleme) değersiz (OQ-27); ölçümle konacak ama yapım öncesi başlangıç değeri kararı gerekir. (Adem kararı)
- [ ] **Alarm eşikleri** — AG-54 "belirli süre", "anormal kısa yanıt süresi" ve yanıt oranı/hacim eşikleri tanımsız. (Adem kararı)
- [ ] **Protokol sürüm geçiş değerlendirmesi** — E-74/AG-47/OQ-29 WATCH; MCP/A2A sürüm geçişinin karar sahibi ve tetikleyicisi tanımlı değil. (Adem kararı)

#### Sorumluluk sınırı ve temel ilkeler
- [ ] **Sorumluluk sınırı: bekler, eşleştirir, yürütmez** — Bekleme, korelasyon ve teslim Relay'in; checkpoint/pause/takeover/devam ve saga bekleyen tarafın; bekleme noktası her ajan sistemine ve müşteri koduna aynı API ile açık. _Kaynak:_ §7.5, §17.1; AG-1, E-46.
- [ ] **Teslim, ack ve yanıt yetki değildir** — Teslim, ack, görüldü, tıklama, kanal/protokol yanıtı ve bekleme çözümü yetki/onay üretmez; uyandırma serbest, uyanan ajanın yetkili eylemi yalnız kendi (Access) yetkisiyle; teslim edilemeyen olay yetki değişikliğini geciktirmez. Inbox butonu, push aksiyonu, kilit ekranı, SMS ve mesajlaşma yanıtı hiçbir zaman onay değildir. _Kaynak:_ §1.7, §2.7, §5.1, §7.7, §17.1, §17.9; MD-2, C-7, INV-28, INV-29, F-11, E-57, AG-2, AG-32.
- [ ] **Yalnız kendi adımlarını geri alma** — Bekleme çözülünce/iptal edilince yalnız Relay'in bekleyen eskalasyon kademeleri ve yapılmamış teslimleri iptal edilir; iş etkisi telafi edilmez, saga yok. _Kaynak:_ §1.7, §6.6, §7.5, §10.6, §17.1; MD-3, INV-35, E-46, AG-3, WF-25.

#### Ajan alıcı kaydı ve kimlik
- [ ] **Ajan alıcı kaydı** — Birinci sınıf alıcı türü ve Relay'in kanonik kaydı: `id`, `name`, teslim uçları (webhook, A2A push, realtime), tek posta kutusu, topic abonelikleri, sahip, isteğe bağlı Access bağı, durum `active`/`suspended`/`deleted` (yumuşak silme). Kayıt teslim içindir, yetkiyi değiştirmez; insan abonenin ya da insan iş kuyruğunun yerine geçmez. _Kaynak:_ §5.3, §7.1, §7.3.8, §17.2; C-21, C-19, C-68, E-28, E-42, AG-5.
- [ ] **Access'siz ajan kimlik doğrulaması** — Ajan Relay API anahtarıyla ya da kiracının bağladığı OIDC IdP jetonuyla doğrulanır; kimlik/yetki doğruluğu kimliği veren sistemdedir. _Kaynak:_ §7.3.8, §7.9, §17.2; E-30, E-62, AG-5, TN-25.
- [ ] **Ajan anahtar kapsamları** — Gönderim, bekleme noktası açma, posta kutusu okuma/ack ayrı ve dar kapsamlar; tek "her şey" kapsamı yok. _Kaynak:_ §17.2; AG-6.

#### Bekleme noktası: tür, yaşam döngüsü ve değişmezler (çekirdek A2'de)
- [ ] **Etkileşim türü ve ajan bildirim tipolojisi** — Gönderimde `notify`/`question`/`review` açıkça seçilir; Question ve Review `action_required` sınıfında, bekleme noktası zorunlu, son kullanma tarihi + yapılandırılmış aksiyon listesi taşır; sonuç sınıfı ve risk kademesi sahibinden etiket. _Kaynak:_ §1.7, §5.9, §17.3; C-75, MD-2, AG-8.
- [ ] **Review kanıt paketi** — Kaynak, beklenen sonuç, yanlışsa zarar gibi yapılandırılmış alanlar; hassas değerler değerle değil özetle (hash). _Kaynak:_ §17.3; AG-8.
- [ ] **Üç bekleme biçimi** — Tek seferlik bekleme noktası, çok mesajlı posta kutusu, çok okuyuculu topic aboneliği (ajan topic'e abone olur). _Kaynak:_ §17.3; AG-7.
- [ ] **Bekleme durum makinesi** — `open`, `stalled`, `resolved`, `expired`, `cancelled`; `stalled` yanıt kabul eder ve toplam süre işler; heartbeat dönünce `open` ve eskalasyon kaldığı kademeden sürer. _Kaynak:_ §17.4.2; AG-10.
- [ ] **Heartbeat ve iki zaman aşımı** — Toplam süre ("insan geç kaldı") → `expired` + `waitpoint.expired`, son tarih retry'larda korunur; heartbeat ("bekleyen öldü") kesilince `stalled` + `waitpoint.stalled`, bekleme sahipsiz, eskalasyon durur. İkisi ayrı ayarlanır, ayrı olay üretir; heartbeat yoksa yalnız toplam süre. _Kaynak:_ §4.3.1, §6.6, §7.5, §7.11, §10.6, §17.4.6; INV-32, L-25, L-53, E-47, WF-25, AG-15.
- [ ] **Yanıtlayan kimliği ve değişmezlik DB kısıtları** — Yanıtlayan ≠ bekleyen, yanıtlayan `responders` kümesinde, başlatan = tamamlayan; süresi geçmiş bekleme çözülemez, geç yanıt reddedilir ve reddi kaydedilir; çözülmüş bekleme değişmez, ikinci yanıt kabul edilmez. _Kaynak:_ §6.6, §17.4.3, §17.9; INV-31, AG-11.
- [ ] **Yanıt şema doğrulaması ve özete bağlılık** — JSON Schema 2020-12 doğrulaması kayıttan önce, geçersiz yanıt yazılmaz, senkron hata; yanıt kaydı `subject_digest` taşır, X'in yanıtı Y'de kullanılamaz; durum bekleme satırındadır, sinyal/ipucu/payload kayıt sistemi değildir. _Kaynak:_ §6.6, §17.4.3; INV-31, MKT-11, AG-11.
- [ ] **Yanıtlayan kümesi üreticinindir** — Relay `responders` kümesini bekleme noktasında ya da eskalasyonda genişletmez/daraltmaz; eklenen her eskalasyon alıcısı kümede olmak zorunda. _Kaynak:_ §17.4.1, §17.5; AG-12.
- [ ] **Bekleme listeleme, sorgu, iptal ve "yanıt bekleyenler"** — Bekleme listelenir, sorgulanır, bekleyen ya da yetkili operatörce iptal edilir; `open` + `stalled` sorgusu her kiracıya ve bekleyene açık. _Kaynak:_ §17.4.2; AG-46.
- [ ] **Bekleme olayları** — `waitpoint.created/escalated/resolved/expired/cancelled/stalled/response_rejected`; ortak teslim motoru ve bekleyen posta kutusuna gider; AsyncAPI kataloğunda. _Kaynak:_ §17.4.7; AG-16.
- [ ] **Özne silmesinin bekleme noktalarına uygulanması** — Bekleme noktalarındaki kişisel alanlar özne silmesine dahil. _Kaynak:_ §20.4; OP-24.

#### Eskalasyon zinciri
- [ ] **Eskalasyon politikası** — Adlandırılmış, sürümlü, yeniden kullanılabilir; kademe = süre → yeni alıcı ve/veya daha müdahaleci kanal; dosya/SDK/API ile yazılır. Politika sahibinden gelir (Suiss'te Work, değilse kiracı koordinatörü/müşteri kodu), Relay uygular. _Kaynak:_ §7.4, §17.5; AG-17, C-47, E-43.
- [ ] **Son kademe yalnız olay** — Son kademe yalnız `waitpoint.expired` üretir; otomatik ret/kabul Relay'in değil, bekleme sahibinde ya da baştan beyan edilmiş `default_response`'tadır; `default_response` `expired` olayında iletilir, yanıt olarak kaydedilmez, `resolution`'a yazılmaz. _Kaynak:_ §7.4, §10.6, §17.5; AG-18, WF-24, E-43.
- [ ] **Eskalasyon ortak zamanlayıcı ve durma** — Eskalasyon "görülmezse yükselt" ile aynı zamanlayıcıyı kullanır; bekleme `resolved`/`cancelled`/`stalled` olunca bekleyen kademeler iptal edilir. _Kaynak:_ §17.5; AG-19.

#### Posta kutusu (ajan yüzü)
- [ ] **Ajan posta kutusu (lease → ack)** — A2'deki ortak kalıcı kayıt çekirdeğinin (sıra numaralı kayıt + cursor + outbox) ajan yüzü; kanal-bağımsız, Postgres-kalıcı; lease ile alma, süresinde ack yoksa yeniden teslim; uyanınca son ack'lenen numaradan sırayla; en az bir kez, ajan mesaj kimliğiyle tekilleştirir. _Kaynak:_ §5.8, §17.6; C-68, MKT-12, AG-20.
- [ ] **Uyandırma ipucu ve dayanıklı handle** — Push/webhook/A2A push yalnız "uyan" ipucu, mesaj kutuda bekler, ipucu kaybı mesajı kaybettirmez; her teslim dayanıklı handle + sorgu ucu taşır. _Kaynak:_ §17.6; AG-21.
- [ ] **Lease ve yeniden teslim ayarları, ölü mektup görünümü** — Lease süresi ve yeniden teslim sayısı üst sınırlı kiracı ayarı (değer PD); aşan mesaj ölü mektup görünümüne alınır, silinmez, sahibine olay gider. _Kaynak:_ §17.6, §22.3; AG-22, OQ-27.
- [ ] **Posta kutusu saklaması ve sahipliği** — Fiziksel silme yok, Access OP-73/OP-74 ve Ek C'ye tabi; Access'te askı/silmede de kutu silinmez; kutu ajanındır, insan iş/onay kuyruğu Work'ündür. _Kaynak:_ §17.6; AG-23.

#### Yanıt toplayıcı ve kanıt düzeyi
- [ ] **Yanıt toplayıcı ve yanıt kaydı** — Relay onay kapısı değil yanıt toplayıcıdır: karar isteğini teslim eder, `resolution` = `value`, `responder`, `channel`, `evidence_level`, `responded_at`, `subject_digest` kaydını toplar ve sahibine iletir; yanıtın kendisi taşınır, geçerliliği değil; yanıt hiçbir koşulda onay değildir. _Kaynak:_ §1.5, §1.7, §5.9, §7.3.3, §7.5, §17.8; C-74, MD-2, F-2, E-16, E-49, AG-25.
- [ ] **Kanıt düzeyleri `channel_claim` ve `relay_session`** — Kanal beyanı (SMS/e-posta/mesajlaşma butonu) ve abone jetonlu oturum yanıtı; API alan adı `response`/`decision`, "approval" kullanılmaz (`access_aas_ref` A13'te). _Kaynak:_ §17.8; AG-26.
- [ ] **Access'siz basit karar kaydı** — İsteğe bağlı; "kanal yanıtı, yetki kanıtı değil" etiketiyle. _Kaynak:_ §7.3.3, §7.5, §17.8; AG-27, E-16, E-49.
- [ ] **Onay oturuma/göreve aittir** — İstek kullanıcının bütün cihaz ve kanallarına gider, bir kez çözülür. _Kaynak:_ §17.8; AG-28.
- [ ] **Kanal üstü yanıt deneyimi** — Onay dışı yanıt butonları yanıt toplar; anında ack, asenkron işleme; öğe "işleniyor → yanıtlandı (kim, ne zaman)"; tekrar tıklama idempotent; yanıt bütün cihaz/kanal kopyalarına yansır; çözülünce/süre dolunca diğer kopyalar "artık yanıt beklenmiyor". _Kaynak:_ §8.6, §15.1.6, §17.9; IN-6, AG-35.

#### Onay güvenliği ve jeton ayrımı
- [ ] **Sunucu render'lı karar isteği ve kilit ekranı kuralı** — Karar isteği metni yapılandırılmış alanlardan sunucuda üretilir; ajan metni "ajanın iddiası" etiketli, Markdown/HTML kapalı. İnsana gösterilen metin `content` tipli alanlarından sunucuda üretilir; `claim_text` ayrı alanda "ajanın iddiası" etiketiyle, render edilmeden. Mobilde kilit ekranından yanıt yok (iOS aksiyonları `authenticationRequired`); yüksek sonuçlu sınıfta bildirim yalnız davet; satır içi yanıt izni sahibinde. _Kaynak:_ §4.2, §4.3.1, §6.6, §17.9; L-27, L-37, INV-33, MKT-3, AG-29, AG-33.
- [ ] **Kimliğe bağlı callback yetkisi** — Varsayılan kimliğe bağlı; bearer gerekirse tek kullanımlık, kısa ömürlü, tek bekleme kapsamlı, son tarihte/yeniden gönderimde döndürülür. _Kaynak:_ §2.7, §4.3.1, §6.6, §17.9; L-36, INV-33, AG-31.
- [ ] **Yanıt jetonu ajan bağlamına girmez** — Yanıt jetonu/bağlantısı, bekleme kimliği bearer'ı ve başka alıcının verisi bekleyene dönen hiçbir API yanıtında, olayda, posta kutusu mesajında yok; yalnız insan kanallarına. _Kaynak:_ §2.7, §7.12, §17.9; INV-33, F-11, E-71, AG-30.
- [ ] **Gönderen türü her yüzeyde görünür** — İnsan/sistem/ajan gönderen türü inbox, push, mesajlaşma ve diğer yüzeylerde gösterilir. _Kaynak:_ §17.9; AG-34.

#### Yapılandırılmış mesaj ve ayrıcalık ayrımı
- [ ] **Yapılandırılmış mesaj ilkesi** — Ajana prompt değil yapılandırılmış mesaj gider; kontrol bilgisi tipli alanlarda (tür, bekleme kimliği, sonuç, yanıtlayan, kanal, kanıt düzeyi, iş özeti, seq, güven etiketi); kontrol alanına serbest metin girmez; içerik ajan/LLM'e talimat değil veri olarak gider, Relay ajana serbest metin talimat yazmaz. _Kaynak:_ §1.7, §2.7, §5.9, §7.12, §11.12, §17.11; MD-11, C-76, INV-30, F-11, E-71, TP-44, AG-39.
- [ ] **Ajan mesaj zarfı** — CloudEvents yalnız dış zarf, kiracı anahtarıyla imzalı; içerik A2A `parts[]` (`TextPart`/`DataPart`, `mediaType`) ve parça başına `audience` (MCP `annotations.audience`). _Kaynak:_ §5.9, §17.11; C-76, AG-40.
- [ ] **Güvenilmez içerik işaretleme ve normalleştirme** — İnsan/dış sistem serbest metni ayrı parçada "güvenilmez içerik" işareti ve kaynak bilgisiyle (yazan, doğrulandı mı, kanal), ayrıcalıklı bağlama girmez; sınır işaretleriyle çevrilir, metindeki işaret kaçırılır; gizli HTML/görünmez karakter/saklı metin ayıklanıp görünür metne normalleştirilir; ham içerik ayrı referansla; aşan payload referansla. _Kaynak:_ §11.12, §17.11, §17.15; AG-40, AG-39, TP-44.
- [ ] **Mesajdaki bağlantı izin listesi** — Mesaj bağlantıları doğrulanmadan açılacak ham URL değildir; eylem bağlantıları kiracı izin listesindeki hedeflere gider. _Kaynak:_ §17.11; AG-40, AG-41.
- [ ] **Gelen mesaj güven etiketi** — `authenticated | unauthenticated | spam | blocked`; ajan uyandırılmadan önce olay türünde görünür; spam/blocked ile uyandırma açık abonelik ister. _Kaynak:_ §5.9, §17.10; C-77, MKT-18, AG-38.
- [ ] **Ayrıcalık ayrımı savunmaları** — Prompt injection savunması filtreleme değil ayrıcalık ayrımı; §17.12 tablosundaki Relay tarafı savunmalar (yapılandırılmış mesaj, imzalı zarf + güven etiketi, sunucu render, jeton ayrımı, normalleştirme + bağlantı listesi, protokol kapı atlatma yasağı) bütünüyle uygulanır. _Kaynak:_ §17.12; AG-41.

#### Ajan gönderen kuralları ve bildirim tavanı
- [ ] **Ajan gönderen kuralları (One dahil)** — One ve diğer `agent` türü göndericiler özel statüsüzdür; ajan tavanına, kullanıcı tercihlerine ve politika kafesine tabidir, ajan kaynaklı etiketlenir; ajanın hafızası/planı/akıl yürütmesi Relay'e girmez, yalnız mesaj ve yapılandırılmış alanlar. _Kaynak:_ §7.1, §7.7; E-55, E-56.
- [ ] **Ajan başına bildirim tavanı** — `agent` gönderenli bildirimler ajan başına tavana tabi; frekans tavanı ve throttle'dan ayrı; insan/sistem etkilenmez; tavan değeri PD (F-28 ile ölçümle). _Kaynak:_ §5.9, §6.6, §17.14, §22.3; C-78, C-24, INV-34, AG-48, AG-51, OQ-27.
- [ ] **Tavan aşımı bekletme ve sahip kararı** — Aşımda gönderilmez/silinmez, kalıcı bekletilir; sahibine `agent.ceiling_exceeded`; sahip bekletilenleri görür ve API ile hepsini gönder / iptal / ajanı durdur kararı verir (serbest bırakma step-up); karar denetimde; bekletilenler `expires_at`'ini korur, süresi geçen `expired`. _Kaynak:_ §5.9, §7.4, §17.14; C-78, INV-3, E-44, AG-49, TN-21, TN-47.
- [ ] **Tavan sayacı fail-closed** — Valkey okunamazsa Postgres yedek sayaç; o da okunamazsa ajan kaynaklı bildirimler bekletilir; insan/sistem kaynaklılar kendi fail-open frekans kuralıyla etkilenmez. _Kaynak:_ §6.6, §7.11, §17.14; INV-34, AG-50.

#### Ajan protokolleri
- [ ] **Protokol eşleme katmanı ve sürüm izleme** — A2A, MCP ve AG-UI desteklenir; iç bekleme modeli protokol sürümünden bağımsız, protokol değişikliği yalnız eşleme tablosunu etkiler; sürümler (A2A v1.0, MCP 2026-07-28) izlenir (WATCH). _Kaynak:_ §7.6, §17.13.4, §22.2; E-50, E-74, AG-47, OQ-29.
- [ ] **Durum eşleme tablosu** — Relay bekleme durumu ↔ A2A (`INPUT_REQUIRED`/`AUTH_REQUIRED`/`WORKING`) ↔ MCP Tasks ↔ Anthropic Managed Agents `requires_action`; kayıpsız çeviri, sürüme bağlı veri; görev durumu bekleyenindir. _Kaynak:_ §4.5, §17.13.5; L-28, AG-46.
- [ ] **A2A v1.0 push alma/gönderme** — Görev yaşam döngüsü olayları taşınır; retry, imza (Standard Webhooks profili), DLQ, replay, SSRF ortak teslim motorundan; gelen olay `(task, seq)` ile idempotent, gerekirse `GetTask` ile uzlaştırılır; push yapılandırmasındaki kimlik bilgileri okumada redakte; `A2A-Version` gönderilir ve doğrulanır. _Kaynak:_ §4.2, §4.5, §6.6, §7.6, §17.13.1; L-28, INV-35, E-51, AG-42.
- [ ] **MCP sunucusu** — Durumsuz (MCP 2026-07-28), yalnız araçlar: gönder, bekleme aç, bekleme oku, yanıt bekleyenleri listele, posta kutusu oku, ack, topic'e abone ol; `sampling`/form ile kimlik isteme yok; MCP Tasks `input_required` bekleme noktasına eşlenir. _Kaynak:_ §7.6, §17.13.2; E-52, AG-43.
- [ ] **MCP araç kataloğu kapsam daraltması** — Araçlar HTTP API ile aynı kapsamlara ve politika kafesine tabi; katalog çağıranın anahtar kapsamına göre daralır, yetkisiz çağrı ayrıca reddedilir; insana yönelik beklemeyi yanıtlayan araç yok. _Kaynak:_ §7.6, §17.13.2; E-52, AG-43.
- [ ] **AG-UI opak taşıma** — AG-UI olayları realtime kanalda ayrı akış türünde opak yük; Relay yorumlamaz, değiştirmez, politika girdisi yapmaz; aynı `(stream, epoch, seq)`, `since` cursor sıralama, kurtarma ve yetki kuralları. _Kaynak:_ §7.6, §15.4.16, §17.13.3; E-53, IN-37, AG-44.
- [ ] **Protokol yanıtı onay değildir** — MCP/A2A üzerinden gelen yanıt Access onayı değildir; protokoller onay kapısını atlayamaz; protokolle taşınan her içerik yapılandırılmış mesaj ilkesine tabi. _Kaynak:_ §7.6, §17.13.4; E-54, AG-45, C-76, INV-30.

#### Uzun işler ve gelen ajan bildirimleri
- [ ] **Uzun iş bitişi webhook'ları** — Giden uzun iş bitişi Standard Webhooks ile; gelen uzun iş bildirimleri (model sağlayıcıları) aynı doğrulayıcıyla doğrulanır. _Kaynak:_ §17.10; AG-36.
- [ ] **Gelen ajan bildirimi tekilleştirme ve mutabakat** — `(görev, seq)` ile tekilleştirme, sırasız gelen yenisini ezmez; bildirim "yeniden oku" ipucudur, kaynaktan okuyarak mutabakat. _Kaynak:_ §17.10; AG-37.
- [ ] **Ajan uzun iş ilerleme yüzeyi** — Live Activities ve Android ProgressStyle, konu bazlı collapse modeline eşlenir. _Kaynak:_ §17.14; AG-52.

#### Sınırlar ve işletim
- [ ] **Ajan kaynak sınırları uygulaması** — Bekleme başına mesaj/kademe sayısı, payload boyutu, azami bekleme (≤ 30 gün), kiracı/bekleyen başına eşzamanlı açık bekleme, lease/yeniden teslim üst sınırı uygulanır ve hata gövdesinde görünür; sayısal değerler ölçümle (EA, değer PD). _Kaynak:_ §17.15, §22.3; AG-53, OQ-27.
- [ ] **Ajan operasyon alarmları** — Sessiz bekleme/görev sayımla (durumu belirli süredir değişmeyenler, hata sayacı değil); yanıt oranı düşerken hacim artışı ya da anormal kısa yanıt süresi ("otomatik kabul makinesi") alarmı. _Kaynak:_ §17.15; AG-54.

#### Bu aşamada doğrulanacak sınırlar
- **INV-28, INV-29, AG-2, AG-32, E-57, E-54, AG-45** — teslim/ack/kanal ya da protokol yanıtı/bekleme çözümü yetki veya onay üretmez; protokoller onay kapısını atlayamaz.
- **INV-35, AG-3, E-46, AG-1, WF-25** — çözümde/iptalde yalnız Relay'in kendi kademeleri ve teslimleri iptal edilir; saga ve yürütme yok; `(task, seq)` idempotent alım.
- **INV-31, AG-11, AG-12** — yanıtlayan ≠ bekleyen ve kümede; süresi geçmiş/çözülmüş bekleme değişmez; şema doğrulama kayıttan önce; `subject_digest` bağı; alıcı kümesi değiştirilmez.
- **INV-32, AG-10, AG-15, E-47** — iki ayrı zaman aşımı; `stalled` yanıt kabul eder, eskalasyon durur ve heartbeat dönünce kaldığı yerden sürer.
- **AG-16, AG-46** — bekleme olayları ve listeleme/iptal/yanıt bekleyenler.
- **WF-24, AG-18, AG-19** — son kademe yalnız `waitpoint.expired`; `default_response` yanıt sayılmaz; çözüm/iptal/stalled'da kademeler iptal.
- **AG-20, AG-21, AG-22, AG-23, INV-47** — lease/ack yeniden teslim, ipucu kaybı mesajı kaybettirmez, ölü mektup silinmez, askı/silmede kutu kalır.
- **AG-25, AG-26, AG-27, AG-28, AG-35, E-49** — yanıt kaydı alanları, kanıt düzeyi, "approval" adı yok, bir kez çözülür, tekrar tıklama idempotent.
- **INV-33, AG-29, AG-30, AG-31, AG-33, E-71** — yanıt jetonu/bekleme bearer'ı ajan bağlamına girmez; tek kullanımlık callback; kilit ekranından yanıt yok.
- **INV-30, AG-39, AG-40, TP-44, AG-34, AG-38** — kontrol alanına serbest metin girmez; güvenilmez içerik işareti, kaçırma ve normalleştirme; gönderen türü ve güven etiketi görünür.
- **INV-34, INV-3, AG-48, AG-49, AG-50** — ajan tavanı aşımı silinmez, bekletilir; sayaç okunamazsa fail-closed; insan/sistem etkilenmez.
- **AG-6, AG-42, AG-43, AG-44, E-51, E-52, E-53, IN-37** — dar kapsamlar, A2A push idempotensi ve redaksiyon, MCP katalog daraltması, AG-UI opak taşıma.
- **AG-37, AG-53, AG-8** — gelen bildirimde sırasız ezme yok; kaynak sınırları hata gövdesinde; Question/Review bekleme noktası zorunlu.

---

### Aşama 13 — Access entegrasyonu

Relay'i Access'e bağlar: tek bağlantı ayarı ve keşif, platform kiracısı, kiracı/organizasyon eşlemesi, operatör kimliği ve step-up, token exchange, ajan kimliği bağı, izin olayları, korunan şablonlar, CIBA daveti ve denetim bağı. Relay Access'siz de tam çalışır; bu aşama A1 (kiracılık, denetim), A3 (API kimliği), A4 (izin/tercih), A5 (üretici sahipli şablon), A9 (abone jetonu), A10 (webhook profili), A11 (İYS) ve A12 (ajan kaydı, yanıt kanıt düzeyi) üzerine kurulur.

#### Spec dışı ön koşullar
- [ ] **Access keşif belgesi şeması** — E-40 uç noktaların, imza anahtarlarının ve yeteneklerin keşif belgesinden alındığını söylüyor, §09 API-7 bunun §07'de olduğunu belirtiyor; §07'de belgenin alanları ve konumu tanımlı değil. (Adem kararı)
- [ ] **Access izin olayı veri şeması** — E-21 İYS alanlarını sözel sayıyor (tarih, kaynak, kanal, alıcı, alıcı türü); CloudEvents `type` ve `data` şeması (alan adları, sıra numarası alanı) tanımlı değil. (Adem kararı)

#### Bağlantı ve temel ilkeler
- [ ] **Dört kullanım durumu ve Access gerektiren özelliğin açık beyanı** — Relay Access'siz ve Access'li çalışır; Relay eklenip kaldırılınca müşteri kodu değişmez (Access'in doğrudan gönderim modu Access'tedir). Access gerektiren her özellik (token exchange, onay yüzeyine derin bağlantı, step-up) panelde, API belgesinde ve hata gövdesinde bunu belirtir ve Access'siz eşdeğerini gösterir; hiçbir özellik sessizce bozulmaz. _Kaynak:_ §1.7, §7.2; MD-1, INV-56, E-5.
- [ ] **Tek bağlantı ayarı ve keşif** — Access–Relay bağlantısı kiracı başına tek ayardır; keşif belgesinden uç noktalar, imza anahtarları ve yetenekler otomatik alınır; ortak CloudEvents ve ortak webhook imza profili. Bağlantı kaldırılınca Relay Access'siz biçime döner, gelen kopyalar (izin, eşleme) saklama kuralına göre kalır. _Kaynak:_ §1.7, §5.13, §7.2, §7.3.13; MD-1, MD-10, E-1, E-2, E-4, E-40.
- [ ] **Ortak Suiss webhook profili** — Access ile aynı başlık seti, varsayılan `v1a` Ed25519 imza (`v1` HMAC yalnız uyumluluk), çakışmalı anahtar rotasyonu, CloudEvents zarfı, `webhook-id` saklama önerisi; alıcı iki ürünü tek doğrulayıcıyla doğrular (profilin Relay tarafı A10'da). _Kaynak:_ §7.3.12; E-36, E-4.
- [ ] **Aynı bölge kuralı** — Access ve Relay kullanan kiracının iki ürünü aynı bölgededir; bağlantı ayarı farklı bölgedeki kurulumları bağlamayı reddeder. _Kaynak:_ §1.7, §5.13, §7.3.13, §18.8; INV-41, E-39, TN-57.
- [ ] **Sınırda veri minimizasyonu** — Access'ten Relay'e yalnız render/teslim alanları, izin olayının İYS alanları ve eşleme bilgisi geçer; kimlik bilgileri, sırlar ve yetki kayıtları geçmez; Relay'den Access'e yalnız teslim durumu (bilgi) ve denetim referansları. _Kaynak:_ §7.12; E-70.
- [ ] **Teslim yetki değildir; "Relay asla" listesi** — Teslim, ack, okundu, yanıt ve bekleme çözümü Access yetki durumunu değiştirmez; Relay yetki/Gate/iş etkisi kaynağı olmaz, teslim edemediği olay için yetki değişikliğini geri almaz/geciktirmez, yanıtı onay saymaz; teslim durumu Access'e yalnız webhook/API bilgisi olarak döner, Access durumunu değiştiren çağrı yok. _Kaynak:_ §1.7, §5.12, §7.3.1, §14.8.4; E-6, E-7, DS-43, MD-2, C-87, INV-28.
- [ ] **Revocation taşıması güvenliği taşımaz** — Yetki iptali ve anlamsal olaylar Relay (ya da Access SSF/CAEP vericisi) ile taşınır; Relay'in gecikmesi/başarısızlığı hiçbir yetki kararını değiştirmez. _Kaynak:_ §7.3.2, §7.11; E-14.
- [ ] **Access webhook'larının tüketimi** — İzin değişikliği, organizasyon eşlemesi, ajan askısı olayları aynı profil/doğrulayıcı ve §16.10.1 kabul kurallarıyla alınır; profil değişikliği iki üründe birlikte yapılır. _Kaynak:_ §16.10.3, §16.11; WH-51, WH-4.
- [ ] **Access erişilemezken/gecikirken davranış** — Gönderim sürer, izinler kopyadan okunur, kopyalar son bilinen durumda kalır; yeni token exchange yapılamaz; step-up gerektiren işlem yapılmaz; hata görünürdür. _Kaynak:_ §7.11; E-18, E-25, E-27.

#### Platform kiracısı ve eşleme
- [ ] **Platform kiracısı** — Access (ve diğer üretici ürünler) kendi gönderen alan adı/gönderici kimlikleri, ayrı itibar ve devre kesicilerle yalıtılmış platform kiracısı; veri yalıtımında ayrıcalık yok; içerik ve "kime, neden" üreticinin, kanal/zamanlama/retry/fallback/teslim durumu Relay'in. _Kaynak:_ §1.7, §5.2, §7.3.2, §18.1.4; MD-1, C-18, E-9, TN-9.
- [ ] **Access anlamsal olay alımı** — Access anlamsal olayları varsayılan `security` sınıfına eşlenir; `dedup_key` Access olay kimliğinden türetilir. _Kaynak:_ §7.3.2; E-10, E-11.
- [ ] **Kiracı ve organizasyon otomatik eşlemesi** — Access kiracısı → Relay kiracısı, Access B2B organizasyonu → Relay alt kiracısı (C-12); organizasyon açılış/değişiminde olayla oluşur/güncellenir; eşleme bağlantı ayarıyla bir kez kurulur. _Kaynak:_ §1.7, §5.13, §7.3.7, §7.3.13, §18.1.2; MD-18, E-4, E-26, E-38, TN-6.
- [ ] **Korunan şablonlar** — Access korunan mesaj anahtarları/şablonları üretici sahipli şablon olarak alınır; kiracı metni ezemez; WhatsApp onaylı şablon eşlemesi dahil kanala göre render Relay'indir. _Kaynak:_ §5.13, §7.3.11; C-55, E-35.
- [ ] **`security` durdurmasının Access'e bildirimi** — Access güvenlik olayları açık seçimle durdurulursa her engellenen teslim `rule_id` ile kaydedilir ve teslim durumu Access'e bilgi olayı olarak döner (alıcı kümesi daraltması sayılmaz). _Kaynak:_ §18.5.2; TN-42.

#### Operatör kimliği ve denetim
- [ ] **Access ile operatör girişi ve yaşam döngüsü** — Access bağlıysa operatörler Access OIDC ile girer; açma/askı/silme Access olaylarıyla yansır, askıya alınan kullanıcının oturumları ve API anahtarları geçersizleşir; roller Relay'de. _Kaynak:_ §1.7, §7.3.7, §18.3.1; MD-1, E-26, TN-20.
- [ ] **Access step-up ve AuthZEN** — Hassas işlemler Access step-up ister, gerekirse Access karar API'sine (AuthZEN) sorulur; sonuç alınamazsa (Access erişilemez dahil) işlem yapılmaz; sonuç denetimde. _Kaynak:_ §1.7, §7.3.7, §7.11, §18.3.1; MD-19, E-27, X-3, TN-21.
- [ ] **Denetim kayıtlarının Access ile bağlanması** — Her kayıt eylemi yapanın Access kimliğini ve ilgili Access kayıt numarasını (step-up, karar, oturum) taşır; referansla bağlanır, kopyalanmaz; SIEM aktarımı ve saklama Access Ek C kurallarına göre. _Kaynak:_ §1.7, §5.12, §7.3.9, §18.6; MD-19, E-31, TN-48.

#### Abone, servis ve ajan kimliği
- [ ] **Token exchange ile abone jetonu** — Access'li kiracıda Access jetonu RFC 8693 ile Relay abone jetonuna çevrilir; abone `external_id` = Access pairwise `sub`; kiracı backend'ine kod gerekmez. _Kaynak:_ §5.2, §5.3, §5.13, §7.3.6, §9.9, §15.6.1, §18.3.4; C-17, C-20, E-24, API-45, IN-41, TN-25.
- [ ] **Access jetonu inbox/tercih anahtarı değildir** — Access jetonu doğrudan inbox, tercih ya da realtime erişimi için kabul edilmez, Access erişilemezken de; erişim yalnız Relay abone jetonuyla. _Kaynak:_ §7.3.6, §7.11, §15.6.1, §18.3.4; E-25, IN-41, TN-25.
- [ ] **Access servis jetonuyla sunucu API'si** — Access anahtarlarıyla doğrulama, `aud` = Relay sunucu API'si; kiracı Access ↔ Relay eşlemesinden; kapsamlar API-43'e eşlenir; yalnız sunucu API'sinde kabul edilir. _Kaynak:_ §9.9; API-48, API-71.
- [ ] **Ajanın Access kimliğine bağlanması** — Ajan kaydı Access Party/Instance'a bağlanır, ajan Access jetonuyla doğrulanır; Access askı/silme olayıyla ajana teslim ve ajan kaynaklı gönderim durur, posta kutusu silinmez (saklama kuralına göre kalır). _Kaynak:_ §5.3, §5.13, §7.1, §7.3.8, §17.2; C-21, E-29, AG-5, TN-25, INV-47.

#### İzin ve tercih
- [ ] **Access izin olaylarından izin kopyası** — Hukuki izin Access'te, tercih Relay'de; Relay at-least-once + sıra numaralı izin olaylarından kopya tutar, eski sıra uygulanmaz, gönderimde Access'e sormaz; kopya uyum kapısı girdisidir (TR'de ayrıca İYS önbelleği); izin/tercih yetki üretmez; Relay yoksa kiracı olayı kendi entegratörüne iletir. _Kaynak:_ §1.7, §5.13, §7.1, §7.3.4, §13.5.2, §13.6.2; MD-17, E-17, E-18, PC-22, PC-28.
- [ ] **Access izin olayından İYS'ye yazım** — Access İYS alanlarını taşıyan izin olayı yayınlar; Relay bağlıysa alır ve İYS'ye yazar; Access İYS'ye doğrudan yazmaz, Relay yoksa kiracı entegratörü işler. _Kaynak:_ §7.3.5; E-21.
- [ ] **Tek "Tercihlerim" ekranı** — Access bağlıyken izinler (Access) + bildirim tercihleri (Relay) tek ekranda. _Kaynak:_ §13.4.4, §13.5.2; PC-22.

#### Onay yüzeyi (CIBA)
- [ ] **CIBA davet teslimi ve `access_aas_ref`** — Access OP'dir; Relay daveti `action_required` sınıfıyla push/SMS/e-posta vb. kanallarla (fallback dahil) taşır; onay Access onay yüzeyinde verilir; Access sonuç olayıyla bekleme `access_aas_ref` kanıt düzeyinde kapanır; CIBA ping istemci bildirimi Access'te kalır, Relay webhook'uyla taşınmaz. _Kaynak:_ §1.7, §5.13, §7.3.3, §17.8; MD-1, C-74, E-15, AG-26, AG-27.
- [ ] **Onay türü öğede yalnız Access derin bağlantısı** — Access'li kurulumda onay türündeki inbox/bildirim öğesinin eylemi yalnız Access onay yüzeyine derin bağlantıdır; inbox butonu onay değildir. _Kaynak:_ §7.3.3, §8.6, §15.1.6, §17.9; E-16, IN-6, AG-32.

#### Bu aşamada doğrulanacak sınırlar
- **INV-56, E-5** — Access'siz/Access'li çalışma; Access gerektiren özellik açıkça beyan edilir, sessiz bozulma yok.
- **INV-41, E-39, TN-57** — farklı bölgedeki Access ve Relay bağlanamaz.
- **INV-28, E-6, E-7, E-14, DS-43, TN-42** — teslim/yanıt Access yetkisini değiştirmez; Access'e yalnız bilgi döner; revocation gecikmesi yetki kararını etkilemez.
- **E-18, E-25, E-27, TN-21** — Access erişilemezken gönderim sürer, token exchange ve step-up'lı işlem yapılmaz; AuthZEN/step-up sonucu alınamazsa işlem reddedilir.
- **E-24, API-45, IN-41, TN-25, API-71** — token exchange ile abone jetonu; Access jetonu inbox/tercih/realtime için kabul edilmez; servis jetonu yalnız sunucu API'sinde.
- **E-29, AG-5, INV-47** — Access askı/silme olayı ajana teslimi durdurur, posta kutusu silinmez.
- **E-15, E-16, IN-6, AG-27, AG-32** — onay yalnız Access onay yüzeyinde; `access_aas_ref`; onay öğesinde yalnız derin bağlantı.
- **E-21, PC-22** — izin kopyası eski sırayı uygulamaz; İYS'ye yalnız Relay yazar.
- **E-70** — sınırdan kimlik bilgisi, sır ve yetki kaydı geçmez.
- **WH-51, TN-6, TN-9, TN-20, TN-48** — Access webhook kabul kuralları, organizasyon eşlemesi, platform kiracısı yalıtımı, operatör askısında oturum/anahtar iptali, denetim bağı.

---

### Aşama 14 — Deneyim ve SDK'lar

Geliştiricinin ve operatörün Relay'e dokunduğu bütün yüzeyler: sözleşmeden üretilen sunucu/istemci SDK'ları, hazır UI bileşenleri, panel, görsel editör, "neden almadım" ekranı, test düzlemi deneyimi ve belge sitesi. API sözleşmesine ve çekirdek hatta (A1–A4), workflow ve gelişmiş adımlara (A3, A8), inbox/realtime'a (A9), webhook'lara, ajan yüzüne (A12) ve kiracı/kill switch altyapısına dayanır; bu aşama yeni karar mantığı üretmez, var olanı gösterir ve sarar.

#### Spec dışı ön koşullar
- [ ] **Tohum alıcı profillerinin tam tanımı** — X-26 dört örnek profil sayıyor ("izinsiz", "ret vermiş", "sessiz saatte", "tavanı dolmuş"); tam liste ve her profilin alan değerleri yok. (Adem kararı)
- [ ] **Birleşik "Tercihlerim" ekranının birleşim sözleşmesi** — E-19/X-19 tek ekran istiyor; Access ve Relay bileşenlerinin hangi origin'de, hangi jetonla ve nasıl birleştirileceği tanımlı değil. (Adem kararı)
- [ ] **X-13 ve X-36 ölçüm protokolleri** — 30 saniye ("neden almadım") ve 5 dakika (ilk bildirim) hedefleri ENGINEERING ASSUMPTION; kullanılabilirlik testi ve onboarding kabul testinin senaryosu ve kabul kriteri tanımlı değil. (Adem kararı)

#### Temel ilkeler
- [ ] **Özellik eşitliği: bütün yüzeyler self-host'ta** — Panel, editör, bileşenler, portal, test ortamı ve SDK'lar self-host'ta eksiksizdir; hiçbir yüzey lisans bayrağıyla kilitlenmez. _Kaynak:_ §8 ilke 3; X-2.
- [ ] **Dürüst gösterim kuralları** — Durum dış projeksiyonla (`unknown_pending`/`unknown` dahil); push'ta "teslim edildi" iddiası yok, kanal başına semantik yazılı; açılma pikseli açıkken güvenilmezlik uyarısı, açılma oranı karar girdisi değil; insan/muhtemel bot tıklama ayrımı; yedek saat dilimi ayrı sayım; gönderen türü etiketi; durum yalnız renkle gösterilmez. _Kaynak:_ §8.2.3, §14.6.4; X-6, DS-32.

#### Sözleşmeden üretilen SDK'lar
- [ ] **SDK seti ve üretimi** — Sunucu: TS/Node, Python, Go, Java, .NET, Elixir, PHP, Ruby; istemci: tarayıcı JS + React, iOS, Android, React Native, Flutter. OpenAPI 3.1/AsyncAPI'den üretilir + ince el yazımı katman; SDK sürümü API sürümüne sabit, paket güncellemesi davranış değiştirmez; tembel sayfalama yineleyicisi. _Kaynak:_ §1.7, §8.10.1, §9.1, §9.11, §9.12; MD-13, X-28, API-2, API-55, API-56.
- [ ] **SDK üretim hattı ve yayını** — Sözleşme değişince bütün SDK'lar CI'da yeniden üretilir, her dilin testleri sözleşmeye karşı koşar, kırılan SDK birleşmeyi durdurur; her SDK kendi SemVer'i, trusted publishing ile yayın. _Kaynak:_ §19.13.4, §19.13.9; T-59 (madde 8), T-64 (SDK kısmı).
- [ ] **Sunucu SDK zorunlu davranışları** — Otomatik `Idempotency-Key` (retry'da aynı); yalnız `retryable: true`'da üstel artış + jitter ve `Retry-After`'a uyum; yazılı hata hiyerarşisi; ham gövdeli webhook doğrulayıcı (ortak profil), belgelerde her dilde doğrulama örneği. _Kaynak:_ §1.7, §8.10.2, §9.4, §9.15, §16.2.4; MD-20, X-29, API-10, API-65, WH-7.
- [ ] **Akış kalıbı (önce aç, sonra geçmiş, tekilleştir)** — İstemci ve ajan SDK'ları akışı önce açıp tamponlar, sonra snapshot/geçmişi listeler, kimlik + sürümle tekilleştirir; ≤ sürümlü olay atılır. _Kaynak:_ §15.4.6, §15.4.7, §17.6; IN-27, IN-28, AG-21.
- [ ] **SDK ajan yardımcıları** — Bekleme noktası oluştur/bekle, posta kutusu oku/ack ve akış kalıbı hazır yardımcı olarak. _Kaynak:_ §8.10.2; X-30.

#### İstemci SDK davranışları (web ve mobil)
- [ ] **Web SDK taşıma seçimi** — Önce WebSocket, sonra SSE ve yoklamaya düşer. _Kaynak:_ §15.4.2; IN-23.
- [ ] **İstemci yeniden bağlanma geri çekilmesi** — Üstel geri çekilme + tam jitter; kabul hızı aşımında geri çekilme. _Kaynak:_ §15.4.13; IN-34.
- [ ] **Ön plana gelişte sayaç senkronu** — Ön plana gelişte koşulsuz sayaç isteği; liste ile sayı tutarsızsa rapor. _Kaynak:_ §15.3.4; IN-21.
- [ ] **İstemci çevrimdışı kuyruğu** — `client_seq` sıralı, öğe başına sıkıştırılmış; `409`'da sunucu durumu sessiz kabul, yalnız ekrandaki ters işlemde "başka cihazda güncellendi". _Kaynak:_ §15.2.4–5; IN-12, IN-13.
- [ ] **İstemci geri al tamponu** — "Geri al" istemci tamponuyla, süre dolunca sunucuya. _Kaynak:_ §15.2.7; IN-15.
- [ ] **Web çok sekme** — Web Locks lider + BroadcastChannel; takipçi kendi REST yazmasını yapar; gizli lider kapanır ve delta senkronla döner; Service Worker rozet ve tıklama yönlendirmesi. _Kaynak:_ §15.4.15; IN-36.
- [ ] **Mobil SDK kapsamı ve sınırı** — Push jeton kaydı/yenileme (`devices:write`), iOS bildirim servis eklentisi ve Android data mesajı işleyicisi, OS izin durumu, Android kanal oluşturma, gösterildi/tıklandı makbuzu, diğer cihazdan kaldırma, inbox/tercih bileşenleri ve realtime; olay tetiklemez, profil/izin yazmaz, gizli anahtar tutmaz. _Kaynak:_ §8.10.3; X-31.
- [ ] **Mobil push izin ve kanal yönetimi** — İzin durumu ve Android kanal önemleri her açılışta bildirilir; iOS provisional yalnız `marketing`/`social` başlangıcında; Android kategori → kanal ID/önem ilk açılışta, ID'ler sürümler arası sabit; içerik taşımayan push'ta içerik çekme, olmazsa genel metne düşme. _Kaynak:_ §12.5.5, §12.5.7; CH-28, CH-29, CH-30, CH-33.
- [ ] **Mobil yaşam döngüsü** — Arka planda bağlantı kapanır; ön plana dönüş sırası sayaç → bağlan → delta/soğuk → kuyruk boşalt → `409` kabul; iOS kaldırma SDK ile. _Kaynak:_ §15.4.14, §15.5.1; IN-35, IN-38.

#### Hazır UI bileşenleri
- [ ] **Hazır UI bileşenleri** — React birinci sınıf; Vue/Angular/Svelte/LiveView/düz HTML için web components; altta headless JS SDK; inbox (zil, rozet, liste; okundu/arşiv/gizle, iyimser rozet), toast, tercih merkezi, webhook portalı; mobil yerel inbox/tercih; tema/marka (alt kiracı dahil), yerelleştirme, WCAG 2.2 AA; ajan kaynaklı bildirim işaretli; yalnız dar kapsamlı abone jetonu, gizli anahtar istemciye girmez. _Kaynak:_ §4.4.3, §5.3, §8.6, §8.10.4; MKT-20, C-24, X-32, X-16, X-17.
- [ ] **Gömülebilir webhook portalı UI** — React bileşeni + web component; kiracı/alt kiracı marka ve teması; uç sağlık paneli panelde ve portalda. _Kaynak:_ §16.7.5, §16.9.1–2; WH-39, WH-46, WH-47.

#### Tercih merkezi ve rıza ekranları
- [ ] **Tercih merkezi: tek motor, üç yüzey** — Gömülebilir bileşen, imzalı/süreli/tek amaçlı belirteçli girişsiz JS'siz barındırılan sayfa ve iOS `providesAppNotificationSettings` aynı kaynaktan render edilir; tercih seviyeleri (kategori × kanal, workflow, tek nesne sessize alma, haftalık program) ve sessiz saat; `—`, "Açık (kilitli)" ve kilidin yararlanıcısı, genel kanal anahtarı, "İzin bekleniyor · İzin ver", "yöneticiniz kapattı", "cihaz ayarlarından kapalı" durumları. _Kaynak:_ §8.7, §13.2.1, §13.4.2–4; X-18, PC-6, PC-15, PC-16, PC-18.
- [ ] **Kilitli kategoriler, toplu seçenekler, kendini açıklayan yollar** — Kilitli kategoriler gerekçesiyle görünür; sütun/satır toplu kapatma amaç karıştırmaz; barındırılan sayfa yolları amaç bildirir (`/bildirim-tercihleri`). _Kaynak:_ §8.7; X-22.
- [ ] **Kapatmada üç seçenekli ara adım** — Anında al / Özet al / Hiç alma; önceden işaretli seçenek yok. _Kaynak:_ §13.4.1; PC-17.
- [ ] **Tık simetrisi ve karanlık kalıp yasakları (otomatik kabul testi)** — Geri alma ≤ verme tık sayısı; kabul/ret görsel eşdeğer (boyut, kontrast, konum, etiket ağırlığı); utandırıcı ret metni yok; EDPB 03/2022 kalıplarının yokluğu ve WCAG 2.2 AA otomatik kabul testidir. _Kaynak:_ §8.7, §13.4.4; X-20, PC-18.
- [ ] **KVKK rıza ekranı kuralları** — İzin ekranı her zaman atlanabilir; özellik erişimine bağlanamaz; aydınlatma ile açık rıza ayrı ekranda ve ayrı işaretlenir; `transactional`/`operational` için rıza sorulmaz. _Kaynak:_ §8.7, §13.4.4; X-21, PC-19.
- [ ] **Birleşik "Tercihlerim" ekranı** — Access + Relay bağlıyken izinler (Access) ve bildirim tercihleri (Relay) tek ekranda, kaynakları ayrı kalarak gösterilir; her alan sahibine yazılır. _Kaynak:_ §7.3.4, §8.7; E-19, X-19.

#### Panel
- [ ] **Panel bağlam ve gösterim çerçevesi** — Panel her zaman tek kiracı bağlamındadır; ortam ve alt kiracı seçimi her ekranda görünür; PII maskeli gösterim ve "göster" eylemi UI'da. _Kaynak:_ §8.2.1; X-4, X-5.
- [ ] **Panel: aktivite, raporlar, denetim kaydı** — Aktivite (bildirim/teslim listesi, deneme geçmişi, defter, atlama kayıtları, satır başına karar ve `rule_id`), raporlar (huni, kanal/sağlayıcı oranları, insan/bot etkileşim, A/B, maliyet, atlama nedeni dağılımı), denetim kaydı görüntüleyici. _Kaynak:_ §8.2.2, §14.3.4, §14.5.1; X-1, DS-16, DS-24.
- [ ] **Panel: workflow, şablon, rota, eskalasyon ekranları** — Workflow sürümleri ve yayın geçmişi; şablon/layout kanal × locale matrisi, önizleme, yayın kapısı sonuçları, eksik locale ölçümü; rota ve eskalasyon politikalarının kullanım yerleri ve değişiklik etkisi. _Kaynak:_ §8.2.2.
- [ ] **Panelde render ve locale sorun toplamları** — `render_failed` nedenleri, `template_locale_missing`, render ölçümleri, WhatsApp kota/red gerekçesi toplu gösterilir. _Kaynak:_ §11.2, §11.5, §11.6, §11.11; TP-7, TP-23, TP-26, TP-41.
- [ ] **Panel: alıcılar, topic'ler, ajanlar, bekleyen istekler, ajan tavanı** — Profil, cihazlar, abonelikler, ajan kaydı ve posta kutusu durumu; `open`/`stalled` bekleme noktaları, eskalasyon kademesi ve eskalasyonla çözülen oran, kanıt düzeyi dağılımı; tavan aşımında bekletilen ajan bildirimleri için hepsini gönder/iptal/ajanı durdur. _Kaynak:_ §8.2.2, §17.14, §17.15; AG-49, AG-54.
- [ ] **Panel: kanallar, gönderici kimlikleri, uyum, webhook, kill switch, ayarlar** — Sağlayıcı hesapları, doğrulama ve devre kesici durumu, "yurt dışına veri gönderir" ve adaptör kullanımdan kaldırma uyarıları; SMS başlıkları, alan adı doğrulama sihirbazı (DNS kayıt rehberi, uyarılar, durum), ısınma planı; İYS bağlantı/senkron, ülke kuralları, kilitli kategoriler; uç noktalar, teslim logu, DLQ, replay, uç sağlığı; aktif kill switch'ler her zaman görünür (kapsam × hedef × sınıf × durum, yürürlük gecikmesi); API anahtarları, roller, saklama, `default_timezone`/`default_locale`. _Kaynak:_ §8.2.2, §12.6.3, §18.5.2; CH-36, TN-41, TN-44.
- [ ] **Panelde ücretli kanal maliyeti gösterimi** — SMS, ses, WhatsApp marketing seçimi maliyetiyle gösterilir. _Kaynak:_ §12.3.5; CH-18.
- [ ] **Operatör paneli ekranları** — Kiracı yönetimi, platform kill switch, `critical` açılımı, kiracı askıya alma, bölge sağlığı Relay'in kendi panelindedir. _Kaynak:_ §8.2.4; X-7.

#### "Neden almadım" ekranı
- [ ] **"Neden almadım" ekranı** — Telefon/e-posta/alıcı kimliğiyle giriş; kanal × izin (kaynak, tarih) ve tercih seviyeleri; son 30 günün bütün kararları (gönderilmeyenler dahil) `rule_id` + sözlük cümlesiyle ve kapatan tercih seviyesi; denemeler, sağlayıcı ham yanıtı, bastırma kaydı, cihaz izin durumu; PII maskeli, "göster" denetimli, toplu liste çekilemez; ekran kendi metnini üretmez. _Kaynak:_ §1.4, §1.7, §8.4, §14.5.4, §20.6; MD-12, X-12, X-1, DS-28, OP-40.
- [ ] **"Neden almadım" 30 saniye hedefi** — Sorunun 30 saniyede cevaplanması kullanılabilirlik testiyle ölçülür (ENGINEERING ASSUMPTION). _Kaynak:_ §8.4; X-13.

#### Workflow ve şablon editörleri
- [ ] **Görsel workflow editörü** — Sürükle-bırak, taslak/test/yayın, tek tıkla eski sürüme dönüş; adım paleti sekiz adımla sınırlı (kanal, bekle, digest, throttle, koşul, olay bekle, zaman penceresi, webhook); koşullar listelerden seçilerek kurulur; rota/deney/eskalasyon tanımı; yayın kapısı sonuçları yayından önce gösterilir, sert kapı geçilmeden yayın çalışmaz; koddan yönetilen akışta kilit uyarısı. _Kaynak:_ §8.3, §10.2, §10.3; X-8, X-9, X-10, WF-3, WF-4, WF-10.
- [ ] **Kod-öncelikli workflow, GitOps ve promote** — SDK'da kendi dilinde yazılan workflow yayında ortak tanım biçimine derlenir, çalışma anında müşteri koduna çağrı yoktur; dosya tabanlı GitOps ve ortamlar arası promote. _Kaynak:_ §4.4.3, §8.3.1, §10.2; MKT-19, X-8, WF-3, WF-5.
- [ ] **Eskalasyon politikası panel editörü** — Eskalasyon politikası panelde görsel olarak yazılır. _Kaynak:_ §17.5; AG-17.
- [ ] **Şablon editörü yardımcıları** — "E-postadan SMS taslağı üret" (düzenlenebilir taslak, canlı bağ yok); çoğul alanlarda dilin CLDR kategorileri gösterilir, ICU arka planda üretilir; düz metin taslağı HTML'den. _Kaynak:_ §11.3, §11.5, §11.6; TP-10, TP-22, TP-27.
- [ ] **Kanala doğru önizleme görünümleri** — iOS kilit ekranı/bildirim merkezi, Android daraltılmış/genişletilmiş, SMS balonu (segment, kodlama, maliyet, transliterasyon öncesi/sonrası), WhatsApp balonu, inbox satırı, e-posta (boyut, düz metin, koyu mod, dar/geniş). _Kaynak:_ §11.10; TP-38.
- [ ] **Sandbox önizleme** — Ayrı origin, CSP, iframe `sandbox`; `raw_html` ve `| raw` çıktısı yalnız orada görüntülenir. _Kaynak:_ §11.5, §11.10; TP-24, TP-39.

#### Test düzlemi deneyimi
- [ ] **Test düzlemi deneyimi** — Ürün içi test ortamı canlıyla aynı hat, yalnız son adımda sahte sağlayıcı; `rule_id`'ler özdeş. _Kaynak:_ §1.7, §2.2; F-10, MD-18, INV-58.
- [ ] **Test inbox'ı ve tohum alıcılar** — Test düzleminde gönderilen her mesaj panelde render edilmiş hâliyle görünür; hazır alıcı profilleri ("izinsiz", "ret vermiş", "sessiz saatte", "tavanı dolmuş"). _Kaynak:_ §8.9; X-26.
- [ ] **İlk bildirim akışı (5 dakika)** — Hazır örnek workflow (in-app + e-posta), kimlik bilgisiz sahte sağlayıcı, ilk bildirim tek `curl` ile; mesaj test inbox'ında ve inbox bileşeninde karar + `rule_id` ile görünür; hedef onboarding kabul testiyle ölçülür. _Kaynak:_ §8.12, §9.1; X-35, X-36, API-5.

#### Belge sitesi
- [ ] **Belge sitesi** — Sektör terimi eşleme tablosu, kanal başına teslim semantiği, garanti dili ve CDC rehberini taşıyan belge sitesi. _Kaynak:_ §2.8, §5.13, §6.12; F-13, INV-60.
- [ ] **Çalıştırılan belge örnekleri** — Belgelerdeki her `curl` ve dil örneği CI'da `test` düzlemine karşı çalışır; çalışmayan örnek build'i kırar. _Kaynak:_ §8.12, §9.1; X-37, API-5.
- [ ] **Koddan üretilen limitler sayfası** — "Limitler, retry takvimleri, garantiler" sayfası kodla aynı kaynaktan üretilir, elle kopya yok; ajan kaynak sınırları da burada. _Kaynak:_ §8.12, §9.1, §17.15; X-37, API-4, AG-53.
- [ ] **Tek garanti dili** — "En az bir kez teslim + kalıcı idempotency ile etkin tek seferlik işlem"; "exactly-once" tek başına kullanılmaz. _Kaynak:_ §8.12; X-38.
- [ ] **CDC bağlama rehberi** — Müşteri DB bağlayıcısı yerine Debezium/Sequin gibi araçları CloudEvents çıkışıyla bağlama rehberi. _Kaynak:_ §7.10, §8.12; E-66.
- [ ] **MCP sunucusu ve ajan "skills" paketi** — Ajan dostu geliştirici araçları ürünün ve belgelerin parçası olarak yayımlanır. _Kaynak:_ §4.2, §8.12, §17.13.2; L-30, X-39, AG-43.
- [ ] **Ajan tarafı güvenlik rehberi** — Ayrıcalıksız bağlamda işleme (çift model), imza doğrulama, eylem öncesi yetki kararı; dış çağrı + güvenilmez içerik + özel veri aynı bağlamda birleştirilmez. _Kaynak:_ §17.12; AG-41.
- [ ] **Relay ürün metinleri çeviri akışı** — Çeviri yönetim sistemi + CI denetimi (eksik çeviri, yer tutucu kümesi karşılaştırması, sözde yerelleştirme). _Kaynak:_ §11.6; TP-30.
- [ ] **WATCH: farklılaşma iddiaları** — Her iddia karşılaştırma kümesi, tarih ve karşı örnekle izlenir; karşı örnek görülürse iddia düşer. _Kaynak:_ §22.2; MKT-2…MKT-18, OQ-28.

#### Bu aşamada doğrulanacak sınırlar
- **INV-58** — Test düzlemi canlıyla aynı hattan geçer; yalnız son adım sahte, `rule_id`'ler özdeş.
- **INV-60, X-38** — Tek garanti dili; "exactly-once" tek başına geçmez.
- **X-2** — Hiçbir yüzey self-host'ta eksik ya da lisans bayrağıyla kilitli değil.
- **X-6** — Dürüst gösterim: dış projeksiyon durumu, push'ta "teslim edildi" yok, renkten bağımsız durum.
- **X-12** — "Neden almadım" ekranı kendi metnini üretmez; sözlük cümlesi + `rule_id`, PII maskeli.
- **X-20, X-21, PC-17, PC-18, PC-19** — Tık simetrisi, karanlık kalıp yokluğu, WCAG 2.2 AA, atlanabilir rıza ekranı, önceden işaretsiz üç seçenek (otomatik kabul testleri).
- **X-29, API-65** — Her sunucu SDK'sında otomatik Idempotency-Key, yalnız `retryable: true`'da retry, hata hiyerarşisi, ham gövde webhook doğrulayıcı.
- **X-31** — Mobil SDK olay tetiklemez, profil/izin yazmaz, gizli anahtar tutmaz.
- **X-32** — Bileşenler yalnız dar kapsamlı abone jetonuyla çalışır; WCAG 2.2 AA.
- **X-37, API-5** — Belge örnekleri CI'da çalışır; limitler sayfası koddan üretilir.
- **TP-39** — `raw_html`/`| raw` yalnız ayrı origin'li sandbox önizlemede.

---

### Aşama 15 — İşletim ve dayanıklılık

Relay'i üretimde, bölge bölge ve kesintiye dayanıklı işletmek: bölge kurulumları ve veri yerleşimi, Postgres HA/DR, arşiv ve silme işletimi, dağıtım/ölçekleme/kapasite, runbook ve olay müdahalesi, oyun günü ve kaos, mevcut sistemden göç modları, self-host ve SaaS işletimi. Bütün önceki aşamalara (özellikle A0 altyapı, A1 defter ve kuyruk, A4 uyum, kill switch ve kiracı yalıtımı) dayanır.

#### Spec dışı ön koşullar
- [ ] **Bölge açılış sırası** — TN-55 bölgelerin (TR, AB, ABD) açılış sırasını "yapım sırasında belirlenir" diye bırakıyor; karar yok. (Adem kararı)
- [ ] **İşletim PD değerleri** — RPO/RTO (oyun gününde ölçülür, değer konmadan yayımlanmaz), şiddet yanıt süreleri ve SEV1 ilk müşteri bildirimi, oyun günü ritmi, gölge mod saklama ve çıkış eşikleri, kademeli yayılım eşikleri, autovacuum eşikleri PD; F-28 gereği değer konmadan yayımlanmaz. _Kaynak:_ §20.5, §20.8, §20.9, §22.3; OQ-27, OP-27, OP-31, OP-45, OP-46, OP-49, OP-52, OP-53. (Adem kararı)
- [ ] **Takedown ve trafik/erişim logu saklama süreleri** — PD değersiz (5651, DSA). _Kaynak:_ §22.3; OQ-27, TN-60. (Adem kararı)

#### Bölge kurulumu ve veri yerleşimi
- [ ] **Bölge başına bağımsız kurulum** — TR, AB, ABD; her bölgenin kendi Postgres, Valkey, KMS/HSM'i; bölgeler arası replikasyon, yedek ya da işletim verisi kopyası yok, bölgeler arası görünüm sorguyla; DR bölge içinde; her bölge self-host paketiyle kurulur. _Kaynak:_ §1.7, §4.3.2, §18.8; MD-10, L-56, INV-41, TN-55.
- [ ] **Türkiye bölgesi yurt içi** — Yurt içi veri merkezi ya da yerli bulut; yedekler, anahtar yedekleri ve gözlem verisi yurt içinde. _Kaynak:_ §18.8, §20.10; TN-56, OP-58.
- [ ] **Bölge kurulum paketi ve kabul testi** — Veri yerleşimli sağlayıcı kataloğu, ön katman, aynı bölgede Access, bağımsız bildirim yolu; bölge kabul testi (yalıtım, kill switch yayılımı, failover, arşiv/geri yükleme, gölge gönderim). _Kaynak:_ §20.10; OP-58.
- [ ] **Bölge başına temel adres** — Her veri bölgesinin kendi temel adresi; başka bölgenin verisine erişmez, bölgeler arası yönlendirme yapmaz. _Kaynak:_ §9.2; API-7.
- [ ] **Ön katman ve TLS yerleşimi** — CDN/WAF/DDoS ön katmanı isteğe bağlıdır ve bölge veri yerleşimine uyar; gelen TLS LB/ters vekilde sonlandırılabilir, ama regüle TR kiracılarında yurt dışında sonlandırılmaz (yurt içi sağlayıcı ya da TCP geçişi); imza doğrulaması uygulamada. _Kaynak:_ §7.10, §18.8, §19.8, §20.10; E-69, TN-55, TN-56, T-43 (gelen), OP-59.
- [ ] **Bölge başına sabit çıkış IP'leri** — IP izin listesi isteyen sağlayıcılar ve webhook alıcıları için bölge başına statik çıkış IP'leri yayımlanır, bölge dışına taşmaz (self-host belgesi, SaaS ağ tasarımı). _Kaynak:_ §12.7.4, §16.8.3; CH-51, WH-42.
- [ ] **Lisanslı kiracı dağıtım rehberi** — TR bölgesi ya da self-host + yerli sağlayıcılar; APNs'siz iOS push yolu olmadığı açıkça belirtilir. _Kaynak:_ §18.8; TN-59.

#### Anahtar yönetimi
- [ ] **Kendi anahtarını getir (BYOK)** — Kiracı başına ayrı KMS anahtarı seçeneği, self-host'ta da. _Kaynak:_ §18.4.1; TN-27.
- [ ] **HSM politikası** — Varsayılan bulut KMS; tek kiracılı HSM yalnız denetçi/regülasyon istediğinde, port soyutlamasıyla kod değişmeden (WATCH). _Kaynak:_ §18.4.3; TN-34.

#### Postgres HA ve DR
- [ ] **Postgres HA ve DR** — Yönetilen HA ya da olgun operatör; senkron kuorum `ANY 1 (s1, s2)`, `FIRST 1` yok; DR ve PITR bölge içinde. _Kaynak:_ §20.5; OP-27.
- [ ] **Failover mükerrere mal olur, kayba değil** — Kısa zombi kurtarma eşiği + tekillik; salt okunur hatalı bağlantılar yenilenir; uygulama düzeyi idempotency zorunlu. _Kaynak:_ §20.5; OP-28.
- [ ] **Bağlantı havuzlama kuralı** — `düğüm × havuz × 2` < `max_connections`/2 ise havuzlayıcısız; aksi hâlde güncel PgBouncer işlem kipi (ilk geçen olunmaz); havuz bekleme hatası yük atmadır. _Kaynak:_ §20.5; OP-30.
- [ ] **Veritabanı sağlık alarmları** — Replikasyon slotu, WAL tutma, XID sarma, arşivleyici, disk %70/%85, ölü satır, indeks şişmesi, uzun işlem, geçersiz indeks; WAL elle silinmez; yaprak başına autovacuum. _Kaynak:_ §20.5; OP-31.

#### Saklama, arşiv, silme ve denetim işletimi
- [ ] **Soğuk arşiv taşıması** — Yumuşak silme + crypto-shred → `DETACH … CONCURRENTLY` → Parquet + şema WORM bölge içi arşiv → satır sayısı + özet doğrulama → sıcak kopya yalnız doğrulamadan sonra `relay_archive` rolüyle kaldırılır; başarısızlıkta baştan, aynı anda tek ayırma; veri imha edilmez. Defter ve inbox bölümleri aynı yolla taşınır. _Kaynak:_ §1.7, §6.9, §15.7.1, §20.3; MD-9, INV-47, IN-44, OP-15.
- [ ] **Kademeli defter saklama ve uyum arşivi** — Defter sıcak/ılık/soğuk arşivde; uyum kanıtı iş kuyruğu temizliğinden etkilenmeyen kalıcı kayıtlarda ve arşivde. _Kaynak:_ §14.9.1; DS-44.
- [ ] **Özne silmesinin kapsamı** — Özne silmesi kuyruktaki işlere, zamanlanmış gönderimlere, digest tamponlarına ve inbox'a uygulanır; yasal kanıt ayrı ve en az veriyle. _Kaynak:_ §15.7.2; IN-45.
- [ ] **Kiracı kapatma ve dışa aktarma** — Kapatmadan önce tam dışa aktarma (JSON/CSV/Parquet); sonra kiracı veri anahtarları ve yükümlülüksüz özne DEK'leri imha; kişi bazlı dışa aktarma. _Kaynak:_ §20.4; OP-26.
- [ ] **Üretimde gecelik yalıtım denetimi** — `tenant_id IS NULL` satır yok, yetim satır yok (FK'siz tablolar dahil), bileşik FK yerinde. _Kaynak:_ §18.2; TN-12, TN-16.
- [ ] **Denetim kontrol noktası yayını ve SIEM aktarımı** — Kontrol noktası dışarı yayımlanır (nesne kilitli depo, SIEM, isteğe bağlı müşteri hedefi); denetim kaydı sürekli akış/toplu dosya ile SIEM'e. _Kaynak:_ §18.6; TN-46, TN-49.

#### Dağıtım, ölçekleme ve kapasite
- [ ] **Kapatma sırası, kademeli dağıtım ve yeniden bağlanma fırtınası önleme** — Yayın kademeli; readiness düşür → LB çıkarsın → işleri ve bağlantıları parti parti boşalt; orkestratör süresi > kuyruk payı + realtime boşaltma (dağıtım testi); jitter'lı yeniden bağlanma, bir seferde sınırlı düğüm yenileme. _Kaynak:_ §15.4.13, §19.2; IN-34, T-5 (madde 2, 4).
- [ ] **Kuyruk gecikmesine göre ölçekleme** — Otomatik ölçekleme sinyali şerit başına en eski iş yaşı ve derinlik, CPU% değil; sağlayıcı kapasitesi doğrulanmadan yatay ölçekleme yok. _Kaynak:_ §19.2; T-6.
- [ ] **Kapasite varsayımları ve kaçış sırası** — EA tablosu (düğüm verimi, ~3 defter olayı, ~1,2 iş, PG GCRA 2–5k, ρ 0,7, 10M push) ölçümle kesinleşir; kaçış: indeks/şişme → kuyruk ayarı → rapor/replika → kiracıya göre ayrı kurulum; kuyruğu ayrı DB'ye taşımak ayrı karar. _Kaynak:_ §20.11; OP-61.
- [ ] **Kaos ve açık döngü yük testleri** — Toxiproxy ile Valkey, sağlayıcı ve PG kesintileri; açık döngü (sabit varış oranı) yük testleri, kapalı döngü araç yok; gece koşar. _Kaynak:_ §19.10, §19.13.6; T-52 (yük/kaos), T-61 (madde 1 kaos/yük).

#### Olay müdahalesi ve runbook'lar
- [ ] **Relay kendine bağımlı değil** — Olay bildirimi, durum sayfası ve nöbet sayfalaması Relay'den geçmez: ayrı barındırılan durum sayfası (izlenir), ayrı e-posta hesabı, bağımsız sağlayıcıda sayfalama; SMS birincil uyandırma değil, gece testiyle doğrulanır; runbook'lar bağımsız erişilebilir; self-host için belgeli. _Kaynak:_ §4.3.2, §6.11, §8.2.4, §20.8; L-58, INV-59, OP-48.
- [ ] **SLO değerlerinin işletimi** — Ölçüm sonrası SLO değerleri ve alarm eşikleri işletime bağlanır. _Kaynak:_ §14.8.3; DS-42.
- [ ] **Runbook disiplini** — Altı zorunlu bölüm; öncelik kanamayı durdurmak; makine okunur başlık; 6 aydan eski test CI'ı kırar; kopyala-yapıştır komutlar, durum değiştiren blok ayrı; metin karar ağacı; depoda sürümlü, çevrimdışı kopya; her alarmın runbook'u. _Kaynak:_ §20.8; OP-43, T-66 (madde 5).
- [ ] **Tek düğmeli azaltma ve otomasyon merdiveni** — Her azaltma adımı test edilebilir, denetimli, idempotent operatör API/CLI eylemi; merdiven 0–4 ve dönüştürme koşulları; geri alınamaz eylem, uyum kararı ve itibar otomatik açılmaz. _Kaynak:_ §20.8; OP-44.
- [ ] **Tek şiddet taksonomisi** — SEV1–4 tablosu ve değiştiriciler; yanıt süresi hedefleri PD; başka tablo yok. _Kaynak:_ §20.8; OP-45.
- [ ] **Olay ilanı, roller, postmortem, nöbet devri** — Erken ilan soruları; olay komutanı/operasyon/iletişim/uyum rolleri; müşteri bildirimi; zorunlu suçlamasız postmortem şablonu; yazılı devir, kill switch canlı okunur. _Kaynak:_ §20.8; OP-46.
- [ ] **Toplu yanlış gönderimde önce durdur** — Kill switch + bekleyen işleri bekletme < 60 sn; kontrol listeli kademeli yeniden açma (%1 → %10 → %100); otomatik özür yok; yanlış veri eşleme ihlal değerlendirmesi başlatır. _Kaynak:_ §20.8; OP-47.
- [ ] **Kill switch acil durum prosedürü ve tatbikatı** — Belgelenmiş doğrudan DB kaydı + yeniden yükleme sinyali prosedürü aynı kaydı ve denetimi üretir; kill switch oyun günlerinde düzenli çekilir, yayılım süresi ölçülür. _Kaynak:_ §18.5.1, §18.5.2; TN-39, TN-45.
- [ ] **Oyun günü ve hata enjeksiyonu** — Dört aile (sağlayıcı, uyum, altyapı, insan); hipotez/ölçüm/kabul; enjeksiyon kill switch altyapısıyla, oran + TTL zorunlu, yalnız üretim dışı ya da açık kaos kipinde; yeni runbook belirli sürede oyun gününden geçer. _Kaynak:_ §20.8; OP-49.
- [ ] **Kapasite olayı sırası ve bilinen tepe planı** — Sağlayıcı → kuyruk → düğüm → DB; gerçek talep / kötüye kullanım / retry fırtınası ayrımı; bilinen tepe proje olarak planlanır. _Kaynak:_ §20.8; OP-50.

#### Göç modları
- [ ] **Gölge mod** — Sağlayıcı doğrulama kipi ya da yerel doğrulama; webhook yalnız gölge uca; İYS'ye gidilmez; kullanıcıya mevcut sistemin sonucu; kasıtlı farklar listesi (sahipli, tarihli, metrikli); karar %100, içerik kanonik özet, yönlendirme ve performans karşılaştırması; maskeli kısa saklama + crypto-shred; kapsama temelli çıkış; ölçülemeyenler belgeli. _Kaynak:_ §20.9.1; OP-52.
- [ ] **Kademeli yayılım** — `özet(tenant, external_id) mod 10.000` yapışkan bölme, rastgele yok; yönlendirme sırası; ≤ 60 sn yayılım, 60 sn geri alma; tek komut acil durdurma + otomatik olay kaydı; rampa ≤ 5× ve ≥ 1 gün, alt sınır %1; kademeli müdahale. _Kaynak:_ §20.9.2; OP-53.
- [ ] **Çift gönderim önleme** — İki sistem aynı dedup anahtarı ve ortak tekillik deposu; tek istemci gösterim noktası; çift yazım tek yazma + outbox; mükerrer oranı istemci telemetrisiyle. _Kaynak:_ §20.9.2; OP-54.
- [ ] **İçe aktarma veri kuralları** — Kimlik bağlamı sabit (ayrı APNs anahtarı); sıra bastırma/izin → token/adres → doğrulama → mod; asimetrik izin eşlemesi, bilinmeyen "göçle gelen, bilinmiyor"; `(token, platform)` benzersiz; otomatik birleştirme yok; sağlayıcı kimliği PK değil; E.164/BCP 47 normalizasyonu, geçersiz kova; AST tabanlı şablon dönüşümü (`AUTO_OK|NEEDS_REVIEW|CANNOT`); TN-58 meta verisi. _Kaynak:_ §20.9.3; OP-55.
- [ ] **Kesme ve zamanlanmış iş devri** — Yeni iş kabulü çevrilir, uçuştaki eskide boşalır; zamanlanmış işte önce ekle sonra iptal; açık digest geçirilmez; atomik cron devri, ilk çalışma gözetimli `dry_run`; eski webhook alıcısı açık kalır; sıcak yedek süresi kiracının. _Kaynak:_ §20.9.3; OP-56.

#### Hizmet ve self-host işletimi
- [ ] **Self-host işletimi** — Compose + Kubernetes belgesi, sırlar referansla; hesapsız kanallar çekirdekte (SMTP, Web Push, in-app), diğerleri BYO, APNs'siz iOS yok belgeli; tam özellik eşitliği, SaaS farkı yalnız hizmet; işletim belgeleri (yedek/geri yükleme, partition alarmı, yükseltme, kill switch, bağımsız bildirim, runbook seti). _Kaynak:_ §20.12; OP-62.
- [ ] **SaaS hizmet işletimi** — Paylaşılan sağlayıcı hesapları ve gönderici itibarı, çok bölgeli işletim ve SLA, yönetilen İYS bağlantısı, yedekleme, güncelleme, nöbet (özellik değil hizmet). _Kaynak:_ §1.7; MD-4.
- [ ] **Taşınabilirlik rehberi** — Kapanma riskine karşı self-host eşitliği, olay akışı ve ham veri dışa aktarımı işletim rehberi. _Kaynak:_ §4.3.2; L-57.

#### Bu aşamada doğrulanacak sınırlar
- **INV-41, TN-55, TN-56, API-7, OP-58, OP-59** — Bölgeler arası veri kopyası/yönlendirme yok; TR verisi, yedeği ve anahtar yedeği yurt içinde; regüle TR kiracısında TLS yurt dışında sonlanmaz; bölge kabul testi.
- **INV-47, OP-15** — Arşivde sıcak kopya yalnız doğrulamadan sonra ve yalnız arşiv rolüyle kaldırılır; imha yok.
- **INV-59, OP-48** — Relay'in olay bildirimi ve sayfalaması Relay'den geçmez.
- **TN-16 (#6)** — Gecelik yalıtım denetimi: `tenant_id IS NULL` ve yetim satır yok.
- **TN-39 (< 2 sn ölçümü), TN-45, OP-47** — Kill switch yayılım süresi ölçülür; acil durum prosedürü aynı kaydı üretir; toplu yanlış gönderim < 60 sn'de durur.
- **T-5** — Kapatma sırası ve boşaltma süresi dağıtım testiyle.
- **OP-26** — Kiracı kapatmada önce dışa aktarma, sonra anahtar imhası.
- **OP-27, OP-28** — Senkron kuorum `ANY 1`; failover kayıp değil yalnız mükerrer üretir.
- **OP-44, OP-49** — Azaltma eylemleri idempotent ve denetimli; hata enjeksiyonu oran + TTL'li, yalnız üretim dışı/kaos kipinde.
- **OP-52, OP-53, OP-54, OP-55, OP-56** — Gölge modda İYS'ye ve canlı webhook'a gidilmez; yapışkan bölme ve 60 sn geri alma; çift gönderim yok; içe aktarma sırası ve otomatik birleştirme yokluğu; kesmede açık digest geçirilmez.

---

### Bilinçli olarak olmayanlar

#### Yürütme motoru ve ajan sınırları
- **Dayanıklı yürütme motoru, checkpoint, saga/telafi** — Checkpoint, pause, takeover, devam ve iş etkisi telafisi bekleyen tarafındır (Access E31); dayanıklı yürütme ayrı ürün sınıfı. Relay ajan adımı çalıştırmaz, yalnız bekler ve eşleştirir. _Kaynak:_ MD-3, E-46, AG-55.
- **Onay kapısı olmak, risk kademesi üretmek** — Yetki Access'te, onay politikası sahibinde. _Kaynak:_ AG-55.
- **Otomatik ret/kabul kararı** — Karar sahibinindir; Relay yalnız `waitpoint.expired` üretir. _Kaynak:_ AG-55.
- **Ajana serbest metin talimat yazmak, LLM ile içerik üretmek** — Prompt injection yüzeyi. _Kaynak:_ AG-55.
- **Ajan sohbet/konuşma ürünü** — Relay teslim ve bekleme katmanıdır; konuşma durumu ajan sistemindedir. _Kaynak:_ AG-55.
- **İnsanın iş ve onay kuyruğu** — Work'ündür (Access XI-7); Relay posta kutusu ajanın kutusudur. _Kaynak:_ F-14, AG-55.
- **OTP kodu üretme, sır tutma, doğrulama** — Gönderenin işi; Relay yalnız hedef korumalarını uygular. _Kaynak:_ F-15.

#### Pazarlama otomasyonu ve iş kuralları
- **Öznitelik sorgulu segment / journey motoru ve kurucu editörü** — Pazarlama otomasyonu ürün sınıfı; kiracı segmenti hesaplayıp liste gönderir. _Kaynak:_ F-12, E-67, X-41, WF-54.
- **Koşullu tercih** — Koşul iş kuralıdır; kiracı değerlendirip olayı gönderir. _Kaynak:_ F-17.
- **Uzun vadeli zamanlama** — 90 günden uzun zamanlama, 31 günden uzun digest/throttle, 30 günden uzun olay bekleme müşterinin zamanlayıcısının işi. _Kaynak:_ F-16.

#### Müşteri kodu ve dış veri erişimi
- **Müşteri veritabanını okuyan bağlayıcı / CDC işletimi** — CDC araçları olgun, üretim sırası Relay'in sorumluluğu değil; Relay müşteri DB'sine erişmez, Debezium/Sequin CloudEvents çıkışıyla bağlanır ve yalnız belge rehberi verilir (A14). _Kaynak:_ F-13, E-66, API-30.
- **Kiracı kodu ve betik çalıştıran dönüşüm editörü** — Müşteri kodu Relay içinde çalışmaz: kod yürütme ve kaynak tüketimi yüzeyi, SSRF, deterministik tekrar oynatma. _Kaynak:_ F-19, E-68, X-41, WH-13.
- **Çalışma anında müşteri koduna çağıran köprü (bridge) ve API'de müşteri tanımlı köprü URL'si** — SSRF yüzeyi (Novu `bridgeUrl` dersi); tanım yayında derlenir, yerel geliştirme CLI tüneliyle. _Kaynak:_ F-19, E-68, X-41, WH-45.
- **Fetch/HTTP, veri güncelle, başka workflow çağır adımları; hesaplanan URL'ye istek** — SSRF, deterministik tekrar oynatmanın bozulması, döngü riski, gizli yazma yolu; veri olayla gelir, zincir webhook + yeni olayla kurulur. _Kaynak:_ F-19, E-68, WF-9, WH-43.
- **SaaS'ta iç ağ hedefi** — Yalnız self-host'ta izin listesiyle. _Kaynak:_ WH-44.

#### Ürün ilkeleri
- **Yalnız bulutta sunulan panel/UI özelliği** — Özellik eşitliği. _Kaynak:_ X-41.
- **Canlı düzlemde sanal saat ya da test kısayolu** — Güvenliği zayıflatan bayrak yok. _Kaynak:_ X-41.

#### Teslim garantileri ve istemci yolu
- **Varsayılan sıralı teslim / "exactly-once" garantisi** — Head-of-line tıkanması; dürüst garanti dili. _Kaynak:_ WH-3, WH-20.
- **Realtime üzerinden istemci yazması/yayını** — Sahte bildirim saldırısı; tek REST kod yolu. _Kaynak:_ IN-31.
- **İçeriksiz ya da kısa ömürlü inbox öğesi** — Talep oluşursa ayrı kararla. _Kaynak:_ IN-46.

#### Kanallar
- **RCS adaptörü** — TR'de RBM sunan operatör yok, doğrudan operatör anlaşması gerekir; operatör/CPaaS listeleri yıllık izlenir (WATCH). _Kaynak:_ CH-63.
- **BIMI** — VMC/CMC maliyeti, marka tescili, sınırlı istemci desteği, DMARCbis ile çelişen `pct=100`. _Kaynak:_ CH-64.
- **Relay'in giden MTA işletmesi** — Relay MTA işletmez; SaaS'ta ticari ESP. _Kaynak:_ CH-34.

#### Çalışma ortamı ve realtime
- **Ayrı realtime sunucusu, WebTransport, Phoenix Presence** — Realtime Phoenix içinde; WebTransport'ta sunucu tarafı olgun değil, UDP/443 sık engelli, WebSocket yedeği her durumda gerekli; Presence'ta yakınsama/bellek sorunları. _Kaynak:_ F-18, IN-23, T-4.
- **Edge çalışma ortamları** — Kalıcı bağlantı, transaction ve veri yerleşimi uyuşmaz (TCMB/BDDK yurt içi tutma). _Kaynak:_ F-18, E-69, OP-60.

#### Teknoloji ve kütüphane seçimleri
- **Postgres LISTEN/NOTIFY ve Erlang `:pg` bildiricisi** — Dayanıksız, havuzlayıcıyla uyumsuz, commit'leri serileştirir; distribution kapalı. _Kaynak:_ T-10, T-55.
- **Horde, `:global` tekil süreçler, küme kütüphanesi liderliği** — Ağ bölünmesinde çift çalışma. _Kaynak:_ T-12.
- **Oban Pro / ticari kuyruk eklentisi** — Apache-2.0 bütünlüğü, açık çekirdek yok. _Kaynak:_ T-14.
- **Teslim yolunda Bloom filtresi/HyperLogLog** — Yanlış pozitif kayıp bildirim demektir. _Kaynak:_ T-16.
- **Bamboo** — Bakım modunda. _Kaynak:_ T-39.
- **Ash, Commanded/EventStore çekirdekte** — Katman ilkesiyle çelişir. _Kaynak:_ T-51.

#### Veri modeli, depolama ve saklama
- **Relay içinde OLAP / iç analitik veritabanı** — Tek zorunlu depo Postgres; rollup'lar hazır raporlara ve kiracı hedefine akışa yeter; ClickHouse vb. analitik DB'ler yalnız teslim hedefi. _Kaynak:_ E-65, DS-35, DS-37, OP-39, §20.13.
- **Kiracı başına şema/veritabanı** — Pool modeli. _Kaynak:_ TN-11, §20.13.
- **Kiracı başına ayrı kuyruk** — Binlerce üretici; adalet kuyruk içinde. _Kaynak:_ WH-38.
- **DEFAULT partition ve dış partition aracı** — Tam tarama, sessiz yanlış yerleşim. _Kaynak:_ OP-13.
- **Kiracı × zaman iki seviyeli partition** — Tablo sayısı ve planlama maliyeti. _Kaynak:_ OP-16.
- **Bölgeler arası replikasyon** — Veri yerleşimi. _Kaynak:_ TN-55, OP-27, §20.13.
- **Fiziksel silme** — Access OP-73; yerine yumuşak silme + crypto-shred + arşiv. _Kaynak:_ OP-17, §20.13.

<!-- toplam: 795 madde, 73 ön koşul, 38 kapsam dışı -->
