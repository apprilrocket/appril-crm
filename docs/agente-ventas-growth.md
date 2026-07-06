# Agente de Ventas WhatsApp de Appril — Briefing para Growth

> Documento operativo para el Chief Growth Officer. Describe el sistema real
> desplegado. **Fuente de verdad: el código** en
> `supabase/functions/whatsapp-agent/index.ts` (proyecto Supabase `hwiocriejizjdqqcfrsj`).

## 1. Qué es, en una frase

Es una **asesora comercial conversacional impulsada por Claude (Sonnet 4.6)** que
vive en WhatsApp. Cuando un profesional de salud escribe al número del CRM, el
agente diagnostica su dolor operativo, le entrega un insight, le dispara una
**demo viva** (una cita real en su propio WhatsApp con botones de
Confirmar/Cancelar) y lo lleva al cierre: o crea cuenta, o lo pasa a un humano
(Mauricio).

No es un chatbot de menú. Sigue una metodología de venta consultiva real
(**SPIN + Challenger + Fogg**) codificada en su "cerebro".

## 2. Arquitectura — las piezas

| Componente | Función |
|---|---|
| `whatsapp-agent` (Edge Function) | El cerebro. Recibe el mensaje, llama a Claude, responde. |
| `demo-callback` (Edge Function) | Cuando el doctor toca el botón de la demo, retoma la venta con el remate de cierre. |
| `inbox-send` (Edge Function) | Permite al humano responder manualmente desde el dashboard. |
| `automation_tick()` (función de DB) | El motor de outbound: encola los primeros toques (templates). |
| `appril-sender` (Lambda AWS) | Drena la cola y envía los templates por la API de Meta. |
| MCP `appril-campaigns` | Herramienta para que el equipo prepare campañas/listas/secuencias. |

El historial completo de cada conversación vive en la tabla `lead_events` (no hay
tabla de "conversaciones" aparte). El estado del lead vive en `leads_master`.

## 3. Punto clave para Growth: el agente es REACTIVO

**El agente nunca inicia la conversación.** Solo se activa cuando entra un mensaje
del lead. WhatsApp (Meta) solo permite texto libre dentro de una **ventana de 24
horas** desde el último mensaje del usuario. Fuera de esa ventana, solo se pueden
enviar **plantillas pre-aprobadas**.

Entonces "despertar" al agente = **provocar un primer mensaje entrante del lead.**
Hay cuatro maneras:

### Vía A — Plantilla de outbound (la principal para campañas en frío)
1. El lead entra a una automatización o campaña.
2. `automation_tick()` lo encola en `message_queue` con una plantilla aprobada.
3. `appril-sender` (Lambda AWS) envía la plantilla. Esto abre la conversación.
4. **Cuando el lead responde** → entra al `whatsapp-agent` → el agente vende.

> Guarda importante: el outbound de WhatsApp **solo se encola si el teléfono está
> en formato E.164 válido** (`+57300...`). Se endureció en la migración
> `20260626_1400`. Números malformados caen a `automation_send_skipped` y nunca se
> contactan. (Hay ~19k leads con `can_whatsapp=true` pero teléfono malformado — ese
> es hoy el cuello de botella real, no el opt-in.)

### Vía B — El Diagnóstico de Agenda Blindada (`discovery.appril.co`)
El lead llena un diagnóstico web. Al terminar, un botón lo manda a WhatsApp con un
mensaje predefinido. Ese mensaje despierta al agente, que **ya llega con contexto**
(madurez de agenda, pérdida anual estimada, urgencia) cargado desde
`discovery_leads`. Es el lead mejor calificado que existe.

### Vía C — Lead entrante orgánico
Alguien escribe al número directamente. El agente lo crea como `COLD`,
`source = whatsapp_inbound`, y arranca el diagnóstico.

### Vía D — Campañas vía MCP `appril-campaigns`
El equipo prepara listas, copys y secuencias. **El MCP nunca envía masivamente
solo** — siempre deja todo listo para aprobación humana.

## 4. Parámetros que recibe el agente (el "contexto del lead")

En cada mensaje arma un `LeadContext` que personaliza su comportamiento. Llenar
estos campos **antes** de despertar al lead lo hace vender mejor:

| Parámetro | De dónde sale | Qué hace |
|---|---|---|
| `name` | `leads_master.full_name` | Si lo tiene, no lo pide; lo usa en demo y handoff. |
| `phone` | `leads_master.phone` | Ya lo tiene — el prompt le prohíbe pedirlo. |
| `segment` | `marketing_segment` / discovery | COLD/WARM/HOT/SUPER_HOT — cambia la apertura. |
| `referredByName` | `referred_by_name` | Activa apertura por referido. |
| `fromDiscovery` | fila en `discovery_leads` | Activa el guion post-diagnóstico. |
| `urgency`, `maturity`, `annualLost`, `desiredNextStep` | `discovery_leads` | Munición para insight y resumen a Mauricio. |
| `messageCount` | historial en `lead_events` | Si ≥1, prohíbe que se vuelva a presentar. |
| `demoAlreadyCreated` / `demoOutcome` / `demoDuplicate` | eventos de demo | Evita repetir la demo y le dice cómo retomar. |

