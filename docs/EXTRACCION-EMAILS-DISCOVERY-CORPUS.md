# Extracción completa de emails → Discovery — Corpus + evidencia

> **Tipo:** extracción técnica de SOLO LECTURA para rediseñar la estrategia de email con objetivo
> `email → click → Discovery → resultado → WhatsApp Agent → demo → activación`.
> **No se modificó, envió, deployó ni activó nada.**
> **Fecha:** 2026-06-29 · **Proyecto Supabase (CRM):** `hwiocriejizjdqqcfrsj` ("Tablas de datos de profesionales" / appril-crm) · **Repo:** `appril-crm` (branch `chore/rescue-edge-functions`).
> **Complementa** a `docs/AUDITORIA-EMAIL-DISCOVERY.md` (auditoría previa). Este documento aporta: **cuerpos completos verbatim**, el **email hardcodeado de resultado de Discovery** (no estaba en la tabla), tablas por template y el **corpus editable**.
> **Honestidad de datos:** el volumen histórico de email es **muy bajo** (~89 envíos reales, todos de *un* template). **No hay base para "tasas" confiables.** Donde no hay datos lo digo. No inventé métricas.

---

## 1. Resumen ejecutivo

- **El CRM tiene 20.789 leads.** 20.425 con email; solo **8.541 con teléfono en formato E.164** (el cuello de botella de WhatsApp). Segmentos: **WARM 11.996 · COLD 8.504 · HOT 170 · DO_NOT_EMAIL 81 · sin segmento 24 · SUPER_HOT 14.**
- **El universo es terreno virgen para Discovery:** hay **20 `discovery_leads` en total y los 20 son QA** (`utm_medium='email'` = 0, `status='completed'` = 0). **Cero leads han llegado al Discovery desde un email.** Toda la estrategia está por construirse.
- **Hay 11 templates de email**, no 10: **10 en `message_templates`** + **1 hardcodeado en código** (el email de RESULTADO del Discovery, `send-discovery-email`). Este último es la pieza central del flujo y **no vivía en la base**.
- **9 de los 10 templates de BD apuntan a `https://appril.co` (home genérica), sin UTMs y sin token de lead.** Venden Appril directo con la promesa **"40–90% menos inasistencias"** (claim fuerte, riesgo de spam/legal). **Solo 1** (`hot_discovery_email_v1...`) ya apunta a `discovery.appril.co` con UTMs — es el patrón a replicar, pero todavía **sin `dl`/`lead_id`** en la URL.
- **Inconsistencia de remitente:** los blasts del CRM (vía Lambda SES) salen de **`hola@appril.co`** con **`Reply-To: mauricio@todoc.co`**; los emails de las edge functions (`send-discovery-email`, `inbox-send`) salen de **`diagnostico@appril.co`** **sin Reply-To**. Dos dominios de envío, dos configuraciones distintas.
- **Deliverability con huecos P0:** AWS SES funciona (config-set `appril-crm`), pero **no hay header `List-Unsubscribe` en ningún envío**, el "unsubscribe" de los templates es un `mailto:` y **no hay manejador de SNS bounce/complaint en el repo** (vive en un Lambda externo). Sí existe lógica de supresión a nivel de dato (`can_email=false` en hard bounce/unsub).
- **Atribución parcial:** existe el funnel de `discovery_events` (instrumentado) y eventos `email_*` en `lead_events`, pero **la cadena email→lead específico no es hermética**: las URLs no llevan `lead_id`/`dl`, y los eventos SES (`lead_events.metadata`) **no traen `template_key` ni `campaign_id`**. Hoy se puede atribuir por **campaña/UTM**, no por lead individual sin agregar un token.

**Conclusión:** la base es grande y segmentable, pero la capa de email está diseñada para "vender Appril", no para "llevar al Discovery". El rediseño es de alto impacto y viable. **Antes de escalar hay que (P0) cerrar deliverability (List-Unsubscribe, footer/baja real, dominio único) y (P1) instrumentar atribución por lead (`dl` token).**

---

## 2. Inventario de templates de email

### 2.1 En `public.message_templates` (canal `email`) — 10 templates, todos `status='active'`, `version=1`

| template_key | name | subject | text_len | html_len | variables | updated_at |
|---|---|---|--:|--:|---|---|
| `cold_followup_email` | COLD · Email follow-up | `Re: Agenda inteligente — Appril` | 262 | 1669 | `["nombre"]` | 2026-06-26 |
| `cold_intro_email` | COLD · Email intro | `Agenda inteligente para tu consultorio — Appril` | 387 | 1881 | `["nombre"]` | 2026-06-26 |
| `demo_email_followup` | Demo · Email follow-up | `Te dejo este recordatorio · Appril` | 148 | 161 | `["nombre"]` | 2026-06-26 |
| `demo_email_intro` | Demo · Email intro a Appril | `Hola {{nombre}} — algo que te puede ayudar con las inasistencias` | 204 | 237 | `["nombre"]` | 2026-06-26 |
| `hot_discovery_email_v1_1782510240077` | HOT · Discovery email v1 | `{{nombre}}, una pregunta sobre tu agenda` | 641 | 905 | `["nombre"]` | 2026-06-26 |
| `hot_followup_email` | HOT · Email follow-up | `Re: Appril para tu consultorio` | 294 | 1768 | `["nombre"]` | 2026-06-26 |
| `hot_intro_email` | HOT · Email intro | `Appril: reduce inasistencias en tu consultorio` | 412 | 2194 | `["nombre"]` | 2026-06-26 |
| `super_hot_email` | SUPER_HOT · Email último recurso | `{{nombre}}, te escribo por email` | 444 | 1974 | `["nombre"]` | 2026-06-26 |
| `warm_reactivation_1` | WARM · Email reactivación #1 | `{{nombre}}, sigues con el problema de las inasistencias?` | 304 | 1985 | `["nombre"]` | 2026-06-26 |
| `warm_reactivation_2` | WARM · Email reactivación #2 | `Esto le funcionó a consultorios como el tuyo` | 401 | 2351 | `["nombre"]` | 2026-06-26 |

> **No existe columna `preheader`** en `message_templates`. El único "preheader" real (texto oculto preheader) está embebido en el HTML de `hot_discovery_email_v1`. **No existe columna de campaña/segmento dentro del template** — la asociación template→segmento vive en `campaigns.segment_filter` y `campaigns.template_keys` (ver §4).
> Columnas reales: `id, workspace_id, template_key, name, description, channel, subject, html_body, text_body, wa_template_name, wa_language, wa_components, variables, status, version, created_by, created_at, updated_at`.
> **Única variable usada hoy: `{{nombre}}`** (en BD; el payload de cola solo lleva `full_name`).

### 2.2 Hardcodeado en código — 1 template (el email de RESULTADO del Discovery)

| Fuente | subject | from | trigger | desplegado |
|---|---|---|---|---|
| `supabase/functions/send-discovery-email/index.ts` (`renderHtml`/`renderText`, líneas ~176–351) | `Tu diagnóstico de agenda está listo` | `Appril <diagnostico@appril.co>` (env `DISCOVERY_FROM_EMAIL`) | AFTER INSERT en `discovery_leads` (trigger pg_net) | **Sí, activo** |

Este es **el email que cierra el bucle** email→Discovery→**resultado**→WhatsApp. Cuerpo completo en §13 (TEMPLATE 11).

---

## 3. Métricas por template (con la verdad del volumen)

