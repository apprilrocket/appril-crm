# Auditoría CRM/Email → Discovery — Appril

> **Alcance:** auditoría técnica de solo lectura para rediseñar la estrategia de email cuyo objetivo es **email → click → Discovery → resultado → WhatsApp Agent → demo → activación**. No se implementó, deployó, modificó ni envió nada.
> **Fecha:** 2026-06-29 · **Proyecto Supabase:** `hwiocriejizjdqqcfrsj` (appril-crm) · **Repo:** `appril-crm`
> **System prompt del agente WhatsApp:** ver `docs/whatsapp-agent-system-prompt.md` (verbatim).
> **Nota de honestidad:** los volúmenes históricos de email son **muy bajos** (≈97 emails enviados por cola, 77 opens, 7 clicks, 28 Discovery completados). No hay base estadística para "tasas" confiables. Donde no hay datos, lo digo y propongo cómo medir. **No inventé métricas.**

---

## 1. Resumen ejecutivo

- **El CRM tiene 20.790 leads**, casi todos con email válido (20.425) y opt-in WhatsApp (20.788), pero **solo 8.542 con teléfono E.164 válido**. Distribución: WARM 11.997 · COLD 8.503 · HOT 171 · SUPER_HOT 14 · DO_NOT_EMAIL 81 · sin segmento 24.
- **Casi nadie ha hecho el Discovery todavía:** 28 `discovery_leads` en total. Es decir, el universo de 20k leads es **terreno virgen** para la estrategia "email → Discovery".
- **Los copys actuales NO están orientados al Discovery.** 9 de 10 templates de email apuntan a `https://appril.co` (home genérica) y venden Appril directamente con la promesa **"40–90% menos inasistencias"** (exagerada, riesgo spam). **Solo 1 template** (`hot_discovery_email_v1`) ya apunta a `discovery.appril.co` con UTMs — es el modelo a replicar.
- **El transporte funciona (AWS SES)** vía la edge `inbox-send`, pero la integración de email por workspace está **`unconfigured`** (usa fallback de env). **Falta instrumentación de deliverability crítica**: no hay header `List-Unsubscribe`, ni footer de baja visible en los templates de campaña, ni verificación de SPF/DKIM/DMARC desde el repo.
- **El tracking existe parcialmente:** hay eventos `email_delivered/opened/clicked/bounced` en `lead_events` y un funnel de Discovery instrumentado (`discovery_events`), pero **la atribución email→Discovery no es hermética** (la URL no lleva `lead_id`/`campaign_id`; solo el template nuevo lleva UTMs).
- **El agente de WhatsApp ya está preparado para recibir el handoff del Discovery** (lee `risk_dominant`, `recommendedAction`, `selectedCurrency`, oferta de mes gratis). El email es la pieza que falta para alimentar ese motor.

**Conclusión:** la base de datos es grande y rica para segmentar, pero la capa de email está pensada para "vender Appril", no para "llevar al Discovery". El rediseño es viable y de alto impacto, **pero antes de escalar hay que cerrar deliverability (P0)** y la atribución.

---

## 2. Estado actual de emails

- **Proveedor:** AWS SES (`SESv2Client`, `SendEmailCommand`) — `supabase/functions/inbox-send/index.ts:10`.
- **From por defecto:** `Appril <diagnostico@appril.co>` (env `INBOX_FROM_EMAIL`; la nueva `send-discovery-email` usa `DISCOVERY_FROM_EMAIL`).
- **Cola:** `public.message_queue` (channel `email`/`whatsapp`).
- **Envío real registrado:** `message_queue` → `email:sent` = **97**, `whatsapp:sent` = 38, `whatsapp:failed` = 138.
- **Templates de email:** 10 activos en `public.message_templates` (channel='email'). 7 templates de WhatsApp.
- **Worker:** memoria del proyecto indica `appril-sender` activo drenando `message_queue`; el envío de email lead-a-lead también puede dispararse por `inbox-send`.

