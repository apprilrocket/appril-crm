# Plan de consolidación WhatsApp/Email → Supabase (matar AWS)

> Estado: **Fases A, B, C y D COMPLETADAS** (decisión 2026-06-30: hacerlo bien, no rápido). Fases A–C el 2026-07-09; **el borrado definitivo de AWS (parte final de la Fase D) se EJECUTÓ el 2026-07-10**: 2 Lambdas, API Gateway `zkb9p2z5je`, regla EventBridge y rol IAM eliminados (verificado en vivo: 0 Lambdas, 0 API Gateways, 0 reglas, rol `NoSuchEntity`). SES y el topic SNS `ses-events-appril-crm` intactos. **Todo el ecosistema corre sin AWS.** Única cola abierta: la **rotación del `SUPABASE_SERVICE_ROLE_KEY` y del `WA_ACCESS_TOKEN`** que vivieron en las Lambdas (riesgo A5 cerrado en infra al borrar; rotación pendiente, de Mauricio — ver `SECURITY-ROTATION.md`).
> Contexto: ver memoria `whatsapp-inbound-architecture.md`.
>
> **Re-verificación 2026-07-12 (AWS CLI + Supabase MCP):** Lambda `appril-crm-sender`
> confirmado inexistente (`ResourceNotFoundException`, sin reglas EventBridge); Edge
> `queue-sender` **v4 ACTIVE** drenando vía pg_cron `queue-sender-tick` (*/2); Edge
> `ses-webhook` **v2 ACTIVE**. ⚠️ **Salvedad de la Fase C**: `webhook_events` estaba
> VACÍA de eventos SES al 12-jul — el cableado SNS→`ses-webhook` en prod NO está
> confirmado funcionando (la paridad 1:1 del 9-jul fue con correos de prueba durante la
> convivencia). Cerrar enviando un email real por `queue-sender` y viendo aterrizar su
> evento SES.

## 1. Arquitectura actual (post-Fases A–D, 2026-07-09)

```
NÚMERO COMERCIAL (+57 311 2211772, phone_id 928845203654774, WABA 1446010070564033)
  Meta lo entrega a UNA sola app de Appril (la "Appril CRM" 1715144349475123 fue
  DES-SUSCRITA el 2026-07-09 vía Graph API DELETE subscribed_apps → {"success":true}):
    · App "Appril" (1904313610456059) → appril-web/whatsapp-webhook (ROUTER ÚNICO, v49)
          └─ si phone_id == comercial → reenvía FIRMADO a CRM_WEBHOOK_URL:
                · HMAC-SHA256 del cuerpo crudo en header `x-crm-signature`
                  (secret compartido CRM_FORWARD_SECRET, en AMBOS proyectos Supabase)
                · header `x-meta-signature-valid` con el veredicto de la validación
                  de Meta hecha en el router
             → whatsapp-agent edge (hwiocriejizjdqqcfrsj) v54+ (commit 1dc4855):
                acepta firma de Meta O firma del forward; WA_HMAC_ENFORCE=true
  ⚠️ HALLAZGO PENDIENTE: en la misma WABA siguen suscritas DOS apps de tyntec
  (BSP anterior): "tyntec - Cloud API Messaging" 390646749558811 y
  "tyntec onboarding" 198334567771449 — quitarlas requiere business.facebook.com
  (WhatsApp Manager → WABA → apps conectadas). Ver SECURITY-ROTATION.md raíz.

NÚMERO DE PACIENTES (distinto) → App "Appril" → appril-web/whatsapp-agent (producto). Intacto.

OUTBOUND (post-Fase B): CRM → message_queue → pg_cron `queue-sender-tick` (cada 2 min)
  → invoke_queue_sender() → Edge `queue-sender` (hwiocriejizjdqqcfrsj) → SES / WA Cloud API.
EMAIL EVENTS (post-Fase C): SES → SNS topic `ses-events-appril-crm` → Edge `ses-webhook`
  (hwiocriejizjdqqcfrsj, modo `live`, firma SNS verificada) → lead_events + flags en leads_master.
  El Lambda `appril-crm-webhook` fue DES-SUSCRITO del topic; la Edge es el único suscriptor.
AWS (post-Fase D, borrado 2026-07-10): 2 Lambdas + API Gateway zkb9p2z5je + regla
  EventBridge appril-crm-sender-cron + rol IAM appril-crm-lambda-role = TODO BORRADO
  (verificado: 0 Lambdas, 0 API GW, 0 reglas, rol NoSuchEntity). SES + topic SNS intactos.
  Respaldo/reversa (restaurar desde cero) en `appril-sender/aws-backup/`.
  Pendiente: rotar SUPABASE_SERVICE_ROLE_KEY + revocar WA_ACCESS_TOKEN expuesto (A5).
```

