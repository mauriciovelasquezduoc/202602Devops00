#!/usr/bin/env bash
# ==================================================================
# GUIA 04 / BLOQUE 01 - Infraestructura Kubernetes consolidada
# Crea/valida rapidamente la infra base de guia bloques 1, 2 y 3:
#   - VPC Multi-AZ + endpoints
#   - Cluster EKS + addons
#   - NodeGroup SPOT
#   - Metrics Server + CloudWatch logs
# Idempotente: si los recursos ya existen, valida y continua.
# ==================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUIA04_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT_DIR="$SCRIPT_DIR/reports"
REPORT_FILE="$REPORT_DIR/infra-k8s-$(date +%Y%m%d-%H%M%S).md"

REGION="${REGION:-us-east-1}"
VPC_STACK="${VPC_STACK:-laboratorio-ep02-vpc}"
EKS_STACK="${EKS_STACK:-laboratorio-ep02-eks}"
CLUSTER_NAME="${CLUSTER_NAME:-laboratorio-ep02-eks}"
NODEGROUP_NAME="${NODEGROUP_NAME:-laboratorio-ep02-nodegroup}"
VPC_TEMPLATE="$SCRIPT_DIR/templates/vpc.yaml"
EKS_TEMPLATE="$SCRIPT_DIR/templates/cluster_eks.yaml"
SECRETS_FILE="$GUIA04_DIR/secrets.txt"

mkdir -p "$REPORT_DIR"

REPORT_LINES=()
STEP_STATUS=()
REPORT_WRITTEN=false


log() { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] ADVERTENCIA: $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ERROR: $*"; exit 1; }

add_report() { REPORT_LINES+=("$*"); }
record_step() { STEP_STATUS+=("| $1 | $2 | $3 |"); }

command_exists() { command -v "$1" >/dev/null 2>&1; }

load_secrets_if_present() {
  if [ -f "$SECRETS_FILE" ]; then
    log "Cargando variables desde $SECRETS_FILE"
    while IFS='=' read -r key value || [ -n "$key" ]; do
      [ -z "${key:-}" ] && continue
      [[ "$key" == \#* ]] && continue
      export "$key=$value"
    done < "$SECRETS_FILE"

    # Compatibilidad con secrets.txt en minusculas.
    [ -n "${aws_access_key_id:-}" ] && export AWS_ACCESS_KEY_ID="$aws_access_key_id"
    [ -n "${aws_secret_access_key:-}" ] && export AWS_SECRET_ACCESS_KEY="$aws_secret_access_key"
    [ -n "${aws_session_token:-}" ] && export AWS_SESSION_TOKEN="$aws_session_token"
    [ -n "${AWS_REGION:-}" ] && export REGION="$AWS_REGION"
  fi
}

require_tools() {
  local missing=0
  for tool in aws kubectl; do
    if command_exists "$tool"; then
      log "Herramienta OK: $tool"
    else
      warn "Falta herramienta requerida: $tool"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || fail "Instala las herramientas faltantes antes de continuar."
}

aws_text() {
  aws "$@" --output text 2>/dev/null || true
}

stack_status() {
  aws_text cloudformation describe-stacks \
    --stack-name "$1" \
    --region "$REGION" \
    --query 'Stacks[0].StackStatus'
}

wait_stack_stable() {
  local stack="$1"
  local status=""
  log "Esperando stack estable: $stack"
  for _ in $(seq 1 90); do
    status="$(stack_status "$stack")"
    log "  $stack: ${status:-NO_EXISTE}"
    case "$status" in
      CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE|IMPORT_COMPLETE)
        return 0
        ;;
      *FAILED|ROLLBACK_COMPLETE|DELETE_COMPLETE|DELETE_IN_PROGRESS|ROLLBACK_IN_PROGRESS|UPDATE_ROLLBACK_IN_PROGRESS)
        return 1
        ;;
    esac
    sleep 20
  done
  return 1
}

stack_output() {
  local stack="$1"
  local key="$2"
  aws cloudformation describe-stacks \
    --stack-name "$stack" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$key'].OutputValue" \
    --output text
}

# Detecta estados terminales de fallo que impiden seguir (hay que borrar y recrear).
is_stack_failed() {
  case "${1:-}" in
    CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED|DELETE_FAILED|UPDATE_ROLLBACK_FAILED)
      return 0 ;;
    *) return 1 ;;
  esac
}

