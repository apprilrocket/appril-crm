# Guía para una IA: cómo usar el MCP `appril-campaigns`

Documento operativo para que **otra IA** (Claude u otro cliente MCP) sepa **para qué
sirve**, **cómo conectarse** y **cómo usar** el MCP de campañas del CRM de Appril.

---

## 1. ¿Para qué sirve?

Es un servidor **MCP** que expone el ciclo de marketing del CRM de Appril como un set de
**herramientas (tools)** que una IA puede invocar:

- Gestionar **contactos y listas** (crear listas, importar contactos con deduplicación).
- Crear y editar **copys de email** (plantillas con variables `{{...}}`).
- Construir y programar **campañas** de email/WhatsApp.
- Construir y validar **secuencias/automations**.
- **Previsualizar audiencias** y **monitorear** envíos (abiertos, clics, rebotes).
- Enviar **emails de prueba** a direcciones autorizadas.
- **Leer el CRM** (desde 2026-07-09): buscar leads, ver su timeline, leer el inbox
  unificado y conversaciones (con ventana de 24h calculada), reportes agregados y salud
  de los agentes WA.
- **Escrituras acotadas sobre leads** (desde 2026-07-09): mover de etapa, editar perfil
  (consentimiento solo-revocable), notas, tareas, pausar/reanudar el agente comercial.
  Ninguna toca `message_queue` ni envía nada.

**Lo que NO hace (a propósito):** no envía campañas masivas por su cuenta, no activa
secuencias, no aprueba envíos. Prepara todo en **borrador** y deja el disparo final a un
**humano**. Ver §6.

Detrás: la IA escribe en la BD del CRM (Supabase). Un Lambda aparte (`appril-sender`)
toma los mensajes encolados y los envía por **AWS SES** (email) o **Meta WhatsApp**.

---

## 2. Cómo conectarse / invocarlo

El MCP corre por **stdio** (entrada/salida estándar): el cliente lo lanza como proceso.

### Requisitos previos (una vez)
```bash
cd appril-crm/mcp
npm install
cp .env.example .env      # completar SUPABASE_SERVICE_ROLE_KEY
npm run build             # genera dist/
```

### A) Claude Code / Claude Desktop (config JSON)
Ya está registrado en `appril-crm/.mcp.json`:
```json
{
  "mcpServers": {
    "appril-campaigns": {
      "command": "node",
      "args": ["mcp/dist/index.js"]
    }
  }
}
```
Al abrir el proyecto, las tools aparecen con el prefijo del servidor. En Claude Code los
nombres se ven como **`mcp__appril-campaigns__<tool>`** (p.ej.
`mcp__appril-campaigns__preview_audience`).

### B) Cualquier cliente MCP genérico
Lanzar el binario y hablar JSON-RPC por stdio:
```bash
node /ruta/appril-crm/mcp/dist/index.js
```
Handshake estándar MCP: `initialize` → `notifications/initialized` → `tools/list` →
`tools/call`. En un cliente genérico los tools se llaman por su nombre **sin prefijo**
(p.ej. `preview_audience`).

> El servidor lee credenciales de `mcp/.env`. No requiere argumentos.

---

## 3. Catálogo de tools

> Notación: los parámetros entre `[]` son opcionales.

### Contactos y listas
| Tool | Parámetros | Qué hace |
|---|---|---|
| `list_segments` | — | Segmentos con audiencia total y elegibles por canal. |
| `list_lead_lists` | — | Listas con número de miembros. |
| `create_list` | `name`, `[description]`, `[source_type]` | Crea una lista vacía. |
| `import_contacts` | `list_name`, `contacts[]`, `[segment]` | Importa contactos (crea la lista si falta), deduplica por email/teléfono E.164. Cada contacto: `{full_name?, email?, phone?, city?, specialization?, country?, whatsapp_opted_in?}`. El opt-in es por lead (true/false, default false). |

### Copys / plantillas
| Tool | Parámetros | Qué hace |
|---|---|---|
| `list_templates` | `[channel]`, `[status]` | Lista plantillas. |
| `get_template` | `template_key` | Devuelve una plantilla completa. |
| `list_wa_templates` | — | Plantillas de WhatsApp **aprobadas por Meta** (solo lectura). |
| `create_email_template` | `name`, `subject`, `html_body`, `[text_body]`, `[description]`, `[activate]` | Crea copy de **email**. Extrae `{{variables}}` solo. |
| `update_email_template` | `template_key`, `[name/subject/html_body/text_body/status]` | Edita un copy de email. |

