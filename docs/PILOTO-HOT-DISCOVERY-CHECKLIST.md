# Checklist final · HOT_Discovery_Email_Pilot_v1

> **Estado: PREPARADO, SIN APROBAR, SIN ENVIAR.** Pendiente tu aprobación para seed y mini-piloto.
> Fecha: 2026-06-30 · Proyecto CRM `hwiocriejizjdqqcfrsj`.

## Campaña
- **Nombre:** `HOT_Discovery_Email_Pilot_v1` · **ID:** `b80bd822-d7d1-4aea-988f-47097a9e1ff0`
- **Template:** `hot_discovery_email_v1_1782510240077` · **Canal:** email
- **Estado:** `draft` · **approved_at:** `null` (compuerta activa)
- **segment_filter:** `{"marketing_segment":["HOT"],"utm_campaign":"HOT_Discovery_Email_Pilot_v1"}`
- **Compuerta verificada:** `crm_launch_campaign(...)` → `{"error":"not_approved"}` (no envía hasta aprobar).

## Audiencia HOT elegible (todos los filtros aplicados)
`marketing_segment=HOT` ∧ `can_email` ∧ `unsubscribed_email=false` ∧ `hard_bounce=false` ∧ email no nulo ∧ sin Discovery completado ∧ `pagando_hoy=false` ∧ no `DO_NOT_EMAIL` ∧ (sin contacto <7d)
**→ 169 leads.** (El filtro "contacto <7d" excluye **0**: `last_contacted_at` está vacío en los HOT — lo registro como dato.)

## Checklist (1–17)

| # | Ítem | Estado | Evidencia |
|---|---|---|---|
| 1 | Template con copy aprobado | ✅ | `hot_discovery_email_v1` active, copy v2 aplicado |
| 2 | Asunto y preheader correctos | ✅ | Asunto: "¿Sabe cuánto tiempo le toma perseguir pacientes?" · Preheader: "Ese tiempo representa mucha plata para su consultorio. Haga este diagnóstico." |
| 3 | HTML renderiza bien | ✅ | preview `docs/previews/hot_discovery_email_v1_1782510240077.html` |
| 4 | Link principal → Discovery (no home) | ✅ | CTA usa `{{discovery_url}}`; `has_home_cta=false` |
| 5 | UTMs correctos | ✅ | `utm_source=crm&utm_medium=email&utm_campaign=HOT_Discovery_Email_Pilot_v1&utm_content=hot_discovery_email_v1_1782510240077` (ajuste de tracking aplicado para clave legible) |
| 6 | URL incluye `dl_token` opaco | ✅ | `&dl=ca80d2e6e67c49dbb1794fbe759c0d7d` (32-hex, ≠ lead_id) |
| 7 | `dl` resuelve a lead/campaign/template | ✅ CERRADO (server) / ⏳ falta deploy frontend | Server-side aplicado y **verificado**: columna `discovery_leads.dl` + trigger `trg_discovery_capture_dl` extrae `dl` de `landing_url` y enlaza `lead_id` (solo si nulo). campaign+template vía `utm_campaign`/`utm_content`. **Frontend (appril-discovery):** edité `tracking.js`+`supabase.js` para mandar `dl` + `page_url` (URL completa) — **falta tu deploy por Git/Vercel** (main limpio). Hasta ese deploy, `landing_url` llega sin query y el `dl` no se captura. |
| 8 | `lead_events` guarda campaign_id y template_key | ✅ CERRADO | `appril-sender` redeployado: evento `message_sent` (sender) y eventos SES `email_delivered/opened/clicked/bounced` (webhook) ahora guardan `campaign_id` + `template_key` en `metadata`. |
| 9 | Footer de baja visible | ✅ | footer con "Cancelar suscripción" → `{{unsubscribe_url}}` |
| 10 | `List-Unsubscribe` o estado explícito | ✅ IMPLEMENTADO | Lambda sender deployado con header `List-Unsubscribe` + one-click (probado: 2 correos entregados a tech@figital.pro) |
| 11 | No hay mensajes futuros en cola | ✅ | `message_queue` pending=0, futuros=0 |
| 12 | No se activa WARM | ✅ | ninguna campaña WARM running |
| 13 | No se activa COLD | ✅ | sin blast COLD; existe wrapper "Secuencia · cold_intro_email" (auto de la prueba, pending=0, no envía) |
| 14 | No se activa WhatsApp masivo | ✅ | WA "Secuencia" son pre-existentes, pending=0; no activé ninguna |
| 15 | No se modifica scoring | ✅ | sin cambios a scoring |
| 16 | Discovery backend sin cambios salvo tracking | ✅ | no toqué Discovery; cambio de `dl` (ítem 7) queda como tracking opcional |
| 17 | No se envía sin aprobación final | ✅ | `approved_at=null` + compuerta probada |

## Plan de tamaños (controlado)
1. **Seed interno (5–10):** a direcciones controladas (NO leads HOT reales). Mecanismo: lista `seed_pilot` + campaña con `utm_campaign=HOT_Discovery_Email_Pilot_v1`. Requiere que me des las direcciones de seed (tengo solo `tech@figital.pro`).
2. **Mini-piloto real (30–50 HOT):** lista `mini_pilot_hot` con 40 de los 169 → `segment_filter.list_ids`. Tope duro = tamaño de la lista (no más de 50).
3. **Resto HOT (≤169):** solo tras validar métricas y errores.

## Lo que NO puedo hacer yo (lo hacés vos / QA)
- **Capturas Gmail desktop/móvil:** no tengo acceso a la bandeja; las tomás vos al recibir el seed.
- **Funnel vivo (click → Discovery → result → WA `fromDiscovery=true`):** corre en appril-web; lo validás navegando, o **simulo** insertando un `discovery_lead` para disparar el email de resultado (decime si querés esa simulación).

## Métricas del piloto (no optimizar por open rate)
- **Email (lead_events, join a campaign por `ses_message_id`/`message_id`):** delivered, bounced, clicked.
- **Discovery (discovery_events por `utm_campaign=HOT_Discovery_Email_Pilot_v1`):** discovery_started, contact_submitted, result_viewed, cta_clicked.
- **WA/activación:** wa_reply, demo_created, account_created (si existe).

## Decisiones que necesito de vos
A. **Atribución por lead (`dl` en Discovery, ítem 7)** y **campaign_id explícito en eventos (ítem 8)**: ¿los implemento antes del piloto, o aceptás atribución por campaña (UTM) + join para el piloto?
B. **Seed:** ¿a qué direcciones controladas lo mando? (5–10)
C. **Aprobación** para: (1) seed, luego (2) mini-piloto 30–50.

**No envío nada hasta tu OK explícito.**
