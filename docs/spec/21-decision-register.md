## 21. Birleşik karar register'ı

Bu bölüm bütün ID ailelerinin özet register'ıdır. Kararların normatif metni ve tek tek register satırları kanonik bölümlerdedir; çelişkide kanonik bölüm kazanır. Statüler §3.1'deki sözlüğe uyar; `· PD/EA/WATCH (…)` niteliği §3.1 kurallarındaki gibidir ve statü sayımında satırın ana statüsü sayılır. ID aileleri ve anlamları Ek A'dadır; açık sorular §22'dedir.

### 21.1 Aileler

Kısaltmalar: KD = KANONİK DEĞİŞMEZ, MK = MERKEZİ KARAR, FÜ = FROZEN (ürün), FT = FROZEN (teknik), FL = FROZEN (landscape), PD = POLICY DEFAULT, EA = ENGINEERING ASSUMPTION, W = WATCH, KDI = KAPSAM DIŞI.

| Aile | Aralık (sayı) | Kanonik bölüm | Konu | Statü dağılımı |
|---|---|---|---|---|
| MD | MD-1–MD-20 (20) | [§1](01-executive-definition.md) | Merkezi kararlar | MK 20 |
| F | F-1–F-30 (30) | [§2](02-product-thesis.md), [§3](03-decision-status-system.md) | Ürün tezi (F-1–F-19, §2) ve statü sistemi (F-20–F-30, §3) | FÜ 22, KDI 8 |
| L | L-1–L-58 (58) | [§4](04-landscape-decisions.md) | Benimsenen ve kaçınılan sektör kalıpları | FL 58 |
| MKT | MKT-1–MKT-22 (22) | [§4](04-landscape-decisions.md) | Farklılaşma ve parite | FL 5, W 17 |
| C | C-1–C-89 (89) | [§5](05-ontology.md) | Kavramlar | KD 2, FÜ 65, FT 22 |
| INV | INV-1–INV-60 (60) | [§6](06-invariants.md) | Değişmezler | KD 60 |
| E | E-1–E-74 (74) | [§7](07-ecosystem-boundaries.md) | Ekosistem sınırları | KD 8, MK 7, FÜ 50, FT 1, PD 1, W 1, KDI 6 |
| X | X-1–X-41 (41) | [§8](08-product-experience.md) | Ürün deneyimi | KD 10, MK 4, FÜ 21, FT 3, EA 2, KDI 1 |
| API | API-1–API-71 (71) | [§9](09-api-contract.md) | API sözleşmesi | FT 66, PD 4, KDI 1 |
| WF | WF-1–WF-55 (55) | [§10](10-workflow-routing.md) | Workflow ve yönlendirme | FT 52, PD 1, KDI 2 |
| TP | TP-1–TP-44 (44) | [§11](11-templates-localization.md) | Şablon ve yerelleştirme | FT 43, PD 1 |
| CH | CH-1–CH-64 (64) | [§12](12-channels-providers.md) | Kanallar ve sağlayıcılar | KD 11, MK 4, FT 41, PD 4, EA 2, KDI 2 |
| PC | PC-1–PC-54 (54) | [§13](13-preferences-compliance.md) | Tercih ve uyum | KD 18, MK 7, FT 26, PD 3 |
| DS | DS-1–DS-46 (46) | [§14](14-delivery-state-observability.md) | Teslim durumu ve gözlem | KD 9, FÜ 9, FT 25, PD 1, EA 2 |
| IN | IN-1–IN-46 (46) | [§15](15-inbox-realtime.md) | Inbox ve realtime | KD 11, FÜ 9, FT 24, PD 1, EA 1 |
| WH | WH-1–WH-51 (51) | [§16](16-webhooks-event-delivery.md) | Webhook ve event teslimi | KD 7, FÜ 11, FT 27, PD 6 |
| AG | AG-1–AG-55 (55) | [§17](17-agents.md) | Ajanlar | KD 14, MK 2, FÜ 22, FT 12, PD 2, EA 1, W 1, KDI 1 |
| TN | TN-1–TN-62 (62) | [§18](18-tenancy-security.md) | Kiracılık ve güvenlik | KD 6, MK 10, FT 42, PD 3, W 1 |
| T | T-1–T-68 (68) | [§19](19-technical-architecture.md) | Teknik mimari ve mühendislik kuralları | KD 6, MK 7, FT 52, PD 2, W 1 |
| OP | OP-1–OP-63 (63) | [§20](20-data-operations.md) | Veri ve operasyon | KD 9, MK 6, FT 43, PD 3, EA 1, KDI 1 |

