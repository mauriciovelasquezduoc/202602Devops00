#!/usr/bin/env bash
# ============================================================================
# aws-limpiar.sh — Limpieza TOTAL de esta guía (evitar cobros en AWS)
# ============================================================================
# Elimina lo creado por bloque01..bloque05:
#   - Namespace "ep02" en Kubernetes (Deployments, Services → LoadBalancer/ELB, HPA)
#   - Load Balancers (clásicos y v2) que hayan quedado en la VPC del lab
#   - Stack CloudFormation "laboratorio-ep02-eks"  (cluster EKS + NodeGroup + addons)
#   - Security Groups huérfanos (k8s-*) en la VPC del lab
#   - Stack CloudFormation "laboratorio-ep02-vpc"  (VPC + subnets + endpoints)
#   - Repositorios ECR (ep02-database, ep02-backend, ep02-frontend)
#   - CloudWatch Log Groups del cluster EKS
#   - Contexto de kubeconfig
#
# Uso:
#   ./aws-limpiar.sh          # pide confirmación
#   ./aws-limpiar.sh -y       # sin confirmación (peligroso)
#
# Credenciales: se leen de ./secrets.txt (aws_access_key_id / secret / session).
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="$SCRIPT_DIR/secrets.txt"

REGION="${REGION:-us-east-1}"
CLUSTER_NAME="laboratorio-ep02-eks"
NAMESPACE="ep02"
STACK_EKS="laboratorio-ep02-eks"
STACK_VPC="laboratorio-ep02-vpc"
NODEGROUP_NAME="laboratorio-ep02-nodegroup"
ECR_REPOS=(ep02-database ep02-backend ep02-frontend)

ROJO='\033[0;31m'; VERDE='\033[0;32m'; AMAR='\033[1;33m'; AZUL='\033[0;34m'; NC='\033[0m'
log()  { echo -e "$*"; }
ok()   { echo -e "  ${VERDE}OK  $*${NC}"; }
warn() { echo -e "  ${AMAR}$*${NC}"; }
err()  { echo -e "  ${ROJO}$*${NC}"; }