---

## 3. Templates actuales (evidencia: `public.message_templates`)

Query: `select template_key,name,channel,status,subject,text_body,variables,updated_at from message_templates;`

### Email (channel='email') — todos `active`, variable única `{{nombre}}`

| key | asunto | CTA / URL | segmento | problema |
|---|---|---|---|---|
| `cold_intro_email` | "Agenda inteligente para tu consultorio — Appril" | "Ver demo gratuita" → `appril.co` | COLD | vende Appril; promesa 40–90%; URL genérica |
| `cold_followup_email` | "Re: Agenda inteligente — Appril" | `appril.co` | COLD | sin foco Discovery |
| `hot_intro_email` | "Appril: reduce inasistencias en tu consultorio" | "Me das 10 minutos?" → `appril.co` | HOT | producto-first; promesa 40–90% |
| `hot_followup_email` | "Re: Appril para tu consultorio" | `appril.co` | HOT | CTA débil |
| **`hot_discovery_email_v1`** | "{{nombre}}, una pregunta sobre tu agenda" | **"Hacer mi diagnóstico" → `discovery.appril.co/?utm_source=crm&utm_medium=email&utm_campaign=hot_email...`** | HOT | ✅ **único alineado al Discovery — modelo a seguir** |
| `super_hot_email` | "{{nombre}}, te escribo por email" | mes gratis → `appril.co` | SUPER_HOT | último recurso post-WA |
| `warm_reactivation_1` | "{{nombre}}, sigues con el problema de las inasistencias?" | `appril.co` | WARM | reactivación, no Discovery |
| `warm_reactivation_2` | "Esto le funcionó a consultorios como el tuyo" | `appril.co` | WARM | testimonios sin Discovery |
| `demo_email_intro` | "Hola {{nombre}} — algo que te puede ayudar con las inasistencias" | demo → responder | demo | ⚠️ cuerpo trae `\\n` literales (bug de escape) |
| `demo_email_followup` | "Te dejo este recordatorio · Appril" | responder/agendar | demo | recordatorio |

> **Cuerpos completos:** disponibles en la BD; el `hot_discovery_email_v1` (subject "{{nombre}}, una pregunta sobre tu agenda", CTA al Discovery con UTMs) es el único cuyo objetivo es el diagnóstico. Los demás venden Appril y mandan a la home.
> **Preheader:** **ningún template tiene preheader** (no hay campo ni texto preheader en el cuerpo). Gap.
> **Riesgo transversal:** la frase "40–90% menos inasistencias" aparece en 4 templates → promesa no verificada, gatillo de spam y de desconfianza.

### WhatsApp (channel='whatsapp') — usan plantillas Meta aprobadas
`super_hot_intro_wa`, `super_hot_followup_wa`, `hot_followup_wa`, `warm_wa_if_opened`, `demo_wa_intro`, `referido_invitacion`, `alerta_interna_wa`. (Detalle en `list_wa_templates`.)

---

## 4. Secuencias y automatizaciones actuales

**Tres mecanismos coexisten:**

1. **`automation_tick()`** — función PL/pgSQL ejecutada por **`pg_cron`** (job `automation-tick`, `* * * * *`). Recorre `automation_runs` activos sobre flujos de `automations` y, en nodos `send_email`/`send_whatsapp`, **encola en `message_queue`**. Guarda en JSONB el flujo. Estado: **1 automation activa, 3 draft**.
   - Guardas en el encolado: email → `can_email AND email`; whatsapp → `can_whatsapp AND phone IS NOT NULL` (⚠️ **sin validar E.164** — hueco ya detectado, parche pendiente en `20260626_1400_harden_whatsapp_guard.sql`).
   - Nodos `condition`/`goal`/`wait`/`exit` permiten delays y stop-conditions; `goal` evalúa `eval_run_condition` (puede cortar al cumplir objetivo).
