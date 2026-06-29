-- ════════════════════════════════════════════════════════════════════════════
-- Inbox legible: enriquecer conversation_messages para el hilo del /inbox
-- ════════════════════════════════════════════════════════════════════════════
-- Objetivo (CGO): el hilo del inbox a veces no se entiende. Esta migración
-- expone el contexto que faltaba para que cada burbuja se lea sola:
--   1. CLICKS DE BOTÓN DEL LEAD: el RPC ahora marca is_button_reply=true cuando
--      el lead tocó un quick-reply (el edge escribe metadata->>'kind'='button_reply').
--      Así el front puede pintar "tocó: «…»" en vez de un texto tecleado idéntico.
--   2. BOTONES OFRECIDOS POR EL AGENTE: se expone metadata->'buttons' (string[]
--      que el edge ya guarda) como columna `buttons`, para renderizar bajo el
--      mensaje del agente las opciones que se le ofrecieron al lead.
--   3. LINKS / CONTENIDO REAL DE TEMPLATES: para message_queue el body ahora usa
--      message_templates.text_body (el copy/link real) antes que el nombre.
--   4. EVENTOS DE SISTEMA como chips: nueva 4ª rama UNION ALL desde lead_events
--      (demo_created, demo_callback_sent, escalated_to_human, unsubscribed,
--      cta_clicked) con kind='system' y body en español (trato de usted).
--
-- ATENCIÓN: añadir columnas al RETURNS TABLE cambia el tipo de retorno, por lo
-- que CREATE OR REPLACE falla con "cannot change return type of existing
-- function". Hay que DROP FUNCTION primero y re-emitir los GRANT (se pierden en
-- el DROP). Las columnas nuevas (buttons, kind, is_button_reply) van AL FINAL
-- para no romper a los consumidores que leen las 7 columnas originales por orden.
-- ════════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS "public"."conversation_messages"("uuid");

CREATE OR REPLACE FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") RETURNS TABLE("id" "uuid", "direction" "text", "via" "text", "channel" "text", "body" "text", "status" "text", "happened_at" timestamp with time zone, "buttons" "text"[], "kind" "text", "is_button_reply" boolean)
    LANGUAGE "sql" STABLE
    AS $$
  with inbound as (
    select distinct on (coalesce(e.metadata->>'wa_message_id', e.metadata->>'id', e.id::text))
      e.id,
      coalesce(e.event_channel, 'whatsapp') as ch,
      coalesce(e.metadata->'text'->>'body', e.event_value, e.event_type) as txt,
      (e.metadata->>'kind' = 'button_reply') as is_btn,
      e.created_at
    from lead_events e
    where e.lead_id = p_lead_id and e.event_type in ('wa_reply', 'email_replied')
    order by coalesce(e.metadata->>'wa_message_id', e.metadata->>'id', e.id::text),
             (e.metadata->>'wa_message_id') is null,  -- prefiere formato agente
             e.created_at
  )
  select i.id, 'in'::text, 'lead'::text, i.ch, i.txt, 'received'::text, i.created_at,
         NULL::text[], 'message'::text, coalesce(i.is_btn, false)
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
    'message'::text, false
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
    NULL::text[], 'message'::text, false
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
    NULL::text[], 'system'::text, false
  from lead_events e
  where e.lead_id = p_lead_id
    and e.event_type in ('demo_created', 'demo_callback_sent', 'escalated_to_human', 'unsubscribed', 'cta_clicked')
  order by 7 asc;
$$;


ALTER FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") OWNER TO "postgres";

-- El DROP descartó los GRANT previos; re-emitirlos igual que en schema.sql.
GRANT ALL ON FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") TO "service_role";
