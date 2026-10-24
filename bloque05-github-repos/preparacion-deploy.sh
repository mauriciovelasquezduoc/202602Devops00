#!/bin/bash
set -e

# ============================================================================
# preparacion-deploy.sh
#
# Copia el deploy.yml (opción 1, workflow_run) de cada servicio en
# bloque05-github-repos/<servicio>/workflows/ hacia su repositorio
# correspondiente en bloque00-aplicacion/<repo>/.github/workflows/,
# y hace commit + push en cada repositorio.
#
# Servicio -> repositorio:
#   database -> ep02_ing_devops_database
#   backend  -> ep02_ing_devops_backend
#   frontend -> ep02_ing_devops_frontend
#
# Opcional: DRY_RUN=1 ./preparacion-deploy.sh  (copia pero no commitea/pushea)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_FILE="$ROOT_DIR/secrets.txt"

# No pedir credenciales por consola: autenticamos con el token de secrets.txt
export GIT_TERMINAL_PROMPT=0

# "servicio:repositorio"
SERVICES=(
  "database:ep02_ing_devops_database"
  "backend:ep02_ing_devops_backend"
  "frontend:ep02_ing_devops_frontend"
)

# Lee un valor de secrets.txt (case-insensitive)
obtener_valor() {
  local key="$1"
  [ -f "$SECRETS_FILE" ] || return 0
  awk -F'=' -v k="$key" '
    /^[[:space:]]*#/ { next }
    {
      n = $1; gsub(/[[:space:]]/, "", n)
      if (toupper(n) == toupper(k)) {
        sub(/^[^=]*=/, ""); v = $0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; exit
      }
    }
  ' "$SECRETS_FILE"
}

remote_por_servicio() {
  case "$1" in
    database) obtener_valor GITHUB_DATABASE ;;
    backend)  obtener_valor GITHUB_BACKEND ;;
    frontend) obtener_valor GITHUB_FRONTEND ;;
  esac
}

banner() {
  echo ""
  echo "========================================="
  echo " $1"
  echo "========================================="
}

# Token de GitHub desde secrets.txt para autenticar el push.
# El helper de credenciales es efímero: NO persiste el token en disco/config.
GITHUB_TOKEN="$(obtener_valor GITHUB_TOKEN)"
if [ -n "$GITHUB_TOKEN" ]; then
  export GITHUB_TOKEN
  GIT_CRED_HELPER='!f() { echo username=x-access-token; echo "password=$GITHUB_TOKEN"; }; f'
  echo "Usando GITHUB_TOKEN de $SECRETS_FILE para autenticar el push."
else
  echo "ADVERTENCIA: GITHUB_TOKEN no encontrado en $SECRETS_FILE (git podría pedir credenciales)."
fi

for entry in "${SERVICES[@]}"; do
  svc="${entry%%:*}"
  repo="${entry##*:}"

  src="$SCRIPT_DIR/$svc/workflows/deploy.yml"
  dest_repo="$ROOT_DIR/bloque00-aplicacion/$repo"
  dest_dir="$dest_repo/.github/workflows"

  banner "$svc -> $repo"

  if [ ! -f "$src" ]; then
    echo "ERROR: no existe $src"
    exit 1
  fi
  if [ ! -d "$dest_repo" ]; then
    echo "ERROR: no existe el directorio $dest_repo"
    exit 1
  fi

  mkdir -p "$dest_dir"
  cp "$src" "$dest_dir/deploy.yml"
  echo "Copiado: $src"
  echo "     -> $dest_dir/deploy.yml"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "  [DRY_RUN] se omite init/commit/push"
    continue
  fi

  # Asegurar que el directorio sea SU PROPIO repositorio git (no el raíz)
  toplevel="$(git -C "$dest_repo" rev-parse --show-toplevel 2>/dev/null || true)"
  expected="$(cd "$dest_repo" && pwd)"

  if [ "$toplevel" != "$expected" ]; then
    echo "  '$repo' no es un repositorio git propio; inicializando..."
    git -C "$dest_repo" init -b main > /dev/null
    remote_url="$(remote_por_servicio "$svc")"
    if [ -n "$remote_url" ]; then
      git -C "$dest_repo" remote add origin "$remote_url" 2>/dev/null || \
        git -C "$dest_repo" remote set-url origin "$remote_url"
      echo "  remote origin -> $remote_url"
    else
      echo "  ADVERTENCIA: sin GITHUB_$(echo "$svc" | tr '[:lower:]' '[:upper:]') en secrets.txt"
    fi
  fi

  (
    cd "$dest_repo"

    # Identidad git local de respaldo (útil en contenedores sin config global)
    if ! git config user.email > /dev/null 2>&1; then
      git config user.email "github-actions[bot]@users.noreply.github.com"
      git config user.name  "github-actions[bot]"
    fi

    # Incluye deploy.yml (y cualquier otro workflow pendiente, p. ej. la calidad de la DB)
    git add .github/workflows/

    if git diff --cached --quiet; then
      echo "  Sin cambios para commitear"
    else
      git commit -m "feat(ci): agrega deploy.yml (opción 1, workflow_run)"
      echo "  Commit creado"
    fi

    echo "  Push a origin..."
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      git -c credential.helper="$GIT_CRED_HELPER" push -u origin HEAD
    else
      git push -u origin HEAD
    fi
  )

  echo "  OK $repo"
done

banner "PROCESO COMPLETADO"