stack_exists() {
  [ -n "$(stack_status "$1")" ]
}

# Elimina un stack y espera a que termine la eliminacion.
delete_stack_wait() {
  local stack="$1"
  warn "Eliminando stack $stack para recrearlo..."
  aws cloudformation delete-stack --stack-name "$stack" --region "$REGION"
  if aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$REGION"; then
    log "Stack $stack eliminado."
  else
    warn "No se pudo confirmar la eliminacion de $stack (continuando)."
  fi
}

# Borra un stack si existe (para recrear siempre desde cero).
teardown_stack() {
  local stack="$1"
  if stack_exists "$stack"; then
    warn "Borrando stack existente: $stack"
    delete_stack_wait "$stack"
  else
    log "Stack $stack no existe (nada que borrar)."
  fi
}

# Borra ABSOLUTAMENTE TODO lo de la guia reutilizando aws-limpiar.sh, que borra
# en el orden correcto (namespace/ELBs -> EKS -> SGs k8s -> VPC -> ECR -> logs).
# Asi se evita el DELETE_FAILED de la VPC por ENIs/ELBs/SGs huerfanos.
limpieza_total() {
  local limpiar="$GUIA04_DIR/aws-limpiar.sh"
  if [ -f "$limpiar" ]; then
    log "Ejecutando limpieza total (aws-limpiar.sh)..."
    bash "$limpiar" -y || warn "aws-limpiar.sh termino con advertencias; se continua."
  else
    warn "No se encontro aws-limpiar.sh; se borran solo los stacks."
    teardown_stack "$EKS_STACK"
    teardown_stack "$VPC_STACK"
  fi
}

ensure_vpc_stack() {
  log "Validando/creando VPC CloudFormation: $VPC_STACK"
  [ -f "$VPC_TEMPLATE" ] || fail "No existe template VPC: $VPC_TEMPLATE"

  local before
  before="$(stack_status "$VPC_STACK")"
  if is_stack_failed "$before"; then
    warn "Stack VPC en estado fallido ($before). Se eliminara y recreara."
    delete_stack_wait "$VPC_STACK"
  elif [ -n "$before" ]; then
    log "Stack VPC ya existe con estado: $before (se validara/actualizara)."
  else
    log "Stack VPC no existe. Se creara."
  fi

  aws cloudformation deploy \
    --template-file "$VPC_TEMPLATE" \
    --stack-name "$VPC_STACK" \
    --region "$REGION" \
    --capabilities CAPABILITY_NAMED_IAM

  wait_stack_stable "$VPC_STACK" || fail "El stack VPC no quedo estable. Revisa CloudFormation."

  local vpc_id public_a public_b app_a app_b data_a data_b
  vpc_id="$(stack_output "$VPC_STACK" VpcId)"
  public_a="$(stack_output "$VPC_STACK" PublicSubnetA)"
  public_b="$(stack_output "$VPC_STACK" PublicSubnetB)"
  app_a="$(stack_output "$VPC_STACK" PrivateAppSubnetA)"
  app_b="$(stack_output "$VPC_STACK" PrivateAppSubnetB)"
  data_a="$(stack_output "$VPC_STACK" PrivateDataSubnetA)"
  data_b="$(stack_output "$VPC_STACK" PrivateDataSubnetB)"

  record_step "VPC" "OK" "Stack $VPC_STACK, VPC $vpc_id"
  add_report "### VPC"
  add_report "- Stack: \`$VPC_STACK\`"
  add_report "- VPC: \`$vpc_id\`"
  add_report "- Public subnets: \`$public_a\`, \`$public_b\`"
  add_report "- Private app subnets: \`$app_a\`, \`$app_b\`"
  add_report "- Private data subnets: \`$data_a\`, \`$data_b\`"
}

validate_subnet_tags() {
  log "Validando tags EKS en subnets"
  local vpc_id
  vpc_id="$(stack_output "$VPC_STACK" VpcId)"

  aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock,Tags[?Key==`Name`].Value|[0],Tags[?Key==`kubernetes.io/cluster/laboratorio-ep02-eks`].Value|[0],Tags[?Key==`kubernetes.io/role/elb`].Value|[0],Tags[?Key==`kubernetes.io/role/internal-elb`].Value|[0]]' \
    --output table

  record_step "Tags subnets" "OK" "Tags de LoadBalancer/EKS validados visualmente"
}

