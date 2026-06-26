-- ════════════════════════════════════════════════════════════════════════════
-- Nombre de saludo: {{nombre}} = primer nombre (con override opcional)
-- ════════════════════════════════════════════════════════════════════════════
-- Aditivo. Una sola fuente de verdad para campañas y secuencias:
--   {{nombre}} = coalesce(first_name override, primer token de full_name, 'Doctor(a)')

-- 1) Columna de override (opcional). Si está vacía, se deriva del full_name.
ALTER TABLE public.leads_master
  ADD COLUMN IF NOT EXISTS first_name text;

COMMENT ON COLUMN public.leads_master.first_name IS
  'Nombre de saludo opcional. Si null/vacío, {{nombre}} se deriva del primer token de full_name.';

-- 2) lead_var_value: 'nombre' ahora prefiere first_name, luego deriva. El resto igual.
--    (motor de secuencias y campañas comparten esta función)
CREATE OR REPLACE FUNCTION public.lead_var_value(p_lead public.leads_master, p_var text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  select case p_var
    when 'nombre'          then coalesce(nullif(p_lead.first_name, ''), nullif(split_part(p_lead.full_name, ' ', 1), ''), 'Doctor(a)')
    when 'nombre_completo' then coalesce(p_lead.full_name, 'Doctor(a)')
    when 'full_name'       then coalesce(p_lead.full_name, 'Doctor(a)')
    when 'email'           then coalesce(p_lead.email, '')
    when 'ciudad'          then coalesce(p_lead.city, '')
    when 'city'            then coalesce(p_lead.city, '')
    when 'especialidad'    then coalesce(p_lead.specialization, '')
    else ''
  end;
$$;

-- 3) crm_launch_campaign: payload con full_name Y nombre (reusa lead_var_value).
CREATE OR REPLACE FUNCTION public.crm_launch_campaign(p_campaign_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c              campaigns%ROWTYPE;
  v_template     text;
  v_segments     text[];
  v_list_ids     uuid[];
  v_require_optin boolean;
  v_scheduled    timestamptz;
  v_audience     bigint;
  v_queued       bigint;
BEGIN
  SELECT * INTO c FROM campaigns WHERE id = p_campaign_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','campaign_not_found'); END IF;
  IF c.approved_at IS NULL THEN
    RETURN jsonb_build_object('error','not_approved',
      'detail','Falta aprobacion humana (campaigns.approved_at)');
  END IF;
  IF c.status NOT IN ('scheduled','draft') THEN
    RETURN jsonb_build_object('error','bad_status','status',c.status);
  END IF;

  v_template := c.template_keys[1];
  IF v_template IS NULL THEN RETURN jsonb_build_object('error','no_template'); END IF;

  v_segments := coalesce(
    (SELECT array_agg(x) FROM jsonb_array_elements_text(c.segment_filter->'marketing_segment') x), '{}');
  v_list_ids := coalesce(
    (SELECT array_agg(x::uuid) FROM jsonb_array_elements_text(c.segment_filter->'list_ids') x), '{}');
  v_require_optin := (c.channel = 'whatsapp')
    AND coalesce((c.segment_filter->>'allow_no_optin')::boolean, false) = false;
  v_scheduled := coalesce(c.scheduled_at, now());

  SELECT count(*) INTO v_audience
  FROM leads_master l
  WHERE l.workspace_id = c.workspace_id
    AND (coalesce(array_length(v_segments,1),0) = 0 OR l.marketing_segment = ANY(v_segments))
    AND (coalesce(array_length(v_list_ids,1),0) = 0 OR EXISTS (
          SELECT 1 FROM lead_list_members m WHERE m.lead_id = l.id AND m.list_id = ANY(v_list_ids)));

  WITH eligible AS (
    SELECT l.*
    FROM leads_master l
    WHERE l.workspace_id = c.workspace_id
      AND (coalesce(array_length(v_segments,1),0) = 0 OR l.marketing_segment = ANY(v_segments))
      AND (coalesce(array_length(v_list_ids,1),0) = 0 OR EXISTS (
            SELECT 1 FROM lead_list_members m WHERE m.lead_id = l.id AND m.list_id = ANY(v_list_ids)))
      AND (
        (c.channel = 'email'
          AND l.can_email AND l.email IS NOT NULL AND l.email LIKE '%@%')
        OR
        (c.channel = 'whatsapp'
          AND l.can_whatsapp AND l.phone IS NOT NULL
          AND l.phone ~ '^\+[1-9][0-9]{7,14}$'
          AND ((NOT v_require_optin) OR l.whatsapp_opted_in))
      )
  )
  INSERT INTO message_queue
    (workspace_id, lead_id, campaign_id, template_key, channel, to_address, payload, triggered_by, scheduled_at, status)
  SELECT
    c.workspace_id, e.id, c.id, v_template, c.channel,
    CASE WHEN c.channel = 'email' THEN e.email ELSE regexp_replace(e.phone, '^\+', '') END,
    jsonb_build_object('full_name', lead_var_value(e, 'full_name'), 'nombre', lead_var_value(e, 'nombre')),
    'campaign', v_scheduled, 'pending'
  FROM eligible e;
  GET DIAGNOSTICS v_queued = ROW_COUNT;

  UPDATE campaigns SET
    status = 'running',
    started_at = now(),
    stats = jsonb_build_object(
      'total', v_queued, 'queued', v_queued, 'sent', 0, 'failed', 0,
      'audience', v_audience, 'excluded', greatest(0, v_audience - v_queued),
      'optin_required', v_require_optin)
  WHERE id = p_campaign_id;

  RETURN jsonb_build_object(
    'queued', v_queued, 'audience', v_audience,
    'excluded', greatest(0, v_audience - v_queued));
END $$;

REVOKE ALL ON FUNCTION public.crm_launch_campaign(uuid) FROM anon, authenticated;
