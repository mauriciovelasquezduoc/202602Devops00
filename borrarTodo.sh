#!/bin/bash
# ==================================================================
# borrarTodo.sh — LIMPIEZA TOTAL del laboratorio
# ==================================================================
# Borra TODO lo creado en AWS (y opcionalmente GitHub + local):
#   - Namespace "ep02" (Pods, Services, Deployments, HPA)
#   - Load Balancers (ELB clásicos y v2/NLB) huérfanos en la VPC
#   - Security Groups k8s-* / eks-cluster-sg huérfanos
#   - Stack CloudFormation "laboratorio-ep02-eks" (cluster + nodegroup + addons)
#   - Stack CloudFormation "laboratorio-ep02-vpc" (VPC + subnets + endpoints)
#   - Repositorios ECR (todo lo que empiece con "ep02")
#   - CloudWatch Log Groups del cluster EKS
#   - Repositorios en GitHub con "ep02" en el nombre
#   - Contexto de kubeconfig + known_hosts de github.com
#
# CLAVE: los ELB y los SG k8s-* deben borrarse ANTES que la VPC; si no,
# CloudFormation falla con DELETE_FAILED (ENIs/SG en uso).
#
# Uso:
#   bash borrarTodo.sh          # pide confirmación
#   bash borrarTodo.sh -y       # sin confirmación
#
# Credenciales: se leen de ./secrets.txt (o del entorno).
# ==================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="$SCRIPT_DIR/secrets.txt"

REGION="us-east-1"
CLUSTER_NAME="laboratorio-ep02-eks"
NAMESPACE="ep02"
STACK_VPC="laboratorio-ep02-vpc"
STACK_EKS="laboratorio-ep02-eks"
NODEGROUP_NAME="laboratorio-ep02-nodegroup"
ECR_PREFIX="ep02"
GH_NAME_FILTER="ep02"

ROJO='\033[0;31m'; VERDE='\033[0;32m'; AMAR='\033[1;33m'; AZUL='\033[0;34m'; NC='\033[0m'
log()  { echo -e "$*"; }
ok()   { echo -e "  ${VERDE}OK  $*${NC}"; }
warn() { echo -e "  ${AMAR}$*${NC}"; }
err()  { echo -e "  ${ROJO}$*${NC}"; }

# ── Cargar credenciales de secrets.txt ──────────────────────────────────────
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

log ""
log "${AZUL}============================================================"
log " LIMPIEZA TOTAL DEL LABORATORIO"
log "============================================================${NC}"
log "${AMAR}⚠  ELIMINA en AWS: VPC, EKS, NodeGroup, ELBs, SGs, ECR, logs."
log "   y en GitHub: repos con '${GH_NAME_FILTER}'. NO se puede deshacer.${NC}"
log ""

if [ "${1:-}" != "-y" ] && [ "${1:-}" != "--yes" ]; then
  read -r -p "  ¿Continuar? (s/N): " CONFIRM
  [ "$CONFIRM" = "s" ] || [ "$CONFIRM" = "S" ] || { log "${ROJO}  Cancelado.${NC}"; exit 0; }
fi

# ── Helpers ─────────────────────────────────────────────────────────────────
stack_status() {
  aws cloudformation describe-stacks --stack-name "$1" --region "$REGION" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null || true
}

delete_cf_stack() {
  local stack="$1" tries=0 status
  status="$(stack_status "$stack")"
  if [ -z "$status" ]; then warn "Stack $stack no existe"; return 0; fi
  while :; do
    aws cloudformation delete-stack --stack-name "$stack" --region "$REGION" 2>/dev/null
    if aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$REGION" 2>/dev/null; then
      ok "Stack $stack eliminado"; return 0
    fi
    tries=$((tries + 1))
    status="$(stack_status "$stack")"
    warn "No se pudo borrar $stack (estado: ${status:-?}), intento $tries/3"
    [ "$tries" -ge 3 ] && return 1
    sleep 15
  done
}

