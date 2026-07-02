-- ════════════════════════════════════════════════════════════════════════════
-- submit_discovery_lead: precedencia de identidad dl → teléfono → crear
-- ════════════════════════════════════════════════════════════════════════════
-- Problema: hoy el lead se resuelve SOLO por teléfono. Si el destinatario del
-- email no tiene teléfono registrado (o ingresa otro), se CREA un lead nuevo en
-- vez de enlazar el Discovery al lead que recibió el email → duplicado.
--
-- Fix (buena práctica, no parche): el `dl` es un token único POR-LEAD en un link
-- único enviado solo a esa persona → señal de identidad de alta confianza.
-- Precedencia de resolución de identidad:
--   1) dl (token por-lead)  →  2) teléfono  →  3) crear nuevo
-- Y al resolver por dl, se enriquece el teléfono del lead si estaba vacío.
--
-- NO cambia: scoring, copy, número de preguntas, eventos, followup gate, RETURN.
-- Solo: + variable v_dl, + lookup por dl antes del lookup por teléfono,
--       + `phone = COALESCE(phone, v_whatsapp)` en la rama UPDATE.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.submit_discovery_lead(input jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

  -- Identidad: token dl por-lead (del email). Viene en input->>'dl'; fallback: extraer de page_url.
  v_dl            text := COALESCE(
                            nullif(trim(input->>'dl'), ''),
                            (regexp_match(COALESCE(input->>'page_url',''), '[?&]dl=([a-fA-F0-9]{32})'))[1]
                          );

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

  v_norm            jsonb;
  v_warnings        jsonb;
  v_score_input_dbg jsonb;
  v_scoring_version text;
  v_event_meta      jsonb;

  v_immediate       boolean;
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

  v_norm     := public.normalize_discovery_score_inputs(
                  v_q_volume, v_q_lost, v_q_intent, v_q_urgency, v_q_ticket, v_q_digital);
  v_warnings := COALESCE(v_norm->'warnings', '[]'::jsonb);

  v_score_input_dbg := jsonb_build_object(
    'received', jsonb_build_object(
      'vol', v_q_volume, 'lost', v_q_lost, 'intent', v_q_intent,
      'urgency', v_q_urgency, 'ticket', v_q_ticket, 'digital', v_q_digital
    ),
    'normalized', jsonb_build_object(
      'vol', v_norm->>'vol', 'lost', v_norm->>'lost', 'intent', v_norm->>'intent',
      'urgency', v_norm->>'urgency', 'ticket', v_norm->>'ticket', 'digital', v_norm->>'digital'
    ),
    'warnings', v_warnings
  );

  v_scoring_version := COALESCE(input->>'scoring_version', 'discovery_v1_compat');

  v_score_result := public.calculate_discovery_score(
    v_q_volume, v_q_lost, v_q_intent, v_q_urgency, v_q_ticket, v_q_digital
  );

  v_segment := v_score_result->>'segment';

  -- ── Resolución de identidad: 1) dl → 2) teléfono → 3) crear ────────────────
  IF v_dl IS NOT NULL THEN
    SELECT id INTO v_lead_id
    FROM public.leads_master
    WHERE workspace_id = v_workspace_id AND dl_token = v_dl
    LIMIT 1;
  END IF;

  IF v_lead_id IS NULL THEN
    SELECT id INTO v_lead_id
    FROM public.leads_master
    WHERE workspace_id = v_workspace_id AND phone = v_whatsapp
    LIMIT 1;
  END IF;

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
      phone              = COALESCE(phone, v_whatsapp),   -- enriquece teléfono si el lead (resuelto por dl) no lo tenía
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
    utm_content,          utm_term,              landing_url,
    legacy_lead_score,    scoring_version,       score_input_debug,
    risk_dominant,        risk_evidence,
    recommended_action,
    main_pain,            main_pains,
    selected_currency,
    primary_cta_key,      primary_cta_label
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
    COALESCE(input->>'page_url', 'https://discovery.appril.co'),
    (v_score_result->>'score')::integer,
    v_scoring_version,
    v_score_input_dbg,
    v_findings->>'risk_dominant',
    v_findings->'risk_evidence',
    v_score_result->>'recommended_action',
    input->>'main_pain',
    input->'main_pains',
    v_fe->'currency'->>'selected_currency',
    input->>'primary_cta_key',
    input->>'primary_cta_label'
  )
  RETURNING id INTO v_discovery_id;

  v_event_meta := jsonb_build_object(
    'discovery_lead_id', v_discovery_id,
    'score',             v_score_result->>'score',
    'segment',           v_segment,
    'classification',    v_score_result->>'lead_classification',
    'maturity',          v_maturity,
    'scoring_version',   v_scoring_version,
    'utm_campaign',      input->>'utm_campaign',
    'utm_source',        input->>'utm_source'
  )
  || CASE WHEN jsonb_array_length(v_warnings) > 0
          THEN jsonb_build_object('score_warnings', v_warnings)
          ELSE '{}'::jsonb END;

  INSERT INTO public.lead_events (workspace_id, lead_id, event_type, event_channel, metadata)
  VALUES (
    v_workspace_id, v_lead_id,
    'discovery_form_submitted', 'funnel',
    v_event_meta
  );

  v_immediate := lower(coalesce(
    public._discovery_cfg('app.settings.discovery_whatsapp_immediate_followup_enabled',
                          'discovery_whatsapp_immediate_followup_enabled'),
    'false')) = 'true';

  IF v_immediate THEN
    v_template_key := CASE v_segment
      WHEN 'SUPER_HOT' THEN 'super_hot_intro_wa'
      WHEN 'HOT'       THEN 'hot_followup_wa'
      ELSE                  'warm_wa_if_opened'
    END;

    INSERT INTO public.message_queue (
      workspace_id, lead_id, template_key, channel,
      to_address, payload, status, scheduled_at
    ) VALUES (
      v_workspace_id, v_lead_id, v_template_key, 'whatsapp',
      v_whatsapp, jsonb_build_object('full_name', split_part(v_full_name, ' ', 1)),
      'pending', now()
    )
    RETURNING id INTO v_queue_id;

    INSERT INTO public.lead_events (workspace_id, lead_id, event_type, event_channel, metadata)
    VALUES (
      v_workspace_id, v_lead_id,
      'message_queued', 'whatsapp',
      jsonb_build_object(
        'message_queue_id', v_queue_id,
        'template_key',     v_template_key,
        'discovery_lead_id', v_discovery_id,
        'trigger',          'immediate'
      )
    );
  ELSE
    v_template_key := NULL;
    v_queue_id     := NULL;
    INSERT INTO public.lead_events (workspace_id, lead_id, event_type, event_channel, metadata)
    VALUES (
      v_workspace_id, v_lead_id,
      'followup_skipped', 'whatsapp',
      jsonb_build_object(
        'stage',             'immediate',
        'reason',            'flag_disabled',
        'discovery_lead_id', v_discovery_id,
        'segment',           v_segment
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok',                  true,
    'discovery_lead_id',   v_discovery_id,
    'lead_id',             v_lead_id,
    'lead_score',          (v_score_result->>'score')::integer,
    'legacy_lead_score',   (v_score_result->>'score')::integer,
    'scoring_version',     v_scoring_version,
    'lead_classification', v_score_result->>'lead_classification',
    'marketing_segment',   v_segment,
    'agenda_maturity_level', v_maturity,
    'recommended_action',  v_score_result->>'recommended_action',
    'annual_lost_revenue', v_annual_lost,
    'annual_admin_hours',  (v_fe->>'annual_admin_hours')::numeric,
    'admin_cost_annual',   (v_fe->>'admin_cost_annual')::numeric,
    'hidden_cost_total',   v_hidden_cost,
    'immediate_whatsapp',  v_immediate,
    'queued_message_id',   v_queue_id,
    'template_key',        v_template_key,
    'score_warnings',      v_warnings,
    'scheduled_at',        now()
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;
