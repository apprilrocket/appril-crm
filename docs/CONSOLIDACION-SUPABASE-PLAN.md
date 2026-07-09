# Plan de consolidación WhatsApp/Email → Supabase (matar AWS)

> Estado: **Fase A EJECUTADA y validada el 2026-07-09 (noche). Fases B–D pendientes** (decisión 2026-06-30: hacerlo bien, no rápido).
> Contexto: ver memoria `whatsapp-inbound-architecture.md`.

## 1. Arquitectura actual (post-Fase A, 2026-07-09)

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

OUTBOUND: CRM → message_queue → Lambda appril-crm-sender (cron 2min) → SES / WA Cloud API.
EMAIL EVENTS: SES → SNS → Lambda appril-crm-webhook /webhook/ses → lead_events.
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

### Fase B — Sender de campañas a Supabase
1. Edge `queue-sender` que porte `appril-sender/src/sender.ts` (SES + WA Cloud API + reintentos) + arreglar el bug "stuck in sending" (re-encolar `sending` > N min).
2. Disparar por `pg_cron` (cada 1-2 min) → `net.http_post` (habilitar `pg_net`) o Supabase Cron.
3. Mantener el Lambda sender en paralelo unos días; comparar; luego apagar EventBridge cron del Lambda.
- **Riesgo:** cuotas/throughput de edge. A volumen actual (mínimo) sobra. **Rollback:** reactivar cron del Lambda.

### Fase C — Eventos SES a Supabase
1. Edge `ses-events` que porte `appril-sender/src/webhook.ts handleSes` (SubscriptionConfirmation + Notification → lead_events + flags en leads_master).
2. Repuntar la suscripción SNS de la URL del Lambda al edge (1 cambio en AWS console).
- **Rollback:** repuntar SNS de vuelta al Lambda.

### Fase D — Apagar AWS
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
- [ ] Campañas se envían (Fase B): `message_queue` drena, `message_attempts`, `lead_events`.
- [ ] Eventos SES llegan (Fase C): `email_delivered/opened/clicked/bounced`.
- [ ] Agente de pacientes intacto en cada fase.
