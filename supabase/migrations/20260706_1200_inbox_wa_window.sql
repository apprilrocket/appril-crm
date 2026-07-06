-- ════════════════════════════════════════════════════════════════════════════
-- Inbox: exponer estado de la ventana de 24h de Meta + opt-outs por canal
-- ════════════════════════════════════════════════════════════════════════════
-- Objetivo: el inbox debe validar SIEMPRE la ventana de servicio de 24h de Meta
-- antes de permitir texto libre por WhatsApp. Para eso el front necesita el
-- timestamp del último mensaje ENTRANTE de WhatsApp del lead (cada 'wa_reply'
-- reabre la ventana rodante). Se añaden 3 columnas al final de inbox_threads:
--   * last_wa_reply_at : último 'wa_reply' del lead (NULL = nunca escribió por WA
--                        → ventana cerrada → solo templates).
--   * can_whatsapp     : opt-out / número sin WA (false ⇒ bloquear WA aunque haya
--                        ventana).
--   * can_email        : bounce / unsubscribe (false ⇒ bloquear email).
--
-- Email NO tiene ventana: se puede enviar siempre que can_email <> false.
--
-- ATENCIÓN: cambiar el RETURNS TABLE obliga a DROP FUNCTION antes de recrear
-- (CREATE OR REPLACE falla con "cannot change return type") y a re-emitir los
-- GRANT (se pierden en el DROP). Las columnas nuevas van AL FINAL para no romper
-- a consumidores que leen las columnas originales por orden.
-- ════════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS "public"."inbox_threads"(integer);

CREATE OR REPLACE FUNCTION "public"."inbox_threads"("p_limit" integer DEFAULT 50) RETURNS TABLE("lead_id" "uuid", "full_name" "text", "phone" "text", "email" "text", "marketing_segment" "text", "pipeline_stage" "text", "engagement_score" integer, "agent_paused" boolean, "last_inbound_at" timestamp with time zone, "last_inbound_text" "text", "last_inbound_channel" "text", "last_outbound_at" timestamp with time zone, "unread" boolean, "last_wa_reply_at" timestamp with time zone, "can_whatsapp" boolean, "can_email" boolean)
    LANGUAGE "sql" STABLE
    AS $$
  with inbound as (
    select distinct on (e.lead_id)
      e.lead_id, e.created_at,
      coalesce(e.metadata->'text'->>'body', e.event_value, e.event_type) as txt,
      coalesce(e.event_channel, 'whatsapp') as ch
    from lead_events e
    where e.event_type in ('wa_reply', 'email_replied')
    order by e.lead_id, e.created_at desc
  ),
  wa_win as (
    select e.lead_id, max(e.created_at) as last_wa
    from lead_events e
    where e.event_type = 'wa_reply'
    group by e.lead_id
  ),
  outbound as (
    select x.lead_id, max(x.at) as last_out from (
      select q.lead_id, q.sent_at as at from message_queue q where q.status = 'sent'
      union all
      select e.lead_id, e.created_at from lead_events e
      where e.event_type in ('wa_agent_reply', 'manual_reply')
    ) x
    group by x.lead_id
  )
  select
    l.id, l.full_name, l.phone, l.email,
    l.marketing_segment, l.pipeline_stage, l.engagement_score, l.agent_paused,
    i.created_at, i.txt, i.ch,
    o.last_out,
    (i.created_at > coalesce(l.inbox_read_at, 'epoch'::timestamptz)) as unread,
    w.last_wa, l.can_whatsapp, l.can_email
  from inbound i
  join leads_master l on l.id = i.lead_id
  left join outbound o on o.lead_id = i.lead_id
  left join wa_win w on w.lead_id = i.lead_id
  order by i.created_at desc
  limit p_limit;
$$;


ALTER FUNCTION "public"."inbox_threads"("p_limit" integer) OWNER TO "postgres";

-- El DROP descartó los GRANT previos; re-emitirlos igual que en schema.sql.
GRANT ALL ON FUNCTION "public"."inbox_threads"("p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."inbox_threads"("p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."inbox_threads"("p_limit" integer) TO "service_role";
