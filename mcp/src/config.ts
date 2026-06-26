import { config as loadEnv } from "dotenv";

// Carga mcp/.env de forma robusta: relativo a este módulo (sirve para `tsx src`
// y para `node dist`), con fallback al .env del cwd.
loadEnv({ path: new URL("../.env", import.meta.url) });
loadEnv();

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Falta la variable de entorno ${name} (ver .env.example)`);
  return v;
}

export const config = {
  supabaseUrl: required("SUPABASE_URL"),
  serviceRoleKey: required("SUPABASE_SERVICE_ROLE_KEY"),

  /** Workspace activo. El CRM es single-tenant hoy; todo se scopea a este id. */
  workspaceId: process.env.APPRIL_WORKSPACE_ID ?? "e2096477-fa6a-4b8f-a8b3-bd46ad720167",

  /** Direcciones permitidas para send_test (envío real, aislado). */
  testAllowlist: (process.env.MCP_TEST_ALLOWLIST ?? "mauricio@todoc.co")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean),

  /** Identidad de auditoría para created_by / triggered_by. */
  serviceUserId: process.env.MCP_SERVICE_USER_ID || null,
} as const;

/**
 * Regla de oro del MCP (ver guardrails.ts):
 *  - El MCP NUNCA inserta en message_queue salvo `send_test` (1 fila, allowlist).
 *  - El MCP NUNCA pone una campaña en 'running' ni setea approved_at.
 *  - El envío masivo real lo gatilla un humano (UI del CRM) o el scheduler,
 *    y el scheduler sólo dispara campañas con approved_at != null.
 */
export const TRIGGERED_BY = "mcp" as const;
