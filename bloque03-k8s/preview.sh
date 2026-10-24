#!/bin/bash

# Script para ver diferencias entre templates y valores actuales

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/values.yaml"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
OUTPUT_DIR="${SCRIPT_DIR}/output"

echo "=== Comparando manifiestos ==="

if [ ! -f "$VALUES_FILE" ]; then
    echo "Error: No se encontro values.yaml"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

export $(grep -v '^#' "$VALUES_FILE" | grep -v '^\s*$' | xargs)

for template in "$TEMPLATES_DIR"/*.yaml; do
    filename=$(basename "$template")
    envsubst < "$template" > "$OUTPUT_DIR/$filename"
done

echo "Manifiestos actualizados en $OUTPUT_DIR/"
echo ""
echo "Para ver el contenido de un manifiesto:"
echo "  cat $OUTPUT_DIR/<archivo>.yaml"
echo ""
echo "Para validar contra el cluster:"
echo "  kubectl diff -f $OUTPUT_DIR/"