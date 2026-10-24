# Laboratorio Deploy a AWS

## Paso 01

Se debe crear un archivo llamado secrets.txt donde dejaremos todo lo ncesario para automatizar las distintas operaciones que realizaremos:

Archivo: secrets.txt

```
aws_access_key_id=
aws_secret_access_key=
aws_session_token=
WSAccountId=
SONAR_TOKEN=
SNYK_TOKEN=
AWS_REGION=us-east-1
GITHUB_TOKEN=
GITHUB_DATABASE=
GITHUB_BACKEND=
GITHUB_FRONTEND=
```

## Paso 02 Aplicación

Se debe seleccionar una aplicacion con tres capas se pueda utilizar para esta implementación, se puede utilizar este mismo codigo, ir a leer y aplicar el paso a paso que esta en

[README.d](bloque00-aplicacion/README.md)

## PASO 03 Maquina Ubuntu para operar con AWS

Se debe ingresar a Docker Desktop y luego entrar ejecutar una imagen de linux especialmente preparada:

Requisito previo

```bash
docker build -t devops-eks-lab .
```

Debes estar dentro del contenedor Docker `devops-eks-lab` con las credenciales de AWS Academy configuradas:

```bash
# Desde Windows PowerShell / CMD (fuera del contenedor):
docker run -it -v ".":/root/work -v ~/.aws:/root/.aws -v /var/run/docker.sock:/var/run/docker.sock devops-eks-lab
```



## Paso 04 creación de repositorios

Ahora, vamos a crear los repositorios de forma automatica en github

```
cd /root/work/bloque00-aplicacion
bash  crear_repos.sh
```

## Paso 04 Infra K8s

Ahora vamos. a crear la infra, que tiene vpc k8s y grupos, el paso a paso esta en

[README.MD](bloque01-infra-k8s/README.md)

## Paso 05 ECR

En el archivo bloque02-ecr/repositorios.yaml se debe poner el nombre del repo que tendra de la imagen, recopmendacion: dejar que comience con ep02- y asi mantener un patron que mas adelante se usara.

[README.md](bloque02-ecr/README.md)

## Paso 06 k8s

Ahora vamos aplicaremos las confiburaciones para todas las aplicaciones

Se debe cambiar los datos de donde estaran las imagens de ECR,  y eso se hace modificando este archivo : bloque03-k8s/values.yaml

[README.md](bloque03-k8s/README.md)

## Paso 07 github secret

Ahora este paso permite crear en forma automatica las variables necesarias para que opere el pipeline, los repositorios deben estar creados en github

[REAME.md](bloque04-github-secret/README.md)

## Paso 08 gihub repos

Ahora, vamos a ir a gihub y vamos a bajar cada proyecto, debe hacerse clone de cada proyecto

[README.md](bloque05-github-repos/README.md)

Para ver la solucion andando:

```
kubectl get svc ep02-frontend \
  -n ep02 \
  -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,CLUSTER-IP:.spec.clusterIP,EXTERNAL-HOST:.status.loadBalancer.ingress[0].hostname,PORT:.spec.ports[0].port
```
