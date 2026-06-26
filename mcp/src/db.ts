import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { config } from "./config.js";

/**
 * Cliente Supabase con SERVICE ROLE → bypassea RLS.
 * CRÍTICO: por eso cada query DEBE filtrar por workspace_id manualmente.
 * Usa siempre el helper `ws()` para no olvidarlo.
 */
export const db: SupabaseClient = createClient(config.supabaseUrl, config.serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

/** Atajo: añade el filtro de workspace a un builder de PostgREST. */
export function ws<T>(query: T): T {
  // @ts-expect-error PostgREST builder encadenable
  return query.eq("workspace_id", config.workspaceId);
}

/** El workspace activo, para inserts. */
export const WORKSPACE_ID = config.workspaceId;
