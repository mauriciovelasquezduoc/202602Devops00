#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_FILE="${SCRIPT_DIR}/repositorios.yaml"
SECRETS_FILE="${SCRIPT_DIR}/../secrets.txt"

echo "=== AWS ECR Repository Manager ==="

# Cargar credenciales AWS desde secrets.txt
if [ -f "$SECRETS_FILE" ]; then
    echo "Cargando credenciales desde $SECRETS_FILE"
    while IFS='=' read -r key value || [ -n "$key" ]; do
        key="${key//[[:space:]]/}"
        [ -z "$key" ] && continue
        [[ "$key" == \#* ]] && continue
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        [ -z "$value" ] && continue
        export "$key=$value"
    done < "$SECRETS_FILE"

    # Compatibilidad con claves en minusculas.
    [ -n "${aws_access_key_id:-}" ] && export AWS_ACCESS_KEY_ID="$aws_access_key_id"
    [ -n "${aws_secret_access_key:-}" ] && export AWS_SECRET_ACCESS_KEY="$aws_secret_access_key"
    [ -n "${aws_session_token:-}" ] && export AWS_SESSION_TOKEN="$aws_session_token"
    [ -n "${AWS_REGION:-}" ] && export AWS_DEFAULT_REGION="$AWS_REGION"
else
    echo "ADVERTENCIA: No se encontro $SECRETS_FILE, usando credenciales por defecto de AWS"
fi

# Verificar que exista repositorios.yaml
if [ ! -f "$REPOS_FILE" ]; then
    echo "Error: No se encontro repositorios.yaml"
    exit 1
fi

# 1. Identificar cuenta AWS actual
echo ""
echo "1/4 Identificando cuenta AWS actual..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}"
ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo "sin-alias")

echo "   Cuenta:     $ACCOUNT_ID"
echo "   Alias:      $ACCOUNT_ALIAS"
echo "   Region:     $REGION"
echo "   ARN:        $(aws sts get-caller-identity --query Arn --output text)"

# 2. Extraer nombres de repositorios del YAML
echo ""
echo "2/4 Leyendo repositorios desde repositorios.yaml..."
REPOS=()

while IFS= read -r line; do
    if [[ "$line" =~ Name:[[:space:]]*(.+) ]]; then
        name="${BASH_REMATCH[1]}"
        name=$(echo "$name" | xargs | tr -d '"' | tr '[:upper:]' '[:lower:]')
        REPOS+=("$name")
    fi
done < "$REPOS_FILE"

if [ ${#REPOS[@]} -eq 0 ]; then
    echo "Error: No se encontraron repositorios en repositorios.yaml"
    exit 1
fi

echo "   Repositorios a crear: ${#REPOS[@]}"
for repo in "${REPOS[@]}"; do
    echo "   - $repo"
done

# 3. Crear repositorios ECR
echo ""
echo "3/4 Creando repositorios ECR..."

for repo in "${REPOS[@]}"; do
    # Validar nombre (solo minusculas, numeros, guiones, puntos, underscores)
    if [[ ! "$repo" =~ ^[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*(/[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*)*$ ]]; then
        echo "   [ERROR] Nombre invalido: $repo"
        echo "           Debe ser minusculas, sin espacios ni caracteres especiales"
        continue
    fi
    
    # Verificar si ya existe
    if aws ecr describe-repositories --repository-names "$repo" --region "$REGION" &>/dev/null; then
        echo "   [EXISTENTE] $repo"
    else
        aws ecr create-repository \
            --repository-name "$repo" \
            --image-scanning-configuration scanOnPush=false \
            --region "$REGION" > /dev/null
        echo "   [CREADO] $repo"
    fi
done

# 4. Listar repositorios creados
echo ""
echo "4/4 Listando repositorios ECR en cuenta $ACCOUNT_ID..."
echo ""
echo "=== Repositorios ECR ==="
aws ecr describe-repositories \
    --query 'repositories[*].[repositoryName,repositoryUri,createdAt]' \
    --output table \
    --region "$REGION"

echo ""
echo "=== URIs para docker push ==="
for repo in "${REPOS[@]}"; do
    echo "$repo -> ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${repo}"
done

echo ""
echo "=== Comandos de login ==="
echo "aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# 5. Generar archivo de resultado
echo ""
echo "5/5 Generando archivo de resultado..."

OUTPUT_FILE="${SCRIPT_DIR}/resultado-ecr.yaml"

cat > "$OUTPUT_FILE" << EOF
# resultado-ecr.yaml - Resultado de creacion de repositorios ECR
# Generado automaticamente por ejecutar-ecr.sh

# Informacion de la cuenta AWS
aws_account:
  account_id: "${ACCOUNT_ID}"
  account_alias: "${ACCOUNT_ALIAS}"
  region: "${REGION}"
  arn: "$(aws sts get-caller-identity --query Arn --output text)"
  login_command: "aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Repositorios creados
repositories:
EOF

for repo in "${REPOS[@]}"; do
    # Obtener URI del repositorio
    URI=$(aws ecr describe-repositories --repository-names "$repo" --query 'repositories[0].repositoryUri' --output text --region "$REGION" 2>/dev/null || echo "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${repo}")
    
    # Obtener fecha de creacion
    CREATED=$(aws ecr describe-repositories --repository-names "$repo" --query 'repositories[0].createdAt' --output text --region "$REGION" 2>/dev/null || echo "N/A")
    
    cat >> "$OUTPUT_FILE" << EOF
  - name: "${repo}"
    uri: "${URI}"
    created_at: "${CREATED}"
    push_command: "docker tag ${repo}:latest ${URI}:latest && docker push ${URI}:latest"
EOF
done

echo ""
echo "   Archivo generado: $OUTPUT_FILE"
echo ""
echo "=== Resumen ==="
echo "Repositorios: ${#REPOS[@]}"
echo "Cuenta: ${ACCOUNT_ID}"
echo "Region: ${REGION}"