## 2. El fix aplicado (y cómo hacerlo permanente)

- **Aplicado:** secret `CRM_WEBHOOK_URL = https://hwiocriejizjdqqcfrsj.supabase.co/functions/v1/whatsapp-agent` en el proyecto appril-web (`gfpdrqqsaqifyepvmwpt`), vía `supabase secrets set`. Reversible borrándolo.
- **Verificado:** agente conversa multi-turno; inbound 100% estructurado, 0 `wa_reply` crudos del Lambda.
- **RESUELTO EN CÓDIGO (commit `c0dbfee8`, router v50, pusheado):** el default hardcodeado de `CRM_WEBHOOK_URL` en `appril-web/supabase/functions/whatsapp-webhook/index.ts` ya no apunta al API Gateway muerto sino al agente del CRM. Era una mina: si el secret faltara, el inbound comercial se perdía EN SILENCIO (`waitUntil` + 200 OK a Meta, sin reintento). Validado con conversación real (4 mensajes/4 respuestas; el agente cita precios en COP desde `fx_rates`).

## 3. Duplicación de statuses (cosmética) — RESUELTA con la Fase A

El comercial llegaba al agente por 2 apps → los `wa_sent/delivered/read/failed` se insertaban 2x (sin daño: no hay índice único en statuses; el inbound sí deduplica por `wa_message_id`). **Desapareció al retirar la app redundante (Fase A, 2026-07-09)** — verificado en la conversación de validación: statuses sin duplicar.

## 4. Plan por fases (ejecutar con QA, no a las carreras)

### Fase A — Un solo camino de inbound ✅ EJECUTADA Y VALIDADA (2026-07-09, noche)
1. ✅ Reenvío firmado desplegado ANTES del flip: router `whatsapp-webhook` **v49** (appril-web, commit local `53c55e3f`, aún SIN push) firma el cuerpo crudo con HMAC-SHA256 (`x-crm-signature`, secret compartido `CRM_FORWARD_SECRET` seteado en ambos proyectos Supabase) + `x-meta-signature-valid`; agente CRM **v54+** (commit `1dc4855`, pusheado) valida firma de Meta O firma del forward.
2. ✅ App **"Appril CRM" (1715144349475123)** DES-SUSCRITA de la WABA `1446010070564033` vía Graph API `DELETE .../subscribed_apps` → `{"success":true}`. appril-web (1904) es ahora **router único**: comercial→agente CRM, pacientes→patient-agent.
3. ✅ Validado con conversación real post-flip (21:37–21:39 UTC): 3 mensajes + respuestas + statuses **sin duplicar**.
4. ✅ Flags de enforce ENCENDIDOS y probados: `WA_HMAC_ENFORCE=true` (POST sin firma → 401, canario `?health=1` OK) y `DEMO_CALLBACK_ENFORCE=true` (POST sin secret → 401).
- **Rollback documentado:** `POST` a la misma URL de Graph (`/{waba_id}/subscribed_apps` con token de la app 1715) re-suscribe.

