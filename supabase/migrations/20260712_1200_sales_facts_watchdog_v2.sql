-- Appril CRM — Hechos de venta sellados en BD + watchdog v2 (12-jul-2026)
--
-- (1) sales_facts: fuente única de precios y hechos medidos (DEC-019) que el
--     prompt del agente comercial lee en runtime — editable sin redeploy.
--     El agente conserva defaults hardcodeados como fallback si la tabla no
--     responde (fail-safe: la venta nunca se bloquea por esto).
--     Tabla espejo en el Supabase del producto (misma tanda) para los prompts
--     de venta de appril-web (referidos y sales-handler IG/Messenger).
-- (2) agent_health_scan() v2: tres detecciones nuevas sobre lead_events —
--     · llm_error: el agente registró agent_llm_error (Anthropic caído/sin
--       saldo/429) — cierra la brecha del incidente del 12-jul-2026, donde
--       la cuenta agotada era invisible para el watchdog.
--     · wa_send_failure: wa_agent_reply con send_ok=false (Meta rechazó el
--       envío; antes contaba como "respondió" y wa_no_reply no disparaba).
--     · claim_flagged: el guard determinístico de cifras detectó un monto o
--       porcentaje fuera de la whitelist sellada en una respuesta enviada.
-- (3) app_config agent_reply_cap_24h: cap duro de respuestas del agente por
--     lead/24h (leído por whatsapp-agent; al alcanzarlo escala a humano).

