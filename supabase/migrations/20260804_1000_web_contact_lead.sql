-- ═══════════════════════════════════════════════════════════════════════════
-- CRM — Formulario "Quiero que me contacten" de www.appril.co → lead + outreach
-- (4-ago-2026; revisado por appril-data-expert: "aprobar con cambios", todos
-- los cambios A-I incorporados)
--
-- La home nueva de www.appril.co tiene un modal "Quiero que me contacten"
-- (nombre, WhatsApp, especialidad). Hasta ahora el submit solo abría wa.me y
-- el lead se perdía si la persona no enviaba el mensaje. Este cableado:
--
--   1. RPC pública `submit_web_contact_lead` (anon A PROPÓSITO — funnel
--      público, mismo estatus que submit_discovery_lead): crea/reusa el lead
--      en leads_master (dedup por teléfono RIGHT-10 del workspace, patrón
--      crm_upsert_referral_lead) y emite `web_contact_requested` (+
--      `contact_submitted`, precedente Discovery: hand-raise pesa y califica).
--   2. El evento dispara trg_auto_enroll → automation nueva
--      "Web · Quiero que me contacten": UN toque inmediato con el template
--      `contacto_web_es` y sale. exit_on_reply=true (la respuesta humana
--      corta el run y la conversación queda con el whatsapp-agent comercial);
--      show_in_inbox=true. enroll_lead_in_automation garantiza además máx 1
--      envío por lead PARA SIEMPRE (never-re-enroll sin allow_reenroll).
--   3. Anti-abuso: cap global 30 leads web_contact/hora (silencioso), nombre
--      saneado a whitelist (sin URLs/dígitos → sin inyección en el {{1}} del
--      template), evento deduplicado a 7 días, anti-enumeración (el anon solo
--      recibe {'ok':true/false} sin lead_id), advisory lock anti-race.
--
-- Consentimiento (decisión implementada, reversible): el formulario es un
-- opt-in explícito fresco → en leads NUEVOS whatsapp_opted_in=true; en leads
-- EXISTENTES se re-abre can_whatsapp/whatsapp_opted_in SOLO si el lead no
-- tiene evento `unsubscribed` (una BAJA real se respeta SIEMPRE). Sin esto,
-- toda la base importada de Todoc (can_whatsapp=false por default de
-- importación, no por BAJA) pediría contacto y nadie la contactaría jamás
-- (automation_send_skipped silencioso).
--
-- Cortesía: el evento NO se emite si el lead es cliente (`converted`) ni si
-- hay conversación humana viva (<72h) con el agente — en ambos casos el lead
-- queda actualizado en el CRM pero sin template frío en mitad de la charla.
--
-- ⚠️ PENDIENTE DEL DUEÑO: crear y aprobar en la WABA comercial el template
-- `contacto_web_es` (idioma es, 1 variable {{1}}=nombre en el BODY). Copy
-- propuesto (ajustable en Meta sin tocar esta migración):
--   «Hola {{1}}, le saludamos de Appril. Nos pidió que le contactáramos
--    desde appril.co: con gusto le mostramos cómo Appril puede ayudarle a
--    gestionar su agenda. ¿Le parece si conversamos por aquí?»
-- Hasta que exista, los envíos fallarán con #132001 → resetear esas filas de
-- message_queue a 'pending' (runbook de los templates de referidos, 27-jul).
-- El template se siembra 'active' A PROPÓSITO: en 'draft' automation_tick
-- saltaría el nodo EN SILENCIO y el toque se perdería para siempre.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 0) Índices (H): la RPC anon hacía 2 seq scans por llamada ───────────────
CREATE INDEX IF NOT EXISTS ix_leads_phone_r10
  ON public.leads_master (workspace_id, right(regexp_replace(coalesce(phone,''),'[^0-9]','','g'), 10));
CREATE INDEX IF NOT EXISTS ix_leads_web_contact_recent
  ON public.leads_master (created_at) WHERE source = 'web_contact';

