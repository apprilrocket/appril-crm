# Agente de Ventas WhatsApp — Appril CRM

> ⚠️ **Fuente de verdad: el código.** El agente vive en
> `appril-crm/supabase/functions/whatsapp-agent/index.ts` (proyecto Supabase
> `hwiocriejizjdqqcfrsj`). Este documento describe cómo funciona el sistema real
> desplegado. Si tocas el comportamiento, edita la edge function y vuelve a
> desplegar (`supabase functions deploy whatsapp-agent`). No hay tabla
> `lead_conversations`: el historial vive en `lead_events`.

## Qué es

Asesora comercial conversacional de Appril por WhatsApp. Cuando un lead (de la
base o entrante) escribe al número del CRM, el agente responde con **Claude
(claude-sonnet-4-6)** siguiendo un guion consultivo de ventas: diagnostica el
dolor, entrega un insight, dispara una **demo viva** y lleva al cierre (registro
o handoff a Mauricio).

**Estado:** desplegado y activo (edge function `whatsapp-agent`). Es el **único
receptor** de los webhooks de WhatsApp del número del CRM — procesa tanto los
mensajes entrantes como los estados de salida (sent/delivered/read/failed) de los
templates que envía `appril-sender`.

## Arquitectura real (flujo end-to-end)

1. Meta (WhatsApp Cloud API) entrega el webhook directo a la edge function.
2. Verifica firma HMAC (`x-hub-signature-256` con `WA_APP_SECRET`).
3. Por cada mensaje entrante (`handleMessage`):
   - Resuelve el lead por teléfono; si no existe, lo crea como `COLD`
     (`source = whatsapp_inbound`).
   - **Deduplica** por `wa_message_id` (índice único `uq_lead_events_wa_reply_wamid`) —
     evita responder dos veces si Meta reintenta.
   - Guarda el mensaje del usuario como `lead_events.wa_reply`.
   - Aplica **salvaguardas** (ver sección): opt-out, contestador automático,
     pausa de secuencias, agente pausado.
   - Carga los **últimos 20** `wa_reply`/`wa_agent_reply` como historial.
   - Construye el contexto del lead (segmento, referido, discovery, demo) y llama
     a Claude con el system prompt.
   - Parsea marcadores, **normaliza el link de registro**, envía la respuesta por
     WhatsApp y la guarda como `wa_agent_reply`.
   - Post-proceso: crea demo viva y/o ejecuta handoff si corresponde.
4. Estados de salida (`handleStatus`): registra `wa_<status>`; en `failed` marca
   la fila de `message_queue` y, ante 131026 (número sin WhatsApp), pone
   `can_whatsapp = false`.

## Identidad y voz

- **Nombre:** Appril. Asesora mujer, consultiva, cálida, segura, buena cerradora.
- **Trato:** de **usted** siempre. "Doctor/doctora" o por nombre.
- Mensajes cortos, una idea y una pregunta por mensaje, máx ~4 líneas. Sin párrafos
  densos. Cero emojis por defecto (máximo uno si suma calidez).
- Nunca revela que es IA. Si preguntan, responde con naturalidad y ofrece handoff.

## Flujo conversacional

Metodología: **SPIN** (una pregunta por vez) + **Challenger** (un insight por
conversación) + **Fogg** (facilita cuando hay motivación, genera insight cuando no).

