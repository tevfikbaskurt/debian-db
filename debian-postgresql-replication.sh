#!/usr/bin/env bash
set -Eeuo pipefail

NETWORK_NAME="${NETWORK_NAME:-bulut-net}"
MASTER_NAME="${MASTER_NAME:-pg-01}"
STANDBY_NAME="${STANDBY_NAME:-pg-02}"
MASTER_PORT="${MASTER_PORT:-5433}"
STANDBY_PORT="${STANDBY_PORT:-5434}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16}"
LAB_LABEL="debian-db.lab"
MASTER_PASSWORD="${MASTER_PASSWORD:-Master_001!}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-Replikasyon_01!}"
MASTER_VOLUME="${MASTER_VOLUME:-pg-01-data}"
STANDBY_VOLUME="${STANDBY_VOLUME:-pg-02-data}"
INTERACTIVE_INSTALL=0

log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
    printf 'HATA: %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fail "Bu betiği root olarak çalıştırın: sudo $0 $*"
    fi
}

install_docker() {
    require_root "$@"
    if [[ ! -r /etc/os-release ]]; then
        fail "Desteklenen işletim sistemi Debian veya Ubuntu olmalıdır."
    fi
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ;;
        *) fail "Desteklenen işletim sistemi Debian veya Ubuntu olmalıdır (bulunan: ${ID:-bilinmiyor})." ;;
    esac

    apt-get update
    apt-get install -y docker.io
    systemctl enable --now docker
    log "Docker kuruldu ve başlatıldı."
}

prompt_value() {
    local prompt="$1"
    local default="$2"
    local answer
    read -r -p "$prompt [$default]: " answer
    printf '%s' "${answer:-$default}"
}

valid_docker_name() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]
}

node_pair_available() {
    local name="$1"
    local volume="$2"
    local other_name="$3"
    local other_volume="$4"

    [[ "$name" != "$other_name" && "$volume" != "$other_volume" ]] &&
        ! docker container inspect "$name" >/dev/null 2>&1 &&
        ! docker volume inspect "$volume" >/dev/null 2>&1
}

resolve_node_names() {
    local base_name base_volume candidate candidate_volume suffix entered

    base_name="$MASTER_NAME"
    base_volume="$MASTER_VOLUME"
    if ! node_pair_available "$MASTER_NAME" "$MASTER_VOLUME" "$STANDBY_NAME" "$STANDBY_VOLUME"; then
        suffix=2
        candidate="${base_name}-${suffix}"
        candidate_volume="${base_volume}-${suffix}"
        while ! node_pair_available "$candidate" "$candidate_volume" "$STANDBY_NAME" "$STANDBY_VOLUME"; do
            suffix=$((suffix + 1))
            candidate="${base_name}-${suffix}"
            candidate_volume="${base_volume}-${suffix}"
        done
        if ((INTERACTIVE_INSTALL)); then
            entered="$(prompt_value "Birincil adı çakışıyor. Alternatif birincil düğüm adı" "$candidate")"
            valid_docker_name "$entered" || fail "Geçersiz Docker düğüm adı: $entered"
            candidate="$entered"
            candidate_volume="${candidate}-data"
            node_pair_available "$candidate" "$candidate_volume" "$STANDBY_NAME" "$STANDBY_VOLUME" ||
                fail "Seçilen alternatif düğüm adı veya veri birimi kullanımda: $candidate / $candidate_volume"
        fi
        MASTER_NAME="$candidate"
        MASTER_VOLUME="$candidate_volume"
        log "Mevcut kaynaklar korunuyor; yeni birincil adı: $MASTER_NAME"
    fi

    base_name="$STANDBY_NAME"
    base_volume="$STANDBY_VOLUME"
    if ! node_pair_available "$STANDBY_NAME" "$STANDBY_VOLUME" "$MASTER_NAME" "$MASTER_VOLUME"; then
        suffix=2
        candidate="${base_name}-${suffix}"
        candidate_volume="${base_volume}-${suffix}"
        while ! node_pair_available "$candidate" "$candidate_volume" "$MASTER_NAME" "$MASTER_VOLUME"; do
            suffix=$((suffix + 1))
            candidate="${base_name}-${suffix}"
            candidate_volume="${base_volume}-${suffix}"
        done
        if ((INTERACTIVE_INSTALL)); then
            entered="$(prompt_value "Yedek adı çakışıyor. Alternatif yedek düğüm adı" "$candidate")"
            valid_docker_name "$entered" || fail "Geçersiz Docker düğüm adı: $entered"
            candidate="$entered"
            candidate_volume="${candidate}-data"
            node_pair_available "$candidate" "$candidate_volume" "$MASTER_NAME" "$MASTER_VOLUME" ||
                fail "Seçilen alternatif düğüm adı veya veri birimi kullanımda: $candidate / $candidate_volume"
        fi
        STANDBY_NAME="$candidate"
        STANDBY_VOLUME="$candidate_volume"
        log "Mevcut kaynaklar korunuyor; yeni yedek adı: $STANDBY_NAME"
    fi
}

