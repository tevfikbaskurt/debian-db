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
    if [[ ! -r /etc/debian_version ]]; then
        fail "Bu kurulum adımı Debian içindir."
    fi

    apt-get update
    apt-get install -y docker.io
    systemctl enable --now docker
    log "Docker kuruldu ve başlatıldı."
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

resolve_master_name() {
    local base_name="$MASTER_NAME"
    local base_volume="$MASTER_VOLUME"
    local suffix=1

    while docker container inspect "$MASTER_NAME" >/dev/null 2>&1 ||
          docker volume inspect "$MASTER_VOLUME" >/dev/null 2>&1 ||
          [[ "$MASTER_NAME" == "$STANDBY_NAME" ]] ||
          [[ "$MASTER_VOLUME" == "$STANDBY_VOLUME" ]]; do
        suffix=$((suffix + 1))
        MASTER_NAME="${base_name}-${suffix}"
        MASTER_VOLUME="${base_volume}-${suffix}"
    done

    if [[ "$MASTER_NAME" != "$base_name" ]]; then
        log "Birincil adı kullanımda; alternatif ad seçildi: $MASTER_NAME"
    fi
}

setup_cluster() {
    local pgpass_password
    require_root
    command -v docker >/dev/null 2>&1 || fail "Docker bulunamadı. Önce: sudo $0 install-docker"
    docker info >/dev/null 2>&1 || fail "Docker servisine erişilemiyor. sudo systemctl start docker komutunu çalıştırın."

    resolve_master_name

    if docker container inspect "$STANDBY_NAME" >/dev/null 2>&1; then
        fail "Yedek düğüm adı zaten kullanımda: $STANDBY_NAME. Mevcut kaynağı inceleyin."
    fi
    if docker volume inspect "$STANDBY_VOLUME" >/dev/null 2>&1; then
        fail "Yedek veri birimi adı zaten kullanımda: $STANDBY_VOLUME. Mevcut veriyi inceleyin."
    fi

    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        fail "Ağ adı zaten kullanımda: $NETWORK_NAME. Mevcut ağı inceleyin; sıfırlamak için: sudo $0 cleanup"
    fi
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
    log "Kurulum tamamlandı. Birincil: localhost:$MASTER_PORT; yedek (salt okunur): localhost:$STANDBY_PORT"
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
Kullanım: sudo $0 {install-docker|setup|status|cleanup}

  install-docker  Debian'ın docker.io paketini kurar ve servisi başlatır.
  setup           pg-01/pg-02 PostgreSQL 16 replikasyon laboratuvarını kurar.
  status          Düğüm ve replikasyon durumunu gösterir.
  cleanup         Laboratuvar konteynerlerini, ağını ve veri birimlerini siler.

Parolalar, portlar ve veri birimleri ortam değişkenleriyle değiştirilebilir:
  MASTER_PASSWORD, REPLICATION_PASSWORD, MASTER_PORT, STANDBY_PORT
  MASTER_VOLUME, STANDBY_VOLUME
EOF
}

case "${1:-}" in
    install-docker) install_docker ;;
    setup) setup_cluster ;;
    status) show_status ;;
    cleanup) cleanup_cluster ;;
    *) usage; exit 2 ;;
esac
