## Ek A. ID aileleri

Her aile 1'den başlar; ID'ler yeniden kullanılmaz ve emekli bir ID register'da "emekli → yerine geçen ID" olarak kalır (§3.2, §3.7). Bir bölüm yalnız kendi ailesinden ID verir; başka bölümün konusuna "§n" ile atıf yapar. Access spec'ine atıf her ID için "Access " önekiyle yapılır (ör. "Access E40", "Access OP-74"); önekli ID'ler Relay ailelerine ait değildir. Statü dağılımı §21'dedir.

| Aile | Bölüm | Anlam | Aralık |
|---|---|---|---|
| MD | §1 Executive Definition (§1.7) | Merkezi kararlar; bütün bölümleri bağlar, bölümler gevşetemez | MD-1–MD-20 |
| F | §2 Product Thesis ve §3 Decision Status System | Ürün tezi, kapsam (IS / IS NOT), must-never listesi (F-1–F-19, §2); statü sistemi, yeniden açma, garanti sınıfları ve register kuralları (F-20–F-30, §3). Aile iki bölüme yayılır | F-1–F-30 |
| L | §4 Landscape Decisions | Sektörden benimsenen kalıplar (L-1–L-30) ve kaçınılan hatalar ve olaylar (L-31–L-58) | L-1–L-58 |
| MKT | §4 Landscape Decisions (§4.4) | Farklılaşma iddiaları ve parite kalemleri; iddialar WATCH | MKT-1–MKT-22 |
| C | §5 Ontoloji | Kanonik kavramlar ve adları | C-1–C-89 |
| INV | §6 Değişmezler | Hiçbir ayarla gevşemeyen kurallar | INV-1–INV-60 |
| E | §7 Ekosistem sınırları | Access, Work, Executor, One, Pay, dış IdP'ler, ajan protokolleri ve diğer dış sistemlerle sahiplik sınırları | E-1–E-74 |
| X | §8 Ürün deneyimi | Panel, görsel editör, "neden almadım", inbox ve tercih UX'i, webhook portalı, test ortamı, SDK, UI bileşenleri, CLI, geliştirici belgeleri | X-1–X-41 |
| API | §9 API sözleşmesi | HTTP API, idempotency, hata modeli, kimlik doğrulama, sürümleme, sayfalama, iptal, gönderim modu | API-1–API-71 |
| WF | §10 Workflow ve yönlendirme | Workflow, adımlar, rota, kanal yükseltme, eskalasyon, digest, throttle, tekilleştirme, zamanlama, saat dilimi, tekrar, A/B, kitle | WF-1–WF-55 |
| TP | §11 Şablon ve yerelleştirme | Şablon motoru, varyantlar, değişken sözleşmesi, render, yerelleştirme, yayın kapısı, layout, üretici sahipli şablon | TP-1–TP-44 |
| CH | §12 Kanallar ve sağlayıcılar | Adaptör portu, hata sınıfları, retry, failover, devre kesici, öncelik, push, e-posta teslim edilebilirliği, SMS, ses, WhatsApp, mesajlaşma kanalları | CH-1–CH-64 |
| PC | §13 Tercih ve uyum | Mesaj sınıfları, politika kafesi, tercihler, izin, İYS, tek tık çıkış, ülke ve platform uyum tablosu, sessiz saat, frekans tavanı, OTP alt türleri | PC-1–PC-54 |
| DS | §14 Teslim durumu ve gözlem | Teslim defteri, dış projeksiyon, rapor pencereleri, atlama sözlüğü, etkileşim, analitik, iz, SLO | DS-1–DS-46 |
| IN | §15 Inbox ve realtime | Inbox veri modeli, okundu ve rozet, realtime akış, cihazlar arası yayılım, abone jetonu, inbox saklaması | IN-1–IN-46 |
| WH | §16 Webhook ve event teslimi | Teslim motoru, imza profili, hedef türleri, retry ve DLQ, kurtarma, SSRF, gömülebilir portal, gelen webhook'lar | WH-1–WH-51 |
| AG | §17 Ajanlar | Bekleme noktası, eskalasyon, posta kutusu, yanıt toplayıcı, onay güvenliği, yapılandırılmış mesaj, ajan protokolleri, ajan tavanı | AG-1–AG-55 |
| TN | §18 Kiracılık ve güvenlik | Kiracı ve alt kiracı, izolasyon, kimlik ve operatör, sır ve anahtar, kill switch, denetim kaydı, gürültülü komşu, bölge, kriptografi | TN-1–TN-62 |
| T | §19 Teknik mimari | Elixir/OTP, roller, Postgres + Valkey, iş kuyruğu, kendi bileşenler, şeritler, kanal istemcileri, BEAM işletimi, bağımlılıklar, yapım sırası kısıtları, mühendislik kuralları (§19.13) | T-1–T-68 |
| OP | §20 Veri ve operasyon | Veri modeli ve yazma yolları, partition ve arşiv, saklama ve silme, HA/DR, gözlemlenebilirlik, mutabakat, runbook, göç ve yayılım, bölge kurulumu, kapasite | OP-1–OP-63 |
| OQ | §22 Açık sorular | İzlenen sorular ve kapanan soruların kayıtları; karar üretmez, kapanan soru kararın ID'sine bağlanır | OQ-1–OQ-34 |

Emekli ID yoktur.
