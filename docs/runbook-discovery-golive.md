# Runbook — Go-live Discovery → Agente

> Proyecto CRM: `hwiocriejizjdqqcfrsj`. Discovery frontend: repo `appril-discovery` (Vercel).
> Honestidad de flags: varios `discovery_*_enabled` son **marcadores de estado** (el código NO los lee).
> Los *gates reales* están marcados. No abrir el email sin secrets SES (cada submit daría 500).

## Pre-flight (ya vivo)
- Backend Discovery aplicado; agente desplegado (`verify_jwt=false`); `demo-callback`, `send-discovery-email`, `sales-demo-appointment` desplegados.
- Envío WhatsApp inmediato **apagado** (gate real `discovery_whatsapp_immediate_followup_enabled=false`).

## Paso 1 — Email (SES) · gate real = secrets + config del trigger
**1a. Secrets (en `appril-crm`):**
```
supabase secrets set \
  AWS_SES_ACCESS_KEY_ID=… AWS_SES_SECRET_ACCESS_KEY=… AWS_SES_REGION=us-east-1 \
  DISCOVERY_FROM_EMAIL="Appril <diagnostico@appril.co>" \
  DISCOVERY_DISPATCH_SECRET=<secreto-fuerte> \
  --project-ref hwiocriejizjdqqcfrsj
```
Dominio `appril.co` verificado en SES y fuera de sandbox.

**1b. Smoke test (a un correo interno, antes de abrir el gate):**
```
curl -X POST 'https://hwiocriejizjdqqcfrsj.supabase.co/functions/v1/send-discovery-email' \
 -H 'Content-Type: application/json' \
 -H 'x-discovery-dispatch-secret: <DISCOVERY_DISPATCH_SECRET>' \
 -d '{"discovery_lead_id":"<id real con email interno>","force":true}'
```
Verificar: email en Gmail+Outlook, CTA WhatsApp → `wa.me/573112211772`, link `www.appril.co/empezar`, moneda correcta, evento `discovery_email_sent`.

**1c. Abrir el gate real del trigger (enciende email automático por submit):**
```sql
insert into public.app_config(key,value) values
 ('edge_base_url','https://hwiocriejizjdqqcfrsj.supabase.co/functions/v1'),
 ('edge_dispatch_secret','<MISMO valor que DISCOVERY_DISPATCH_SECRET>')
on conflict (key) do update set value=excluded.value, updated_at=now();
```
> Mientras `edge_base_url` no exista, el trigger queda **inerte** (ese es el gate real).

**Caveat AR:** el email no excluye Argentina (FX). Decidir exclusión/USD antes de 1c si habrá tráfico AR.

## Paso 2 — Frontend (`appril-discovery` → Vercel)
Config de prod inline en `index.html → window.APPRIL_CONFIG` (ya corregido: signupUrl=`www.appril.co/empezar`, whatsappNumber=`+573112211772`, supabaseUrl/anonKey del CRM). Deploy a Vercel (prod). Verificar: wizard → resultado → CTA WhatsApp abre `wa.me/573112211772` con mensaje prellenado → agente responde con contexto `fromDiscovery`.

## Paso 3 — Flags
| Flag | ¿Lo lee el código? | Acción |
|---|---|---|
| `edge_base_url` / `edge_dispatch_secret` | SÍ (trigger email) | setear en 1c |
| `discovery_whatsapp_immediate_followup_enabled` | SÍ (submit) | dejar `false` |
| `demo_cooldown_hours` / `demo_resend_guard_minutes` | SÍ (agente) | 24 / 3 |
| `discovery_email_enabled` / `_agent_enabled` / `_public_traffic_enabled` / `_backend_enabled` | NO (cosméticos) | reflejar estado |

El **agente ya está vivo** (no hay flag que lo encienda). "Abrir tráfico" = desplegar el frontend + promocionar.

## Paso 4 — Canary end-to-end
1–3 leads internos: Discovery → email → CTA WhatsApp → agente `fromDiscovery` → demo viva → confirmar/cancelar → handoff. Revisar funnel en `lead_events`: `discovery_form_submitted → discovery_email_sent → cta_clicked → wa_reply → wa_agent_reply → demo_created → demo_callback_sent`.

## Paso 5 — Abrir tráfico
Pauta/landing pública solo tras canary verde. Empezar con presupuesto bajo.

## 🔴 Kill switches
- Cortar email ya: `delete from app_config where key='edge_base_url';` (o `DROP TRIGGER trg_discovery_lead_email ON public.discovery_leads;`).
- WhatsApp inmediato: ya off.
- Pausar agente por lead: `agent_paused=true`.
- Bajar frontend: rollback del deploy de Vercel.
- Backend: snapshots en `supabase/rollback/` + re-aplicar migración previa.
