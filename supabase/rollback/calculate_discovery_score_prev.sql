-- SNAPSHOT DE ROLLBACK — calculate_discovery_score(text x6) — versión VIVA antes de aplicar 20260629_1500
-- Capturado de producción (hwiocriejizjdqqcfrsj) vía pg_get_functiondef.
-- Para revertir: ejecutar este CREATE OR REPLACE tal cual.
CREATE OR REPLACE FUNCTION public.calculate_discovery_score(p_q_volume text, p_q_lost text, p_q_intent text, p_q_urgency text, p_q_ticket text, p_q_digital text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
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
  v_vol := CASE p_q_volume
    WHEN 'gt_300'   THEN 25
    WHEN '151_300'  THEN 20
    WHEN '81_150'   THEN 13
    WHEN '30_80'    THEN 6
    WHEN 'lt_30'    THEN 2
    ELSE 0 END;

  v_lost := CASE p_q_lost
    WHEN 'no_medido' THEN 6
    WHEN 'gt_20'     THEN 20
    WHEN '11_20'     THEN 16
    WHEN '6_10'      THEN 12
    WHEN '3_5'       THEN 8
    WHEN '0_2'       THEN 2
    ELSE 0 END;

  v_int := CASE p_q_intent
    WHEN 'demo'        THEN 20
    WHEN 'probar'      THEN 15
    WHEN 'información' THEN 8
    WHEN 'solo_ver'    THEN 3
    ELSE 0 END;

  v_urg := CASE p_q_urgency
    WHEN 'alta'  THEN 15
    WHEN 'media' THEN 8
    WHEN 'baja'  THEN 2
    ELSE 0 END;

  v_tick := CASE p_q_ticket
    WHEN 'gt_100'  THEN 10
    WHEN '50_100'  THEN 8
    WHEN '25_50'   THEN 5
    WHEN 'variable' THEN 5
    WHEN '10_25'   THEN 3
    WHEN 'lt_10'   THEN 1
    ELSE 0 END;

  v_dig := CASE
    WHEN p_q_digital IN ('papel','llamadas','sin_sistema')    THEN 10
    WHEN p_q_digital IN ('whatsapp','excel')                  THEN 7
    WHEN p_q_digital = 'software_basico'                      THEN 3
    WHEN p_q_digital = 'software_avanzado'                    THEN 1
    ELSE 0 END;

  v_total := LEAST(100, v_vol + v_lost + v_int + v_urg + v_tick + v_dig);

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
$function$;
