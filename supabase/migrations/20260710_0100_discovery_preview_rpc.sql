-- ── Discovery: la tasa y el scoring dejan de vivir en el navegador ───────────
-- Aplicada en prod el 2026-07-10.
--
-- ANTES: `appril-discovery/scoring.js` calculaba economía, madurez y riesgo con
-- una tabla FX estática (COP 4015 vs 3341 real; ARS 1100 vs 1491). Y existían
-- DOS scorings distintos: el del frontend (midpoints del rediseño 2026) y el
-- canónico del backend (`calculate_discovery_score`, sobre enums v1). Nunca
-- podían coincidir.
--
-- AHORA:
--   · discovery_fx_rates()  → el wizard lee las tasas del día desde fx_rates.
--   · discovery_preview()   → fuente única del diagnóstico. El SCORE lo produce
--     `calculate_discovery_score` (la misma función que usa submit_discovery_lead),
--     así que lo que ve el lead es lo que la BD guarda. El preview solo añade lo
--     que el backend no tiene: economía, madurez y riesgo dominante.
--   · Devuelve CLAVES i18n (risk_dominant, evidencia), nunca textos: el copy
--     sigue en el cliente.
--
-- Detalles descubiertos al portar (verificados contra los leads históricos):
--   · Los enums canónicos de volumen/caídas son `weekly_*` (data.js: _opts toma
--     el 2º elemento como value). Usar las claves i18n daba midpoint 0.
--   · `normalize_discovery_score_inputs` NO mapea `media_interesa`/`media_explorando`
--     → `media`: quien llame a calculate_discovery_score con la urgencia cruda
--     pierde 8 puntos. `submit_discovery_lead` sí canoniza; aquí se replica.
--
-- Regresión sobre 25 leads reales: riesgo idéntico en todos; score idéntico en 5
-- y +puntos en 4 (efecto correcto de la tasa real: el ticket en USD vale más);
-- ninguna clasificación empeoró.

-- ── 1. Tasas para el wizard (anon; solo lectura, dato público) ───────────────
create or replace function public.discovery_fx_rates()
returns table (currency text, rate_usd_to_local numeric, fetched_at timestamptz)
language sql stable security definer set search_path = public as $$
  select f.currency, f.rate_usd_to_local, f.fetched_at
  from fx_rates f
  where f.currency in ('USD','COP','MXN','EUR','BRL','CLP','PEN','ARS');
$$;
revoke all on function public.discovery_fx_rates() from public;
grant execute on function public.discovery_fx_rates() to anon, authenticated, service_role;

-- ── 2. Midpoints (espejo de data.js) ────────────────────────────────────────
create or replace function public.discovery_midpoint(p_question text, p_value text)
returns numeric language sql immutable set search_path = public as $$
  select case p_question
    when 'monthly_appointments_range' then case p_value
      when 'weekly_lt_15' then 43 when 'lt_15' then 43
      when 'weekly_15_50' then 139 when '15_50' then 139
      when 'weekly_51_100' then 325 when '51_100' then 325
      when 'weekly_100_plus' then 563 when 'gt_100' then 563
      else 0 end
    when 'lost_appointments_range' then case p_value
      when 'weekly_none' then 0 when 'none' then 0
      when 'weekly_1_2' then 6.5 when '1_2' then 6.5
      when 'weekly_3_5' then 17 when '3_5' then 17
      when 'weekly_6_10' then 35 when '6_10' then 35
      when 'weekly_10_plus' then 56 when 'gt_10' then 56
      when 'no_medido' then 13
      else 0 end
    when 'admin_minutes_per_appointment' then case p_value
      when 'lte_5' then 4 when '6_10' then 8 when '11_15' then 13 when '16_20' then 18
      when 'gt_20' then 25 when 'nose' then 8 else 0 end
    else 0 end::numeric;
$$;

