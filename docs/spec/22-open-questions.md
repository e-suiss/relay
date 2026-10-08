## 22. Açık sorular

Bu bölüm Relay spec'inin bütün açık sorularını tek listede toplar (§3.6). "Açık" ertelenmiş değil, kararı henüz verilmemiş ya da kanıtı henüz bulunmamış demektir. Bir soru karara bağlandığında karar ilgili bölüme yeni ya da güncellenmiş bir ID ile yazılır ve soru §22.3'e "kapandı → ID" olarak taşınır; OQ numarası yeniden kullanılmaz.

"Bloklar mı?" sütunu, sorunun hangi implementasyonu karar verilene kadar durdurduğunu söyler.

### 22.1 Özet

Karar bekleyen açık soru yoktur. Açık kalan maddeler yalnız izlenen (WATCH) maddelerdir.

| OQ | Konu | Bloklar mı? | Etkilenen ID'ler |
|---|---|---|---|
| OQ-28 | Farklılaşma iddiaları | Hayır (izlenir) | MKT-2 … MKT-18 |
| OQ-29 | Ajan protokol sürümleri | Hayır (izlenir) | E-74, AG-47 |
| OQ-30 | Dil kararının yeniden değerlendirme koşulları | Hayır (izlenir) | T-2, MD-5 |
| OQ-31 | Tek kiracılı HSM ihtiyacı | Hayır (izlenir) | TN-34 |
| OQ-32 | RCS | Hayır (izlenir) | CH-63 |
| OQ-33 | ABD rıza geri çekme kapsamı kuralının yürürlüğü | Hayır (izlenir) | PC-44 |
| OQ-34 | İş günü / tatil takviminin güncelleme sahibi ve kaynağı | Hayır (izlenir) | PC-31 |

### 22.2 İzlenen maddeler (WATCH)

Bu maddeler karar beklemez; dış dünyadaki değişiklik izlenir ve değişiklik olursa ilgili karar yeniden değerlendirilir (§3.1).

**OQ-28 — Farklılaşma iddiaları (MKT-2 … MKT-18).** Her iddia karşılaştırma kümesi, tarih ve geçersiz kılacak karşı örnekle §4.4.2'dedir. Karşı örnek görülürse iddia düşer; tez değişmez.

**OQ-29 — Ajan protokol sürümleri (E-74, AG-47).** A2A ve MCP revizyon takvimi izlenir; değişiklik yalnız eşleme katmanını etkiler.

**OQ-30 — Dil kararının yeniden değerlendirme koşulları (T-2, MD-5).** Telafili saga yürütme zorunluluğu, Postgres üstü zamanlayıcının ölçümde yetmemesi, FIPS zorunluluğu. Bekleme noktası satır + zamanlayıcı olarak tasarlandığı için (MD-3) koşul bugün tetiklenmemiştir.

**OQ-31 — Tek kiracılı HSM (TN-34).** Varsayılan bulut KMS'tir; denetim ya da regülasyon tek kiracılı HSM isterse açılır.

**OQ-32 — RCS (CH-63).** Türkiye'de RBM sunan operatör yoktur; operatör ve CPaaS bölge listeleri yıllık izlenir.

**OQ-33 — ABD rıza geri çekme kapsamı kuralı (PC-44).** Kuralın yürürlük durumu ⚠️ doğrulanmadı; uyum tablosu satırı veriyle güncellenir.

**OQ-34 — İş günü / tatil takvimi (PC-31).** Takvim sürümlü veridir; güncelleme sahibi ve kaynağı belirlenecektir.

### 22.3 Kapanan sorular

