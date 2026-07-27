-- ═══════════════════════════════════════════════════════════════════════════
-- Referidos · Contacto garantizado (27-jul-2026)
--
-- Problema: los referidos que no respondían (o cuyo "reply" era el contestador
-- automático de su propio consultorio) morían en silencio tras la invitación
-- inicial, los leads SELF ("YO" del NPS) jamás recibían contacto proactivo del
-- CRM, y NADA de esto se veía en el inbox (trg_attach_message_to_campaign les
-- cuelga campaign_id y inbox_threads excluía todo lo que tuviera campaña).
--
-- Piezas:
--   1. lead_var_value: variables referido_nombre / referidor_nombre.
--   2. eval_run_condition: condición nueva human_wa_replied (excluye replies
--      con metadata.auto_responder=true — el whatsapp-agent los sella desde
--      su versión del 27-jul).
--   3. auto_advance_pipeline: un auto-responder ya NO avanza el stage a
--      qualified.
--   4. auto_exit_runs_on_human_signal: respuesta humana / account_created /
--      converted / BAJA → cierra al instante los runs de automations con
--      trigger_config.exit_on_reply=true (sin esperar al próximo condition).
--   5. Templates nuevos: referido_seguimiento, referido_ultimo_toque,
--      self_mes_gratis, self_ultimo_toque (los 4 wa_template_name *_es deben
--      existir APROBADOS en Meta; hasta entonces un envío falla con #132001 y
--      se recupera re-encolando — mismo procedimiento que José Daniel 27-jul).
--   6. Automations "Referido · Seguimiento sin respuesta" (día 3 + día 7) y
--      "Self · Rescate del mes gratis" (24h + día 4), enroladas por evento.
--   7. enqueue_referral_invite v2: emite referral_invited al encolar la
--      invitación y self_lead_created para appril_nps_self (dispara el
--      auto-enrolamiento existente auto_enroll_on_event).
--   8. inbox_threads v2: los envíos del trigger de referidos y de automations
--      marcadas show_in_inbox=true SÍ aparecen en el inbox (pedido del dueño:
--      "quiero que todos se vean en el CRM").
--   9. Backfill: enrola los referidos/selfs de julio sin respuesta HUMANA y
--      re-encola la invitación fallida de la Dra. Lindeman (token 8-jul).
--
-- Cadencia aprobada por el dueño (27-jul): referidos día 3 + día 7 (máx 3
-- toques totales); selfs 24h + día 4. Stops: respuesta humana, BAJA,
-- account_created. Los selfs del backfill arrancan con +48h de gracia para
-- que las plantillas de Meta alcancen a aprobarse.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1) Variables de template para referidos ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.lead_var_value(p_lead leads_master, p_var text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case p_var
    when 'nombre'           then coalesce(nullif(p_lead.first_name, ''), nullif(split_part(p_lead.full_name, ' ', 1), ''), 'Doctor(a)')
    when 'nombre_completo'  then coalesce(p_lead.full_name, 'Doctor(a)')
    when 'full_name'        then coalesce(p_lead.full_name, 'Doctor(a)')
    when 'email'            then coalesce(p_lead.email, '')
    when 'ciudad'           then coalesce(p_lead.city, '')
    when 'city'             then coalesce(p_lead.city, '')
    when 'especialidad'     then coalesce(p_lead.specialization, '')
    when 'referido_nombre'  then coalesce(nullif(trim(p_lead.full_name), ''), 'Doctor(a)')
    when 'referidor_nombre' then coalesce(nullif(trim(p_lead.referred_by_name), ''), 'un colega')
    else ''
  end;
$function$;

-- ── 2) Condición human_wa_replied ───────────────────────────────────────────
-- Igual a wa_replied (con matching por variantes de teléfono) pero excluyendo
-- los wa_reply sellados como contestador automático.
CREATE OR REPLACE FUNCTION public.eval_run_condition(p_lead_id uuid, p_run_started timestamp with time zone, p_kind text, p_value text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
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
    when 'human_wa_replied' then exists (
      select 1 from lead_events le
       where le.event_type = 'wa_reply' and le.created_at >= p_run_started
         and coalesce(le.metadata->>'auto_responder','') <> 'true'
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
$function$;

-- ── 3) Un auto-responder no avanza el pipeline ──────────────────────────────
CREATE OR REPLACE FUNCTION public.auto_advance_pipeline()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  target_stage text;
  l record;
  cur_pos int;
  new_pos int;
begin
  if new.lead_id is null then return new; end if;

  -- Contestador automático del consultorio del lead: no es un humano, no
  -- puede calificar al lead (antes lo subía a 'qualified').
  if new.event_type = 'wa_reply' and coalesce(new.metadata->>'auto_responder','') = 'true' then
    return new;
  end if;

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
$function$;

-- ── 4) Señal humana → cerrar runs de seguimiento al instante ────────────────
CREATE OR REPLACE FUNCTION public.auto_exit_runs_on_human_signal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
begin
  if new.lead_id is null then return new; end if;
  if not (
    (new.event_type = 'wa_reply' and coalesce(new.metadata->>'auto_responder','') <> 'true')
    or new.event_type in ('account_created','converted','unsubscribed')
  ) then
    return new;
  end if;

  update automation_runs ar
     set status = 'completed',
         exit_reason = 'human_signal_' || new.event_type,
         finished_at = now()
    from automations a
   where a.id = ar.automation_id
     and ar.lead_id = new.lead_id
     and ar.status = 'active'
     and coalesce((a.trigger_config->>'exit_on_reply')::boolean, false);

  return new;