**Realidad:** de los 11 templates, **solo 2 se han enviado alguna vez por la cola**, y prácticamente todo el volumen es de **uno** (`hot_intro_email`, batch del 14-jun). Los demás 8 de BD **nunca se han enviado** (0 filas en `message_queue`). El email de Discovery **aún no se ha disparado nunca** (0 envíos; 0 Discovery desde email).

### 3.1 `message_queue` por template (canal email)

| template_key | status | filas | enviados (`sent_at`) | rango programado |
|---|---|--:|--:|---|
| `hot_intro_email` | sent | 87 | 87 | 2026-06-14 22:45 |
| `demo_email_intro` | sent | 1 | 1 | 2026-05-23 01:09 |
| *(los otros 8 templates de BD)* | — | **0** | 0 | nunca encolados |
| `hot_discovery_email_v1...` | — | **0** | 0 | nunca encolado |

### 3.2 Eventos de email en `lead_events` (totales del sistema, no por template)

| event_type | n | primer evento | último evento |
|---|--:|---|---|
| `message_sent` (email) | 89 | 2026-05-23 | 2026-06-14 |
| `email_delivered` | 86 | 2026-05-23 | 2026-06-14 |
| `email_opened` | 63 | 2026-05-23 | 2026-06-28 |
| `email_bounced` | 3 | 2026-06-14 | 2026-06-15 |
| `email_clicked` | 2 | 2026-06-14 | 2026-06-15 |

> **Por qué no hay tabla "queued/sent/opened/clicked por template":** los eventos SES en `lead_events.metadata` **NO llevan `template_key` ni `campaign_id`** (solo el payload crudo de SES: From/Reply-To/To/Subject/messageId). La única forma de atribuir por template es **inferir por `Subject` o por join `lead_id`→campaña/fecha**. En la práctica **todos los opens reales corresponden al subject `Appril: reduce inasistencias en tu consultorio` = `hot_intro_email`**. Por eso solo ese template tiene métricas con sentido:
> - **hot_intro_email** ≈ 87 enviados · 86 delivered · ~63 opens · 2 clicks · 3 bounces.
> - **Opens inflados:** varios opens vienen de `GoogleImageProxy`/prefetch de Gmail (MPP). El número real de lectura humana es menor. **No usar 63/89 como "open rate" de campaña.**
> - **Clicks ≈ 2** sobre ~86 entregados ⇒ señal de **CTA débil** (apunta a home, sin razón fuerte para click).
> - **Demo/COLD/WARM/SUPER_HOT/Discovery templates:** sin datos (nunca enviados).

---

## 4. Mapa template → campaña / secuencia / automatización

### 4.1 Campañas (`campaigns`)

| name | canal | status | template_keys | segment_filter | started/ended | stats |
|---|---|---|---|---|---|---|
| Outreach · hot_intro_email | email | done | `hot_intro_email` | — | 26-may | sent 2 / opened 1 / clicked 1 |
| Outreach · hot_intro_email · 14 jun | email | done | `hot_intro_email` | `marketing_segment:[HOT]` | 14-jun | (sin stats; aquí salió el batch de 87) |
| Outreach · demo_email_intro | email | done | `demo_email_intro` | — | 23-may | sent 1 / opened 1 |
| **HOT Email Test V1 — Discovery** | email | **draft** | `hot_discovery_email_v1_1782510240077` | `marketing_segment:[HOT]` | — | — |
| Secuencia · demo_email_intro | email | **running** | `demo_email_intro` | — | desde 22-jun | — |
| **Secuencia · hot_discovery_email_v1...** | email | **running** | `hot_discovery_email_v1...` | — | desde 26-jun | — |
| Outreach · alerta_interna_wa | whatsapp | done | `alerta_interna_wa` | — | — | sent 23 / failed 79 |
| Outreach · hot_followup_wa | whatsapp | done | `hot_followup_wa` | — | — | sent 1 / failed 3 |
| Outreach · demo_wa_intro | whatsapp | done | `demo_wa_intro` | — | — | sent 1 |
| Outreach · super_hot_intro_wa (+ ·14 jun) | whatsapp | done | `super_hot_intro_wa` | `[SUPER_HOT]` | — | sent 2 / failed 2 |
| Secuencia · referido_invitacion | whatsapp | running | `referido_invitacion` | — | desde 20-jun | — |
| Secuencia · alerta_interna_wa | whatsapp | running | `alerta_interna_wa` | — | desde 22-jun | — |
| Secuencia · hot_followup_wa | whatsapp | running | `hot_followup_wa` | — | desde 26-jun | — |
| Secuencia · warm_wa_if_opened | whatsapp | running | `warm_wa_if_opened` | — | desde 28-jun | — |
| Secuencia · super_hot_intro_wa | whatsapp | running | `super_hot_intro_wa` | — | desde 29-jun | — |

### 4.2 Secuencias de leads (`lead_sequences`) — **estado "active" pero estancadas**

| sequence_name | status | leads | última acción | próximas acciones futuras |
|---|---|--:|---|--:|
| `warm_reactivation` | active | **4.607** | (null) | **0** (next_action_at máx = 18-jun, ya pasó) |
| `hot_email_wa` | active | 170 | 14-jun | **0** (todas en el pasado) |
| `super_hot_wa` | active | 13 | 14-jun | **0** |

> **Riesgo/observación:** las 3 secuencias están marcadas `active` con **miles de leads enrolados**, pero **ninguna tiene `next_action_at` en el futuro** ⇒ están **paradas** (no van a disparar nada nuevo por sí solas). 4.607 leads "colgando" en `warm_reactivation` sin haber recibido nada. Cambiar un template **no afecta envíos programados** porque **no hay envíos programados a futuro** (ver §5).

### 4.3 Automatizaciones (`automations`) — solo 1 activa, y es de prueba

| name | trigger | status | usa templates |
|---|---|---|---|
| Prueba end-to-end · Email + WhatsApp hasta respuesta | manual | **active** | `demo_email_intro` → wait → `demo_wa_intro` → loop `wa_replied` → goal |
| "Nuevo" ×2, "prueba" | manual | draft | (vacías) |

> La única automatización activa es un **flujo de prueba** (waits de 2–3 min) que usa `demo_email_intro` + `demo_wa_intro`. No es producción real.

---

## 5. Estado de campañas/secuencias/cola — ¿riesgo al cambiar templates?

- **`message_queue`:** **0 filas con `scheduled_at` en el futuro** (todos los `future_scheduled = 0`). No hay envíos de email pendientes ni programados.
- **Secuencias:** 3 "active" pero **0 acciones futuras** (estancadas, ver §4.2).
- **Automatización:** 1 activa, de prueba, manual.
- **Campañas:** 2 de email `running` ("Secuencia · demo_email_intro" y "Secuencia · hot_discovery_email_v1") y 1 `draft` ("HOT Email Test V1 — Discovery"), pero **sin nada encolado**.

**Conclusión de riesgo:** **modificar/reescribir los templates HOY no afecta ningún envío en vuelo** — no hay cola futura. El único cuidado: la **campaña draft "HOT Email Test V1 — Discovery"** y la **secuencia running** apuntan a `hot_discovery_email_v1_...`; si reescribes ESE template, cambiarás lo que esa campaña enviaría cuando se lance. Todo lo demás es seguro de editar. (Ver §14.)

---

## 6. URLs y CTAs por template