find_role_arn() {
  local pattern="$1"
  aws iam list-roles \
    --query "Roles[?contains(RoleName, '$pattern')].Arn | [0]" \
    --output text
}

# Despliega/actualiza el stack EKS con los parametros dados.
eks_stack_deploy() {
  aws cloudformation deploy \
    --template-file "$EKS_TEMPLATE" \
    --stack-name "$EKS_STACK" \
    --region "$REGION" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
      VPCId="$1" \
      PublicSubnetA="$2" \
      PublicSubnetB="$3" \
      PrivateAppSubnetA="$4" \
      PrivateAppSubnetB="$5" \
      EksClusterRoleArn="$6" \
      EksNodeRoleArn="$7"
}

ensure_eks_stack() {
  log "Validando/creando cluster EKS: $CLUSTER_NAME"
  [ -f "$EKS_TEMPLATE" ] || fail "No existe template EKS: $EKS_TEMPLATE"

  local vpc_id public_a public_b app_a app_b cluster_role node_role
  vpc_id="$(stack_output "$VPC_STACK" VpcId)"
  public_a="$(stack_output "$VPC_STACK" PublicSubnetA)"
  public_b="$(stack_output "$VPC_STACK" PublicSubnetB)"
  app_a="$(stack_output "$VPC_STACK" PrivateAppSubnetA)"
  app_b="$(stack_output "$VPC_STACK" PrivateAppSubnetB)"
  cluster_role="$(find_role_arn LabEksClusterRole)"
  node_role="$(find_role_arn LabEksNodeRole)"

  [ -n "$cluster_role" ] && [ "$cluster_role" != "None" ] || fail "No encontre rol IAM LabEksClusterRole"
  [ -n "$node_role" ] && [ "$node_role" != "None" ] || fail "No encontre rol IAM LabEksNodeRole"

  local before
  before="$(stack_status "$EKS_STACK")"
  if is_stack_failed "$before"; then
    warn "Stack EKS en estado fallido ($before). Se eliminara y recreara."
    delete_stack_wait "$EKS_STACK"
  elif [ -n "$before" ]; then
    log "Stack EKS ya existe con estado: $before (se validara/actualizara)."
  else
    log "Stack EKS no existe. Se creara. Puede tardar 15-25 minutos."
  fi

  # CloudFormation NO puede reemplazar un NodeGroup de EKS con el mismo nombre
  # in-place (AmiType, etc.): intenta crear el nuevo antes de borrar el viejo y
  # EKS responde 409 AlreadyExists. Si el deploy falla por eso, se borra y recrea.
  if ! eks_stack_deploy "$vpc_id" "$public_a" "$public_b" "$app_a" "$app_b" "$cluster_role" "$node_role"; then
    warn "El update del stack EKS fallo (reemplazo de NodeGroup no soportado in-place). Se borra y recrea el stack."
    delete_stack_wait "$EKS_STACK"
    eks_stack_deploy "$vpc_id" "$public_a" "$public_b" "$app_a" "$app_b" "$cluster_role" "$node_role" \
      || fail "No se pudo recrear el stack EKS."
  fi

  wait_stack_stable "$EKS_STACK" || fail "El stack EKS no quedo estable. Revisa CloudFormation."

  wait_cluster_active
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
  record_step "Cluster EKS" "OK" "Cluster $CLUSTER_NAME activo y kubeconfig actualizado"
  add_report "### EKS"
  add_report "- Stack: \`$EKS_STACK\`"
  add_report "- Cluster: \`$CLUSTER_NAME\`"
  add_report "- Cluster role: \`$cluster_role\`"
  add_report "- Node role: \`$node_role\`"
}

wait_cluster_active() {
  log "Esperando cluster EKS ACTIVE: $CLUSTER_NAME"
  for _ in $(seq 1 90); do
    local status
    status="$(aws_text eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query 'cluster.status')"
    log "  Cluster: ${status:-NO_EXISTE}"
    if [ "$status" = "ACTIVE" ]; then
      return 0
    fi
    sleep 20
  done
  fail "El cluster $CLUSTER_NAME no llego a ACTIVE."
}