### Fase B — Sender de campañas a Supabase ✅ EJECUTADA Y ACTIVA (2026-07-09, noche)
1. ✅ Edge `queue-sender` desplegada (commit `5b11f81`): puerto **fiel** de la Lambda `appril-crm-sender` — verificado byte a byte que `appril-sender/src/` ES lo desplegado (CodeSha256 del zip = ambas Lambdas) antes de portar. Mismo SELECT, backoff lineal `attempt×5min`, `message_attempts`, `lead_events`, `ses_message_id`/`wa_message_id` (el webhook correlaciona igual), MIME crudo con List-Unsubscribe + RFC 8058 + configuration set.
2. ✅ **Mejora deliberada — mata de raíz el bug "stuck in sending"**: claim ATÓMICO vía `queue_claim_batch` (FOR UPDATE SKIP LOCKED) en vez de marcar el lote antes de procesar; `queue_recover_stuck` con umbral temporal real (`claimed_at`). Migración `20260709_2400_queue_atomic_claim.sql` (aplicada en prod).
3. ✅ Disparo por pg_cron `queue-sender-tick` (cada 2 min) → `invoke_queue_sender()` (secret en `app_config.queue_sender_cron_secret`; **modo `live` explícito en el body — el default de la función es `shadow`**, red de seguridad). Migración `20260710_0010_invoke_queue_sender_cron.sql` (aplicada en prod).
4. ✅ **FLIP ejecutado** (commit `1712d82`): EventBridge `appril-crm-sender-cron` **DISABLED** primero, cron después (Lambda y Edge NO deben drenar a la vez — el Lambda no usa el claim atómico). El código del Lambda sigue en AWS como reversa.
- **Validado en prod:** sombra (claim→pending sin enviar) · email live end-to-end (sent → SES → webhook correlacionó `email_delivered`+`email_opened`) · WA live (Meta aceptó con `wamid`; la entrega falló por `131049` = límite de frecuencia de marketing al número de prueba — NO es bug; el ciclo de statuses post-Fase A corrió completo: Meta → router firmado → agente → cola marcada) · primer tick del cron drenó una fila real.
- **Vigilancia:** el watchdog `agent_health_scan` (`queue_stuck`/`queue_overdue`) vigila al drenador nuevo sin cambios.
- **Hallazgo colateral (deuda de datos, no de la Fase B):** el template `alerta_interna_wa` (`wa_template_name` `appril_alerta_crm`) está desajustado — Meta espera parámetros en el body pero el registro dice `variables: []` y no tiene `wa_components` → todo envío con payload vacío falla con `132000` (le pasaba igual al Lambda). Corregir el registro o la plantilla en Meta.
- **Rollback:** `cron.unschedule('queue-sender-tick')` + `aws events enable-rule appril-crm-sender-cron`.

### Fase C — Eventos SES a Supabase ✅ EJECUTADA Y ACTIVA (2026-07-09, modo `live`)
1. ✅ Edge `ses-webhook` desplegada (commits `93b1eec` sombra + `13c4662` live): porta `appril-sender/src/webhook.ts handleSes` (SubscriptionConfirmation + Notification → `lead_events` + flags en `leads_master`), correlación por `ses_message_id`, mismo mapa de eventos y atribución (`campaign_id`+`template_key`).
2. ✅ El Lambda `appril-crm-webhook` fue **DES-SUSCRITO** del topic `ses-events-appril-crm`; la Edge es el **único suscriptor**. Validado: paridad 1:1 (delivered+opened, correlación por `ses_message_id`).
3. ✅ **La Fase C cerró DOS vulnerabilidades reales del Lambda**, que no validaba nada: (a) **sin verificación de firma SNS** → un POST forjado con Complaint/Bounce ponía `can_email=false` en leads arbitrarios (destrucción de audiencia); (b) **SSRF**: `fetch(SubscribeURL)` a cualquier URL. La Edge verifica firma RSA contra el certificado de AWS (X.509→SPKI, SHA-1/SHA-256 según `SignatureVersion`), restringe `SigningCertURL`/`SubscribeURL` a `sns.<region>.amazonaws.com` y valida `TopicArn`. Probado: POST forjados → 403; suscripción SNS real confirmada (la firma legítima valida).
- **Rollback:** repuntar SNS de vuelta al Lambda (sacar concurrencia 0) y re-suscribir.

