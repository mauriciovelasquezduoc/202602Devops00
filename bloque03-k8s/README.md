# Guía Kubernetes - Arquitectura de Microservicios

## Estructura del Proyecto

```
bloque02-k8s/
├── values.yaml              # Configuración centralizada
├── templates/               # Plantillas YAML con variables
│   ├── namespace.yaml
│   ├── database-secret.yaml
│   ├── database-deployment.yaml
│   ├── database-service.yaml
│   ├── backend-deployment.yaml
│   ├── backend-service.yaml
│   ├── frontend-deployment.yaml
│   ├── frontend-service.yaml
│   ├── backend-hpa.yaml
│   └── frontend-hpa.yaml
├── output/                  # YAMLs generados (gitignore)
├── apply-all.sh             # Genera y aplica
├── generate.sh              # Solo genera YAMLs
└── preview.sh               # Preview sin aplicar
```

## Configuración Centralizada

Edita `values.yaml` para cambiar cualquier parámetro:

```bash
# Namespace
NAMESPACE=ep02

# Imágenes
DATABASE_IMAGE=461663648686.dkr.ecr.us-east-1.amazonaws.com/ep02-db:latest
BACKEND_IMAGE=461663648686.dkr.ecr.us-east-1.amazonaws.com/ep02-backend:latest
FRONTEND_IMAGE=461663648686.dkr.ecr.us-east-1.amazonaws.com/ep02-frontend:latest

# Base de datos
DATABASE_NAME=ep02
DATABASE_USER=ep02_user
DATABASE_PASSWORD_B64=YWx1bW5vc19wYXNz

# Backend
BACKEND_HPA_MIN=1
BACKEND_HPA_MAX=10
BACKEND_HPA_CPU=70

# Frontend
FRONTEND_HPA_MIN=2
FRONTEND_HPA_MAX=6
FRONTEND_HPA_CPU=60
```

## Scripts Disponibles

### `apply-all.sh` - Generar y aplicar

```bash
cd /root/work/bloque03-k8s
./apply-all.sh
```

1. Lee `values.yaml`
2. Genera YAMLs en `output/`
3. Aplica todos los manifiestos a Kubernetes

### `generate.sh` - Solo generar

```bash
./generate.sh
```

Genera los YAMLs sin aplicarlos (útil para inspeccionar).

### `preview.sh` - Preview

```bash
./preview.sh
```

Genera y muestra los archivos generados.

## Comandos Explicados

### 1. Namespace

Crea el namespace aislado para todos los recursos del proyecto.

### 2. Secret

Almacena credenciales en base64 para la base de datos.

### 3. Base de Datos

- **Deployment**: PostgreSQL con health checks TCP
- **Service**: ClusterIP interno `ep02-db:5432`

### 4. Backend

- **Deployment**: Spring Boot con métricas para HPA
- **Service**: ClusterIP interno `ep02-backend:8080`

### 5. Frontend

- **Deployment**: Nginx con RollingUpdate
- **Service**: Load Balancer público AWS

### 6. HPA

Escalado automático basado en CPU:

- Backend: 1-10 réplicas (70% CPU)
- Frontend: 2-6 réplicas (60% CPU)

## Diagrama de Arquitectura

```mermaid
graph TB
    subgraph Internet
        User([Usuario])
    end

    subgraph AWS["AWS EKS Cluster - Namespace: ep02"]
        subgraph Public["Red Pública"]
            LB[Load Balancer<br/>:80]
        end

        subgraph Private["Red Privada"]
            subgraph FrontendTier["Frontend Tier"]
                FE1[Frontend Pod 1<br/>Nginx :80]
                FE2[Frontend Pod 2<br/>Nginx :80]
                HPA_FE[HPA Frontend<br/>2-6 réplicas<br/>60% CPU]
            end

            subgraph BackendTier["Backend Tier"]
                BE1[Backend Pod 1<br/>Spring Boot :8080]
                BE2[Backend Pod N<br/>Spring Boot :8080]
                HPA_BE[HPA Backend<br/>1-10 réplicas<br/>70% CPU]
            end

            subgraph DataTier["Data Tier"]
                DB[(Database<br/>PostgreSQL :5432)]
                Secret[Secret<br/>database-secret]
            end
        end
    end

    User -->|HTTP| LB
    LB --> FE1 & FE2
    FE1 & FE2 -->|API REST| BE1 & BE2
    BE1 & BE2 -->|SQL| DB
    DB -.->|lee credenciales| Secret
  
    HPA_BE -.->|escala| BE1 & BE2
    HPA_FE -.->|escala| FE1 & FE2

    style LB fill:#FF9900,stroke:#FF9900,color:#000
    style DB fill:#336791,stroke:#336791,color:#fff
    style Secret fill:#dc3545,stroke:#dc3545,color:#fff
    style HPA_BE fill:#28a745,stroke:#28a745,color:#fff
    style HPA_FE fill:#28a745,stroke:#28a745,color:#fff
```

## Flujo de Datos

```mermaid
sequenceDiagram
    participant U as Usuario
    participant LB as Load Balancer
    participant FE as Frontend
    participant BE as Backend
    participant DB as Database

    U->>LB: HTTP Request
    LB->>FE: Distribuye carga
    FE->>BE: API REST (JSON)
    BE->>DB: SQL Query
    DB-->>BE: Resultados
    BE-->>FE: JSON Response
    FE-->>U: HTML/CSS/JS
```

## Flujo de Generación

```mermaid
flowchart LR
    A[values.yaml] --> B[envsubst]
    C[templates/*.yaml] --> B
    B --> D[output/*.yaml]
    D --> E[kubectl apply]
  
    style A fill:#FF9900,stroke:#FF9900,color:#000
    style C fill:#336791,stroke:#336791,color:#fff
    style D fill:#28a745,stroke:#28a745,color:#fff
    style E fill:#dc3545,stroke:#dc3545,color:#fff
```

## Comandos Útiles

```bash
# Verificar estado
kubectl get all -n ep02

# Ver pods
kubectl get pods -n ep02 -o wide

# Ver HPA
kubectl get hpa -n ep02

# Logs
kubectl logs -f <pod-name> -n ep02

# Shell en pod
kubectl exec -it <pod-name> -n ep02 -- /bin/bash
```

## Notas Importantes

- Edita `values.yaml` para cambiar configuración
- Los templates usan variables `${VAR}` con envsubst
- El directorio `output/` contiene los YAMLs generados
- Las imágenes están en ECR privado de AWS
- Los HPA requieren Metrics Server
