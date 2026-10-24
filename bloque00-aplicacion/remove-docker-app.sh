#!/bin/bash
set -e

# =====================================================
# Script: remove-docker-app.sh
# Detiene los contenedores de la aplicación, los elimina
# y luego borra las imágenes Docker locales.
#
# Contenedores / imágenes de la aplicación:
#   ep02-frontend
#   ep02-backend
#   ep02-db
#
# Uso:
#   bash remove-docker-app.sh
#   bash remove-docker-app.sh --volumes   # además borra el volumen pgdata
# =====================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Orden inverso al de arranque: frontend, backend, database
APP_DIRS=(
  "ep02_ing_devops_frontend"
  "ep02_ing_devops_backend"
  "ep02_ing_devops_database"
)

CONTAINERS=(
  "ep02-frontend"
  "ep02-backend"
  "ep02-db"
)

IMAGES=(
  "ep02-frontend:latest"
  "ep02-backend:latest"
  "ep02-db:latest"
)

REMOVE_VOLUMES=false
for arg in "$@"; do
  case "$arg" in
    --volumes|-v) REMOVE_VOLUMES=true ;;
    -h|--help)
      echo "Uso: bash remove-docker-app.sh [--volumes]"
      exit 0
      ;;
    *)
      echo "Opción desconocida: $arg"
      echo "Uso: bash remove-docker-app.sh [--volumes]"
      exit 1
      ;;
  esac
done

banner() {
  echo ""
  echo "========================================="
  echo " $1"
  echo "========================================="
  echo ""
}

banner "ELIMINANDO APLICACIÓN DOCKER"

# Verificar Docker
if ! command -v docker &> /dev/null; then
  echo "ERROR: Docker no está instalado."
  exit 1
fi

if ! docker info &> /dev/null; then
  echo "ERROR: Docker no está en ejecución. Inicia Docker Desktop."
  exit 1
fi

# 1) Detener y eliminar los contenedores de cada servicio
for name in "${APP_DIRS[@]}"; do
  dir="${SCRIPT_DIR}/${name}"

  if [ ! -d "$dir" ]; then
    echo "ADVERTENCIA: No existe la carpeta $dir (omitido)"
    continue
  fi

  banner "Servicio: $name"
  (
    cd "$dir"
    if [ "$REMOVE_VOLUMES" = true ]; then
      echo "Deteniendo y eliminando contenedores y volúmenes..."
      docker compose down --volumes || true
    else
      echo "Deteniendo y eliminando contenedores..."
      docker compose down || true
    fi
  )
done

# 2) Asegurar que no queden contenedores con esos nombres
banner "Verificando contenedores"
for c in "${CONTAINERS[@]}"; do
  if [ -n "$(docker ps -aq -f "name=^/${c}$")" ]; then
    echo "Eliminando contenedor restante: $c"
    docker rm -f "$c" || true
  else
    echo "  Contenedor $c no existe (OK)"
  fi
done

# 3) Eliminar las imágenes
banner "Eliminando imágenes"
for img in "${IMAGES[@]}"; do
  if docker image inspect "$img" &> /dev/null; then
    echo "Eliminando imagen: $img"
    docker rmi -f "$img" || true
  else
    echo "  Imagen $img no existe (OK)"
  fi
done

banner "RESUMEN"
echo "Contenedores restantes:"
docker ps -a --filter "name=ep02-" --format "  {{.Names}}\t{{.Status}}" || true
echo ""
echo "Imágenes restantes:"
docker images --filter "reference=ep02-*" --format "  {{.Repository}}:{{.Tag}}" || true
echo ""
echo "PROCESO COMPLETADO"