# Borra ELBs (v2 + clásicos) y SGs k8s-* de la VPC (liberan ENIs/SGs que
# bloquean el borrado de la VPC).
purge_vpc_dependencies() {
  local vpc_id="$1"
  [ -n "$vpc_id" ] && [ "$vpc_id" != "None" ] || { warn "Sin VPC ID; salto purga"; return 0; }

  local arn lb sg
  for arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?VpcId=='$vpc_id'].LoadBalancerArn" --output text 2>/dev/null); do
    aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" >/dev/null 2>&1 \
      && ok "LBv2 borrado: $arn" || warn "no se pudo borrar $arn"
  done
  for lb in $(aws elb describe-load-balancers --region "$REGION" \
      --query "LoadBalancerDescriptions[?VPCId=='$vpc_id'].LoadBalancerName" --output text 2>/dev/null); do
    aws elb delete-load-balancer --load-balancer-name "$lb" --region "$REGION" >/dev/null 2>&1 \
      && ok "ELB clásico borrado: $lb" || warn "no se pudo borrar $lb"
  done
  warn "Esperando 30s a que se liberen las ENIs de los LB…"; sleep 30

  for sg in $(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=vpc-id,Values=$vpc_id" \
      --query "SecurityGroups[?GroupName!='default' && (starts_with(GroupName,'k8s-') || starts_with(GroupName,'eks-cluster-sg'))].GroupId" \
      --output text 2>/dev/null); do
    aws ec2 delete-security-group --group-id "$sg" --region "$REGION" >/dev/null 2>&1 \
      && ok "SG borrado: $sg" || warn "SG $sg en uso (se reintentará al borrar la VPC)"
  done
}

# ── 0. Conectividad AWS ─────────────────────────────────────────────────────
log "${AZUL}[0/10] Validando conectividad AWS…${NC}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [ -z "$ACCOUNT_ID" ]; then
  err "Sin conexión a AWS. Renueva credenciales (AWS Academy → Start Lab) y actualiza secrets.txt."
  exit 1
fi
ok "AWS OK — account=$ACCOUNT_ID region=$REGION"
log ""

# VPC ID (antes de borrar el stack)
VPC_ID="$(aws cloudformation describe-stacks --stack-name "$STACK_VPC" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text 2>/dev/null || true)"

# ── 1. kubeconfig + namespace ep02 ──────────────────────────────────────────
log "${AZUL}[1/10] Borrando namespace $NAMESPACE…${NC}"
CLUSTER_STATUS="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query 'cluster.status' --output text 2>/dev/null || echo NOEXISTE)"
if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
fi
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
log ""

# ── 2. Load Balancers + SGs huérfanos (antes de tocar VPC) ───────────────────
log "${AZUL}[2/10] Borrando ELBs y SGs k8s-* huérfanos en la VPC…${NC}"
if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  # La VPC pudo no existir aún; intentar recalcular
  VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=laboratorio-ep02" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
fi
purge_vpc_dependencies "${VPC_ID:-}"
log ""

# ── 3. Stack EKS (cluster + nodegroup + addons) ─────────────────────────────
log "${AZUL}[3/10] Borrando stack $STACK_EKS (10-15 min)…${NC}"
delete_cf_stack "$STACK_EKS" || err "El stack $STACK_EKS no se pudo eliminar (revisa eventos)"
log ""

# ── 4. Dependencias restantes de la VPC (SGs/ELBs que quedaron) ──────────────
log "${AZUL}[4/10] Purgando dependencias restantes de la VPC…${NC}"
purge_vpc_dependencies "${VPC_ID:-}"
log ""

# ── 5. Stack VPC ────────────────────────────────────────────────────────────
log "${AZUL}[5/10] Borrando stack $STACK_VPC…${NC}"
delete_cf_stack "$STACK_VPC" || err "El stack $STACK_VPC no se pudo eliminar (probable ENI/SG en uso; reintenta)"
log ""

# ── 6. Repositorios ECR (todo lo que empiece con 'ep02') ────────────────────
log "${AZUL}[6/10] Borrando repositorios ECR (prefijo '$ECR_PREFIX')…${NC}"
ECR_REPOS="$(aws ecr describe-repositories --region "$REGION" \
  --query "repositories[?starts_with(repositoryName, '$ECR_PREFIX')].repositoryName" --output text 2>/dev/null || true)"
if [ -n "$ECR_REPOS" ] && [ "$ECR_REPOS" != "None" ]; then
  for repo in $ECR_REPOS; do
    aws ecr delete-repository --repository-name "$repo" --region "$REGION" --force >/dev/null 2>&1 \
      && ok "$repo eliminado" || err "$repo: error al borrar"
  done
else
  warn "No hay repos ECR con prefijo '$ECR_PREFIX'"
fi
log ""

# ── 7. CloudWatch Log Groups del cluster ────────────────────────────────────
log "${AZUL}[7/10] Borrando CloudWatch Log Groups…${NC}"
LOG_GROUPS="$(aws logs describe-log-groups --region "$REGION" \
  --query "logGroups[?contains(logGroupName, '/aws/eks/$CLUSTER_NAME')].logGroupName" --output text 2>/dev/null || true)"
