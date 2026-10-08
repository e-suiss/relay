## 0. Okuma rehberi

### 0.1 Bu belge nedir

Bu belge Suiss Relay'in kanonik spec'idir. Relay, Suiss'in bildirim, mesajlaşma ve event orkestrasyon platformudur (§1). Açık kaynaktır (Apache-2.0); aynı paketle self-host ve bölge başına SaaS olarak çalışır.

Spec Türkçe ve normatiftir. Teknik terimler gerektiğinde İngilizce kalır. Özet "Kısaca Relay" (`00-overview.md`) bölümündedir; özet ile numaralı bölümler çelişirse numaralı bölümler kazanır.

Kararlar şu ölçütlerle verilir:
- kanıt kalitesi: ölçüm, birincil kaynak, standart metni
- semantik doğruluk ve sahiplik netliği
- garanti dilinin dürüstlüğü (§3.3)
- uygulanabilirlik ve test edilebilirlik
- eksiksizlik

Yapım sırası spec'te değil, ayrı bir ekte belirlenir. Spec sürüm ya da aşama adı gibi zaman etiketi taşımaz; bir şey ya kapsamdadır ya da gerekçesiyle KAPSAM DIŞI'dır.

### 0.2 Merkezi kararlar (MD-1…MD-20)

Merkezi kararlar bütün bölümleri bağlar; tam metin §1.7'dedir.

| MD | Karar |
|---|---|
| MD-1 | Relay ve Access bağımsız çalışır, birlikte sürtünmesiz çalışır (Access E40) |
| MD-2 | Relay yetki ve onay kaynağı değildir; yanıt toplayıcıdır |
| MD-3 | Bekleme noktası ve teslim Relay'in; yürütme, checkpoint, devam ve telafi bekleyenin |
| MD-4 | Apache-2.0, tam özellik eşitliği; SaaS farkı hizmettir; open-core yok |
| MD-5 | Elixir/OTP + Phoenix; ayrı realtime sunucusu ve edge çalışma ortamı yok |
| MD-6 | Zorunlu bileşenler PostgreSQL + Valkey; doğruluk Postgres'te |
| MD-7 | Yalnız Oban OSS; hız limiti, adalet, workflow takibi, bekleme tablosu Relay'in kendi kodu |
| MD-8 | Yedi sabit mesaj sınıfı; kabulde atanır, değişmez; şerit sınıftan türer |
| MD-9 | Fiziksel silme yok; crypto-shredding; saklama Access OP-73/Access OP-74 ve Access Ek C |
| MD-10 | Bölge başına bağımsız kurulum; bölgeler arası veri akışı yok |
| MD-11 | Ajana yapılandırılmış mesaj teslim edilir; serbest metin talimat yok |
| MD-12 | Sessiz kayıp yok; karar ≠ hata |
| MD-13 | Önce sözleşme: OpenAPI 3.1 + AsyncAPI 3.x |
| MD-14 | Uyum ve güvenlik kapıları fail-closed; kiracı yalnız sıkılaştırır |
| MD-15 | Doğruluk kalıcı kayıtta; taşıma sinyal; dürüst garanti dili |
| MD-16 | Müşteri kodu Relay içinde çalışmaz |
| MD-17 | Türkiye birinci sınıf; uyum kuralları ülke tablosu; İYS'ye tek yazıcı Relay |
| MD-18 | Kiracı + tek seviyeli alt kiracı + `live`/`test` düzlemleri çekirdekte |
| MD-19 | Operatör kimliği herhangi bir OIDC IdP; Merkle kontrol noktalı denetim kaydı |
| MD-20 | Üç ayrı tekrar koruması: Idempotency-Key, `dedup_key`, içerik tekilleştirme |

### 0.3 Etiketler ve normatif dil

