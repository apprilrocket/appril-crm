-- ── Claim atómico de la cola de mensajes (Fase B de consolidación) ───────────
-- Aplicada en prod el 2026-07-09. El Lambda marcaba el lote entero como
-- 'sending' ANTES de procesarlo y recuperaba huérfanos asumiendo runs
-- secuenciales (timeout 60s < cron 120s). Esa premisa es el origen del bug de
-- "stuck in sending". Con FOR UPDATE SKIP LOCKED el claim es atómico: dos
-- workers concurrentes jamás toman la misma fila.

alter table public.message_queue
  add column if not exists claimed_at timestamptz;

create or replace function public.queue_claim_batch(p_limit integer default 50)
returns setof public.message_queue
language sql volatile security definer set search_path = public as $$
  with claimed as (
    select id
    from message_queue
    where status = 'pending' and scheduled_at <= now()
    order by scheduled_at asc
    limit greatest(1, least(p_limit, 200))
    for update skip locked
  )
  update message_queue q
  set status = 'sending', claimed_at = now()
  from claimed c
  where q.id = c.id
  returning q.*;
$$;

create or replace function public.queue_recover_stuck(
  p_stale_minutes integer default 10,
  p_max_attempts  integer default 3
) returns integer
language plpgsql volatile security definer set search_path = public as $$
declare v_count integer;
begin
  with stale as (
    select id, coalesce(attempts, 0) as attempts
    from message_queue
    where status = 'sending'
      and coalesce(claimed_at, sent_at, created_at) < now() - make_interval(mins => p_stale_minutes)
    for update skip locked
  ), fixed as (
    update message_queue q
    set status       = case when s.attempts >= p_max_attempts then 'failed' else 'pending' end,
        scheduled_at = case when s.attempts >= p_max_attempts then q.scheduled_at else now() end,
        claimed_at   = null,
        last_error   = 'STUCK_SENDING: huérfano en sending, recuperado por queue_recover_stuck'
    from stale s
    where q.id = s.id
    returning 1
  )
  select count(*) into v_count from fixed;
  return v_count;
end $$;

revoke all on function public.queue_claim_batch(integer)            from public, anon, authenticated;
revoke all on function public.queue_recover_stuck(integer, integer) from public, anon, authenticated;
grant execute on function public.queue_claim_batch(integer)            to service_role;
grant execute on function public.queue_recover_stuck(integer, integer) to service_role;