**Implicación:** un lead con `referredByName` + `fromDiscovery` recibe una apertura
totalmente distinta a un frío. Entre más campos llenes, más afilado vende.

## 5. Cómo vende — el flujo conversacional

1. **Calificar** — UNA pregunta para detectar el dolor.
2. **Insight** — un golpe de claridad.
3. **Demo viva** — el ajá moment.
4. **Recomendar plan** — según uso.
5. **Cierre** — árbol A/B/C según fricción.
6. **Activación** — si ya creó cuenta, lo guía a 10 pacientes + 10 citas.

**Métrica norte:** usuario activado = profesional con ≥10 pacientes y ≥10 citas.

## 6. La demo viva (la mejor arma)

El modelo emite `[CREATE_DEMO]`. El sistema crea una **cita real en el WhatsApp del
doctor**, desde el número de pacientes de Appril, con botones Confirmar/Cancelar.
Al tocar el botón, `demo-callback` le manda el **remate de venta** y todo queda
registrado. Una demo por conversación, nunca como primer mensaje frío.

## 7. El handoff a Mauricio — en detalle

El agente emite dos marcadores: `[HANDOFF_MAURICIO:nombre]` y
`[MAURICIO_MSG]…[/MAURICIO_MSG]` (briefing estructurado). El sistema entonces:

1. **Envía el resumen por WhatsApp a Mauricio** (+57 300 4860240) con datos, dolor,
   objeción, demo, plan sugerido, temperatura y últimos mensajes.
2. **Pausa el agente para ese lead** (`leads_master.agent_paused = true`).
3. Registra el evento auditable `escalated_to_human`.

> ⚠️ **Punto operativo crítico:** tras el handoff, el agente queda **apagado para
> ese lead** hasta que alguien lo **reactive manualmente** desde el inbox (toggle
> `agent_paused`). Si Mauricio abandona y nadie reactiva, el lead queda huérfano.
> Conviene un SLA sobre esto.

**Disparadores:** pide hablar con persona · demo positiva + quiere empezar · >50
citas/mes · asistente con dolor claro · clínica multi-profesional · migración ·
pregunta de privacidad/facturación · pide descuento · dos objeciones fuertes ·
demo falló con intención alta · el agente no está seguro.

## 8. Salvaguardas

- **Opt-out conservador** — apaga `can_whatsapp` + `whatsapp_opted_in`, despedida
  única, nunca vuelve a escribir. Crítico para el quality rating del número.
- **Filtro de contestadores automáticos** — no responde a auto-respuestas de otros
  consultorios (evita loops bot-vs-bot).
- **Anti-doble-toque** — pausa secuencias salientes a `manual_review` cuando hay
  conversación viva.
- **Deduplicación** — no procesa el mismo mensaje dos veces.
- **Normalización de link** — cualquier URL de registro se reescribe al oficial
  `www.appril.co/empezar`.
- **Validación E.164** — uniforme en todas las rutas de envío.

## 9. Cómo mejorarlo — palancas concretas

**Prompt / modelo (rápido, sin código nuevo):**
- El "cerebro" es un system prompt de ~380 líneas en `buildSystemPrompt()`. Iterar
  el copy ahí es la palanca de mayor ROI.
- Falta **A/B testing de prompts** (hoy hay una sola versión).
- El social proof está hardcodeado — mantenerlo fresco y verificable.

**Funnel (lo que más mueve la aguja):**
- **Limpiar teléfonos a E.164** — ~19k leads con `can_whatsapp=true` y número
  malformado nunca se contactan. La fuga más grande del outbound.
- **Maximizar la vía Diagnóstico** — leads precalificados y con contexto.
- **Enriquecer `leads_master` antes de contactar** (nombre, referido).

**Observabilidad (medir, no adivinar):**
- Todo está en `lead_events`. Se puede construir un dashboard de funnel: mensajes →
  demos disparadas → demos confirmadas → handoffs → cuentas creadas. **Hoy no
  existe.** Métricas clave: tasa de respuesta a la primera plantilla, % que acepta
  demo, % que la confirma, % de handoff, leads huérfanos tras handoff.

**Escala/riesgo:**
- Un solo número de WhatsApp y un solo humano de handoff son los cuellos de botella
  si crece el volumen. El handoff manual no escala.

## 10. Referencia de eventos en `lead_events`

| event_type | Significado |
|---|---|
| `wa_reply` | Mensaje entrante del lead. |
| `wa_agent_reply` | Respuesta del agente (o del inbox manual). |
| `wa_sent` / `wa_delivered` / `wa_read` / `wa_failed` | Estados de salida de Meta. |
| `demo_created` | Demo viva creada (valor = appointment_id o `duplicate_reused`). |
| `demo_callback_sent` | El doctor tocó Confirmar/Cancelar; se envió el remate. |
| `escalated_to_human` | Handoff a Mauricio ejecutado. |
| `unsubscribed` | Opt-out. |
| `wa_auto_responder_skipped` | Contestador automático detectado, no se respondió. |
| `automation_send_skipped` | Outbound no encolado (p. ej. teléfono no E.164). |