2. **`lead_sequences`** — **4.791 filas activas**. Mecanismo de secuencias por lead (enrolamiento masivo). Requiere inspección de su motor para confirmar disparo/stop.
3. **`campaigns` + `crm_launch_campaign()`** — campañas one-shot. Estado: **7 running, 8 done, 1 draft**. `crm_launch_campaign` calcula audiencia elegible (regex E.164 para WA, `can_email` para email) y encola.

**Mapa actual (reconstruido):**
```
Lead → (marketing_segment) → automation/sequence/campaign → message_queue(channel,template_key,scheduled_at)
     → worker SES/WA → lead_events(message_sent/delivered/opened/...)
```

**Lo que NO está claro / falta verificar (gaps):**
- ❓ ¿Se detiene la secuencia cuando el lead **hace click**? No hay evidencia de stop-on-click en `automation_tick`.
- ❓ ¿Se detiene cuando **completa Discovery**? El `goal` podría, pero no hay condición `discovery_completed` cableada por defecto.
- ✅ Se detiene cuando responde por WhatsApp / pide baja: el **agente WhatsApp** marca `unsubscribed` ante stop-words (`whatsapp-agent/index.ts:578,720`).
- ✅ Respeta hard bounce / unsubscribe en email: `inbox-send` bloquea `can_email=false`. Pero **el encolado por automation/campaign depende de `can_email`**, que debe actualizarse por bounces.
- ❓ **Control de frecuencia / frequency cap:** no hay evidencia de límite por lead. Riesgo.

---

## 5. Segmentos del CRM (evidencia)

**Tabla resumen (query agregada sobre `leads_master`):**

| segmento | leads | email válido | WhatsApp válido (E.164) | abrió email | hizo click | completó Discovery | unsub | hard bounce |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| SUPER_HOT | 14 | 14 | 14 | 8 | 8 | 0 | 0 | 0 |
| HOT | 171 | 171 | 144 | 45 | 2 | 1 | 0 | 1 |
| WARM | 11.997 | 11.994 | 8.219 | 93 | 0 | 1 | 0 | 0 |
| COLD | 8.503 | 8.165 | 60 | 0 | 0 | 0 | 0 | 0 |
| DO_NOT_EMAIL | 81 | 81 | 81 | 6 | 0 | 0 | 6 | 75 |
| (sin segmento) | 24 | 0 | 24 | 0 | 0 | 0 | 0 | 0 |
| **TOTAL** | **20.790** | 20.425 | 8.542 | 152 | 10 | 28* | 6 | 76 |

\* `discovery_leads` total = 28 (la mayoría aún no atribuidos a un segmento histórico).

**Cobertura de campos clave (`leads_master`):** `first_name` 12.317 (59%) · `city` 8.471 (41%) · `specialization` 374 (1,8%) · `pagando_hoy` 6 · `alguna_vez_pago` 61 · `referred_by_name` 26 · `can_email` 20.343 · `whatsapp_opted_in` 20.788.

**Campos disponibles para segmentar (schema `leads_master`):** `marketing_segment`, `country`, `city`, `department`, `source`, `specialization`, `recovery_score`, `engagement_score`, `opened_email`, `clicked_email`, `last_contacted_at`, `last_channel_touched`, `next_best_action`, `pipeline_stage`, `whatsapp_opted_in`, `can_email`, `can_whatsapp`, `unsubscribed_email`, `hard_bounce`, `referred_by_name`, `total_citas`, `total_pacientes`, `pagando_hoy`, `is_todoc`, `is_colombia`. (De Discovery, vía `discovery_leads`: `risk_dominant`, `selected_currency`, `findings`, `frontend_calculations`.)

---

## 6. Fuentes de los leads (evidencia: `group by source`)