| template_key | CTA (texto) | URL destino | problema | destino recomendado |
|---|---|---|---|---|
| `cold_intro_email` | "Ver demo gratuita (10 min)" | `https://appril.co` | home genérica, sin UTM, sin `dl` | `discovery.appril.co` + UTM + `dl` |
| `cold_followup_email` | "Ver cómo funciona" | `https://appril.co` | ídem | Discovery |
| `hot_intro_email` | "¿Me das 10 minutos esta semana?" | `https://appril.co` | ídem | Discovery |
| `hot_followup_email` | "Ver demo en 10 minutos" | `https://appril.co` | ídem | Discovery |
| `super_hot_email` | "Ver una demo de Appril" | `https://appril.co` | ídem | Discovery o WhatsApp directo |
| `warm_reactivation_1` | "Conocer Appril" | `https://appril.co` | ídem | Discovery |
| `warm_reactivation_2` | "Agendar una demo gratuita" | `https://appril.co` | ídem | Discovery |
| `demo_email_intro` | (sin botón; "¿demo de 10 min?") | — | sin CTA con link | Discovery |
| `demo_email_followup` | (sin botón; "responde este correo") | — | sin CTA con link | Discovery |
| `hot_discovery_email_v1...` | "Hacer mi diagnóstico de agenda" | `https://discovery.appril.co/?utm_source=crm&utm_medium=email&utm_campaign=hot_email_test_v1&utm_content=D` | **bien (UTM)** pero **sin `dl`/`lead_id`** ⇒ no atribuible por lead | añadir `&dl=<token>` / `lead_id` |
| **`send-discovery-email`** (resultado) | "Activar mi mes gratis de Appril" + botón WhatsApp | `https://www.appril.co/empezar` (+ UTM) y `https://wa.me/573112211772?text=...` | CTA de activación va a **`www.appril.co/empezar`** (registro), no a Discovery (correcto, es el cierre) | mantener; unificar dominio/medición |
| *todos (footer)* | "Cancelar suscripción" | `mailto:hola@appril.co?subject=Cancelar+suscripcion` | **baja por mailto**, no hay endpoint ni `List-Unsubscribe` | endpoint real de baja + header |

**Clasificación de dominios encontrados:** `appril.co` (home, 9 templates) · `discovery.appril.co` (1 template) · `www.appril.co/empezar` (email de resultado, registro) · `wa.me/573112211772` (email de resultado, sin tracking) · `mailto:hola@appril.co` (footer baja).

---

## 7. Variables: usadas hoy vs. disponibles

**Hoy se usa una sola: `{{nombre}}`** (renderizada desde `full_name` del payload de cola). El email de resultado de Discovery usa además `{{name}}, {{riskTitle}}, {{evidence}}, {{lostRevenue}}, {{adminHours}}, {{hiddenCost}}, {{ctaLabel}}, {{ctaUrl}}, {{waUrl}}, {{waLabel}}` (todas derivadas de `discovery_leads`).

**Disponibles desde `leads_master` (cobertura real medida sobre 20.789 leads):**

| variable | fuente (columna) | cobertura | confiabilidad | ¿usar en copy? | comentario |
|---|---|--:|---|---|---|
| first_name | `first_name` | 12.317 (59%) | media | **sí, con fallback** | 41% sin nombre ⇒ necesita default ("Hola,") |
| full_name | `full_name` | alta | media | sí (saludo) | es lo que hoy llega como `{{nombre}}` |
| city | `city` | 8.471 (41%) | media | con cuidado | <50% cobertura |
| country | `country` | — | media | no crítico | |
| source | `source` | alta | alta | no en copy | segmentación interna |
| marketing_segment | `marketing_segment` | 99,9% | alta | no en copy | routing/segmentación |
| referred_by_name | `referred_by_name` | 25 leads | alta donde existe | **sí (referidos)** | personaliza "te recomendó X" |
| opened_email | `opened_email` | flag | media | no en copy | segmentación |
| clicked_email | `clicked_email` | flag | media | no en copy | segmentación |
| whatsapp_e164 | `phone` (regex E.164) | 8.541 (41%) | alta | enrutar a WA | cuello de botella WA |
| specialization | `specialization` | 374 (1,8%) | baja | **no** (cobertura mínima) | no personalizar por especialidad aún |
| risk_dominant (post-Discovery) | `discovery_leads.risk_dominant` | solo quien hizo Discovery | alta | **sí, post-Discovery** | alimenta resultado + WhatsApp |
| selected_currency (post-Discovery) | `discovery_leads.selected_currency` | solo Discovery | alta | sí (montos) | formato de moneda |
| recommended_action / primary_cta | `discovery_leads.recommended_action` / `primary_cta_*` | solo Discovery | alta | sí | handoff a WhatsApp |

> **Regla práctica:** personalizar solo con `first_name` (con fallback) y, post-Discovery, con los campos de `discovery_leads`. **No** personalizar por `specialization` ni `city` masivamente (cobertura insuficiente).

---

## 8. Riesgos de copy por template

| template_key | problema | fragmento exacto | riesgo | prioridad |
|---|---|---|---|---|
| `cold_intro_email` | promesa fuerte no validada | "Resultado promedio: 40-90% menos inasistencias en los primeros 30 dias." | spam/legal | **alta** |
| `cold_intro_email` | "fundador" + Appril muy temprano | "Mi nombre es Mauricio Garcia, fundador de Appril…" | frío, vende producto antes del problema | media |
| `hot_intro_email` | promesa 40–90% (lista) | "40–90% menos inasistencias" | spam/legal | **alta** |
| `hot_intro_email` | CTA a home | "¿Me das 10 minutos esta semana?" → `appril.co` | CTA débil, sin Discovery | alta |
| `super_hot_email` | claim "hasta un 90%" | "reducir las inasistencias hasta un 90%" | promesa no validada | **alta** |
| `super_hot_email` | "el primer mes es gratis" temprano | "el primer mes es gratis" | descuento antes de valor | media |
| `warm_reactivation_1` | claim social no verificable | "ya esta ayudando a cientos de profesionales" | exageración | media |
| `warm_reactivation_2` | testimonios sin atribución | "Mis inasistencias bajaron de 6 por semana a menos de 1." | claims sin fuente | media |
| `cold_intro_email`/`hot_intro_email` | demasiado producto, no Discovery | "confirma las citas por WhatsApp… panel… llena espacios" | habla de features, no de diagnóstico | alta |
| `demo_email_intro` / `demo_email_followup` | sin CTA con link, sin footer, HTML mínimo | `<p>…¿demo de 10 min?</p>` | no lleva a ninguna acción medible; sin baja | media |
| `demo_email_intro` | **bug de escape**: `\\n` literal en text_body | `Hola {{nombre}},\\n\\nSoy Mauricio…` | el `\n` se muestra literal en texto plano | **alta (bug)** |
| **todos los de BD** | "Cancelar suscripción" por `mailto`, sin `List-Unsubscribe` | footer | deliverability/compliance | **alta (P0)** |
| `hot_discovery_email_v1...` | (el mejor) sin footer legal ni baja visible | — | falta footer/baja | media |
| varios | "Soy Mauricio… fundador" | cold/hot/discovery/super_hot | identidad antes que problema | baja-media |

> **Patrón transversal:** los copys **venden Appril y prometen reducción de %**, en lugar de **ofrecer un diagnóstico**. El único alineado a Discovery es `hot_discovery_email_v1` (no nombra Appril como software, ofrece "diagnóstico breve", no promete %).

---

## 9. Deliverability (evidencia)

