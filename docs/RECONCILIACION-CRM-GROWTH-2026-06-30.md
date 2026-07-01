# Reconciliación CRM ↔ Growth — estado real (2026-06-30)

> **Solo lectura.** No se envió, encoló, activó, deployó ni cambió copy en esta reconciliación.
> Proyecto CRM `hwiocriejizjdqqcfrsj`. Regla: CRM ejecuta, Growth decide.

## 1. Resumen ejecutivo
- **No existe `hot_discovery_email_v2_20260630` en CRM** (0 resultados). El copy v2 aprobado se implementó **in-place sobre `hot_discovery_email_v1_1782510240077`**. La propia **DEC-012** de Growth ya aceptó esta key como la operativa, condicionada a confirmar el match por export/hashes (este doc lo confirma).
- **10 templates email**, todos `active`, todos con copy v2, `updated_at = 2026-06-30 13:28 UTC`, todos con `variables = [nombre, discovery_url, unsubscribe_url]` y **CTA a Discovery (0 a home)**. Checksums abajo.
- **Discovery productivo = 9 preguntas** (confirmado en `appril-discovery/data.js` · `AP.QUESTIONS`). PASS.
- **Cola limpia:** `message_queue` 0 pending / 0 future / 0 processing. 1 automation activa pero `manual` (no auto-encola). **Nada puede enviarse solo.**
- **Riesgo de reconciliación:** la campaña **`Piloto HOT · Discovery (hot_intro_email)` está APROBADA en CRM** (draft+approved → lanzable a 169), pero **DEC-012 la marca como NO aprobada para seed** y usa `hot_intro_email` (no el template Discovery). → Decisión de Growth: desaprobar/archivar.
- **`dl`:** backend listo y probado (token + columna + trigger + resolución a lead). **Falta deploy de frontend Discovery** (1 commit en `appril-discovery`, ya editado, sin desplegar).
- **Email resultado + WA Agent:** componentes desplegados; **chain end-to-end NUNCA ejercida** (0 Discovery completados) → validación pendiente.

## Tabla de readiness

| Área | Estado | Evidencia | Riesgo | Próxima acción (Growth decide) |
|---|---|---|---|---|
| Templates email v2 | **pass** | 10 active, copy v2, hashes abajo, CTA→Discovery | — | confirmar match copy vs Email Library V2 por hash |
| Template HOT key | **pass** (reconciliado) | `hot_discovery_email_v1_1782510240077`, subject "¿Sabe cuánto tiempo…?"; no existe v2_20260630 | DEC-008 mencionaba v2; DEC-012 ya aceptó v1 | usar `hot_discovery_email_v1_1782510240077` para seed |
| Email resultado (hardcoded) | **pass (deployado)** | From hola@, CTA→WA, vars hiddenCost/lostRevenue/adminHours | nunca ejercido con Discovery real | validar 1 corrida (autorizar) |
| Campaña pilot HOT Discovery | **blocked** | `HOT_Discovery_Email_Pilot_v1` draft, **sin aprobar**, gate probado | requiere sync+dl frontend+evidencia | aprobar cuando Growth lo decida |
| Campaña `Piloto HOT (hot_intro)` | **blocked/riesgo** | draft **APROBADA**, template `hot_intro_email` | armada, no es el template Discovery | **desaprobar/archivar** |
| `dl` backend | **pass** | token+columna+trigger+resolución probados | — | — |
| `dl` frontend Discovery | **blocked** | `appril-discovery` editado, no deployado | sin deploy, dl/utm no llegan | deploy Git/Vercel (main limpio) |
| Discovery 9 preguntas | **pass** | `AP.QUESTIONS` = 9 (ids listados) | — | — |
| WA Agent fromDiscovery | **pass (código) / no validado** | `ctx.fromDiscovery` en whatsapp-agent (deployado) | chain no ejercida | validar con corrida real |
| Deliverability | **pass parcial** | List-Unsubscribe one-click deployado+probado; supresión auto | DMARC/warming no auditados | auditar DNS + plan warming |
| Cola | **pass** | 0 pending/future/processing | — | — |
| Sprint cells | **mixed** | tamaños abajo | Referidos sin email; COLD necesita throttle | definir lotes |

---

## 2. Export completo de templates email (metadata + checksums)
Todos: `status=active`, `channel=email`, `variables=[nombre,discovery_url,unsubscribe_url]`, `updated_at=2026-06-30 13:28:24 UTC`, **CTA = `{{discovery_url}}` (Discovery), 0 links a home, footer baja = `{{unsubscribe_url}}`**.