ensure_nodegroup_active() {
  log "Validando NodeGroup: $NODEGROUP_NAME"
  for _ in $(seq 1 90); do
    local status
    status="$(aws_text eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" --region "$REGION" --query 'nodegroup.status')"
    log "  NodeGroup: ${status:-NO_EXISTE}"
    case "$status" in
      ACTIVE)
        record_step "NodeGroup" "OK" "$NODEGROUP_NAME ACTIVE"
        add_report "### NodeGroup"
        add_report "- Nombre: \`$NODEGROUP_NAME\`"
        add_report "- Estado: \`ACTIVE\`"
        return 0
        ;;
      CREATE_FAILED|DELETE_FAILED|DEGRADED)
        fail "NodeGroup en estado problematico: $status"
        ;;
    esac
    sleep 20
  done
  fail "El NodeGroup $NODEGROUP_NAME no llego a ACTIVE."
}

# Nombre del Auto Scaling Group asociado al NodeGroup (o vacio si no existe).
nodegroup_asg_name() {
  aws_text eks describe-nodegroup \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --region "$REGION" \
    --query 'nodegroup.resources.autoScalingGroups[0].name'
}

# Capacidad deseada actual del ASG del NodeGroup (vacio si no se puede leer).
nodegroup_asg_desired() {
  local asg="$1"
  [ -n "$asg" ] && [ "$asg" != "None" ] || return 0
  aws_text autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$asg" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].DesiredCapacity'
}

# El rol IAM de los nodos necesita 3 policies administradas. Si falta
# AmazonEKSWorkerNodePolicy el nodo no se registra; si falta AmazonEKS_CNI_Policy
# el nodo arranca pero nunca pasa a Ready (networking). Auto-corregimos.
NODE_ROLE_POLICIES=(
  "AmazonEKSWorkerNodePolicy"
  "AmazonEKS_CNI_Policy"
  "AmazonEC2ContainerRegistryReadOnly"
)

ensure_node_role_policies() {
  local role_arn role_name
  role_arn="$(aws_text eks describe-nodegroup \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --region "$REGION" \
    --query 'nodegroup.nodeRole')"

  if [ -z "$role_arn" ] || [ "$role_arn" = "None" ]; then
    warn "No pude obtener el rol IAM del NodeGroup; omito validacion de policies."
    return 0
  fi
  role_name="${role_arn##*/}"
  log "Validando policies del rol de nodo: $role_name"

  local attached missing=()
  attached="$(aws_text iam list-attached-role-policies \
    --role-name "$role_name" \
    --query 'AttachedPolicies[*].PolicyName')"

  local p
  for p in "${NODE_ROLE_POLICIES[@]}"; do
    printf '%s\n' "$attached" | tr '\t' '\n' | grep -qx "$p" || missing+=("$p")
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    log "  Rol de nodo OK (tiene las policies EKS requeridas)."
    record_step "Node role policies" "OK" "las 3 policies presentes"
    return 0
  fi

  warn "  Faltan policies en $role_name: ${missing[*]}"
  for p in "${missing[@]}"; do
    log "  Adjuntando arn:aws:iam::aws:policy/$p"
    aws iam attach-role-policy \
      --role-name "$role_name" \
      --policy-arn "arn:aws:iam::aws:policy/$p" >/dev/null 2>&1 \
      || warn "  No se pudo adjuntar $p (revisa permisos)."
  done
  record_step "Node role policies" "OK" "adjuntadas: ${missing[*]}"

  # Refrescar el aws-node para que tome la policy CNI recien adjuntada.
  kubectl -n kube-system rollout restart daemonset aws-node >/dev/null 2>&1 \
    || warn "  No pude reiniciar aws-node (quizas aun no existe)."
}

