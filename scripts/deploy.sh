#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
REPO_ROOT="$(git rev-parse --show-toplevel)"
LOCAL_DIR="${REPO_ROOT}/site/"

# 1. Разбор аргумента --dry-run
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
elif [[ -n "${1:-}" ]]; then
    echo "Неизвестный параметр: $1" >&2
    echo "Использование: $0 [--dry-run]" >&2
    exit 1
fi

# 2. Проверки по требованиям 4 и 5
# Требование 4: Если файл site/index.html отсутствует, доставка не выполняется; сообщение в stderr, код 1
if [[ ! -f "${REPO_ROOT}/site/index.html" ]]; then
    echo "Ошибка: Главная страница ${REPO_ROOT}/site/index.html не найдена!" >&2
    exit 1
fi

# Требование 5: Если в репозитории есть незафиксированные изменения, доставка не выполняется; код 1
if ! git -C "${REPO_ROOT}" diff --quiet || ! git -C "${REPO_ROOT}" diff --cached --quiet; then
    echo "Ошибка: В репозитории есть незафиксированные изменения! Зафиксируйте коммит перед деплоем." >&2
    exit 1
fi

if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain "${REPO_ROOT}/site")" ]]; then
    echo "Ошибка: В каталоге site/ присутствуют неотслеживаемые или изменённые файлы!" >&2
    exit 1
fi

# 3. Синхронизация каталога
SSH_OPTS="ssh -o BatchMode=yes -o ConnectTimeout=5"
RSYNC_FLAGS=(-avz --delete --chmod=D755,F644 -e "$SSH_OPTS")
if [[ "$DRY_RUN" == true ]]; then
    RSYNC_FLAGS+=(--dry-run)
fi

rsync "${RSYNC_FLAGS[@]}" "${LOCAL_DIR}" "${REMOTE}:${REMOTE_DIR}/"

# 4. При --dry-run — завершение с кодом 0 без проверки доступности
if [[ "$DRY_RUN" == true ]]; then
    echo "Режим dry-run успешно завершён. Изменения не применены."
    exit 0
fi

# 5. Проверка доступности
CURL_ARGS=(-fsS --cacert "$CA_CERT" "$SITE_URL")
if ! curl "${CURL_ARGS[@]}" >/dev/null 2>&1; then
    echo "Ошибка: Проверка доступности ресурса ${SITE_URL} завершилась неудачей!" >&2
    exit 1
fi

# Вывод короткого хеша доставленного коммита
COMMIT_HASH="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
echo "Деплой успешно выполнен! Доставлен коммит: ${COMMIT_HASH}"
exit 0