-- ── Reproducibilidad: objetos que existían SOLO en la BD ─────────────────────
-- Este archivo NO cambia nada en prod (ambos objetos ya existen); lleva al
-- repo el cron de automations y el trigger del teléfono de prueba para que
-- una reconstrucción de la BD no los pierda. Detectados en la auditoría del
-- 2026-07-09 (ESTADO.md).

-- 1. Cron del motor de automations (verificado activo en cron.job, jobid 1).
--    Se registra idempotente: si ya existe, no se duplica.
do $$
begin
  if not exists (select 1 from cron.job where jobname = 'automation-tick') then
    perform cron.schedule('automation-tick', '* * * * *', 'select automation_tick()');
  end if;
end $$;

-- 2. Trigger que impide que el teléfono de prueba de Mauricio quede con el
--    agente pausado (p.ej. tras un handoff durante pruebas). Existía en BD
--    sin migración; se documenta aquí tal cual está desplegado.
create or replace function public.tg_keep_test_phone_unpaused() returns trigger
language plpgsql as $$
begin
  if NEW.phone = any (array['+573004860240']::text[]) and coalesce(NEW.agent_paused, false) is true then
    NEW.agent_paused := false;  -- nunca bloquear el teléfono de prueba
  end if;
  return NEW;
end $$;

drop trigger if exists trg_keep_test_phone_unpaused on public.leads_master;
create trigger trg_keep_test_phone_unpaused
  before insert or update on public.leads_master
  for each row execute function public.tg_keep_test_phone_unpaused();