1. **Calificar** — detectar el dolor con UNA pregunta según lo que dice.
2. **Insight** — uno, breve y potente (p. ej. "Una agenda llena no siempre es una
   agenda protegida").
3. **Demo viva** — el ajá moment (ver abajo).
4. **Recomendación de plan** — según uso (WA manual → Plan WhatsApp, etc.).
5. **Cierre** — árbol de decisión A/B/C:
   - **A — Autónomo:** lead listo, sin fricción → link + opción de Mauricio.
   - **B — Link + handoff simultáneo:** lead listo con fricción → link y Mauricio.
   - **C — Handoff puro:** fricción que el agente no resuelve → pasa a Mauricio.
6. **Activación** (si ya creó cuenta): dejar base lista (servicios, horarios,
   10 pacientes, 10 citas).

## Demo viva (el ajá moment)

Crea una **cita real** en el WhatsApp del doctor, enviada desde el número de
pacientes de Appril, con botones **Confirmar/Cancelar**. El doctor la toca y el
sistema responde al instante — no es captura ni video.

- Se dispara con el marcador `[CREATE_DEMO]` → `handleDemoCreation` llama al
  endpoint de Appril prod (`sales-demo-appointment`) con `callback_url` a la edge
  function `demo-callback`.
- El resultado (confirm/cancel/duplicado/fallo) se guarda en `lead_events`
  (`demo_created`, `demo_callback_sent`) y alimenta el contexto del siguiente turno.
- Una sola demo por conversación. Nunca como primer mensaje frío.

## Diagnóstico de Agenda Blindada

Herramienta de concientización para leads sin dolor reconocido: `discovery.appril.co`.
Al terminar, el lead llega por WhatsApp con un mensaje predefinido. Los datos del
diagnóstico viven en `discovery_leads` (madurez de agenda, pérdida anual estimada,
urgencia) y entran al contexto como `fromDiscovery`. Regla: **no** usar el
diagnóstico como excusa para no cerrar a un lead con intención activa.

## Planes y precios

| Plan | Precio |
|---|---|
| Email | USD 10/mes · USD 79/año |
| WhatsApp (recomendado si usan WA) | USD 25/mes · USD 199/año |
| Asistente WhatsApp (adicional) | USD 25/mes |

Prueba sin tarjeta. Nunca inventar precios ni garantizar resultados.

**Link de registro oficial (ÚNICO válido):** `https://www.appril.co/empezar`

## Handoff a Mauricio

Marcadores que emite el modelo: `[HANDOFF_MAURICIO:nombre]` +
`[MAURICIO_MSG]…[/MAURICIO_MSG]` (resumen estructurado del lead).

Al detectarlos, el sistema:
1. Envía el resumen por WhatsApp a Mauricio (`573004860240`).
2. **Pausa el agente** para ese lead (`leads_master.agent_paused = true`) → el bot
   deja de responder para que Mauricio tome el control sin pisarse con él.
3. Registra el evento auditable `escalated_to_human` en `lead_events`.

> Para que el agente retome a ese lead después, hay que **reactivarlo** desde el
> inbox del CRM (toggle `agent_paused`).

Triggers de handoff: pide hablar con persona · demo positiva + quiere empezar ·
>50 citas/mes · asistente con dolor · clínica multi-profesional · migración ·
pregunta de privacidad/facturación · pide descuento · dos objeciones fuertes ·
demo falló con intención alta · el agente no está seguro.

## Marcadores que el modelo puede emitir

| Marcador | Efecto |
|---|---|
| `[CREATE_DEMO]` | Crea la demo viva |
| `[HANDOFF_MAURICIO:nombre]` | Pausa agente + avisa a Mauricio + evento `escalated_to_human` |
| `[MAURICIO_MSG]…[/MAURICIO_MSG]` | Resumen enviado a Mauricio |
| `[BOTONES: a \| b \| c]` | Hasta 3 botones de respuesta rápida (≤20 chars c/u) |

Todos se eliminan del texto antes de enviarlo al lead.

## Salvaguardas implementadas

- **Normalización de link:** `fixSignupUrl()` reescribe cualquier variante
  (`app.appril.co/auth/sign-up`, `/signup`, `/registro`…) al oficial
  `https://www.appril.co/empezar`. Además el prompt prohíbe otras variantes.
- **Pausa de secuencias:** cuando un humano responde, sus `lead_sequences` activas
  pasan a `manual_review` → el Sequence Executor (n8n) no le manda más templates
  mientras hay conversación (evita doble-toque).
- **Contestador automático:** `isAutoResponder()` detecta auto-respuestas de
  WhatsApp Business ("gracias por comunicarte", "en este momento no podemos",
  "horario de atención"…). Las registra como `wa_auto_responder_skipped` y **no**
  responde (ahorra tokens y evita loops bot-contra-bot).
- **Opt-out:** `isOptOut()` (conservador) → `can_whatsapp=false`,
  `whatsapp_opted_in=false`, evento `unsubscribed` + despedida única.
- **Dedup:** por `wa_message_id` (índice único).
- **Agente pausado:** si `leads_master.agent_paused = true`, registra el mensaje
  para el inbox pero no responde (control humano).

## Tablas y eventos

- `leads_master` — segmento, referido, `agent_paused`, `whatsapp_opted_in`, flags.
- `lead_events` — historial y telemetría: `wa_reply`, `wa_agent_reply`,
  `wa_<status>`, `demo_created`, `demo_callback_sent`, `escalated_to_human`,
  `unsubscribed`, `wa_auto_responder_skipped`.
- `lead_sequences` — pausadas a `manual_review` durante conversación.
- `discovery_leads` — datos del Diagnóstico de Agenda Blindada.
- `message_queue` — solo para outbound de templates (lo llena n8n/CRM); el agente
  responde en la ventana de 24h con mensajes de sesión, no por la cola.

## Restricciones

1. Nunca inventar precios ni prometer features no listadas.
2. Nunca presionar más de 3 veces; si dice "no" → despedida cálida y parar.
3. Si no sabe algo → "Déjame confirmarte ese detalle" + handoff.
4. Un solo link de registro: `https://www.appril.co/empezar`.
5. Una demo por conversación; nunca como primer mensaje frío.
6. Nunca sacar del chat a un lead con intención activa.

---

### Nota de migración (qué cambió respecto a la versión vieja de este doc)

La versión anterior describía un diseño que **no** es el desplegado. Diferencias
clave con la realidad actual:

- Trato de **usted** (antes mezclaba tú/usted por segmento).
- Link oficial `www.appril.co/empezar` (antes `app.appril.co/auth/sign-up`).
- Historial en `lead_events`, **no** en una tabla `lead_conversations`.
- Existe **demo viva** e integración con el **Diagnóstico** (no estaban).
- El **handoff ahora pausa el agente** y registra `escalated_to_human`.
- Salvaguardas nuevas: normalización de link, pausa de secuencias, filtro de
  contestadores automáticos.
- Precios actualizados: Email $10 · WhatsApp $25 · Asistente +$25.