| source | leads | calidad esperada | consentimiento | canal sugerido |
|---|--:|---|---|---|
| `todoc` | 12.291 | media-alta (ex-usuarios Todoc, relación previa) | opt-in WA sí; email válido | **email + WA** (warm reactivation) |
| `colombia` | 8.420 | baja-media (base fría Colombia) | opt-in marcado; frío real | **email** (WA casi sin E.164) |
| `mixed` | 50 | residual | — | email |
| `appril_nps_self` | 19 | alta (auto-registro NPS) | propio | ambos |
| `appril_referral` | 7 | alta (referidos) | propio | WA + email |
| `discovery_form` | 1 | alta (vino del Discovery) | explícito | WA |
| `manual` / `test` | 2 | — | — | no contactar (test) |

**País:** Colombia 12.042 · México 2.841 · Chile 978 · Argentina 884 · Perú 769 · Ecuador 712 · España 678 · Venezuela 424 · (resto LATAM < 220 c/u). ⚠️ Hay 2 valores con encoding roto (`M�xico`, `CO`) — limpiar.

**Riesgo de contacto frío:** `colombia` (8.420) es la base más fría → mayor riesgo de spam/bounce; conviene **warming + email-first** y exclusión de Argentina del primer envío (FX/calidad).

---

## 7. Métricas históricas de email (evidencia: `lead_events` + `message_queue`)

> ⚠️ **Volumen ínfimo — no son tasas confiables, son conteos absolutos.**

| evento (lead_events) | n |
|---|--:|
| `message_sent` | 281 |
| `email_delivered` | 95 |
| `email_opened` | 77 |
| `email_clicked` | 7 |
| `email_bounced` | 3 |
| `wa_reply` | 102 · `wa_agent_reply` 95 |
| `demo_created` | 5 |
| `cta_clicked` (discovery) | 13 |
| `discovery_form_submitted` | 28 |

| message_queue | n |
|---|--:|
| `email:sent` | 97 |
| `whatsapp:sent` | 38 · `whatsapp:failed` | 138 |

**Lectura:** se han mandado ~97–281 emails en la historia; ~77 opens y **solo 7 clicks**. **No hay datos suficientes para open/click rate por template.** Lo que falta instrumentar para tener métricas reales por template/campaña: ver §14 (P0: `campaign_id`/`template_key` en cada send + agregación). **No hay métricas de spam complaints** (SES complaint feedback no parece capturado).

**Tabla por template:** *no se puede construir con fidelidad hoy* — `lead_events` de email no traen `template_key` de forma consistente. Recomendación: instrumentar (§14).

---

## 8. Tracking actual

- **UTMs:** solo `hot_discovery_email_v1` los lleva. Los demás van a `appril.co` sin UTM. ❌
- **Open tracking:** sí (`email_opened` 77 en `lead_events`) — probablemente vía eventos SES o pixel.
- **Click tracking:** sí pero mínimo (`email_clicked` 7). No hay wrapper de links propio evidente.
- **Funnel Discovery (instrumentado, `discovery_events`):** `discovery_page_view` 162 → `discovery_started` 55 → `contact_form_viewed` 51 → `contact_submitted` 31 → `result_viewed` 28 → `cta_clicked` 14. ✅ Bien instrumentado del lado Discovery.
- **Atribución email→Discovery:** **débil**. El Discovery captura `utm_*` y `anonymous_session_id`, pero **la URL del email no lleva `lead_id` ni `campaign_id`**, así que no se puede unir 1:1 el email enviado con el `discovery_lead` resultante (solo por UTM agregado).
- **IDs disponibles:** `message_queue.id`, `template_key`, `campaign_id` (en queue), `ses_message_id`, `wa_message_id`. En `discovery_leads`: `utm_*`, `landing_url`.

