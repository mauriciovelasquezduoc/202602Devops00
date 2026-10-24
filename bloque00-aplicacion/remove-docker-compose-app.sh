#!/bin/bash
set -e

# =====================================================
# Script: remove-docker-compose-app.sh
# Elimina TODO lo creado por docker compose en esta
# carpeta (bloque00-aplicacion):
#   - detiene y elimina los contenedores
#   - elimina la red ep02-network
#   - elimina las imágenes ep02-db/backend/frontend
#   - (opcional) elimina el volumen pgdata con --volumes
#
# Uso:
#   bash remove-docker-compose-app.sh
#   bash remove-docker-compose-app.sh --volumes   # además borra el volumen pgdata
# =====================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

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
      echo "Uso: bash remove-docker-compose-app.sh [--volumes]"
      exit 0
      ;;
    *)
      echo "Opción desconocida: $arg"
      echo "Uso: bash remove-docker-compose-app.sh [--volumes]"
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

banner "ELIMINANDO STACK DOCKER COMPOSE"

# Verificar Docker
if ! command -v docker &> /dev/null; then
  echo "ERROR: Docker no está instalado."
  exit 1
fi

if ! docker info &> /dev/null; then
  echo "ERROR: Docker no está en ejecución. Inicia Docker Desktop."
  exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "ERROR: No se encontró $COMPOSE_FILE"
  exit 1
fi

# 1) Detener y eliminar contenedores, red y (opcionalmente) volúmenes
banner "docker compose down"
(
  cd "$SCRIPT_DIR"
  if [ "$REMOVE_VOLUMES" = true ]; then
    echo "Eliminando contenedores, red y volúmenes..."
    docker compose down --remove-orphans --volumes || true
  else
    echo "Eliminando contenedores y red..."
    docker compose down --remove-orphans || true
  fi
)

# 2) Eliminar contenedores ep02- que hayan quedado huérfanos
banner "Verificando contenedores"
for c in $(docker ps -aq -f "name=^/ep02-" 2>/dev/null); do
  name="$(docker inspect -f '{{.Name}}' "$c" | sed 's#^/##')"
  echo "Eliminando contenedor restante: $name"
  docker rm -f "$c" || true
done
docker ps -a --filter "name=ep02-" --format "  {{.Names}}" | grep -q . \
  || echo "  No quedan contenedores ep02- (OK)"

# 3) Eliminar la red ep02-network si aún existe
banner "Verificando red"
if docker network inspect ep02-network &> /dev/null; then
  echo "Eliminando red ep02-network"
  docker network rm ep02-network || true
else
  echo "  Red ep02-network no existe (OK)"
fi

# 4) Eliminar las imágenes
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
echo "Contenedores ep02- restantes:"
docker ps -a --filter "name=ep02-" --format "  {{.Names}}\t{{.Status}}" || true
echo ""
echo "Imágenes ep02- restantes:"
docker images --filter "reference=ep02-*" --format "  {{.Repository}}:{{.Tag}}" || true
echo ""
echo "Volúmenes ep02 / pgdata restantes:"
docker volume ls --format "  {{.Name}}" | grep -Ei 'pgdata|ep02' || echo "  (ninguno)"
echo ""
echo "PROCESO COMPLETADO"
