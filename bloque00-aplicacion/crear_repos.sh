#!/bin/bash
set -uo pipefail

# =====================================================
# Script: crear_repos.sh
# Crea en GitHub los 3 repositorios de la aplicación a
# partir de las carpetas locales y los sube (push).
#
# Lee GITHUB_TOKEN desde ../secrets.txt.
#
# Carpetas locales -> repositorios en GitHub:
#   ep02_ing_devops_database
#   ep02_ing_devops_backend
#   ep02_ing_devops_frontend
#
# El script es idempotente: si el repositorio ya existe en
# GitHub, no lo vuelve a crear pero igual sincroniza el
# contenido local (push). Un repo existente pero vacío se
# completa con los commits locales.
# =====================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_FILE="$ROOT_DIR/secrets.txt"

# Orden de despliegue: database, backend, frontend
REPO_DIRS=(
  "ep02_ing_devops_database"
  "ep02_ing_devops_backend"
  "ep02_ing_devops_frontend"
)

# Estado por repositorio (para el resumen final)
declare -a REPO_OK=()
declare -a REPO_ERR=()

banner() {
  echo ""
  echo "========================================="
  echo " $1"
  echo "========================================="
  echo ""
}

# Lee el valor de una clave desde secrets.txt (case-insensitive)
obtener_valor() {
  local target="$1"
  local file="$2"
  awk -F'=' -v key="$target" '
    /^[[:space:]]*#/ { next }
    {
      k = $1
      gsub(/[[:space:]]/, "", k)
      if (toupper(k) == toupper(key)) {
        sub(/^[^=]*=/, "")
        v = $0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        print v
        exit
      }
    }
  ' "$file"
}

banner "CREACIÓN DE REPOSITORIOS EN GITHUB"

# Verificar GitHub CLI
if ! command -v gh &> /dev/null; then
  echo "ERROR: GitHub CLI (gh) no está instalado."
  echo "       Instálalo con: brew install gh"
  exit 1
fi

# Verificar secrets.txt
if [ ! -f "$SECRETS_FILE" ]; then
  echo "ERROR: No se encontró $SECRETS_FILE"
  exit 1
fi

# Obtener GITHUB_TOKEN
GITHUB_TOKEN="$(obtener_valor "GITHUB_TOKEN" "$SECRETS_FILE")"
if [ -z "$GITHUB_TOKEN" ]; then
  echo "ERROR: GITHUB_TOKEN no está definido en $SECRETS_FILE"
  exit 1
fi
echo "Token leído desde: $SECRETS_FILE"

# Autenticar con GitHub CLI usando el token de secrets.txt
# gh detecta GH_TOKEN automáticamente; no se requiere "gh auth login".
export GH_TOKEN="$GITHUB_TOKEN"
echo "Usando GITHUB_TOKEN para autenticar..."

# El push se hace con git directo, no con gh, así que necesita un
# helper de credenciales. Se exporta GITHUB_TOKEN para que el helper
# (que corre en otra shell) pueda leerlo.
export GITHUB_TOKEN
export GIT_TERMINAL_PROMPT=0
GIT_CRED_HELPER='!f() { echo username=x-access-token; echo "password=$GITHUB_TOKEN"; }; f'

GH_OWNER="$(gh api user -q '.login')" || {
  echo "ERROR: No se pudo autenticar en GitHub. Revisa GITHUB_TOKEN."
  exit 1
}
echo "Usuario GitHub: $GH_OWNER"

# Prepara el repositorio local: init, identidad, add y commit.
# Deja el repo listo para hacer push.
preparar_repo_local() {
  local dir="$1"
  local name="$2"

  cd "$dir" || { echo "  ERROR: no se pudo entrar a $dir"; return 1; }

  if [ ! -d .git ]; then
    echo "Inicializando repositorio git..."
    git init -b main > /dev/null 2>&1 || {
      git init > /dev/null 2>&1 || return 1
      git symbolic-ref HEAD refs/heads/main
    }
  fi

  # Identidad git local de respaldo (útil en contenedores sin config global)
  if ! git config user.email > /dev/null 2>&1; then
    git config user.email "${GH_OWNER}@users.noreply.github.com"
    git config user.name "${GH_OWNER}"
  fi

  git add -A || { echo "  ERROR: git add falló"; return 1; }

  if git diff --cached --quiet; then
    echo "Sin cambios para commitear"
  else
    git commit -q -m "Initial commit: $name" || {
      echo "  ERROR: git commit falló"
      return 1
    }
    echo "Commit inicial creado"
  fi

  # Repo recién inicializado y sin archivos: se crea un commit vacío
  # para que el push tenga una rama que enviar.
  if ! git rev-parse --verify HEAD > /dev/null 2>&1; then
    git commit -q --allow-empty -m "Initial commit: $name" || {
      echo "  ERROR: no se pudo crear el commit inicial"
      return 1
    }
    echo "Commit inicial creado"
  fi

  return 0
}