### Campañas
| Tool | Parámetros | Qué hace |
|---|---|---|
| `preview_audience` | `channel`, `[segments]`, `[list_ids]`, `[allow_no_optin]` | **Audiencia total vs elegibles.** Úsalo SIEMPRE antes de crear. |
| `create_campaign` | `name`, `channel`, `template_key`, `[segments]`, `[list_ids]`, `[allow_no_optin]`, `[description]` | Crea campaña en **borrador**. Valida el template. Devuelve el preview. |
| `schedule_campaign` | `campaign_id`, `scheduled_at` (ISO) | Fija fecha; deja la campaña lista para **aprobación humana**. No la lanza. |
| `list_campaigns` | `[status]` | Lista campañas. |
| `get_campaign` | `campaign_id` | Detalle + desglose en vivo de la cola. |

### Monitoreo
| Tool | Parámetros | Qué hace |
|---|---|---|
| `queue_status` | — | Estado global de la cola (pending/sent/failed...). |
| `campaign_stats` | `campaign_id` | Cola por status y por `triggered_by` (lote vs seed) + engagement email: opens/clics/rebotes en eventos y en leads únicos (atribución por `metadata.campaign_id`; WA no atribuible aún). |

### Secuencias (automations) — solo borrador
| Tool | Parámetros | Qué hace |
|---|---|---|
| `list_automations` | — | Lista secuencias. |
| `get_automation` | `id` | Devuelve la secuencia y su `flow`. |
| `create_automation` | `name` | Crea borrador con nodo trigger. |
| `update_automation` | `id`, `[name]`, `[flow]` | Actualiza y **valida** el flow. No activa ni enrola. |

### Lecturas del CRM (leads, inbox, reportes, salud) — solo lectura (2026-07-09, `82c7d71`)
| Tool | Parámetros | Qué hace |
|---|---|---|
| `search_leads` | `[q]`, `[segment]`, `[stage]`, `[city]`, `[specialization]`, `[can_email]`, `[can_whatsapp]`, `[limit]` | Busca leads por texto (nombre/email/teléfono) y filtros. Default 20, máx 100. |
| `get_lead` | `[lead_id]`/`[email]`/`[phone]` (uno) | Lead completo + últimos 10 eventos + tareas abiertas. |
| `lead_timeline` | `lead_id`, `[limit]` | Timeline de `lead_events`, más reciente primero (default 50, máx 200). |
| `inbox_threads` | `[limit]` | Hilos del inbox unificado (misma RPC que el dashboard): último inbound/outbound, unread, `last_wa_reply_at`, flags de canal. |
| `get_conversation` | `lead_id` | Conversación completa (burbujas con receipts) + estado calculado de la **ventana de 24h de Meta** (open/expires_at). |
| `get_report` | `report` (`funnel`/`channel_stats`/`activity_daily`/`quality_summary`), `[days]`, `[include_seed]` | Reportes agregados del CRM. SEED excluido por defecto. |
| `agent_health` | `[status]` (`open`/`notified`/`resolved`), `[limit]` | Incidentes del watchdog de agentes WA (`agent_health_incidents`) + conteo de abiertos. |

### Escrituras acotadas sobre leads (2026-07-09, `e05df51`) — jamás tocan `message_queue`
| Tool | Parámetros | Qué hace |
|---|---|---|
| `update_lead_stage` | `lead_id`, `stage` | Mueve el lead de etapa (valida contra `pipeline_stages`); evento `stage_changed` auditado. |
| `update_lead` | `lead_id`, `[fields]`, `[revoke_can_email]`, `[revoke_can_whatsapp]` | Edita perfil (whitelist: full_name, first_name, city, country, specialization, marketing_segment). **Consentimiento solo-revocable**: puede quitar canales, jamás habilitarlos. |
| `add_lead_note` | `lead_id`, `body` | Nota interna (`lead_notes`, visible en el dashboard). |
| `create_lead_task` | `lead_id`, `title`, `[description]`, `[due_at]` | Tarea `open` con vencimiento opcional. |
| `complete_lead_task` | `task_id`, `[reopen]` | Completa (o reabre) una tarea. |
| `set_agent_paused` | `lead_id`, `paused`, `[reason]` | Pausa/reanuda el agente IA comercial para ese lead. Auditado en `lead_events`. |

> **Excluido a propósito:** re-encolar/reintentar mensajes fallidos NO existe como tool
> (re-encolar = disparar envíos reales → violaría `FORBIDDEN_WRITES`, `src/guardrails.ts`).
> Sigue siendo exclusivo de la UI. Todas las mutaciones quedan auditadas con
> `triggered_by: mcp`.

### Prueba
| Tool | Parámetros | Qué hace |
|---|---|---|
| `send_test` | `template_key`, `to_address`, `[payload]` | Envía **1 email real** a una dirección de la *allowlist*. Única vía de envío del MCP. |

---

