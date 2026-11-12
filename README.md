# Debian üzerinde PostgreSQL 16 fiziksel replikasyon laboratuvarı

Bu laboratuvar, `Laboratuvar_Uygulaması.txt` içindeki başlangıç parametrelerini kullanarak Docker üzerinde iki PostgreSQL düğümü kurar:

| Rol | Düğüm adı | Host portu | Kullanım |
|---|---|---:|---|
| Birincil (master) | `pg-01` | `5433` | Veri yazma ve okuma |
| Yedek (standby) | `pg-02` | `5434` | Replikasyon üzerinden salt okunur sorgular |

Docker ağı `bulut-net` adını taşır. Birincil düğümde `cihazlar` tablosu oluşturulur ve `Bulut Sunucu 01` başlangıç kaydı eklenir. `pg-02`, PostgreSQL fiziksel streaming replication ile birincilin kopyasını tutar.

> Kaynak TXT'nin ilk bölümündeki düğüm/ağ/parola parametreleri esas alınmıştır: `Master_001!` ve `Replikasyon_01!`. Dosyanın devamındaki farklı örnek isimler ve parolalar kullanılmaz. Bu parolalar laboratuvar içindir; gerçek veya internete açık sistemlerde değiştirin.

## Gereksinimler

- Debian makinesi ve `sudo` yetkisi
- İnternet erişimi (Docker paketi ve `postgres:16` imajını indirmek için)
- DBeaver, aynı makinede veya Debian sunucusuna erişebilen bir istemcide

Kurulum, Debian'ın `docker.io` paketini kullanır. Betik sistem değişikliği ve Docker yönetimi yaptığı için `sudo` ile çalıştırılmalıdır.

## Kurulum ve kontrol

```bash
chmod +x debian-postgresql-replication.sh
sudo ./debian-postgresql-replication.sh install-docker
sudo ./debian-postgresql-replication.sh setup
sudo ./debian-postgresql-replication.sh status
```

`setup`, düğümleri başlatır, `replicator` rolünü oluşturur, replikasyon erişimini açar, yedek düğüme başlangıç kopyasını alır ve örnek tablo/veriyi ekler. Her iki düğümün verisi de Docker volume içinde tutulur. Son adımda yedek düğümden tabloyu sorgulayarak kurulumu doğrular.

Docker'da `pg-01` adı veya buna ait veri birimi zaten varsa betik birincil düğüm için `pg-01-2`, sonraki çakışmalarda `pg-01-3` gibi boş bir ad ve ona karşılık gelen veri birimini seçer. `status` ve `cleanup` bu alternatifi Docker etiketlerinden bulur. `pg-02` ya da `bulut-net` adı kullanımda ise kurulum güvenli şekilde durur. Container adının otomatik değişmesi host portlarını değiştirmez; `5433`/`5434` portları doluysa kurulumdan önce ortam değişkenleriyle boş port verin.

Script varsayılan değerleri kullanır; port veya parola değişikliği ortam değişkenleriyle yapılabilir:

```bash
sudo MASTER_PORT=5433 STANDBY_PORT=5434 \
  MASTER_PASSWORD='Master_001!' REPLICATION_PASSWORD='Replikasyon_01!' \
  ./debian-postgresql-replication.sh setup
```

Birincil adı çakışırsa betik alternatif ad seçer; yedek adı veya ağ adı çakışırsa `setup` güvenlik amacıyla durur. Mevcut konteynerleri veya verileri incelemeden temizleme çalıştırmayın.

## DBeaver bağlantıları

Her düğüm için ayrı PostgreSQL bağlantısı oluşturun:

| DBeaver alanı | Birincil bağlantı | Yedek bağlantı |
|---|---|---|
| Host | Debian sunucusunun adresi (`localhost` aynı makinede) | Debian sunucusunun adresi (`localhost` aynı makinede) |
| Port | `5433` | `5434` |
| Database | `postgres` | `postgres` |
| Username | `postgres` | `postgres` |
| Password | `Master_001!` | `Master_001!` |

Önce `pg-01` bağlantısında SQL Editor açın:

```sql
SELECT id, isim FROM cihazlar ORDER BY id;

INSERT INTO cihazlar (isim) VALUES ('Hatalı Giriş');
INSERT INTO cihazlar (isim) VALUES ('Bulut Sunucu 02');
```

Bu iki INSERT'i birincilde çalıştırdıktan sonra `pg-02` bağlantısında sorguyu çalıştırın:

```sql
SELECT id, isim FROM cihazlar ORDER BY id;
```

Yedek düğümde birincildeki kayıtların görünmesi replikasyonun çalıştığını gösterir. Kaynaktaki `Hatalı Giriş` sadece örnek bir kayıt adıdır; birincilde çalıştırıldığında hata vermez ve replike edilir. PostgreSQL standby düğümü salt okunurdur; INSERT/UPDATE/DELETE işlemlerini `pg-01` üzerinde yapın. Standby'da ayrıca INSERT deneyerek salt-okunurluğu kontrol edebilirsiniz; yazma reddedilmelidir.

> Portlar Docker tarafından host arayüzlerine yayımlanır. Debian sunucusuna başka makinelerden bağlanacaksanız güvenlik duvarında yalnızca güvenilir istemci adreslerine izin verin; laboratuvar parolalarını üretim ortamında kullanmayın.

## Faydalı komutlar

```bash
# Replikasyon bağlantısı ve standby salt-okunurluk durumu
sudo ./debian-postgresql-replication.sh status

# Konteyner günlükleri (alternatif birincil adı seçildiyse `status` çıktısındaki adı kullanın)
sudo docker logs pg-01
sudo docker logs pg-02

# Laboratuvarı tamamen kaldırır; iki düğümün veri birimlerini de siler
sudo ./debian-postgresql-replication.sh cleanup
```

`cleanup` devam etmeden önce açık onay ister. İki düğümün veri birimleri geri alınamaz şekilde silinir; korunması gereken veri varsa bu komutu kullanmayın.

## Güvenli kullanım notları

- Replikasyon rolü için ayrı parola kullanılır; `postgres` hesabı replikasyon için kullanılmaz.
- Replikasyon için `pg_hba.conf` kuralı Docker ağı üzerinden gelen istemcilere izin verecek şekilde eklenir. Host portları da dışarıya açıldığından host güvenlik duvarını uygun şekilde kısıtlayın.
- Bu kurulum tek yönlü fiziksel replikasyondur; otomatik failover, yedekten geri yükleme planı veya yüksek erişilebilirlik çözümü değildir.