| # | ítem | estado | evidencia |
|---|---|---|---|
| 1 | Proveedor | **AWS SES** (v2) | config-set `appril-crm`, `sendingAccountId 516426598004`, rol `appril-crm-lambda-role`; `SESv2Client` en edge functions |
| 2 | From name/email (blasts CRM) | **`hola@appril.co`** | headers SES en `lead_events.metadata` |
| 2b | From (edge functions) | **`Appril <diagnostico@appril.co>`** | `send-discovery-email`/`inbox-send` (env `*_FROM_EMAIL`) |
| 3 | Reply-To (blasts) | **`mauricio@todoc.co`** | header SES en eventos |
| 3b | Reply-To (edge functions) | **ausente** | no se setea en código |
| 4 | List-Unsubscribe | **NO existe** | ningún header `List-Unsubscribe` en envíos ni en código |
| 5 | Endpoint de baja | **NO** (solo `mailto:`) | footer de templates = `mailto:hola@appril.co?subject=Cancelar+suscripcion` |
| 6 | Footer legal | **mínimo** | "Appril · appril.co — Cancelar suscripción"; sin dirección física/CAN-SPAM |
| 7 | SES SNS bounces | **manejado fuera del repo** | no hay función SNS en `supabase/functions`; eventos llegan a `lead_events` (Lambda externo) |
| 8 | Complaints | capturados como evento | `lead_events` admite `email_complaint`; sin handler en repo |
| 9 | Hard bounce → `can_email=false` | **sí (a nivel dato)** | trigger en `schema.sql`: `can_email=false` cuando `hard_bounce` o `unsubscribed_email`; `inbox-send` bloquea si `can_email=false` |
| 10 | Lista de supresión | **implícita** | `can_email`, `unsubscribed_email`, `hard_bounce`, `whatsapp_opted_in/can_whatsapp` en `leads_master` (no tabla dedicada) |
| 11 | Rate limit / warming / frequency cap | **NO en email** | solo cooldown de demo (24h, `app_config`); sin throttle de envío |
| 12 | SPF/DKIM/DMARC | **no documentado en repo** | verificación vive en SES/DNS, fuera del código |

**Números de salud actuales (sobre 20.789):** `unsubscribed_email` = 6 · `hard_bounce` = 76 · `can_email=false` = 447 · `opened_email`(lifetime) = 151 · `clicked_email` = 9.

**P0 antes de escalar:** (a) header `List-Unsubscribe` + endpoint real de baja; (b) footer con baja visible y datos del remitente; (c) decidir **un solo dominio de envío** (`hola@` vs `diagnostico@`) y alinear Reply-To; (d) throttle/warming para no quemar reputación con un blast de 12k.

---

## 10. Atribución email → Discovery

**Cadena objetivo:** `email enviado → click → discovery_started → contact_submitted → result_viewed → cta_clicked (WhatsApp)`.

**Lo que SÍ existe:**
- Funnel de Discovery instrumentado en `discovery_events` (event_name): `discovery_page_view (176)`, `discovery_started (63)`, `question_viewed (1116)`, `question_answered (455)`, `section_completed (138)`, `contact_form_viewed (65)`, `contact_submitted (23)`, `result_viewed (20)`, `cta_clicked (10)`, `discovery_abandoned (2)`.
- `discovery_leads` y `discovery_events` traen **UTMs completos** (`utm_source/medium/campaign/content/term`) + `landing_url` + `anonymous_session_id`.
- `discovery_leads.lead_id` enlaza con `leads_master` (los 20 actuales están enlazados).
- `lead_events` con `email_delivered/opened/clicked/bounced`.
- El email HOT de Discovery ya manda UTMs: `utm_source=crm&utm_medium=email&utm_campaign=hot_email_test_v1&utm_content=D`.

**Lo que NO se puede atribuir hoy:**
- **Email → lead individual:** la URL del Discovery **no lleva `lead_id` ni token `dl`** ⇒ no se sabe *qué lead* del CRM hizo *qué* Discovery a partir del click. Solo se atribuye a nivel **campaña** (por `utm_campaign`).
- **Open/click SES → template/campaña:** `lead_events.metadata` (payload SES) **no incluye `template_key` ni `campaign_id`**; hay que inferir por `Subject` o por join `lead_id`+fecha.
- Resultado actual: `discovery_leads` con `utm_medium='email'` = **0** ⇒ aún **ninguna** atribución real email→Discovery.

**Recomendación técnica mínima:**
1. Añadir a cada link de Discovery un **token `dl`** (o `lead_id` firmado) → propagarlo a `discovery_leads.lead_id`/`utm_term`.
2. Persistir `template_key`+`campaign_id` en `lead_events` al encolar (o un `dl` por mensaje) para cerrar open/click→template.
3. Estandarizar UTMs por template (no solo el HOT). Convención: `utm_source=crm`, `utm_medium=email`, `utm_campaign=<template_key>`, `utm_content=<variante>`, `utm_term=<dl token>`.

---

## 11. Segmentos y tamaños (datos de hoy)

| # | segmento | definición (resumen) | tamaño | canal recomendado | prioridad |
|---|---|---|--:|---|---|
| 1 | **HOT** email válido, sin Discovery | `marketing_segment=HOT` ∧ email_ok ∧ ¬discovery | **169** | email → Discovery | **P0 (piloto)** |
| 2 | **WARM** email válido, sin Discovery | `WARM` ∧ email_ok ∧ ¬discovery | **11.995** | email → Discovery | P1 (escalar tras piloto) |
| 3 | **WARM** con WhatsApp válido | `WARM` ∧ phone E.164 ∧ can_whatsapp | **8.218** | email + WhatsApp | P1 |
| 4 | **WARM** sin WA E.164 (email ok) | `WARM` ∧ email_ok ∧ ¬E.164 | **3.778** | solo email | P2 |
| 5 | **Referidos** | `referred_by_name` no nulo | **25** | WhatsApp/email cálido | P1 (alta conversión) |
| 6 | **Abrió, no hizo click** | email_ok ∧ opened ∧ ¬clicked | **136** | re-engage / asunto nuevo | P2 |
| 7 | **Hizo click, sin Discovery completado** | clicked ∧ ¬discovery_completed | **9** | empuje a Discovery / WhatsApp | P1 |
| 8 | **Completó Discovery, sin escribir por WA** | discovery_completed ∧ ¬E.164 | **0** | (n/a hoy) | — |
| 9 | **SUPER_HOT sin activación** | `SUPER_HOT` ∧ ¬`pagando_hoy` | **8** | WhatsApp directo (founder) | **P0** |
| 10 | **COLD** (solo tamaño) | `marketing_segment=COLD` | **8.504** | no en arranque | — |

**Validez base (medida):** email_ok total ≈ 20.5k; WARM email_ok 11.995, COLD email_ok 8.165, HOT 169, SUPER_HOT 13; teléfono E.164 = 8.541. `whatsapp_opted_in` ≈ todos (backfill previo) ⇒ **el límite WA es el formato E.164, no el opt-in.** `DO_NOT_EMAIL` = 81 (email_ok 0) → excluir siempre.

> **Recomendación de arranque:** piloto con **#1 (169 HOT)** + **#9 (8 SUPER_HOT)**, medir email→Discovery→WhatsApp con atribución `dl`, y solo entonces abrir **#2/#3 (WARM, ~12k)**.

---

## 12. Corpus editable — `message_templates` (10)

> Texto verbatim de BD. `\n` mostrado como salto real para edición. HTML completo incluido por template.

