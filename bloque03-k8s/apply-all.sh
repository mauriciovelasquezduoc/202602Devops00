#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/values.yaml"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
OUTPUT_DIR="${SCRIPT_DIR}/output"
SECRETS_FILE="${SCRIPT_DIR}/../secrets.txt"

echo "=== Kubernetes Config Generator ==="

# Cargar credenciales desde secrets.txt
if [ -f "$SECRETS_FILE" ]; then
    echo "Leyendo $SECRETS_FILE..."
    while IFS='=' read -r key value || [ -n "$key" ]; do
        key="${key//[[:space:]]/}"
        [ -z "$key" ] && continue
        [[ "$key" == \#* ]] && continue
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        [ -z "$value" ] && continue
        export "$key=$value"
    done < "$SECRETS_FILE"

    # Compatibilidad con claves AWS en minusculas.
    [ -n "${aws_access_key_id:-}" ] && export AWS_ACCESS_KEY_ID="$aws_access_key_id"
    [ -n "${aws_secret_access_key:-}" ] && export AWS_SECRET_ACCESS_KEY="$aws_secret_access_key"
    [ -n "${aws_session_token:-}" ] && export AWS_SESSION_TOKEN="$aws_session_token"
    [ -n "${AWS_REGION:-}" ] && export AWS_DEFAULT_REGION="$AWS_REGION"
else
    echo "ADVERTENCIA: No se encontro $SECRETS_FILE"
fi

REGION="${AWS_REGION:-us-east-1}"

# Cuenta real: se DERIVA desde STS para NO depender de un account hardcodeado
# en values.yaml ni de secrets.txt.
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
if [ -z "$ACCOUNT_ID" ]; then
    ACCOUNT_ID="${AWSAccountId:-}"
    [ -n "$ACCOUNT_ID" ] && echo "ADVERTENCIA: STS no respondio; usando AWSAccountId de secrets.txt ($ACCOUNT_ID)"
fi
echo "Cuenta AWS: ${ACCOUNT_ID:-desconocida} (region $REGION)"

aws eks update-kubeconfig --region "$REGION" --name laboratorio-ep02-eks

# Verificar que exista values.yaml
if [ ! -f "$VALUES_FILE" ]; then
    echo "Error: No se encontro values.yaml"
    exit 1
fi

# Crear directorio de salida
mkdir -p "$OUTPUT_DIR"

# Cargar variables desde values.yaml
echo "1/3 Leyendo valores desde values.yaml..."

# NO se usa "source": valores como <AWSAccountId> serian interpretados por el
# shell como redirecciones (< archivo). Se parsea key=value de forma literal.
while IFS='=' read -r key value || [ -n "$key" ]; do
    key="${key//[[:space:]]/}"
    [ -z "$key" ] && continue
    [[ "$key" == \#* ]] && continue
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    export "$key=$value"
done < "$VALUES_FILE"

echo "   Variables cargadas"

# Desacoplar las imágenes de la cuenta: reemplazar "<account>.dkr.ecr.<region>"
# por la cuenta real (STS), SIN modificar values.yaml.
# Reconoce tanto un account numérico previo como el placeholder <AWSAccountId>.
if [ -n "$ACCOUNT_ID" ]; then
    for var in DATABASE_IMAGE BACKEND_IMAGE FRONTEND_IMAGE; do
        val="${!var:-}"
        [ -n "$val" ] || continue
        new="$(echo "$val" | sed -E "s#^[^/]+\.dkr\.ecr\.[a-z0-9-]+#${ACCOUNT_ID}.dkr.ecr.${REGION}#")"
        export "$var=$new"
        echo "   $var = $new"
    done
fi

# Generar YAMLs desde templates
echo ""
echo "2/3 Generando manifiestos..."
for template in "$TEMPLATES_DIR"/*.yaml; do
    filename=$(basename "$template")
    cp "$template" "$OUTPUT_DIR/$filename"
    
    # Reemplazar cada variable ${KEY} usando awk
    awk '{
        line = $0
        while (match(line, /\$\{[A-Z_0-9]+\}/)) {
            var = substr(line, RSTART + 2, RLENGTH - 3)
            value = ENVIRON[var]
            if (value != "") {
                line = substr(line, 1, RSTART - 1) value substr(line, RSTART + RLENGTH)
            } else {
                break
            }
        }
        print line
    }' "$OUTPUT_DIR/$filename" > "$OUTPUT_DIR/$filename.tmp"
    mv "$OUTPUT_DIR/$filename.tmp" "$OUTPUT_DIR/$filename"
    
    echo "   - $filename"
done

# Aplicar manifiestos
echo ""
echo "3/3 Aplicando manifiestos a Kubernetes..."
kubectl apply -f "$OUTPUT_DIR/namespace.yaml"
kubectl apply -f "$OUTPUT_DIR/database-secret.yaml"
kubectl apply -f "$OUTPUT_DIR/database-deployment.yaml"
kubectl apply -f "$OUTPUT_DIR/database-service.yaml"
kubectl apply -f "$OUTPUT_DIR/backend-deployment.yaml"
kubectl apply -f "$OUTPUT_DIR/backend-service.yaml"
kubectl apply -f "$OUTPUT_DIR/frontend-deployment.yaml"
kubectl apply -f "$OUTPUT_DIR/frontend-service.yaml"
kubectl apply -f "$OUTPUT_DIR/backend-hpa.yaml"
kubectl apply -f "$OUTPUT_DIR/frontend-hpa.yaml"

echo ""
echo "=== Despliegue completado ==="
kubectl get all -n "$NAMESPACE"