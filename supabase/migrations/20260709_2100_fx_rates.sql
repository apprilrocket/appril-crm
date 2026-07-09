-- ── fx_rates: tasas de cambio determinísticas para todo el ecosistema ─────────
-- Diseño original en appril-web/docs/modulo-campanas-marketing-PLAN.md (§5):
-- tabla fx_rates + cron de refresco contra open.er-api.com (cubre LATAM;
-- Frankfurter/BCE no cubre COP/ARS/CLP). Regla: los consumidores leen SIEMPRE
-- esta tabla (nunca la API, nunca calcula un LLM); toda cifra convertida se
-- muestra con "≈" y la fecha de la tasa (fetched_at).
-- Se aplica idéntica en los DOS proyectos Supabase (CRM y producto).

create table if not exists public.fx_rates (
  currency          text primary key,
  rate_usd_to_local numeric not null check (rate_usd_to_local > 0),
  fetched_at        timestamptz not null default now(),
  source            text not null default 'seed_static'
);

alter table public.fx_rates enable row level security;
-- Lectura para usuarios autenticados (dato público, no sensible); escritura
-- solo vía las funciones DEFINER de abajo / service_role.
drop policy if exists fx_rates_read on public.fx_rates;
create policy fx_rates_read on public.fx_rates for select to authenticated using (true);
revoke all on public.fx_rates from anon;

-- Seed con la tabla estática histórica de Discovery (data.js) — la tabla nunca
-- está vacía; el cron la sobreescribe con tasas reales.
insert into public.fx_rates (currency, rate_usd_to_local, source) values
  ('USD', 1,    'seed_static_discovery'),
  ('COP', 4015, 'seed_static_discovery'),
  ('MXN', 18,   'seed_static_discovery'),
  ('EUR', 0.92, 'seed_static_discovery'),
  ('BRL', 5.4,  'seed_static_discovery'),
  ('CLP', 950,  'seed_static_discovery'),
  ('PEN', 3.75, 'seed_static_discovery'),
  ('ARS', 1100, 'seed_static_discovery')
on conflict (currency) do nothing;

-- Requests pendientes del fetch asíncrono (patrón fire/collect de pg_net,
-- igual que el canario del watchdog).
create table if not exists public.fx_refresh_requests (
  request_id   bigint primary key,
  requested_at timestamptz not null default now()
);
alter table public.fx_refresh_requests enable row level security; -- sin políticas: solo definer

-- Dispara el GET asíncrono a la API.
create or replace function public.fx_rates_fire() returns void
language plpgsql security definer set search_path = public as $$
declare v_rid bigint;
begin
  select net.http_get('https://open.er-api.com/v6/latest/USD') into v_rid;
  insert into fx_refresh_requests (request_id) values (v_rid);
end $$;

-- Recoge respuestas pendientes y actualiza la tabla. Si la API falló, la tasa
-- anterior queda intacta (solo envejece fetched_at) — nunca hay hueco.
create or replace function public.fx_rates_collect() returns integer
language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_body jsonb;
  v_count integer := 0;
begin
  for r in select request_id, requested_at from fx_refresh_requests loop
    select content::jsonb into v_body
    from net._http_response
    where id = r.request_id and status_code = 200;

    if v_body is not null and v_body->>'result' = 'success' then
      insert into fx_rates (currency, rate_usd_to_local, fetched_at, source)
      select e.key, (e.value #>> '{}')::numeric, now(), 'open.er-api.com'
      from jsonb_each(v_body->'rates') e
      where (e.value #>> '{}')::numeric > 0
      on conflict (currency) do update
        set rate_usd_to_local = excluded.rate_usd_to_local,
            fetched_at        = excluded.fetched_at,
            source            = excluded.source;
      get diagnostics v_count = row_count;
    end if;

    -- Limpia si ya hay respuesta (éxito o error) o si venció (>1h sin respuesta).
    if exists (select 1 from net._http_response where id = r.request_id)
       or r.requested_at < now() - interval '1 hour' then
      delete from fx_refresh_requests where request_id = r.request_id;
    end if;
  end loop;
  return v_count;
end $$;

-- Conversión determinística vía USD como pivote. NULL si falta alguna moneda.
create or replace function public.fx_convert(p_amount numeric, p_from text, p_to text)
returns numeric language sql stable security definer set search_path = public as $$
  select p_amount / f.rate_usd_to_local * t.rate_usd_to_local
  from fx_rates f, fx_rates t
  where f.currency = upper(p_from) and t.currency = upper(p_to);
$$;

revoke all on function public.fx_rates_fire()    from public, anon, authenticated;
revoke all on function public.fx_rates_collect() from public, anon, authenticated;
grant execute on function public.fx_convert(numeric, text, text) to authenticated, service_role;

-- Cron: fire de madrugada, collect 5 minutos después (la API responde en segundos).
select cron.schedule('fx-rates-fire',    '15 6 * * *', 'select public.fx_rates_fire()');
select cron.schedule('fx-rates-collect', '20 6 * * *', 'select public.fx_rates_collect()');