## 4. Recetas (flujos paso a paso)

### Lanzar una campaña de email (camino completo)
1. `list_segments` / `list_lead_lists` → entender a quién puedes llegar.
2. `list_templates` con `channel:"email"` (o `create_email_template` + activar).
3. **`preview_audience`** con el canal y los segmentos/listas → mira `eligible`
   (no `audience`). **Confírmale al usuario el número** antes de seguir: los segmentos son
   grandes (WARM ≈ 12k, COLD ≈ 8k).
4. `create_campaign` → queda en `draft`.
5. (Opcional) `send_test` para validar el render/entrega.
6. `schedule_campaign(campaign_id, scheduled_at)` → fija la fecha.
7. **Para el usuario:** entrega `campaign_id`, audiencia elegible, fecha, y aclara que un
   **humano** debe aprobarla para que se envíe. La IA no aprueba.

### Importar contactos a una lista
```
import_contacts({
  list_name: "Webinar junio",
  segment: "WARM",
  contacts: [
    { full_name: "Ana López", email: "ana@clinica.co", phone: "+573001234567" },
    { full_name: "Juan Ruiz", email: "juan@x.co" }
  ]
})
```
Devuelve `{ nuevos, existentes, invalidos, duplicados_archivo }`. Teléfonos sin `+`/país se
descartan (no se adivina indicativo).

### Crear un copy de email
```
create_email_template({
  name: "Reactivación julio",
  subject: "Hola {{full_name}}, te extrañamos",
  html_body: "<p>Hola {{full_name}}, ...</p>",
  activate: true
})
```
> Importante: hoy el envío sólo hidrata `{{full_name}}`. Si usas otras variables saldrán
> vacías (los tools te lo **avisan** con un campo `warning`).

---

## 5. Cómo interpretar resultados / errores

- Las tools devuelven **JSON en texto**. Los errores llegan como `ERROR: ...`.
- `[guardarraíl] ...` = bloqueado a propósito por seguridad (p.ej. `send_test` a una
  dirección fuera de la allowlist). No insistas: respeta el límite.
- Si `preview_audience` falla con *"function not found"*, falta aplicar la migración
  `mcp_campaign_launch` en la BD.
- Distingue siempre **`audience`** (total) de **`eligible`** (los que de verdad reciben).

### Regla SEED (DEC-023 gate D — obligatoria en TODA lectura)

Los seeds internos (`leads_master.marketing_segment = 'SEED'`, envíos con
`message_queue.triggered_by = 'seed_internal'`) son QA técnico: **existen como
evidencia histórica pero JAMÁS cuentan como mercado**. Por eso:

- `campaign_stats`, `get_report` y las RPCs de reporte del dashboard los
  **excluyen por defecto**; solo aparecen con `include_seed=true`, y ese flag se
  usa únicamente para auditar evidencia, nunca para métricas de negocio.
- Todo reporte que redactes debe separar cuatro poblaciones y decirlo
  explícitamente: **seed_internal** (QA), **lotes reales** (`triggered_by` del
  lote), **tests** (campañas `PRUEBA`/allowlist) y **leads reales**.
- Nunca uses el total con seeds como denominador de un lote (lección del HOT 30:
  el "completó Discovery" del reporte era un seed; la lectura real era 0).
- `by_trigger` de `campaign_stats` siempre muestra el desglose completo — úsalo
  para declarar cuántos seeds quedaron fuera.

---

## 6. Modelo de seguridad — lo que la IA NO puede hacer

Invariantes garantizados por el servidor (no intentes rodearlos):

1. **No lanza campañas.** Lo más lejos que llega es dejarlas en `draft` + programadas.
2. **No activa secuencias** ni **enrola leads** (eso dispara envíos → es humano).
3. **No aprueba** (`approved_at` lo pone un humano). El scheduler sólo envía campañas
   aprobadas.
4. **Único envío:** `send_test`, 1 mensaje, sólo a la *allowlist*.
5. Todo está acotado al `workspace` configurado.
6. **No re-encola ni reintenta mensajes fallidos** (excluido de las tools de escritura a
   propósito) y **no puede otorgar consentimiento** (`can_email`/`can_whatsapp` solo se
   revocan vía MCP, nunca se habilitan).

Si el usuario pide "manda ya la campaña a todos": la respuesta correcta es prepararla y
programarla, y explicar que **un humano debe aprobarla**.

---

## 7. Referencias

- Código y arquitectura: `mcp/README.md`.
- Skill de operación (para Claude): `appril-mcp-campaigns`.
- Agente especializado: `campaign-operator` (`.claude/agents/`).
- Capa canónica SQL: `supabase/migrations/20260626_1200_mcp_campaign_launch.sql`.
