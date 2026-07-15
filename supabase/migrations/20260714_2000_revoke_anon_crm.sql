-- ═══════════════════════════════════════════════════════════════════════════
-- SEGURIDAD — Barrido de grants FASE 3 (CRM): revocar anon/PUBLIC (14-jul-2026)
--
-- 30 funciones SECURITY DEFINER del CRM estaban ejecutables por anon. Se
-- revoca el subconjunto que NO es del funnel público de Discovery y que jamás
-- debe ser anónimo (todas conservan authenticated o service_role — verificado):
--   · crm_launch_campaign — un anónimo podía LANZAR una campaña (envío masivo)
--   · crm_preview_audience — leía leads_master (PII de leads)
--   · crm_run_due_campaigns, automation_tick, agent_health_* (5) — crons
--     internos (pg_cron/service_role), nunca invocados por anon
--   · enroll_lead_in_automation, enroll_segment_in_automation,
--     eval_run_condition — internos de automations
--   · create_workspace_with_admin — alta de workspace (authenticated)
--
-- DELIBERADAMENTE NO tocadas (funnel PÚBLICO de Discovery — el frontend sin
-- sesión las llama; contrato appril-growth/13-integrations):
--   submit_discovery_lead (x2), track_discovery_event, track_discovery_cta,
--   discovery_preview, discovery_fx_rates, appril_capabilities_*, fx_convert.
-- Tampoco current_user_role/current_workspace_id (helpers de auth.uid() usados
-- por RLS: inofensivos para anon —devuelven null— y quitarlos arriesga RLS).
-- Triggers no son invocables por RPC.
-- ═══════════════════════════════════════════════════════════════════════════

REVOKE ALL ON FUNCTION public.agent_health_canary_collect() FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.agent_health_canary_fire() FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.agent_health_notify() FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.agent_health_scan() FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.agent_health_tick() FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.automation_tick() FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.create_workspace_with_admin(text) FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.crm_launch_campaign(uuid) FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.crm_preview_audience(uuid,text,text[],uuid[],boolean) FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.crm_run_due_campaigns() FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.enroll_lead_in_automation(uuid,uuid) FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.enroll_segment_in_automation(uuid,text,integer) FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.eval_run_condition(uuid,timestamp with time zone,text,text) FROM anon, PUBLIC;
