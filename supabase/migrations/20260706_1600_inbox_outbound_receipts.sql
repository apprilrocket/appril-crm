-- ════════════════════════════════════════════════════════════════════════════
-- Inbox: hilos iniciados por saliente + estado de entrega/lectura por burbuja
-- ════════════════════════════════════════════════════════════════════════════
-- Dos cambios para soportar la barra de búsqueda (escribir a leads que no han
-- respondido) y mostrar resultados de apertura/lectura:
--
-- 1. inbox_threads: hasta ahora solo listaba leads con evento ENTRANTE (INNER
--    join sobre inbound), así que un lead al que escribías pero no respondía
--    "desaparecía". Ahora la base es (inbound ∪ outbound); se ordena por
--    last_activity_at (máx entre último inbound y último saliente). Se añaden
--    last_activity_at y last_outbound_text para que el front pinte hora y
--    preview también en hilos sin respuesta. unread solo aplica a inbound.
--
-- 2. conversation_messages: nueva columna `receipt` con el mejor estado de
--    entrega por burbuja saliente (clicked > read/opened > delivered > sent >
--    failed), correlacionando los eventos wa_*/email_* por el id externo:
--    message_queue → wa_message_id|ses_message_id; wa_agent_reply/manual_reply →
--    metadata.wa_message_id.
--
-- Cambian el RETURNS TABLE → DROP + recreate + re-GRANT (columnas nuevas al final).
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. inbox_threads ────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS "public"."inbox_threads"(integer);

CREATE OR REPLACE FUNCTION "public"."inbox_threads"("p_limit" integer DEFAULT 50) RETURNS TABLE("lead_id" "uuid", "full_name" "text", "phone" "text", "email" "text", "marketing_segment" "text", "pipeline_stage" "text", "engagement_score" integer, "agent_paused" boolean, "last_inbound_at" timestamp with time zone, "last_inbound_text" "text", "last_inbound_channel" "text", "last_outbound_at" timestamp with time zone, "unread" boolean, "last_wa_reply_at" timestamp with time zone, "can_whatsapp" boolean, "can_email" boolean, "last_activity_at" timestamp with time zone, "last_outbound_text" "text")
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
    select distinct on (z.lead_id) z.lead_id, z.at, z.txt from (
      select q.lead_id, coalesce(q.sent_at, q.created_at) as at,
        case
          when q.template_key = '__freeform__'
            then coalesce(q.payload->>'text', q.payload->>'subject', '(mensaje)')
          else coalesce(t.text_body, t.name, q.template_key)
        end as txt
      from message_queue q
      left join message_templates t on t.template_key = q.template_key and t.workspace_id = q.workspace_id
      -- Solo envíos 1:1 (manuales/directos): excluir campañas y automatizaciones
      -- para que un blast masivo NO inunde el inbox de "conversaciones".
      where q.status in ('sent', 'sending', 'pending')
        and q.campaign_id is null and q.automation_run_id is null
      union all
      select e.lead_id, e.created_at, coalesce(e.event_value, '')
      from lead_events e
      where e.event_type in ('wa_agent_reply', 'manual_reply')
    ) z
    order by z.lead_id, z.at desc nulls last
  ),
  base as (
    select lead_id from inbound
    union
    select lead_id from outbound
  )
  select
    l.id, l.full_name, l.phone, l.email,
    l.marketing_segment, l.pipeline_stage, l.engagement_score, l.agent_paused,
    i.created_at, i.txt, i.ch,
    o.at,
    (i.created_at is not null and i.created_at > coalesce(l.inbox_read_at, 'epoch'::timestamptz)) as unread,
    w.last_wa, l.can_whatsapp, l.can_email,
    greatest(coalesce(i.created_at, 'epoch'::timestamptz), coalesce(o.at, 'epoch'::timestamptz)) as last_activity_at,
    o.txt
  from base b
  join leads_master l on l.id = b.lead_id
  left join inbound i on i.lead_id = b.lead_id
  left join outbound o on o.lead_id = b.lead_id
  left join wa_win w on w.lead_id = b.lead_id
  order by last_activity_at desc
  limit p_limit;
$$;

