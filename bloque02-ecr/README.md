# Guía ECR - Repositorios de Contenedores Docker

## Estructura del Proyecto

```
bloque02-ecr/
├── repositorios.yaml    # Configuración de repositorios
├── ejecutar-ecr.sh      # Script de gestión ECR
├── resultado-ecr.yaml   # Resultado generado (gitignore)
├── .gitignore           # Excluye archivos generados
└── README.md            # Esta documentación
```

## Configuración

Edita `repositorios.yaml` para agregar o modificar repositorios:

```yaml
REPOSITORIES:
  - Name: ep02-database
    Description: Repositorio para imagen de base de datos
    ImageTagMutability: MUTABLE
    ScanOnPush: false

  - Name: ep02-backend
    Description: Repositorio para imagen de backend Spring Boot
    ImageTagMutability: MUTABLE
    ScanOnPush: false

  - Name: ep02-frontend
    Description: Repositorio para imagen de frontend Nginx
    ImageTagMutability: MUTABLE
    ScanOnPush: false
```

## Uso

### Ejecutar script completo

```bash
cd /root/work/bloque02-ecr
./ejecutar-ecr.sh
```

El script realizará:

1. Identificar la cuenta AWS actual
2. Leer repositorios desde `repositorios.yaml`
3. Crear repositorios ECR (si no existen)
4. Listar todos los repositorios con sus URIs
5. Generar archivo `resultado-ecr.yaml` con los valores

## Proceso que realiza el script

### Paso 1: Identificación de cuenta AWS

```bash
aws sts get-caller-identity
```

Obtiene:

- Account ID (número de cuenta)
- ARN (identificador del usuario/rol)
- Región configurada

### Paso 2: Lectura de repositorios

Lee el archivo `repositorios.yaml` y extrae los nombres de los repositorios a crear.

### Paso 3: Creación de repositorios

```bash
aws ecr create-repository --repository-name <nombre>
```

Para cada repositorio:

- Verifica si ya existe
- Si no existe, lo crea con las configuraciones especificadas
- Si ya existe, muestra [EXISTENTE]

### Paso 4: Listado de repositorios

```bash
aws ecr describe-repositories
```

Muestra:

- Nombre del repositorio
- URI completa (para docker push)
- Fecha de creación

### Paso 5: Generación de archivo resultado

Genera `resultado-ecr.yaml` con:

- Información de la cuenta AWS
- URIs de cada repositorio
- Comandos para push de imágenes

## Diagrama de Flujo

```mermaid
flowchart TD
    A[Inicio] --> B[Leer repositorios.yaml]
    B --> C[Identificar cuenta AWS]
    C --> D{Repositorio existe?}
    D -->|Si| E[Mostrar EXISTENTE]
    D -->|No| F[Crear repositorio]
    F --> G[Mostrar CREADO]
    E --> H{Mas repositorios?}
    G --> H
    H -->|Si| D
    H -->|No| I[Listar repositorios]
    I --> J[Mostrar URIs]
    J --> K[Generar resultado-ecr.yaml]
    K --> L[Fin]
  
    style A fill:#FF9900,stroke:#FF9900,color:#000
    style F fill:#28a745,stroke:#28a745,color:#fff
    style E fill:#17a2b8,stroke:#17a2b8,color:#fff
    style J fill:#dc3545,stroke:#dc3545,color:#fff
    style K fill:#6f42c1,stroke:#6f42c1,color:#fff
```

## Diagrama de Arquitectura

```mermaid
graph TB
    subgraph Local["Desarrollo Local"]
        DEV[Desarrollador]
        CODE[Codigo Fuente]
    end
  
    subgraph ECR["AWS ECR"]
        DB_REPO[(ep02-database)]
        BE_REPO[(ep02-backend)]
        FE_REPO[(ep02-frontend)]
    end
  
    subgraph EKS["AWS EKS"]
        DB_POD[Database Pod]
        BE_POD[Backend Pod]
        FE_POD[Frontend Pod]
    end
  
    DEV -->|docker push| ECR
    ECR -->|docker pull| EKS
    CODE --> DEV
  
    style DB_REPO fill:#336791,stroke:#336791,color:#fff
    style BE_REPO fill:#28a745,stroke:#28a745,color:#fff
    style FE_REPO fill:#FF9900,stroke:#FF9900,color:#000
```

## Comandos Útiles de AWS ECR

```bash
# Listar repositorios
aws ecr describe-repositories --query 'repositories[*].repositoryName' --output table

# Obtener URI de un repositorio
aws ecr describe-repositories --repository-names ep02-backend --query 'repositories[0].repositoryUri' --output text

# Login a ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com

# Listar imagenes en un repositorio
aws ecr list-images --repository-name ep02-backend

# Eliminar repositorio
aws ecr delete-repository --repository-name ep02-backend --force
```

## Flujo de Trabajo Completo

```mermaid
sequenceDiagram
    participant D as Desarrollador
    participant L as Local
    participant ECR as AWS ECR
    participant EKS as AWS EKS

    D->>L: Desarrolla codigo
    L->>L: docker build
    L->>ECR: docker push
    ECR-->>L: Push completado
    EKS->>ECR: docker pull
    ECR-->>EKS: Imagen descargada
    EKS->>EKS: Despliega pod
    EKS-->>D: Aplicacion desplegada
```

## Ejemplo de resultado-ecr.yaml

```yaml
# resultado-ecr.yaml - Resultado de creacion de repositorios ECR

aws_account:
  account_id: "123456789012"
  account_alias: "mi-cuenta"
  region: "us-east-1"
  arn: "arn:aws:iam::123456789012:root"
  login_command: "aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-east-1.amazonaws.com"

repositories:
  - name: "ep02-database"
    uri: "123456789012.dkr.ecr.us-east-1.amazonaws.com/ep02-database"
    created_at: "2025-01-15T10:30:00Z"
    push_command: "docker tag ep02-database:latest 123456789012.dkr.ecr.us-east-1.amazonaws.com/ep02-database:latest && docker push 123456789012.dkr.ecr.us-east-1.amazonaws.com/ep02-database:latest"
  - name: "ep02-backend"
    uri: "123456789012.dkr.ecr.us-east-1.amazonaws.com/ep02-backend"
    created_at: "2025-01-15T10:30:05Z"
    push_command: "docker tag ep02-backend:latest 123456789012.dkr.ecr.us-east-1.amazonaws.com/ep02-backend:latest && docker push 123456789012.dkr.ecr.us-east-1.amazonaws.com/ep02-backend:latest"
  - name: "ep02-frontend"
    uri: "123456789012.dkr.ecr.us-east-1.amazonaws.com/ep02-frontend"
    created_at: "2025-01-15T10:30:10Z"
    push_command: "docker tag ep02-frontend:latest 123456789012.dkr.ecr.us-east-1.amazonaws.com/ep02-frontend:latest && docker push 123456789012.dkr.ecr.us-east-1.amazonaws.com/ep02-frontend:latest"
```

## Notas Importantes

- Los repositorios se crean en la región configurada en AWS CLI
- `ImageTagMutability: MUTABLE` permite sobreescribir tags como `latest`
- `ScanOnPush: false` desactiva el escaneo automático (reduce costos)
- Los repositorios vacíos no generan costos
- El script es idempotente: puede ejecutarse múltiples veces sin problemas
- El archivo `resultado-ecr.yaml` está en `.gitignore` (contiene datos sensibles)