### TEMPLATE: `cold_intro_email`
**Uso:** COLD · intro. Campaña "Outreach · …" (nunca enviado por cola). **Asunto:** `Agenda inteligente para tu consultorio — Appril`
**Texto:**
```
Hola {{nombre}},

Mi nombre es Mauricio Garcia, fundador de Appril, una plataforma de agenda online con confirmacion automatica de citas por WhatsApp.

Trabajamos con consultorios medicos, psicologicos y odontologicos en toda Latinoamerica.

Resultado promedio: 40-90% menos inasistencias en los primeros 30 dias.

Ver demo gratuita: https://appril.co

Mauricio Garcia
Appril - appril.co
```
**HTML:**
```html
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head><body style="margin:0;padding:0;background:#f4f4f4;font-family:Arial,Helvetica,sans-serif;"><table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f4;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#fff;border-radius:8px;"><tr><td style="background:#00875A;padding:20px 28px;border-radius:8px 8px 0 0;"><span style="color:#fff;font-size:22px;font-weight:bold;">Appril</span></td></tr><tr><td style="padding:28px;color:#222;font-size:15px;line-height:1.7;"><p style="margin:0 0 16px">Hola {{nombre}},</p><p style="margin:0 0 16px">Mi nombre es Mauricio García, fundador de <strong>Appril</strong>, una plataforma de agenda online con confirmación automática de citas por WhatsApp.</p><p style="margin:0 0 16px">Trabajamos con consultorios médicos, psicológicos y odontológicos en toda Latinoamérica.</p><p style="margin:0 0 24px">Resultado promedio: <strong>40–90% menos inasistencias</strong> en los primeros 30 días.</p><a href="https://appril.co" style="background:#00875A;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-weight:bold;display:inline-block;">Ver demo gratuita (10 min)</a><p style="color:#888;font-size:13px;margin:24px 0 0">Mauricio García<br>Appril — appril.co</p></td></tr><tr><td style="padding:16px 28px;background:#f8f8f8;border-radius:0 0 8px 8px;border-top:1px solid #eee;"><p style="margin:0;color:#aaa;font-size:12px;">Appril · appril.co — <a href="mailto:hola@appril.co?subject=Cancelar+suscripcion" style="color:#aaa;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>
```
**CTA:** "Ver demo gratuita (10 min)" → `https://appril.co` · **Problemas:** 40–90%; home; "fundador"; vende producto, no Discovery; baja por mailto.

---

### TEMPLATE: `cold_followup_email`
**Uso:** COLD · follow-up. **Asunto:** `Re: Agenda inteligente — Appril`
**Texto:**
```
Hola {{nombre}},

Hace unos dias te escribi sobre Appril. Solo quiero asegurarme de que mi correo no se perdio.

Si las inasistencias de pacientes te afectan, tengo 10 minutos libres esta semana para mostrarte como funciona.

https://appril.co

Mauricio - Appril
```
**HTML:**
```html
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head><body style="margin:0;padding:0;background:#f4f4f4;font-family:Arial,Helvetica,sans-serif;"><table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f4;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#fff;border-radius:8px;"><tr><td style="background:#00875A;padding:20px 28px;border-radius:8px 8px 0 0;"><span style="color:#fff;font-size:22px;font-weight:bold;">Appril</span></td></tr><tr><td style="padding:28px;color:#222;font-size:15px;line-height:1.7;"><p style="margin:0 0 16px">Hola {{nombre}},</p><p style="margin:0 0 16px">Hace unos días te escribí sobre Appril. Solo quiero asegurarme de que mi correo no se perdió.</p><p style="margin:0 0 24px">Si las inasistencias de pacientes te afectan, tengo 10 minutos libres esta semana para mostrarte nuestra solución.</p><a href="https://appril.co" style="background:#00875A;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-weight:bold;display:inline-block;">Ver cómo funciona</a><p style="color:#888;font-size:13px;margin:24px 0 0">Mauricio — Appril</p></td></tr><tr><td style="padding:16px 28px;background:#f8f8f8;border-radius:0 0 8px 8px;border-top:1px solid #eee;"><p style="margin:0;color:#aaa;font-size:12px;">Appril · appril.co — <a href="mailto:hola@appril.co?subject=Cancelar+suscripcion" style="color:#aaa;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>
```
**CTA:** "Ver cómo funciona" → `https://appril.co` · **Problemas:** home; sin Discovery; baja por mailto.

---

### TEMPLATE: `hot_intro_email`  *(el único con volumen real)*
**Uso:** HOT · intro. **Batch real de 87 envíos el 14-jun** (campaña "Outreach · hot_intro_email · 14 jun", filtro `[HOT]`). **Asunto:** `Appril: reduce inasistencias en tu consultorio`
**Texto:**
```
Hola {{nombre}},

Soy Mauricio Garcia, fundador de Appril. Ayudamos a profesionales de salud a reducir las inasistencias sin tener que llamar a cada paciente.

Appril confirma las citas por WhatsApp automaticamente y te da un panel para ver todo desde el celular.

Resultado promedio: 40-90% menos inasistencias en los primeros 30 dias.

Me das 10 minutos esta semana? https://appril.co

Mauricio Garcia - Appril
```
**HTML:**
```html
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head><body style="margin:0;padding:0;background:#f4f4f4;font-family:Arial,Helvetica,sans-serif;"><table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f4;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#fff;border-radius:8px;"><tr><td style="background:#00875A;padding:20px 28px;border-radius:8px 8px 0 0;"><span style="color:#fff;font-size:22px;font-weight:bold;">Appril</span></td></tr><tr><td style="padding:28px;color:#222;font-size:15px;line-height:1.7;"><p style="margin:0 0 16px">Hola {{nombre}},</p><p style="margin:0 0 16px">Soy Mauricio García, fundador de <strong>Appril</strong>. Muchos profesionales de salud que conocí me han preguntado cómo reducir las inasistencias sin tener que llamar a cada paciente manualmente.</p><p style="margin:0 0 16px">Appril lo hace automáticamente: confirma las citas por WhatsApp, llena los espacios vacíos y te da un panel para ver todo desde el celular.</p><p style="margin:0 0 8px"><strong>Resultado promedio en los primeros 30 días:</strong></p><ul style="margin:0 0 24px;padding-left:20px;"><li style="margin-bottom:8px">40–90% menos inasistencias</li><li style="margin-bottom:8px">Menos tiempo al teléfono llamando pacientes</li><li style="margin-bottom:8px">Agenda siempre llena</li></ul><a href="https://appril.co" style="background:#00875A;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-weight:bold;display:inline-block;">¿Me das 10 minutos esta semana?</a><p style="color:#888;font-size:13px;margin:24px 0 0">Mauricio García<br>Fundador, Appril</p></td></tr><tr><td style="padding:16px 28px;background:#f8f8f8;border-radius:0 0 8px 8px;border-top:1px solid #eee;"><p style="margin:0;color:#aaa;font-size:12px;">Appril · appril.co — <a href="mailto:hola@appril.co?subject=Cancelar+suscripcion" style="color:#aaa;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>
```
**CTA:** "¿Me das 10 minutos esta semana?" → `https://appril.co` · **Problemas:** 40–90% (lista); home; CTA débil (2 clicks/86); baja por mailto.

---