# Reconciliar el scaling del NodeGroup: CloudFormation NO reescala un stack
# existente, y AWS Academy puede dejar el ASG en 0 al detener el lab mientras
# el nodegroup conserva desiredSize=1. Actualizar al mismo valor es un no-op,
# asi que forzamos un ciclo 0 -> N para provocar que EKS lance instancias.
reconcile_nodegroup() {
  log "Asegurando que el NodeGroup tenga nodos (desired>=1): $NODEGROUP_NAME"
  local desired="${NODEGROUP_DESIRED:-1}"
  local min="${NODEGROUP_MIN:-1}"
  local max="${NODEGROUP_MAX:-3}"

  local asg asg_desired
  asg="$(nodegroup_asg_name)"
  asg_desired="$(nodegroup_asg_desired "$asg")"
  log "  ASG asociado: ${asg:-NO_DISPONIBLE} (capacidad deseada actual: ${asg_desired:-?})"

  # Si ya hay capacidad deseada suficiente, no reescalamos (evita recrear nodos sanos).
  if [[ "${asg_desired:-}" =~ ^[0-9]+$ ]] && [ "$asg_desired" -ge "$desired" ]; then
    log "  El NodeGroup ya tiene capacidad deseada >= $desired. No se reescala."
    record_step "NodeGroup scaling" "OK" "sin cambios (desired actual ${asg_desired})"
    return 0
  fi

  log "  Reciclando NodeGroup para lanzar nodos (desired 0 -> $desired)"
  aws eks update-nodegroup-config \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --region "$REGION" \
    --scaling-config minSize=0,maxSize="$max",desiredSize=0 \
    >/dev/null 2>&1 || warn "No se pudo aplicar desired=0 (continuando)."

  aws eks wait nodegroup-active \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --region "$REGION" 2>/dev/null || true

  aws eks update-nodegroup-config \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --region "$REGION" \
    --scaling-config minSize="$min",maxSize="$max",desiredSize="$desired" \
    >/dev/null 2>&1 || fail "No se pudo aplicar el scaling del NodeGroup."

  aws eks wait nodegroup-active \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --region "$REGION" 2>/dev/null || true

  record_step "NodeGroup scaling" "OK" "reciclado 0->$desired (min=$min max=$max)"
}

# Diagnostico rapido del NodeGroup/ASG para explicar por que no hay nodos.
log_nodegroup_diag() {
  local asg asg_info health
  asg="$(nodegroup_asg_name)"
  if [ -n "$asg" ] && [ "$asg" != "None" ]; then
    asg_info="$(aws_text autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$asg" \
      --region "$REGION" \
      --query 'AutoScalingGroups[0].[DesiredCapacity,MinSize,MaxSize,length(Instances)]')"
    log "  diag ASG: ${asg} (desired/min/max/instances: ${asg_info//$'\t'/,})"
  else
    log "  diag ASG: NO_DISPONIBLE"
  fi

  health="$(aws_text eks describe-nodegroup \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --region "$REGION" \
    --query 'nodegroup.health.issues[*].[code,message]')"
  if [ -n "$health" ] && [ "$health" != "None" ]; then
    warn "  diag health: $health"
  fi
}

# Explica por que un nodo ya registrado queda NotReady: condiciones + addon CNI.
log_node_not_ready_reason() {
  local name _ reason
  while read -r name _; do
    [ -n "${name:-}" ] || continue
    reason="$(kubectl get node "$name" \
      -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status} | {.reason}: {.message}{end}' \
      2>/dev/null)"
    log "  nodo $name => ${reason:-sin datos de condicion}"
  done < <(kubectl get nodes --no-headers 2>/dev/null)

  local cni coredns
  cni="$(kubectl -n kube-system get pods -l k8s-app=aws-node --no-headers 2>/dev/null \
    | tr -s ' ' | cut -d' ' -f1,3- | head -5)"
  [ -n "$cni" ] && log "  aws-node: $cni" || log "  aws-node: no encontrado"
  coredns="$(kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null \
    | tr -s ' ' | cut -d' ' -f1,3- | head -5)"
  [ -n "$coredns" ] && log "  coredns: $coredns"
}

# Estado de las instancias del NodeGroup en el ASG.
nodegroup_instances() {
  local asg="$1"
  [ -n "$asg" ] && [ "$asg" != "None" ] || return 0
  aws_text autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$asg" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus]'
}

# Vuelca la consola de arranque (cloud-init / nodeadm / kubelet) de cada instancia.
# Es donde aparece el error real cuando el nodo nunca se une al cluster.
dump_node_bootstrap_errors() {
  local asg inst iid
  asg="$(nodegroup_asg_name)"
  inst="$(nodegroup_instances "$asg")"
  if [ -z "$inst" ] || [ "$inst" = "None" ]; then
    warn "  No hay instancias en el ASG ${asg:-?}."
    return 0
  fi
  log "  Instancias del NodeGroup (InstanceId/LifecycleState/HealthStatus):"
  printf '%s\n' "$inst" | tr '\t' ' '

  while read -r iid _; do
    [ -n "${iid:-}" ] || continue
    log "  Consola de $iid (ultimas lineas de cloud-init/kubelet):"
    aws ec2 get-console-output --instance-id "$iid" --latest \
      --region "$REGION" --output text 2>/dev/null | tail -40 || true
  done < <(printf '%s\n' "$inst" | awk 'NF {print $1}')
}