end;
$function$;

DROP TRIGGER IF EXISTS trg_auto_exit_on_human_signal ON public.lead_events;
CREATE TRIGGER trg_auto_exit_on_human_signal
  AFTER INSERT ON public.lead_events
  FOR EACH ROW EXECUTE FUNCTION public.auto_exit_runs_on_human_signal();

-- ── 5) Templates de seguimiento (Meta: crear los 4 *_es y aprobarlos) ───────
INSERT INTO public.message_templates
  (workspace_id, template_key, name, channel, status, wa_template_name, wa_language, wa_components, variables, description)
VALUES
  ('e2096477-fa6a-4b8f-a8b3-bd46ad720167', 'referido_seguimiento',
   'Referido · Seguimiento día 3', 'whatsapp', 'active',
   'referido_seguimiento_es', 'es',
   '[{"type":"header","parameters":[{"type":"text","text":"{{referido_nombre}}"}]},
     {"type":"body","parameters":[{"type":"text","text":"{{referidor_nombre}}"}]}]'::jsonb,
   '["referido_nombre","referidor_nombre"]'::jsonb,
   'Seguimiento al referido que no respondió la invitación (día 3). Header={{referido_nombre}}, Body={{referidor_nombre}}, quick replies de interés.'),
  ('e2096477-fa6a-4b8f-a8b3-bd46ad720167', 'referido_ultimo_toque',
   'Referido · Último toque día 7', 'whatsapp', 'active',
   'referido_ultimo_toque_es', 'es',
   '[{"type":"header","parameters":[{"type":"text","text":"{{referido_nombre}}"}]},
     {"type":"body","parameters":[{"type":"text","text":"{{referidor_nombre}}"}]}]'::jsonb,
   '["referido_nombre","referidor_nombre"]'::jsonb,
   'Último toque al referido sin respuesta (día 7): cierra la secuencia dejando el mes gratis reservado.'),
  ('e2096477-fa6a-4b8f-a8b3-bd46ad720167', 'self_mes_gratis',
   'Self · Rescate mes gratis 24h', 'whatsapp', 'active',
   'self_mes_gratis_es', 'es',
   '[{"type":"header","parameters":[{"type":"text","text":"{{nombre}}"}]}]'::jsonb,
   '["nombre"]'::jsonb,
   'Rescate del lead SELF (respondió YO al NPS) sin actividad a las 24h: su mes gratis quedó reservado.'),
  ('e2096477-fa6a-4b8f-a8b3-bd46ad720167', 'self_ultimo_toque',
   'Self · Último toque día 4', 'whatsapp', 'active',
   'self_ultimo_toque_es', 'es',
   '[{"type":"header","parameters":[{"type":"text","text":"{{nombre}}"}]}]'::jsonb,
   '["nombre"]'::jsonb,
   'Último toque al SELF sin actividad (día 4): cierra la secuencia dejando el mes gratis reservado.')