resolve_network_name() {
    local base_name="$NETWORK_NAME"
    local candidate
    local suffix=2

    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        candidate="${base_name}-${suffix}"
        while docker network inspect "$candidate" >/dev/null 2>&1; do
            suffix=$((suffix + 1))
            candidate="${base_name}-${suffix}"
        done
        if ((INTERACTIVE_INSTALL)); then
            candidate="$(prompt_value "Ağ adı kullanımda. Yeni laboratuvar ağı" "$candidate")"
            valid_docker_name "$candidate" || fail "Geçersiz Docker ağ adı: $candidate"
            docker network inspect "$candidate" >/dev/null 2>&1 &&
                fail "Seçilen Docker ağı zaten kullanımda: $candidate"
        fi
        NETWORK_NAME="$candidate"
        log "Mevcut ağ korunuyor; yeni laboratuvar ağı: $NETWORK_NAME"
    fi
}

port_is_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :$port" | grep -q .; then
        return 0
    fi
    docker ps -a --format '{{.Ports}}' |
        grep -Eq "(^|[,:])${port}->"
}

resolve_ports() {
    local label="$1"
    local current="$2"
    local other="$3"
    local candidate="$current"
    local entered

    if [[ ! "$candidate" =~ ^[0-9]+$ ]]; then
        fail "$label geçerli bir TCP portu değil: $candidate"
    fi
    candidate=$((10#$candidate))
    if ((candidate < 1 || candidate > 65535)); then
        fail "$label geçerli bir TCP portu değil: $candidate"
    fi
    if port_is_in_use "$candidate" || [[ "$candidate" == "$other" ]]; then
        if ((INTERACTIVE_INSTALL)); then
            candidate=$((candidate + 1))
            while ((candidate <= 65535)) && { port_is_in_use "$candidate" || [[ "$candidate" == "$other" ]]; }; do
                candidate=$((candidate + 1))
            done
            ((candidate <= 65535)) || fail "Kullanılabilir port bulunamadı."
            entered="$(prompt_value "$label kullanımda. Alternatif host portu" "$candidate")"
            [[ "$entered" =~ ^[0-9]+$ ]] || fail "Geçersiz TCP portu: $entered"
            entered=$((10#$entered))
            ((entered >= 1 && entered <= 65535)) ||
                fail "Geçersiz TCP portu: $entered"
            if port_is_in_use "$entered" || [[ "$entered" == "$other" ]]; then
                fail "Seçilen TCP portu kullanımda veya diğer düğümle aynı: $entered"
            fi
            candidate="$entered"
        else
            fail "$label portu kullanımda veya diğer düğümle aynı: $candidate. Boş port seçin."
        fi
    fi
    printf '%s' "$candidate"
}

wait_for_postgres() {
    local container="$1"
    local attempt
    for attempt in $(seq 1 60); do
        if docker exec "$container" pg_isready -U postgres >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    fail "$container 120 saniye içinde hazır olmadı. docker logs $container çıktısını inceleyin."
}

resolve_existing_lab_name() {
    local role="$1"
    local name
    name="$(docker ps -a \
        --filter "label=${LAB_LABEL}=${NETWORK_NAME}" \
        --filter "label=debian-db.role=${role}" \
        --format '{{.Names}}')"
    if [[ -n "$name" ]]; then
        printf '%s' "${name%%$'\n'*}"
    fi
}

setup_cluster() {
    local pgpass_password
    require_root
    command -v docker >/dev/null 2>&1 || fail "Docker bulunamadı. Önce: sudo $0 install-docker"
    docker info >/dev/null 2>&1 || fail "Docker servisine erişilemiyor. sudo systemctl start docker komutunu çalıştırın."

    valid_docker_name "$NETWORK_NAME" || fail "Geçersiz Docker ağ adı: $NETWORK_NAME"
    valid_docker_name "$MASTER_NAME" || fail "Geçersiz birincil düğüm adı: $MASTER_NAME"
    valid_docker_name "$STANDBY_NAME" || fail "Geçersiz yedek düğüm adı: $STANDBY_NAME"
    resolve_node_names
    resolve_network_name
    MASTER_PORT="$(resolve_ports "Birincil portu" "$MASTER_PORT" "")"
    STANDBY_PORT="$(resolve_ports "Yedek portu" "$STANDBY_PORT" "$MASTER_PORT")"
    docker network create --label "${LAB_LABEL}=${NETWORK_NAME}" "$NETWORK_NAME" >/dev/null

    docker volume create --label "${LAB_LABEL}=${NETWORK_NAME}" \
        --label debian-db.role=master "$MASTER_VOLUME" >/dev/null
    log "$MASTER_NAME birincil düğümü başlatılıyor."
    docker run -d \
        --name "$MASTER_NAME" \
        --label "${LAB_LABEL}=${NETWORK_NAME}" \
        --label debian-db.role=master \
        --network "$NETWORK_NAME" \
        -p "${MASTER_PORT}:5432" \
        -v "${MASTER_VOLUME}:/var/lib/postgresql/data" \
        -e "POSTGRES_PASSWORD=$MASTER_PASSWORD" \
        "$POSTGRES_IMAGE" \
        -c wal_level=replica \
        -c max_wal_senders=5 \
        -c max_replication_slots=5 >/dev/null
    wait_for_postgres "$MASTER_NAME"

    log "Replikasyon rolü ve erişim kuralı hazırlanıyor."
    if docker exec "$MASTER_NAME" psql -U postgres -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname = 'replicator'" | grep -q 1; then
        docker exec -i "$MASTER_NAME" psql -U postgres -v ON_ERROR_STOP=1 \
            -v "replication_password=$REPLICATION_PASSWORD" >/dev/null <<'SQL'
ALTER ROLE replicator WITH REPLICATION LOGIN PASSWORD :'replication_password';
SQL
    else
        docker exec -i "$MASTER_NAME" psql -U postgres -v ON_ERROR_STOP=1 \
            -v "replication_password=$REPLICATION_PASSWORD" >/dev/null <<'SQL'
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD :'replication_password';
SQL
    fi

    docker exec "$MASTER_NAME" sh -c \
        "grep -qxF 'host replication replicator 0.0.0.0/0 scram-sha-256' \"\$PGDATA/pg_hba.conf\" ||
         printf '%s\\n' 'host replication replicator 0.0.0.0/0 scram-sha-256' >> \"\$PGDATA/pg_hba.conf\""
    docker exec "$MASTER_NAME" psql -U postgres -v ON_ERROR_STOP=1 \
        -c "SELECT pg_reload_conf();" >/dev/null

    docker volume create --label "${LAB_LABEL}=${NETWORK_NAME}" \
        --label debian-db.role=standby "$STANDBY_VOLUME" >/dev/null
    log "$STANDBY_NAME için ilk veri kopyası alınıyor."
    docker run --rm \
        --network "$NETWORK_NAME" \
        -e "PGPASSWORD=$REPLICATION_PASSWORD" \
        -v "${STANDBY_VOLUME}:/var/lib/postgresql/data" \
        "$POSTGRES_IMAGE" \
        pg_basebackup \
        -h "$MASTER_NAME" \
        -U replicator \
        -D /var/lib/postgresql/data \
        -Fp -Xs -P -R \
        -d "host=$MASTER_NAME user=replicator"

    pgpass_password="${REPLICATION_PASSWORD//\\/\\\\}"
    pgpass_password="${pgpass_password//:/\\:}"
    docker run --rm \
        --user root \
        -e "MASTER_NAME=$MASTER_NAME" \
        -e "PGPASS_PASSWORD=$pgpass_password" \
        -v "${STANDBY_VOLUME}:/var/lib/postgresql/data" \
        --entrypoint sh \
        "$POSTGRES_IMAGE" \
        -c 'umask 077
            printf "%s:5432:replication:replicator:%s\n" "$MASTER_NAME" "$PGPASS_PASSWORD" > /var/lib/postgresql/data/.pgpass
            chown postgres:postgres /var/lib/postgresql/data/.pgpass
            chmod 600 /var/lib/postgresql/data/.pgpass
            sed -i "/^[[:space:]]*primary_conninfo[[:space:]]*=/d" /var/lib/postgresql/data/postgresql.auto.conf
            printf "primary_conninfo = '\''host=%s user=replicator passfile=/var/lib/postgresql/data/.pgpass'\''\n" "$MASTER_NAME" >> /var/lib/postgresql/data/postgresql.auto.conf'

    log "$STANDBY_NAME yedek düğümü başlatılıyor."
    docker run -d \
        --name "$STANDBY_NAME" \
        --label "${LAB_LABEL}=${NETWORK_NAME}" \
        --label debian-db.role=standby \
        --network "$NETWORK_NAME" \
        -p "${STANDBY_PORT}:5432" \
        -v "${STANDBY_VOLUME}:/var/lib/postgresql/data" \
        "$POSTGRES_IMAGE" >/dev/null
    wait_for_postgres "$STANDBY_NAME"

    log "Örnek tablo ve başlangıç verisi birincil düğümde hazırlanıyor."
    docker exec "$MASTER_NAME" psql -U postgres -v ON_ERROR_STOP=1 -c \
        "CREATE TABLE IF NOT EXISTS cihazlar (id SERIAL PRIMARY KEY, isim VARCHAR(50));"
    docker exec "$MASTER_NAME" psql -U postgres -v ON_ERROR_STOP=1 -c \
        "INSERT INTO cihazlar (isim)
         SELECT 'Bulut Sunucu 01'
         WHERE NOT EXISTS (SELECT 1 FROM cihazlar WHERE isim = 'Bulut Sunucu 01');"

    log "Replikasyon ve örnek kaydın yedeğe ulaşması doğrulanıyor."
    local attempt
    for attempt in $(seq 1 30); do
        if [[ "$(docker exec "$STANDBY_NAME" psql -U postgres -tAc \
            "SELECT count(*) FROM cihazlar WHERE isim = 'Bulut Sunucu 01';" \
            2>/dev/null | tr -d '[:space:]')" == "1" ]] &&
           [[ "$(docker exec "$STANDBY_NAME" psql -U postgres -tAc \
            'SELECT pg_is_in_recovery();' 2>/dev/null | tr -d '[:space:]')" == "t" ]]; then
            break
        fi
        if [[ "$attempt" -eq 30 ]]; then
            fail "$STANDBY_NAME replikasyonu veya başlangıç kaydı doğrulanamadı. docker logs $STANDBY_NAME çıktısını inceleyin."
        fi
        sleep 2
    done

    docker exec "$STANDBY_NAME" psql -U postgres -v ON_ERROR_STOP=1 -c \
        "SELECT id, isim FROM cihazlar ORDER BY id;"
    log "Kurulum tamamlandı."
    show_connection_details
}

show_connection_details() {
    local host_address
    host_address="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$host_address" ]] || host_address="Sunucunun erişilebilir IP adresi"

    cat <<EOF

DBeaver bağlantı bilgileri
--------------------------
Host:       $host_address (uzak istemcide erişilebilir IP/DNS; aynı makinede localhost)
Veritabanı: postgres
Kullanıcı:  postgres
Parola:     $MASTER_PASSWORD

Birincil (yazma/okuma):
  Düğüm: $MASTER_NAME
  Port:  $MASTER_PORT

Yedek (salt okunur):
  Düğüm: $STANDBY_NAME
  Port:  $STANDBY_PORT

Replikasyon kullanıcısı: replicator
Replikasyon parolası:    $REPLICATION_PASSWORD

EOF
    if [[ "$NETWORK_NAME" != "bulut-net" ]]; then
        printf "Durum kontrolü:\n  sudo env NETWORK_NAME='%s' '%s' status\n" "$NETWORK_NAME" "$0"
        printf "Temizleme (verileri siler):\n  sudo env NETWORK_NAME='%s' '%s' cleanup\n" "$NETWORK_NAME" "$0"
    else
        printf "Durum kontrolü:\n  sudo '%s' status\n" "$0"
        printf "Temizleme (verileri siler):\n  sudo %s cleanup\n" "$0"
    fi
}

interactive_install() {
    local confirmation

    require_root
    [[ -t 0 ]] || fail "Etkileşimli kurulum terminal gerektirir. Terminalde sudo $0 install komutunu çalıştırın."

    NETWORK_NAME="$(prompt_value "Docker ağı adı" "$NETWORK_NAME")"
    MASTER_NAME="$(prompt_value "Birincil düğüm adı" "$MASTER_NAME")"
    STANDBY_NAME="$(prompt_value "Yedek düğüm adı" "$STANDBY_NAME")"
    MASTER_PORT="$(prompt_value "Birincil host portu" "$MASTER_PORT")"
    STANDBY_PORT="$(prompt_value "Yedek host portu" "$STANDBY_PORT")"
    MASTER_PASSWORD="$(prompt_value "PostgreSQL/DBeaver parolası" "$MASTER_PASSWORD")"
    REPLICATION_PASSWORD="$(prompt_value "Replikasyon parolası" "$REPLICATION_PASSWORD")"

    printf '\nKurulum özeti (Enter varsayılanları kabul eder):\n'
    printf '  Ağ: %s\n  Birincil: %s:%s\n  Yedek: %s:%s\n' \
        "$NETWORK_NAME" "$MASTER_NAME" "$MASTER_PORT" "$STANDBY_NAME" "$STANDBY_PORT"
    read -r -p 'Devam edilsin mi? [E/h]: ' confirmation
    [[ -z "$confirmation" || "$confirmation" =~ ^[EeYy]$ ]] ||
        fail "Kurulum kullanıcı tarafından iptal edildi."

    if ! command -v docker >/dev/null 2>&1; then
        install_docker
    elif ! docker info >/dev/null 2>&1; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable --now docker
        fi
        docker info >/dev/null 2>&1 || fail "Docker daemon başlatılamadı veya erişilemiyor."
    fi

    INTERACTIVE_INSTALL=1
    setup_cluster
}

show_status() {
    command -v docker >/dev/null 2>&1 || fail "Docker bulunamadı."
    local found_master
    local found_standby
    found_master="$(resolve_existing_lab_name master)"
    found_standby="$(resolve_existing_lab_name standby)"
    [[ -z "$found_master" ]] || MASTER_NAME="$found_master"
    [[ -z "$found_standby" ]] || STANDBY_NAME="$found_standby"
    docker ps --filter "name=^/${MASTER_NAME}$" --filter "name=^/${STANDBY_NAME}$" \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    if docker container inspect "$MASTER_NAME" >/dev/null 2>&1 &&
       docker container inspect "$STANDBY_NAME" >/dev/null 2>&1; then
        docker exec "$MASTER_NAME" psql -U postgres -c \
            "SELECT application_name, state, sync_state FROM pg_stat_replication;"
        docker exec "$STANDBY_NAME" psql -U postgres -c \
            "SELECT pg_is_in_recovery() AS standby_read_only;"
    fi
}

cleanup_cluster() {
    require_root
    local found_master
    local found_standby
    local network_label
    local -a lab_volumes
    found_master="$(resolve_existing_lab_name master)"
    found_standby="$(resolve_existing_lab_name standby)"
    [[ -z "$found_master" ]] || MASTER_NAME="$found_master"
    [[ -z "$found_standby" ]] || STANDBY_NAME="$found_standby"
    mapfile -t lab_volumes < <(docker volume ls -q --filter "label=${LAB_LABEL}=${NETWORK_NAME}")

    printf 'UYARI: %s ve %s konteynerleri, %s etiketli veri birimleri ve laboratuvar ağı silinecek.\n' \
        "$MASTER_NAME" "$STANDBY_NAME" "$NETWORK_NAME"
    read -r -p 'Devam etmek için "evet" yazın: ' confirmation
    [[ "$confirmation" == "evet" ]] || fail "Temizlik iptal edildi."

    if [[ -n "$found_master" ]]; then docker rm -f "$found_master" >/dev/null; fi
    if [[ -n "$found_standby" ]]; then docker rm -f "$found_standby" >/dev/null; fi
    if ((${#lab_volumes[@]})); then docker volume rm "${lab_volumes[@]}" >/dev/null; fi
    network_label="$(docker network inspect --format \
        "{{ index .Labels \"${LAB_LABEL}\" }}" "$NETWORK_NAME" 2>/dev/null || true)"
    if [[ "$network_label" == "$NETWORK_NAME" ]]; then
        docker network rm "$NETWORK_NAME" >/dev/null
    fi
    log "Belirtilen laboratuvar kaynakları kaldırıldı."
}

usage() {
    cat <<EOF
Kullanım: sudo $0 {install|install-docker|setup|status|cleanup}

  install         Docker'ı gerekirse kurar, sorularla ayarları alır ve iki düğümü kurar.
  install-docker  Debian/Ubuntu'nun docker.io paketini kurar ve servisi başlatır.
  setup           Varsayılan/ortam ayarlarıyla iki PostgreSQL düğümünü kurar.
  status          Düğüm ve replikasyon durumunu gösterir.
  cleanup         Laboratuvar konteynerlerini, ağını ve veri birimlerini siler.

Parolalar, portlar ve veri birimleri ortam değişkenleriyle değiştirilebilir:
  MASTER_PASSWORD, REPLICATION_PASSWORD, MASTER_PORT, STANDBY_PORT
  MASTER_VOLUME, STANDBY_VOLUME
EOF
}

case "${1:-}" in
    install) interactive_install ;;
    install-docker) install_docker ;;
    setup) setup_cluster ;;
    status) show_status ;;
    cleanup) cleanup_cluster ;;
    *) usage; exit 2 ;;
esac
