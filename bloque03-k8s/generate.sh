#!/bin/bash

# Script para generar YAMLs sin aplicar (solo preview)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/values.yaml"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
OUTPUT_DIR="${SCRIPT_DIR}/output"

echo "=== Generando manifiestos (preview) ==="

if [ ! -f "$VALUES_FILE" ]; then
    echo "Error: No se encontro values.yaml"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Funcion para reemplazar variables usando sed
replace_vars() {
    local file="$1"
    local output="$2"
    
    cp "$file" "$output"
    
    while IFS='=' read -r key value; do
        # Ignorar comentarios y lineas vacias
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        [[ -z "$value" ]] && continue
        
        # Reemplazar ${KEY} por el valor usando sed
        sed -i.bak "s|\${${key}}|${value}|g" "$output"
    done < "$VALUES_FILE"
    
    # Eliminar archivo de respaldo
    rm -f "$output.bak"
}

for template in "$TEMPLATES_DIR"/*.yaml; do
    filename=$(basename "$template")
    replace_vars "$template" "$OUTPUT_DIR/$filename"
    echo "Generado: $OUTPUT_DIR/$filename"
done

echo ""
echo "=== Archivos generados en $OUTPUT_DIR ==="
ls -la "$OUTPUT_DIR"