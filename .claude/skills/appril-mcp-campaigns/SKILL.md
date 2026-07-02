---
name: appril-mcp-campaigns
description: Operar el MCP de campañas del CRM de Appril — gestionar contactos, listas, copys de email, campañas y secuencias vía el servidor MCP "appril-campaigns". Usa cuando el usuario quiera crear/programar campañas, importar contactos, escribir copys, previsualizar audiencias o lanzar (con aprobación humana). Cubre el modelo de seguridad: el MCP nunca envía solo.
version: 1.0.0
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

# Skill: appril-mcp-campaigns

Guía para operar el **MCP de campañas** del CRM de Appril (servidor `appril-campaigns`,
código en `/Users/mauriciogarcia/dev/appril/appril-crm/mcp`).

## Qué es

Un servidor MCP que deja que una IA gestione el ciclo de marketing del CRM **sin poder
enviar de forma autónoma**. La IA prepara; el envío masivo lo aprueba un humano.

- BD: Supabase `hwiocriejizjdqqcfrsj` (proyecto "Tablas de datos de profesionales").
- Sender: Lambda `appril-sender` consume `message_queue` cada ~2 min → SES / Meta WhatsApp.
- Workspace único: `e2096477-fa6a-4b8f-a8b3-bd46ad720167`.

## Regla de oro — NUNCA romper

El MCP **no** pone campañas en `running`, **no** activa automations, **no** enrola en
automations activas y **no** setea `approved_at`. La única inserción en `message_queue`
es `send_test` (1 mensaje, allowlist). Si te piden "envía ya la campaña a todos", la
respuesta es: el MCP la deja **lista y programada**, y un **humano la aprueba**.

## Flujo para lanzar una campaña (el camino feliz)

1. `list_segments` / `list_lead_lists` → entender la audiencia disponible.
2. `list_templates` (o `create_email_template`) → elegir/crear el copy. Actívalo.
3. **`preview_audience`** → SIEMPRE antes de crear. Mira `eligible` (no `audience`):
   los segmentos grandes son enormes (WARM ≈ 12k, COLD ≈ 8k). Confirma el tamaño con
   el usuario antes de seguir.
4. `create_campaign` → queda en **draft**. Devuelve el preview otra vez.
5. `schedule_campaign(campaign_id, scheduled_at)` → fija fecha, marca
   `launch_requested_at`. Sigue en draft.
6. **Dile al usuario que un humano debe aprobar** (UI futura, o el SQL del README):
   `UPDATE campaigns SET approved_at=now(), approved_by='<crm_users.id>', status='scheduled' WHERE id=…`.
7. El scheduler (`crm_run_due_campaigns`, vía pg_cron) la lanza en su fecha. Si el cron
   no está activo, ver README → "Activar el auto-lanzamiento".

## Probar antes de comprometer

`send_test(template_key, to_address)` envía un email real a una dirección de la
allowlist (`mauricio@todoc.co` por defecto). Úsalo para validar render + entrega antes
de programar la campaña real. Requiere que exista un lead con ese email.

## WhatsApp — asimetría clave

- Email: la IA crea copys libremente (`create_email_template`).
- WhatsApp: la IA **no** crea copys. Las plantillas requieren aprobación previa de Meta.
  Usa `list_wa_templates` para ver las aprobadas y referenciarlas. `send_test` es sólo email.

## Contactos y listas

- `import_contacts(list_name, contacts[])` crea la lista si no existe, normaliza
  email/teléfono (E.164 con `+`), deduplica en-archivo y contra BD. Nuevos = `COLD`.
- Teléfonos sin `+`/indicativo se descartan (no se adivina país).

## Secuencias (automations)

- `create_automation` + `update_automation(flow)` → sólo **borrador** + validación.
- Nodos del flow: `trigger`, `send_email`, `send_whatsapp`, `wait`, `condition`, `goal`, `exit`.
- **Activar** una automation y **enrolar** leads dispara envíos → son acciones HUMANAS,
  no del MCP.

## Setup / mantenimiento

- Build: `cd mcp && npm install && npm run build`.
- Credenciales: `mcp/.env` (service role). No versionar.
- Capa canónica en Postgres: migración `supabase/migrations/20260626_1200_mcp_campaign_launch.sql`.
- Test: `cd mcp && npm run test:integration` (limpia lo que crea).
- Doc completa: `mcp/README.md`.

## Al empezar una sesión

1. Verifica que `mcp/dist` existe (si no, build).
2. Verifica que la migración esté aplicada (si `preview_audience` falla con "function not
   found", falta aplicarla).
3. Para cualquier envío real, confirma tamaño de audiencia con el usuario y recuerda que
   la aprobación final es humana.