### TEMPLATE: `hot_followup_email`
**Uso:** HOT · follow-up. **Asunto:** `Re: Appril para tu consultorio`
**Texto:**
```
Hola {{nombre}},

Hace unos dias te escribi sobre Appril. Quiero ser breve:

Si las inasistencias no son un problema en tu consultorio, no te molesto mas.

Pero si todavia se te van citas sin aviso, tengo algo que podria ayudarte. Solo necesito 10 minutos.

https://appril.co

Mauricio - Appril
```
**HTML:**
```html
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head><body style="margin:0;padding:0;background:#f4f4f4;font-family:Arial,Helvetica,sans-serif;"><table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f4;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#fff;border-radius:8px;"><tr><td style="background:#00875A;padding:20px 28px;border-radius:8px 8px 0 0;"><span style="color:#fff;font-size:22px;font-weight:bold;">Appril</span></td></tr><tr><td style="padding:28px;color:#222;font-size:15px;line-height:1.7;"><p style="margin:0 0 16px">Hola {{nombre}},</p><p style="margin:0 0 16px">Hace unos días te escribí sobre Appril. Quiero ser breve:</p><p style="margin:0 0 16px">Si las inasistencias no son un problema en tu consultorio, no te molesto más.</p><p style="margin:0 0 24px">Pero si todavía se te van citas sin aviso, tengo algo que podría ayudarte. Solo necesito 10 minutos para mostrarte cómo funciona.</p><a href="https://appril.co" style="background:#00875A;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-weight:bold;display:inline-block;">Ver demo en 10 minutos</a><p style="color:#888;font-size:13px;margin:24px 0 0">Mauricio — Appril</p></td></tr><tr><td style="padding:16px 28px;background:#f8f8f8;border-radius:0 0 8px 8px;border-top:1px solid #eee;"><p style="margin:0;color:#aaa;font-size:12px;">Appril · appril.co — <a href="mailto:hola@appril.co?subject=Cancelar+suscripcion" style="color:#aaa;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>
```
**CTA:** "Ver demo en 10 minutos" → `https://appril.co` · **Problemas:** home; sin Discovery; baja por mailto. *(Buen ángulo "si no es problema, no te molesto" — reutilizable.)*

---

### TEMPLATE: `super_hot_email`
**Uso:** SUPER_HOT · último recurso (tras no responder WhatsApp). **Asunto:** `{{nombre}}, te escribo por email`
**Texto:**
```
Hola {{nombre}},

Te escribi por WhatsApp un par de veces sin recibir respuesta. Entiendo que estas ocupado/a, por eso te escribo tambien por aqui.

Soy Mauricio de Appril. Llevamos ya varios meses ayudando a consultorios a reducir las inasistencias hasta un 90% con confirmacion automatica por WhatsApp.

Si en algun momento quieres ver como funciona en 10 minutos, el primer mes es gratis.

https://appril.co

Mauricio Garcia
Fundador, Appril
```
**HTML:**
```html
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head><body style="margin:0;padding:0;background:#f4f4f4;font-family:Arial,Helvetica,sans-serif;"><table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f4;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#fff;border-radius:8px;"><tr><td style="background:#00875A;padding:20px 28px;border-radius:8px 8px 0 0;"><span style="color:#fff;font-size:22px;font-weight:bold;">Appril</span></td></tr><tr><td style="padding:28px;color:#222;font-size:15px;line-height:1.7;"><p style="margin:0 0 16px">Hola {{nombre}},</p><p style="margin:0 0 16px">Te escribí por WhatsApp un par de veces sin recibir respuesta. Entiendo que estás ocupado/a, por eso te escribo también por aquí.</p><p style="margin:0 0 16px">Soy Mauricio de <strong>Appril</strong>. Llevamos ya varios meses ayudando a consultorios a reducir las inasistencias hasta un 90% con confirmación automática por WhatsApp.</p><p style="margin:0 0 24px">Si en algún momento quieres ver cómo funciona en 10 minutos, con gusto me adapto a tu horario. El primer mes es gratis, sin compromiso.</p><a href="https://appril.co" style="background:#00875A;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-weight:bold;display:inline-block;">Ver una demo de Appril</a><p style="color:#888;font-size:13px;margin:24px 0 0">Mauricio García<br>Fundador, Appril</p></td></tr><tr><td style="padding:16px 28px;background:#f8f8f8;border-radius:0 0 8px 8px;border-top:1px solid #eee;"><p style="margin:0;color:#aaa;font-size:12px;">Appril · appril.co — <a href="mailto:hola@appril.co?subject=Cancelar+suscripcion" style="color:#aaa;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>
```
**CTA:** "Ver una demo de Appril" → `https://appril.co` · **Problemas:** "hasta un 90%"; mes gratis temprano; home.

---

### TEMPLATE: `warm_reactivation_1`
**Uso:** WARM · reactivación #1. (Secuencia `warm_reactivation`: 4.607 leads, estancada.) **Asunto:** `{{nombre}}, sigues con el problema de las inasistencias?`
**Texto:**
```
Hola {{nombre}},

Como van las inasistencias en tu consultorio?

Si siguen siendo un problema, Appril ya esta ayudando a cientos de profesionales a recuperar esas horas perdidas con confirmacion automatica por WhatsApp.

El primer mes es completamente gratis.

https://appril.co

Mauricio Garcia - Appril
```
**HTML:**
```html
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head><body style="margin:0;padding:0;background:#f4f4f4;font-family:Arial,Helvetica,sans-serif;"><table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f4;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#fff;border-radius:8px;"><tr><td style="background:#00875A;padding:20px 28px;border-radius:8px 8px 0 0;"><span style="color:#fff;font-size:22px;font-weight:bold;">Appril</span></td></tr><tr><td style="padding:28px;color:#222;font-size:15px;line-height:1.7;"><p style="margin:0 0 16px">Hola {{nombre}},</p><p style="margin:0 0 16px">¿Cómo van las inasistencias en tu consultorio?</p><p style="margin:0 0 16px">Si siguen siendo un problema, quiero contarte que <strong>Appril</strong> ya está ayudando a cientos de profesionales de salud en Colombia y Latinoamérica a recuperar esas horas perdidas.</p><p style="margin:0 0 16px">La plataforma confirma automáticamente las citas por WhatsApp, envía recordatorios y te avisa cuando un paciente cancela para que puedas llenar el espacio.</p><p style="margin:0 0 24px"><strong>El primer mes es completamente gratis.</strong></p><a href="https://appril.co" style="background:#00875A;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-weight:bold;display:inline-block;">Conocer Appril</a><p style="color:#888;font-size:13px;margin:24px 0 0">Mauricio García — Appril</p></td></tr><tr><td style="padding:16px 28px;background:#f8f8f8;border-radius:0 0 8px 8px;border-top:1px solid #eee;"><p style="margin:0;color:#aaa;font-size:12px;">Appril · appril.co — <a href="mailto:hola@appril.co?subject=Cancelar+suscripcion" style="color:#aaa;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>
```
**CTA:** "Conocer Appril" → `https://appril.co` · **Problemas:** "cientos de profesionales"; mes gratis; home. *(Asunto-pregunta es buen gancho para Discovery.)*

---

