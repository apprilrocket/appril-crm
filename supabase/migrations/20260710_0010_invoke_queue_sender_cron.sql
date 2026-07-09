-- ── Fase B ACTIVA: pg_cron releva al Lambda como drenador de message_queue ───
-- Aplicada en prod el 2026-07-09 (noche). Orden del flip ejecutado:
-- (1) aws events disable-rule appril-crm-sender-cron  [Lambda apagado]
-- (2) cron.schedule('queue-sender-tick')              [Edge toma el relevo]
-- El Lambda y la Edge NO deben drenar a la vez (el Lambda no usa el claim
-- atómico). Reversa: cron.unschedule('queue-sender-tick') + enable-rule.

create or replace function public.invoke_queue_sender() returns void
language plpgsql security definer set search_path = public as $$
declare v_secret text;
begin
  select value into v_secret from app_config where key = 'queue_sender_cron_secret';
  if v_secret is null then
    raise warning 'invoke_queue_sender: falta queue_sender_cron_secret en app_config';
    return;
  end if;
  perform net.http_post(
    url     := 'https://hwiocriejizjdqqcfrsj.supabase.co/functions/v1/queue-sender',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', v_secret),
    body    := '{"mode":"live"}'::jsonb
  );
end $$;
revoke all on function public.invoke_queue_sender() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'queue-sender-tick') then
    perform cron.schedule('queue-sender-tick', '*/2 * * * *', 'select public.invoke_queue_sender()');
  end if;
end $$;