/** Midpoint LOCAL del ticket por (moneda, bucket t1..t5). Espeja AP.TICKET_RANGES. */
create or replace function public.discovery_ticket_local(p_currency text, p_bucket text)
returns numeric language sql immutable set search_path = public as $$
  select case upper(coalesce(p_currency,'USD'))
    when 'COP' then case p_bucket when 't1' then 60000 when 't2' then 115000 when 't3' then 225000 when 't4' then 450000 when 't5' then 750000 end
    when 'MXN' then case p_bucket when 't1' then 220 when 't2' then 500 when 't3' then 1100 when 't4' then 2250 when 't5' then 3800 end
    when 'EUR' then case p_bucket when 't1' then 30 when 't2' then 60 when 't3' then 115 when 't4' then 225 when 't5' then 380 end
    when 'USD' then case p_bucket when 't1' then 38 when 't2' then 75 when 't3' then 150 when 't4' then 300 when 't5' then 500 end
    when 'BRL' then case p_bucket when 't1' then 110 when 't2' then 250 when 't3' then 550 when 't4' then 1125 when 't5' then 1900 end
    when 'CLP' then case p_bucket when 't1' then 22000 when 't2' then 50000 when 't3' then 110000 when 't4' then 225000 when 't5' then 380000 end
    when 'PEN' then case p_bucket when 't1' then 60 when 't2' then 130 when 't3' then 265 when 't4' then 525 when 't5' then 900 end
    when 'ARS' then case p_bucket when 't1' then 18000 when 't2' then 40000 when 't3' then 82000 when 't4' then 165000 when 't5' then 300000 end
  end::numeric;
$$;

-- ── 3. Bucket canónico USD del ticket (espeja AP.deriveCanonicalTicketRange) ─
create or replace function public.discovery_ticket_bucket(p_ticket_usd numeric)
returns text language sql immutable set search_path = public as $$
  select case
    when coalesce(p_ticket_usd,0) <= 0 then 'variable'
    when p_ticket_usd < 10 then 'lt_10'
    when p_ticket_usd < 25 then '10_25'
    when p_ticket_usd < 50 then '25_50'
    when p_ticket_usd < 100 then '50_100'
    else 'gt_100' end;
$$;
grant execute on function public.discovery_ticket_bucket(numeric) to anon, authenticated, service_role;

