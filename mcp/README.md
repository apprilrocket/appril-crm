# appril-mcp-campaigns

Servidor **MCP** del CRM de Appril. Permite que una IA gestione **contactos, listas,
copys (email), campañas y secuencias** sobre la BD del CRM — **sin poder enviar de
forma autónoma**. La IA prepara borradores; el envío masivo real lo gatilla un humano
o el scheduler, y sólo sobre campañas aprobadas por una persona.

## Regla de oro (modelo de seguridad)

> El MCP **nunca** pone una campaña en `running`, **nunca** activa una automation,
> **nunca** enrola leads en una automation activa y **nunca** escribe
> `campaigns.approved_at`. La **única** inserción en `message_queue` que hace es
> `send_test` (1 mensaje, a una dirección de la *allowlist*).

El envío masivo viaja así:

```
IA (MCP)                         HUMANO                      Scheduler (pg_cron)        Lambda appril-sender
─────────                        ──────                      ───────────────────        ────────────────────
create_campaign  → draft
schedule_campaign→ draft + fecha
                                 aprueba:
                                 approved_at + status=scheduled
                                                             crm_run_due_campaigns()
                                                             → crm_launch_campaign()
                                                               (inserta message_queue)
                                                                                        envía por SES / Meta WA
```

`crm_launch_campaign` exige `approved_at != null`: sin aprobación humana no hay envío.

## Arquitectura

- **Capa canónica (Postgres RPC)** — `migrations/20260626_1200_mcp_campaign_launch.sql`
  - `crm_preview_audience(...)` → audiencia total vs elegibles (mismas guardas que el lanzamiento).
  - `crm_launch_campaign(campaign_id)` → enqueue canónico (espejo de `launchCampaign`), exige aprobación.
  - `crm_run_due_campaigns()` → scheduler: lanza campañas `scheduled` + aprobadas + vencidas.
  - Columnas nuevas en `campaigns`: `approved_at`, `approved_by`, `launch_requested_at`.
- **Sender (Lambda `appril-sender`)** — ya existente; consume `message_queue` cada ~2 min → SES (email) / Meta (WhatsApp).
- **MCP server (este paquete)** — service role; **scopea `workspace_id` en cada query** (RLS no protege al service role).

## Tools (21)

| Dominio | Tool | Escribe | Notas |
|---|---|---|---|
| Contactos | `list_segments`, `list_lead_lists` | no | conteos en vivo |
| | `create_list`, `import_contacts` | sí | dedupe email/teléfono E.164; corrige el bug de `email_normalized` |
| Copys | `list_templates`, `get_template`, `list_wa_templates` | no | WA sólo lectura (aprobación de Meta) |
| | `create_email_template`, `update_email_template` | sí | extrae `{{vars}}`; sólo email |
| Campañas | `preview_audience` | no | **úsalo siempre antes de crear** |
| | `create_campaign`, `schedule_campaign` | sí | crean/dejan **draft**; nunca lanzan |
| | `list_campaigns`, `get_campaign` | no | + desglose de la cola |
| Monitoreo | `queue_status`, `campaign_stats` | no | opens/clicks/bounces |
| Secuencias | `list_automations`, `get_automation` | no | |
| | `create_automation`, `update_automation` | sí | sólo borrador + validación de flow |
| Prueba | `send_test` | sí (1) | **única** vía de envío del MCP; allowlist |

WhatsApp: la IA **no crea copys de WhatsApp** (requieren aprobación previa en Meta
Business Manager). Usa `list_wa_templates` para ver los aprobados y referenciarlos en
campañas/automations.

## Setup

```bash
cd mcp
npm install
cp .env.example .env     # y completa SUPABASE_SERVICE_ROLE_KEY
npm run build
```

Aplicar la migración (capa canónica) — requiere permiso para tocar la BD de producción:

```bash
# vía Supabase CLI / dashboard, o el MCP de Supabase:
#   supabase/migrations/20260626_1200_mcp_campaign_launch.sql
```

Registrar en Claude Code: ya está en `.mcp.json` del repo (`appril-campaigns`).

### Variables de entorno (`.env`)

| Var | Obligatoria | Default |
|---|---|---|
| `SUPABASE_URL` | sí | — |
| `SUPABASE_SERVICE_ROLE_KEY` | sí | — |
| `APPRIL_WORKSPACE_ID` | no | `e2096477-…` |
| `MCP_TEST_ALLOWLIST` | no | `mauricio@todoc.co` |
| `MCP_SERVICE_USER_ID` | no | `null` (audita `created_by`) |

## Activar el auto-lanzamiento (scheduler)

Construido pero **pausado**. Para encenderlo (lanza campañas aprobadas en su fecha):

```sql
SELECT cron.schedule('crm-campaign-scheduler', '* * * * *',
  $$SELECT public.crm_run_due_campaigns()$$);
```

Para aprobar una campaña (acción **humana**):

```sql
UPDATE campaigns
   SET approved_at = now(), approved_by = '<crm_users.id>', status = 'scheduled'
 WHERE id = '<campaign_id>';
```

## Pruebas

```bash
npm run test:integration        # ejercita los tools contra la BD viva y limpia
RUN_SEND_TEST=0 npm run test:integration   # sin enviar email real
```

## Pendientes / hardening (fase 2)

- **Fuente única de verdad:** migrar `src/app/campaigns/actions.ts` (web) para que
  llame `crm_launch_campaign` en vez de su propia copia de la lógica.
- **Aprobación en UI:** botón "Aprobar y programar" en el CRM (hoy la aprobación es SQL).
- **WhatsApp en `send_test`** y **hidratación de variables** más rica (hoy sólo `full_name`,
  igual que el CRM; el motor de automations ya mapea `nombre/ciudad/especialidad`).
- **Identidad de servicio:** crear un `crm_users` sintético y poner su id en `MCP_SERVICE_USER_ID`.