ON CONFLICT DO NOTHING;

-- ── 6) Automations de seguimiento ───────────────────────────────────────────
-- exit_on_reply → las cierra el trigger (4) ante señal humana.
-- show_in_inbox → sus envíos aparecen en inbox_threads (8).
INSERT INTO public.automations (workspace_id, name, description, trigger_type, trigger_config, status, flow)
SELECT 'e2096477-fa6a-4b8f-a8b3-bd46ad720167',
       'Referido · Seguimiento sin respuesta',
       'Día 3 y día 7 tras la invitación referral: si no hay respuesta HUMANA (los contestadores automáticos no cuentan), toca de nuevo. Máx 3 toques totales; sale ante respuesta, cuenta creada o BAJA.',
       'event',
       '{"event_type":"referral_invited","exit_on_reply":true,"show_in_inbox":true}'::jsonb,
       'active',
       '{
         "nodes": [
           {"id":"t","type":"trigger","position":{"x":0,"y":0},"data":{"label":"Invitación referral enviada"}},
           {"id":"w1","type":"wait","position":{"x":0,"y":120},"data":{"amount":3,"unit":"days","label":"Esperar 3 días"}},
           {"id":"c1","type":"condition","position":{"x":0,"y":240},"data":{"kind":"human_wa_replied","value":null,"label":"¿Respondió un humano?"}},
           {"id":"s1","type":"send_whatsapp","position":{"x":0,"y":360},"data":{"templateKey":"referido_seguimiento","label":"Seguimiento día 3"}},
           {"id":"w2","type":"wait","position":{"x":0,"y":480},"data":{"amount":4,"unit":"days","label":"Esperar 4 días"}},
           {"id":"c2","type":"condition","position":{"x":0,"y":600},"data":{"kind":"human_wa_replied","value":null,"label":"¿Respondió un humano?"}},
           {"id":"s2","type":"send_whatsapp","position":{"x":0,"y":720},"data":{"templateKey":"referido_ultimo_toque","label":"Último toque día 7"}},
           {"id":"x","type":"exit","position":{"x":320,"y":400},"data":{"label":"Fin"}}
         ],
         "edges": [
           {"id":"e1","source":"t","target":"w1"},
           {"id":"e2","source":"w1","target":"c1"},
           {"id":"e3","source":"c1","sourceHandle":"yes","target":"x"},
           {"id":"e4","source":"c1","sourceHandle":"no","target":"s1"},
           {"id":"e5","source":"s1","target":"w2"},
           {"id":"e6","source":"w2","target":"c2"},
           {"id":"e7","source":"c2","sourceHandle":"yes","target":"x"},
           {"id":"e8","source":"c2","sourceHandle":"no","target":"s2"},
           {"id":"e9","source":"s2","target":"x"}
         ]
       }'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM public.automations WHERE name = 'Referido · Seguimiento sin respuesta');

