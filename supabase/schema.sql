


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."apply_lead_engagement"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  w integer := lead_event_weight(new.event_type);
begin
  if w > 0 and new.lead_id is not null then
    update leads_master
       set engagement_score = engagement_score + w,
           last_engaged_at  = greatest(coalesce(last_engaged_at, new.created_at), new.created_at),
           updated_at       = now()
     where id = new.lead_id;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."apply_lead_engagement"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_advance_pipeline"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  target_stage text;
  l record;
  cur_pos int;
  new_pos int;
begin
  if new.lead_id is null then return new; end if;

  target_stage := stage_for_event(new.event_type);
  if target_stage is null then return new; end if;

  select pipeline_stage, workspace_id into l from leads_master where id = new.lead_id;
  if not found then return new; end if;

  -- etapas terminales: no se tocan automáticamente
  if l.pipeline_stage in ('converted','lost') then return new; end if;

  select position into cur_pos from pipeline_stages
   where workspace_id = l.workspace_id and key = coalesce(l.pipeline_stage,'new');
  select position into new_pos from pipeline_stages
   where workspace_id = l.workspace_id and key = target_stage;

  if new_pos is null or (cur_pos is not null and new_pos <= cur_pos) then
    return new;  -- solo hacia adelante
  end if;

  update leads_master
     set pipeline_stage = target_stage,
         last_contacted_at = case when new.event_type in ('message_sent','wa_sent','email_delivered')
                                  then now() else last_contacted_at end,
         updated_at = now()
   where id = new.lead_id;

  insert into lead_events (workspace_id, lead_id, event_type, event_value, metadata)
  values (l.workspace_id, new.lead_id, 'stage_changed', target_stage,
          jsonb_build_object('auto', true, 'from', l.pipeline_stage, 'cause', new.event_type));

  return new;
end;
$$;


ALTER FUNCTION "public"."auto_advance_pipeline"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_enroll_on_event"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  a record;
begin
  if new.lead_id is null then return new; end if;
  -- no reaccionar a eventos internos del propio motor
  if new.event_type like 'automation_%' then return new; end if;

  for a in
    select id from automations
     where status = 'active'
       and (
         (trigger_type = 'event' and trigger_config->>'event_type' = new.event_type)
         or (trigger_type = 'stage' and new.event_type = 'stage_changed'
             and trigger_config->>'stage' = new.event_value)
       )
  loop
    perform enroll_lead_in_automation(a.id, new.lead_id);
  end loop;
  return new;
end;
$$;


ALTER FUNCTION "public"."auto_enroll_on_event"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."automation_tick"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  r record;
  a_flow jsonb;
  node jsonb;
  node_type text;
  next_id text;
  hops int;
  processed int := 0;
  lead leads_master%rowtype;
  tpl record;
  v_to text;
  v_payload jsonb;
  cond_ok boolean;
  wait_minutes int;
  recheck_hours int;
  timeout_days int;
begin
  for r in
    select ar.id as run_id, ar.lead_id, ar.current_node_id, ar.started_at, ar.workspace_id,
           a.id as automation_id, a.flow, a.name as automation_name
      from automation_runs ar
      join automations a on a.id = ar.automation_id
     where ar.status = 'active' and ar.next_run_at <= now() and a.status = 'active'
     order by ar.next_run_at
     limit 200
     for update of ar skip locked
  loop
    processed := processed + 1;
    a_flow := r.flow;
    next_id := r.current_node_id;
    hops := 0;

    select * into lead from leads_master where id = r.lead_id;
    if not found then
      update automation_runs set status='failed', exit_reason='lead_missing', finished_at=now() where id = r.run_id;
      continue;
    end if;

    <<advance>>
    loop
      hops := hops + 1;
      if hops > 25 then
        update automation_runs set status='failed', exit_reason='loop_guard', finished_at=now() where id = r.run_id;
        exit advance;
      end if;

      node := flow_node(a_flow, next_id);
      if node is null then
        update automation_runs set status='completed', exit_reason='end_of_flow', finished_at=now() where id = r.run_id;
        exit advance;
      end if;
      node_type := node->>'type';

      if node_type = 'trigger' then
        next_id := flow_next_node(a_flow, next_id);
        if next_id is null then
          update automation_runs set status='completed', exit_reason='end_of_flow', finished_at=now() where id = r.run_id;
          exit advance;
        end if;
        update automation_runs set current_node_id = next_id where id = r.run_id;

      elsif node_type in ('send_email','send_whatsapp') then
        select * into tpl from message_templates
         where template_key = node->'data'->>'templateKey' and status = 'active' limit 1;

        if found then
          v_to := case when node_type = 'send_email' then lead.email else lead.phone end;
          if (node_type = 'send_email' and coalesce(lead.can_email,false) and v_to is not null)
             or (node_type = 'send_whatsapp' and coalesce(lead.can_whatsapp,false) and v_to is not null) then

            select coalesce(jsonb_object_agg(v, lead_var_value(lead, v)), '{}'::jsonb)
              into v_payload
              from jsonb_array_elements_text(coalesce(tpl.variables, '[]'::jsonb)) v;

            insert into message_queue
              (workspace_id, lead_id, automation_run_id, template_key, channel, to_address, payload, triggered_by, scheduled_at)
            values
              (r.workspace_id, r.lead_id, r.run_id, tpl.template_key,
               case when node_type='send_email' then 'email' else 'whatsapp' end,
               v_to, v_payload, 'automation', now());
          else
            insert into lead_events (workspace_id, lead_id, event_type, event_value)
            values (r.workspace_id, r.lead_id, 'automation_send_skipped',
                    r.automation_name || ' · ' || coalesce(node->'data'->>'templateKey','?'));
          end if;
        end if;
        next_id := flow_next_node(a_flow, next_id);
        if next_id is null then
          update automation_runs set status='completed', exit_reason='end_of_flow', finished_at=now() where id = r.run_id;
          exit advance;
        end if;
        update automation_runs set current_node_id = next_id where id = r.run_id;

      elsif node_type = 'wait' then
        wait_minutes := coalesce((node->'data'->>'amount')::int, 1) *
          case coalesce(node->'data'->>'unit','days')
            when 'minutes' then 1 when 'hours' then 60 else 1440 end;
        next_id := flow_next_node(a_flow, next_id);
        if next_id is null then
          update automation_runs set status='completed', exit_reason='end_of_flow', finished_at=now() where id = r.run_id;
        else
          update automation_runs
             set current_node_id = next_id,
                 next_run_at = now() + make_interval(mins => wait_minutes)
           where id = r.run_id;
        end if;
        exit advance;

      elsif node_type = 'condition' then
        cond_ok := eval_run_condition(r.lead_id, r.started_at,
                     node->'data'->>'kind', node->'data'->>'value');
        next_id := flow_next_node(a_flow, next_id, case when cond_ok then 'yes' else 'no' end);
        if next_id is null then
          update automation_runs set status='completed', exit_reason='condition_dead_end', finished_at=now() where id = r.run_id;
          exit advance;
        end if;
        update automation_runs set current_node_id = next_id where id = r.run_id;

      elsif node_type = 'goal' then
        cond_ok := eval_run_condition(r.lead_id, r.started_at,
                     node->'data'->>'kind', node->'data'->>'value');
        if cond_ok then
          update automation_runs
             set status='converted', exit_reason='goal_met', goal_met_at=now(), finished_at=now()
           where id = r.run_id;
          insert into lead_events (workspace_id, lead_id, event_type, event_value)
          values (r.workspace_id, r.lead_id, 'automation_converted', r.automation_name);
          exit advance;
        end if;

        timeout_days := coalesce((node->'data'->>'timeoutDays')::int, 30);
        if r.started_at + make_interval(days => timeout_days) < now() then
          next_id := flow_next_node(a_flow, next_id, 'no');
          if next_id is null then
            update automation_runs set status='completed', exit_reason='goal_timeout', finished_at=now() where id = r.run_id;
            exit advance;
          end if;
          update automation_runs set current_node_id = next_id where id = r.run_id;
        else
          recheck_hours := coalesce((node->'data'->>'recheckHours')::int, 6);
          update automation_runs set next_run_at = now() + make_interval(hours => recheck_hours) where id = r.run_id;
          exit advance;
        end if;

      elsif node_type = 'exit' then
        update automation_runs set status='completed', exit_reason='exit_node', finished_at=now() where id = r.run_id;
        insert into lead_events (workspace_id, lead_id, event_type, event_value)
        values (r.workspace_id, r.lead_id, 'automation_completed', r.automation_name);
        exit advance;

      else
        update automation_runs set status='failed', exit_reason='unknown_node_'||coalesce(node_type,'null'), finished_at=now() where id = r.run_id;
        exit advance;
      end if;
    end loop advance;
  end loop;

  return processed;
end;
$$;


ALTER FUNCTION "public"."automation_tick"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_discovery_score"("p_q_volume" "text", "p_q_lost" "text", "p_q_intent" "text", "p_q_urgency" "text", "p_q_ticket" "text", "p_q_digital" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
  v_vol   integer := 0;
  v_lost  integer := 0;
  v_int   integer := 0;
  v_urg   integer := 0;
  v_tick  integer := 0;
  v_dig   integer := 0;
  v_total integer;
  v_seg   text;
  v_cls   text;
  v_action text;
BEGIN
  -- Factor 1: Volumen (0-25) — espeja scoring.js midpoints
  v_vol := CASE p_q_volume
    WHEN 'gt_300'   THEN 25
    WHEN '151_300'  THEN 20
    WHEN '81_150'   THEN 13
    WHEN '30_80'    THEN 6
    WHEN 'lt_30'    THEN 2
    ELSE 0 END;

  -- Factor 2: Citas perdidas (0-20) — midpoints: 0_2→1, 3_5→4, 6_10→8, 11_20→15, gt_20→25
  v_lost := CASE p_q_lost
    WHEN 'no_medido' THEN 6
    WHEN 'gt_20'     THEN 20
    WHEN '11_20'     THEN 16
    WHEN '6_10'      THEN 12
    WHEN '3_5'       THEN 8
    WHEN '0_2'       THEN 2
    ELSE 0 END;

  -- Factor 3: Intención (0-20)
  v_int := CASE p_q_intent
    WHEN 'demo'        THEN 20
    WHEN 'probar'      THEN 15
    WHEN 'información' THEN 8
    WHEN 'solo_ver'    THEN 3
    ELSE 0 END;

  -- Factor 4: Urgencia (0-15) — ya debe venir canonicalizado (alta|media|baja)
  v_urg := CASE p_q_urgency
    WHEN 'alta'  THEN 15
    WHEN 'media' THEN 8
    WHEN 'baja'  THEN 2
    ELSE 0 END;

  -- Factor 5: Ticket (0-10) — midpoints: lt_10→8, 10_25→18, 25_50→38, 50_100→75, gt_100→120, variable→50
  v_tick := CASE p_q_ticket
    WHEN 'gt_100'  THEN 10
    WHEN '50_100'  THEN 8
    WHEN '25_50'   THEN 5
    WHEN 'variable' THEN 5
    WHEN '10_25'   THEN 3
    WHEN 'lt_10'   THEN 1
    ELSE 0 END;

  -- Factor 6: Método de agenda (0-10)
  v_dig := CASE
    WHEN p_q_digital IN ('papel','llamadas','sin_sistema')    THEN 10
    WHEN p_q_digital IN ('whatsapp','excel')                  THEN 7
    WHEN p_q_digital = 'software_basico'                      THEN 3
    WHEN p_q_digital = 'software_avanzado'                    THEN 1
    ELSE 0 END;

  v_total := LEAST(100, v_vol + v_lost + v_int + v_urg + v_tick + v_dig);

  -- Segmento y clasificación
  v_seg    := CASE WHEN v_total >= 75 THEN 'SUPER_HOT'
                   WHEN v_total >= 50 THEN 'HOT'
                   WHEN v_total >= 25 THEN 'WARM'
                   ELSE 'COLD' END;
  v_cls    := CASE WHEN v_total >= 75 THEN 'sql_caliente'
                   WHEN v_total >= 50 THEN 'mql'
                   WHEN v_total >= 25 THEN 'lead_tibio'
                   ELSE 'lead_frio' END;
  v_action := CASE WHEN v_total >= 50 THEN 'contactar_whatsapp'
                   WHEN v_total >= 25 THEN 'nutrir'
                   ELSE 'enviar_guia' END;

  RETURN jsonb_build_object(
    'score',               v_total,
    'segment',             v_seg,
    'lead_classification', v_cls,
    'recommended_action',  v_action,
    'breakdown', jsonb_build_object(
      'volume', v_vol, 'lost', v_lost, 'intent', v_int,
      'urgency', v_urg, 'ticket', v_tick, 'digital', v_dig
    )
  );
END;
$$;