- **Statüler** §3.1'dedir: KANONİK DEĞİŞMEZ, MERKEZİ KARAR, FROZEN (ürün / teknik / landscape), POLICY DEFAULT, ENGINEERING ASSUMPTION, WATCH, KAPSAM DIŞI. **DAY-1** statüye dik bir niteliktir (§3.1a).
- **Garanti sınıfları** §3.3'tedir: BS, UDC, NG, PU.
- **⚠️ / "doğrulanmadı":** bilgi birincil kaynakta teyit edilmemiştir; yalnız gerekçe sütununda ve WATCH satırlarında kullanılır (§3.4).
- **PD (değer ölçümle):** değeri henüz konmamış POLICY DEFAULT; değer, bağlı özellik yapım sırasına girerken konur (F-28).
- **Normatif fiiller:** "zorunludur", "-ır/-ir" biçimindeki kesin anlatım ve "yapılmaz/yoktur" bağlayıcıdır. "-ebilir" izin verir, zorunlu kılmaz. "Önerilir" bağlayıcı değildir.
- **Atıflar:** Relay içi atıf "§n" ve ID ile (MD-6, F-4) yapılır. Access spec'ine atıf "Access E40", "Access OP-74" biçimindedir.

### 0.4 ID aileleri

| Aile | Bölüm | Aile | Bölüm |
|---|---|---|---|
| MD-n | §1 Merkezi kararlar | F-n | §2 Ürün tezi, §3 Statü sistemi |
| L-n, MKT-n | §4 Landscape | C-n | §5 Ontoloji |
| INV-n | §6 Değişmezler | E-n | §7 Ekosistem sınırları |
| X-n | §8 Ürün deneyimi | API-n | §9 API sözleşmesi |
| WF-n | §10 Workflow ve yönlendirme | TP-n | §11 Şablon ve yerelleştirme |
| CH-n | §12 Kanallar ve sağlayıcılar | PC-n | §13 Tercih ve uyum |
| DS-n | §14 Teslim durumu ve gözlem | IN-n | §15 Inbox ve realtime |
| WH-n | §16 Webhook ve event teslimi | AG-n | §17 Ajanlar |
| TN-n | §18 Kiracılık ve güvenlik | T-n | §19 Teknik mimari |
| OP-n | §20 Veri ve operasyon | OQ-n | §22 Açık sorular (karar üretmez) |

Birleşik register §21'de, aile listesi Ek A'dadır.

Her aile 1'den başlar; ID'ler yeniden kullanılmaz (§3.2, §3.7).

### 0.5 Bölüm haritası

