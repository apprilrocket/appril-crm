# Plan de consolidación WhatsApp/Email → Supabase (matar AWS)

> Estado: **plan documentado, NO ejecutado** (decisión 2026-06-30: hacerlo bien, no rápido).
> Contexto: ver memoria `whatsapp-inbound-architecture.md`.

## 1. Arquitectura actual (post-fix 2026-06-30)

```
NÚMERO COMERCIAL (+57 311 2211772, phone_id 928845203654774, WABA 1446010070564033)
  Meta lo entrega a DOS apps:
    · App "Appril CRM" (1715144349475123) → whatsapp-agent edge (hwiocriejizjdqqcfrsj)  ← responde
    · App "Appril"     (1904313610456059) → appril-web/whatsapp-webhook (router)
          └─ si phone_id == comercial → reenvía a CRM_WEBHOOK_URL
                ANTES: → Lambda appril-crm-webhook (colisión de wa_reply → bug multi-turno)
                AHORA: → whatsapp-agent edge (secret CRM_WEBHOOK_URL en proyecto appril-web)  ✅

NÚMERO DE PACIENTES (distinto) → App "Appril" → appril-web/whatsapp-agent (producto). Intacto.

OUTBOUND: CRM → message_queue → Lambda appril-crm-sender (cron 2min) → SES / WA Cloud API.
EMAIL EVENTS: SES → SNS → Lambda appril-crm-webhook /webhook/ses → lead_events.
```

## 2. El fix aplicado (y cómo hacerlo permanente)

- **Aplicado:** secret `CRM_WEBHOOK_URL = https://hwiocriejizjdqqcfrsj.supabase.co/functions/v1/whatsapp-agent` en el proyecto appril-web (`gfpdrqqsaqifyepvmwpt`), vía `supabase secrets set`. Reversible borrándolo.
- **Verificado:** agente conversa multi-turno; inbound 100% estructurado, 0 `wa_reply` crudos del Lambda.
- **Pendiente para hacerlo permanente en código** (no urgente, el secret es durable): cambiar el default hardcodeado en `appril-web/supabase/functions/whatsapp-webhook/index.ts` (línea ~45) de la URL del Lambda a la del agente. ⚠️ NO desplegar appril-web hasta resolver su `main` sucio (tiene cambios de producto sin commit).

## 3. Duplicación de statuses (cosmética)

El comercial llega al agente por 2 apps → los `wa_sent/delivered/read/failed` se insertan 2x (sin daño: no hay índice único en statuses; el inbound sí deduplica por `wa_message_id`). Se elimina al retirar la app redundante (Fase A).

## 4. Plan por fases (ejecutar con QA, no a las carreras)

### Fase A — Un solo camino de inbound (Meta-only, sin deploy)
1. Verificar que `appril-web → agente` (vía CRM_WEBHOOK_URL) funciona de forma aislada (logs de `whatsapp-webhook` en gfpd + dedup en el agente).
2. Retirar la suscripción de la app **"Appril CRM" (1715)** al WABA (o quitarle el campo `messages`). Entonces appril-web (1904) queda como **router único**: comercial→agente, pacientes→patient-agent.
3. Resultado: 1 sola entrega por mensaje → adiós duplicación de statuses, adiós cualquier resto de colisión.
- **Riesgo:** si el forward appril-web→agente fallara, el comercial se queda sin inbound → verificar (paso 1) ANTES. **Rollback:** re-suscribir la app 1715.

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
- [ ] Inbound comercial sigue respondiendo (prueba con +573004860240, ver `test-phone-reset.md`).
- [ ] Statuses de campaña se registran (1x tras Fase A).
- [ ] Campañas se envían (Fase B): `message_queue` drena, `message_attempts`, `lead_events`.
- [ ] Eventos SES llegan (Fase C): `email_delivered/opened/clicked/bounced`.
- [ ] Agente de pacientes intacto en cada fase.