**Tracking mínimo propuesto (cadena completa):**
```
email_sent(template_key,campaign_id,lead_id) → email_click(lead_id) →
discovery_started(utm+session) → contact_submitted(discovery_lead_id,lead_id) →
result_viewed → cta_clicked(primary_cta_key) → wa_reply → demo_created → handoff
```
Pieza faltante clave: **propagar `lead_id`/`campaign_id`/`template_key` en la URL del CTA** (token, no PII — ver §13) y resolverlos en `submit_discovery_lead` para cerrar la atribución.

---

## 9. Deliverability y reputación

| Ítem | Estado (evidencia) |
|---|---|
| Proveedor | **AWS SES** (`inbox-send/index.ts:10`) |
| Dominio envío | `appril.co` (from `diagnostico@appril.co`) |
| From name / email | `Appril <diagnostico@appril.co>` (env `INBOX_FROM_EMAIL` / `DISCOVERY_FROM_EMAIL`) |
| Reply-to | ❓ no seteado explícitamente en `inbox-send` (revisar) |
| `workspace_integrations` email | **`status='unconfigured'`, `from_email=null`** → se envía por fallback de env, no por integración de workspace |
| SPF / DKIM / DMARC | ❓ **No verificable desde el repo** → requiere `dig TXT appril.co` / consola SES (recomendado antes de escalar) |
| Bounce handling | `hard_bounce` col + segmento `DO_NOT_EMAIL` (81, con 75 hard bounces) → hay supresión básica |
| Unsubscribe email | `unsubscribed_email` col (6) + `can_email` gate; **pero sin endpoint/footer visible** |
| `List-Unsubscribe` header | ❌ **No encontrado** en los senders → **P0 deliverability** |
| Warming / límites diarios / rate limit | ❌ No hay evidencia de warming ni frequency cap |
| Riesgo de quemar dominio | **ALTO si se envía a los 8.420 fríos de golpe** sin warming, sin List-Unsubscribe y con promesa "40–90%" |

---

## 10. Consentimiento / legal

| Control | Campo (`leads_master`) | Valor |
|---|---|---|
| Puede recibir email | `can_email` (bool) | 20.343 true |
| Baja de email | `unsubscribed_email` (bool) | 6 |
| Hard bounce | `hard_bounce` (bool) | 76 |
| Opt-in WhatsApp | `whatsapp_opted_in` (bool) | 20.788 |
| País | `country` | poblado |
| Fuente del consentimiento | `source` / `referral_campaign` | parcial |

- **Qué pasa al desuscribir:** WhatsApp → el agente marca `unsubscribed` (stop-words). Email → no se encontró endpoint/handler de unsubscribe HTTP. ❓ Gap.
- **Footer legal / política de privacidad:** ❌ no presente en los cuerpos de los templates de campaña.

**Clasificación de riesgo legal/deliverability por audiencia:**
| Audiencia | Riesgo |
|---|---|
| Base propia (ex-Todoc, NPS, referidos) | **Bajo-Medio** (relación previa) |
| Leads fríos (`colombia` 8.420) | **Alto** (frío + sin footer baja + sin List-Unsubscribe) |
| Referidos | Bajo |
| Hicieron Discovery | **Muy bajo** (consentimiento explícito) |
| Ya interactuaron (abrió/click/WA) | Bajo |

---

## 11. ICPs recomendados (5 segmentos accionables)

