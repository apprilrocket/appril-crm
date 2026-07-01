# Runbook · Unificar remitente a hola@appril.co (parte AWS)

> Objetivo: que el Lambda `appril-crm-sender` use **From `hola@appril.co`** y **Reply-To `hola@appril.co`** (hoy Reply-To es `mauricio@todoc.co`, dominio distinto).
> El `deploy:sender` **NO** sube envs (solo código), por eso esto se hace en AWS.
> El cambio de env es **inmediato** para nuevas invocaciones; no requiere redeploy de código.

## 0. Pre-requisitos
- Acceso a la consola AWS (o `aws` CLI configurado con permisos sobre Lambda/SES).
- Región: **us-east-1** (N. Virginia). La cuenta es `516426598004`.
- Confirmar que `hola@appril.co` es un buzón real que **recibe y monitoreás** (sí, confirmado).

## 1. Cambiar la env del Lambda (Reply-To)

### Opción A — Consola (recomendada, sin riesgo de borrar otras envs)
1. AWS Console → arriba a la derecha elegí región **N. Virginia (us-east-1)**.
2. **Lambda → Functions → `appril-crm-sender`**.
3. Pestaña **Configuration → Environment variables → Edit**.
4. Editá:
   - `SES_REPLY_TO` → **`hola@appril.co`** (estaba `mauricio@todoc.co`).
   - Confirmá que `SES_FROM_EMAIL` = **`hola@appril.co`**.
   - Confirmá que `SES_CONFIGURATION_SET` = `appril-crm`.
5. **Save**. Listo: aplica a los próximos envíos.

### Opción B — CLI (ojo: `update` reemplaza TODO el mapa de envs)
No edites con `--environment "Variables={...}"` a mano: si te olvidás una var, la borrás.
Hacelo así (lee las actuales, cambia solo Reply-To, reaplica todas):
```bash
REGION=us-east-1
FN=appril-crm-sender

# 1) Volcar envs actuales
aws lambda get-function-configuration --function-name $FN --region $REGION \
  --query 'Environment.Variables' --output json > /tmp/sender-env.json

# 2) Cambiar SES_REPLY_TO (y asegurar From) sin tocar el resto
jq '.SES_REPLY_TO="hola@appril.co" | .SES_FROM_EMAIL="hola@appril.co"' \
  /tmp/sender-env.json > /tmp/sender-env2.json

# 3) Construir el input y aplicar
jq -n --argjson v "$(cat /tmp/sender-env2.json)" '{Environment:{Variables:$v}}' > /tmp/update.json
aws lambda update-function-configuration --function-name $FN --region $REGION \
  --cli-input-json file:///tmp/update.json
```

## 2. Verificar el cambio
```bash
aws lambda get-function-configuration --function-name appril-crm-sender --region us-east-1 \
  --query 'Environment.Variables.{From:SES_FROM_EMAIL,ReplyTo:SES_REPLY_TO,ConfigSet:SES_CONFIGURATION_SET}'
```
Esperado:
```json
{ "From": "hola@appril.co", "ReplyTo": "hola@appril.co", "ConfigSet": "appril-crm" }
```

## 3. Confirmar identidad SES + autenticación de dominio (antes de blast)
```bash
# Identidad verificada (dominio y/o dirección)
aws ses get-identity-verification-attributes --identities appril.co hola@appril.co --region us-east-1

# DKIM (debe ser Success y los CNAME publicados en DNS)
aws ses get-identity-dkim-attributes --identities appril.co --region us-east-1
```
- **DKIM:** `DkimVerificationStatus: Success`.
- **SPF:** el TXT del dominio (o del MAIL FROM) debe incluir `include:amazonses.com`.
- **DMARC:** debe existir un TXT en `_dmarc.appril.co` (ej. `v=DMARC1; p=none; rua=mailto:...`).
- **Recepción:** `hola@appril.co` recibe vía el MX de `appril.co` (Google Workspace u otro). Esto es independiente de SES — solo asegurate de poder leer ese buzón.

## 4. Redeploy de las edge functions (lado Supabase, NO AWS)
Para que el **email de resultado** y el **inbox manual** también salgan de `hola@appril.co`:
```bash
# por tu canal Supabase habitual
supabase functions deploy send-discovery-email --project-ref hwiocriejizjdqqcfrsj
supabase functions deploy inbox-send --project-ref hwiocriejizjdqqcfrsj
```
(No hay overrides `DISCOVERY_FROM_EMAIL`/`INBOX_FROM_EMAIL` en Supabase — verificado — así que el nuevo default aplica solo.)

## 5. Prueba de humo
1. Enviar un correo de prueba a una dirección propia (cuando actives un envío controlado).
2. Verificar cabeceras: **From** y **Reply-To** = `hola@appril.co`.
3. **Responder** ese correo → debe llegar a la bandeja de `hola@appril.co`.
4. Click en "Cancelar suscripción" (footer) → página de confirmación; al confirmar, el lead queda `can_email=false`.

## Rollback
- Volver a poner `SES_REPLY_TO=mauricio@todoc.co` en la env del Lambda (Opción A/B).
- Las edge functions: redeploy de la versión anterior (o setear `DISCOVERY_FROM_EMAIL`/`INBOX_FROM_EMAIL` = `Appril <diagnostico@appril.co>` como override temporal).