ALTER FUNCTION "public"."inbox_threads"("p_limit" integer) OWNER TO "postgres";
GRANT ALL ON FUNCTION "public"."inbox_threads"("p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."inbox_threads"("p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."inbox_threads"("p_limit" integer) TO "service_role";


-- ── 2. conversation_messages ────────────────────────────────────────────────
DROP FUNCTION IF EXISTS "public"."conversation_messages"("uuid");

CREATE OR REPLACE FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") RETURNS TABLE("id" "uuid", "direction" "text", "via" "text", "channel" "text", "body" "text", "status" "text", "happened_at" timestamp with time zone, "buttons" "text"[], "kind" "text", "is_button_reply" boolean, "receipt" "text")
    LANGUAGE "sql" STABLE
    AS $$
  with receipts as (
    -- Mejor estado de entrega por id externo (wamid o SES messageId).
    select
      coalesce(e.metadata->>'id', e.metadata->'mail'->>'messageId') as ext_id,
      max(case e.event_type
        when 'email_clicked'   then 6
        when 'wa_read'         then 5
        when 'email_opened'    then 5
        when 'wa_delivered'    then 4
        when 'email_delivered' then 4
        when 'wa_sent'         then 3
        when 'wa_failed'       then 2
        when 'email_bounced'   then 2
        when 'email_complained' then 2
        when 'email_rejected'  then 2
        else 0 end) as rank
    from lead_events e
    where e.lead_id = p_lead_id
      and e.event_type in ('wa_sent','wa_delivered','wa_read','wa_failed',
        'email_delivered','email_opened','email_clicked','email_bounced','email_complained','email_rejected')
      and coalesce(e.metadata->>'id', e.metadata->'mail'->>'messageId') is not null
    group by 1
  ),
  inbound as (
    select distinct on (coalesce(e.metadata->>'wa_message_id', e.metadata->>'id', e.id::text))
      e.id,
      coalesce(e.event_channel, 'whatsapp') as ch,
      coalesce(e.metadata->'text'->>'body', e.event_value, e.event_type) as txt,
      (e.metadata->>'kind' = 'button_reply') as is_btn,
      e.created_at
    from lead_events e
    where e.lead_id = p_lead_id and e.event_type in ('wa_reply', 'email_replied')
    order by coalesce(e.metadata->>'wa_message_id', e.metadata->>'id', e.id::text),
             (e.metadata->>'wa_message_id') is null,
             e.created_at
  )
  select i.id, 'in'::text, 'lead'::text, i.ch, i.txt, 'received'::text, i.created_at,
         NULL::text[], 'message'::text, coalesce(i.is_btn, false), NULL::text
  from inbound i
  union all
  select e.id, 'out'::text,
    case when coalesce(e.metadata->>'manual', 'false') = 'true' then 'manual' else 'agent' end,
    coalesce(e.event_channel, 'whatsapp'),
    coalesce(e.event_value, ''),
    'sent'::text, e.created_at,
    case
      when jsonb_typeof(e.metadata->'buttons') = 'array'
           and jsonb_array_length(e.metadata->'buttons') > 0
        then array(select jsonb_array_elements_text(e.metadata->'buttons'))
      else NULL::text[]
    end,
    'message'::text, false,
    (select case r.rank when 6 then 'clicked' when 5 then 'read' when 4 then 'delivered' when 3 then 'sent' when 2 then 'failed' else null end
       from receipts r where r.ext_id = e.metadata->>'wa_message_id')
  from lead_events e
  where e.lead_id = p_lead_id and e.event_type in ('wa_agent_reply', 'manual_reply')
  union all
  select q.id, 'out'::text, coalesce(q.triggered_by, 'queue'),
    q.channel,
    case
      when q.template_key = '__freeform__'
        then coalesce(q.payload->>'text', q.payload->>'subject', '(mensaje)')
      else coalesce(t.text_body, t.name, q.template_key)
    end,
    coalesce(q.status, 'pending'),
    coalesce(q.sent_at, q.created_at),
    NULL::text[], 'message'::text, false,
    (select case r.rank when 6 then 'clicked' when 5 then 'read' when 4 then 'delivered' when 3 then 'sent' when 2 then 'failed' else null end
       from receipts r where r.ext_id = coalesce(q.wa_message_id, q.ses_message_id))
  from message_queue q
  left join message_templates t
    on t.template_key = q.template_key and t.workspace_id = q.workspace_id
  where q.lead_id = p_lead_id
  union all
  select e.id, 'system'::text, e.event_type,
    coalesce(e.event_channel, 'whatsapp'),
    case e.event_type
      when 'demo_created' then
        case when e.event_value = 'duplicate_reused'
          then 'Demo viva duplicada (el número ya tenía una)'
          else 'Demo viva creada' end
      when 'demo_callback_sent' then
        case when e.event_value = 'cancel'
          then 'El doctor canceló la cita demo'
          else 'El doctor confirmó la cita demo' end
      when 'escalated_to_human' then 'Pasado a Mauricio'
      when 'unsubscribed' then 'El lead se dio de baja'
      when 'cta_clicked' then
        'Hizo click en el CTA' ||
        case when coalesce(e.event_value, '') <> '' and e.event_value <> e.event_type
          then ': ' || e.event_value else '' end
      else e.event_type
    end,
    ''::text, e.created_at,
    NULL::text[], 'system'::text, false, NULL::text
  from lead_events e
  where e.lead_id = p_lead_id
    and e.event_type in ('demo_created', 'demo_callback_sent', 'escalated_to_human', 'unsubscribed', 'cta_clicked')
  order by 7 asc;
$$;

ALTER FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") OWNER TO "postgres";
GRANT ALL ON FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") TO "service_role";