| § | Dosya | Bölüm | İçerik |
|---|---|---|---|
| — | `00-overview.md` | Kısaca Relay | Ne, ne değil, çözdüğü problem, temel kavramlar (normatif değil) |
| 0 | `00-reading-guide.md` | Okuma rehberi | Bu bölüm |
| 1 | `01-executive-definition.md` | Executive Definition | Tanım, temel problem, ürün vaadi, tek soru, aktörler, merkezi kararlar (MD) |
| 2 | `02-product-thesis.md` | Product Thesis / IS / IS NOT | Tez, kapsam, komşu sınırları, must-never listesi (F) |
| 3 | `03-decision-status-system.md` | Decision Status System | Statüler, DAY-1, yeniden açma, garanti sınıfları, iddia dili (F) |
| 4 | `04-landscape-decisions.md` | Landscape Decisions | Benimsenen kalıplar, kaçınılan hatalar, farklılaşma ve parite (L, MKT) |
| 5 | `05-ontology.md` | Ontoloji | Kavramlar ve ilişkileri (C) |
| 6 | `06-invariants.md` | Değişmezler | Kanonik değişmezler (INV) |
| 7 | `07-ecosystem-boundaries.md` | Ekosistem sınırları | Access, Executor, Work, Pay, One, dış IdP'ler, ajan çerçeveleri (E) |
| 8 | `08-product-experience.md` | Ürün deneyimi | Panel, görsel editör, inbox UX, tercih ekranı, webhook portalı, test ortamı, SDK ve UI bileşenleri, geliştirici deneyimi (X) |
| 9 | `09-api-contract.md` | API sözleşmesi | Giriş, idempotency, batch, hatalar, sürümleme, iptal (API) |
| 10 | `10-workflow-routing.md` | Workflow ve yönlendirme | Workflow, adımlar, rota, kanal yükseltme, eskalasyon, digest, throttle, dedup, zamanlama, tekrar, saat dilimi, A/B, kitle ve topic (WF) |
| 11 | `11-templates-localization.md` | Şablon ve yerelleştirme | Şablon, layout, marka, korunan şablonlar, locale, render (TP) |
| 12 | `12-channels-providers.md` | Kanallar ve sağlayıcılar | Kanal adaptörleri, sağlayıcı yedeği, hata sınıfları, teslim edilebilirlik, push öncelik (CH) |
| 13 | `13-preferences-compliance.md` | Tercih ve uyum | Mesaj sınıfları, tercihler, izin, İYS, tek tık çıkış, ülke tablosu, sessiz saat (PC) |
| 14 | `14-delivery-state-observability.md` | Teslim durumu ve gözlem | Teslim defteri, durum projeksiyonu, atlama nedenleri, analitik, iz (DS) |
| 15 | `15-inbox-realtime.md` | Inbox ve realtime | Inbox veri modeli, okundu, rozet, akış ve kurtarma (IN) |
| 16 | `16-webhooks-event-delivery.md` | Webhook ve event teslimi | Giden webhook, olay hedefleri, imza, retry, DLQ, replay, portal, gelen sağlayıcı webhook'ları (WH) |
| 17 | `17-agents.md` | Ajanlar | Ajan alıcısı, posta kutusu, bekleme noktası, yanıt toplama, eskalasyon, A2A/MCP/AG-UI (AG) |
| 18 | `18-tenancy-security.md` | Kiracılık ve güvenlik | Kiracı, alt kiracı, bölge, kimlik ve operatör, anahtar ve sır yönetimi, kill switch, denetim kaydı, kriptografi (TN) |
| 19 | `19-technical-architecture.md` | Teknik mimari | Elixir/OTP, roller, Postgres + Valkey, Oban OSS ve kendi bileşenler, push istemcisi, bağımlılıklar (T) |
| 20 | `20-data-operations.md` | Veri ve operasyon | Veri modeli ve yazma yolları, saklama, HA/DR, gözlemlenebilirlik, SLO, runbook, göç ve yayılım, kapasite (OP) |
| 21 | `21-decision-register.md` | Birleşik karar register'ı | Bütün ailelerin register satırları |
| 22 | `22-open-questions.md` | Açık sorular | Kararı verilmemiş konular ve implementasyona etkisi |
| Ek A | `appendix-a-id-families.md` | ID aileleri | Aile, bölüm, aralık |
| Ek B | `appendix-b-feature-inventory.md` | Ek B. Özellik envanteri ve yapım sırası (normatif değil) | Aşamalar, maddeler, spec dışı ön koşullar, doğrulanacak sınırlar, kapsam dışı kararlar |
| — | `README.md` | Spec dizini | Dosya listesi ve kısa giriş |

### 0.6 Okuma sırası

- **Ürünü anlamak için:** "Kısaca Relay", §1, §2, §5'in temel kavramları, §7.
- **Uygulayıcılar için:** §3, §5, §6, §9, §10, §14, §19, §20; çalışılan alana göre §11–§13, §15–§18.
- **Ajan entegrasyonu için:** MD-2, MD-3, MD-11, §7, §17, §15, §16.
- **Uyum ve güvenlik için:** MD-9, MD-10, MD-14, MD-17, §13, §18, §20.
- **Access ile birlikte kurulum için:** MD-1, §7, Access E40 ve Access §7.9.8.
