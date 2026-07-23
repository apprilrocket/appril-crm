-- DEC-023 gate D: excluir SEED por defecto de toda lectura de funnel/reportes.
--
-- Regla de filtrado (canónica, ver appril-growth/13-integrations/crm-mcp-contract.md):
--   · lead seed      = leads_master.marketing_segment = 'SEED'
--   · envío seed     = message_queue.triggered_by = 'seed_internal'
--   Los seeds EXISTEN como evidencia histórica (jamás se borran); solo se
--   excluyen de las lecturas. Para verlos: p_include_seed => true (RPCs) /
--   include_seed=true (tools del MCP).
--
-- Las 4 RPCs de reporte cambian de firma (+ p_include_seed boolean DEFAULT false),
-- por eso DROP + CREATE. Los callers existentes (dashboard /reports y /quality,
-- MCP get_report) llaman sin el parámetro → default false → SEED excluido.
-- De paso se cierran los grants: estas 4 quedaban ejecutables por anon/PUBLIC
-- (stats del negocio sin sesión); quedan en authenticated + service_role, como
-- el resto del barrido del 14-jul.

DROP FUNCTION IF EXISTS public.report_funnel();
DROP FUNCTION IF EXISTS public.report_channel_stats(integer);
DROP FUNCTION IF EXISTS public.report_activity_daily(integer);
DROP FUNCTION IF EXISTS public.lead_quality_summary();

CREATE FUNCTION public.report_funnel(p_include_seed boolean DEFAULT false)
 RETURNS TABLE(stage_key text, stage_label text, stage_color text, sort_order integer, leads bigint)
 LANGUAGE sql
 STABLE
AS $function$
  select ps.key, ps.label, ps.color, ps.position, count(l.id)
  from pipeline_stages ps
  left join leads_master l
    on l.pipeline_stage = ps.key
   and (p_include_seed or coalesce(l.marketing_segment, '') <> 'SEED')
  group by ps.key, ps.label, ps.color, ps.position
  order by ps.position;
$function$;

CREATE FUNCTION public.report_channel_stats(p_days integer DEFAULT 30, p_include_seed boolean DEFAULT false)
 RETURNS TABLE(channel text, sent bigint, delivered bigint, opened bigint, clicked bigint, replied bigint, failed bigint)
 LANGUAGE sql
 STABLE
AS $function$
  select
    coalesce(e.event_channel, 'otro'),
    count(*) filter (where e.event_type in ('message_sent', 'wa_agent_reply', 'manual_reply')),
    count(*) filter (where e.event_type in ('email_delivered', 'wa_delivered')),
    count(*) filter (where e.event_type in ('email_opened', 'wa_read')),
    count(*) filter (where e.event_type in ('email_clicked', 'cta_clicked')),
    count(*) filter (where e.event_type in ('wa_reply', 'email_replied')),
    count(*) filter (where e.event_type in ('wa_failed', 'email_bounced', 'email_complained'))
  from lead_events e
  where e.created_at >= now() - make_interval(days => p_days)
    and e.event_channel in ('email', 'whatsapp')
    and (p_include_seed or not exists (
      select 1 from leads_master lm
      where lm.id = e.lead_id and lm.marketing_segment = 'SEED'
    ))
  group by 1
  order by 1;
$function$;

CREATE FUNCTION public.report_activity_daily(p_days integer DEFAULT 14, p_include_seed boolean DEFAULT false)
 RETURNS TABLE(day date, outbound bigint, inbound bigint, engagement bigint)
 LANGUAGE sql
 STABLE
AS $function$
  select
    d.day::date,
    count(e.id) filter (where e.event_type in ('message_sent', 'wa_agent_reply', 'manual_reply')),
    count(e.id) filter (where e.event_type in ('wa_reply', 'email_replied')),
    count(e.id) filter (where e.event_type in ('email_opened', 'email_clicked', 'wa_read', 'cta_clicked', 'result_viewed'))
  from generate_series(
    (now() - make_interval(days => p_days - 1))::date,
    now()::date,
    interval '1 day'
  ) as d(day)
  left join lead_events e
    on e.created_at::date = d.day::date
   and (p_include_seed or not exists (
     select 1 from leads_master lm
     where lm.id = e.lead_id and lm.marketing_segment = 'SEED'
   ))
  group by d.day
  order by d.day;
$function$;

CREATE FUNCTION public.lead_quality_summary(p_include_seed boolean DEFAULT false)
 RETURNS TABLE(total bigint, sin_email bigint, sin_telefono bigint, telefono_invalido bigint, sin_nombre bigint, email_duplicado bigint, telefono_duplicado bigint)
 LANGUAGE sql
 STABLE
AS $function$
  with base as (
    select id, email, email_normalized, phone, full_name,
           (phone is not null and phone !~ '^\+[1-9][0-9]{7,14}$') as bad_phone
    from leads_master
    where (p_include_seed or coalesce(marketing_segment, '') <> 'SEED')
  ),
  dup_email as (
    select email_normalized from base
    where email_normalized is not null and email_normalized <> ''
    group by email_normalized having count(*) > 1
  ),
  dup_phone as (
    select phone from base
    where phone is not null and phone <> ''
    group by phone having count(*) > 1
  )
  select
    count(*),
    count(*) filter (where email is null or email = ''),
    count(*) filter (where phone is null or phone = ''),
    count(*) filter (where bad_phone),
    count(*) filter (where full_name is null or full_name = '' or full_name = 'Desconocido'),
    (select count(*) from base b join dup_email d on d.email_normalized = b.email_normalized),
    (select count(*) from base b join dup_phone d on d.phone = b.phone)
  from base;
$function$;

-- Grants: fuera anon/PUBLIC (antes ejecutables sin sesión), quedan cliente
-- logueado del dashboard + agentes/MCP.
REVOKE ALL ON FUNCTION public.report_funnel(boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_channel_stats(integer, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_activity_daily(integer, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lead_quality_summary(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_funnel(boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.report_channel_stats(integer, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.report_activity_daily(integer, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.lead_quality_summary(boolean) TO authenticated, service_role;