ALTER FUNCTION "public"."calculate_discovery_score"("p_q_volume" "text", "p_q_lost" "text", "p_q_intent" "text", "p_q_urgency" "text", "p_q_ticket" "text", "p_q_digital" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."campaign_lead_results"("p_campaign_id" "uuid") RETURNS TABLE("lead_id" "uuid", "full_name" "text", "email" "text", "phone" "text", "to_address" "text", "queue_status" "text", "last_error" "text", "sent_at" timestamp with time zone, "delivered" boolean, "opened" boolean, "clicked" boolean, "replied_at" timestamp with time zone, "reply_value" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  with msgs as (
    select mq.lead_id, mq.to_address, mq.status, mq.last_error, mq.sent_at
      from message_queue mq
     where mq.campaign_id = p_campaign_id
  ),
  ev as (
    select le.lead_id,
           bool_or(le.event_type in ('email_delivered','wa_delivered')) as delivered,
           bool_or(le.event_type in ('email_opened','wa_read')) as opened,
           bool_or(le.event_type in ('email_clicked','cta_clicked')) as clicked,
           max(le.created_at) filter (where le.event_type in ('wa_reply','email_replied')) as replied_at,
           (array_agg(le.event_value order by le.created_at desc)
              filter (where le.event_type in ('wa_reply','email_replied')))[1] as reply_value
      from lead_events le
      join msgs m on m.lead_id = le.lead_id
     where m.sent_at is not null and le.created_at >= m.sent_at
     group by le.lead_id
  )
  select m.lead_id, l.full_name, l.email, l.phone, m.to_address, m.status, m.last_error, m.sent_at,
         coalesce(e.delivered, false), coalesce(e.opened, false), coalesce(e.clicked, false),
         e.replied_at, e.reply_value
    from msgs m
    join leads_master l on l.id = m.lead_id
    left join ev e on e.lead_id = m.lead_id
   order by e.replied_at desc nulls last, m.sent_at desc nulls last;
$$;


ALTER FUNCTION "public"."campaign_lead_results"("p_campaign_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."campaign_results"("p_campaign_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  with msgs as (
    select lead_id, status, sent_at from message_queue where campaign_id = p_campaign_id
  ),
  ev as (
    select le.lead_id, le.event_type
      from lead_events le
      join msgs m on m.lead_id = le.lead_id
     where m.sent_at is not null and le.created_at >= m.sent_at
  )
  select jsonb_build_object(
    'total',     (select count(*) from msgs),
    'pending',   (select count(*) from msgs where status in ('pending','sending')),
    'sent',      (select count(*) from msgs where status = 'sent'),
    'failed',    (select count(*) from msgs where status = 'failed'),
    'delivered', (select count(distinct lead_id) from ev where event_type in ('email_delivered','wa_delivered')),
    'opened',    (select count(distinct lead_id) from ev where event_type in ('email_opened','wa_read')),
    'clicked',   (select count(distinct lead_id) from ev where event_type in ('email_clicked','cta_clicked')),
    'replied',   (select count(distinct lead_id) from ev where event_type in ('wa_reply','email_replied'))
  );
$$;


ALTER FUNCTION "public"."campaign_results"("p_campaign_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."campaigns_overview"() RETURNS TABLE("campaign_id" "uuid", "total" bigint, "pending" bigint, "sent" bigint, "failed" bigint, "delivered" bigint, "opened" bigint, "clicked" bigint, "replied" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  with msgs as (
    select mq.campaign_id, mq.lead_id, mq.status, mq.sent_at
      from message_queue mq
     where mq.campaign_id is not null
  ),
  ev as (
    select m.campaign_id, le.lead_id, le.event_type
      from lead_events le
      join msgs m on m.lead_id = le.lead_id
     where m.sent_at is not null and le.created_at >= m.sent_at
  ),
  ev_agg as (
    select e.campaign_id,
           count(distinct e.lead_id) filter (where e.event_type in ('email_delivered','wa_delivered')) as delivered,
           count(distinct e.lead_id) filter (where e.event_type in ('email_opened','wa_read')) as opened,
           count(distinct e.lead_id) filter (where e.event_type in ('email_clicked','cta_clicked')) as clicked,
           count(distinct e.lead_id) filter (where e.event_type in ('wa_reply','email_replied')) as replied
      from ev e
     group by e.campaign_id
  ),
  msg_agg as (
    select m.campaign_id,
           count(*) as total,
           count(*) filter (where m.status in ('pending','sending')) as pending,
           count(*) filter (where m.status = 'sent') as sent,
           count(*) filter (where m.status = 'failed') as failed
      from msgs m
     group by m.campaign_id
  )
  select ma.campaign_id, ma.total, ma.pending, ma.sent, ma.failed,
         coalesce(ea.delivered, 0), coalesce(ea.opened, 0), coalesce(ea.clicked, 0), coalesce(ea.replied, 0)
    from msg_agg ma
    left join ev_agg ea on ea.campaign_id = ma.campaign_id;
$$;


ALTER FUNCTION "public"."campaigns_overview"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") RETURNS TABLE("id" "uuid", "direction" "text", "via" "text", "channel" "text", "body" "text", "status" "text", "happened_at" timestamp with time zone)
    LANGUAGE "sql" STABLE
    AS $$
  with inbound as (
    select distinct on (coalesce(e.metadata->>'wa_message_id', e.metadata->>'id', e.id::text))
      e.id,
      coalesce(e.event_channel, 'whatsapp') as ch,
      coalesce(e.metadata->'text'->>'body', e.event_value, e.event_type) as txt,
      e.created_at
    from lead_events e
    where e.lead_id = p_lead_id and e.event_type in ('wa_reply', 'email_replied')
    order by coalesce(e.metadata->>'wa_message_id', e.metadata->>'id', e.id::text),
             (e.metadata->>'wa_message_id') is null,  -- prefiere formato agente
             e.created_at
  )
  select i.id, 'in'::text, 'lead'::text, i.ch, i.txt, 'received'::text, i.created_at
  from inbound i
  union all
  select e.id, 'out'::text,
    case when coalesce(e.metadata->>'manual', 'false') = 'true' then 'manual' else 'agent' end,
    coalesce(e.event_channel, 'whatsapp'),
    coalesce(e.event_value, ''),
    'sent'::text, e.created_at
  from lead_events e
  where e.lead_id = p_lead_id and e.event_type in ('wa_agent_reply', 'manual_reply')
  union all
  select q.id, 'out'::text, coalesce(q.triggered_by, 'queue'),
    q.channel,
    case
      when q.template_key = '__freeform__'
        then coalesce(q.payload->>'text', q.payload->>'subject', '(mensaje)')
      else coalesce(t.name, q.template_key)
    end,
    coalesce(q.status, 'pending'),
    coalesce(q.sent_at, q.created_at)
  from message_queue q
  left join message_templates t
    on t.template_key = q.template_key and t.workspace_id = q.workspace_id
  where q.lead_id = p_lead_id
  order by 7 asc;
$$;


ALTER FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_workspace_with_admin"("p_name" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_email text;
  v_ws uuid;
  v_slug text;
  v_n int := 0;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'workspace name required';
  end if;

  -- Ya tiene workspace -> idempotente
  select workspace_id into v_ws from crm_users where auth_user_id = v_uid limit 1;
  if v_ws is not null then
    return v_ws;
  end if;

  select email into v_email from auth.users where id = v_uid;

  -- slug único a partir del nombre
  v_slug := lower(regexp_replace(trim(p_name), '[^a-zA-Z0-9]+', '-', 'g'));
  v_slug := trim(both '-' from v_slug);
  if v_slug = '' then v_slug := 'workspace'; end if;
  while exists (select 1 from workspaces where slug = v_slug || case when v_n = 0 then '' else '-' || v_n end) loop
    v_n := v_n + 1;
  end loop;
  if v_n > 0 then v_slug := v_slug || '-' || v_n; end if;

  insert into workspaces (name, slug)
  values (trim(p_name), v_slug)
  returning id into v_ws;

  insert into crm_users (auth_user_id, workspace_id, email, role, active)
  values (v_uid, v_ws, coalesce(v_email, ''), 'admin', true);

  insert into pipeline_stages (workspace_id, key, label, position, color, is_terminal) values
    (v_ws, 'new',       'Nuevo',        1, '#94a3b8', false),
    (v_ws, 'contacted', 'Contactado',   2, '#3b82f6', false),
    (v_ws, 'engaged',   'Comprometido', 3, '#8b5cf6', false),
    (v_ws, 'qualified', 'Calificado',   4, '#10b981', false),
    (v_ws, 'converted', 'Convertido',   5, '#22c55e', true),
    (v_ws, 'lost',      'Perdido',      6, '#ef4444', true);

  insert into workspace_integrations (workspace_id, channel) values
    (v_ws, 'email'),
    (v_ws, 'whatsapp');

  return v_ws;
end;
$$;


ALTER FUNCTION "public"."create_workspace_with_admin"("p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_user_role"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT role
  FROM public.crm_users
  WHERE auth_user_id = auth.uid()
  LIMIT 1
$$;


ALTER FUNCTION "public"."current_user_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_workspace_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT workspace_id
  FROM public.crm_users
  WHERE auth_user_id = auth.uid()
  LIMIT 1
$$;


ALTER FUNCTION "public"."current_workspace_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_referral_invite"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.source = 'appril_referral' and coalesce(new.phone, '') <> '' then
    -- dedup: no escribir 2 veces al mismo referido con este template
    if not exists (
      select 1 from public.message_queue
      where template_key = 'referido_invitacion' and to_address = new.phone
    ) then
      insert into public.message_queue
        (workspace_id, lead_id, template_key, channel, to_address, payload, scheduled_at, status, triggered_by)
      values (
        coalesce(new.workspace_id, 'e2096477-fa6a-4b8f-a8b3-bd46ad720167'::uuid),
        new.id,
        'referido_invitacion',
        'whatsapp',
        new.phone,
        jsonb_build_object(
          'referido_nombre',  coalesce(nullif(trim(new.full_name), ''), 'Doctor(a)'),
          'referidor_nombre', coalesce(nullif(trim(new.referred_by_name), ''), 'un paciente')
        ),
        now(),
        'pending',
        'appril_referral_trigger'
      );
    end if;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."enqueue_referral_invite"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enroll_lead_in_automation"("p_automation_id" "uuid", "p_lead_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  a record;
  trigger_node_id text;
  run_id uuid;
  allow_reenroll boolean;
begin
  select * into a from automations where id = p_automation_id and status = 'active';
  if not found then return null; end if;

  select n->>'id' into trigger_node_id
    from jsonb_array_elements(a.flow->'nodes') n
   where n->>'type' = 'trigger' limit 1;
  if trigger_node_id is null then return null; end if;

  allow_reenroll := coalesce((a.trigger_config->>'allow_reenroll')::boolean, false);

  -- nunca dos runs activos; sin re-enroll tampoco si ya pasó por el flujo
  if exists (select 1 from automation_runs
              where automation_id = p_automation_id and lead_id = p_lead_id
                and (status = 'active' or not allow_reenroll)) then
    return null;
  end if;

  insert into automation_runs (workspace_id, automation_id, lead_id, current_node_id, status, next_run_at)
  values (a.workspace_id, p_automation_id, p_lead_id, trigger_node_id, 'active', now())
  returning id into run_id;

  insert into lead_events (workspace_id, lead_id, event_type, event_value)
  values (a.workspace_id, p_lead_id, 'automation_enrolled', a.name);

  return run_id;
end;
$$;


ALTER FUNCTION "public"."enroll_lead_in_automation"("p_automation_id" "uuid", "p_lead_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enroll_segment_in_automation"("p_automation_id" "uuid", "p_segment" "text", "p_limit" integer DEFAULT 1000) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  n int := 0;
  r record;
begin
  for r in
    select l.id from leads_master l
     where l.marketing_segment = p_segment
       and l.workspace_id = (select workspace_id from automations where id = p_automation_id)
       and not exists (select 1 from automation_runs ar
                        where ar.automation_id = p_automation_id and ar.lead_id = l.id)
     limit p_limit
  loop
    if enroll_lead_in_automation(p_automation_id, r.id) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;


ALTER FUNCTION "public"."enroll_segment_in_automation"("p_automation_id" "uuid", "p_segment" "text", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."eval_run_condition"("p_lead_id" "uuid", "p_run_started" timestamp with time zone, "p_kind" "text", "p_value" "text") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
declare
  l record;
begin
  select pipeline_stage, marketing_segment, engagement_score, phone
    into l from leads_master where id = p_lead_id;

  return case p_kind
    when 'email_opened' then exists (
      select 1 from lead_events where lead_id = p_lead_id
        and event_type = 'email_opened' and created_at >= p_run_started)
    when 'email_clicked' then exists (
      select 1 from lead_events where lead_id = p_lead_id
        and event_type in ('email_clicked','cta_clicked') and created_at >= p_run_started)
    when 'wa_replied' then exists (
      select 1 from lead_events le
       where le.event_type = 'wa_reply' and le.created_at >= p_run_started
         and (le.lead_id = p_lead_id or (
           nullif(regexp_replace(coalesce(l.phone,''), '\D', '', 'g'), '') is not null
           and le.lead_id in (
             select lm.id from leads_master lm
              where regexp_replace(coalesce(lm.phone,''), '\D', '', 'g')
                  = regexp_replace(l.phone, '\D', '', 'g')))))
    when 'any_reply' then exists (
      select 1 from lead_events le
       where le.event_type in ('wa_reply','email_replied','contact_submitted','discovery_form_submitted')
         and le.created_at >= p_run_started
         and (le.lead_id = p_lead_id or (
           nullif(regexp_replace(coalesce(l.phone,''), '\D', '', 'g'), '') is not null
           and le.lead_id in (
             select lm.id from leads_master lm
              where regexp_replace(coalesce(lm.phone,''), '\D', '', 'g')
                  = regexp_replace(l.phone, '\D', '', 'g')))))
    when 'event_occurred' then exists (
      select 1 from lead_events where lead_id = p_lead_id
        and event_type = p_value and created_at >= p_run_started)
    when 'stage_is'   then l.pipeline_stage = p_value
    when 'segment_is' then l.marketing_segment = p_value
    when 'heat_gte'   then coalesce(l.engagement_score, 0) >= coalesce(nullif(p_value,'')::int, 0)
    else false
  end;
end;
$$;


ALTER FUNCTION "public"."eval_run_condition"("p_lead_id" "uuid", "p_run_started" timestamp with time zone, "p_kind" "text", "p_value" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."flow_next_node"("p_flow" "jsonb", "p_node_id" "text", "p_handle" "text" DEFAULT NULL::"text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select e->>'target'
    from jsonb_array_elements(p_flow->'edges') e
   where e->>'source' = p_node_id
     and (
       (p_handle is null and (e->>'sourceHandle' is null or e->>'sourceHandle' = ''))
       or (p_handle is not null and e->>'sourceHandle' = p_handle)
     )
   limit 1;
$$;


ALTER FUNCTION "public"."flow_next_node"("p_flow" "jsonb", "p_node_id" "text", "p_handle" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."flow_node"("p_flow" "jsonb", "p_node_id" "text") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select n from jsonb_array_elements(p_flow->'nodes') n where n->>'id' = p_node_id limit 1;
$$;


ALTER FUNCTION "public"."flow_node"("p_flow" "jsonb", "p_node_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sequence_steps"("p_sequence_name" "text") RETURNS TABLE("step_number" integer, "action" "text", "channel" "text", "wait_hours" integer, "template_key" "text", "description" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  SELECT * FROM (VALUES
    -- SUPER_HOT: WhatsApp personal → follow-up → email → manual
    (0, 'send_message', 'whatsapp', 48, 'super_hot_intro_wa', 'WA intro personal'),
    (1, 'send_message', 'whatsapp', 72, 'super_hot_followup_wa', 'WA follow-up si no responde'),
    (2, 'send_message', 'email', 120, 'super_hot_email', 'Email como último recurso'),
    (3, 'mark_review', 'none', 0, NULL, 'Marcar para revisión manual'),

    -- HOT: Email personalizado → WA → email follow-up → manual
    (10, 'send_message', 'email', 72, 'hot_intro_email', 'Email personalizado intro'),
    (11, 'send_message', 'whatsapp', 72, 'hot_followup_wa', 'WA si no abrió email'),
    (12, 'send_message', 'email', 120, 'hot_followup_email', 'Email follow-up'),
    (13, 'mark_review', 'none', 0, NULL, 'Marcar para revisión manual'),

    -- WARM: Email reactivación → segundo email → WA condicional → fin
    (20, 'send_message', 'email', 120, 'warm_reactivation_1', 'Email reactivación #1'),
    (21, 'send_message', 'email', 168, 'warm_reactivation_2', 'Email reactivación #2'),
    (22, 'send_message', 'whatsapp', 120, 'warm_wa_if_opened', 'WA solo si abrió algún email'),
    (23, 'mark_exhausted', 'none', 0, NULL, 'Secuencia agotada'),

    -- COLD: Email frío → segundo email → fin
    (30, 'send_message', 'email', 168, 'cold_intro_email', 'Email frío intro'),
    (31, 'send_message', 'email', 240, 'cold_followup_email', 'Email frío follow-up'),
    (32, 'mark_exhausted', 'none', 0, NULL, 'Secuencia agotada')
  ) AS t(step_number, action, channel, wait_hours, template_key, description)
  WHERE 
    CASE p_sequence_name
      WHEN 'super_hot_wa' THEN t.step_number BETWEEN 0 AND 3
      WHEN 'hot_email_wa' THEN t.step_number BETWEEN 10 AND 13
      WHEN 'warm_reactivation' THEN t.step_number BETWEEN 20 AND 23
      WHEN 'cold_prospection' THEN t.step_number BETWEEN 30 AND 32
    END
  ORDER BY t.step_number;
END;
$$;


ALTER FUNCTION "public"."get_sequence_steps"("p_sequence_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."inbox_threads"("p_limit" integer DEFAULT 50) RETURNS TABLE("lead_id" "uuid", "full_name" "text", "phone" "text", "email" "text", "marketing_segment" "text", "pipeline_stage" "text", "engagement_score" integer, "agent_paused" boolean, "last_inbound_at" timestamp with time zone, "last_inbound_text" "text", "last_inbound_channel" "text", "last_outbound_at" timestamp with time zone, "unread" boolean)
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
    (i.created_at > coalesce(l.inbox_read_at, 'epoch'::timestamptz)) as unread
  from inbound i
  join leads_master l on l.id = i.lead_id
  left join outbound o on o.lead_id = i.lead_id
  order by i.created_at desc
  limit p_limit;
$$;


ALTER FUNCTION "public"."inbox_threads"("p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."inbox_unread_count"() RETURNS integer
    LANGUAGE "sql" STABLE
    AS $$
  select count(distinct e.lead_id)::int
  from lead_events e
  join leads_master l on l.id = e.lead_id
  where e.event_type in ('wa_reply', 'email_replied')
    and e.created_at > coalesce(l.inbox_read_at, 'epoch'::timestamptz);
$$;


ALTER FUNCTION "public"."inbox_unread_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."lead_event_weight"("p_event_type" "text") RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case p_event_type
    when 'email_opened'             then 1
    when 'wa_read'                  then 1
    when 'email_clicked'            then 3
    when 'cta_clicked'              then 5
    when 'result_viewed'            then 3
    when 'discovery_form_submitted' then 8
    when 'contact_submitted'        then 8
    when 'email_replied'            then 10
    when 'wa_reply'                 then 10
    when 'demo_created'             then 10
    when 'converted'                then 15
    else 0
  end;
$$;


ALTER FUNCTION "public"."lead_event_weight"("p_event_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."lead_filter_options"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  select jsonb_build_object(
    'sources', (
      select coalesce(jsonb_agg(jsonb_build_object('value', source, 'count', cnt) order by cnt desc), '[]'::jsonb)
        from (select source, count(*) as cnt from leads_master where source is not null group by source) s
    ),
    'cities', (
      select coalesce(jsonb_agg(jsonb_build_object('value', city, 'count', cnt) order by cnt desc), '[]'::jsonb)
        from (select city, count(*) as cnt from leads_master where city is not null group by city order by count(*) desc limit 40) c
    ),
    'specializations', (
      select coalesce(jsonb_agg(jsonb_build_object('value', specialization, 'count', cnt) order by cnt desc), '[]'::jsonb)
        from (select specialization, count(*) as cnt from leads_master where specialization is not null group by specialization order by count(*) desc limit 40) sp
    )
  );
$$;


ALTER FUNCTION "public"."lead_filter_options"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."lead_quality_summary"() RETURNS TABLE("total" bigint, "sin_email" bigint, "sin_telefono" bigint, "telefono_invalido" bigint, "sin_nombre" bigint, "email_duplicado" bigint, "telefono_duplicado" bigint)
    LANGUAGE "sql" STABLE
    AS $_$
  with base as (
    select id, email, email_normalized, phone, full_name,
           (phone is not null and phone !~ '^\+[1-9][0-9]{7,14}$') as bad_phone
    from leads_master
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
$_$;


ALTER FUNCTION "public"."lead_quality_summary"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."leads_master" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text",
    "email_normalized" "text",
    "phone" "text",
    "full_name" "text",
    "city" "text",
    "country" "text",
    "source" "text",
    "is_todoc" boolean DEFAULT false,
    "is_colombia" boolean DEFAULT false,
    "total_citas" integer,
    "ultima_cita" timestamp with time zone,
    "pagando_hoy" boolean,
    "opened_email" boolean,
    "clicked_email" boolean,
    "hard_bounce" boolean,
    "growth_segment" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "email_secondary" "text",
    "phone_e164_2" "text",
    "department" "text",
    "address" "text",
    "todoc_user_id" bigint,
    "alguna_vez_pago" boolean,
    "total_sedes" integer,
    "total_pacientes" integer,
    "recovery_score" integer,
    "segmento_growth" "text",
    "unsubscribed_email" boolean DEFAULT false,
    "marketing_segment" "text",
    "specialization" "text",
    "can_email" boolean DEFAULT false,
    "can_whatsapp" boolean DEFAULT false,
    "last_contacted_at" timestamp with time zone,
    "last_channel_touched" "text",
    "next_best_action" "text",
    "whatsapp_opted_in" boolean DEFAULT false,
    "workspace_id" "uuid",
    "pipeline_stage" "text" DEFAULT 'new'::"text",
    "owner_id" "uuid",
    "referred_by_name" "text",
    "referred_by_phone" "text",
    "referral_campaign" "text",
    "appril_referral_id" "uuid",
    "engagement_score" integer DEFAULT 0 NOT NULL,
    "last_engaged_at" timestamp with time zone,
    "inbox_read_at" timestamp with time zone,
    "agent_paused" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."leads_master" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."lead_var_value"("p_lead" "public"."leads_master", "p_var" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case p_var
    when 'nombre'          then coalesce(nullif(split_part(p_lead.full_name, ' ', 1), ''), 'Doctor(a)')
    when 'nombre_completo' then coalesce(p_lead.full_name, 'Doctor(a)')
    when 'full_name'       then coalesce(p_lead.full_name, 'Doctor(a)')
    when 'email'           then coalesce(p_lead.email, '')
    when 'ciudad'          then coalesce(p_lead.city, '')
    when 'city'            then coalesce(p_lead.city, '')
    when 'especialidad'    then coalesce(p_lead.specialization, '')
    else ''
  end;
$$;


ALTER FUNCTION "public"."lead_var_value"("p_lead" "public"."leads_master", "p_var" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."leads_needing_reply"("p_limit" integer DEFAULT 10) RETURNS TABLE("lead_id" "uuid", "full_name" "text", "email" "text", "phone" "text", "marketing_segment" "text", "pipeline_stage" "text", "engagement_score" integer, "replied_at" timestamp with time zone, "reply_value" "text", "reply_channel" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  with last_reply as (
    select distinct on (le.lead_id) le.lead_id, le.created_at, le.event_value, le.event_channel
      from lead_events le
     where le.event_type in ('wa_reply','email_replied','contact_submitted','discovery_form_submitted')
     order by le.lead_id, le.created_at desc
  ),
  last_out as (
    select distinct on (le.lead_id) le.lead_id, le.created_at
      from lead_events le
     where le.event_type in ('message_sent','wa_agent_reply')
     order by le.lead_id, le.created_at desc
  )
  select l.id, l.full_name, l.email, l.phone, l.marketing_segment, l.pipeline_stage,
         l.engagement_score, r.created_at, r.event_value, r.event_channel
    from last_reply r
    join leads_master l on l.id = r.lead_id
    left join last_out o on o.lead_id = r.lead_id
   where (o.created_at is null or r.created_at > o.created_at)
     and coalesce(l.pipeline_stage, 'new') not in ('converted','lost')
   order by r.created_at desc
   limit p_limit;
$$;


ALTER FUNCTION "public"."leads_needing_reply"("p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."lists_overview"() RETURNS TABLE("id" "uuid", "name" "text", "description" "text", "source_type" "text", "created_at" timestamp with time zone, "members" bigint)
    LANGUAGE "sql" STABLE
    AS $$
  select l.id, l.name, l.description, l.source_type, l.created_at, count(m.lead_id)
  from lead_lists l
  left join lead_list_members m on m.list_id = l.id
  group by l.id
  order by l.created_at desc;
$$;


ALTER FUNCTION "public"."lists_overview"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_email"("input" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select nullif(
    lower(
      regexp_replace(
        trim(coalesce(input, '')),
        '\s+',
        '',
        'g'
      )
    ),
    ''
  );
$$;


ALTER FUNCTION "public"."normalize_email"("input" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_name"("input" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select nullif(
    lower(
      regexp_replace(
        trim(coalesce(input, '')),
        '\s+',
        ' ',
        'g'
      )
    ),
    ''
  );
$$;


ALTER FUNCTION "public"."normalize_name"("input" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recalculate_segments"() RETURNS TABLE("updated_count" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_count integer := 0;
  v_partial integer;
BEGIN
  -- 1. DO_NOT_EMAIL
  UPDATE leads_master SET marketing_segment = 'DO_NOT_EMAIL', can_email = false
  WHERE (hard_bounce = true OR unsubscribed_email = true)
    AND marketing_segment != 'DO_NOT_EMAIL';
  GET DIAGNOSTICS v_partial = ROW_COUNT; v_count := v_count + v_partial;

  -- 2. SUPER_HOT
  UPDATE leads_master SET marketing_segment = 'SUPER_HOT'
  WHERE marketing_segment NOT IN ('DO_NOT_EMAIL')
    AND (clicked_email = true OR (pagando_hoy = true AND total_pacientes > 100))
    AND marketing_segment != 'SUPER_HOT';
  GET DIAGNOSTICS v_partial = ROW_COUNT; v_count := v_count + v_partial;

  -- 3. HOT
  UPDATE leads_master SET marketing_segment = 'HOT'
  WHERE marketing_segment NOT IN ('DO_NOT_EMAIL', 'SUPER_HOT')
    AND (
      pagando_hoy = true
      OR (alguna_vez_pago = true AND total_pacientes > 50)
      OR (alguna_vez_pago = true AND total_sedes >= 2)
      OR recovery_score >= 10
      OR segmento_growth IN (
        'Recuperar primero - grande y ex pagador',
        'Recuperar primero - ex pagador',
        'Recuperar primero - grande con churn',
        'Upsell - activo reciente',
        'Prevenir churn - en riesgo'
      )
    )
    AND marketing_segment != 'HOT';
  GET DIAGNOSTICS v_partial = ROW_COUNT; v_count := v_count + v_partial;

  -- 4. WARM
  UPDATE leads_master SET marketing_segment = 'WARM'
  WHERE marketing_segment NOT IN ('DO_NOT_EMAIL', 'SUPER_HOT', 'HOT')
    AND (
      (opened_email = true AND clicked_email = false)
      OR segmento_growth IN ('Recuperar - historico valioso', 'Recuperacion - churn reciente', 'Recuperacion - churn antiguo')
      OR alguna_vez_pago = true
      OR (is_todoc = true AND total_pacientes > 20)
      OR (is_todoc = true AND total_citas > 50)
    )
    AND marketing_segment != 'WARM';
  GET DIAGNOSTICS v_partial = ROW_COUNT; v_count := v_count + v_partial;

  -- 5. Todo lo demás → COLD
  UPDATE leads_master SET marketing_segment = 'COLD'
  WHERE marketing_segment NOT IN ('DO_NOT_EMAIL', 'SUPER_HOT', 'HOT', 'WARM')
    OR marketing_segment IS NULL;
  GET DIAGNOSTICS v_partial = ROW_COUNT; v_count := v_count + v_partial;

  -- 6. Actualizar updated_at
  UPDATE leads_master SET updated_at = now() WHERE updated_at < now() - interval '1 day';

  RETURN QUERY SELECT v_count;
END;
$$;


ALTER FUNCTION "public"."recalculate_segments"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."report_activity_daily"("p_days" integer DEFAULT 14) RETURNS TABLE("day" "date", "outbound" bigint, "inbound" bigint, "engagement" bigint)
    LANGUAGE "sql" STABLE
    AS $$
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
  left join lead_events e on e.created_at::date = d.day::date
  group by d.day
  order by d.day;
$$;


ALTER FUNCTION "public"."report_activity_daily"("p_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."report_channel_stats"("p_days" integer DEFAULT 30) RETURNS TABLE("channel" "text", "sent" bigint, "delivered" bigint, "opened" bigint, "clicked" bigint, "replied" bigint, "failed" bigint)
    LANGUAGE "sql" STABLE
    AS $$
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
  group by 1
  order by 1;
$$;


ALTER FUNCTION "public"."report_channel_stats"("p_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."report_funnel"() RETURNS TABLE("stage_key" "text", "stage_label" "text", "stage_color" "text", "sort_order" integer, "leads" bigint)
    LANGUAGE "sql" STABLE
    AS $$
  select ps.key, ps.label, ps.color, ps.position, count(l.id)
  from pipeline_stages ps
  left join leads_master l on l.pipeline_stage = ps.key
  group by ps.key, ps.label, ps.color, ps.position
  order by ps.position;
$$;


ALTER FUNCTION "public"."report_funnel"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."stage_for_event"("p_event_type" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    -- nos comunicamos con el lead
    when p_event_type in ('message_sent','wa_sent','email_delivered') then 'contacted'
    -- el lead mostró interés
    when p_event_type in ('email_opened','email_clicked','cta_clicked','result_viewed','wa_read') then 'engaged'
    -- el lead levantó la mano
    when p_event_type in ('wa_reply','email_replied','contact_submitted','discovery_form_submitted','demo_created') then 'qualified'
    -- conversión explícita de negocio
    when p_event_type in ('converted','subscription_started','payment_confirmed') then 'converted'
    else null
  end;
$$;


ALTER FUNCTION "public"."stage_for_event"("p_event_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_discovery_lead"("input" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
  v_workspace_id  CONSTANT uuid := 'e2096477-fa6a-4b8f-a8b3-bd46ad720167';
  v_score_result  jsonb;
  v_discovery_id  uuid;
  v_lead_id       uuid;
  v_queue_id      uuid;
  v_template_key  text;

  v_full_name     text := trim(input->>'name');
  v_whatsapp      text := trim(input->>'whatsapp_e164');
  v_email         text := nullif(trim(input->>'email'), '');
  v_city          text := nullif(trim(input->>'city'), '');
  v_clinic        text := nullif(trim(input->>'clinic_name'), '');
  v_country       text := COALESCE(nullif(trim(input->>'phone_country_iso2'),''), 'CO');
  v_consent       boolean := COALESCE((input->>'consent')::boolean, false);

  v_q_volume      text := input->>'monthly_appointments_range';
  v_q_lost        text := input->>'lost_appointments_range';
  v_q_intent      text := input->>'desired_next_step';
  v_q_urgency     text;
  v_q_ticket      text := input->>'average_ticket_range';
  v_q_digital     text := input->>'scheduling_method';

  v_fe            jsonb := COALESCE(input->'frontend_calculations', '{}'::jsonb);
  v_findings      jsonb := COALESCE(input->'findings', '{}'::jsonb);
  v_maturity      text;
  v_annual_lost   numeric;
  v_hidden_cost   numeric;
  v_segment       text;
BEGIN
  IF v_full_name IS NULL OR v_full_name = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Nombre requerido');
  END IF;
  IF v_whatsapp IS NULL OR v_whatsapp !~ '^\+[1-9][0-9]{7,14}$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Teléfono inválido. Formato E.164 requerido (+573001234567)');
  END IF;
  IF NOT v_consent THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Consentimiento requerido');
  END IF;

  v_q_urgency := CASE
    WHEN (input->>'urgency') LIKE 'media%' THEN 'media'
    ELSE COALESCE(input->>'urgency', 'baja')
  END;

  v_maturity    := COALESCE(v_findings->>'agenda_maturity_level', v_fe->>'agenda_maturity_level');
  v_annual_lost := (COALESCE(v_findings->>'annual_lost_revenue', v_fe->>'annual_lost_revenue'))::numeric;
  v_hidden_cost := (COALESCE(v_findings->>'hidden_cost_total',   v_fe->>'hidden_cost_total'))::numeric;

  v_score_result := public.calculate_discovery_score(
    v_q_volume, v_q_lost, v_q_intent, v_q_urgency, v_q_ticket, v_q_digital
  );

  v_segment := v_score_result->>'segment';

  SELECT id INTO v_lead_id
  FROM public.leads_master
  WHERE workspace_id = v_workspace_id AND phone = v_whatsapp
  LIMIT 1;

  IF v_lead_id IS NULL THEN
    INSERT INTO public.leads_master (
      workspace_id, full_name, phone, email, specialization, city, country,
      marketing_segment, recovery_score, can_whatsapp, can_email,
      pipeline_stage, source, referral_campaign, whatsapp_opted_in
    ) VALUES (
      v_workspace_id,
      v_full_name,
      v_whatsapp,
      v_email,
      nullif(trim(input->>'specialty'), ''),
      v_city,
      v_country,
      v_segment,
      (v_score_result->>'score')::integer,
      true,
      v_email IS NOT NULL,
      'new',
      'discovery_form',
      COALESCE(input->>'utm_campaign', 'discovery_form'),
      true
    )
    RETURNING id INTO v_lead_id;
  ELSE
    UPDATE public.leads_master SET
      full_name          = v_full_name,
      email              = COALESCE(v_email, email),
      city               = COALESCE(v_city, city),
      recovery_score     = GREATEST(recovery_score, (v_score_result->>'score')::integer),
      marketing_segment  = CASE
        WHEN ARRAY_POSITION(ARRAY['COLD','WARM','HOT','SUPER_HOT']::text[], v_segment)
           > ARRAY_POSITION(ARRAY['COLD','WARM','HOT','SUPER_HOT']::text[], marketing_segment)
        THEN v_segment
        ELSE marketing_segment END,
      can_whatsapp       = true,
      whatsapp_opted_in  = true,
      updated_at         = now()
    WHERE id = v_lead_id;
  END IF;

  INSERT INTO public.discovery_leads (
    workspace_id,         lead_id,
    full_name,            whatsapp_e164,         email,
    city,                 country,               clinic_name,
    consent,              preferred_contact_channel,
    q_volume,             q_lost,                q_intent,
    q_urgency,            q_ticket,              q_digital,
    monthly_appointments_range, scheduling_method,
    average_ticket_range, lost_appointments_range,
    urgency,              desired_next_step,
    raw_answers,
    score,                marketing_segment,     score_breakdown,
    lead_classification,  calculation_version,
    agenda_maturity_level, annual_lost_revenue,  hidden_cost_total,
    findings,             frontend_calculations,
    completion_rate,      started_at,
    utm_source,           utm_medium,            utm_campaign,
    utm_content,          utm_term,              landing_url
  ) VALUES (
    v_workspace_id,       v_lead_id,
    v_full_name,          v_whatsapp,            v_email,
    v_city,               v_country,             v_clinic,
    v_consent,            'whatsapp',
    v_q_volume,           v_q_lost,              v_q_intent,
    v_q_urgency,          v_q_ticket,            v_q_digital,
    v_q_volume,           v_q_digital,
    v_q_ticket,           v_q_lost,
    v_q_urgency,          v_q_intent,
    COALESCE(input->'raw_answers', input->'raw_payload', '{}'::jsonb),
    (v_score_result->>'score')::integer,
    v_segment,
    v_score_result->'breakdown',
    v_score_result->>'lead_classification',
    'v2',
    v_maturity,           v_annual_lost,         v_hidden_cost,
    v_findings,           v_fe,
    (input->>'completion_rate')::numeric,
    (input->>'started_at')::timestamptz,
    input->>'utm_source',  input->>'utm_medium',  input->>'utm_campaign',
    input->>'utm_content', input->>'utm_term',
    COALESCE(input->>'page_url', 'https://discovery.appril.co')
  )
  RETURNING id INTO v_discovery_id;

  INSERT INTO public.lead_events (workspace_id, lead_id, event_type, event_channel, metadata)
  VALUES (
    v_workspace_id, v_lead_id,
    'discovery_form_submitted', 'funnel',
    jsonb_build_object(
      'discovery_lead_id', v_discovery_id,
      'score',             v_score_result->>'score',
      'segment',           v_segment,
      'classification',    v_score_result->>'lead_classification',
      'maturity',          v_maturity,
      'utm_campaign',      input->>'utm_campaign',
      'utm_source',        input->>'utm_source'
    )
  );

  -- Elegir template WA según segmento
  v_template_key := CASE v_segment
    WHEN 'SUPER_HOT' THEN 'super_hot_intro_wa'
    WHEN 'HOT'       THEN 'hot_followup_wa'
    ELSE                  'warm_wa_if_opened'   -- WARM y COLD: misma plantilla
  END;

  -- Encolar mensaje WA (inmediato, scheduled_at = now())
  INSERT INTO public.message_queue (
    workspace_id, lead_id, template_key, channel,
    to_address, payload, status, scheduled_at
  ) VALUES (
    v_workspace_id,
    v_lead_id,
    v_template_key,
    'whatsapp',
    v_whatsapp,
    jsonb_build_object('full_name', split_part(v_full_name, ' ', 1)),
    'pending',
    now()
  )
  RETURNING id INTO v_queue_id;

  INSERT INTO public.lead_events (workspace_id, lead_id, event_type, event_channel, metadata)
  VALUES (
    v_workspace_id, v_lead_id,
    'message_queued', 'whatsapp',
    jsonb_build_object(
      'message_queue_id', v_queue_id,
      'template_key',     v_template_key,
      'discovery_lead_id', v_discovery_id
    )
  );

  RETURN jsonb_build_object(
    'ok',                  true,
    'discovery_lead_id',   v_discovery_id,
    'lead_id',             v_lead_id,
    'lead_score',          (v_score_result->>'score')::integer,
    'lead_classification', v_score_result->>'lead_classification',
    'marketing_segment',   v_segment,
    'agenda_maturity_level', v_maturity,
    'recommended_action',  v_score_result->>'recommended_action',
    'annual_lost_revenue', v_annual_lost,
    'annual_admin_hours',  (v_fe->>'annual_admin_hours')::numeric,
    'admin_cost_annual',   (v_fe->>'admin_cost_annual')::numeric,
    'hidden_cost_total',   v_hidden_cost,
    'queued_message_id',   v_queue_id,
    'template_key',        v_template_key,
    'scheduled_at',        now()
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$_$;


ALTER FUNCTION "public"."submit_discovery_lead"("input" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_discovery_lead"("p_workspace_slug" "text", "p_full_name" "text", "p_whatsapp_e164" "text", "p_email" "text" DEFAULT NULL::"text", "p_specialization" "text" DEFAULT NULL::"text", "p_city" "text" DEFAULT NULL::"text", "p_country" "text" DEFAULT 'CO'::"text", "p_q_volume" "text" DEFAULT NULL::"text", "p_q_lost" "text" DEFAULT NULL::"text", "p_q_intent" "text" DEFAULT NULL::"text", "p_q_urgency" "text" DEFAULT NULL::"text", "p_q_ticket" "text" DEFAULT NULL::"text", "p_q_digital" "text" DEFAULT NULL::"text", "p_utm_source" "text" DEFAULT NULL::"text", "p_utm_medium" "text" DEFAULT NULL::"text", "p_utm_campaign" "text" DEFAULT NULL::"text", "p_utm_content" "text" DEFAULT NULL::"text", "p_utm_term" "text" DEFAULT NULL::"text", "p_landing_url" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
DECLARE
  v_workspace_id uuid;
  v_score_result jsonb;
  v_discovery_id uuid;
  v_lead_id      uuid;
  v_segment_rank integer[];
BEGIN
  -- Validate phone
  IF p_whatsapp_e164 !~ '^\+[1-9][0-9]{7,14}$' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Teléfono inválido. Debe ser E.164, ej: +573001234567');
  END IF;

  -- Get workspace
  SELECT id INTO v_workspace_id FROM public.workspaces WHERE slug = p_workspace_slug;
  IF v_workspace_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Workspace no encontrado');
  END IF;

  -- Calculate score
  v_score_result := public.calculate_discovery_score(
    p_q_volume, p_q_lost, p_q_intent, p_q_urgency, p_q_ticket, p_q_digital
  );

  -- Find existing lead by phone in this workspace
  SELECT id INTO v_lead_id
  FROM public.leads_master
  WHERE workspace_id = v_workspace_id AND phone = p_whatsapp_e164
  LIMIT 1;

  IF v_lead_id IS NULL THEN
    -- New lead
    INSERT INTO public.leads_master (
      workspace_id, full_name, phone, email, specialization, city, country,
      marketing_segment, recovery_score, can_whatsapp, can_email,
      pipeline_stage, source, referral_campaign, whatsapp_opted_in
    ) VALUES (
      v_workspace_id,
      p_full_name,
      p_whatsapp_e164,
      p_email,
      p_specialization,
      p_city,
      COALESCE(p_country, 'CO'),
      v_score_result->>'segment',
      (v_score_result->>'score')::integer,
      true,
      p_email IS NOT NULL,
      'new',
      'discovery_form',
      p_utm_campaign,
      true
    )
    RETURNING id INTO v_lead_id;
  ELSE
    -- Existing lead: update but never downgrade segment
    UPDATE public.leads_master SET
      full_name         = p_full_name,
      email             = COALESCE(p_email, email),
      specialization    = COALESCE(p_specialization, specialization),
      city              = COALESCE(p_city, city),
      recovery_score    = GREATEST(recovery_score, (v_score_result->>'score')::integer),
      -- No-downgrade: only upgrade segment (COLD < WARM < HOT < SUPER_HOT)
      marketing_segment = CASE
        WHEN ARRAY_POSITION(ARRAY['COLD','WARM','HOT','SUPER_HOT']::text[], v_score_result->>'segment')
           > ARRAY_POSITION(ARRAY['COLD','WARM','HOT','SUPER_HOT']::text[], marketing_segment)
        THEN v_score_result->>'segment'
        ELSE marketing_segment
      END,
      can_whatsapp      = true,
      whatsapp_opted_in = true,
      updated_at        = now()
    WHERE id = v_lead_id;
  END IF;

  -- Insert discovery_leads record
  INSERT INTO public.discovery_leads (
    workspace_id, lead_id,
    full_name, whatsapp_e164, email, specialization, city, country,
    q_volume, q_lost, q_intent, q_urgency, q_ticket, q_digital,
    raw_answers,
    score, marketing_segment, score_breakdown, calculation_version,
    utm_source, utm_medium, utm_campaign, utm_content, utm_term, landing_url
  ) VALUES (
    v_workspace_id, v_lead_id,
    p_full_name, p_whatsapp_e164, p_email, p_specialization, p_city, COALESCE(p_country,'CO'),
    p_q_volume, p_q_lost, p_q_intent, p_q_urgency, p_q_ticket, p_q_digital,
    jsonb_build_object(
      'q_volume', p_q_volume, 'q_lost', p_q_lost, 'q_intent', p_q_intent,
      'q_urgency', p_q_urgency, 'q_ticket', p_q_ticket, 'q_digital', p_q_digital
    ),
    (v_score_result->>'score')::integer,
    v_score_result->>'segment',
    v_score_result->'breakdown',
    'v1',
    p_utm_source, p_utm_medium, p_utm_campaign, p_utm_content, p_utm_term, p_landing_url
  )
  RETURNING id INTO v_discovery_id;

  -- Log in lead_events
  INSERT INTO public.lead_events (workspace_id, lead_id, event_type, event_channel, metadata)
  VALUES (
    v_workspace_id, v_lead_id,
    'discovery_form_submitted',
    'web',
    jsonb_build_object(
      'discovery_lead_id', v_discovery_id,
      'score',          v_score_result->>'score',
      'segment',        v_score_result->>'segment',
      'utm_campaign',   p_utm_campaign,
      'utm_source',     p_utm_source
    )
  );

  RETURN jsonb_build_object(
    'success',           true,
    'discovery_lead_id', v_discovery_id,
    'lead_id',           v_lead_id,
    'score',             (v_score_result->>'score')::integer,
    'segment',           v_score_result->>'segment',
    'breakdown',         v_score_result->'breakdown'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$_$;


ALTER FUNCTION "public"."submit_discovery_lead"("p_workspace_slug" "text", "p_full_name" "text", "p_whatsapp_e164" "text", "p_email" "text", "p_specialization" "text", "p_city" "text", "p_country" "text", "p_q_volume" "text", "p_q_lost" "text", "p_q_intent" "text", "p_q_urgency" "text", "p_q_ticket" "text", "p_q_digital" "text", "p_utm_source" "text", "p_utm_medium" "text", "p_utm_campaign" "text", "p_utm_content" "text", "p_utm_term" "text", "p_landing_url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."template_usage"() RETURNS TABLE("template_key" "text", "total" bigint, "sent" bigint, "failed" bigint, "last_used_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  select mq.template_key,
         count(*) as total,
         count(*) filter (where mq.status = 'sent') as sent,
         count(*) filter (where mq.status = 'failed') as failed,
         max(mq.created_at) as last_used_at
    from message_queue mq
   group by mq.template_key;
$$;


ALTER FUNCTION "public"."template_usage"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


ALTER FUNCTION "public"."touch_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."track_discovery_event"("input" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_workspace_id      CONSTANT uuid := 'e2096477-fa6a-4b8f-a8b3-bd46ad720167';
  v_event_name        text := input->>'event_name';
  v_anon_session      text := trim(input->>'anonymous_session_id');
  v_discovery_lead_id uuid := (input->>'discovery_lead_id')::uuid;
  v_lead_id           uuid := (input->>'lead_id')::uuid;
  v_discovery_event_id uuid;
  v_lead_event_id      uuid;

  v_allowed text[] := ARRAY[
    'discovery_page_view','discovery_started',
    'question_viewed','question_answered',
    'gift_viewed','section_completed',
    'contact_form_viewed','contact_submitted',
    'result_viewed','cta_clicked',
    'discovery_abandoned','discovery_pdf_generated',
    'discovery_message_queued','discovery_queue_skipped'
  ];
  v_crm_events text[] := ARRAY[
    'contact_submitted','result_viewed','cta_clicked',
    'discovery_abandoned','discovery_pdf_generated',
    'discovery_message_queued','discovery_queue_skipped'
  ];
BEGIN
  IF v_event_name IS NULL OR NOT (v_event_name = ANY(v_allowed)) THEN
    RETURN jsonb_build_object('ok',false,'error',
      format('event_name inválido: "%s"', COALESCE(v_event_name,'null')));
  END IF;
  IF v_anon_session IS NULL OR v_anon_session = '' THEN
    RETURN jsonb_build_object('ok',false,'error','anonymous_session_id requerido');
  END IF;

  INSERT INTO public.discovery_events (
    workspace_id, anonymous_session_id, discovery_lead_id, lead_id, event_name,
    section, section_index, step_key, step_index, question_key,
    answer_value, answer_label, cta_key, cta_label, progress_percent,
    time_on_step_ms, elapsed_ms, metadata,
    utm_source, utm_medium, utm_campaign, utm_content, utm_term,
    device_type, landing_variant
  ) VALUES (
    v_workspace_id, v_anon_session, v_discovery_lead_id, v_lead_id, v_event_name,
    input->>'section',          (input->>'section_index')::integer,
    input->>'step_key',         (input->>'step_index')::integer,
    input->>'question_key',
    input->>'answer_value',     input->>'answer_label',
    input->>'cta_key',          input->>'cta_label',
    (input->>'progress_percent')::numeric,
    (input->>'time_on_step_ms')::integer,
    (input->>'elapsed_ms')::integer,
    COALESCE(input->'metadata', '{}'::jsonb),
    input->>'utm_source',  input->>'utm_medium',  input->>'utm_campaign',
    input->>'utm_content', input->>'utm_term',
    input->>'device_type', input->>'landing_variant'
  )
  RETURNING id INTO v_discovery_event_id;

  IF v_lead_id IS NOT NULL AND v_event_name = ANY(v_crm_events) THEN
    INSERT INTO public.lead_events (
      workspace_id, lead_id, event_type, event_channel, event_value, metadata
    ) VALUES (
      v_workspace_id, v_lead_id, v_event_name, 'funnel',
      COALESCE(input->>'cta_key', input->>'lead_classification', input->>'step_key'),
      jsonb_build_object(
        'discovery_event_id',   v_discovery_event_id,
        'anonymous_session_id', v_anon_session,
        'discovery_lead_id',    v_discovery_lead_id,
        'score',                input->>'lead_score',
        'segment',              input->>'marketing_segment',
        'cta_key',              input->>'cta_key',
        'progress_percent',     input->>'progress_percent',
        'utm_campaign',         input->>'utm_campaign',
        'utm_source',           input->>'utm_source'
      )
    )
    RETURNING id INTO v_lead_event_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',true,
    'discovery_event_id', v_discovery_event_id,
    'lead_event_id',      v_lead_event_id
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok',false,'error',SQLERRM);
END;
$$;


ALTER FUNCTION "public"."track_discovery_event"("input" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."automation_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "automation_id" "uuid" NOT NULL,
    "lead_id" "uuid" NOT NULL,
    "current_step" integer DEFAULT 0,
    "status" "text" DEFAULT 'active'::"text",
    "exit_reason" "text",
    "next_run_at" timestamp with time zone DEFAULT "now"(),
    "started_at" timestamp with time zone DEFAULT "now"(),
    "finished_at" timestamp with time zone,
    "current_node_id" "text",
    "context" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "goal_met_at" timestamp with time zone,
    CONSTRAINT "automation_runs_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'paused'::"text", 'completed'::"text", 'converted'::"text", 'exited'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."automation_runs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."automations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "trigger_type" "text" NOT NULL,
    "trigger_config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "steps" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "exit_conditions" "jsonb" DEFAULT '{}'::"jsonb",
    "status" "text" DEFAULT 'active'::"text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "flow" "jsonb" DEFAULT '{"edges": [], "nodes": []}'::"jsonb" NOT NULL,
    CONSTRAINT "automations_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'active'::"text", 'paused'::"text", 'archived'::"text"]))),
    CONSTRAINT "automations_trigger_type_check" CHECK (("trigger_type" = ANY (ARRAY['segment_match'::"text", 'event'::"text", 'stage'::"text", 'manual'::"text", 'schedule'::"text"])))
);


ALTER TABLE "public"."automations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."campaigns" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "channel" "text" NOT NULL,
    "segment_filter" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "template_keys" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "status" "text" DEFAULT 'draft'::"text",
    "scheduled_at" timestamp with time zone,
    "started_at" timestamp with time zone,
    "ended_at" timestamp with time zone,
    "stats" "jsonb" DEFAULT '{}'::"jsonb",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "campaigns_channel_check" CHECK (("channel" = ANY (ARRAY['email'::"text", 'whatsapp'::"text", 'multi'::"text"]))),
    CONSTRAINT "campaigns_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'scheduled'::"text", 'running'::"text", 'paused'::"text", 'done'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."campaigns" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."crm_users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "auth_user_id" "uuid",
    "workspace_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "full_name" "text",
    "role" "text" DEFAULT 'admin'::"text",
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "crm_users_role_check" CHECK (("role" = ANY (ARRAY['admin'::"text", 'operator'::"text", 'viewer'::"text"])))
);


ALTER TABLE "public"."crm_users" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."discovery_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "form_title" "text" DEFAULT 'Diagnóstico de Agenda Blindada'::"text" NOT NULL,
    "form_subtitle" "text",
    "brand_color" "text" DEFAULT '#2563eb'::"text" NOT NULL,
    "logo_url" "text",
    "redirect_url" "text",
    "notification_emails" "text"[],
    "wa_template_super_hot" "text",
    "wa_template_hot" "text",
    "wa_template_warm" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."discovery_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."discovery_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "anonymous_session_id" "text" NOT NULL,
    "discovery_lead_id" "uuid",
    "event_name" "text" NOT NULL,
    "step_index" integer,
    "step_key" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "lead_id" "uuid",
    "section" "text",
    "section_index" integer,
    "question_key" "text",
    "answer_value" "text",
    "answer_label" "text",
    "cta_key" "text",
    "cta_label" "text",
    "progress_percent" numeric(5,2),
    "time_on_step_ms" integer,
    "elapsed_ms" integer,
    "utm_source" "text",
    "utm_medium" "text",
    "utm_campaign" "text",
    "utm_content" "text",
    "utm_term" "text",
    "device_type" "text",
    "landing_variant" "text"
);


ALTER TABLE "public"."discovery_events" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."discovery_cta_performance" AS
 WITH "result_views" AS (
         SELECT "discovery_events"."workspace_id",
            "count"(DISTINCT "discovery_events"."anonymous_session_id") AS "sessions_with_result"
           FROM "public"."discovery_events"
          WHERE ("discovery_events"."event_name" = 'result_viewed'::"text")
          GROUP BY "discovery_events"."workspace_id"
        ), "clicks" AS (
         SELECT "discovery_events"."workspace_id",
            "discovery_events"."cta_key",
            "max"("discovery_events"."cta_label") AS "cta_label",
            ("discovery_events"."metadata" ->> 'lead_classification'::"text") AS "lead_classification",
            ("discovery_events"."metadata" ->> 'marketing_segment'::"text") AS "marketing_segment",
            "count"(*) AS "clicks"
           FROM "public"."discovery_events"
          WHERE (("discovery_events"."event_name" = 'cta_clicked'::"text") AND ("discovery_events"."cta_key" IS NOT NULL))
          GROUP BY "discovery_events"."workspace_id", "discovery_events"."cta_key", ("discovery_events"."metadata" ->> 'lead_classification'::"text"), ("discovery_events"."metadata" ->> 'marketing_segment'::"text")
        )
 SELECT "c"."workspace_id",
    "c"."cta_key",
    "c"."cta_label",
    "c"."lead_classification",
    "c"."marketing_segment",
    "rv"."sessions_with_result" AS "views_before_cta",
    "c"."clicks",
    "round"(((("c"."clicks")::numeric / (NULLIF("rv"."sessions_with_result", 0))::numeric) * (100)::numeric), 2) AS "click_rate"
   FROM ("clicks" "c"
     LEFT JOIN "result_views" "rv" USING ("workspace_id"))
  ORDER BY "c"."clicks" DESC;


ALTER VIEW "public"."discovery_cta_performance" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."discovery_funnel_sessions" AS
 SELECT "workspace_id",
    "anonymous_session_id",
    "min"("created_at") AS "first_seen_at",
    "max"("created_at") AS "last_seen_at",
    (EXTRACT(epoch FROM ("max"("created_at") - "min"("created_at"))))::integer AS "elapsed_seconds",
    ("array_agg"("event_name" ORDER BY "created_at" DESC))[1] AS "last_event_name",
    ("array_agg"("step_key" ORDER BY "created_at" DESC) FILTER (WHERE ("step_key" IS NOT NULL)))[1] AS "last_step_key",
    ("array_agg"("section" ORDER BY "created_at" DESC) FILTER (WHERE ("section" IS NOT NULL)))[1] AS "last_section",
    "max"("step_index") AS "max_step_index",
    "count"(*) FILTER (WHERE ("event_name" = 'question_answered'::"text")) AS "answered_questions_count",
    "max"("progress_percent") AS "progress_percent",
    "bool_or"(("event_name" = 'contact_form_viewed'::"text")) AS "saw_contact_form",
    "bool_or"(("event_name" = 'contact_submitted'::"text")) AS "submitted_contact",
    "bool_or"(("event_name" = 'result_viewed'::"text")) AS "saw_result",
    "bool_or"(("event_name" = 'cta_clicked'::"text")) AS "clicked_cta",
    ("array_agg"("discovery_lead_id" ORDER BY "created_at") FILTER (WHERE ("discovery_lead_id" IS NOT NULL)))[1] AS "discovery_lead_id",
    ("array_agg"("lead_id" ORDER BY "created_at") FILTER (WHERE ("lead_id" IS NOT NULL)))[1] AS "lead_id",
    ("array_agg"("utm_source" ORDER BY "created_at") FILTER (WHERE ("utm_source" IS NOT NULL)))[1] AS "utm_source",
    ("array_agg"("utm_medium" ORDER BY "created_at") FILTER (WHERE ("utm_medium" IS NOT NULL)))[1] AS "utm_medium",
    ("array_agg"("utm_campaign" ORDER BY "created_at") FILTER (WHERE ("utm_campaign" IS NOT NULL)))[1] AS "utm_campaign",
    ("array_agg"("device_type" ORDER BY "created_at") FILTER (WHERE ("device_type" IS NOT NULL)))[1] AS "device_type",
    ("array_agg"("landing_variant" ORDER BY "created_at") FILTER (WHERE ("landing_variant" IS NOT NULL)))[1] AS "landing_variant"
   FROM "public"."discovery_events"
  GROUP BY "workspace_id", "anonymous_session_id";


ALTER VIEW "public"."discovery_funnel_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."discovery_leads" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "whatsapp_e164" "text" NOT NULL,
    "email" "text",
    "specialization" "text",
    "city" "text",
    "country" "text" DEFAULT 'CO'::"text" NOT NULL,
    "q_volume" "text",
    "q_lost" "text",
    "q_intent" "text",
    "q_urgency" "text",
    "q_ticket" "text",
    "q_digital" "text",
    "raw_answers" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "score" integer DEFAULT 0 NOT NULL,
    "marketing_segment" "text" DEFAULT 'COLD'::"text" NOT NULL,
    "score_breakdown" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "calculation_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "utm_source" "text",
    "utm_medium" "text",
    "utm_campaign" "text",
    "utm_content" "text",
    "utm_term" "text",
    "landing_url" "text",
    "lead_id" "uuid",
    "status" "text" DEFAULT 'new'::"text" NOT NULL,
    "submission_ip" "inet",
    "user_agent" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "monthly_appointments_range" "text",
    "scheduling_method" "text",
    "average_ticket_range" "text",
    "lost_appointments_range" "text",
    "urgency" "text",
    "desired_next_step" "text",
    "agenda_maturity_level" "text",
    "lead_classification" "text",
    "annual_lost_revenue" numeric(12,2),
    "hidden_cost_total" numeric(12,2),
    "findings" "jsonb",
    "frontend_calculations" "jsonb",
    "consent" boolean DEFAULT false NOT NULL,
    "clinic_name" "text",
    "preferred_contact_channel" "text" DEFAULT 'whatsapp'::"text",
    "completion_rate" numeric(5,4),
    "started_at" timestamp with time zone,
    CONSTRAINT "discovery_leads_marketing_segment_check" CHECK (("marketing_segment" = ANY (ARRAY['SUPER_HOT'::"text", 'HOT'::"text", 'WARM'::"text", 'COLD'::"text"]))),
    CONSTRAINT "discovery_leads_score_check" CHECK ((("score" >= 0) AND ("score" <= 100))),
    CONSTRAINT "discovery_leads_status_check" CHECK (("status" = ANY (ARRAY['new'::"text", 'notified'::"text", 'contacted'::"text", 'qualified'::"text", 'converted'::"text", 'disqualified'::"text"]))),
    CONSTRAINT "discovery_leads_whatsapp_e164_check" CHECK (("whatsapp_e164" ~ '^\+[1-9][0-9]{7,14}$'::"text"))
);


ALTER TABLE "public"."discovery_leads" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."discovery_lead_summary" AS
 SELECT "dl"."id",
    "dl"."workspace_id",
    "dl"."full_name",
    "dl"."whatsapp_e164",
    "dl"."email",
    "dl"."specialization",
    "dl"."city",
    "dl"."score",
    "dl"."marketing_segment",
    "dl"."status",
    "dl"."utm_campaign",
    "dl"."utm_source",
    "dl"."lead_id",
    "lm"."pipeline_stage",
    "lm"."can_whatsapp",
    "lm"."can_email",
    "dl"."score_breakdown",
    "dl"."created_at"
   FROM ("public"."discovery_leads" "dl"
     LEFT JOIN "public"."leads_master" "lm" ON (("lm"."id" = "dl"."lead_id")));


ALTER VIEW "public"."discovery_lead_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."discovery_section_funnel" AS
 WITH "starts" AS (
         SELECT "discovery_events"."workspace_id",
            "discovery_events"."section",
            "discovery_events"."section_index",
            "discovery_events"."anonymous_session_id"
           FROM "public"."discovery_events"
          WHERE (("discovery_events"."event_name" = 'question_viewed'::"text") AND ("discovery_events"."section" IS NOT NULL))
          GROUP BY "discovery_events"."workspace_id", "discovery_events"."section", "discovery_events"."section_index", "discovery_events"."anonymous_session_id"
        ), "completes" AS (
         SELECT "discovery_events"."workspace_id",
            "discovery_events"."section",
            "discovery_events"."anonymous_session_id"
           FROM "public"."discovery_events"
          WHERE (("discovery_events"."event_name" = 'section_completed'::"text") AND ("discovery_events"."section" IS NOT NULL))
          GROUP BY "discovery_events"."workspace_id", "discovery_events"."section", "discovery_events"."anonymous_session_id"
        )
 SELECT "s"."workspace_id",
    "s"."section",
    "max"("s"."section_index") AS "section_index",
    "count"(DISTINCT "s"."anonymous_session_id") AS "sessions_started_section",
    "count"(DISTINCT "c"."anonymous_session_id") AS "sessions_completed_section",
    "round"(((("count"(DISTINCT "c"."anonymous_session_id"))::numeric / (NULLIF("count"(DISTINCT "s"."anonymous_session_id"), 0))::numeric) * (100)::numeric), 2) AS "completion_rate",
    "round"((((1)::numeric - (("count"(DISTINCT "c"."anonymous_session_id"))::numeric / (NULLIF("count"(DISTINCT "s"."anonymous_session_id"), 0))::numeric)) * (100)::numeric), 2) AS "dropoff_rate"
   FROM ("starts" "s"
     LEFT JOIN "completes" "c" ON ((("c"."workspace_id" = "s"."workspace_id") AND ("c"."section" = "s"."section") AND ("c"."anonymous_session_id" = "s"."anonymous_session_id"))))
  GROUP BY "s"."workspace_id", "s"."section"
  ORDER BY ("max"("s"."section_index"));


ALTER VIEW "public"."discovery_section_funnel" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."discovery_step_dropoff" AS
 WITH "step_views" AS (
         SELECT "discovery_events"."workspace_id",
            "discovery_events"."anonymous_session_id",
            "discovery_events"."section",
            "discovery_events"."step_key",
            "discovery_events"."step_index",
            "avg"("discovery_events"."time_on_step_ms") AS "avg_time_ms"
           FROM "public"."discovery_events"
          WHERE (("discovery_events"."event_name" = 'question_viewed'::"text") AND ("discovery_events"."step_key" IS NOT NULL))
          GROUP BY "discovery_events"."workspace_id", "discovery_events"."anonymous_session_id", "discovery_events"."section", "discovery_events"."step_key", "discovery_events"."step_index"
        ), "step_answers" AS (
         SELECT DISTINCT "discovery_events"."workspace_id",
            "discovery_events"."anonymous_session_id",
            "discovery_events"."step_key"
           FROM "public"."discovery_events"
          WHERE (("discovery_events"."event_name" = 'question_answered'::"text") AND ("discovery_events"."step_key" IS NOT NULL))
        ), "next_step" AS (
         SELECT DISTINCT "discovery_events"."workspace_id",
            "discovery_events"."anonymous_session_id",
            ("discovery_events"."step_index" - 1) AS "prev_index"
           FROM "public"."discovery_events"
          WHERE (("discovery_events"."event_name" = 'question_viewed'::"text") AND ("discovery_events"."step_index" IS NOT NULL) AND ("discovery_events"."step_index" > 0))
        )
 SELECT "sv"."workspace_id",
    "sv"."section",
    "sv"."step_key",
    "sv"."step_index",
    "count"(*) AS "viewed_count",
    "count"("sa"."step_key") AS "answered_count",
    "count"("ns"."prev_index") AS "next_step_count",
    ("count"(*) - "count"("ns"."prev_index")) AS "dropoff_count",
    "round"(((("count"("sa"."step_key"))::numeric / (NULLIF("count"(*), 0))::numeric) * (100)::numeric), 2) AS "answer_rate",
    "round"((((("count"(*) - "count"("ns"."prev_index")))::numeric / (NULLIF("count"(*), 0))::numeric) * (100)::numeric), 2) AS "dropoff_rate",
    ("round"("avg"("sv"."avg_time_ms")))::integer AS "avg_time_on_step_ms"
   FROM (("step_views" "sv"
     LEFT JOIN "step_answers" "sa" ON ((("sa"."workspace_id" = "sv"."workspace_id") AND ("sa"."anonymous_session_id" = "sv"."anonymous_session_id") AND ("sa"."step_key" = "sv"."step_key"))))
     LEFT JOIN "next_step" "ns" ON ((("ns"."workspace_id" = "sv"."workspace_id") AND ("ns"."anonymous_session_id" = "sv"."anonymous_session_id") AND ("ns"."prev_index" = "sv"."step_index"))))
  GROUP BY "sv"."workspace_id", "sv"."section", "sv"."step_key", "sv"."step_index"
  ORDER BY "sv"."step_index";


ALTER VIEW "public"."discovery_step_dropoff" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lead_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "lead_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "event_channel" "text",
    "event_value" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "workspace_id" "uuid"
);


ALTER TABLE "public"."lead_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lead_list_members" (
    "list_id" "uuid" NOT NULL,
    "lead_id" "uuid" NOT NULL,
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."lead_list_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lead_lists" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "source_type" "text" DEFAULT 'csv_import'::"text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."lead_lists" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lead_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "lead_id" "uuid" NOT NULL,
    "author_id" "uuid",
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."lead_notes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lead_sequences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "lead_id" "uuid" NOT NULL,
    "sequence_name" "text" NOT NULL,
    "current_step" integer DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "next_action_at" timestamp with time zone,
    "last_action" "text",
    "last_action_at" timestamp with time zone,
    "attempts" integer DEFAULT 0,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "workspace_id" "uuid"
);


ALTER TABLE "public"."lead_sequences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lead_tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "lead_id" "uuid",
    "assigned_to" "uuid",
    "title" "text" NOT NULL,
    "description" "text",
    "due_at" timestamp with time zone,
    "status" "text" DEFAULT 'open'::"text",
    "priority" "text" DEFAULT 'normal'::"text",
    "completed_at" timestamp with time zone,
    "completed_by" "uuid",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "lead_tasks_priority_check" CHECK (("priority" = ANY (ARRAY['low'::"text", 'normal'::"text", 'high'::"text", 'urgent'::"text"]))),
    CONSTRAINT "lead_tasks_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'done'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."lead_tasks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."message_attempts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "message_id" "uuid" NOT NULL,
    "attempt_number" integer NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"(),
    "finished_at" timestamp with time zone,
    "status" "text" NOT NULL,
    "http_status" integer,
    "response_payload" "jsonb",
    "error_code" "text",
    "error_message" "text",
    CONSTRAINT "message_attempts_status_check" CHECK (("status" = ANY (ARRAY['success'::"text", 'error'::"text", 'timeout'::"text", 'rate_limited'::"text"])))
);


ALTER TABLE "public"."message_attempts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."message_queue" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "lead_id" "uuid" NOT NULL,
    "campaign_id" "uuid",
    "automation_run_id" "uuid",
    "template_key" "text" NOT NULL,
    "channel" "text" NOT NULL,
    "to_address" "text" NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb",
    "scheduled_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'pending'::"text",
    "attempts" integer DEFAULT 0,
    "last_error" "text",
    "ses_message_id" "text",
    "wa_message_id" "text",
    "sent_at" timestamp with time zone,
    "triggered_by" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "message_queue_channel_check" CHECK (("channel" = ANY (ARRAY['email'::"text", 'whatsapp'::"text"]))),
    CONSTRAINT "message_queue_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'sending'::"text", 'sent'::"text", 'failed'::"text", 'cancelled'::"text", 'skipped'::"text"])))
);


ALTER TABLE "public"."message_queue" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."message_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "template_key" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "channel" "text" NOT NULL,
    "subject" "text",
    "html_body" "text",
    "text_body" "text",
    "wa_template_name" "text",
    "wa_language" "text" DEFAULT 'es'::"text",
    "wa_components" "jsonb",
    "variables" "jsonb" DEFAULT '[]'::"jsonb",
    "status" "text" DEFAULT 'draft'::"text",
    "version" integer DEFAULT 1,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "message_templates_channel_check" CHECK (("channel" = ANY (ARRAY['email'::"text", 'whatsapp'::"text"]))),
    CONSTRAINT "message_templates_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'active'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."message_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pipeline_stages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "key" "text" NOT NULL,
    "label" "text" NOT NULL,
    "position" integer NOT NULL,
    "color" "text",
    "is_terminal" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."pipeline_stages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."source_brevo_campaign_recipients" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "campaign_id" "text",
    "campaign_name" "text",
    "email" "text",
    "email_normalized" "text",
    "send_date" "text",
    "delivered_date" "text",
    "open_date" "text",
    "total_opens" integer,
    "total_apple_mpp_opens" integer,
    "unsubscribe_date" "text",
    "hard_bounce_date" "text",
    "hard_bounce_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "Campaign ID" "text",
    "Campaign Name" "text",
    "Email_ID" "text",
    "Send_Date" "text",
    "Delivered_Date" "text",
    "Open_Date" "text",
    "Total Opens" "text",
    "Total Apple MPP Opens" "text",
    "Unsubscribe_Date" "text",
    "Hard_Bounce_Date" "text",
    "Hard_Bounce_Reason" "text",
    "Soft_Bounce_Date" "text",
    "Soft_Bounce_Reason" "text",
    "Open_IP" "text",
    "Click_IP" "text",
    "Unsubscribe_IP" "text",
    "Clicked_Links_Count" "text",
    "Complaint_date" "text",
    "https://www.appril.co/" integer,
    "https://www.appril.co/_1" integer,
    "https://apps.apple.com/us/app/appril-agenda-de-profesionales/id" integer,
    "https://play.google.com/store/apps/details?id=com.appril.app" integer,
    "appril_web_1" "text",
    "appril_web_2" "text",
    "app_store" "text",
    "play_store" "text"
);


ALTER TABLE "public"."source_brevo_campaign_recipients" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."source_brevo_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text",
    "email_normalized" "text",
    "campaign_name" "text",
    "event_type" "text",
    "event_datetime" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."source_brevo_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."source_colombia_contacts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "codigo" "text",
    "nombre2" "text",
    "depanombre" "text",
    "muninombre" "text",
    "direccion" "text",
    "email" "text",
    "email_normalized" "text",
    "phone_e164" "text",
    "phone_e164_2" "text",
    "total_registros_unificados" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."source_colombia_contacts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."source_manual_leads" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "full_name" "text",
    "full_name_normalized" "text",
    "email" "text",
    "email_normalized" "text",
    "phone_e164" "text",
    "phone_e164_2" "text",
    "country" "text" DEFAULT 'Colombia'::"text",
    "department" "text",
    "city" "text",
    "address" "text",
    "source_detail" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."source_manual_leads" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."source_todoc_contacts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "todoc_user_id" bigint,
    "full_name" "text",
    "full_name_normalized" "text",
    "email" "text",
    "email_normalized" "text",
    "phone_e164" "text",
    "phone_e164_2" "text",
    "country" "text",
    "department" "text",
    "city" "text",
    "address" "text",
    "specialization" "text",
    "total_citas" integer DEFAULT 0,
    "ultima_cita" timestamp with time zone,
    "alguna_vez_pago" boolean DEFAULT false,
    "pagando_hoy" boolean DEFAULT false,
    "total_sedes" integer DEFAULT 0,
    "total_pacientes" integer DEFAULT 0,
    "recovery_score" integer DEFAULT 0,
    "segmento_growth" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."source_todoc_contacts" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_brevo_email_summary" AS
 SELECT "email_normalized",
    "max"("email") AS "email",
    "count"(*) FILTER (WHERE ("lower"("event_type") = 'sent'::"text")) AS "brevo_sent",
    "count"(*) FILTER (WHERE ("lower"("event_type") = 'open'::"text")) AS "brevo_opened",
    "count"(*) FILTER (WHERE ("lower"("event_type") = 'click'::"text")) AS "brevo_clicked",
    "count"(*) FILTER (WHERE ("lower"("event_type") = 'unsubscribe'::"text")) AS "brevo_unsubscribed",
    "count"(*) FILTER (WHERE ("lower"("event_type") = 'bounce'::"text")) AS "brevo_bounced",
    "max"("event_datetime") AS "brevo_last_event_at"
   FROM "public"."source_brevo_events"
  WHERE ("email_normalized" IS NOT NULL)
  GROUP BY "email_normalized";


ALTER VIEW "public"."v_brevo_email_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_brevo_summary" AS
 SELECT "email_normalized",
    "max"(
        CASE
            WHEN (COALESCE("open_date", "Open_Date") IS NOT NULL) THEN 1
            ELSE 0
        END) AS "opened_email",
    "max"(
        CASE
            WHEN (NULLIF(TRIM(BOTH FROM COALESCE("app_store", ''::"text")), ''::"text") IS NOT NULL) THEN 1
            WHEN (NULLIF(TRIM(BOTH FROM COALESCE("play_store", ''::"text")), ''::"text") IS NOT NULL) THEN 1
            WHEN (NULLIF(TRIM(BOTH FROM COALESCE("appril_web_1", ''::"text")), ''::"text") IS NOT NULL) THEN 1
            WHEN (NULLIF(TRIM(BOTH FROM COALESCE("appril_web_2", ''::"text")), ''::"text") IS NOT NULL) THEN 1
            WHEN ((NULLIF(TRIM(BOTH FROM COALESCE("Clicked_Links_Count", ''::"text")), ''::"text") IS NOT NULL) AND (TRIM(BOTH FROM COALESCE("Clicked_Links_Count", ''::"text")) <> '0'::"text")) THEN 1
            ELSE 0
        END) AS "clicked_email",
    "max"(
        CASE
            WHEN (COALESCE("hard_bounce_date", "Hard_Bounce_Date") IS NOT NULL) THEN 1
            ELSE 0
        END) AS "hard_bounce",
    "max"(
        CASE
            WHEN (COALESCE("unsubscribe_date", "Unsubscribe_Date") IS NOT NULL) THEN 1
            ELSE 0
        END) AS "unsubscribed_email"
   FROM "public"."source_brevo_campaign_recipients"
  WHERE ("email_normalized" IS NOT NULL)
  GROUP BY "email_normalized";


ALTER VIEW "public"."v_brevo_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_growth_master" AS
 SELECT COALESCE("t"."email_normalized", "b"."email_normalized", "public"."normalize_email"("c"."email")) AS "email",
    "t"."full_name",
    "t"."phone_e164" AS "phone_todoc",
    "c"."phone_e164" AS "phone_colombia",
        CASE
            WHEN ("t"."email" IS NOT NULL) THEN true
            ELSE false
        END AS "is_todoc",
        CASE
            WHEN ("c"."email" IS NOT NULL) THEN true
            ELSE false
        END AS "is_colombia",
    "t"."total_citas",
    "t"."ultima_cita",
    "t"."pagando_hoy",
    "t"."recovery_score",
    "t"."segmento_growth",
        CASE
            WHEN ("b"."Open_Date" IS NOT NULL) THEN true
            ELSE false
        END AS "opened_email",
        CASE
            WHEN ("b"."Clicked_Links_Count" IS NOT NULL) THEN true
            ELSE false
        END AS "clicked_email",
        CASE
            WHEN ("b"."Hard_Bounce_Date" IS NOT NULL) THEN true
            ELSE false
        END AS "hard_bounce",
        CASE
            WHEN ("b"."Hard_Bounce_Date" IS NOT NULL) THEN 'INVALID_EMAIL'::"text"
            WHEN ("b"."Open_Date" IS NOT NULL) THEN 'ENGAGED'::"text"
            WHEN ("t"."total_citas" > 5) THEN 'HOT_TODOC'::"text"
            WHEN ("t"."total_citas" > 0) THEN 'WARM_TODOC'::"text"
            WHEN ("c"."email" IS NOT NULL) THEN 'COLD_COLOMBIA'::"text"
            ELSE 'UNKNOWN'::"text"
        END AS "growth_segment"
   FROM (("public"."source_todoc_contacts" "t"
     FULL JOIN "public"."source_colombia_contacts" "c" ON (("public"."normalize_email"("c"."email") = "t"."email_normalized")))
     FULL JOIN "public"."source_brevo_campaign_recipients" "b" ON (("b"."email_normalized" = COALESCE("t"."email_normalized", "public"."normalize_email"("c"."email")))));


ALTER VIEW "public"."v_growth_master" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_leads_base_union" AS
 SELECT COALESCE("source_todoc_contacts"."email_normalized", "source_todoc_contacts"."phone_e164", "source_todoc_contacts"."phone_e164_2") AS "identity_key",
    "source_todoc_contacts"."email",
    "source_todoc_contacts"."email_normalized",
    "source_todoc_contacts"."phone_e164",
    "source_todoc_contacts"."phone_e164_2",
    "source_todoc_contacts"."full_name",
    "source_todoc_contacts"."city",
    "source_todoc_contacts"."department",
    "source_todoc_contacts"."country",
    "source_todoc_contacts"."address",
    true AS "is_todoc",
    false AS "is_colombia",
    "source_todoc_contacts"."todoc_user_id",
    "source_todoc_contacts"."total_citas",
    "source_todoc_contacts"."ultima_cita",
    "source_todoc_contacts"."alguna_vez_pago",
    "source_todoc_contacts"."pagando_hoy",
    "source_todoc_contacts"."total_sedes",
    "source_todoc_contacts"."total_pacientes",
    "source_todoc_contacts"."recovery_score",
    "source_todoc_contacts"."segmento_growth"
   FROM "public"."source_todoc_contacts"
UNION ALL
 SELECT COALESCE("source_colombia_contacts"."email_normalized", "source_colombia_contacts"."phone_e164", "source_colombia_contacts"."phone_e164_2") AS "identity_key",
    "source_colombia_contacts"."email",
    "source_colombia_contacts"."email_normalized",
    "source_colombia_contacts"."phone_e164",
    "source_colombia_contacts"."phone_e164_2",
    "source_colombia_contacts"."nombre2" AS "full_name",
    "source_colombia_contacts"."muninombre" AS "city",
    "source_colombia_contacts"."depanombre" AS "department",
    'Colombia'::"text" AS "country",
    "source_colombia_contacts"."direccion" AS "address",
    false AS "is_todoc",
    true AS "is_colombia",
    NULL::bigint AS "todoc_user_id",
    NULL::integer AS "total_citas",
    NULL::timestamp with time zone AS "ultima_cita",
    NULL::boolean AS "alguna_vez_pago",
    NULL::boolean AS "pagando_hoy",
    NULL::integer AS "total_sedes",
    NULL::integer AS "total_pacientes",
    NULL::integer AS "recovery_score",
    NULL::"text" AS "segmento_growth"
   FROM "public"."source_colombia_contacts"
  WHERE (COALESCE("source_colombia_contacts"."email_normalized", "source_colombia_contacts"."phone_e164", "source_colombia_contacts"."phone_e164_2") IS NOT NULL);


ALTER VIEW "public"."v_leads_base_union" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_leads_unified" AS
 WITH "brevo" AS (
         SELECT "source_brevo_campaign_recipients"."email_normalized",
            "max"(COALESCE("source_brevo_campaign_recipients"."email", "source_brevo_campaign_recipients"."Email_ID")) AS "email",
            "max"(
                CASE
                    WHEN (COALESCE("source_brevo_campaign_recipients"."open_date", "source_brevo_campaign_recipients"."Open_Date") IS NOT NULL) THEN 1
                    ELSE 0
                END) AS "opened_email",
            "max"(
                CASE
                    WHEN (NULLIF(TRIM(BOTH FROM COALESCE("source_brevo_campaign_recipients"."app_store", ''::"text")), ''::"text") IS NOT NULL) THEN 1
                    WHEN (NULLIF(TRIM(BOTH FROM COALESCE("source_brevo_campaign_recipients"."play_store", ''::"text")), ''::"text") IS NOT NULL) THEN 1
                    WHEN (NULLIF(TRIM(BOTH FROM COALESCE("source_brevo_campaign_recipients"."appril_web_1", ''::"text")), ''::"text") IS NOT NULL) THEN 1
                    WHEN (NULLIF(TRIM(BOTH FROM COALESCE("source_brevo_campaign_recipients"."appril_web_2", ''::"text")), ''::"text") IS NOT NULL) THEN 1
                    WHEN ((NULLIF(TRIM(BOTH FROM COALESCE("source_brevo_campaign_recipients"."Clicked_Links_Count", ''::"text")), ''::"text") IS NOT NULL) AND (TRIM(BOTH FROM COALESCE("source_brevo_campaign_recipients"."Clicked_Links_Count", ''::"text")) <> '0'::"text")) THEN 1
                    ELSE 0
                END) AS "clicked_email",
            "max"(
                CASE
                    WHEN (COALESCE("source_brevo_campaign_recipients"."hard_bounce_date", "source_brevo_campaign_recipients"."Hard_Bounce_Date") IS NOT NULL) THEN 1
                    ELSE 0
                END) AS "hard_bounce",
            "max"(
                CASE
                    WHEN (COALESCE("source_brevo_campaign_recipients"."unsubscribe_date", "source_brevo_campaign_recipients"."Unsubscribe_Date") IS NOT NULL) THEN 1
                    ELSE 0
                END) AS "unsubscribed_email"
           FROM "public"."source_brevo_campaign_recipients"
          WHERE ("source_brevo_campaign_recipients"."email_normalized" IS NOT NULL)
          GROUP BY "source_brevo_campaign_recipients"."email_normalized"
        ), "all_emails" AS (
         SELECT "source_todoc_contacts"."email_normalized"
           FROM "public"."source_todoc_contacts"
          WHERE ("source_todoc_contacts"."email_normalized" IS NOT NULL)
        UNION
         SELECT "source_colombia_contacts"."email_normalized"
           FROM "public"."source_colombia_contacts"
          WHERE ("source_colombia_contacts"."email_normalized" IS NOT NULL)
        UNION
         SELECT "brevo"."email_normalized"
           FROM "brevo"
          WHERE ("brevo"."email_normalized" IS NOT NULL)
        )
 SELECT "e"."email_normalized",
    COALESCE("c"."email", "t"."email", "b"."email") AS "email",
    NULL::"text" AS "email_secondary",
    COALESCE("c"."phone_e164", "t"."phone_e164") AS "phone",
    COALESCE("c"."phone_e164_2", "t"."phone_e164_2") AS "phone_e164_2",
    COALESCE("c"."nombre2", "t"."full_name") AS "full_name",
    COALESCE("c"."muninombre", "t"."city") AS "city",
    COALESCE("c"."depanombre", "t"."department") AS "department",
    COALESCE("t"."country", 'Colombia'::"text") AS "country",
    COALESCE("c"."direccion", "t"."address") AS "address",
        CASE
            WHEN (("t"."email_normalized" IS NOT NULL) AND ("c"."email_normalized" IS NOT NULL)) THEN 'mixed'::"text"
            WHEN ("t"."email_normalized" IS NOT NULL) THEN 'todoc'::"text"
            WHEN ("c"."email_normalized" IS NOT NULL) THEN 'colombia'::"text"
            WHEN ("b"."email_normalized" IS NOT NULL) THEN 'brevo_only'::"text"
            ELSE 'unknown'::"text"
        END AS "source",
    ("t"."email_normalized" IS NOT NULL) AS "is_todoc",
    ("c"."email_normalized" IS NOT NULL) AS "is_colombia",
    "t"."todoc_user_id",
    "t"."total_citas",
    "t"."ultima_cita",
    "t"."alguna_vez_pago",
    "t"."pagando_hoy",
    "t"."total_sedes",
    "t"."total_pacientes",
    "t"."recovery_score",
    "t"."segmento_growth",
    (COALESCE("b"."opened_email", 0))::boolean AS "opened_email",
    (COALESCE("b"."clicked_email", 0))::boolean AS "clicked_email",
    (COALESCE("b"."hard_bounce", 0))::boolean AS "hard_bounce",
    (COALESCE("b"."unsubscribed_email", 0))::boolean AS "unsubscribed_email"
   FROM ((("all_emails" "e"
     LEFT JOIN "public"."source_todoc_contacts" "t" ON (("t"."email_normalized" = "e"."email_normalized")))
     LEFT JOIN "public"."source_colombia_contacts" "c" ON (("c"."email_normalized" = "e"."email_normalized")))
     LEFT JOIN "brevo" "b" ON (("b"."email_normalized" = "e"."email_normalized")));


ALTER VIEW "public"."v_leads_unified" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_master_contacts_staging" AS
 WITH "todoc" AS (
         SELECT "source_todoc_contacts"."id" AS "source_todoc_id",
            "source_todoc_contacts"."todoc_user_id",
            "source_todoc_contacts"."full_name",
            "source_todoc_contacts"."full_name_normalized",
            "source_todoc_contacts"."email",
            "source_todoc_contacts"."email_normalized",
            "source_todoc_contacts"."phone_e164",
            "source_todoc_contacts"."phone_e164_2",
            "source_todoc_contacts"."country",
            "source_todoc_contacts"."department",
            "source_todoc_contacts"."city",
            "source_todoc_contacts"."address",
            "source_todoc_contacts"."specialization",
            "source_todoc_contacts"."total_citas",
            "source_todoc_contacts"."ultima_cita",
            "source_todoc_contacts"."alguna_vez_pago",
            "source_todoc_contacts"."pagando_hoy",
            "source_todoc_contacts"."total_sedes",
            "source_todoc_contacts"."total_pacientes",
            "source_todoc_contacts"."recovery_score",
            "source_todoc_contacts"."segmento_growth"
           FROM "public"."source_todoc_contacts"
        ), "colombia" AS (
         SELECT "source_colombia_contacts"."id" AS "source_colombia_id",
            "source_colombia_contacts"."codigo",
            "source_colombia_contacts"."nombre2",
            "public"."normalize_name"("source_colombia_contacts"."nombre2") AS "nombre2_normalized",
            "source_colombia_contacts"."depanombre",
            "source_colombia_contacts"."muninombre",
            "source_colombia_contacts"."direccion",
            "source_colombia_contacts"."email",
            "source_colombia_contacts"."email_normalized",
            "source_colombia_contacts"."phone_e164",
            "source_colombia_contacts"."phone_e164_2",
            "source_colombia_contacts"."total_registros_unificados"
           FROM "public"."source_colombia_contacts"
        ), "match_email" AS (
         SELECT 'email'::"text" AS "matched_by",
            "t"."source_todoc_id",
            "c"."source_colombia_id",
            "t"."todoc_user_id",
            "c"."codigo" AS "colombia_codigo",
            COALESCE("t"."full_name", "c"."nombre2") AS "full_name",
            COALESCE("t"."full_name_normalized", "c"."nombre2_normalized") AS "full_name_normalized",
            COALESCE("t"."email", "c"."email") AS "email",
            COALESCE("t"."email_normalized", "c"."email_normalized") AS "email_normalized",
            COALESCE("t"."phone_e164", "c"."phone_e164") AS "phone_e164",
            COALESCE("t"."phone_e164_2", "c"."phone_e164_2") AS "phone_e164_2",
            COALESCE("t"."country", 'Colombia'::"text") AS "country",
            COALESCE("t"."department", "c"."depanombre") AS "department",
            COALESCE("t"."city", "c"."muninombre") AS "city",
            COALESCE("t"."address", "c"."direccion") AS "address",
            "t"."specialization",
            true AS "has_todoc",
            true AS "has_colombia",
            "t"."total_citas",
            "t"."ultima_cita",
            "t"."alguna_vez_pago",
            "t"."pagando_hoy",
            "t"."total_sedes",
            "t"."total_pacientes",
            "t"."recovery_score",
            "t"."segmento_growth",
            "c"."total_registros_unificados"
           FROM ("todoc" "t"
             JOIN "colombia" "c" ON ((("t"."email_normalized" IS NOT NULL) AND ("c"."email_normalized" IS NOT NULL) AND ("t"."email_normalized" = "c"."email_normalized"))))
        ), "matched_todoc_email" AS (
         SELECT DISTINCT "match_email"."source_todoc_id"
           FROM "match_email"
        ), "matched_colombia_email" AS (
         SELECT DISTINCT "match_email"."source_colombia_id"
           FROM "match_email"
        ), "match_phone_1" AS (
         SELECT 'phone_e164'::"text" AS "matched_by",
            "t"."source_todoc_id",
            "c"."source_colombia_id",
            "t"."todoc_user_id",
            "c"."codigo" AS "colombia_codigo",
            COALESCE("t"."full_name", "c"."nombre2") AS "full_name",
            COALESCE("t"."full_name_normalized", "c"."nombre2_normalized") AS "full_name_normalized",
            COALESCE("t"."email", "c"."email") AS "email",
            COALESCE("t"."email_normalized", "c"."email_normalized") AS "email_normalized",
            COALESCE("t"."phone_e164", "c"."phone_e164") AS "phone_e164",
            COALESCE("t"."phone_e164_2", "c"."phone_e164_2") AS "phone_e164_2",
            COALESCE("t"."country", 'Colombia'::"text") AS "country",
            COALESCE("t"."department", "c"."depanombre") AS "department",
            COALESCE("t"."city", "c"."muninombre") AS "city",
            COALESCE("t"."address", "c"."direccion") AS "address",
            "t"."specialization",
            true AS "has_todoc",
            true AS "has_colombia",
            "t"."total_citas",
            "t"."ultima_cita",
            "t"."alguna_vez_pago",
            "t"."pagando_hoy",
            "t"."total_sedes",
            "t"."total_pacientes",
            "t"."recovery_score",
            "t"."segmento_growth",
            "c"."total_registros_unificados"
           FROM ("todoc" "t"
             JOIN "colombia" "c" ON ((("t"."phone_e164" IS NOT NULL) AND ("c"."phone_e164" IS NOT NULL) AND ("t"."phone_e164" = "c"."phone_e164"))))
          WHERE ((NOT ("t"."source_todoc_id" IN ( SELECT "matched_todoc_email"."source_todoc_id"
                   FROM "matched_todoc_email"))) AND (NOT ("c"."source_colombia_id" IN ( SELECT "matched_colombia_email"."source_colombia_id"
                   FROM "matched_colombia_email"))))
        ), "matched_todoc_phone_1" AS (
         SELECT DISTINCT "match_phone_1"."source_todoc_id"
           FROM "match_phone_1"
        ), "matched_colombia_phone_1" AS (
         SELECT DISTINCT "match_phone_1"."source_colombia_id"
           FROM "match_phone_1"
        ), "match_phone_2" AS (
         SELECT 'phone_e164_2'::"text" AS "matched_by",
            "t"."source_todoc_id",
            "c"."source_colombia_id",
            "t"."todoc_user_id",
            "c"."codigo" AS "colombia_codigo",
            COALESCE("t"."full_name", "c"."nombre2") AS "full_name",
            COALESCE("t"."full_name_normalized", "c"."nombre2_normalized") AS "full_name_normalized",
            COALESCE("t"."email", "c"."email") AS "email",
            COALESCE("t"."email_normalized", "c"."email_normalized") AS "email_normalized",
            COALESCE("t"."phone_e164", "c"."phone_e164") AS "phone_e164",
            COALESCE("t"."phone_e164_2", "c"."phone_e164_2") AS "phone_e164_2",
            COALESCE("t"."country", 'Colombia'::"text") AS "country",
            COALESCE("t"."department", "c"."depanombre") AS "department",
            COALESCE("t"."city", "c"."muninombre") AS "city",
            COALESCE("t"."address", "c"."direccion") AS "address",
            "t"."specialization",
            true AS "has_todoc",
            true AS "has_colombia",
            "t"."total_citas",
            "t"."ultima_cita",
            "t"."alguna_vez_pago",
            "t"."pagando_hoy",
            "t"."total_sedes",
            "t"."total_pacientes",
            "t"."recovery_score",
            "t"."segmento_growth",
            "c"."total_registros_unificados"
           FROM ("todoc" "t"
             JOIN "colombia" "c" ON ((("t"."phone_e164_2" IS NOT NULL) AND ("c"."phone_e164_2" IS NOT NULL) AND ("t"."phone_e164_2" = "c"."phone_e164_2"))))
          WHERE ((NOT ("t"."source_todoc_id" IN ( SELECT "matched_todoc_email"."source_todoc_id"
                   FROM "matched_todoc_email"
                UNION
                 SELECT "matched_todoc_phone_1"."source_todoc_id"
                   FROM "matched_todoc_phone_1"))) AND (NOT ("c"."source_colombia_id" IN ( SELECT "matched_colombia_email"."source_colombia_id"
                   FROM "matched_colombia_email"
                UNION
                 SELECT "matched_colombia_phone_1"."source_colombia_id"
                   FROM "matched_colombia_phone_1"))))
        ), "matched_todoc_all" AS (
         SELECT "match_email"."source_todoc_id"
           FROM "match_email"
        UNION
         SELECT "match_phone_1"."source_todoc_id"
           FROM "match_phone_1"
        UNION
         SELECT "match_phone_2"."source_todoc_id"
           FROM "match_phone_2"
        ), "matched_colombia_all" AS (
         SELECT "match_email"."source_colombia_id"
           FROM "match_email"
        UNION
         SELECT "match_phone_1"."source_colombia_id"
           FROM "match_phone_1"
        UNION
         SELECT "match_phone_2"."source_colombia_id"
           FROM "match_phone_2"
        ), "todoc_only" AS (
         SELECT 'todoc_only'::"text" AS "matched_by",
            "t"."source_todoc_id",
            NULL::"uuid" AS "source_colombia_id",
            "t"."todoc_user_id",
            NULL::"text" AS "colombia_codigo",
            "t"."full_name",
            "t"."full_name_normalized",
            "t"."email",
            "t"."email_normalized",
            "t"."phone_e164",
            "t"."phone_e164_2",
            "t"."country",
            "t"."department",
            "t"."city",
            "t"."address",
            "t"."specialization",
            true AS "has_todoc",
            false AS "has_colombia",
            "t"."total_citas",
            "t"."ultima_cita",
            "t"."alguna_vez_pago",
            "t"."pagando_hoy",
            "t"."total_sedes",
            "t"."total_pacientes",
            "t"."recovery_score",
            "t"."segmento_growth",
            1 AS "total_registros_unificados"
           FROM "todoc" "t"
          WHERE (NOT ("t"."source_todoc_id" IN ( SELECT "matched_todoc_all"."source_todoc_id"
                   FROM "matched_todoc_all")))
        ), "colombia_only" AS (
         SELECT 'colombia_only'::"text" AS "matched_by",
            NULL::"uuid" AS "source_todoc_id",
            "c"."source_colombia_id",
            NULL::bigint AS "todoc_user_id",
            "c"."codigo" AS "colombia_codigo",
            "c"."nombre2" AS "full_name",
            "c"."nombre2_normalized" AS "full_name_normalized",
            "c"."email",
            "c"."email_normalized",
            "c"."phone_e164",
            "c"."phone_e164_2",
            'Colombia'::"text" AS "country",
            "c"."depanombre" AS "department",
            "c"."muninombre" AS "city",
            "c"."direccion" AS "address",
            NULL::"text" AS "specialization",
            false AS "has_todoc",
            true AS "has_colombia",
            0 AS "total_citas",
            NULL::timestamp with time zone AS "ultima_cita",
            false AS "alguna_vez_pago",
            false AS "pagando_hoy",
            0 AS "total_sedes",
            0 AS "total_pacientes",
            0 AS "recovery_score",
            NULL::"text" AS "segmento_growth",
            COALESCE("c"."total_registros_unificados", 1) AS "total_registros_unificados"
           FROM "colombia" "c"
          WHERE (NOT ("c"."source_colombia_id" IN ( SELECT "matched_colombia_all"."source_colombia_id"
                   FROM "matched_colombia_all")))
        ), "base_union" AS (
         SELECT "match_email"."matched_by",
            "match_email"."source_todoc_id",
            "match_email"."source_colombia_id",
            "match_email"."todoc_user_id",
            "match_email"."colombia_codigo",
            "match_email"."full_name",
            "match_email"."full_name_normalized",
            "match_email"."email",
            "match_email"."email_normalized",
            "match_email"."phone_e164",
            "match_email"."phone_e164_2",
            "match_email"."country",
            "match_email"."department",
            "match_email"."city",
            "match_email"."address",
            "match_email"."specialization",
            "match_email"."has_todoc",
            "match_email"."has_colombia",
            "match_email"."total_citas",
            "match_email"."ultima_cita",
            "match_email"."alguna_vez_pago",
            "match_email"."pagando_hoy",
            "match_email"."total_sedes",
            "match_email"."total_pacientes",
            "match_email"."recovery_score",
            "match_email"."segmento_growth",
            "match_email"."total_registros_unificados"
           FROM "match_email"
        UNION ALL
         SELECT "match_phone_1"."matched_by",
            "match_phone_1"."source_todoc_id",
            "match_phone_1"."source_colombia_id",
            "match_phone_1"."todoc_user_id",
            "match_phone_1"."colombia_codigo",
            "match_phone_1"."full_name",
            "match_phone_1"."full_name_normalized",
            "match_phone_1"."email",
            "match_phone_1"."email_normalized",
            "match_phone_1"."phone_e164",
            "match_phone_1"."phone_e164_2",
            "match_phone_1"."country",
            "match_phone_1"."department",
            "match_phone_1"."city",
            "match_phone_1"."address",
            "match_phone_1"."specialization",
            "match_phone_1"."has_todoc",
            "match_phone_1"."has_colombia",
            "match_phone_1"."total_citas",
            "match_phone_1"."ultima_cita",
            "match_phone_1"."alguna_vez_pago",
            "match_phone_1"."pagando_hoy",
            "match_phone_1"."total_sedes",
            "match_phone_1"."total_pacientes",
            "match_phone_1"."recovery_score",
            "match_phone_1"."segmento_growth",
            "match_phone_1"."total_registros_unificados"
           FROM "match_phone_1"
        UNION ALL
         SELECT "match_phone_2"."matched_by",
            "match_phone_2"."source_todoc_id",
            "match_phone_2"."source_colombia_id",
            "match_phone_2"."todoc_user_id",
            "match_phone_2"."colombia_codigo",
            "match_phone_2"."full_name",
            "match_phone_2"."full_name_normalized",
            "match_phone_2"."email",
            "match_phone_2"."email_normalized",
            "match_phone_2"."phone_e164",
            "match_phone_2"."phone_e164_2",
            "match_phone_2"."country",
            "match_phone_2"."department",
            "match_phone_2"."city",
            "match_phone_2"."address",
            "match_phone_2"."specialization",
            "match_phone_2"."has_todoc",
            "match_phone_2"."has_colombia",
            "match_phone_2"."total_citas",
            "match_phone_2"."ultima_cita",
            "match_phone_2"."alguna_vez_pago",
            "match_phone_2"."pagando_hoy",
            "match_phone_2"."total_sedes",
            "match_phone_2"."total_pacientes",
            "match_phone_2"."recovery_score",
            "match_phone_2"."segmento_growth",
            "match_phone_2"."total_registros_unificados"
           FROM "match_phone_2"
        UNION ALL
         SELECT "todoc_only"."matched_by",
            "todoc_only"."source_todoc_id",
            "todoc_only"."source_colombia_id",
            "todoc_only"."todoc_user_id",
            "todoc_only"."colombia_codigo",
            "todoc_only"."full_name",
            "todoc_only"."full_name_normalized",
            "todoc_only"."email",
            "todoc_only"."email_normalized",
            "todoc_only"."phone_e164",
            "todoc_only"."phone_e164_2",
            "todoc_only"."country",
            "todoc_only"."department",
            "todoc_only"."city",
            "todoc_only"."address",
            "todoc_only"."specialization",
            "todoc_only"."has_todoc",
            "todoc_only"."has_colombia",
            "todoc_only"."total_citas",
            "todoc_only"."ultima_cita",
            "todoc_only"."alguna_vez_pago",
            "todoc_only"."pagando_hoy",
            "todoc_only"."total_sedes",
            "todoc_only"."total_pacientes",
            "todoc_only"."recovery_score",
            "todoc_only"."segmento_growth",
            "todoc_only"."total_registros_unificados"
           FROM "todoc_only"
        UNION ALL
         SELECT "colombia_only"."matched_by",
            "colombia_only"."source_todoc_id",
            "colombia_only"."source_colombia_id",
            "colombia_only"."todoc_user_id",
            "colombia_only"."colombia_codigo",
            "colombia_only"."full_name",
            "colombia_only"."full_name_normalized",
            "colombia_only"."email",
            "colombia_only"."email_normalized",
            "colombia_only"."phone_e164",
            "colombia_only"."phone_e164_2",
            "colombia_only"."country",
            "colombia_only"."department",
            "colombia_only"."city",
            "colombia_only"."address",
            "colombia_only"."specialization",
            "colombia_only"."has_todoc",
            "colombia_only"."has_colombia",
            "colombia_only"."total_citas",
            "colombia_only"."ultima_cita",
            "colombia_only"."alguna_vez_pago",
            "colombia_only"."pagando_hoy",
            "colombia_only"."total_sedes",
            "colombia_only"."total_pacientes",
            "colombia_only"."recovery_score",
            "colombia_only"."segmento_growth",
            "colombia_only"."total_registros_unificados"
           FROM "colombia_only"
        ), "final_join" AS (
         SELECT "b"."matched_by",
            "b"."source_todoc_id",
            "b"."source_colombia_id",
            "b"."todoc_user_id",
            "b"."colombia_codigo",
            "b"."full_name",
            "b"."full_name_normalized",
            "b"."email",
            "b"."email_normalized",
            "b"."phone_e164",
            "b"."phone_e164_2",
            "b"."country",
            "b"."department",
            "b"."city",
            "b"."address",
            "b"."specialization",
            "b"."has_todoc",
            "b"."has_colombia",
            "b"."total_citas",
            "b"."ultima_cita",
            "b"."alguna_vez_pago",
            "b"."pagando_hoy",
            "b"."total_sedes",
            "b"."total_pacientes",
            "b"."recovery_score",
            "b"."segmento_growth",
            "b"."total_registros_unificados",
            "bs"."brevo_sent",
            "bs"."brevo_opened",
            "bs"."brevo_clicked",
            "bs"."brevo_unsubscribed",
            "bs"."brevo_bounced",
            "bs"."brevo_last_event_at",
            ("bs"."email_normalized" IS NOT NULL) AS "has_brevo"
           FROM ("base_union" "b"
             LEFT JOIN "public"."v_brevo_email_summary" "bs" ON (("b"."email_normalized" = "bs"."email_normalized")))
        )
 SELECT "gen_random_uuid"() AS "staging_id",
    "matched_by",
    "full_name",
    "full_name_normalized",
    "email",
    "email_normalized",
    NULL::"text" AS "email_secondary",
    "phone_e164",
    "phone_e164_2",
    "country",
    "department",
    "city",
    "address",
    "specialization",
        CASE
            WHEN ("has_todoc" AND "has_colombia") THEN 'mixed'::"text"
            WHEN "has_todoc" THEN 'todoc'::"text"
            WHEN "has_colombia" THEN 'colombia'::"text"
            WHEN "has_brevo" THEN 'brevo_only'::"text"
            ELSE 'unknown'::"text"
        END AS "source_primary",
    "has_todoc",
    "has_colombia",
    "has_brevo",
    "todoc_user_id",
    "colombia_codigo",
    COALESCE("total_registros_unificados", 1) AS "total_registros_unificados",
    COALESCE("total_citas", 0) AS "total_citas",
    "ultima_cita",
    COALESCE("alguna_vez_pago", false) AS "alguna_vez_pago",
    COALESCE("pagando_hoy", false) AS "pagando_hoy",
    COALESCE("total_sedes", 0) AS "total_sedes",
    COALESCE("total_pacientes", 0) AS "total_pacientes",
    COALESCE("recovery_score", 0) AS "recovery_score",
    "segmento_growth",
    COALESCE("brevo_sent", (0)::bigint) AS "brevo_sent",
    COALESCE("brevo_opened", (0)::bigint) AS "brevo_opened",
    COALESCE("brevo_clicked", (0)::bigint) AS "brevo_clicked",
    COALESCE("brevo_unsubscribed", (0)::bigint) AS "brevo_unsubscribed",
    COALESCE("brevo_bounced", (0)::bigint) AS "brevo_bounced",
    "brevo_last_event_at"
   FROM "final_join";


ALTER VIEW "public"."v_master_contacts_staging" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."webhook_endpoints" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "secret" "text" NOT NULL,
    "url_token" "text" NOT NULL,
    "active" boolean DEFAULT true,
    "last_used_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."webhook_endpoints" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."webhook_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "endpoint_id" "uuid",
    "event_type" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "processed" boolean DEFAULT false,
    "processed_at" timestamp with time zone,
    "error" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."webhook_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."workspace_integrations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "channel" "text" NOT NULL,
    "status" "text" DEFAULT 'unconfigured'::"text" NOT NULL,
    "from_email" "text",
    "from_name" "text",
    "wa_phone_number_id" "text",
    "wa_waba_id" "text",
    "wa_phone_display" "text",
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "workspace_integrations_channel_check" CHECK (("channel" = ANY (ARRAY['email'::"text", 'whatsapp'::"text"]))),
    CONSTRAINT "workspace_integrations_status_check" CHECK (("status" = ANY (ARRAY['unconfigured'::"text", 'pending_verification'::"text", 'active'::"text", 'disabled'::"text"])))
);


ALTER TABLE "public"."workspace_integrations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."workspace_secrets" (
    "workspace_id" "uuid" NOT NULL,
    "key" "text" NOT NULL,
    "value" "text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."workspace_secrets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."workspaces" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "settings" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."workspaces" OWNER TO "postgres";


ALTER TABLE ONLY "public"."automation_runs"
    ADD CONSTRAINT "automation_runs_automation_id_lead_id_key" UNIQUE ("automation_id", "lead_id");



ALTER TABLE ONLY "public"."automation_runs"
    ADD CONSTRAINT "automation_runs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."automations"
    ADD CONSTRAINT "automations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."campaigns"
    ADD CONSTRAINT "campaigns_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."crm_users"
    ADD CONSTRAINT "crm_users_auth_user_id_key" UNIQUE ("auth_user_id");



ALTER TABLE ONLY "public"."crm_users"
    ADD CONSTRAINT "crm_users_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."crm_users"
    ADD CONSTRAINT "crm_users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."discovery_config"
    ADD CONSTRAINT "discovery_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."discovery_config"
    ADD CONSTRAINT "discovery_config_workspace_id_key" UNIQUE ("workspace_id");



ALTER TABLE ONLY "public"."discovery_events"
    ADD CONSTRAINT "discovery_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."discovery_leads"
    ADD CONSTRAINT "discovery_leads_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lead_events"
    ADD CONSTRAINT "lead_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lead_list_members"
    ADD CONSTRAINT "lead_list_members_pkey" PRIMARY KEY ("list_id", "lead_id");



ALTER TABLE ONLY "public"."lead_lists"
    ADD CONSTRAINT "lead_lists_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lead_lists"
    ADD CONSTRAINT "lead_lists_workspace_id_name_key" UNIQUE ("workspace_id", "name");



ALTER TABLE ONLY "public"."lead_notes"
    ADD CONSTRAINT "lead_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lead_sequences"
    ADD CONSTRAINT "lead_sequences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lead_tasks"
    ADD CONSTRAINT "lead_tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."leads_master"
    ADD CONSTRAINT "leads_master_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."message_attempts"
    ADD CONSTRAINT "message_attempts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."message_queue"
    ADD CONSTRAINT "message_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."message_templates"
    ADD CONSTRAINT "message_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."message_templates"
    ADD CONSTRAINT "message_templates_workspace_id_template_key_key" UNIQUE ("workspace_id", "template_key");



ALTER TABLE ONLY "public"."pipeline_stages"
    ADD CONSTRAINT "pipeline_stages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pipeline_stages"
    ADD CONSTRAINT "pipeline_stages_workspace_id_key_key" UNIQUE ("workspace_id", "key");



ALTER TABLE ONLY "public"."source_brevo_campaign_recipients"
    ADD CONSTRAINT "source_brevo_campaign_recipients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."source_brevo_events"
    ADD CONSTRAINT "source_brevo_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."source_colombia_contacts"
    ADD CONSTRAINT "source_colombia_contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."source_manual_leads"
    ADD CONSTRAINT "source_manual_leads_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."source_todoc_contacts"
    ADD CONSTRAINT "source_todoc_contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."webhook_endpoints"
    ADD CONSTRAINT "webhook_endpoints_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."webhook_endpoints"
    ADD CONSTRAINT "webhook_endpoints_url_token_key" UNIQUE ("url_token");



ALTER TABLE ONLY "public"."webhook_events"
    ADD CONSTRAINT "webhook_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."workspace_integrations"
    ADD CONSTRAINT "workspace_integrations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."workspace_integrations"
    ADD CONSTRAINT "workspace_integrations_workspace_id_channel_key" UNIQUE ("workspace_id", "channel");



ALTER TABLE ONLY "public"."workspace_secrets"
    ADD CONSTRAINT "workspace_secrets_pkey" PRIMARY KEY ("workspace_id", "key");



ALTER TABLE ONLY "public"."workspaces"
    ADD CONSTRAINT "workspaces_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."workspaces"
    ADD CONSTRAINT "workspaces_slug_key" UNIQUE ("slug");



CREATE INDEX "idx_attempts_message" ON "public"."message_attempts" USING "btree" ("message_id", "attempt_number");



CREATE INDEX "idx_automation_runs_due" ON "public"."automation_runs" USING "btree" ("next_run_at") WHERE ("status" = 'active'::"text");



CREATE INDEX "idx_de_anon_session" ON "public"."discovery_events" USING "btree" ("anonymous_session_id");



CREATE INDEX "idx_de_created_at" ON "public"."discovery_events" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_de_cta_key" ON "public"."discovery_events" USING "btree" ("workspace_id", "cta_key") WHERE ("cta_key" IS NOT NULL);



CREATE INDEX "idx_de_device_type" ON "public"."discovery_events" USING "btree" ("device_type") WHERE ("device_type" IS NOT NULL);



CREATE INDEX "idx_de_discovery_lead" ON "public"."discovery_events" USING "btree" ("discovery_lead_id");



CREATE INDEX "idx_de_event_name" ON "public"."discovery_events" USING "btree" ("event_name");



CREATE INDEX "idx_de_lead_id" ON "public"."discovery_events" USING "btree" ("lead_id") WHERE ("lead_id" IS NOT NULL);



CREATE INDEX "idx_de_section" ON "public"."discovery_events" USING "btree" ("workspace_id", "section") WHERE ("section" IS NOT NULL);



CREATE INDEX "idx_de_step_index" ON "public"."discovery_events" USING "btree" ("workspace_id", "step_index") WHERE ("step_index" IS NOT NULL);



CREATE INDEX "idx_de_step_key" ON "public"."discovery_events" USING "btree" ("workspace_id", "step_key") WHERE ("step_key" IS NOT NULL);



CREATE INDEX "idx_de_utm_campaign" ON "public"."discovery_events" USING "btree" ("utm_campaign") WHERE ("utm_campaign" IS NOT NULL);



CREATE INDEX "idx_de_utm_source" ON "public"."discovery_events" USING "btree" ("utm_source") WHERE ("utm_source" IS NOT NULL);



CREATE INDEX "idx_de_workspace" ON "public"."discovery_events" USING "btree" ("workspace_id");



CREATE INDEX "idx_discovery_leads_created" ON "public"."discovery_leads" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_discovery_leads_lead_id" ON "public"."discovery_leads" USING "btree" ("lead_id") WHERE ("lead_id" IS NOT NULL);



CREATE INDEX "idx_discovery_leads_segment" ON "public"."discovery_leads" USING "btree" ("workspace_id", "marketing_segment");



CREATE INDEX "idx_discovery_leads_status" ON "public"."discovery_leads" USING "btree" ("workspace_id", "status");



CREATE INDEX "idx_discovery_leads_workspace" ON "public"."discovery_leads" USING "btree" ("workspace_id");



CREATE INDEX "idx_events_lead" ON "public"."lead_events" USING "btree" ("lead_id", "created_at" DESC);



CREATE INDEX "idx_events_type" ON "public"."lead_events" USING "btree" ("workspace_id", "event_type", "created_at" DESC);



CREATE INDEX "idx_events_workspace" ON "public"."lead_events" USING "btree" ("workspace_id", "created_at" DESC);



CREATE INDEX "idx_lead_events_created_at" ON "public"."lead_events" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_lead_events_event_type" ON "public"."lead_events" USING "btree" ("event_type");



CREATE INDEX "idx_lead_events_inbound" ON "public"."lead_events" USING "btree" ("lead_id", "created_at" DESC) WHERE ("event_type" = ANY (ARRAY['wa_reply'::"text", 'email_replied'::"text"]));



CREATE INDEX "idx_lead_events_lead_created" ON "public"."lead_events" USING "btree" ("lead_id", "created_at" DESC);



CREATE INDEX "idx_lead_events_lead_id" ON "public"."lead_events" USING "btree" ("lead_id");



CREATE INDEX "idx_leads_email_norm" ON "public"."leads_master" USING "btree" ("email_normalized");



CREATE INDEX "idx_leads_master_can_email" ON "public"."leads_master" USING "btree" ("can_email");



CREATE INDEX "idx_leads_master_email_normalized" ON "public"."leads_master" USING "btree" ("email_normalized");



CREATE INDEX "idx_leads_master_heat" ON "public"."leads_master" USING "btree" ("workspace_id", "last_engaged_at" DESC, "engagement_score" DESC);



CREATE INDEX "idx_leads_master_marketing_segment" ON "public"."leads_master" USING "btree" ("marketing_segment");



CREATE INDEX "idx_leads_master_phone" ON "public"."leads_master" USING "btree" ("phone");



CREATE INDEX "idx_leads_owner" ON "public"."leads_master" USING "btree" ("owner_id");



CREATE INDEX "idx_leads_phone" ON "public"."leads_master" USING "btree" ("phone");



CREATE INDEX "idx_leads_segment" ON "public"."leads_master" USING "btree" ("workspace_id", "marketing_segment");



CREATE INDEX "idx_leads_stage" ON "public"."leads_master" USING "btree" ("workspace_id", "pipeline_stage");



CREATE INDEX "idx_leads_updated" ON "public"."leads_master" USING "btree" ("updated_at" DESC);



CREATE INDEX "idx_leads_workspace" ON "public"."leads_master" USING "btree" ("workspace_id");



CREATE INDEX "idx_list_members_lead" ON "public"."lead_list_members" USING "btree" ("lead_id");



CREATE INDEX "idx_notes_lead" ON "public"."lead_notes" USING "btree" ("lead_id", "created_at" DESC);



CREATE UNIQUE INDEX "idx_one_active_per_lead" ON "public"."lead_sequences" USING "btree" ("lead_id") WHERE ("status" = 'active'::"text");



CREATE INDEX "idx_queue_campaign" ON "public"."message_queue" USING "btree" ("campaign_id");



CREATE INDEX "idx_queue_lead" ON "public"."message_queue" USING "btree" ("lead_id", "created_at" DESC);



CREATE INDEX "idx_queue_pending" ON "public"."message_queue" USING "btree" ("scheduled_at") WHERE ("status" = 'pending'::"text");



CREATE INDEX "idx_queue_ses_id" ON "public"."message_queue" USING "btree" ("ses_message_id") WHERE ("ses_message_id" IS NOT NULL);



CREATE INDEX "idx_queue_wa_id" ON "public"."message_queue" USING "btree" ("wa_message_id") WHERE ("wa_message_id" IS NOT NULL);



CREATE INDEX "idx_queue_workspace" ON "public"."message_queue" USING "btree" ("workspace_id", "status");



CREATE INDEX "idx_runs_automation" ON "public"."automation_runs" USING "btree" ("automation_id", "status");



CREATE INDEX "idx_runs_lead" ON "public"."automation_runs" USING "btree" ("lead_id");



CREATE INDEX "idx_runs_next" ON "public"."automation_runs" USING "btree" ("next_run_at") WHERE ("status" = 'active'::"text");



CREATE INDEX "idx_sequences_lead" ON "public"."lead_sequences" USING "btree" ("lead_id", "status");



CREATE INDEX "idx_sequences_pending" ON "public"."lead_sequences" USING "btree" ("status", "next_action_at") WHERE ("status" = 'active'::"text");



CREATE INDEX "idx_source_brevo_campaign" ON "public"."source_brevo_events" USING "btree" ("campaign_name");



CREATE INDEX "idx_source_brevo_email_norm" ON "public"."source_brevo_events" USING "btree" ("email_normalized");



CREATE INDEX "idx_source_brevo_event_type" ON "public"."source_brevo_events" USING "btree" ("event_type");



CREATE INDEX "idx_source_colombia_codigo" ON "public"."source_colombia_contacts" USING "btree" ("codigo");



CREATE INDEX "idx_source_colombia_email_norm" ON "public"."source_colombia_contacts" USING "btree" ("email_normalized");



CREATE INDEX "idx_source_colombia_phone_1" ON "public"."source_colombia_contacts" USING "btree" ("phone_e164");



CREATE INDEX "idx_source_colombia_phone_2" ON "public"."source_colombia_contacts" USING "btree" ("phone_e164_2");



CREATE INDEX "idx_source_todoc_email_norm" ON "public"."source_todoc_contacts" USING "btree" ("email_normalized");



CREATE INDEX "idx_source_todoc_phone_1" ON "public"."source_todoc_contacts" USING "btree" ("phone_e164");



CREATE INDEX "idx_source_todoc_phone_2" ON "public"."source_todoc_contacts" USING "btree" ("phone_e164_2");



CREATE INDEX "idx_source_todoc_user_id" ON "public"."source_todoc_contacts" USING "btree" ("todoc_user_id");



CREATE INDEX "idx_tasks_assigned" ON "public"."lead_tasks" USING "btree" ("assigned_to") WHERE ("status" = 'open'::"text");



CREATE INDEX "idx_tasks_lead" ON "public"."lead_tasks" USING "btree" ("lead_id", "created_at" DESC);



CREATE INDEX "idx_tasks_open" ON "public"."lead_tasks" USING "btree" ("workspace_id", "due_at") WHERE ("status" = 'open'::"text");



CREATE INDEX "idx_webhook_unprocessed" ON "public"."webhook_events" USING "btree" ("created_at") WHERE ("processed" = false);



CREATE UNIQUE INDEX "uq_automation_runs_active" ON "public"."automation_runs" USING "btree" ("automation_id", "lead_id") WHERE ("status" = 'active'::"text");



CREATE UNIQUE INDEX "uq_lead_events_wa_reply_wamid" ON "public"."lead_events" USING "btree" (COALESCE(("metadata" ->> 'wa_message_id'::"text"), ("metadata" ->> 'id'::"text"))) WHERE (("event_type" = 'wa_reply'::"text") AND (COALESCE(("metadata" ->> 'wa_message_id'::"text"), ("metadata" ->> 'id'::"text")) IS NOT NULL));



CREATE UNIQUE INDEX "workspace_integrations_wa_phone_idx" ON "public"."workspace_integrations" USING "btree" ("wa_phone_number_id") WHERE ("wa_phone_number_id" IS NOT NULL);



CREATE OR REPLACE TRIGGER "discovery_config_updated_at" BEFORE UPDATE ON "public"."discovery_config" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "discovery_leads_updated_at" BEFORE UPDATE ON "public"."discovery_leads" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "trg_auto_enroll" AFTER INSERT ON "public"."lead_events" FOR EACH ROW EXECUTE FUNCTION "public"."auto_enroll_on_event"();



CREATE OR REPLACE TRIGGER "trg_auto_pipeline" AFTER INSERT ON "public"."lead_events" FOR EACH ROW EXECUTE FUNCTION "public"."auto_advance_pipeline"();



CREATE OR REPLACE TRIGGER "trg_enqueue_referral_invite" AFTER INSERT ON "public"."leads_master" FOR EACH ROW EXECUTE FUNCTION "public"."enqueue_referral_invite"();



CREATE OR REPLACE TRIGGER "trg_lead_engagement" AFTER INSERT ON "public"."lead_events" FOR EACH ROW EXECUTE FUNCTION "public"."apply_lead_engagement"();



CREATE OR REPLACE TRIGGER "workspace_integrations_touch" BEFORE UPDATE ON "public"."workspace_integrations" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



ALTER TABLE ONLY "public"."automation_runs"
    ADD CONSTRAINT "automation_runs_automation_id_fkey" FOREIGN KEY ("automation_id") REFERENCES "public"."automations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."automation_runs"
    ADD CONSTRAINT "automation_runs_lead_id_fkey" FOREIGN KEY ("lead_id") REFERENCES "public"."leads_master"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."automation_runs"
    ADD CONSTRAINT "automation_runs_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."automations"
    ADD CONSTRAINT "automations_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."crm_users"("id");



ALTER TABLE ONLY "public"."automations"
    ADD CONSTRAINT "automations_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."campaigns"
    ADD CONSTRAINT "campaigns_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."crm_users"("id");



ALTER TABLE ONLY "public"."campaigns"
    ADD CONSTRAINT "campaigns_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."crm_users"
    ADD CONSTRAINT "crm_users_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."discovery_config"
    ADD CONSTRAINT "discovery_config_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id");



ALTER TABLE ONLY "public"."discovery_events"
    ADD CONSTRAINT "discovery_events_discovery_lead_id_fkey" FOREIGN KEY ("discovery_lead_id") REFERENCES "public"."discovery_leads"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."discovery_events"
    ADD CONSTRAINT "discovery_events_lead_id_fkey" FOREIGN KEY ("lead_id") REFERENCES "public"."leads_master"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."discovery_events"
    ADD CONSTRAINT "discovery_events_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id");



ALTER TABLE ONLY "public"."discovery_leads"
    ADD CONSTRAINT "discovery_leads_lead_id_fkey" FOREIGN KEY ("lead_id") REFERENCES "public"."leads_master"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."discovery_leads"
    ADD CONSTRAINT "discovery_leads_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id");



ALTER TABLE ONLY "public"."lead_events"
    ADD CONSTRAINT "lead_events_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id");



ALTER TABLE ONLY "public"."lead_list_members"
    ADD CONSTRAINT "lead_list_members_lead_id_fkey" FOREIGN KEY ("lead_id") REFERENCES "public"."leads_master"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lead_list_members"
    ADD CONSTRAINT "lead_list_members_list_id_fkey" FOREIGN KEY ("list_id") REFERENCES "public"."lead_lists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lead_lists"
    ADD CONSTRAINT "lead_lists_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id");



ALTER TABLE ONLY "public"."lead_notes"
    ADD CONSTRAINT "lead_notes_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."crm_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."lead_notes"
    ADD CONSTRAINT "lead_notes_lead_id_fkey" FOREIGN KEY ("lead_id") REFERENCES "public"."leads_master"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lead_notes"
    ADD CONSTRAINT "lead_notes_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lead_sequences"
    ADD CONSTRAINT "lead_sequences_lead_id_fkey" FOREIGN KEY ("lead_id") REFERENCES "public"."leads_master"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lead_sequences"
    ADD CONSTRAINT "lead_sequences_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id");



ALTER TABLE ONLY "public"."lead_tasks"
    ADD CONSTRAINT "lead_tasks_assigned_to_fkey" FOREIGN KEY ("assigned_to") REFERENCES "public"."crm_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."lead_tasks"
    ADD CONSTRAINT "lead_tasks_completed_by_fkey" FOREIGN KEY ("completed_by") REFERENCES "public"."crm_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."lead_tasks"
    ADD CONSTRAINT "lead_tasks_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."crm_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."lead_tasks"
    ADD CONSTRAINT "lead_tasks_lead_id_fkey" FOREIGN KEY ("lead_id") REFERENCES "public"."leads_master"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lead_tasks"
    ADD CONSTRAINT "lead_tasks_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."leads_master"
    ADD CONSTRAINT "leads_master_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."crm_users"("id");



ALTER TABLE ONLY "public"."leads_master"
    ADD CONSTRAINT "leads_master_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id");



ALTER TABLE ONLY "public"."message_attempts"
    ADD CONSTRAINT "message_attempts_message_id_fkey" FOREIGN KEY ("message_id") REFERENCES "public"."message_queue"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."message_queue"
    ADD CONSTRAINT "message_queue_automation_run_id_fkey" FOREIGN KEY ("automation_run_id") REFERENCES "public"."automation_runs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."message_queue"
    ADD CONSTRAINT "message_queue_campaign_id_fkey" FOREIGN KEY ("campaign_id") REFERENCES "public"."campaigns"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."message_queue"
    ADD CONSTRAINT "message_queue_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."crm_users"("id");



ALTER TABLE ONLY "public"."message_queue"
    ADD CONSTRAINT "message_queue_lead_id_fkey" FOREIGN KEY ("lead_id") REFERENCES "public"."leads_master"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."message_queue"
    ADD CONSTRAINT "message_queue_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."message_templates"
    ADD CONSTRAINT "message_templates_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."crm_users"("id");



ALTER TABLE ONLY "public"."message_templates"
    ADD CONSTRAINT "message_templates_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pipeline_stages"
    ADD CONSTRAINT "pipeline_stages_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."webhook_endpoints"
    ADD CONSTRAINT "webhook_endpoints_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."webhook_events"
    ADD CONSTRAINT "webhook_events_endpoint_id_fkey" FOREIGN KEY ("endpoint_id") REFERENCES "public"."webhook_endpoints"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."webhook_events"
    ADD CONSTRAINT "webhook_events_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."workspace_integrations"
    ADD CONSTRAINT "workspace_integrations_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."workspace_secrets"
    ADD CONSTRAINT "workspace_secrets_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;



CREATE POLICY "admins manage own integrations" ON "public"."workspace_integrations" USING ((("workspace_id" = "public"."current_workspace_id"()) AND ("public"."current_user_role"() = 'admin'::"text"))) WITH CHECK ((("workspace_id" = "public"."current_workspace_id"()) AND ("public"."current_user_role"() = 'admin'::"text")));



CREATE POLICY "attempts_tenant_rw" ON "public"."message_attempts" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."message_queue" "mq"
  WHERE (("mq"."id" = "message_attempts"."message_id") AND ("mq"."workspace_id" = "public"."current_workspace_id"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."message_queue" "mq"
  WHERE (("mq"."id" = "message_attempts"."message_id") AND ("mq"."workspace_id" = "public"."current_workspace_id"())))));



ALTER TABLE "public"."automation_runs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "automation_runs_tenant_rw" ON "public"."automation_runs" TO "authenticated" USING (("workspace_id" = "public"."current_workspace_id"())) WITH CHECK (("workspace_id" = "public"."current_workspace_id"()));



ALTER TABLE "public"."automations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "automations_tenant_rw" ON "public"."automations" TO "authenticated" USING (("workspace_id" = "public"."current_workspace_id"())) WITH CHECK (("workspace_id" = "public"."current_workspace_id"()));



ALTER TABLE "public"."campaigns" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "campaigns_tenant_rw" ON "public"."campaigns" TO "authenticated" USING (("workspace_id" = "public"."current_workspace_id"())) WITH CHECK (("workspace_id" = "public"."current_workspace_id"()));



CREATE POLICY "crm_select_discovery_config" ON "public"."discovery_config" FOR SELECT USING (("workspace_id" = "public"."current_workspace_id"()));



CREATE POLICY "crm_select_discovery_events" ON "public"."discovery_events" FOR SELECT USING (("workspace_id" = "public"."current_workspace_id"()));



CREATE POLICY "crm_select_discovery_leads" ON "public"."discovery_leads" FOR SELECT USING (("workspace_id" = "public"."current_workspace_id"()));



CREATE POLICY "crm_update_discovery_config" ON "public"."discovery_config" FOR UPDATE USING ((("workspace_id" = "public"."current_workspace_id"()) AND ("public"."current_user_role"() = 'admin'::"text")));



CREATE POLICY "crm_update_discovery_leads" ON "public"."discovery_leads" FOR UPDATE USING (("workspace_id" = "public"."current_workspace_id"()));



ALTER TABLE "public"."crm_users" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."discovery_config" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."discovery_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."discovery_leads" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lead_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lead_events_tenant_rw" ON "public"."lead_events" TO "authenticated" USING (("workspace_id" = "public"."current_workspace_id"())) WITH CHECK (("workspace_id" = "public"."current_workspace_id"()));



ALTER TABLE "public"."lead_list_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lead_list_members_tenant_rw" ON "public"."lead_list_members" USING ((EXISTS ( SELECT 1
   FROM "public"."lead_lists" "l"
  WHERE (("l"."id" = "lead_list_members"."list_id") AND ("l"."workspace_id" = "public"."current_workspace_id"())))));



ALTER TABLE "public"."lead_lists" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lead_lists_tenant_rw" ON "public"."lead_lists" USING (("workspace_id" = "public"."current_workspace_id"()));



ALTER TABLE "public"."lead_notes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lead_notes_tenant_rw" ON "public"."lead_notes" TO "authenticated" USING (("workspace_id" = "public"."current_workspace_id"())) WITH CHECK (("workspace_id" = "public"."current_workspace_id"()));



ALTER TABLE "public"."lead_sequences" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lead_sequences_tenant_rw" ON "public"."lead_sequences" TO "authenticated" USING (("workspace_id" = "public"."current_workspace_id"())) WITH CHECK (("workspace_id" = "public"."current_workspace_id"()));



ALTER TABLE "public"."lead_tasks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lead_tasks_tenant_rw" ON "public"."lead_tasks" TO "authenticated" USING (("workspace_id" = "public"."current_workspace_id"())) WITH CHECK (("workspace_id" = "public"."current_workspace_id"()));



ALTER TABLE "public"."leads_master" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "leads_master_tenant_rw" ON "public"."leads_master" TO "authenticated" USING (("workspace_id" = "public"."current_workspace_id"())) WITH CHECK (("workspace_id" = "public"."current_workspace_id"()));



CREATE POLICY "members read own integrations" ON "public"."workspace_integrations" FOR SELECT USING (("workspace_id" = "public"."current_workspace_id"()));



ALTER TABLE "public"."message_attempts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."message_queue" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "message_queue_tenant_rw" ON "public"."message_queue" TO "authenticated" USING (("workspace_id" = "public"."current_workspace_id"())) WITH CHECK (("workspace_id" = "public"."current_workspace_id"()));



ALTER TABLE "public"."message_templates" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "message_templates_tenant_rw" ON "public"."message_templates" TO "authenticated" USING (("workspace_id" = "public"."current_workspace_id"())) WITH CHECK (("workspace_id" = "public"."current_workspace_id"()));



ALTER TABLE "public"."pipeline_stages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."source_brevo_campaign_recipients" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."source_brevo_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."source_colombia_contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."source_manual_leads" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."source_todoc_contacts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "stages_admin_write" ON "public"."pipeline_stages" TO "authenticated" USING ((("workspace_id" = "public"."current_workspace_id"()) AND ("public"."current_user_role"() = 'admin'::"text"))) WITH CHECK ((("workspace_id" = "public"."current_workspace_id"()) AND ("public"."current_user_role"() = 'admin'::"text")));



CREATE POLICY "stages_select" ON "public"."pipeline_stages" FOR SELECT TO "authenticated" USING (("workspace_id" = "public"."current_workspace_id"()));



CREATE POLICY "users_admin_all" ON "public"."crm_users" TO "authenticated" USING ((("workspace_id" = "public"."current_workspace_id"()) AND ("public"."current_user_role"() = 'admin'::"text"))) WITH CHECK ((("workspace_id" = "public"."current_workspace_id"()) AND ("public"."current_user_role"() = 'admin'::"text")));



CREATE POLICY "users_select_same_ws" ON "public"."crm_users" FOR SELECT TO "authenticated" USING (("workspace_id" = "public"."current_workspace_id"()));



ALTER TABLE "public"."webhook_endpoints" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "webhook_endpoints_tenant_rw" ON "public"."webhook_endpoints" TO "authenticated" USING (("workspace_id" = "public"."current_workspace_id"())) WITH CHECK (("workspace_id" = "public"."current_workspace_id"()));



ALTER TABLE "public"."webhook_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "webhook_events_tenant_rw" ON "public"."webhook_events" TO "authenticated" USING (("workspace_id" = "public"."current_workspace_id"())) WITH CHECK (("workspace_id" = "public"."current_workspace_id"()));



ALTER TABLE "public"."workspace_integrations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."workspace_secrets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."workspaces" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ws_select_own" ON "public"."workspaces" FOR SELECT TO "authenticated" USING (("id" = "public"."current_workspace_id"()));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";





GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";











































































































































































GRANT ALL ON FUNCTION "public"."apply_lead_engagement"() TO "anon";
GRANT ALL ON FUNCTION "public"."apply_lead_engagement"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_lead_engagement"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_advance_pipeline"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_advance_pipeline"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_advance_pipeline"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_enroll_on_event"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_enroll_on_event"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_enroll_on_event"() TO "service_role";



GRANT ALL ON FUNCTION "public"."automation_tick"() TO "anon";
GRANT ALL ON FUNCTION "public"."automation_tick"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."automation_tick"() TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_discovery_score"("p_q_volume" "text", "p_q_lost" "text", "p_q_intent" "text", "p_q_urgency" "text", "p_q_ticket" "text", "p_q_digital" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_discovery_score"("p_q_volume" "text", "p_q_lost" "text", "p_q_intent" "text", "p_q_urgency" "text", "p_q_ticket" "text", "p_q_digital" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_discovery_score"("p_q_volume" "text", "p_q_lost" "text", "p_q_intent" "text", "p_q_urgency" "text", "p_q_ticket" "text", "p_q_digital" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."campaign_lead_results"("p_campaign_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."campaign_lead_results"("p_campaign_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."campaign_lead_results"("p_campaign_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."campaign_results"("p_campaign_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."campaign_results"("p_campaign_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."campaign_results"("p_campaign_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."campaigns_overview"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."campaigns_overview"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."campaigns_overview"() TO "service_role";



GRANT ALL ON FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."conversation_messages"("p_lead_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_workspace_with_admin"("p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_workspace_with_admin"("p_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_workspace_with_admin"("p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_workspace_with_admin"("p_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."current_user_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_user_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_user_role"() TO "service_role";



GRANT ALL ON FUNCTION "public"."current_workspace_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_workspace_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_workspace_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enqueue_referral_invite"() TO "anon";
GRANT ALL ON FUNCTION "public"."enqueue_referral_invite"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enqueue_referral_invite"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enroll_lead_in_automation"("p_automation_id" "uuid", "p_lead_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."enroll_lead_in_automation"("p_automation_id" "uuid", "p_lead_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."enroll_lead_in_automation"("p_automation_id" "uuid", "p_lead_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."enroll_segment_in_automation"("p_automation_id" "uuid", "p_segment" "text", "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."enroll_segment_in_automation"("p_automation_id" "uuid", "p_segment" "text", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."enroll_segment_in_automation"("p_automation_id" "uuid", "p_segment" "text", "p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."eval_run_condition"("p_lead_id" "uuid", "p_run_started" timestamp with time zone, "p_kind" "text", "p_value" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."eval_run_condition"("p_lead_id" "uuid", "p_run_started" timestamp with time zone, "p_kind" "text", "p_value" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."eval_run_condition"("p_lead_id" "uuid", "p_run_started" timestamp with time zone, "p_kind" "text", "p_value" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."flow_next_node"("p_flow" "jsonb", "p_node_id" "text", "p_handle" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."flow_next_node"("p_flow" "jsonb", "p_node_id" "text", "p_handle" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."flow_next_node"("p_flow" "jsonb", "p_node_id" "text", "p_handle" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."flow_node"("p_flow" "jsonb", "p_node_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."flow_node"("p_flow" "jsonb", "p_node_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."flow_node"("p_flow" "jsonb", "p_node_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sequence_steps"("p_sequence_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_sequence_steps"("p_sequence_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sequence_steps"("p_sequence_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."inbox_threads"("p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."inbox_threads"("p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."inbox_threads"("p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."inbox_unread_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."inbox_unread_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."inbox_unread_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."lead_event_weight"("p_event_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."lead_event_weight"("p_event_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."lead_event_weight"("p_event_type" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."lead_filter_options"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."lead_filter_options"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."lead_filter_options"() TO "service_role";



GRANT ALL ON FUNCTION "public"."lead_quality_summary"() TO "anon";
GRANT ALL ON FUNCTION "public"."lead_quality_summary"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."lead_quality_summary"() TO "service_role";



GRANT ALL ON TABLE "public"."leads_master" TO "anon";
GRANT ALL ON TABLE "public"."leads_master" TO "authenticated";
GRANT ALL ON TABLE "public"."leads_master" TO "service_role";



GRANT ALL ON FUNCTION "public"."lead_var_value"("p_lead" "public"."leads_master", "p_var" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."lead_var_value"("p_lead" "public"."leads_master", "p_var" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."lead_var_value"("p_lead" "public"."leads_master", "p_var" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."leads_needing_reply"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."leads_needing_reply"("p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."leads_needing_reply"("p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."lists_overview"() TO "anon";
GRANT ALL ON FUNCTION "public"."lists_overview"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."lists_overview"() TO "service_role";



GRANT ALL ON FUNCTION "public"."normalize_email"("input" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_email"("input" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_email"("input" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."normalize_name"("input" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_name"("input" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_name"("input" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."recalculate_segments"() TO "anon";
GRANT ALL ON FUNCTION "public"."recalculate_segments"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalculate_segments"() TO "service_role";



GRANT ALL ON FUNCTION "public"."report_activity_daily"("p_days" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."report_activity_daily"("p_days" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."report_activity_daily"("p_days" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."report_channel_stats"("p_days" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."report_channel_stats"("p_days" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."report_channel_stats"("p_days" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."report_funnel"() TO "anon";
GRANT ALL ON FUNCTION "public"."report_funnel"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."report_funnel"() TO "service_role";



GRANT ALL ON FUNCTION "public"."stage_for_event"("p_event_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."stage_for_event"("p_event_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."stage_for_event"("p_event_type" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_discovery_lead"("input" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_discovery_lead"("input" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_discovery_lead"("input" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_discovery_lead"("input" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."submit_discovery_lead"("p_workspace_slug" "text", "p_full_name" "text", "p_whatsapp_e164" "text", "p_email" "text", "p_specialization" "text", "p_city" "text", "p_country" "text", "p_q_volume" "text", "p_q_lost" "text", "p_q_intent" "text", "p_q_urgency" "text", "p_q_ticket" "text", "p_q_digital" "text", "p_utm_source" "text", "p_utm_medium" "text", "p_utm_campaign" "text", "p_utm_content" "text", "p_utm_term" "text", "p_landing_url" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_discovery_lead"("p_workspace_slug" "text", "p_full_name" "text", "p_whatsapp_e164" "text", "p_email" "text", "p_specialization" "text", "p_city" "text", "p_country" "text", "p_q_volume" "text", "p_q_lost" "text", "p_q_intent" "text", "p_q_urgency" "text", "p_q_ticket" "text", "p_q_digital" "text", "p_utm_source" "text", "p_utm_medium" "text", "p_utm_campaign" "text", "p_utm_content" "text", "p_utm_term" "text", "p_landing_url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_discovery_lead"("p_workspace_slug" "text", "p_full_name" "text", "p_whatsapp_e164" "text", "p_email" "text", "p_specialization" "text", "p_city" "text", "p_country" "text", "p_q_volume" "text", "p_q_lost" "text", "p_q_intent" "text", "p_q_urgency" "text", "p_q_ticket" "text", "p_q_digital" "text", "p_utm_source" "text", "p_utm_medium" "text", "p_utm_campaign" "text", "p_utm_content" "text", "p_utm_term" "text", "p_landing_url" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."template_usage"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."template_usage"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."template_usage"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."track_discovery_event"("input" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."track_discovery_event"("input" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."track_discovery_event"("input" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."track_discovery_event"("input" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";
























GRANT ALL ON TABLE "public"."automation_runs" TO "anon";
GRANT ALL ON TABLE "public"."automation_runs" TO "authenticated";
GRANT ALL ON TABLE "public"."automation_runs" TO "service_role";



GRANT ALL ON TABLE "public"."automations" TO "anon";
GRANT ALL ON TABLE "public"."automations" TO "authenticated";
GRANT ALL ON TABLE "public"."automations" TO "service_role";



GRANT ALL ON TABLE "public"."campaigns" TO "anon";
GRANT ALL ON TABLE "public"."campaigns" TO "authenticated";
GRANT ALL ON TABLE "public"."campaigns" TO "service_role";



GRANT ALL ON TABLE "public"."crm_users" TO "anon";
GRANT ALL ON TABLE "public"."crm_users" TO "authenticated";
GRANT ALL ON TABLE "public"."crm_users" TO "service_role";



GRANT ALL ON TABLE "public"."discovery_config" TO "anon";
GRANT ALL ON TABLE "public"."discovery_config" TO "authenticated";
GRANT ALL ON TABLE "public"."discovery_config" TO "service_role";



GRANT ALL ON TABLE "public"."discovery_events" TO "anon";
GRANT ALL ON TABLE "public"."discovery_events" TO "authenticated";
GRANT ALL ON TABLE "public"."discovery_events" TO "service_role";



GRANT ALL ON TABLE "public"."discovery_cta_performance" TO "anon";
GRANT ALL ON TABLE "public"."discovery_cta_performance" TO "authenticated";
GRANT ALL ON TABLE "public"."discovery_cta_performance" TO "service_role";



GRANT ALL ON TABLE "public"."discovery_funnel_sessions" TO "anon";
GRANT ALL ON TABLE "public"."discovery_funnel_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."discovery_funnel_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."discovery_leads" TO "anon";
GRANT ALL ON TABLE "public"."discovery_leads" TO "authenticated";
GRANT ALL ON TABLE "public"."discovery_leads" TO "service_role";



GRANT ALL ON TABLE "public"."discovery_lead_summary" TO "anon";
GRANT ALL ON TABLE "public"."discovery_lead_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."discovery_lead_summary" TO "service_role";



GRANT ALL ON TABLE "public"."discovery_section_funnel" TO "anon";
GRANT ALL ON TABLE "public"."discovery_section_funnel" TO "authenticated";
GRANT ALL ON TABLE "public"."discovery_section_funnel" TO "service_role";



GRANT ALL ON TABLE "public"."discovery_step_dropoff" TO "anon";
GRANT ALL ON TABLE "public"."discovery_step_dropoff" TO "authenticated";
GRANT ALL ON TABLE "public"."discovery_step_dropoff" TO "service_role";



GRANT ALL ON TABLE "public"."lead_events" TO "anon";
GRANT ALL ON TABLE "public"."lead_events" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_events" TO "service_role";



GRANT ALL ON TABLE "public"."lead_list_members" TO "anon";
GRANT ALL ON TABLE "public"."lead_list_members" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_list_members" TO "service_role";



GRANT ALL ON TABLE "public"."lead_lists" TO "anon";
GRANT ALL ON TABLE "public"."lead_lists" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_lists" TO "service_role";



GRANT ALL ON TABLE "public"."lead_notes" TO "anon";
GRANT ALL ON TABLE "public"."lead_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_notes" TO "service_role";



GRANT ALL ON TABLE "public"."lead_sequences" TO "anon";
GRANT ALL ON TABLE "public"."lead_sequences" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_sequences" TO "service_role";



GRANT ALL ON TABLE "public"."lead_tasks" TO "anon";
GRANT ALL ON TABLE "public"."lead_tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_tasks" TO "service_role";



GRANT ALL ON TABLE "public"."message_attempts" TO "anon";
GRANT ALL ON TABLE "public"."message_attempts" TO "authenticated";
GRANT ALL ON TABLE "public"."message_attempts" TO "service_role";



GRANT ALL ON TABLE "public"."message_queue" TO "anon";
GRANT ALL ON TABLE "public"."message_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."message_queue" TO "service_role";



GRANT ALL ON TABLE "public"."message_templates" TO "anon";
GRANT ALL ON TABLE "public"."message_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."message_templates" TO "service_role";



GRANT ALL ON TABLE "public"."pipeline_stages" TO "anon";
GRANT ALL ON TABLE "public"."pipeline_stages" TO "authenticated";
GRANT ALL ON TABLE "public"."pipeline_stages" TO "service_role";



GRANT ALL ON TABLE "public"."source_brevo_campaign_recipients" TO "anon";
GRANT ALL ON TABLE "public"."source_brevo_campaign_recipients" TO "authenticated";
GRANT ALL ON TABLE "public"."source_brevo_campaign_recipients" TO "service_role";



GRANT ALL ON TABLE "public"."source_brevo_events" TO "anon";
GRANT ALL ON TABLE "public"."source_brevo_events" TO "authenticated";
GRANT ALL ON TABLE "public"."source_brevo_events" TO "service_role";



GRANT ALL ON TABLE "public"."source_colombia_contacts" TO "anon";
GRANT ALL ON TABLE "public"."source_colombia_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."source_colombia_contacts" TO "service_role";



GRANT ALL ON TABLE "public"."source_manual_leads" TO "anon";
GRANT ALL ON TABLE "public"."source_manual_leads" TO "authenticated";
GRANT ALL ON TABLE "public"."source_manual_leads" TO "service_role";



GRANT ALL ON TABLE "public"."source_todoc_contacts" TO "anon";
GRANT ALL ON TABLE "public"."source_todoc_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."source_todoc_contacts" TO "service_role";



GRANT ALL ON TABLE "public"."v_brevo_email_summary" TO "anon";
GRANT ALL ON TABLE "public"."v_brevo_email_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."v_brevo_email_summary" TO "service_role";



GRANT ALL ON TABLE "public"."v_brevo_summary" TO "anon";
GRANT ALL ON TABLE "public"."v_brevo_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."v_brevo_summary" TO "service_role";



GRANT ALL ON TABLE "public"."v_growth_master" TO "anon";
GRANT ALL ON TABLE "public"."v_growth_master" TO "authenticated";
GRANT ALL ON TABLE "public"."v_growth_master" TO "service_role";



GRANT ALL ON TABLE "public"."v_leads_base_union" TO "anon";
GRANT ALL ON TABLE "public"."v_leads_base_union" TO "authenticated";
GRANT ALL ON TABLE "public"."v_leads_base_union" TO "service_role";



GRANT ALL ON TABLE "public"."v_leads_unified" TO "anon";
GRANT ALL ON TABLE "public"."v_leads_unified" TO "authenticated";
GRANT ALL ON TABLE "public"."v_leads_unified" TO "service_role";



GRANT ALL ON TABLE "public"."v_master_contacts_staging" TO "anon";
GRANT ALL ON TABLE "public"."v_master_contacts_staging" TO "authenticated";
GRANT ALL ON TABLE "public"."v_master_contacts_staging" TO "service_role";



GRANT ALL ON TABLE "public"."webhook_endpoints" TO "anon";
GRANT ALL ON TABLE "public"."webhook_endpoints" TO "authenticated";
GRANT ALL ON TABLE "public"."webhook_endpoints" TO "service_role";



GRANT ALL ON TABLE "public"."webhook_events" TO "anon";
GRANT ALL ON TABLE "public"."webhook_events" TO "authenticated";
GRANT ALL ON TABLE "public"."webhook_events" TO "service_role";



GRANT ALL ON TABLE "public"."workspace_integrations" TO "anon";
GRANT ALL ON TABLE "public"."workspace_integrations" TO "authenticated";
GRANT ALL ON TABLE "public"."workspace_integrations" TO "service_role";



GRANT ALL ON TABLE "public"."workspace_secrets" TO "anon";
GRANT ALL ON TABLE "public"."workspace_secrets" TO "authenticated";
GRANT ALL ON TABLE "public"."workspace_secrets" TO "service_role";



GRANT ALL ON TABLE "public"."workspaces" TO "anon";
GRANT ALL ON TABLE "public"."workspaces" TO "authenticated";
GRANT ALL ON TABLE "public"."workspaces" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