# Revisa como autentican los nodos al cluster (access entries o aws-auth).
check_cluster_auth() {
  log "  Auth de nodos en el cluster:"
  local entries
  entries="$(aws_text eks list-access-entries --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'accessEntries')"
  if [ -n "$entries" ] && [ "$entries" != "None" ]; then
    log "    access entries: $entries"
  else
    log "    access entries: (ninguno)"
  fi
  if kubectl get configmap aws-auth -n kube-system >/dev/null 2>&1; then
    log "    aws-auth mapRoles:"
    kubectl -n kube-system get configmap aws-auth -o jsonpath='{.data.mapRoles}' 2>/dev/null | sed 's/^/      /'
    echo ""
  else
    log "    aws-auth: no existe (auth mode basado en API)"
  fi
}

# Recrea el stack EKS (cluster + NodeGroup + addons) cuando el NodeGroup queda
# inservible (nodos que nunca se unen, DEGRADED o estado fallido).
recreate_eks_stack() {
  log "Recreando stack EKS: $EKS_STACK"
  if stack_exists "$EKS_STACK"; then
    delete_stack_wait "$EKS_STACK"
  fi
  record_step "Recreacion EKS" "OK" "Stack $EKS_STACK eliminado y recreado"
  ensure_eks_stack
}

wait_nodes_ready() {
  log "Esperando al menos 1 nodo Ready en el cluster"
  local out registered ready
  for i in $(seq 1 90); do
    # OJO: usamos -o name y NO mezclamos stderr: "No resources found" va a stderr
    # y no debe contar como nodo.
    out="$(kubectl get nodes -o name 2>/dev/null || true)"
    registered="$(printf '%s\n' "$out" | grep -c '^node/' || true)"
    ready="$(kubectl get nodes --no-headers 2>/dev/null | grep -cE '[[:space:]]Ready[[:space:]]' || true)"
    log "  Nodos registrados: ${registered:-0} | Ready: ${ready:-0}"
    if [ "${ready:-0}" -ge 1 ]; then
      record_step "Nodos" "OK" "$ready nodo(s) Ready"
      add_report "### Nodos"
      add_report "- Nodos Ready: \`$ready\`"
      return 0
    fi
    # Cada ~2 minutos mostramos diagnostico del NodeGroup/ASG para entender por que no suben nodos.
    if [ $((i % 8)) -eq 0 ]; then
      log_nodegroup_diag
      if [ "${registered:-0}" -ge 1 ]; then
        log_node_not_ready_reason
      fi
    fi
    sleep 15
  done

  # Diagnostico final: mostrar el estado de nodos/pods/eventos antes de fallar.
  log "Diagnostico de nodos (kubectl get nodes -o wide):"
  kubectl get nodes -o wide 2>&1 || true
  log_node_not_ready_reason
  dump_node_bootstrap_errors
  check_cluster_auth
  log "Pods de kube-system:"
  kubectl -n kube-system get pods -o wide 2>&1 || true
  log "Eventos recientes del cluster:"
  kubectl get events -A --sort-by=.lastTimestamp 2>&1 | tail -20 || true
  warn "No hay nodos Ready en el cluster $CLUSTER_NAME."
  return 1
}

validate_kubernetes() {
  log "Validando Kubernetes"
  kubectl get nodes -o wide
  kubectl get pods -n kube-system -o wide
  record_step "Kubernetes" "OK" "Nodos y pods kube-system consultados"
}

validate_observability() {
  log "Validando observabilidad: metrics-server + CloudWatch"
  kubectl get apiservices | grep -E 'metrics|NAME' || true
  kubectl top nodes 2>/dev/null || warn "kubectl top nodes aun no entrega metricas; puede tardar unos minutos."
  aws logs describe-log-groups \
    --region "$REGION" \
    --query 'logGroups[?contains(logGroupName, `eks`)].logGroupName' \
    --output table 2>/dev/null || true

  record_step "Observabilidad" "OK" "Metrics Server/CloudWatch validados o en propagacion"
  add_report "### Observabilidad"
  add_report "- Metrics Server: addon EKS incluido en el template."
  add_report "- CloudWatch: logging EKS habilitado en el cluster."
}