### TEMPLATE: `warm_reactivation_2`
**Uso:** WARM · reactivación #2 (prueba social). **Asunto:** `Esto le funcionó a consultorios como el tuyo`
**Texto:**
```
Hola {{nombre}},

Esta semana hable con mas de 50 profesionales de salud. La queja mas comun: pacientes que no aparecen sin avisar.

Lo que nos contaron despues de usar Appril:
- "Mis inasistencias bajaron de 6 por semana a menos de 1."
- "El WhatsApp automatico me ahorro 2 horas diarias."

Te gustaria ver como funciona para tu consultorio? Son solo 10 minutos.

https://appril.co

Mauricio - Appril
```
**HTML:**
```html
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head><body style="margin:0;padding:0;background:#f4f4f4;font-family:Arial,Helvetica,sans-serif;"><table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f4;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#fff;border-radius:8px;"><tr><td style="background:#00875A;padding:20px 28px;border-radius:8px 8px 0 0;"><span style="color:#fff;font-size:22px;font-weight:bold;">Appril</span></td></tr><tr><td style="padding:28px;color:#222;font-size:15px;line-height:1.7;"><p style="margin:0 0 16px">Hola {{nombre}},</p><p style="margin:0 0 16px">Esta semana hablé con más de 50 profesionales de salud. La queja más común: pacientes que no aparecen sin avisar.</p><p style="margin:0 0 8px">Lo que nos contaron después de usar <strong>Appril</strong> durante un mes:</p><table width="100%" cellpadding="12" cellspacing="0" style="margin:16px 0 24px;border-collapse:collapse;"><tr><td style="background:#f0faf5;border-left:3px solid #00875A;padding:12px 16px;font-size:14px;font-style:italic;margin-bottom:8px;">"Mis inasistencias bajaron de 6 por semana a menos de 1."</td></tr><tr><td style="height:8px;"></td></tr><tr><td style="background:#f0faf5;border-left:3px solid #00875A;padding:12px 16px;font-size:14px;font-style:italic;">"El WhatsApp automático me ahorró 2 horas diarias."</td></tr></table><p style="margin:0 0 24px">¿Te gustaría ver cómo funciona para tu consultorio? Son solo 10 minutos.</p><a href="https://appril.co" style="background:#00875A;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-weight:bold;display:inline-block;">Agendar una demo gratuita</a><p style="color:#888;font-size:13px;margin:24px 0 0">Mauricio — Appril</p></td></tr><tr><td style="padding:16px 28px;background:#f8f8f8;border-radius:0 0 8px 8px;border-top:1px solid #eee;"><p style="margin:0;color:#aaa;font-size:12px;">Appril · appril.co — <a href="mailto:hola@appril.co?subject=Cancelar+suscripcion" style="color:#aaa;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>
```
**CTA:** "Agendar una demo gratuita" → `https://appril.co` · **Problemas:** testimonios sin atribución; home.

---

### TEMPLATE: `demo_email_intro`
**Uso:** Demo · intro (usado por la automatización de prueba y "Secuencia · demo_email_intro" running). **Asunto:** `Hola {{nombre}} — algo que te puede ayudar con las inasistencias`
**Texto (⚠️ contiene `\n` literal escapado — BUG):**
```
Hola {{nombre}},\n\nSoy Mauricio de Appril. Estoy ayudando a doctores como tú a reducir inasistencias con confirmaciones automáticas por WhatsApp.\n\n¿Te gustaría ver una demo de 10 minutos?\n\n— Mauricio
```
**HTML:**
```html
<p>Hola {{nombre}},</p><p>Soy Mauricio de <strong>Appril</strong>. Estoy ayudando a doctores como tú a reducir inasistencias con confirmaciones automáticas por WhatsApp.</p><p>¿Te gustaría ver una demo de 10 minutos?</p><p>— Mauricio</p>
```
**CTA:** ninguno con link · **Problemas:** **bug `\\n` literal en text_body**; sin footer/baja; sin CTA medible; HTML sin estructura/branding.

---

### TEMPLATE: `demo_email_followup`
**Uso:** Demo · follow-up. **Asunto:** `Te dejo este recordatorio · Appril`
**Texto:**
```
Hola {{nombre}}, quería traer este tema a tu radar otra vez. Si te interesa ver Appril en 10 minutos, responde este correo o agendamos directamente.
```
**HTML:**
```html
<p>Hola {{nombre}}, quería traer este tema a tu radar otra vez.</p><p>Si te interesa ver Appril en 10 minutos, responde este correo o agendamos directamente.</p>
```
**CTA:** ninguno con link · **Problemas:** sin footer/baja; sin CTA medible.

---

### TEMPLATE: `hot_discovery_email_v1_1782510240077`  *(★ único alineado a Discovery — patrón a replicar)*
**Uso:** HOT · Discovery. Campaña draft "HOT Email Test V1 — Discovery" (`[HOT]`) + "Secuencia · hot_discovery_email_v1" running. **Nunca enviado aún.** **Asunto:** `{{nombre}}, una pregunta sobre tu agenda`
**Texto:**
```
Hola {{nombre}},

Soy Mauricio, fundador de Appril.

Estoy revisando cómo profesionales que atienden pacientes por cita están manejando algo muy concreto: confirmaciones, cancelaciones y cambios de agenda.

A veces el problema no se ve como caos. Se ve como pacientes que no responden, cambios de hora, confirmaciones pendientes y tiempo administrativo que nadie mide.

Preparamos un diagnóstico breve para revisar dónde puede estar la fricción antes de pensar en automatizar nada.

Hacer mi diagnóstico de agenda:
https://discovery.appril.co/?utm_source=crm&utm_medium=email&utm_campaign=hot_email_test_v1&utm_content=D

Un saludo,
Mauricio
```
**HTML (incluye preheader oculto):**
```html
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">
Un diagnóstico breve para revisar confirmaciones, cambios y seguimiento sin pedirte una demo.
</div>

<p>Hola {{nombre}},</p>

<p>Soy Mauricio, fundador de Appril.</p>

<p>Estoy revisando cómo profesionales que atienden pacientes por cita están manejando algo muy concreto: confirmaciones, cancelaciones y cambios de agenda.</p>

<p>A veces el problema no se ve como caos. Se ve como pacientes que no responden, cambios de hora, confirmaciones pendientes y tiempo administrativo que nadie mide.</p>

<p>Preparamos un diagnóstico breve para revisar dónde puede estar la fricción antes de pensar en automatizar nada.</p>

<p><a href="https://discovery.appril.co/?utm_source=crm&amp;utm_medium=email&amp;utm_campaign=hot_email_test_v1&amp;utm_content=D">Hacer mi diagnóstico de agenda</a></p>

<p>Un saludo,<br>Mauricio</p>
```
**CTA:** "Hacer mi diagnóstico de agenda" → `https://discovery.appril.co/?utm_*` · **Aciertos:** ofrece diagnóstico (no demo/producto); no promete %; tiene preheader; UTMs. · **Pendiente:** sin `dl`/`lead_id` (no atribuible por lead); sin footer/baja; HTML sin branding ni botón estilizado.

---

## 13. Corpus editable — email hardcodeado (TEMPLATE 11)

