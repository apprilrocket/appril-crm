-- SNAPSHOT DE ROLLBACK — submit_discovery_lead(jsonb) — versión VIVA antes de aplicar 20260629_1500
-- Capturado de producción (hwiocriejizjdqqcfrsj) vía pg_get_functiondef.
-- Para revertir: ejecutar este CREATE OR REPLACE tal cual.
CREATE OR REPLACE FUNCTION public.submit_discovery_lead(input jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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

  v_template_key := CASE v_segment
    WHEN 'SUPER_HOT' THEN 'super_hot_intro_wa'
    WHEN 'HOT'       THEN 'hot_followup_wa'
    ELSE                  'warm_wa_if_opened'
  END;

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
$function$;