| # | Segmento (query) | Tamaño aprox. | Dolor probable | Mensaje | CTA | Riesgo | Prioridad |
|---|---|--:|---|---|---|---|---|
| 1 | **HOT con email válido, no completó Discovery** (`marketing_segment='HOT' and email like '%@%' and id not in (select lead_id from discovery_leads)`) | ~170 | inasistencias/WA manual; ya tuvo Todoc | "una pregunta sobre tu agenda" (modelo `hot_discovery_email_v1`) | Discovery | Bajo | **P0** |
| 2 | **WARM email-válido sin WhatsApp E.164** (`WARM and email and phone !~ E164`) | ~3.800 | reactivación; no alcanzable por WA | dolor invisible de agenda | Discovery | Medio | **P1** |
| 3 | **WARM con WhatsApp válido** (`WARM and phone ~ E164`) | ~8.219 | multicanal posible | email→Discovery, WA de respaldo | Discovery | Medio | P1 |
| 4 | **Referidos** (`referred_by_name is not null`) | 26 | confianza del referente | "me dijeron que esto le serviría" | Discovery | Bajo | P1 |
| 5 | **Abrió pero no hizo click** (`opened_email and not clicked_email`) | ~145 | interés tibio | reescritura de asunto/CTA, re-toque | Discovery | Bajo | P2 |
| (bonus) | **Completó Discovery, no escribió por WA** (`id in discovery_leads` sin `wa_reply`) | ~20 | ya diagnosticado, falta empujón | recordatorio con su `risk_dominant` | WhatsApp/Demo | Muy bajo | **P0** |

> El segmento COLD (8.503) queda **fuera del primer envío** hasta cerrar deliverability (warming + List-Unsubscribe).

---

## 12. Problemas de copy actual (orientado a conversión)

| template | problema principal | por qué afecta conversión | recomendación |
|---|---|---|---|
| `hot_intro_email` / `cold_intro_email` | empieza con "Soy Mauricio, fundador…" + explica Appril antes del dolor | el lector no tiene interés aún; se siente venta | abrir con el dolor/curiosidad, no con la bio |
| (4 templates) | promesa "40–90% menos inasistencias" | exagerada, no verificable → spam y desconfianza | quitar; usar lenguaje de diagnóstico ("revisar dónde se escapa") |
| casi todos | CTA a `appril.co` (home genérica) | no hay micro-compromiso ni medición; fricción alta | CTA único al **Discovery** con UTMs+token |
| todos | asuntos genéricos o de producto ("Appril: reduce inasistencias…") | bajo open rate | asunto de curiosidad/pregunta ("{{nombre}}, una pregunta sobre tu agenda") |
| todos | sin preheader | se desperdicia el segundo gancho en la bandeja | añadir preheader |
| `warm_reactivation_2` | demasiada info + testimonios sin foco | dispersa, no lleva a una acción | una idea, un CTA: el Discovery |
| todos | personalización solo `{{nombre}}` (59% cobertura) | poca relevancia; "Hola ," si falta | usar fallback "Doctor(a)"; sumar ciudad/especialidad donde haya |
| `demo_email_intro` | `\\n` literales en el cuerpo (bug de escape) | se ve roto | corregir escape |
| general | lenguaje de software ("plataforma", "panel") | el ICP piensa en su agenda, no en software | hablar de agenda/pacientes/tiempo, no de features |

---

## 13. Oportunidades psicológicas de conversión

- **Curiosidad > venta:** el objetivo del email NO es explicar Appril, es abrir un loop ("¿dónde se te está escapando la agenda?") que solo cierra el Discovery.
- **Diagnóstico como micro-compromiso (Fogg):** "hacer mi diagnóstico" es de baja fricción vs "agendar demo". El Discovery ya hace el trabajo de convicción.
- **Especificidad del dolor (Challenger):** nombrar confirmaciones/cancelaciones/huecos/tiempo administrativo crea reconocimiento ("eso me pasa").
- **Tensión sin promesa:** "una cita agendada todavía puede terminar en hueco" crea tensión sin prometer cifras.
- **Coherencia de marca con el agente WA:** el agente abre reconociendo el `risk_dominant` del Discovery — el email debe sembrar exactamente ese lenguaje (no-shows, cancelaciones tardías, WhatsApp manual, tiempo administrativo).

---

## 14. Campañas recomendadas (estrategia, sin copys finales)

