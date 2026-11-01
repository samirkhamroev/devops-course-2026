#!/usr/bin/env bash
set -uo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  [OK] $desc"
        ((PASS++))
    else
        echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"
        ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f 2>/dev/null || hostname), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
sshd_cfg="$(sudo sshd -T 2>/dev/null)"
check "Вход от имени root запрещён" "no" "$(echo "$sshd_cfg" | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no" "$(echo "$sshd_cfg" | awk '/^passwordauthentication/{print $2}')"
# TODO 1: проверьте, что значение параметра port отлично от 22
ssh_port="$(echo "$sshd_cfg" | awk '/^port/{print $2}')"
check "Значение параметра port отлично от 22" "true" "$([[ "$ssh_port" != "22" && -n "$ssh_port" ]] && echo "true" || echo "false")"
# TODO 2: проверьте, что значение параметра maxauthtries равно 3
check "Значение параметра maxauthtries равно 3" "3" "$(echo "$sshd_cfg" | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status 2>/dev/null | awk '/^Status:/{print $2}')"
# TODO 3: проверьте, что политика по умолчанию для входящего трафика равна deny
# источник данных: sudo ufw status verbose | grep Default
check "Политика по умолчанию для входящего трафика равна deny" "deny" "$(sudo ufw status verbose 2>/dev/null | grep -i 'Default:' | grep -o 'deny (incoming)' | awk '{print $1}')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "  %s (uid=%s)\n",$1,$3}' /etc/passwd

# [4] Веб-сервер (из ПР № 6)
if command -v nginx >/dev/null 2>&1; then
    echo "[4] Веб-сервер"
    check "Служба nginx активна" "active" "$(systemctl is-active nginx 2>/dev/null || echo 'inactive')"
    
    nginx_test="fail"
    if sudo nginx -t >/dev/null 2>&1; then nginx_test="ok"; fi
    check "Конфигурация nginx синтаксически корректна" "ok" "$nginx_test"

    cert_valid="no"
    if openssl x509 -checkend 2592000 -noout -in /etc/ssl/certs/devops.crt >/dev/null 2>&1; then cert_valid="yes"; fi
    check "Сертификат devops.crt истекает не ранее чем через 30 дней" "yes" "$cert_valid"

    world_writable="$(find /var/www/devops-site -perm -o+w 2>/dev/null | wc -l)"
    key_perms="$(sudo stat -c '%a' /etc/ssl/private/devops.key 2>/dev/null || echo 'none')"
    sec_check="fail"
    if [[ "$world_writable" -eq 0 && "$key_perms" == "600" ]]; then sec_check="ok"; fi
    check "В каталоге ресурса нет файлов o+w и права ключа 600" "ok" "$sec_check"
fi

# [5] Контейнеризация (из ПР № 7)
if command -v docker >/dev/null 2>&1; then
    echo "[5] Контейнеризация"
    check "Служба docker активна" "active" "$(systemctl is-active docker 2>/dev/null || echo 'inactive')"
    
    db_health="$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null || echo 'none')"
    check "Контейнер СУБД находится в состоянии healthy" "healthy" "$db_health"

    bad_listeners="$(ss -tln 2>/dev/null | grep -E ':(5000|5432)\b' | grep -v '127\.0\.0\.1' | wc -l)"
    check "Порты 5000 и 5432 привязаны только к 127.0.0.1" "0" "$bad_listeners"

    env_perms="$(stat -c '%a' ~/app/.env 2>/dev/null || echo 'none')"
    check "Права файла ~/app/.env равны 600" "600" "$env_perms"
fi

# [6] Контрольная работа № 2 (Дополнительное задание)
if [[ -d ~/kr2 && -f /etc/nginx/sites-available/kr2 ]]; then
    echo "[6] Контрольная работа № 2"
    
    kr2_redis_id="$(docker compose --project-directory ~/kr2 ps -q redis 2>/dev/null || echo '')"
    kr2_redis_health="none"
    if [[ -n "$kr2_redis_id" ]]; then
        kr2_redis_health="$(docker inspect -f '{{.State.Health.Status}}' "$kr2_redis_id" 2>/dev/null || echo 'none')"
    fi
    check "Контейнер redis находится в состоянии healthy" "healthy" "$kr2_redis_health"

    kr2_port_out="$(docker compose --project-directory ~/kr2 port app 8003 2>/dev/null || echo 'none')"
    check "Порт 8003 опубликован только на 127.0.0.1" "127.0.0.1:8003" "$kr2_port_out"

    kr2_env_perms="$(stat -c '%a' ~/kr2/.env 2>/dev/null || echo 'none')"
    check "Права файла ~/kr2/.env равны 600" "600" "$kr2_env_perms"

    kr2_cert_valid="no"
    if openssl x509 -checkend 2592000 -noout -in /etc/ssl/certs/kr2.crt >/dev/null 2>&1; then kr2_cert_valid="yes"; fi
    check "Сертификат kr2.crt истекает не ранее чем через 30 дней" "yes" "$kr2_cert_valid"

    kr2_enabled="no"
    if [[ -L /etc/nginx/sites-enabled/kr2 ]]; then kr2_enabled="yes"; fi
    check "Ресурс kr2 активирован в sites-enabled" "yes" "$kr2_enabled"
fi

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1