# ── 0. Cargar credenciales de secrets.txt ───────────────────────────────────
if [ -f "$SECRETS_FILE" ]; then
  while IFS='=' read -r key value || [ -n "$key" ]; do
    key="${key//[[:space:]]/}"; [ -z "$key" ] && continue; [[ "$key" == \#* ]] && continue
    value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
    [ -z "$value" ] && continue; export "$key=$value"
  done < "$SECRETS_FILE"
  [ -n "${aws_access_key_id:-}" ]     && export AWS_ACCESS_KEY_ID="$aws_access_key_id"
  [ -n "${aws_secret_access_key:-}" ] && export AWS_SECRET_ACCESS_KEY="$aws_secret_access_key"
  [ -n "${aws_session_token:-}" ]     && export AWS_SESSION_TOKEN="$aws_session_token"
  [ -n "${AWS_REGION:-}" ]            && REGION="$AWS_REGION"
fi

echo ""
log "${AZUL}============================================================"
log " aws-limpiar.sh — Limpieza total del laboratorio ep02"
log "============================================================${NC}"
log "${AMAR}⚠  Esto ELIMINARÁ: namespace $NAMESPACE, ELBs, cluster EKS,"
log "   VPC, repos ECR y log groups de la cuenta AWS."
log "   NO se puede deshacer.${NC}"
echo ""

if [ "${1:-}" != "-y" ] && [ "${1:-}" != "--yes" ]; then
  read -r -p "  ¿Continuar? (s/N): " CONFIRM
  if [ "$CONFIRM" != "s" ] && [ "$CONFIRM" != "S" ]; then
    log "${ROJO}  Cancelado.${NC}"; exit 0
  fi
fi

# ── 1. AWS conectividad ─────────────────────────────────────────────────────
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [ -z "$ACCOUNT_ID" ]; then
  err "Sin conexión a AWS. Renueva credenciales (AWS Academy → Start Lab) y actualiza secrets.txt."
  exit 1
fi
ok "AWS OK — account=$ACCOUNT_ID region=$REGION"

# ── 2. Kubeconfig + borrar namespace ────────────────────────────────────────
CLUSTER_STATUS="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query 'cluster.status' --output text 2>/dev/null || echo NOEXISTE)"
if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
fi

log ""
log "${AZUL}[1/7] Borrando namespace $NAMESPACE (y su LoadBalancer)…${NC}"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl delete hpa        -n "$NAMESPACE" --all --grace-period=0 --force >/dev/null 2>&1 || true
  kubectl delete deployment -n "$NAMESPACE" --all --grace-period=0 --force >/dev/null 2>&1 || true
  kubectl delete svc        -n "$NAMESPACE" --all --grace-period=0 --force >/dev/null 2>&1 || true
  kubectl delete pod        -n "$NAMESPACE" --all --grace-period=0 --force >/dev/null 2>&1 || true
  kubectl delete namespace  "$NAMESPACE" --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || break; sleep 2; done
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 && warn "Namespace aún existe (se resolverá al borrar el cluster)" || ok "Namespace $NAMESPACE eliminado"
else
  warn "Namespace $NAMESPACE no existe"
fi

# ── 3. Load Balancers huérfanos en la VPC del lab ───────────────────────────
log ""
log "${AZUL}[2/7] Borrando Load Balancers que queden en la VPC del lab…${NC}"
VPC_ID="$(aws cloudformation describe-stacks --stack-name "$STACK_VPC" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text 2>/dev/null || true)"
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  for lb in $(aws elb describe-load-balancers --region "$REGION" \
      --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null); do
    aws elb delete-load-balancer --load-balancer-name "$lb" --region "$REGION" >/dev/null 2>&1 && ok "ELB clásico borrado: $lb" || warn "no se pudo borrar ELB $lb"
  done
  for arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null); do
    aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" >/dev/null 2>&1 && ok "LBv2 borrado: $arn" || warn "no se pudo borrar $arn"
  done
  warn "Esperando 30s a que se liberen las ENIs de los LB…"; sleep 30
else
  warn "No se pudo obtener la VPC ($STACK_VPC)"
fi

# ── 4. Stack EKS (cluster + nodegroup + addons) ─────────────────────────────
log ""
log "${AZUL}[3/7] Borrando stack CloudFormation $STACK_EKS (10-15 min)…${NC}"
if aws cloudformation describe-stacks --stack-name "$STACK_EKS" --region "$REGION" >/dev/null 2>&1; then
  aws cloudformation delete-stack --stack-name "$STACK_EKS" --region "$REGION"
  if aws cloudformation wait stack-delete-complete --stack-name "$STACK_EKS" --region "$REGION" 2>/dev/null; then
    ok "Stack $STACK_EKS eliminado"
  else
    err "El stack $STACK_EKS no se pudo eliminar (revisa dependencias/ENIs)"
  fi
else
  warn "Stack $STACK_EKS no existe"
fi

# ── 5. Security Groups huérfanos (k8s-*) y stack VPC ────────────────────────
log ""
log "${AZUL}[4/7] Borrando Security Groups huérfanos y stack ${STACK_VPC}…${NC}"
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  for sg in $(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" \
      --query "SecurityGroups[?GroupName!='default' && starts_with(GroupName, 'k8s-')].GroupId" --output text 2>/dev/null); do
    aws ec2 delete-security-group --group-id "$sg" --region "$REGION" >/dev/null 2>&1 && ok "SG borrado: $sg" || warn "SG $sg en uso (se reintentará al borrar la VPC)"
  done
fi
if aws cloudformation describe-stacks --stack-name "$STACK_VPC" --region "$REGION" >/dev/null 2>&1; then
  aws cloudformation delete-stack --stack-name "$STACK_VPC" --region "$REGION"
  if aws cloudformation wait stack-delete-complete --stack-name "$STACK_VPC" --region "$REGION" 2>/dev/null; then
    ok "Stack $STACK_VPC eliminado"
  else
    err "El stack $STACK_VPC no se pudo eliminar (probable dependencia: ENIs/SG). Reintenta luego."
  fi
else
  warn "Stack $STACK_VPC no existe"
fi

# ── 6. Repos ECR ────────────────────────────────────────────────────────────
log ""
log "${AZUL}[5/7] Borrando repositorios ECR…${NC}"
for repo in "${ECR_REPOS[@]}"; do
  if aws ecr describe-repositories --repository-name "$repo" --region "$REGION" >/dev/null 2>&1; then
    aws ecr delete-repository --repository-name "$repo" --region "$REGION" --force >/dev/null 2>&1 && ok "$repo eliminado" || err "$repo: error al borrar"
  else
    warn "$repo ya no existía"
  fi
done

# ── 7. CloudWatch Log Groups + kubeconfig ───────────────────────────────────
log ""
log "${AZUL}[6/7] Borrando CloudWatch Log Groups del cluster…${NC}"
for lg in $(aws logs describe-log-groups --region "$REGION" \
    --query "logGroups[?contains(logGroupName, '/aws/eks/$CLUSTER_NAME')].logGroupName" --output text 2>/dev/null); do
  aws logs delete-log-group --log-group-name "$lg" --region "$REGION" >/dev/null 2>&1 && ok "log group borrado: $lg" || warn "no se pudo borrar $lg"
done

log ""
log "${AZUL}[7/7] Limpiando kubeconfig…${NC}"
CLUSTER_ARN="arn:aws:eks:$REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME"
kubectl config delete-context "$CLUSTER_ARN" >/dev/null 2>&1 || true
kubectl config delete-cluster "$CLUSTER_ARN" >/dev/null 2>&1 || true
kubectl config delete-user    "$CLUSTER_ARN" >/dev/null 2>&1 || true
ok "kubeconfig limpiado"

# ── Verificación ────────────────────────────────────────────────────────────
log ""
log "${AZUL}===== VERIFICACIÓN =====${NC}"
ERRORES=0
verify() { # nombre comando_que_devuelve_estado
  if eval "$2" >/dev/null 2>&1; then err "$1: aún existe"; ERRORES=$((ERRORES+1)); else ok "$1: eliminado"; fi
}
ST_EKS="$(aws cloudformation describe-stacks --stack-name "$STACK_EKS" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
[ -n "$ST_EKS" ] && { err "Stack $STACK_EKS: $ST_EKS"; ERRORES=$((ERRORES+1)); } || ok "Stack $STACK_EKS: eliminado"
ST_VPC="$(aws cloudformation describe-stacks --stack-name "$STACK_VPC" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
[ -n "$ST_VPC" ] && { err "Stack $STACK_VPC: $ST_VPC"; ERRORES=$((ERRORES+1)); } || ok "Stack $STACK_VPC: eliminado"
for repo in "${ECR_REPOS[@]}"; do
  verify "ECR $repo" "aws ecr describe-repositories --repository-name $repo --region $REGION"
done

echo ""
if [ "$ERRORES" -eq 0 ]; then
  log "${VERDE}LIMPIEZA COMPLETA — no deberían quedar recursos cobrables.${NC}"
else
  log "${AMAR}Limpieza terminada con $ERRORES pendiente(s). Revisa los mensajes y reintenta lo que falte.${NC}"
fi
log "${AZUL}============================================================${NC}"
echo ""
