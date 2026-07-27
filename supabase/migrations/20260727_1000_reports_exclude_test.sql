-- DEC-023 gate C — higiene aprobada por Mauricio (27-jul): los leads de prueba
-- (marketing_segment = 'TEST') quedan excluidos de reportes igual que SEED.
-- Contexto: 3 leads de prueba contaminaban HOT desde el E2E del 30-jun; fueron
-- reclasificados HOT→TEST vía MCP (auditado en lead_events + lead_notes).
-- Este cambio amplía el filtro por defecto de las 4 RPCs de reporte de
-- ('SEED') a ('SEED','TEST'). Firmas intactas (CREATE OR REPLACE conserva
-- grants: authenticated + service_role). p_include_seed=true sigue
-- reincorporando AMBAS poblaciones (evidencia histórica).

CREATE OR REPLACE FUNCTION public.report_funnel(p_include_seed boolean DEFAULT false)
 RETURNS TABLE(stage_key text, stage_label text, stage_color text, sort_order integer, leads bigint)
 LANGUAGE sql
 STABLE
AS $function$
  select ps.key, ps.label, ps.color, ps.position, count(l.id)
  from pipeline_stages ps
  left join leads_master l
    on l.pipeline_stage = ps.key
   and (p_include_seed or coalesce(l.marketing_segment, '') not in ('SEED','TEST'))
  group by ps.key, ps.label, ps.color, ps.position
  order by ps.position;
$function$;

CREATE OR REPLACE FUNCTION public.report_channel_stats(p_days integer DEFAULT 30, p_include_seed boolean DEFAULT false)
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
      where lm.id = e.lead_id and lm.marketing_segment in ('SEED','TEST')
    ))
  group by 1
  order by 1;
$function$;

CREATE OR REPLACE FUNCTION public.report_activity_daily(p_days integer DEFAULT 14, p_include_seed boolean DEFAULT false)
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
     where lm.id = e.lead_id and lm.marketing_segment in ('SEED','TEST')
   ))
  group by d.day
  order by d.day;
$function$;

CREATE OR REPLACE FUNCTION public.lead_quality_summary(p_include_seed boolean DEFAULT false)
 RETURNS TABLE(total bigint, sin_email bigint, sin_telefono bigint, telefono_invalido bigint, sin_nombre bigint, email_duplicado bigint, telefono_duplicado bigint)
 LANGUAGE sql
 STABLE
AS $function$
  with base as (
    select id, email, email_normalized, phone, full_name,
           (phone is not null and phone !~ '^\+[1-9][0-9]{7,14}$') as bad_phone
    from leads_master
    where (p_include_seed or coalesce(marketing_segment, '') not in ('SEED','TEST'))
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