if [ -n "$LOG_GROUPS" ] && [ "$LOG_GROUPS" != "None" ]; then
  for lg in $LOG_GROUPS; do
    aws logs delete-log-group --log-group-name "$lg" --region "$REGION" >/dev/null 2>&1 \
      && ok "log group borrado: $lg" || warn "no se pudo borrar $lg"
  done
else
  warn "No hay log groups de $CLUSTER_NAME"
fi
log ""

# ── 8. Repositorios en GitHub (nombre contiene 'ep02') ──────────────────────
log "${AZUL}[8/10] Borrando repositorios GitHub (contienen '$GH_NAME_FILTER')…${NC}"
USER_GITHUB="$(gh api user --jq '.login' 2>/dev/null || echo "")"
if [ -n "$USER_GITHUB" ]; then
  log "  Usuario GitHub: $USER_GITHUB"
  GH_REPOS="$(gh repo list "$USER_GITHUB" --limit 300 --json name \
    --jq ".[] | select(.name | test(\"$GH_NAME_FILTER\"; \"i\")) | .name" 2>/dev/null || true)"
  if [ -n "$GH_REPOS" ]; then
    while read -r repo; do
      [ -n "$repo" ] || continue
      gh repo delete "$USER_GITHUB/$repo" --yes >/dev/null 2>&1 \
        && ok "$USER_GITHUB/$repo eliminado" || err "$USER_GITHUB/$repo: error al borrar"
    done <<< "$GH_REPOS"
  else
    warn "No hay repos con '$GH_NAME_FILTER'"
  fi
else
  warn "No se pudo obtener usuario GitHub (gh no autenticado). Se omite."
fi
log ""

# ── 9. Archivos locales generados ───────────────────────────────────────────
log "${AZUL}[9/10] Limpiando archivos locales generados…${NC}"
rm -f "$SCRIPT_DIR/bloque02-ecr/resultado-ecr.yaml" 2>/dev/null && ok "resultado-ecr.yaml eliminado" || true
rm -rf "$SCRIPT_DIR/bloque03-k8s/output" 2>/dev/null && ok "bloque03-k8s/output eliminado" || true
log ""

# ── 10. kubeconfig + known_hosts ────────────────────────────────────────────
log "${AZUL}[10/10] Limpiando kubeconfig y known_hosts…${NC}"
CLUSTER_ARN="arn:aws:eks:$REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME"
kubectl config delete-context "$CLUSTER_ARN" >/dev/null 2>&1 || true
kubectl config delete-cluster "$CLUSTER_ARN" >/dev/null 2>&1 || true
kubectl config delete-user    "$CLUSTER_ARN" >/dev/null 2>&1 || true
kubectl config unset "contexts.$CLUSTER_NAME" >/dev/null 2>&1 || true
kubectl config unset "clusters.$CLUSTER_NAME" >/dev/null 2>&1 || true
ok "kubeconfig limpiado"
ssh-keygen -R github.com >/dev/null 2>&1 || true
ok "known_hosts de github.com limpiado"
log ""

# ── Verificación ────────────────────────────────────────────────────────────
log "${AZUL}===== VERIFICACIÓN =====${NC}"
ERRORES=0
for stack in "$STACK_EKS" "$STACK_VPC"; do
  st="$(stack_status "$stack")"
  if [ -n "$st" ]; then err "Stack $stack: $st"; ERRORES=$((ERRORES + 1)); else ok "Stack $stack: eliminado"; fi
done
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  if aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$VPC_ID" >/dev/null 2>&1; then
    err "VPC $VPC_ID: aún existe"; ERRORES=$((ERRORES + 1))
  else
    ok "VPC: eliminada"
  fi
fi
REMAIN_ECR="$(aws ecr describe-repositories --region "$REGION" \
  --query "repositories[?starts_with(repositoryName, '$ECR_PREFIX')].repositoryName" --output text 2>/dev/null || true)"
if [ -n "$REMAIN_ECR" ] && [ "$REMAIN_ECR" != "None" ]; then
  err "ECR restantes: $REMAIN_ECR"; ERRORES=$((ERRORES + 1))
else
  ok "ECR: sin repos '$ECR_PREFIX*'"
fi

log ""
log "${AZUL}============================================================${NC}"
if [ "$ERRORES" -eq 0 ]; then
  log "${VERDE} LIMPIEZA COMPLETA — no deberían quedar recursos cobrables${NC}"
else
  log "${AMAR} Limpieza con $ERRORES pendiente(s). Revisa los mensajes y reintenta.${NC}"
fi
log "${AZUL}============================================================${NC}"
log ""
