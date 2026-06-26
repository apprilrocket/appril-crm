import { config } from "./config.js";

/** Error de guardarraíl: se devuelve como texto al modelo, no se lanza al protocolo. */
export class GuardrailError extends Error {}

/** send_test sólo a direcciones explícitamente permitidas. */
export function assertTestRecipient(email: string): string {
  const e = email.trim().toLowerCase();
  if (!config.testAllowlist.includes(e)) {
    throw new GuardrailError(
      `Destinatario de prueba no permitido: ${email}. ` +
        `send_test sólo puede enviar a: ${config.testAllowlist.join(", ")}. ` +
        `Edita MCP_TEST_ALLOWLIST si necesitas otro.`,
    );
  }
  return e;
}

/** Validación mínima de email entregable (espejo de la guarda del CRM: can_email + '%@%'). */
export function isPlausibleEmail(email: string | null | undefined): boolean {
  return !!email && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email);
}

/**
 * Columnas que el MCP NUNCA debe escribir (la aprobación y el envío son humanos).
 * Se usa como checklist en revisión; ningún tool las setea.
 */
export const FORBIDDEN_WRITES = [
  "campaigns.status = 'running'",
  "campaigns.approved_at",
  "campaigns.approved_by",
  "message_queue (excepto send_test: 1 fila, allowlist)",
] as const;
