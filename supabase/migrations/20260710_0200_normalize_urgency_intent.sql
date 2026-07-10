-- ── normalize_discovery_score_inputs: cubrir los enums del rediseño 2026 ─────
-- Aplicada en prod el 2026-07-10.
--
-- La función mapeaba weekly_* (volumen y caídas) y los sistemas de agenda, pero
-- NO la urgencia ni las variantes de intención:
--   · urgency 'media_interesa' / 'media_explorando' → pasaba tal cual → 0 puntos
--     (debe dar 8). Afectaba al 52% de los leads históricos. `submit_discovery_lead`
--     canoniza a mano antes de llamar (LIKE 'media%'), así que los scores GUARDADOS
--     están bien; pero cualquier otro consumidor de calculate_discovery_score
--     perdía 8 puntos en silencio. Lo descubrió la regresión al portar el scoring.
--   · intent 'agendar_demo' / 'crear_cuenta' (que scoring.js ya trata como
--     demo/probar) darían 0 en vez de 20/15. Hoy no llegan del wizard, pero el
--     frontend los contempla: se cubren antes de que muerdan.
--
-- El resto de mapeos se deja INTACTO: se verificó que weekly_lt_15→30_80,
-- weekly_1_2→6_10, weekly_3_5→11_20, etc. son correctos (los buckets del backend
-- son MENSUALES y los del wizard, semanales).
--
-- Verificado: score con urgencia cruda == score con urgencia canónica (86);
-- agendar_demo=20 pts, crear_cuenta=15 pts; cero warnings en los 25 leads
-- históricos; la regresión de discovery_preview no se mueve.

create or replace function public.normalize_discovery_score_inputs(
  p_vol text, p_lost text, p_intent text, p_urgency text, p_ticket text, p_digital text
) returns jsonb
language plpgsql immutable set search_path = public as $$
DECLARE
  v_vol text; v_lost text; v_intent text; v_urgency text; v_ticket text; v_digital text;
  v_warn text[] := ARRAY[]::text[];
  c_vol     CONSTANT text[] := ARRAY['lt_30','30_80','81_150','151_300','gt_300'];
  c_lost    CONSTANT text[] := ARRAY['0_2','3_5','6_10','11_20','gt_20','no_medido'];
  c_intent  CONSTANT text[] := ARRAY['información','demo','probar','solo_ver'];
  c_urgency CONSTANT text[] := ARRAY['alta','media','baja'];
  c_ticket  CONSTANT text[] := ARRAY['lt_10','10_25','25_50','50_100','gt_100','variable'];
  c_digital CONSTANT text[] := ARRAY['papel','llamadas','sin_sistema','whatsapp','excel','software_basico','software_avanzado'];
BEGIN
  IF p_vol IS NULL THEN v_vol := NULL;
  ELSIF p_vol = ANY (c_vol) THEN v_vol := p_vol;
  ELSE
    v_vol := CASE p_vol
      WHEN 'weekly_lt_15' THEN '30_80' WHEN 'weekly_15_50' THEN '81_150'
      WHEN 'weekly_51_100' THEN 'gt_300' WHEN 'weekly_100_plus' THEN 'gt_300'
      ELSE NULL END;
    IF v_vol IS NULL THEN v_vol := p_vol; v_warn := array_append(v_warn, 'vol'); END IF;
  END IF;

  IF p_lost IS NULL THEN v_lost := NULL;
  ELSIF p_lost = ANY (c_lost) THEN v_lost := p_lost;
  ELSE
    v_lost := CASE p_lost
      WHEN 'weekly_none' THEN '0_2' WHEN 'weekly_1_2' THEN '6_10' WHEN 'weekly_3_5' THEN '11_20'
      WHEN 'weekly_6_10' THEN 'gt_20' WHEN 'weekly_10_plus' THEN 'gt_20'
      ELSE NULL END;
    IF v_lost IS NULL THEN v_lost := p_lost; v_warn := array_append(v_warn, 'lost'); END IF;
  END IF;

  IF p_intent IS NULL THEN v_intent := NULL;
  ELSIF p_intent = ANY (c_intent) THEN v_intent := p_intent;
  ELSE
    v_intent := CASE p_intent
      WHEN 'agendar_demo' THEN 'demo' WHEN 'crear_cuenta' THEN 'probar'
      WHEN 'informacion' THEN 'información'
      ELSE NULL END;
    IF v_intent IS NULL THEN v_intent := p_intent; v_warn := array_append(v_warn, 'intent'); END IF;
  END IF;

  IF p_urgency IS NULL THEN v_urgency := NULL;
  ELSIF p_urgency = ANY (c_urgency) THEN v_urgency := p_urgency;
  ELSIF p_urgency LIKE 'media%' THEN v_urgency := 'media';
  ELSE v_urgency := p_urgency; v_warn := array_append(v_warn, 'urgency');
  END IF;

  IF p_ticket IS NULL THEN v_ticket := NULL;
  ELSIF p_ticket = ANY (c_ticket) THEN v_ticket := p_ticket;
  ELSE v_ticket := p_ticket; v_warn := array_append(v_warn, 'ticket');
  END IF;

  IF p_digital IS NULL THEN v_digital := NULL;
  ELSIF p_digital = ANY (c_digital) THEN v_digital := p_digital;
  ELSE
    v_digital := CASE p_digital
      WHEN 'digital_calendar' THEN 'software_basico' WHEN 'scheduling_software' THEN 'software_basico'
      WHEN 'external_portal' THEN 'software_basico' WHEN 'clinical_system' THEN 'software_avanzado'
      WHEN 'institution_system' THEN 'software_avanzado' WHEN 'not_centralized' THEN 'sin_sistema'
      ELSE NULL END;
    IF v_digital IS NULL THEN v_digital := p_digital; v_warn := array_append(v_warn, 'digital'); END IF;
  END IF;

  RETURN jsonb_build_object(
    'vol', v_vol, 'lost', v_lost, 'intent', v_intent, 'urgency', v_urgency,
    'ticket', v_ticket, 'digital', v_digital, 'warnings', to_jsonb(v_warn)
  );
END;
$$;
