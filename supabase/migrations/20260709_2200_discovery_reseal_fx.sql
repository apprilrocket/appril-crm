-- ── Re-sellado backend del FX de Discovery ────────────────────────────────────
-- Cierra el drift documentado en el contrato ("FX estático sin re-sellado
-- backend"): el frontend de Discovery convierte con su tabla estática (que ya
-- estaba ~20% desviada en COP); desde ahora, al insertar el lead, el backend
-- SOBREESCRIBE la tasa dentro de frontend_calculations.currency con la de
-- fx_rates (refrescada a diario) y preserva la del frontend para auditoría.
-- Consumidores (send-discovery-email, whatsapp-agent) leen fx_rate_to_usd del
-- jsonb, así que quedan corregidos sin tocarlos. No se recalculan score ni
-- findings (snapshot de lo que el lead VIO en pantalla — se respeta).

create or replace function public.tg_discovery_reseal_fx() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_cur  text;
  v_rate numeric;
  v_date timestamptz;
begin
  if NEW.frontend_calculations is null or NEW.frontend_calculations->'currency' is null then
    return NEW;
  end if;

  v_cur := upper(coalesce(
    NEW.selected_currency,
    NEW.frontend_calculations->'currency'->>'selected_currency',
    ''
  ));
  if v_cur = '' or v_cur = 'USD' then
    return NEW;
  end if;

  select rate_usd_to_local, fetched_at into v_rate, v_date
  from fx_rates where currency = v_cur;
  if v_rate is null or v_rate <= 0 then
    return NEW; -- sin tasa: se queda la del frontend (mejor que nada)
  end if;

  NEW.frontend_calculations := jsonb_set(
    NEW.frontend_calculations,
    '{currency}',
    (NEW.frontend_calculations->'currency')
      || jsonb_build_object(
           'fx_rate_frontend', NEW.frontend_calculations->'currency'->'fx_rate_to_usd',
           'fx_rate_to_usd',   v_rate,
           'fx_rate_source',   'backend_fx_rates',
           'fx_rate_date',     to_char(v_date, 'YYYY-MM-DD')
         )
  );
  return NEW;
end $$;

drop trigger if exists trg_discovery_reseal_fx on public.discovery_leads;
create trigger trg_discovery_reseal_fx
  before insert on public.discovery_leads
  for each row execute function public.tg_discovery_reseal_fx();