# Sincroniza el repositorio local con GitHub: asegura el remote
# origin y hace push de la rama main.
sincronizar_repo() {
  local dir="$1"
  local name="$2"
  local url="https://github.com/$GH_OWNER/$name.git"

  cd "$dir" || { echo "  ERROR: no se pudo entrar a $dir"; return 1; }

  # El remote puede venir ya configurado (por ejemplo si el repo
  # local se clonado antes). "git remote add" falla si origin ya
  # existe, así que se actualiza la URL en vez de agregarla.
  if git remote get-url origin > /dev/null 2>&1; then
    git remote set-url origin "$url"
    echo "Remote origin actualizado: $url"
  else
    git remote add origin "$url" || {
      echo "  ERROR: no se pudo agregar el remote origin"
      return 1
    }
    echo "Remote origin agregado: $url"
  fi

  git -c credential.helper="$GIT_CRED_HELPER" push -u origin HEAD:refs/heads/main || {
    echo "  ERROR: falló el push a origin"
    return 1
  }
  echo "  ✔ Push completado"
  return 0
}

# Crear y subir cada repositorio
for name in "${REPO_DIRS[@]}"; do
  dir="${SCRIPT_DIR}/${name}"
  banner "Repositorio: $name"

  if [ ! -d "$dir" ]; then
    echo "ADVERTENCIA: No existe la carpeta $dir (omitido)"
    REPO_ERR+=("$name: no existe la carpeta local")
    continue
  fi

  # Se crea el repo en GitHub sin --source: así gh no intenta agregar
  # el remote (falla si origin ya existe) y el push se controla aquí.
  if gh repo view "$GH_OWNER/$name" > /dev/null 2>&1; then
    echo "El repositorio $GH_OWNER/$name ya existe en GitHub."
    echo "Se sincroniza el contenido local."
  else
    echo "Creando repositorio $GH_OWNER/$name..."
    if ! gh repo create "$GH_OWNER/$name" --public; then
      echo "  ERROR: no se pudo crear el repositorio en GitHub"
      REPO_ERR+=("$name: no se pudo crear el repositorio")
      continue
    fi
    echo "  ✔ Repositorio creado"
  fi

  if ! ( preparar_repo_local "$dir" "$name" ); then
    REPO_ERR+=("$name: error preparando el repositorio local")
    continue
  fi

  if ! ( sincronizar_repo "$dir" "$name" ); then
    REPO_ERR+=("$name: error en el push a GitHub")
    continue
  fi

  REPO_OK+=("$name")
done

banner "RESUMEN"
for name in "${REPO_DIRS[@]}"; do
  if printf '%s\n' "${REPO_OK[@]:-}" | grep -qx "$name"; then
    echo "  ✔ https://github.com/$GH_OWNER/$name"
  else
    echo "  ✗ https://github.com/$GH_OWNER/$name (con errores)"
  fi
done

if [ "${#REPO_ERR[@]}" -gt 0 ]; then
  echo ""
  echo "Errores:"
  for err in "${REPO_ERR[@]}"; do
    echo "  - $err"
  done
fi

# Escribe/actualiza el nombre del repositorio en secrets.txt
# Mapea cada carpeta local a su clave correspondiente.
clave_para_repo() {
  case "$1" in
    ep02_ing_devops_database) echo "GITHUB_DATABASE" ;;
    ep02_ing_devops_backend)  echo "GITHUB_BACKEND" ;;
    ep02_ing_devops_frontend) echo "GITHUB_FRONTEND" ;;
    *) echo "" ;;
  esac
}

# Asigna el valor de una clave en secrets.txt (la crea si no existe)
set_secret_valor() {
  local key="$1"
  local value="$2"
  local file="$3"
  [ -f "$file" ] || touch "$file"
  local tmp
  tmp="$(mktemp)"
  awk -F'=' -v key="$key" -v val="$value" '
    BEGIN { found = 0 }
    {
      k = $1
      gsub(/[[:space:]]/, "", k)
      if (toupper(k) == toupper(key)) {
        print key "=" val
        found = 1
        next
      }
      print
    }
    END {
      if (!found) print key "=" val
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

banner "ACTUALIZANDO $SECRETS_FILE"
for name in "${REPO_DIRS[@]}"; do
  key="$(clave_para_repo "$name")"
  if [ -n "$key" ]; then
    url="https://github.com/$GH_OWNER/$name"
    set_secret_valor "$key" "$url" "$SECRETS_FILE"
    echo "  ✔ $key=$url"
  fi
done

echo ""
if [ "${#REPO_ERR[@]}" -gt 0 ]; then
  echo "PROCESO COMPLETADO CON ERRORES (${#REPO_ERR[@]})"
  exit 1
fi

echo "PROCESO COMPLETADO"