| Campaña | Segmento ideal | Tamaño CRM | CTA | Secuencia | Riesgo deliverability | Métrica principal | Stop condition |
|---|---|--:|---|---|---|---|---|
| **A — Dolor invisible de agenda** ("una cita agendada puede terminar en hueco") | HOT + WARM email-válido sin Discovery | ~12.000 (escalonar) | Discovery | intro → +3d follow-up | Medio (escalonar, warming) | Discovery completados | click / Discovery / WA reply |
| **B — WhatsApp administrativo** ("¿cuánto tiempo se va persiguiendo pacientes por WhatsApp?") | WARM con dolor WA manual | ~8.000 | Discovery | intro → +4d | Medio | CTR → Discovery | Discovery completado |
| **C — Cancelaciones tardías** ("una cancelación tarde mata un espacio completo") | WARM/HOT | ~6.000 | Discovery | intro → +4d | Medio | Discovery started | click |
| **D — Asistente saturada** ("su asistente no debería ser el sistema de confirmación") | leads con asistente / odontología | subconjunto (specialization 374 + heurística) | Discovery | intro → +5d | Bajo | Discovery completado | click |
| **E — Referidos** ("me dijeron que este diagnóstico podía servirle") | `referred_by_name` | 26 | Discovery (o WA) | 1 toque cálido | Bajo | respuesta/Discovery | cualquier respuesta |

**Regla común:** una sola idea por email, CTA único al Discovery, máximo 1 follow-up, **stop al click o al Discovery completado** (cablear `goal: discovery_completed`).

---

## 15. Variables dinámicas disponibles para personalización

| variable | campo fuente | cobertura | confiabilidad | ¿usar en copy? |
|---|---|--:|---|---|
| nombre | `first_name` / deriva de `full_name` | 59% directo, 100% con fallback | alta (fallback "Doctor(a)") | **Sí** |
| ciudad | `city` | 41% | media | sí, con fallback (no forzar) |
| país | `country` | ~100% | alta | sí (segmentación, no copy) |
| especialidad | `specialization` | 1,8% | baja | **No** (cobertura insuficiente → falsa personalización) |
| referido | `referred_by_name` | 26 leads | alta | **Sí** (solo campaña E) |
| source | `source` | 100% | alta | no en copy (segmentación) |
| segmento | `marketing_segment` | 100% | alta | no en copy |
| dolor / `risk_dominant` | `discovery_leads.findings` | solo 28 (post-Discovery) | alta | **Sí** pero solo post-Discovery (no en email de captación) |
| `estimated_lost` / `currency` | `discovery_leads.frontend_calculations` | post-Discovery | alta | sí, post-Discovery |
| `opened_email`/`clicked_email` | `leads_master` | 100% bool | media | segmentación, no copy |

> **Regla anti-creepy:** en el email de captación (pre-Discovery) **no** tenemos dolor/cifras del lead → personalización limitada a nombre + (ciudad). El dolor/risk se usa **después**, en WhatsApp y emails post-Discovery.

---

## 16. URLs / CTAs recomendados

- **URL Discovery (producción):** `https://discovery.appril.co/` (confirmado en código y en el system prompt del agente WA).
- **Staging:** no se encontró ambiente staging documentado. ❓
- **UTMs:** solo el template nuevo los usa. Estandarizar.

**Estructura estándar propuesta:**
```
https://discovery.appril.co/?utm_source=email&utm_medium=crm&utm_campaign={{campaign_key}}&utm_content={{template_key}}&dl={{token}}
```
- **No exponer `lead_id` crudo** (PII/enumerable). Usar un **token opaco** (`dl=`) que el Discovery resuelva a `lead_id`/`campaign_id` server-side (tabla `discovery_link_tokens` o HMAC firmado). Esto cierra la atribución email→Discovery sin filtrar PII.
- CTA por segmento: **email siempre → Discovery** (el agente WhatsApp ya decide cuándo mantener en WA vs mandar al Discovery). Reservar CTA directo a WhatsApp solo para post-Discovery o referidos calientes.

---