-- ── (1) sales_facts ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.sales_facts (
  key        text PRIMARY KEY,
  value      text NOT NULL,
  notes      text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.sales_facts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sales_facts FROM anon, authenticated;

INSERT INTO public.sales_facts (key, value, notes) VALUES
  ('price_email_month',      '10',  'USD/mes plan Email'),
  ('price_email_year',       '79',  'USD/año plan Email'),
  ('price_wa_month',         '25',  'USD/mes plan WhatsApp'),
  ('price_wa_year',          '199', 'USD/año plan WhatsApp'),
  ('price_assistant_month',  '25',  'USD/mes adicional Asistente WA'),
  ('fact_reminder_response', 'Más de 8 de cada 10 pacientes RESPONDEN el recordatorio por WhatsApp. Su asistente deja de perseguirlos.', 'DEC-019 hecho medido'),
  ('fact_notice',            'Los que no pueden ir, avisan a tiempo: ese espacio se puede volver a llenar.', 'DEC-019 hecho medido'),
  ('fact_noshow',            'Las citas con recordatorio tienen cerca de 35% menos inasistencias que las que no lo tienen.', 'DEC-019 hecho medido'),
  ('fact_todoc',             'Appril nace de Todoc: diez años gestionando agendas médicas en la región, más de 2 millones de citas y más de 12.000 profesionales.', 'DEC-019 linaje Todoc')
ON CONFLICT (key) DO NOTHING;

-- ── (3) Cap de respuestas del agente por lead/24h ─────────────────────────────
INSERT INTO public.app_config (key, value) VALUES ('agent_reply_cap_24h', '30')
ON CONFLICT (key) DO NOTHING;

-- ── (2) agent_health_scan v2 ──────────────────────────────────────────────────
-- Idéntica a la v1 (20260701_1930) + detecciones 5, 6 y 7.
CREATE OR REPLACE FUNCTION public.agent_health_scan() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- 1) wa_reply sin wa_agent_reply del mismo lead en >5 min (ventana 5-30 min;
  --    se ignoran leads con agente pausado o handoff humano).
  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
  SELECT 'crm_wa_agent', 'wa_no_reply', e.id::text,
         jsonb_build_object('lead_id', e.lead_id, 'reply_at', e.created_at)
  FROM lead_events e
  JOIN leads_master l ON l.id = e.lead_id
  WHERE e.event_type = 'wa_reply'
    AND e.created_at BETWEEN now() - interval '30 minutes' AND now() - interval '5 minutes'
    AND l.agent_paused = false
    AND NOT EXISTS (
      SELECT 1 FROM lead_events r
      WHERE r.lead_id = e.lead_id
        AND r.event_type = 'wa_agent_reply'
        AND r.created_at >= e.created_at
    )
  ON CONFLICT (source, incident_type, coalesce(ref_id, '')) WHERE status IN ('open','notified') DO NOTHING;

  -- 2) Mensajes atascados en sending >10 min (bug conocido del sender).
  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
  SELECT 'message_queue', 'queue_stuck', q.id::text,
         jsonb_build_object('template_key', q.template_key, 'channel', q.channel, 'updated_at', q.updated_at)
  FROM message_queue q
  WHERE q.status = 'sending' AND q.updated_at < now() - interval '10 minutes'
  ON CONFLICT (source, incident_type, coalesce(ref_id, '')) WHERE status IN ('open','notified') DO NOTHING;

  -- 3) Pendientes vencidos >15 min (el cron del sender corre cada 2 min).
  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
  SELECT 'message_queue', 'queue_overdue', q.id::text,
         jsonb_build_object('template_key', q.template_key, 'channel', q.channel, 'scheduled_at', q.scheduled_at)
  FROM message_queue q
  WHERE q.status = 'pending' AND q.scheduled_at < now() - interval '15 minutes'
    AND q.template_key <> 'agent_health_alert'
  ON CONFLICT (source, incident_type, coalesce(ref_id, '')) WHERE status IN ('open','notified') DO NOTHING;

  -- 4) Racha de fallos de envío: >=3 errores en 20 min (un incidente por franja).
  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
  SELECT 'message_queue', 'send_failures', to_char(date_trunc('hour', now()), 'YYYY-MM-DD HH24:00'),
         jsonb_build_object('errors_20min', c.n)
  FROM (SELECT count(*) AS n FROM message_attempts
        WHERE status <> 'success' AND started_at > now() - interval '20 minutes') c
  WHERE c.n >= 3
  ON CONFLICT (source, incident_type, coalesce(ref_id, '')) WHERE status IN ('open','notified') DO NOTHING;

  -- 5) Error del LLM registrado por el agente (Anthropic caído, sin saldo, 429):
  --    incidente directo con causa explícita — no depende de la ventana de
  --    wa_no_reply ni deja adivinar si el problema es Meta, la cola o el LLM.
  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
  SELECT 'crm_wa_agent', 'llm_error', e.id::text,
         jsonb_build_object('lead_id', e.lead_id, 'at', e.created_at, 'error', left(e.event_value, 300))
  FROM lead_events e
  WHERE e.event_type = 'agent_llm_error'
    AND e.created_at > now() - interval '30 minutes'
  ON CONFLICT (source, incident_type, coalesce(ref_id, '')) WHERE status IN ('open','notified') DO NOTHING;

  -- 6) Respuesta del agente cuyo envío a Meta FALLÓ (send_ok=false): el turno
  --    existe como wa_agent_reply (por eso wa_no_reply no dispara) pero el lead
  --    nunca recibió nada.
  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
  SELECT 'crm_wa_agent', 'wa_send_failure', e.id::text,
         jsonb_build_object('lead_id', e.lead_id, 'at', e.created_at,
                            'error', left(coalesce(e.metadata->>'send_error', ''), 300))
  FROM lead_events e
  WHERE e.event_type = 'wa_agent_reply'
    AND (e.metadata->>'send_ok') = 'false'
    AND e.created_at > now() - interval '30 minutes'
  ON CONFLICT (source, incident_type, coalesce(ref_id, '')) WHERE status IN ('open','notified') DO NOTHING;

  -- 7) Cifra fuera de la whitelist sellada en una respuesta YA enviada (guard
  --    determinístico del agente): posible precio/porcentaje inventado. No se
  --    bloqueó el envío (flag-only); el incidente existe para que un humano
  --    revise la conversación.
  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
  SELECT 'crm_wa_agent', 'claim_flagged', e.id::text,
         jsonb_build_object('lead_id', e.lead_id, 'at', e.created_at,
                            'tokens', e.metadata->'tokens', 'snippet', left(e.event_value, 200))
  FROM lead_events e
  WHERE e.event_type = 'claim_flagged'
    AND e.created_at > now() - interval '60 minutes'
  ON CONFLICT (source, incident_type, coalesce(ref_id, '')) WHERE status IN ('open','notified') DO NOTHING;

  -- Auto-resolución: wa_no_reply cuya respuesta llegó después; stuck/overdue ya drenados.
  UPDATE agent_health_incidents i SET status = 'resolved', resolved_at = now()
  WHERE i.status IN ('open','notified') AND i.incident_type = 'wa_no_reply'
    AND EXISTS (
      SELECT 1 FROM lead_events r
      WHERE r.lead_id = (i.details->>'lead_id')::uuid
        AND r.event_type = 'wa_agent_reply'
        AND r.created_at >= (i.details->>'reply_at')::timestamptz
    );

  UPDATE agent_health_incidents i SET status = 'resolved', resolved_at = now()
  WHERE i.status IN ('open','notified') AND i.incident_type IN ('queue_stuck','queue_overdue')
    AND NOT EXISTS (
      SELECT 1 FROM message_queue q
      WHERE q.id::text = i.ref_id AND q.status IN ('sending','pending')
    );
END $$;