### Fase D — Apagar AWS ✅ COMPLETADA · apagado 2026-07-09 → BORRADO 2026-07-10
1. ✅ Respaldo completo en `appril-sender/aws-backup/` (commits `bdd52de`/`ba8820d`/`3ba6f0f`): zips con sha256 verificado contra `CodeSha256`, configs SIN valores de env vars, rutas API GW, targets EventBridge, políticas IAM, runbook de restauración. **Es ahora la única copia de esa infra.**
2. ✅ Fase de apagado (2026-07-09): ambas Lambdas con `reserved-concurrent-executions=0`; EventBridge DISABLED. Validado con las Lambdas apagadas: correo real por `queue-sender` → SES → `ses-webhook` escribió delivered+opened; 0 invocaciones y 0 throttles durante 24h.
3. ✅ **BORRADO DEFINITIVO EJECUTADO Y VERIFICADO EN VIVO (2026-07-10):** eliminados las 2 Lambdas (`appril-crm-sender`, `appril-crm-webhook`), el API Gateway `zkb9p2z5je`, la regla EventBridge `appril-crm-sender-cron` y el rol IAM `appril-crm-lambda-role`. Verificación: **0 Lambdas, 0 API Gateways, 0 reglas, rol `NoSuchEntity`.** El ecosistema corre sin AWS: pg_cron `queue-sender-tick` activo, último envío OK, cola sin atascos.
   - **Investigación previa (informe AWS del dueño):** los 4 hits del `appril-crm-webhook` en 24h eran los **correos de prueba de las Fases B/C** llegando vía la suscripción SNS del Lambda durante la convivencia con la Edge — benignos, NO un tercero; pararon al des-suscribir el Lambda del topic.
4. ⏳ **Pendiente (riesgo A5, de Mauricio — consolas web):** con las Lambdas borradas desapareció la copia del `SUPABASE_SERVICE_ROLE_KEY` y del `WA_ACCESS_TOKEN` que vivían fuera de Supabase (riesgo A5 **cerrado a nivel de infra**). La **rotación** sigue pendiente: R1 rotar service_role del CRM + deshabilitar legacy JWT keys; R2 revocar el token WA expuesto `EAAYX6imwYTMBR...`; R3 quitar las 2 apps de tyntec de la WABA. Consumidores del service_role a actualizar: `appril-crm/mcp/.env`, dashboard en Vercel (`src/lib/supabase/admin.ts`), scripts locales. Detalle en `SECURITY-ROTATION.md`.
- **Aclaración:** SES NO se apagó — sigue siendo el proveedor de email, invocado desde `queue-sender` con las credenciales que ya viven en secrets de Supabase. El topic SNS `ses-events-appril-crm` tampoco se borró (apunta a `ses-webhook`). En la cuenta AWS hay otros recursos ajenos a Appril (FALLA_EMAIL, NotificacionCita, cola SEND_MAIL) que NO se tocaron.
- Resultado: **todo en Supabase**, sin llave maestra fuera de Supabase una vez rotada.

## 5. Lo que NO se toca en ninguna fase
- El **agente de pacientes** (appril-web, número distinto).
- El **número de pacientes** y su flujo (confirmaciones, NPS, referidos).

## 6. Checklist de verificación por fase
- [x] Inbound comercial sigue respondiendo (verificado post-Fase A con conversación real, 2026-07-09 21:37–21:39 UTC).
- [x] Statuses se registran 1x tras Fase A (verificado en la misma conversación).
- [x] Campañas se envían (Fase B): `message_queue` drena por la Edge `queue-sender`, `message_attempts` y `lead_events` verificados (email E2E; WA aceptado por Meta con `wamid`, entrega limitada por `131049` al número de prueba — no bug). 2026-07-09.
- [x] Eventos SES llegan (Fase C): `email_delivered/opened` correlacionados 1:1 por la Edge `ses-webhook` en `live`; POST forjados rechazados con 403. 2026-07-09.
- [x] AWS apagado sin pérdida de tráfico (Fase D): correo E2E con las Lambdas en concurrencia 0; 0 invocaciones/0 throttles. 2026-07-09.
- [x] AWS BORRADO por completo (Fase D final): 0 Lambdas, 0 API Gateways, 0 reglas EventBridge, rol IAM `NoSuchEntity`; ecosistema corriendo sin AWS (pg_cron activo, cola sin atascos). 2026-07-10.
- [x] Agente de pacientes intacto en cada fase (número distinto, nunca tocado).