### TEMPLATE: `send-discovery-email` (RESULTADO del Discovery)
**Fuente:** `supabase/functions/send-discovery-email/index.ts` · **Trigger:** AFTER INSERT en `discovery_leads` (pg_net) · **Idempotente** (chequea `discovery_email_sent` en `lead_events`). · **From:** `Appril <diagnostico@appril.co>` (env `DISCOVERY_FROM_EMAIL`) · **Sin Reply-To, sin List-Unsubscribe.**
**Asunto:** `Tu diagnóstico de agenda está listo`
**Preheader:** `Detectamos dónde se te pueden estar escapando confirmaciones, cancelaciones, tiempo y espacios.`
**Texto (plantilla):**
```
Hola, {{name}}

Tu diagnóstico de agenda está listo.

Tu principal oportunidad: {{riskTitle}}
{{evidence}}

Impacto estimado al año:
- Pérdida anual estimada: {{lostRevenue}}
- Horas administrativas / año: {{adminHours}}
- Costo oculto total: {{hiddenCost}}

Son estimaciones basadas en tus respuestas, no una promesa de ahorro.

Cómo te ayuda Appril:
- Confirmaciones automáticas por WhatsApp para reducir ausencias.
- Agenda centralizada que llena espacios vacíos.
- Menos trabajo manual: recuperas horas cada semana.

Prueba Appril 1 mes gratis (sin tarjeta):
{{ctaUrl}}

O actívalo por WhatsApp:
{{waUrl}}
```
**Estructura HTML (renderHtml):** header oscuro `#0f172a` "Appril" · saludo "Hola, {{name}} 👋" · título · "Tu principal oportunidad" ({{riskTitle}} + {{evidence}}) · 3 tarjetas de impacto (Pérdida anual / Horas admin / Costo oculto) · disclaimer "Son estimaciones… no una promesa de ahorro" · "Cómo te ayuda Appril" (3 bullets) · bloque oferta "Prueba Appril 1 mes gratis · Sin tarjeta" con **2 botones**: `{{ctaLabel}}` (azul `#0ea5e9` → `ctaUrl`) y `{{waLabel}}` (verde `#25D366` → `waUrl`) · footer "Recibiste este correo porque completaste el diagnóstico de agenda de Appril. · Appril · appril.co".
**Variables:** `{{name}}, {{riskTitle}}, {{evidence}}, {{lostRevenue}}, {{adminHours}}, {{hiddenCost}}, {{ctaLabel}}, {{ctaUrl}}, {{waLabel}}, {{waUrl}}`.
**`riskTitle` (mapa `risk_dominant` → texto):** `no_show(s)`→"Confirmaciones y ausencias que se te están escapando" · `cancellation(s)`→"Cancelaciones de último momento sin reemplazo" · `lost_appointments/lost`→"Citas que se pierden antes de agendarse" · `admin_time/admin/time`→"Tiempo administrativo que podrías recuperar" · `empty_slots/idle_capacity/capacity`→"Espacios vacíos en tu agenda sin llenar" · `whatsapp_overload/whatsapp`→"Saturación de WhatsApp en la coordinación de citas" · `manual_scheduling`→"Agendamiento manual propenso a errores" · `no_system`→"Falta de un sistema centralizado de agenda" · `revenue_leak`→"Ingresos que se te pueden estar filtrando" · fallback→"La principal oportunidad de tu agenda".
**URLs:** `ctaUrl` = `https://www.appril.co/empezar` (env `DISCOVERY_CTA_URL`) + UTMs (`utm_source=discovery_email`, `utm_medium=email`, `utm_campaign/content/term` desde el `discovery_lead`); `waUrl` = `https://wa.me/573112211772?text=Hola, recibí mi diagnóstico de Appril y quiero activar mi mes gratis.`; footer → `https://appril.co`.
**Moneda:** multi-divisa con FX y formato `es-CO`.
**Problemas:** sin Reply-To ni List-Unsubscribe; dominio remitente distinto (`diagnostico@` vs `hola@`); `wa.me` sin tracking; footer sin baja real.

### Otros contenidos hardcodeados (no email de campaña, para contexto)
- **`demo-callback/index.ts`** — 2 mensajes WhatsApp (confirmación/cancelación de demo), cierran con `https://www.appril.co/empezar`. Activo.
- **`inbox-send/index.ts`** — envío manual desde el inbox; envuelve el texto del usuario en HTML simple; From `Appril <diagnostico@appril.co>` (env `INBOX_FROM_EMAIL`, override por workspace); bloquea si `can_email=false`; asunto por defecto `Re: Appril`. Activo.

---

## 14. Riesgos antes de modificar

1. **`hot_discovery_email_v1_...` está en una campaña draft + una secuencia running.** Reescribirlo cambia lo que esos flujos enviarían al lanzarse. Los otros 8 templates de BD **no tienen flujos futuros** → edición segura.
2. **No hay cola futura** (`message_queue` future = 0) → editar templates **no interrumpe envíos en vuelo**.
3. **El email de resultado vive en código** (`send-discovery-email`), no en BD. Cambiarlo = **deploy de edge function** (canal Supabase), no edición en CRM. No tocar sin coordinar deploy.
4. **`demo_email_intro` tiene un bug de `\n` literal** en `text_body`; corregirlo es seguro (template sin volumen real) pero hay una secuencia running que lo usa.
5. **Deliverability P0 sin resolver:** lanzar un blast a WARM (~12k) **sin `List-Unsubscribe`/baja real/warming** arriesga reputación del dominio. No escalar antes de cerrarlo.
6. **Dos dominios de envío** (`hola@` vs `diagnostico@`): unificar antes de escalar para no fragmentar reputación/branding.
7. **Atribución sin `dl`:** si rediseñas sin añadir token por lead, seguirás sin poder medir email→Discovero por lead (solo por campaña).

---

## 15. Recomendación de orden de rediseño

1. **P0 — Deliverability (infra, no copy):** header `List-Unsubscribe` + endpoint de baja real + footer con baja visible y remitente; elegir **un** dominio de envío; throttle/warming. *(Habilita todo lo demás.)*
2. **P0 — `hot_discovery_email_v1`** (intro a Discovery): es el patrón correcto. Pulir: añadir `dl`/`lead_id` a la URL, footer/baja, branding y botón. Es el template del **piloto HOT (169) + SUPER_HOT (8)**.
3. **P1 — Email de resultado (`send-discovery-email`)**: ya es bueno; alinear remitente/Reply-To, añadir baja, y asegurar tracking en `wa.me` (cierra el bucle a WhatsApp Agent).
4. **P1 — Reescribir COLD/WARM/HOT/SUPER_HOT intro+followup hacia "diagnóstico"** (no "demo/producto"), **eliminando "40–90%"/"hasta 90%"** y CTAs a home → todos a `discovery.appril.co` con UTMs+`dl`. Orden por tamaño/valor: WARM intro (#2, 12k) tras validar piloto, luego followups.
5. **P2 — Re-engage** (#6 abrió-no-click: 136; #7 click-sin-Discovery: 9) con asunto/ángulo nuevo.
6. **P2 — Arreglar bug `\n` de `demo_email_intro`** y dotar a los demo-emails de CTA medible + footer, o deprecarlos.
7. **Atribución (transversal):** estandarizar UTMs por template + token `dl`; persistir `template_key`/`campaign_id` en `lead_events`.

---

### Apéndice — consultas y fuentes usadas (evidencia)
- **DB (CRM `hwiocriejizjdqqcfrsj`):** `message_templates` (bodies completos), `campaigns`, `automations`, `lead_sequences`, `message_queue`, `lead_events`, `discovery_leads`, `discovery_events`, `leads_master` (segmentos/cobertura). Todas las cifras de este doc salen de queries `SELECT` de solo lectura ejecutadas el 2026-06-29.
- **Código (repo `appril-crm`):** `supabase/functions/send-discovery-email/index.ts`, `inbox-send/index.ts`, `demo-callback/index.ts`; migraciones de dispatch de Discovery; `schema.sql` (triggers `can_email`).
- **Deliverability:** headers SES reales extraídos de `lead_events.metadata` (eventos `email_opened`): From `hola@appril.co`, Reply-To `mauricio@todoc.co`, config-set `appril-crm`. No se expusieron secrets/tokens/credenciales.
</content>
</invoke>
