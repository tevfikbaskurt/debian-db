# Debian/Ubuntu üzerinde PostgreSQL 16 fiziksel replikasyon laboratuvarı

Bu laboratuvar, `Laboratuvar_Uygulaması.txt` içindeki başlangıç parametrelerini kullanarak Docker üzerinde iki PostgreSQL düğümü kurar:

| Rol | Düğüm adı | Host portu | Kullanım |
|---|---|---:|---|
| Birincil (master) | `pg-01` | `5433` | Veri yazma ve okuma |
| Yedek (standby) | `pg-02` | `5434` | Replikasyon üzerinden salt okunur sorgular |

Docker ağı `bulut-net` adını taşır. Birincil düğümde `cihazlar` tablosu oluşturulur ve `Bulut Sunucu 01` başlangıç kaydı eklenir. `pg-02`, PostgreSQL fiziksel streaming replication ile birincilin kopyasını tutar.

> Kaynak TXT'nin ilk bölümündeki düğüm/ağ/parola parametreleri esas alınmıştır: `Master_001!` ve `Replikasyon_01!`. Dosyanın devamındaki farklı örnek isimler ve parolalar kullanılmaz. Bu parolalar laboratuvar içindir; gerçek veya internete açık sistemlerde değiştirin.

## Gereksinimler

- Debian veya Ubuntu makinesi ve `sudo` yetkisi
- İnternet erişimi (Docker paketi ve `postgres:16` imajını indirmek için)
- DBeaver, aynı makinede veya Debian sunucusuna erişebilen bir istemcide

Kurulum, Debian/Ubuntu'nun `docker.io` paketini kullanır. Betik sistem değişikliği ve Docker yönetimi yaptığı için `sudo` ile çalıştırılmalıdır.

## Kurulum ve kontrol

```bash
chmod +x debian-postgresql-replication.sh
sudo ./debian-postgresql-replication.sh install
sudo ./debian-postgresql-replication.sh status
```

`install`, Docker kurulu değilse kurar, servisi başlatır ve ağ adı, düğüm adları, portlar ve parolaları etkileşimli olarak sorar. Her soruda Enter varsayılanı kabul eder. Varsayılanlar kaynak TXT ile aynıdır: `bulut-net`, `pg-01`, `pg-02`, `5433`, `5434`, `Master_001!` ve `Replikasyon_01!`. Kurulum bitince DBeaver için Host, port, veritabanı, kullanıcı ve parolayı ekrana yazar.

Kurulum, `replicator` rolünü oluşturur, replikasyon erişimini açar, yedek düğüme ilk kopyayı alır ve örnek tablo/veriyi ekler. Her iki düğümün verisi Docker volume içinde tutulur; son adımda yedek üzerinden tabloyu sorgulayarak replikasyonu doğrular.

Replikasyon parolası SQL'e `psql` değişkeni ve betik girdisi üzerinden verilir; böylece `!` gibi karakterler shell tarafından yorumlanmaz. Mevcut `pg-01`, `pg-02`, ağ veya veri birimi adı çakışırsa kaynaklar silinmez. Betik boş alternatif ad önerir (`pg-01-2`, `pg-02-2`, `bulut-net-2` gibi) ve etkileşimli kurulumda alternatif ad girmenize izin verir. Varsayılan portlardan biri doluysa kullanılabilir port önerir. Seçilen değerler kurulum sonunda yazdırılır.

Örnek bağlantı bilgileri:

| DBeaver alanı | Birincil (yazma/okuma) | Yedek (salt okunur) |
|---|---|---|
| Host | Sunucunun erişilebilir IP/DNS adı (`localhost` aynı makinede) | Sunucunun erişilebilir IP/DNS adı (`localhost` aynı makinede) |
| Port | `5433` (kurulumda değişebilir) | `5434` (kurulumda değişebilir) |
| Database | `postgres` | `postgres` |
| Username | `postgres` | `postgres` |
| Password | `Master_001!` (kurulumda değişebilir) | `Master_001!` (kurulumda değişebilir) |

Kurulum sırasında farklı ad, port veya parola seçtiyseniz ekranda yazdırılan değerleri kullanın. Uzak DBeaver bağlantısı için sunucunun güvenlik duvarında seçilen PostgreSQL portlarına yalnızca güvenilir istemcilerden erişime izin verin.

Önce kurulum sonunda yazdırılan birincil düğüm bağlantısında SQL Editor açın:

```sql
SELECT id, isim FROM cihazlar ORDER BY id;

INSERT INTO cihazlar (isim) VALUES ('Hatalı Giriş');
INSERT INTO cihazlar (isim) VALUES ('Bulut Sunucu 02');
```

Bu iki INSERT'i birincilde çalıştırdıktan sonra yedek düğüm bağlantısında sorguyu çalıştırın:

```sql
SELECT id, isim FROM cihazlar ORDER BY id;
```

Yedek düğümde birincildeki kayıtların görünmesi replikasyonun çalıştığını gösterir. Kaynaktaki `Hatalı Giriş` sadece örnek bir kayıt adıdır; birincilde çalıştırıldığında replike edilir. PostgreSQL standby düğümü salt okunurdur; INSERT/UPDATE/DELETE işlemlerini birincilde yapın.

> Portlar Docker tarafından host arayüzlerine yayımlanır. Debian sunucusuna başka makinelerden bağlanacaksanız güvenlik duvarında yalnızca güvenilir istemci adreslerine izin verin; laboratuvar parolalarını üretim ortamında kullanmayın.

## Faydalı komutlar

```bash
# Replikasyon bağlantısı ve standby salt-okunurluk durumu
sudo ./debian-postgresql-replication.sh status

# Konteyner günlükleri; adlar farklı seçildiyse `pg-01`/`pg-02` yerine yazdırılanları kullanın
sudo docker logs pg-01
sudo docker logs pg-02

# Laboratuvarı tamamen kaldırır; iki düğümün veri birimlerini de siler
sudo ./debian-postgresql-replication.sh cleanup
```

`cleanup` devam etmeden önce açık onay ister. İki düğümün veri birimleri geri alınamaz şekilde silinir; korunması gereken veri varsa bu komutu kullanmayın. Ağ adı varsayılandan farklı seçildiyse kurulum sonunda yazdırılan `sudo env NETWORK_NAME='seçilen-ağ' ...` komutlarını kullanın.

## Güvenli kullanım notları

- Replikasyon rolü için ayrı parola kullanılır; `postgres` hesabı replikasyon için kullanılmaz.
- Replikasyon için `pg_hba.conf` kuralı Docker ağı üzerinden gelen istemcilere izin verecek şekilde eklenir. Host portları da dışarıya açıldığından host güvenlik duvarını uygun şekilde kısıtlayın.
- Bu kurulum tek yönlü fiziksel replikasyondur; otomatik failover, yedekten geri yükleme planı veya yüksek erişilebilirlik çözümü değildir.