INSERT INTO public.automations (workspace_id, name, description, trigger_type, trigger_config, status, flow)
SELECT 'e2096477-fa6a-4b8f-a8b3-bd46ad720167',
       'Self · Rescate del mes gratis',
       'Lead SELF (respondió YO al NPS del producto): si a las 24h no creó cuenta ni habló con el comercial, se le recuerda que su mes gratis quedó reservado; último toque al día 4. Sale ante respuesta humana, cuenta creada o BAJA.',
       'event',
       '{"event_type":"self_lead_created","exit_on_reply":true,"show_in_inbox":true}'::jsonb,
       'active',
       '{
         "nodes": [
           {"id":"t","type":"trigger","position":{"x":0,"y":0},"data":{"label":"Lead SELF creado"}},
           {"id":"w1","type":"wait","position":{"x":0,"y":120},"data":{"amount":24,"unit":"hours","label":"Esperar 24h"}},
           {"id":"c0","type":"condition","position":{"x":0,"y":240},"data":{"kind":"event_occurred","value":"account_created","label":"¿Creó cuenta?"}},
           {"id":"c1","type":"condition","position":{"x":0,"y":360},"data":{"kind":"human_wa_replied","value":null,"label":"¿Habló con el comercial?"}},
           {"id":"s1","type":"send_whatsapp","position":{"x":0,"y":480},"data":{"templateKey":"self_mes_gratis","label":"Rescate 24h"}},
           {"id":"w2","type":"wait","position":{"x":0,"y":600},"data":{"amount":3,"unit":"days","label":"Esperar 3 días"}},
           {"id":"c2","type":"condition","position":{"x":0,"y":720},"data":{"kind":"event_occurred","value":"account_created","label":"¿Creó cuenta?"}},
           {"id":"c3","type":"condition","position":{"x":0,"y":840},"data":{"kind":"human_wa_replied","value":null,"label":"¿Habló con el comercial?"}},
           {"id":"s2","type":"send_whatsapp","position":{"x":0,"y":960},"data":{"templateKey":"self_ultimo_toque","label":"Último toque día 4"}},
           {"id":"x","type":"exit","position":{"x":320,"y":500},"data":{"label":"Fin"}}
         ],
         "edges": [
           {"id":"e1","source":"t","target":"w1"},
           {"id":"e2","source":"w1","target":"c0"},
           {"id":"e3","source":"c0","sourceHandle":"yes","target":"x"},
           {"id":"e4","source":"c0","sourceHandle":"no","target":"c1"},
           {"id":"e5","source":"c1","sourceHandle":"yes","target":"x"},
           {"id":"e6","source":"c1","sourceHandle":"no","target":"s1"},
           {"id":"e7","source":"s1","target":"w2"},
           {"id":"e8","source":"w2","target":"c2"},
           {"id":"e9","source":"c2","sourceHandle":"yes","target":"x"},
           {"id":"e10","source":"c2","sourceHandle":"no","target":"c3"},
           {"id":"e11","source":"c3","sourceHandle":"yes","target":"x"},
           {"id":"e12","source":"c3","sourceHandle":"no","target":"s2"},
           {"id":"e13","source":"s2","target":"x"}
         ]
       }'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM public.automations WHERE name = 'Self · Rescate del mes gratis');

-- ── 7) enqueue_referral_invite v2: eventos de enrolamiento ──────────────────
-- referral_invited y self_lead_created disparan auto_enroll_on_event (ya
-- existente) hacia las automations de arriba.
CREATE OR REPLACE FUNCTION public.enqueue_referral_invite()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      -- evento de enrolamiento del seguimiento día 3 / día 7
      insert into public.lead_events (workspace_id, lead_id, event_type, event_value, metadata)
      values (
        coalesce(new.workspace_id, 'e2096477-fa6a-4b8f-a8b3-bd46ad720167'::uuid),
        new.id, 'referral_invited', 'referido_invitacion',
        jsonb_build_object('via', 'appril_referral_trigger')
      );
    end if;
  elsif new.source = 'appril_nps_self' then
    -- el SELF ya está conversando con el agente del producto; aquí solo se
    -- siembra el evento que lo enrola en el rescate de 24h
    insert into public.lead_events (workspace_id, lead_id, event_type, event_value, metadata)
    values (
      coalesce(new.workspace_id, 'e2096477-fa6a-4b8f-a8b3-bd46ad720167'::uuid),
      new.id, 'self_lead_created', new.source,
      jsonb_build_object('via', 'appril_referral_trigger')
    );
  end if;
  return new;
end;
$function$;