-- ── 4. El preview completo (fuente única del diagnóstico) ───────────────────
-- El SCORE lo delega a calculate_discovery_score (canónica del backend). Aquí
-- solo se calcula lo que el backend no tiene: economía, madurez y riesgo.
-- Ver el cuerpo desplegado en prod (md5 73304f1cd6f1e30e9e685f47bf507d4c).
create or replace function public.discovery_preview(p_answers jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  a jsonb := coalesce(p_answers, '{}'::jsonb);
  v_cur text := upper(coalesce(a->>'ticket_currency', 'USD'));
  v_bucket text := a->>'average_ticket_range';
  v_fx numeric; v_fx_date timestamptz;
  v_ticket_local numeric; v_ticket_usd numeric;
  v_monthly numeric; v_lost numeric; v_admin_min numeric;
  v_annual_lost numeric; v_m_admin_min numeric; v_a_admin_min numeric;
  v_m_admin_h numeric; v_a_admin_h numeric;
  v_hourly numeric := 8;
  v_admin_m numeric; v_admin_a numeric; v_hidden numeric;
  v_lost_rate numeric; v_estimated boolean;
  v_urgency text;
  v_score jsonb;
  v_mat int := 0; v_level int;
  v_risk text; v_cands text[] := '{}'; v_ev text[] := '{}'; v_pain text; v_pain_risk text;
  v_sm text := a->>'scheduling_method';
  v_cc text := a->>'confirmation_consistency';
  v_cp text := a->>'cancellation_process';
begin
  select rate_usd_to_local, fetched_at into v_fx, v_fx_date from fx_rates where currency = v_cur;
  if v_fx is null or v_fx <= 0 then v_fx := 1; end if;

  if v_bucket = 'unknown' then v_ticket_usd := 40;
  elsif v_bucket is null then v_ticket_usd := 0;
  else
    v_ticket_local := discovery_ticket_local(v_cur, v_bucket);
    v_ticket_usd := round(coalesce(v_ticket_local, 0) / v_fx, 2);
  end if;

  v_monthly   := discovery_midpoint('monthly_appointments_range', a->>'monthly_appointments_range');
  v_lost      := discovery_midpoint('lost_appointments_range', a->>'lost_appointments_range');
  v_admin_min := discovery_midpoint('admin_minutes_per_appointment', a->>'admin_minutes_per_appointment');

  v_annual_lost := round(v_lost * v_ticket_usd * 12, 2);
  v_m_admin_min := v_monthly * v_admin_min;
  v_a_admin_min := v_m_admin_min * 12;
  v_m_admin_h   := round(v_m_admin_min / 60, 2);
  v_a_admin_h   := round(v_a_admin_min / 60, 2);

  if coalesce((a->>'hourly_cost_usd')::numeric, 0) > 0 then
    v_hourly := (a->>'hourly_cost_usd')::numeric;
  elsif coalesce((a->>'monthly_agenda_person_cost_usd')::numeric, 0) > 0 then
    v_hourly := round((a->>'monthly_agenda_person_cost_usd')::numeric
                      / nullif(coalesce((a->>'monthly_work_hours')::numeric, 160), 0), 2);
  end if;

  v_admin_m := round(v_m_admin_h * v_hourly, 2);
  v_admin_a := round(v_a_admin_h * v_hourly, 2);
  v_hidden  := round(v_annual_lost + v_admin_a, 2);
  v_lost_rate := case when v_monthly > 0 then round(least(1, v_lost / v_monthly), 2) end;
  v_estimated := (v_bucket = 'unknown') or (a->>'lost_appointments_range' = 'no_medido') or (a->>'admin_minutes_per_appointment' = 'nose');

  -- Canoniza igual que submit_discovery_lead: normalize_discovery_score_inputs
  -- NO mapea media_interesa/media_explorando → media (serían -8 puntos).
  v_urgency := case when (a->>'urgency') like 'media%' then 'media' else coalesce(a->>'urgency','baja') end;

  v_score := calculate_discovery_score(
    a->>'monthly_appointments_range', a->>'lost_appointments_range', a->>'desired_next_step',
    v_urgency, discovery_ticket_bucket(v_ticket_usd), a->>'scheduling_method');

  if v_sm in ('scheduling_software','clinical_system','institution_system') then v_mat := v_mat + 3;
  elsif v_sm = 'digital_calendar' then v_mat := v_mat + 2;
  elsif v_sm = 'external_portal' then v_mat := v_mat + 1; end if;

  case a->>'appointment_scheduler_type'
    when 'pacientes_autoagenda' then v_mat := v_mat + 2;
    when 'asistentes' then v_mat := v_mat + 1;
    when 'institucion' then v_mat := v_mat + 1;
    else null; end case;

  if v_cc = 'siempre' then v_mat := v_mat + 4;
  elsif v_cc = 'casi_siempre' then v_mat := v_mat + 2; end if;
  if v_cp = 'sistema_automatico' then v_mat := v_mat + 3;
  elsif v_cp = 'asistente_llena_manual' then v_mat := v_mat + 1; end if;
  v_level := case when v_mat <= 2 then 1 when v_mat <= 5 then 2 when v_mat <= 8 then 3 when v_mat <= 11 then 4 else 5 end;

  if v_sm = 'whatsapp' and v_cc is distinct from 'siempre' then v_cands := v_cands || 'whatsapp_dependent_agenda'::text; end if;
  if v_cc in ('depende_carga','cuando_hay_tiempo','sin_proceso','no_sabe') then v_cands := v_cands || 'confirmation_inconsistent'::text; end if;
  if v_cp in ('se_pierde','paciente_vuelve_a_escribir','sin_proceso') or v_lost >= 17 then v_cands := v_cands || 'lost_cancellation_spaces'::text; end if;
  if v_m_admin_h >= 20 then v_cands := v_cands || 'admin_overload'::text; end if;
  if a->>'appointment_scheduler_type' = 'institucion' or v_sm = 'institution_system' then v_cands := v_cands || 'delegated_agenda_control'::text; end if;
  if v_sm = 'external_portal' then v_cands := v_cands || 'external_portal_dependency'::text; end if;
  if v_sm in ('digital_calendar','scheduling_software','clinical_system') then v_cands := v_cands || 'software_without_operational_control'::text; end if;
  v_cands := v_cands || 'low_operational_maturity'::text;

  v_pain := case when jsonb_typeof(a->'main_pain') = 'array' then a->'main_pain'->>0 else a->>'main_pain' end;
  v_pain_risk := case v_pain
    when 'whatsapp_caotico' then 'whatsapp_dependent_agenda'
    when 'pacientes_lleguen_mas' then 'confirmation_inconsistent'
    when 'confirmaciones_manuales' then 'confirmation_inconsistent'
    when 'llenar_cancelaciones' then 'lost_cancellation_spaces'
    when 'asistente_no_persiga' then 'admin_overload'
    when 'agenda_no_interrumpa' then 'admin_overload'
    when 'saber_quien_llega' then 'software_without_operational_control'
    when 'reagendar_facil' then 'lost_cancellation_spaces'
    end;
  v_risk := v_cands[1];
  if v_pain_risk is not null and v_pain_risk = any(v_cands) then v_risk := v_pain_risk; end if;

  if v_sm is not null then v_ev := v_ev || ('risk.evidence.method.' || v_sm)::text; end if;
  if v_cc in ('depende_carga','cuando_hay_tiempo','sin_proceso','no_sabe') then v_ev := v_ev || 'risk.evidence.confirm'::text; end if;
  if v_cp in ('se_pierde','paciente_vuelve_a_escribir','sin_proceso') then v_ev := v_ev || 'risk.evidence.cancel'::text; end if;
  if array_length(v_ev,1) < 2 and v_lost >= 17 then v_ev := v_ev || 'risk.evidence.lost'::text; end if;
  if array_length(v_ev,1) < 2 and v_m_admin_h >= 20 then v_ev := v_ev || 'risk.evidence.admin'::text; end if;

  return jsonb_build_object(
    'source', 'backend_discovery_preview',
    'currency', jsonb_build_object('selected_currency', v_cur, 'fx_rate_to_usd', v_fx,
      'fx_rate_source', case when v_fx = 1 and v_cur <> 'USD' then 'fallback_missing_rate' else 'fx_rates' end,
      'fx_rate_date', to_char(v_fx_date, 'YYYY-MM-DD')),
    'calc', jsonb_build_object(
      'monthly_appointments_midpoint', v_monthly, 'lost_appointments_midpoint', v_lost,
      'lost_appointment_rate', v_lost_rate, 'admin_minutes_per_appointment', v_admin_min,
      'ticket_midpoint_local', v_ticket_local, 'ticket_midpoint_usd', v_ticket_usd,
      'derived_average_ticket_range', discovery_ticket_bucket(v_ticket_usd),
      'annual_lost_revenue', v_annual_lost,
      'monthly_admin_minutes', v_m_admin_min, 'annual_admin_minutes', v_a_admin_min,
      'monthly_admin_hours', v_m_admin_h, 'annual_admin_hours', v_a_admin_h,
      'hourly_cost_usd', v_hourly, 'admin_cost_monthly', v_admin_m, 'admin_cost_annual', v_admin_a,
      'hidden_cost_total', v_hidden, 'estimated', v_estimated),
    'score', v_score,
    'maturity', jsonb_build_object('maturity_score', v_mat, 'level_id', v_level),
    'risk', jsonb_build_object('risk_dominant', v_risk, 'risk_evidence_keys', to_jsonb(v_ev), 'main_pain', v_pain)
  );
end $$;

revoke all on function public.discovery_preview(jsonb) from public;
grant execute on function public.discovery_preview(jsonb) to anon, authenticated, service_role;
