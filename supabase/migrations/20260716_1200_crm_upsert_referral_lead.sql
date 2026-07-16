-- ═══════════════════════════════════════════════════════════════════════════
-- CRM — RPC idempotente de aterrizaje de referidos del producto (16-jul-2026)
--
-- El producto (growth loop NPS + tool save_referral del agente) empujaba
-- referidos con un POST crudo a /rest/v1/leads_master → cada push creaba una
-- fila nueva (sin dedup: leads_master tiene 1.566 teléfonos ya duplicados, un
-- índice único global es inviable), y un reintento duplicaba el lead. Además
-- las dos vías fijaban el consentimiento distinto (una true, otra false).
--
-- Esta RPC centraliza el aterrizaje: dedup por teléfono normalizado (últimos
-- 10 dígitos) dentro del workspace; si el lead ya existe lo REUSA (enriquece
-- solo campos vacíos, NUNCA toca el consentimiento → respeta un BAJA previo);
-- si es nuevo lo crea con consentimiento (whatsapp_opted_in=true, decisión del
-- dueño: el opt-out se maneja por mensajes/BAJA). Devuelve el lead_id (nuevo o
-- existente) para que el producto selle wa_referrals.crm_lead_id. Ser
-- idempotente hace SEGURO el reintento del barrido de pendientes.
-- La invitación WhatsApp (trigger enqueue_referral_invite AFTER INSERT para
-- source='appril_referral') sigue disparando solo en leads NUEVOS.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.crm_upsert_referral_lead(
  p_full_name         text,
  p_phone             text,
  p_source            text,
  p_referred_by_name  text  DEFAULT NULL,
  p_referred_by_phone text  DEFAULT NULL,
  p_appril_referral_id uuid DEFAULT NULL,
  p_referral_campaign text  DEFAULT NULL,
  p_email             text  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_ws   uuid := 'e2096477-fa6a-4b8f-a8b3-bd46ad720167';
  v_norm text := right(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), 10);
  v_email text := lower(nullif(trim(coalesce(p_email, '')), ''));
  v_existing uuid;
  v_id   uuid;
BEGIN
  -- Dedup: teléfono normalizado (≥7 dígitos) o, si no hay, email.
  IF length(v_norm) >= 7 THEN
    SELECT id INTO v_existing FROM leads_master
    WHERE workspace_id = v_ws
      AND right(regexp_replace(coalesce(phone, ''), '[^0-9]', '', 'g'), 10) = v_norm
    ORDER BY created_at ASC LIMIT 1;
  ELSIF v_email IS NOT NULL THEN
    SELECT id INTO v_existing FROM leads_master
    WHERE workspace_id = v_ws AND lower(email) = v_email
    ORDER BY created_at ASC LIMIT 1;
  END IF;

  IF v_existing IS NOT NULL THEN
    -- Reusar: enriquecer SOLO lo vacío; jamás tocar el consentimiento.
    UPDATE leads_master SET
      full_name          = COALESCE(NULLIF(full_name, ''), NULLIF(p_full_name, '')),
      referred_by_name   = COALESCE(NULLIF(referred_by_name, ''), p_referred_by_name),
      referred_by_phone  = COALESCE(NULLIF(referred_by_phone, ''), p_referred_by_phone),
      referral_campaign  = COALESCE(referral_campaign, p_referral_campaign),
      appril_referral_id = COALESCE(appril_referral_id, p_appril_referral_id),
      updated_at         = now()
    WHERE id = v_existing;
    RETURN jsonb_build_object('lead_id', v_existing, 'deduped', true);
  END IF;

  INSERT INTO leads_master (
    workspace_id, full_name, phone, email, source, pipeline_stage,
    can_whatsapp, whatsapp_opted_in,
    referred_by_name, referred_by_phone, referral_campaign, appril_referral_id
  ) VALUES (
    v_ws, NULLIF(p_full_name, ''), NULLIF(p_phone, ''), NULLIF(p_email, ''),
    p_source, 'new', true, true,
    p_referred_by_name, p_referred_by_phone, p_referral_campaign, p_appril_referral_id
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('lead_id', v_id, 'deduped', false);
END;
$$;

REVOKE ALL ON FUNCTION public.crm_upsert_referral_lead(text,text,text,text,text,uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_upsert_referral_lead(text,text,text,text,text,uuid,text,text) TO service_role;