| template_key | subject | text_md5 | html_md5 | text_len | html_len | created_at | campañas que lo referencian |
|---|---|---|---|--:|--:|---|---|
| cold_intro_email | ¿Sabe cuánto le cuestan los pacientes que no llegan? | `0d63e9db5f64ebee804b63d20c0ddb45` | `2ce283d84bb8df8339a068bdc5ce5fad` | 569 | 2332 | 2026-05-26 | Secuencia · cold_intro_email [running,sin-aprobar] |
| cold_followup_email | ¿Su asistente o usted confirman la agenda de mañana? | `88878a5a4f228fb246accdcb4bc02b24` | `11f5236783bdebec01d4fe412d75371f` | 588 | 2352 | 2026-05-26 | — |
| hot_intro_email | ¿Cuántas citas le cancelan al mes en su consultorio? | `745c9ddab0d03309d26b4834bdd8c12e` | `eff76db4cf57f6c02f34458753b56aa1` | 559 | 2306 | 2026-05-26 | Outreach·hot_intro (done×2); **Piloto HOT [draft,APROBADA]**; PRUEBA TEST [running,aprobada] |
| hot_followup_email | ¿Para usted es un problema que los pacientes cancelen o no lleguen? | `c939f8d11e41b7617467f835fc26209c` | `e2554f0f5d7c7077033dca2fe7b8a32a` | 548 | 2280 | 2026-05-26 | — |
| super_hot_email | Sus pacientes necesitan ver innovación | `8469a9f179c85404afa06556fe402678` | `05cf3ef599a54fee4b33db8d94c3b87e` | 574 | 2349 | 2026-05-26 | — |
| warm_reactivation_1 | ¿Todavía confirma pacientes por WhatsApp? | `704cc3b1660eb4ac8f8164900e34937d` | `02c1ff9e80f053a4aeb4fc47af97f339` | 560 | 2372 | 2026-05-26 | — |
| warm_reactivation_2 | Las citas que se pierden le cuestan mucha plata | `506bd407b77afb0b9a2d37ab64da1466` | `ce9b1790e78a4a63f1e71bdaf0488b1d` | 498 | 2283 | 2026-05-26 | — |
| demo_email_intro | Su consultorio está perdiendo plata y usted lo sabe | `ee7fbf06beda123752ffff3d102f5635` | `55ae950baba3195de2406bf69c61c1fe` | 547 | 2309 | 2026-05-22 | Outreach·demo (done); Secuencia·demo [running,sin-aprobar] |
| demo_email_followup | ¿Sabe si está administrando bien su consultorio? | `c946dc52f9cf8eb0c526143291c9ca8a` | `a6ba984ae3f8b7f7fdd0af73b5756a55` | 490 | 2238 | 2026-05-22 | — |
| **hot_discovery_email_v1_1782510240077** | ¿Sabe cuánto tiempo le toma perseguir pacientes? | `885ad1611bd8c9eb6d37cea7bb676da0` | `53d6a93242ca348d43b8dfbca94eb570` | 541 | 2324 | 2026-06-26 | HOT Email Test V1 [draft,sin-aprobar]; Secuencia·v1 [running,sin-aprobar]; **HOT_Discovery_Email_Pilot_v1 [draft,sin-aprobar]** |

> Preheaders embebidos en HTML (`<div style="display:none…">`). CTA por template: cold_intro "Hacer mi diagnóstico" · cold_followup "Revisar mi agenda" · hot_intro "Analizar mi agenda" · hot_followup "Hacer el diagnóstico" · super_hot "Hacer mi diagnóstico" · warm_1 "Revisar mi agenda" · warm_2 "Realizar el diagnóstico" · demo_intro "Hacer el diagnóstico" · demo_followup "Revisar mi consultorio" · hot_discovery_v1 "Hacer mi diagnóstico". **Todos → `{{discovery_url}}`.**
> Cuerpos completos: `text_body` en `supabase/migrations/20260629_1800_discovery_email_rewrite.sql`; HTML renderizado en `docs/previews/<template_key>.html`.