**Toplam:** 1073 karar. KD 171, MK 67, FÜ 209, FT 479, FL 63, PD 32, EA 9, W 21, KDI 22.

DAY-1 niteliği taşıyan merkezi kararlar §3.1a'dadır.

### 21.2 WATCH satırları

Ana statüsü WATCH olan ya da `· WATCH (…)` niteliği taşıyan satırlar. İzlenen maddeler §22.2'de açık soru olarak da listelenir; karar bekleyen WATCH satırı yoktur.

| ID | Bölüm | Karar | Statü |
|---|---|---|---|
| MKT-2 | §4 | Yerleşik eskalasyon zinciri | WATCH |
| MKT-3 | §4 | Kimliğe ve işleme bağlı insan yanıtı (Access + Relay) | WATCH |
| MKT-4 | §4 | Self-host tam eşitlik + küçük bağımlılık seti | WATCH |
| MKT-5 | §4 | Dayanıklı log olarak giden webhook | WATCH |
| MKT-6 | §4 | Atlama nedeni olayları | WATCH |
| MKT-7 | §4 | İçerik tabanlı tekilleştirme | WATCH |
| MKT-8 | §4 | Etkileşimde duran kanal yükseltmesi | WATCH |
| MKT-9 | §4 | Türkiye uyumu çekirdekte | WATCH |
| MKT-10 | §4 | Kiracı özellikleri ücretsiz çekirdekte | WATCH |
| MKT-11 | §4 | Erken yanıt tamponu + doğrulanan karar | WATCH |
| MKT-12 | §4 | Kanal-bağımsız kalıcı ajan posta kutusu | WATCH |
| MKT-13 | §4 | Özne bazlı silme API'si (crypto-shredding) | WATCH |
| MKT-14 | §4 | Kesin sayaçlar ve dürüst garanti dili | WATCH |
| MKT-15 | §4 | Elixir'de açık kaynak workflow takibi ve dağıtık hız limiti | WATCH |
| MKT-16 | §4 | Doğrulanmış sağlayıcıya kısıtlı failover | WATCH |
| MKT-17 | §4 | `sender_config` hata sınıfı | WATCH |
| MKT-18 | §4 | Gelen ajan mesajı güven etiketi | WATCH |
| E-74 | §7 | Protokol sürümleri (A2A v1.0, MCP 2026-07-28) | WATCH |
| CH-63 | §12 | RCS adaptörü kapsam dışıdır; operatör ve CPaaS bölge listeleri yıllık izlenir | KAPSAM DIŞI · WATCH (operatör ve CPaaS RCS listeleri) |
| PC-31 | §13 | İş günü/resmî tatil takvimi sürümlü veri tablosudur | FROZEN (teknik) · WATCH (güncelleme sahibi ve kaynağı) |
| PC-44 | §13 | Hazır gelen satırlar TR (6563/İYS), AB (GDPR/ePrivacy, soft opt-in) ve ABD (CAN-SPAM, TCPA saat penceresi, 10DLC) içindir (§13.8.2); satır içeriği değiştikçe tablo sürümü güncellenir | POLICY DEFAULT · WATCH (ABD rıza geri çekme kapsamı kuralının yürürlük durumu ⚠️) |
| AG-47 | §17 | Ajan protokol sürümleri hızla değişir; protokol değişikliği yalnız eşleme katmanını etkiler | WATCH |
| TN-34 | §18 | Varsayılan bulut KMS; tek kiracılı HSM yalnız denetim/regülasyon istediğinde | WATCH |
| T-2 | §19 | Dil kararının yeniden değerlendirme koşulları: telafili saga yürütme zorunluluğu, PG zamanlayıcının ölçümde yetmemesi, FIPS zorunluluğu | WATCH |

