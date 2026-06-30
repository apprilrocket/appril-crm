-- ════════════════════════════════════════════════════════════════════════════
-- Endurecer guarda de WhatsApp en el motor de automatizaciones
-- ════════════════════════════════════════════════════════════════════════════
-- Problema: automation_tick() solo exigía `can_whatsapp AND phone IS NOT NULL`
-- para encolar WhatsApp. can_whatsapp=true existe en ~19k leads pero la mayoría
-- tiene teléfono malformado (sin formato E.164), por lo que un número inválido
-- podía entrar a message_queue por esta vía (las rutas de campañas e inbox-send
-- SÍ validan E.164; esta no).
--
-- Fix: agregar el mismo regex E.164 que usa crm_launch_campaign / inbox-send.
-- Resultado: "sin teléfono E.164 válido → no se encola nada por WhatsApp"
-- aplica de forma uniforme en TODAS las rutas. Un número inválido cae al else
-- y se registra como 'automation_send_skipped'. Email queda igual.
--
-- Único cambio funcional vs. la definición vigente: la condición de la línea
-- del send_whatsapp (se añade `and v_to ~ '^\+[1-9][0-9]{7,14}$'`).

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
          -- send_whatsapp ahora exige teléfono en formato E.164 (igual que campañas/inbox).
          if (node_type = 'send_email' and coalesce(lead.can_email,false) and v_to is not null)
             or (node_type = 'send_whatsapp' and coalesce(lead.can_whatsapp,false) and v_to is not null
                 and v_to ~ '^\+[1-9][0-9]{7,14}$') then

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