### 3 (sección §3 del pedido). Template HOT real aprobado — confirmación
1. **¿Existe `hot_discovery_email_v2_20260630`?** **NO** (0 en `message_templates`).
2. **¿El copy aprobado se implementó sobre `hot_discovery_email_v1`?** **SÍ**, in-place (subject + preheader + text + html v2).
3. **Key real para seed:** **`hot_discovery_email_v1_1782510240077`**.
4. **Subject real:** `¿Sabe cuánto tiempo le toma perseguir pacientes?`
5. **Preheader real:** `Ese tiempo representa mucha plata para su consultorio. Haga este diagnóstico.`
6. **text_body (completo):**
```
Hola {{nombre}},

Una pregunta concreta:

¿Sabe cuánto tiempo le toma a usted o a su equipo perseguir pacientes para que confirmen una cita?

Ese tiempo casi nunca se mide, pero sí cuesta: mensajes, llamadas, interrupciones, pacientes que no responden y citas que pueden terminar vacías.

Por eso preparamos un diagnóstico corto para revisar cuánto dinero, tiempo y oportunidad se pueden estar perdiendo antes de que el paciente llegue.

Son 9 preguntas. Sin crear cuenta.

Hacer mi diagnóstico:
{{discovery_url}}

Un saludo,
Mauricio
Appril
```
7. **html_body (completo):** `text_md5=885ad1611bd8c9eb6d37cea7bb676da0`, `html_md5=53d6a93242ca348d43b8dfbca94eb570`. Render: `docs/previews/hot_discovery_email_v1_1782510240077.html`. Estructura: preheader oculto → header "Appril" (#F45B69) → 6 párrafos → botón #F45B69 "Hacer mi diagnóstico" → `{{discovery_url}}` → firma "Mauricio / Appril" → footer con "Cancelar suscripción" → `{{unsubscribe_url}}`.
8. **Campañas que lo referencian:** `HOT Email Test V1 — Discovery` (draft, sin aprobar), `Secuencia · hot_discovery_email_v1` (running, sin aprobar, cola 0), `HOT_Discovery_Email_Pilot_v1` (draft, sin aprobar).
9. **¿Riesgo de copy viejo?** **NO.** El template se sobrescribió in-place; cualquier campaña que lo use toma el copy v2 actual. No existe copia del copy v1-viejo en ningún template activo.

## 3. Email hardcodeado post-Discovery (`send-discovery-email/index.ts`)
- **Desplegado:** SÍ (deploy 2026-06-30, esta sesión). Disparo: trigger `AFTER INSERT on discovery_leads` → pg_net (migración `20260629_1510`). Idempotente (`discovery_email_sent`).
- **subject:** `Su diagnóstico está listo`
- **preheader:** dinámico → `Tiene una oportunidad estimada de {{hiddenCost}} al año.` (si hay cifra) · fallback `Vea dónde se le están escapando dinero, tiempo y oportunidades.`
- **renderText (completo):**
```
Hola, {{name}}

Su diagnóstico está listo.

[si hay cifra] Encontramos una oportunidad estimada de {{hiddenCost}} al año.

El punto más importante:
{{riskTitle}}

{{evidence}}

Qué significa:
Su consultorio puede estar perdiendo dinero antes de que el paciente llegue: en confirmaciones pendientes, cancelaciones tarde, tiempo de WhatsApp o espacios que no se recuperan.

Impacto estimado al año:
- Pérdida anual estimada: {{lostRevenue}}
- Horas administrativas estimadas: {{adminHours}}
- Costo oculto total: {{hiddenCost}}

Estas cifras son estimaciones basadas en sus respuestas. No son una promesa de ahorro.

Cómo puede ayudar Appril:
- Sus pacientes pueden confirmar, cancelar o reagendar con más claridad.
- Su consultorio deja de perseguir paciente por paciente.
- Usted puede ver quién confirmó, quién sigue pendiente y qué espacios requieren acción.

Por haber hecho el diagnóstico, puede activar un mes gratis de Appril.

Activar mi mes gratis por WhatsApp:
{{waUrl}}

Crear cuenta sin tarjeta:
{{ctaUrl}}

Appril
```
- **HTML (resumen):** header "Su diagnóstico está listo" → bloque destacado "Oportunidad estimada al año {{hiddenCost}}" (solo si hay cifra) → "El punto más importante" {{riskTitle}}+{{evidence}} → "Qué significa" → 3 cards ({{lostRevenue}}/{{adminHours}}/{{hiddenCost}}) → disclaimer → "Cómo puede ayudar Appril" (3 bullets) → **CTA principal WhatsApp** ({{waLabel}}→{{waUrl}}, verde) + **CTA secundario** "Crear cuenta sin tarjeta" ({{ctaUrl}}) → footer.
- **Variables:** name, riskTitle, evidence, lostRevenue, adminHours, hiddenCost, waUrl, waLabel, ctaUrl, ctaLabel.
- **ctaUrl:** `https://www.appril.co/empezar` (+UTM discovery_email) · **waUrl:** `https://wa.me/573112211772?text=Hola, recibí mi diagnóstico de Appril y quiero activar mi mes gratis.`
- **Remitente:** `Appril <hola@appril.co>`. **Reply-To:** no se setea (las respuestas van al From = hola@). **List-Unsubscribe:** NO en este email (es transaccional; el header vive en el camino de campaña, no aquí). **Endpoint de baja:** este correo no incluye link de baja (transaccional post-acción).

## 4. Inventario campañas email
| campaign_id | name | status | template | subject | seg | aprobada | q_total/sent/pending/future | gate | ¿envía sin aprobación? | candidata seed | acción |
|---|---|---|---|---|---|---|---|---|---|---|---|
| b80bd822… | **HOT_Discovery_Email_Pilot_v1** | draft | hot_discovery_email_v1 | ¿Sabe cuánto tiempo…? | HOT | **NO** | 0/0/0/0 | **SÍ (gate activo)** | no (rechaza: not_approved) | **SÍ** | aprobar cuando Growth decida |
| e5503b6a… | Piloto HOT · Discovery (hot_intro_email) | draft | **hot_intro_email** | ¿Cuántas citas…? | HOT | **SÍ** | 0/0/0/0 | no | **SÍ si alguien la lanza** | no (template equivocado) | **desaprobar/archivar** |
| 2a2f8022… | HOT Email Test V1 — Discovery | draft | hot_discovery_email_v1 | — | HOT | NO | 0/0/0/0 | sí | no | histórica | archivar |
| cc7c84dc… | PRUEBA · campaña a TEST | running | hot_intro_email | — | TEST | sí | 1/1/0/0 | — | ya envió 1 (prueba) | no | histórica |
| 1b8d68e3… | Secuencia · cold_intro_email | running | cold_intro_email | — | — | NO | 1/1/0/0 | — | no | histórica (auto) | — |
| b0057a56… | Secuencia · hot_discovery_email_v1 | running | hot_discovery_email_v1 | — | — | NO | 0/0/0/0 | — | no | no | — |
| 0d09cdb7… | Secuencia · demo_email_intro | running | demo_email_intro | — | — | NO | 0/0/0/0 | — | no | no | — |
| 56d3059e… | Outreach · hot_intro · 14 jun | done | hot_intro_email | — | HOT | NO | 87/87/0/0 | — | no | histórica | — |
| fde44c7d… | Outreach · hot_intro | done | hot_intro_email | — | — | NO | 0/0/0/0 | — | no | histórica | — |
| 142dd0a2… | Outreach · demo_email_intro | done | demo_email_intro | — | — | NO | 1/1/0/0 | — | no | histórica | — |

**Confirmaciones explícitas:**
- **¿Campaña HOT que pueda enviar sin aprobación?** Técnicamente **`Piloto HOT (hot_intro_email)` está aprobada** → si alguien la lanza (botón/RPC) enviaría a 169. **No se dispara sola**, pero está "armada". Recomendado **desaprobarla**. `HOT_Discovery_Email_Pilot_v1` está **bloqueada** (sin aprobar, gate probado: `{"error":"not_approved"}`).
- **¿Envío programado?** NO (`scheduled_at` nulo en todas; `message_queue` future = 0).
- **¿Filas futuras en message_queue?** NO (0).
- **¿Automation que pueda usar estos templates?** Solo 1 activa (`Prueba end-to-end…`) con `trigger_type=manual` → **no auto-encola**.

## 5. Segment Learning Sprint v1 — readiness por celda
Criterio elegible (email): `email no nulo ∧ can_email ∧ ¬unsubscribed ∧ ¬hard_bounce ∧ ¬pagando ∧ ¬Discovery_completado`. (`can_email=false` ya excluye hard_bounce/unsub por trigger.)

| Celda | Total | Elegible (email) | WhatsApp E.164 | Template | Campaña draft | Estado | Falta |
|---|--:|--:|--:|---|---|---|---|
| **HOT** | 170 | **169** | 143 | hot_discovery_email_v1 | HOT_Discovery_Email_Pilot_v1 (sin aprobar) | **ready (blocked por aprobación+dl frontend)** | aprobar + deploy dl frontend |
| **WARM** (lote 50–100) | 11.996 | **11.995** | 8.218 | warm_reactivation_1/2 | — | ready audiencia / sin campaña | crear lote 50–100 + warming |
| **Referidos** (10–25) | 26 | **0 (email)** | 26 | referido_invitacion (WA) | — | **fail para email** | es celda **WhatsApp/referido**, no email |
| **Abrió-no-click** (30–50) | — | **136** | — | (re-engage) | — | ready audiencia | definir copy/asunto nuevo |
| **COLD** (25–50 máx) | 8.504 | **8.165** | 61 | cold_intro/followup | — | ready audiencia / **requiere throttle** | throttle + deliverability |
| **SUPER_HOT** (1:1) | 14 | **7** (no pagando) | 14 | super_hot (o WA 1:1) | — | flujo 1:1, **no campaña** | manejo manual |

## 6. Estado `dl`
1. **¿Dónde se genera `dl_token`?** Columna `leads_master.dl_token`, `DEFAULT replace(gen_random_uuid()::text,'-','')` (32-hex). Backfill de los 20.791 (0 nulos). Migración `20260629_1800` / `discovery_email_rewrite_v2`.
2. **¿Dónde se guarda?** `leads_master.dl_token` (por lead) y `discovery_leads.dl` (capturado al submit).
3. **¿Qué resuelve `dl`?** Trigger `trg_discovery_capture_dl` (BEFORE INSERT en `discovery_leads`): extrae `dl` de `landing_url` y setea `discovery_leads.lead_id` desde `leads_master.dl_token` (solo si lead_id viene nulo). Función `discovery_capture_dl()`.
4. **Resuelve a:** **lead_id** (vía dl_token). **campaign_id / template_key / variant / segment**: NO vía dl — viajan como **UTM en la misma URL** (`utm_campaign`, `utm_content`=template, `utm_term`=variant) y se guardan en `discovery_leads.utm_*`. Segment se deriva del lead.
5. **Endpoint/RPC que resuelve `dl`:** no hay endpoint dedicado; la resolución ocurre en el trigger al hacer submit (`submit_discovery_lead`). Además el endpoint `email-unsubscribe` usa `dl`→lead.
6. **`{{discovery_url}}`:** se genera en `crm_launch_campaign` por lead: `https://discovery.appril.co/?utm_source=crm&utm_medium=email&utm_campaign=<key>&utm_content=<template_key>&utm_term=A&dl=<dl_token>`.
7. **Ejemplo (token redactado):** `https://discovery.appril.co/?utm_source=crm&utm_medium=email&utm_campaign=HOT_Discovery_Email_Pilot_v1&utm_content=hot_discovery_email_v1_1782510240077&utm_term=A&dl=••••••••••••••••••••••••••••••••`
8. **Probado hoy:** generación del token (backfill 0 nulos), regex de extracción de `dl` desde URL, resolución `dl`→lead, columna+trigger existen. (Verificado por SELECT, sin insertar.)
9. **Falta en frontend Discovery:** que el front mande `page_url` (URL completa con query) y/o `dl` en el submit. Hoy `landing_url` llega como `https://discovery.appril.co` (sin query) → `dl`/`utm` no se capturan.
10. **Repo frontend:** `appril-discovery` (github `apprilrocket/appril-discovery`), `main` limpio.
11. **Archivos a tocar (ya editados, sin deploy):** `tracking.js` (`captureUtm`: agregar `dl`+`page_url`) y `supabase.js` (payload: agregar `dl`+`page_url`).
12. **Evento que debe incluir `dl`:** el payload del submit a `submit_discovery_lead` (vía `supabase.js`).
13. **Commit/deploy que falta:** 1 commit en `appril-discovery` + deploy Vercel. (Edición preparada; CRM no despliega frontend.)

## 7. Discovery 9 preguntas
- **PASS.** `appril-discovery/data.js` (`AP.QUESTIONS`) = **9 preguntas**. Comentario del archivo: "flujo de 9 preguntas core".
- IDs: `appointment_scheduler_type, monthly_appointments_range, scheduling_method, confirmation_consistency, average_ticket_range, lost_appointments_range, cancellation_process, admin_minutes_per_appointment, main_pain`.
- Validación: estructura en `data.js`; el productivo es `discovery.appril.co` (deploy de `appril-discovery`).

## 8. Email resultado + WhatsApp Agent
1. **¿Se dispara al completar Discovery?** SÍ (trigger AFTER INSERT en `discovery_leads`).
2. **Trigger:** pg_net POST → edge `send-discovery-email` (`20260629_1510`).
3. **Activo:** SÍ (deployado 2026-06-30).
4. **Copy v2:** SÍ (subject "Su diagnóstico está listo").
5. **Variables hiddenCost/lostRevenue/adminHours:** SÍ.
6. **CTA principal → WhatsApp:** SÍ (`waUrl`).
7. **CTA secundario → registro:** SÍ (`ctaUrl=www.appril.co/empezar`).
8. **WA Agent recibe `fromDiscovery=true`:** código presente (`ctx.fromDiscovery` en `whatsapp-agent`, deployado).
9. **Campo/evento que conecta:** el lead de WhatsApp se cruza con su `discovery_lead` (por teléfono/lead_id); el agente lee `fromDiscovery` + `riskTitle`/`recommendedAction`.
10. **Prueba existente:** **ninguna end-to-end** (Discovery completados = 0). Componentes desplegados pero **chain no ejercida** → validación pendiente (no autorizada a correr nueva prueba).

## 9. Deliverability
- **Remitente:** `hola@appril.co` (campañas: Lambda; resultado/inbox: edge). **Reply-To:** `hola@appril.co` (Lambda); edge sin reply-to (va al From).
- **List-Unsubscribe:** **SÍ** implementado (Lambda `ses.ts`, one-click RFC 8058, deployado).
- **Endpoint de baja propio:** **SÍ** (`email-unsubscribe`, deployado, probado HTTP 200).
- **One-click probado:** SÍ (2 correos de prueba entregados hoy con el header).
- **hard bounce → can_email=false:** **SÍ** (webhook setea hard_bounce; trigger `schema.sql:1223` → can_email=false + DO_NOT_EMAIL).
- **complaint → can_email=false:** **SÍ** (webhook setea unsubscribed_email → trigger).
- **unsubscribe → can_email=false:** **SÍ** (endpoint setea directo).
- **SPF/DKIM/DMARC:** **no auditado por CRM**; la entrega exitosa (88 delivered) implica DKIM/SPF funcionales; **DMARC sin verificar** (DNS/AWS, lado Growth/infra).
- **Warming/rate limit:** throttle implícito `BATCH_SIZE=50` por corrida (~cada 2 min); **sin rampa de warming dedicada**.
- **Throttle COLD:** mismo BATCH_SIZE; **sin throttle dedicado por segmento** → COLD necesita plan explícito.

## 10. Estado de cola
- `message_queue`: **128 total · 0 pending · 0 future · 0 processing · 24 failed (WA viejos) · 2 sent hoy (pruebas)**.
- **Leads reales encolados por error:** NO.
- **Automations activas que puedan encolar:** 1 (`Prueba end-to-end…`) pero `manual` → no auto-encola.

## 11. Bloqueos
1. `HOT_Discovery_Email_Pilot_v1`: bloqueada (sin aprobar) + depende de **deploy dl frontend** + validación chain.
2. **`Piloto HOT (hot_intro_email)` aprobada** (riesgo de disparo manual; template equivocado para Discovery) → desaprobar.
3. **dl frontend** sin deploy (appril-discovery) → atribución por lead inactiva hasta el deploy.
4. **Chain Discovery→resultado→WA** nunca validada end-to-end.
5. **DMARC + warming** sin auditar para masivo.
6. **Referidos** sin audiencia email (solo WhatsApp).

## 12. Decisiones que necesita Growth
1. Confirmar `hot_discovery_email_v1_1782510240077` como key oficial del seed (ya alineado con DEC-012) — comparar hashes vs Email Library V2.
2. ¿Desaprobar/archivar `Piloto HOT (hot_intro_email)` y `HOT Email Test V1`?
3. Autorizar (o no) **deploy de `appril-discovery`** para activar `dl`/utm.
4. Autorizar (o no) **1 validación end-to-end** Discovery→resultado→WA.
5. Definir lotes del Sprint (WARM 50–100, Abrió-no-click 30–50, COLD 25–50 con throttle, SUPER_HOT 1:1) y mover Referidos a canal WhatsApp.
6. Plan de **warming + verificación DMARC** antes de cualquier lote > seed.

## 13. Confirmación explícita (esta reconciliación)
- **No se envió nada.**
- **No se encoló nada** (message_queue pending=0; sin filas nuevas).
- **No se activó ninguna campaña** (todas siguen en su estado previo).
- **No se hizo deploy** (solo lectura).
- **No se cambió copy** (templates intactos; `updated_at` previo 13:28).
