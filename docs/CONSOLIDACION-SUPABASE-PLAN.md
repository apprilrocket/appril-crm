# Plan de consolidación WhatsApp/Email → Supabase (matar AWS)

> Estado: **Fases A y B EJECUTADAS y validadas el 2026-07-09 (noche). Fases C–D pendientes** (decisión 2026-06-30: hacerlo bien, no rápido).
> Contexto: ver memoria `whatsapp-inbound-architecture.md`.

## 1. Arquitectura actual (post-Fases A y B, 2026-07-09)

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
  El Lambda appril-crm-sender está APAGADO como drenador (EventBridge
  `appril-crm-sender-cron` DISABLED); su código sigue en AWS solo como reversa.
EMAIL EVENTS: SES → SNS → Lambda appril-crm-webhook /webhook/ses → lead_events. (Fase C pendiente.)
```

## 2. El fix aplicado (y cómo hacerlo permanente)

- **Aplicado:** secret `CRM_WEBHOOK_URL = https://hwiocriejizjdqqcfrsj.supabase.co/functions/v1/whatsapp-agent` en el proyecto appril-web (`gfpdrqqsaqifyepvmwpt`), vía `supabase secrets set`. Reversible borrándolo.
- **Verificado:** agente conversa multi-turno; inbound 100% estructurado, 0 `wa_reply` crudos del Lambda.
- **Pendiente para hacerlo permanente en código** (no urgente, el secret es durable): cambiar el default hardcodeado en `appril-web/supabase/functions/whatsapp-webhook/index.ts` (línea ~45) de la URL del Lambda a la del agente. ⚠️ NO desplegar appril-web hasta resolver su `main` sucio (tiene cambios de producto sin commit).

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

### Fase C — Eventos SES a Supabase (pendiente)
1. Edge `ses-events` que porte `appril-sender/src/webhook.ts handleSes` (SubscriptionConfirmation + Notification → lead_events + flags en leads_master).
2. Repuntar la suscripción SNS de la URL del Lambda al edge (1 cambio en AWS console).
- **Rollback:** repuntar SNS de vuelta al Lambda.
- **Nota post-Fase B:** el Lambda `appril-crm-webhook` sigue **vivo y necesario** (SES/SNS + verificación WA legacy + `/webhook/external`) hasta que esta fase se ejecute.

### Fase D — Apagar AWS (pendiente)
1. Confirmar B y C estables varios días.
2. Desactivar/borrar Lambdas (`appril-crm-sender`, `appril-crm-webhook`), API Gateway, EventBridge cron, suscripción SNS al Lambda.
3. Quitar la `service_role` key de Supabase que vivía en AWS (endurecimiento que el README de appril-sender ya señalaba).
- Resultado: **todo en Supabase**, sin factura AWS, sin llave maestra fuera de Supabase.

## 5. Lo que NO se toca en ninguna fase
- El **agente de pacientes** (appril-web, número distinto).
- El **número de pacientes** y su flujo (confirmaciones, NPS, referidos).

## 6. Checklist de verificación por fase
- [x] Inbound comercial sigue respondiendo (verificado post-Fase A con conversación real, 2026-07-09 21:37–21:39 UTC).
- [x] Statuses se registran 1x tras Fase A (verificado en la misma conversación).
- [x] Campañas se envían (Fase B): `message_queue` drena por la Edge `queue-sender`, `message_attempts` y `lead_events` verificados (email E2E; WA aceptado por Meta con `wamid`, entrega limitada por `131049` al número de prueba — no bug). 2026-07-09.
- [ ] Eventos SES llegan (Fase C): `email_delivered/opened/clicked/bounced`.
- [ ] Agente de pacientes intacto en cada fase.
