#!/bin/bash
set -e

# =====================================================
# Script: crear-repos-y-secrets.sh
# Actualiza secrets en repositorios existentes de GitHub
# usando GitHub CLI (gh).
#
# Lee todo desde /guia-04/secrets.txt:
#   - Secretos (AWS_ACCESS_KEY_ID, etc.)
#   - Repositorios (GITHUB_DATABASE, GITHUB_BACKEND, GITHUB_FRONTEND)
# =====================================================

SECRETS_FILE="../secrets.txt"

banner() {
  echo ""
  echo "========================================="
  echo " $1"
  echo "========================================="
  echo ""
}

# -----------------------------------------------------
# Leer todo desde secrets.txt
# -----------------------------------------------------
leer_secrets() {
  SECRETS_KEYS=()
  SECRETS_VALS=()

  if [ ! -f "$SECRETS_FILE" ]; then
    echo "ERROR: No se encontró $SECRETS_FILE"
    exit 1
  fi

  while IFS='=' read -r key value || [ -n "$key" ]; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    [[ -z "$value" ]] && continue
    SECRETS_KEYS+=("$key")
    SECRETS_VALS+=("$value")
  done < "$SECRETS_FILE"
}

obtener_valor() {
  local target="$1"
  # Buscar case-insensitive
  local target_upper=$(echo "$target" | tr '[:lower:]' '[:upper:]')
  for i in "${!SECRETS_KEYS[@]}"; do
    local key_upper=$(echo "${SECRETS_KEYS[$i]}" | tr '[:lower:]' '[:upper:]')
    if [ "$key_upper" = "$target_upper" ]; then
      echo "${SECRETS_VALS[$i]}"
      return
    fi
  done
}

# Extraer nombre del repositorio desde URL de GitHub
extraer_nombre_repo() {
  local url="$1"
  # Si es URL completa, extraer el nombre del repositorio
  if [[ "$url" == *"github.com"* ]]; then
    # Obtener la ultima parte de la URL (antes de .git si existe)
    local repo_name=$(basename "$url" .git)
    echo "$repo_name"
  else
    # Si no es URL, devolver tal cual
    echo "$url"
  fi
}

# -----------------------------------------------------
# INICIO
# -----------------------------------------------------

banner "ACTUALIZACIÓN DE SECRETS EN GITHUB"

# Verificar gh
if ! command -v gh &> /dev/null; then
  echo "ERROR: GitHub CLI (gh) no está instalado."
  echo "       Instálalo: brew install gh"
  exit 1
fi

# Leer secrets.txt
echo "Leyendo desde: $SECRETS_FILE"
leer_secrets
echo "   Encontrados: ${#SECRETS_KEYS[@]} claves"

# Obtener repositorios desde secrets.txt
REPOS=()
for repo in GITHUB_DATABASE GITHUB_BACKEND GITHUB_FRONTEND; do
  valor=$(obtener_valor "$repo")
  if [ -n "$valor" ]; then
    # Extraer nombre del repositorio desde URL
    repo_name=$(extraer_nombre_repo "$valor")
    REPOS+=("$repo_name")
    echo "   - $repo: $repo_name"
  fi
done

if [ ${#REPOS[@]} -eq 0 ]; then
  echo "ERROR: No se encontraron repositorios (GITHUB_*) en secrets.txt"
  exit 1
fi

# Autenticar
GH_TOKEN=$(obtener_valor "GITHUB_TOKEN")
unset GITHUB_TOKEN

if ! gh auth status &> /dev/null; then
  if [ -n "$GH_TOKEN" ]; then
    echo ""
    echo "Autenticando con GITHUB_TOKEN..."
    echo "$GH_TOKEN" | gh auth login --with-token
  else
    echo ""
    echo "Iniciando autenticación interactiva..."
    gh auth login
  fi
fi

echo ""
gh auth status

# Owner
GH_OWNER=$(gh api user -q '.login')
echo ""
echo "Usuario GitHub: $GH_OWNER"

# -----------------------------------------------------
# Verificar que los repos existen
# -----------------------------------------------------

banner "VERIFICANDO REPOSITORIOS"

REPOS_OK=()

for repo in "${REPOS[@]}"; do
  FULL_NAME="$GH_OWNER/$repo"
  
  if gh repo view "$FULL_NAME" &> /dev/null; then
    echo "  ✔ $FULL_NAME"
    REPOS_OK+=("$repo")
  else
    echo "  ✗ $FULL_NAME (no existe - omitido)"
  fi
done

if [ ${#REPOS_OK[@]} -eq 0 ]; then
  echo ""
  echo "ERROR: No se encontró ningún repositorio válido."
  exit 1
fi

# -----------------------------------------------------
# Secretos a configurar (excluyendo GITHUB_* y comentarios)
# -----------------------------------------------------

banner "SECRETOS A CONFIGURAR"

SECRET_NAMES=(
  "AWS_ACCESS_KEY_ID"
  "AWS_SECRET_ACCESS_KEY"
  "AWS_SESSION_TOKEN"
  "AWS_REGION"
  "SONAR_TOKEN"
  "SNYK_TOKEN"
)

SECRETS_VALUES=()
for secret in "${SECRET_NAMES[@]}"; do
  valor=$(obtener_valor "$secret")
  SECRETS_VALUES+=("$valor")
done

for i in "${!SECRET_NAMES[@]}"; do
  secret="${SECRET_NAMES[$i]}"
  valor="${SECRETS_VALUES[$i]}"
  if [ -n "$valor" ]; then
    printf "  %-30s ✔ (%d chars)\n" "$secret" "${#valor}"
  else
    printf "  %-30s ✗ (sin valor)\n" "$secret"
  fi
done

# -----------------------------------------------------
# Aplicar secretos
# -----------------------------------------------------

banner "ACTUALIZANDO SECRETOS"

set +e

for repo in "${REPOS_OK[@]}"; do
  FULL_NAME="$GH_OWNER/$repo"
  echo ""
  echo ">>> $FULL_NAME"

  for i in "${!SECRET_NAMES[@]}"; do
    secret="${SECRET_NAMES[$i]}"
    valor="${SECRETS_VALUES[$i]}"

    if [ -z "$valor" ]; then
      echo "  [$secret] ○ omitido"
      continue
    fi

    printf "  [%s] " "$secret"
    if gh secret set "$secret" --body "$valor" --repo "$FULL_NAME" 2>&1; then
      echo "✔"
    else
      echo "✗ ERROR"
    fi
  done
done

set -e

# -----------------------------------------------------
# Resumen
# -----------------------------------------------------

banner "RESUMEN"

echo "Repositorios actualizados:"
for repo in "${REPOS_OK[@]}"; do
  echo "  ✔ https://github.com/$GH_OWNER/$repo"
done

echo ""
echo "Secrets configurados:"
for secret in "${SECRET_NAMES[@]}"; do
  valor=$(obtener_valor "$secret")
  [ -n "$valor" ] && echo "  ✔ $secret" || echo "  ○ $secret (sin valor)"
done

echo ""
echo "Verificar en:"
for repo in "${REPOS_OK[@]}"; do
  echo "  https://github.com/$GH_OWNER/$repo/settings/secrets/actions"
done

echo ""
echo "========================================="
echo " PROCESO COMPLETADO"
echo "========================================="