-- ── 1) RPC pública ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.submit_web_contact_lead(
  p_full_name text,
  p_phone     text,
  p_specialty text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_ws     uuid := 'e2096477-fa6a-4b8f-a8b3-bd46ad720167';
  -- (D) whitelist: letras/espacios/'- — mata URLs y dígitos en el {{1}}
  -- (sin '.' a propósito: "bit.ly" sobreviviría y WhatsApp linkifica dominios)
  v_name   text := left(nullif(btrim(regexp_replace(
                     regexp_replace(coalesce(p_full_name, ''), '[^[:alpha:][:space:]''-]', ' ', 'g'),
                     '\s+', ' ', 'g')), ''), 120);
  v_spec   text := left(nullif(trim(coalesce(p_specialty, '')), ''), 120);
  v_raw    text := trim(coalesce(p_phone, ''));
  v_digits text := regexp_replace(v_raw, '[^0-9]', '', 'g');
  v_e164   text;
  v_norm   text;
  v_lead   uuid;
  v_stage  text;
  v_had_baja boolean := false;
  v_live_convo boolean := false;
BEGIN
  IF v_name IS NULL OR length(v_name) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_name');
  END IF;

  -- E.164 (lección 30-jul: la cola exige E.164 o Meta no entrega):
  -- '+' explícito se respeta; 10 dígitos empezando por 3 = celular CO
  -- (mercado principal); 11-15 dígitos = país+número tecleado sin '+'.
  -- (C) 8-10 dígitos sin '+' que no sean celular CO se RECHAZAN (número
  -- local sin indicativo → adivinar fabrica E.164 de otro país).
  IF left(v_raw, 1) = '+' AND length(v_digits) BETWEEN 8 AND 15 THEN
    v_e164 := '+' || v_digits;
  ELSIF length(v_digits) = 10 AND left(v_digits, 1) = '3' THEN
    v_e164 := '+57' || v_digits;
  ELSIF length(v_digits) BETWEEN 11 AND 15 THEN
    v_e164 := '+' || v_digits;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_phone');
  END IF;
  v_norm := right(v_digits, 10);

  -- (I) anti-race: dos submits concurrentes del mismo teléfono = un solo lead
  PERFORM pg_advisory_xact_lock(hashtext('web_contact:' || v_norm));

  -- Cap de abuso: silencioso a propósito (no dar señal al atacante).
  IF (SELECT count(*) FROM leads_master
       WHERE workspace_id = v_ws AND source = 'web_contact'
         AND created_at > now() - interval '1 hour') >= 30 THEN
    RETURN jsonb_build_object('ok', true);
  END IF;

  -- Dedup por teléfono normalizado dentro del workspace (cualquier source).
  SELECT id, pipeline_stage INTO v_lead, v_stage FROM leads_master
   WHERE workspace_id = v_ws
     AND right(regexp_replace(coalesce(phone, ''), '[^0-9]', '', 'g'), 10) = v_norm
   ORDER BY created_at ASC LIMIT 1;

  IF v_lead IS NOT NULL THEN
    -- (A) re-opt-in por opt-in explícito fresco, SALVO BAJA real registrada.
    v_had_baja := EXISTS (SELECT 1 FROM lead_events
                           WHERE lead_id = v_lead AND event_type = 'unsubscribed');
    UPDATE leads_master SET
      full_name         = COALESCE(NULLIF(full_name, ''), v_name),
      specialization    = COALESCE(NULLIF(specialization, ''), v_spec),
      -- (B) teléfono legacy en formato local → E.164 (queue-sender no normaliza)
      phone             = CASE WHEN left(coalesce(phone, ''), 1) <> '+' THEN v_e164 ELSE phone END,
      can_whatsapp      = CASE WHEN v_had_baja THEN can_whatsapp ELSE true END,
      whatsapp_opted_in = CASE WHEN v_had_baja THEN whatsapp_opted_in ELSE true END,
      updated_at        = now()
    WHERE id = v_lead;
  ELSE
    INSERT INTO leads_master (
      workspace_id, full_name, phone, specialization, source,
      pipeline_stage, can_whatsapp, whatsapp_opted_in
    ) VALUES (
      v_ws, v_name, v_e164, v_spec, 'web_contact', 'new', true, true
    ) RETURNING id INTO v_lead;
    v_stage := 'new';
  END IF;

  -- (G) conversación humana viva con el agente (<72h) → sin template frío.
  v_live_convo := EXISTS (
    SELECT 1 FROM lead_events le
     WHERE le.lead_id = v_lead AND le.event_type = 'wa_reply'
       AND coalesce(le.metadata->>'auto_responder', '') <> 'true'
       AND le.created_at > now() - interval '72 hours');

  -- Evento de enrolamiento, deduplicado a 7 días. (E) clientes fuera.
  IF v_stage IS DISTINCT FROM 'converted' AND NOT v_live_convo AND NOT EXISTS (
    SELECT 1 FROM lead_events
     WHERE lead_id = v_lead AND event_type = 'web_contact_requested'
       AND created_at > now() - interval '7 days'
  ) THEN
    INSERT INTO lead_events (workspace_id, lead_id, event_type, event_value)
    VALUES (v_ws, v_lead, 'web_contact_requested', 'landing_home');
    -- (F) precedente Discovery: el hand-raise pesa en engagement y califica.
    INSERT INTO lead_events (workspace_id, lead_id, event_type, event_value)
    VALUES (v_ws, v_lead, 'contact_submitted', 'web_contact_form');
  END IF;

  -- Anti-enumeración: el cliente anónimo no recibe lead_id ni si fue dedup.
  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_web_contact_lead(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_web_contact_lead(text,text,text) TO anon, authenticated, service_role;

-- ── 2) Template (Meta: crear y aprobar contacto_web_es) ─────────────────────
INSERT INTO public.message_templates
  (workspace_id, template_key, name, channel, status, wa_template_name, wa_language, wa_components, variables, description)
VALUES
  ('e2096477-fa6a-4b8f-a8b3-bd46ad720167', 'contacto_web',
   'Web · Contacto solicitado', 'whatsapp', 'active',
   'contacto_web_es', 'es',
   '[{"type":"body","parameters":[{"type":"text","text":"{{nombre}}"}]}]'::jsonb,
   '["nombre"]'::jsonb,
   'Primer toque al lead que pidió contacto en el formulario de www.appril.co. Body {{1}}=nombre.')
ON CONFLICT DO NOTHING;

-- ── 3) Automation de outreach (1 toque, sale ante respuesta humana) ─────────
INSERT INTO public.automations (workspace_id, name, description, trigger_type, trigger_config, status, flow)
SELECT 'e2096477-fa6a-4b8f-a8b3-bd46ad720167',
       'Web · Quiero que me contacten',
       'Lead del formulario de contacto de www.appril.co: un toque inmediato por WhatsApp (contacto_web_es). La respuesta cae al agente comercial; exit_on_reply corta el run ante señal humana; never-re-enroll = máx 1 toque por lead.',
       'event',
       '{"event_type":"web_contact_requested","exit_on_reply":true,"show_in_inbox":true}'::jsonb,
       'active',
       '{
         "nodes": [
           {"id":"t","type":"trigger","position":{"x":0,"y":0},"data":{"label":"Contacto solicitado en la web"}},
           {"id":"s1","type":"send_whatsapp","position":{"x":0,"y":120},"data":{"templateKey":"contacto_web","label":"Primer toque"}},
           {"id":"x","type":"exit","position":{"x":0,"y":240},"data":{"label":"Fin"}}
         ],
         "edges": [
           {"id":"e1","source":"t","target":"s1"},
           {"id":"e2","source":"s1","target":"x"}
         ]
       }'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM public.automations WHERE name = 'Web · Quiero que me contacten');