## 17. Instrumentación faltante (priorizada)

**P0 (obligatorio antes de campañas serias):**
- `List-Unsubscribe` header + endpoint de baja + footer legal en todos los templates de campaña.
- Supresión robusta de hard bounces / complaints desde SES (SNS → actualizar `can_email`/`hard_bounce`).
- `campaign_id` + `template_key` propagados en cada send y en `lead_events` (para métricas reales por campaña).
- Token de atribución (`dl=`) email→Discovery.
- Warming + límite diario para no quemar `appril.co` (sobre todo con la base fría).
- Verificar SPF/DKIM/DMARC del dominio.

**P1 (importante):**
- Dashboard de funnel email→Discovery→WA (agregación de `lead_events`+`discovery_events`).
- Stop-conditions cableadas: `goal: discovery_completed` / stop-on-click.
- Frequency cap por lead.
- Snapshots de segmento por campaña (audiencia reproducible).

**P2 (después):**
- A/B testing de asunto/CTA.
- Versionado de templates.
- Alertas de deliverability (bounce/complaint rate).

---

## 18. Riesgos

| Riesgo | Prob. | Impacto | Mitigación |
|---|---|---|---|
| Quemar dominio enviando a 8.420 fríos sin warming/List-Unsubscribe | Alta | Alto | warming, escalonar, P0 deliverability, empezar por base propia |
| Promesa "40–90%" → spam/quejas | Alta | Alto | reescribir copy hacia diagnóstico |
| Atribución email→Discovery incompleta | Cierta hoy | Medio | token `dl=` + `campaign_id`/`template_key` |
| Métricas no confiables (volumen ínfimo) | Cierta | Medio | instrumentar antes de "optimizar" |
| `workspace_integrations` email `unconfigured` | Cierta | Medio | configurar o documentar el fallback de env |
| Sin frequency cap | Media | Medio | cap por lead |
| Encoding de país roto / specialization 1,8% | Media | Bajo | limpiar datos; no personalizar por especialidad |
| Hueco E.164 en `automation_tick` (WA) | Media | Medio | aplicar parche pendiente |

---

## 19. Próximos pasos

1. **Cerrar P0 de deliverability** (List-Unsubscribe, supresión SES, SPF/DKIM/DMARC, warming) — antes de cualquier envío masivo.
2. **Estandarizar la URL del Discovery** con UTMs + token `dl=` y resolverlo en `submit_discovery_lead`.
3. **Rediseñar copys** con el `hot_discovery_email_v1` como plantilla base: asunto-pregunta, dolor-first, CTA único al Discovery, preheader, footer legal. Quitar "40–90%".
4. **Lanzar P0 con la base propia caliente** (Campaña A sobre HOT + segmento "Discovery no completado", ~170 + WARM escalonado), midiendo Discovery completados.
5. **Cablear stop-conditions** (click / Discovery completado) y `campaign_id`/`template_key` en cada send.
6. **Construir el dashboard** email→Discovery→WA para tener tasas reales.

**Criterio de éxito:** el sistema completo medible de punta a punta — `email_sent → email_click → discovery_started → contact_submitted → result_viewed → cta_clicked → wa_reply → demo → activación` — con atribución por lead/campaña y deliverability sana.

---

### Anexos / evidencia
- System prompt agente WhatsApp: `docs/whatsapp-agent-system-prompt.md` (verbatim).
- Tablas consultadas: `leads_master`, `message_templates`, `message_queue`, `lead_events`, `discovery_leads`, `discovery_events`, `workspace_integrations`, `automations`, `lead_sequences`, `campaigns`.
- Edge functions de email: `supabase/functions/inbox-send/index.ts` (SES), `supabase/functions/send-discovery-email/index.ts` (nueva, Fase 1, sin deploy).
- Queries de conteo: incluidas inline en cada sección (reproducibles en el proyecto `hwiocriejizjdqqcfrsj`).