-- ── 8) inbox_threads v2: los referidos y sus seguimientos SÍ se ven ─────────
-- Los envíos del trigger de referidos llevan campaign_id (se lo cuelga
-- trg_attach_message_to_campaign para stats) y quedaban excluidos del inbox.
-- Se incluyen ahora explícitamente, igual que los envíos de automations
-- marcadas con trigger_config.show_in_inbox=true. Los blasts de campaña y el
-- resto de automations siguen excluidos.
CREATE OR REPLACE FUNCTION public.inbox_threads(p_limit integer DEFAULT 50)
 RETURNS TABLE(lead_id uuid, full_name text, phone text, email text, marketing_segment text, pipeline_stage text, engagement_score integer, agent_paused boolean, last_inbound_at timestamp with time zone, last_inbound_text text, last_inbound_channel text, last_outbound_at timestamp with time zone, unread boolean, last_wa_reply_at timestamp with time zone, can_whatsapp boolean, can_email boolean, last_activity_at timestamp with time zone, last_outbound_text text)
 LANGUAGE sql
 STABLE
AS $function$
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
      -- 1:1 (manuales/directos), invitaciones de referidos y automations
      -- conversacionales marcadas show_in_inbox; los blasts siguen fuera.
      where q.status in ('sent', 'sending', 'pending')
        and (
          (q.campaign_id is null and q.automation_run_id is null)
          or q.triggered_by = 'appril_referral_trigger'
          or (q.automation_run_id is not null and exists (
            select 1 from automation_runs ar
            join automations a on a.id = ar.automation_id
            where ar.id = q.automation_run_id
              and coalesce((a.trigger_config->>'show_in_inbox')::boolean, false)
          ))
        )
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
$function$;

-- ── 9) Backfill julio + rescate de la invitación fallida (Dra. Lindeman) ────
-- Re-encolar la invitación que falló el 8-jul por el incidente del token WA
-- (la Dra. Lindeman nunca recibió el primer mensaje).
UPDATE public.message_queue
   SET status = 'pending', scheduled_at = now(), attempts = 0,
       last_error = null, claimed_at = null, updated_at = now()
 WHERE id = '2c25af7c-c827-4039-bbe1-e57ac4a2129d' AND status = 'failed';

-- Enrolar referidos/selfs de julio sin respuesta HUMANA (los contestadores
-- automáticos históricos no llevan flag → heurística de texto espejo de
-- isAutoResponder del agente). Excluye convertidos, BAJA y etapas terminales.
DO $$
declare
  r record;
  v_auto_ref  uuid;
  v_auto_self uuid;
begin
  select id into v_auto_ref  from public.automations where name = 'Referido · Seguimiento sin respuesta';
  select id into v_auto_self from public.automations where name = 'Self · Rescate del mes gratis';

  for r in
    select lm.id, lm.source
    from public.leads_master lm
    where lm.source in ('appril_referral','appril_nps_self')
      and lm.created_at >= '2026-07-01'
      and coalesce(lm.can_whatsapp, true)
      and coalesce(lm.pipeline_stage, 'new') not in ('converted','lost')
      and not exists (
        select 1 from public.lead_events le
        where le.lead_id = lm.id
          and le.event_type = 'wa_reply'
          and coalesce(le.metadata->>'auto_responder','') <> 'true'
          and lower(coalesce(le.event_value,'')) !~ '(gracias por (comunicarte|escribir|contactar|tu mensaje|escribirnos)|pronto nos pondremos en contacto|horario de atenci|mensaje.{0,4}automatic|fuera de(l)? horario|hemos recibido (tu|su) mensaje)'
      )
      and not exists (
        select 1 from public.lead_events le2
        where le2.lead_id = lm.id
          and le2.event_type in ('account_created','converted','unsubscribed')
      )
  loop
    perform public.enroll_lead_in_automation(
      case when r.source = 'appril_referral' then v_auto_ref else v_auto_self end,
      r.id
    );
  end loop;

  -- Gracia de 48h a los SELF del backfill: su primer toque sería a las 24h y
  -- las plantillas de Meta aún deben aprobarse.
  update public.automation_runs
     set next_run_at = now() + interval '48 hours'
   where automation_id = v_auto_self and status = 'active';
end $$;
