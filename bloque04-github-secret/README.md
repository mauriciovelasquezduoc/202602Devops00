# Configuración de Secrets en GitHub

## Prerrequisitos

Los repositorios de GitHub deben estar creados **antes** de ejecutar este script:

| Repositorio              | URL                                                  |
| ------------------------ | ---------------------------------------------------- |
| ep02_ing_devops_database | https://github.com/TUCUENTA/ep02_ing_devops_database |
| ep02_ing_devops_backend  | https://github.com/TUCUENTA/ep02_ing_devops_backend  |
| ep02_ing_devops_frontend | https://github.com/TUCUENTA/ep02_ing_devops_frontend |

Si aún no existen, crearlos ejecutando los comandos del README en `bloque00-aplicacion/`.

## Ejecutar el Script

```bash
cd /root/work/bloque04-github-secret
bash crear-actualizar-secrets.sh
```

## Qué hace el Script

1. Lee `../secrets.txt` con las credenciales AWS y tokens
2. Extrae los nombres de los repositorios (GITHUB_DATABASE, GITHUB_BACKEND, GITHUB_FRONTEND)
3. Se autentica en GitHub con GITHUB_TOKEN
4. Configura los secrets en cada repositorio:
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`
   - `AWS_SESSION_TOKEN`
   - `AWS_REGION`
   - `SONAR_TOKEN`
   - `SNYK_TOKEN`

## Archivo secrets.txt

Ubicación: `/guia-04/secrets.txt`

```
aws_access_key_id=ASIAXXXX
aws_secret_access_key=XXXX
aws_session_token=XXXX
SONAR_TOKEN=XXXX
SNYK_TOKEN=XXXX
AWS_REGION=us-east-1
GITHUB_TOKEN=ghp_XXXX
GITHUB_DATABASE=https://github.com/usuario/ep02_ing_devops_database.git
GITHUB_BACKEND=https://github.com/usuario/ep02_ing_devops_backend.git
GITHUB_FRONTEND=https://github.com/usuario/ep02_ing_devops_frontend.git
```

## Verificar Secrets Configurados

```bash
gh secret list --repo TUCUENTA/ep02_ing_devops_database
gh secret list --repo TUCUENTA/ep02_ing_devops_backend
gh secret list --repo TUCUENTA/ep02_ing_devops_frontend
```

## Solución de Problemas

### "Repositorio no encontrado"

- Verificar que el repositorio exista en GitHub
- Verificar que el nombre en `secrets.txt` sea correcto

### "Token inválido"

- Verificar que `GITHUB_TOKEN` en `secrets.txt` sea válido
- Generar nuevo token: https://github.com/settings/tokens

### "Permisos insuficientes"

- El token debe tener scope `repo` para configurar secrets