write_report() {
  local account
  account="$(aws_text sts get-caller-identity --query Account)"

  {
    echo "# Reporte Infra K8s"
    echo ""
    echo "Generado: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "## Contexto"
    echo ""
    echo "- AWS Account: \`${account:-desconocida}\`"
    echo "- Region: \`$REGION\`"
    echo "- VPC Stack: \`$VPC_STACK\`"
    echo "- EKS Stack: \`$EKS_STACK\`"
    echo "- Cluster: \`$CLUSTER_NAME\`"
    echo "- NodeGroup: \`$NODEGROUP_NAME\`"
    echo ""
    echo "## Estado de pasos"
    echo ""
    echo "| Paso | Estado | Detalle |"
    echo "|---|---|---|"
    for line in "${STEP_STATUS[@]}"; do echo "$line"; done
    echo ""
    printf '%s\n' "${REPORT_LINES[@]}"
    echo ""
    echo "## Evidencia sugerida"
    echo ""
    echo '```bash'
    echo "aws cloudformation describe-stacks --region $REGION --stack-name $VPC_STACK --query 'Stacks[0].StackStatus' --output text"
    echo "aws cloudformation describe-stacks --region $REGION --stack-name $EKS_STACK --query 'Stacks[0].StackStatus' --output text"
    echo "aws eks describe-cluster --region $REGION --name $CLUSTER_NAME --query 'cluster.{name:name,status:status,version:version,endpoint:endpoint}' --output table"
    echo "aws eks describe-nodegroup --region $REGION --cluster-name $CLUSTER_NAME --nodegroup-name $NODEGROUP_NAME --query 'nodegroup.{name:nodegroupName,status:status,capacity:capacityType,desired:scalingConfig.desiredSize}' --output table"
    echo "kubectl get nodes -o wide"
    echo "kubectl get pods -n kube-system -o wide"
    echo "kubectl top nodes"
    echo '```'
  } > "$REPORT_FILE"

  REPORT_WRITTEN=true
  log "Reporte generado: $REPORT_FILE"
}

on_exit() {
  local code=$?
  if [ "$code" -ne 0 ] && [ "${REPORT_WRITTEN:-false}" != true ]; then
    STEP_STATUS+=("| Ejecucion | ERROR | Codigo de salida $code |")
    write_report >/dev/null 2>&1 || true
    echo "Reporte parcial: $REPORT_FILE"
  fi
}

trap on_exit EXIT

main() {
  echo "============================================================="
  echo " GUIA 04 - BLOQUE 01: Infraestructura Kubernetes consolidada"
  echo "============================================================="
  echo ""

  load_secrets_if_present
  require_tools

  log "Validando credenciales AWS"
  aws sts get-caller-identity >/dev/null || fail "AWS CLI no tiene credenciales validas."
  record_step "Credenciales AWS" "OK" "STS respondio correctamente"

  # Recrear SIEMPRE desde cero: se borra TODO lo existente antes de crear.
  # Se usa aws-limpiar.sh (namespace/ELBs -> EKS -> SGs -> VPC -> ECR -> logs)
  # para no quedar en loops con stacks en DELETE_FAILED/ROLLBACK_COMPLETE.
  log "Borrando infraestructura previa (si existe) para recrear desde cero..."
  limpieza_total

  ensure_vpc_stack
  validate_subnet_tags
  ensure_eks_stack
  ensure_nodegroup_active
  ensure_node_role_policies
  reconcile_nodegroup

  # Si el NodeGroup no logra nodos Ready, se borra y recrea el stack EKS y se
  # reintenta una sola vez (cubre clusters/NodeGroups en estado inservible).
  if ! wait_nodes_ready; then
    warn "El NodeGroup no logro nodos Ready. Se borrara y recreara el stack EKS."
    recreate_eks_stack
    ensure_nodegroup_active
    ensure_node_role_policies
    reconcile_nodegroup
    wait_nodes_ready || fail "No hay nodos Ready tras recrear. Revisa el SCP de AWS Academy o reinicia el lab (Start Lab)."
  fi

  validate_kubernetes
  validate_observability
  write_report

  echo ""
  echo "============================================================="
  echo " INFRA K8S LISTA"
  echo "============================================================="
  echo "Reporte: $REPORT_FILE"
  echo ""
}

main "$@"