### 21.3 ENGINEERING ASSUMPTION satırları

Ana statüsü ENGINEERING ASSUMPTION olan ya da `· EA (…)` niteliği taşıyan satırlar. Her biri §3.1c benchmark alt koşuluna tabidir ve ölçülene kadar ürün iddiası değildir.

| ID | Bölüm | Karar | Statü |
|---|---|---|---|
| X-13 | §8 | "Neden almadım" sorusunu 30 saniyede cevaplama hedefi | ENGINEERING ASSUMPTION |
| X-36 | §8 | 5 dakika hedefinin karşılandığı | ENGINEERING ASSUMPTION |
| CH-12 | §12 | Backoff tam jitter'lı ve kanal × sınıf tablosundan gelir; `max_attempts` mesajın yararlılık ömrünü (`expires_at`) aşamaz; başlangıç tablosu §12.2.6 | ENGINEERING ASSUMPTION |
| CH-16 | §12 | Devre kesici başlangıç parametreleri §12.3.3 tablosundaki gibidir | ENGINEERING ASSUMPTION |
| CH-19 | §12 | Öncelik → platform eşleme tablosunun (§12.4.2) hücre değerleri test cihazlarında ölçülerek kesinleşir | MERKEZİ KARAR · EA (tablo hücre değerleri) |
| PC-33 | §13 | TR + `marketing` + bireysel alıcıda yerel İYS önbelleğinde ONAY yoksa ya da senkron bayatlık eşiğini aştıysa gönderilmez (fail-closed); başlangıç eşikleri 6 saat uyarı / 24 saat sayfalama ve durdurma | KANONİK DEĞİŞMEZ · EA (bayatlık eşikleri) |
| DS-22 | §14 | Sağlayıcı olay kimliğiyle kalıcı tekilleştirme; kanal başına periyodik mutabakat; sıklık ölçümle (§14.4.5) | ENGINEERING ASSUMPTION |
| DS-42 | §14 | Mesaj sınıfı başına tek SLO tablosu; değerler ölçülene kadar yazılmaz (§14.8.3) | ENGINEERING ASSUMPTION |
| IN-14 | §15 | Tümünü okundu atomik (sayaç sıfırı + işaret); keyfi filtre ve toplu arşiv/gizle asenkron parçalı; mekanizma ölçüme bağlı (§15.2.6) | ENGINEERING ASSUMPTION |
| AG-53 | §17 | Kaynak sınırları sayfası: bekleme başına mesaj/kademe, payload boyutu, azami bekleme (≤ 30 gün), eşzamanlı bekleme, lease/yeniden teslim; sayısal değerler | ENGINEERING ASSUMPTION |
| TN-39 | §18 | Doğruluk Postgres, yayılım Valkey sinyali, okuma düğüm önbelleği; Valkey yoksa yoklama; yayılım < 2 sn | FROZEN (teknik) · EA (< 2 sn) |
| T-23 | §19 | Fan-out dilimli (5.000/200), keyset, kontrol noktalı; kampanya modu; ilerleme tablosu; `partial`; "anında" iddiası yok | FROZEN (teknik) · EA (dilim ve eşik sayıları) |
| OP-61 | §20 | Kapasite varsayımları tablosu; tek birincil DB kaçış sırası; kuyruğu ayrı DB'ye taşımak ayrı karar | ENGINEERING ASSUMPTION |