| OQ | Soru | Karar | İşlendiği ID'ler |
|---|---|---|---|
| OQ-1 | `marketing` varsayılanı push ve WhatsApp'ta kapalı mı? | Varsayılan ülke ve platform satırından türer: iOS push ve WhatsApp kapalı (kullanıcı açarsa gider); Android push ve in-app kiracı seçer; ülke satırı onay istiyorsa her zaman kapalı; mevzuatın ya da platform kuralının istemediği izin şartı yok | PC-14, PC-15, PC-27, PC-43, PC-54 (yeni), MD-17 |
| OQ-2 | Kill switch'in engellediği iş duraklatılır mı, iptal edilir mi? | Varsayılan duraklatma (`PAUSED`; silinmez, hata sayılmaz, otomatik denenmez); resume'da baştan değerlendirme; toplu iptal ayrı, açık, denetim kayıtlı eylem; süresi dolan `expired` | TN-40, TN-36, C-65 |
| OQ-3 | Kuyruk bildiricisi hangi uygulamayla Valkey üzerinden taşınır? | Relay'in kendi Valkey bildiricisi (Oban notifier arayüzü); Valkey yoksa yoklama; LISTEN/NOTIFY ve `:pg` yok | T-55 (yeni), T-10, T-13, T-17, T-18 |
| OQ-4 | Kuyruk tablosunun temizlenmesi fiziksel silme yasağıyla nasıl bağdaşır? | Kuyruk tablosu geçici çalışma listesidir, yalnız kimlik taşır; sonuç kalıcı kayda yazıldıktan sonra temizlenebilir; tek istisna, kayıt tablolarına uygulanmaz (Access OP-73 madde 7) | OP-12, OP-9, OP-17, T-15, T-29, INV-47, MD-9 |
| OQ-5 | Soğuk arşive aktarılmış partition'ın sıcak kopyası kaldırılabilir mi? | Evet: WORM kopya doğrulandıktan sonra, yalnız arşiv rolüyle; veri imha edilmez (Access OP-73 madde 4) | OP-15, OP-9, OP-17, INV-47, MD-9 |
| OQ-6 | Denetim kaydı bütünlük modeli Access ile nasıl aynı olur? | Access modeli aynen: periyodik imzalı Merkle kontrol noktası, kayıt başına hash zinciri yok; tek doğrulayıcı; tek kaydın varlığı diğerleri açılmadan kanıtlanır | TN-46, OP-63 (yeni), INV-49, C-87, MD-19, E-31 |
| OQ-7 | Başlık ekleyemeyen CloudEvents üreticisi `Idempotency-Key` kuralını nasıl karşılar? | Yalnız CloudEvents girişinde anahtar `(tenant, source, id)`'den türetilir | API-31, API-10 |
| OQ-8 | Mobil SDK kendi cihazını hangi yetkiyle kaydeder? | Ayrı dar `devices:write` abone jetonu kapsamı | API-46, IN-41, IN-43, TN-25, X-31 |
| OQ-9 | Sunucu API'sine OAuth2 ya da Access jetonuyla erişilebilir mi? | Üç yol birlikte: API anahtarı, OAuth2 client credentials, Access servis jetonu; mTLS her biriyle ek katman | API-48, API-70 (yeni), API-71 (yeni), E-25 |
| OQ-10 | Self-host'ta iç ağ webhook hedefleri açılabilir mi? | Yalnız kurulum operatörünün izin listesiyle, denetim kayıtlı; kiracı açamaz | WH-44 |
| OQ-11 | `retention: none` mesaj inbox'a yazılabilir mi? | Hayır; birleşim reddedilir | IN-46, API-26, TP-40, DS-45 |
| OQ-12 | CIBA ping bildirimi Relay webhook'uyla mı taşınır? | Hayır; Access'te kalır, Relay yalnız daveti taşır | E-15 |
| OQ-13 | Access kullanıcısı ile Relay abonesi hangi kimlikle eşlenir? | Token exchange'de Access'in kiracıya özgü `sub`'ı; `external_id` bu değerdir | IN-41, C-20, E-24, §5.13 |
| OQ-14 | VAPID anahtarı kiracı başına mı, uygulama başına mı? | Kanal kimliği (uygulama) başına | TN-31, CH-26, C-26 |
| OQ-15 | İçerik taşımayan push varsayılan mı? | TR bölgesi ve "yalnız yurt içi" kiracılarda, her bölgede `security` ve `sensitive` şablonlarda varsayılan açık; diğerlerinde seçenek; içerik çekilemezse genel metin; SDK desteği hazır | CH-33, X-31 |
| OQ-16 | `security` sınıfı kota tükendiğinde reddedilir mi? | Sınırlı ek pay (PD %10), anında uyarı, ek pay bitince red; hedef korumaları önce; sınıf başına kota payı | TN-52, API-51 |
| OQ-17 | Yedi sınıf dört şeride nasıl eşlenir? | L0 `security`; L1 `transactional` + `action_required`; L2 `operational` + `system` + `social`; L3 `marketing` | T-31 |
| OQ-18 | Kilitlenebilir kategori kümesi ve `action_required` varsayılan satırı | Yazıldığı gibi: kilit yalnız `transactional`/`operational`/`action_required`; `action_required` push, e-posta, in-app açık | PC-6, PC-14 |
| OQ-19 | Kullanıcı sessiz saati e-postaya uygulanır mı? | Varsayılan yalnız anında kesen kanallar; e-posta ve inbox hariç; kullanıcı e-postayı dahil edebilir | PC-45 |
| OQ-20 | Öncelik eşleme tablosunun hücre değerleri | Test cihazlarında ölçülerek kesinleşir (ENGINEERING ASSUMPTION) | CH-19 |
| OQ-21 | `stalled` bekleme noktası nasıl davranır? | Yazıldığı gibi: yanıt almaya devam eder; heartbeat dönünce eskalasyon kaldığı kademeden sürer | AG-10 |
| OQ-22 | Ajan olay adları, ölü mektup görünümü, MCP araç listesi, A2A eşlemesi | Yazıldığı gibi | AG-16, AG-22, AG-43, AG-46, AG-49 |
| OQ-23 | Gönderim modu tanımları ve CLI onayı | Yazıldığı gibi | X-15, X-33, X-35, API-62, OP-51 |
| OQ-24 | Ses ve WhatsApp teslim raporu pencereleri | POLICY DEFAULT; sağlayıcı ölçümüyle kesinleşir | DS-19 |
| OQ-25 | Giden webhook'ta 3xx yeniden denenmez mi? | Yeniden denenmez | WH-23 |
| OQ-26 | Inbox jeton ömrü, delta tavanı, nesne deposu dosya adı | Yazıldığı gibi (15 dk ve 500 PD) | IN-42, IN-29, WH-21 |
| OQ-27 | Değeri verilmemiş POLICY DEFAULT'lar | Değer, bağlı özellik yapım sırasına girerken ölçüm ya da plan kararıyla konur; değer konmadan özellik yayımlanmaz | F-28 |

**OQ-27 kapsamındaki değersiz PD'ler** (F-28 gereği her biri bağlı özellik yapım sırasına girerken konur): webhook tüketicisi başına uç sayısı (WH-16); nesne deposu parti eşikleri (WH-21); webhook yük boyutu sert sınırı (WH-29); webhook teslim günlüğü saklaması (WH-30); kiracı askıya alma hukuki süreleri (TN-10); takedown ve trafik/erişim logu saklama süreleri (TN-60; 5651, DSA); RPO/RTO (OP-27); mesaj sınıfı başına SLO değerleri (OP-36, DS-42); sağlayıcı mutabakat sıklığı (DS-22); ajan başına tavan (AG-51); lease süresi ve yeniden teslim sayısı (AG-22); kaynak sınırları sayfası değerleri (AG-53); API hız limiti değerleri ve uç ağırlıkları (API-50).

### 22.4 Karar register'ı

Bu bölüm karar üretmez. Kapanan her OQ, kararın yazıldığı bölümün ID'sine §22.3'te bağlanır.
