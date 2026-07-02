/** Regex E.164 — idéntico a src/lib/leadFilters.ts (E164_SQL_REGEX) del CRM. */
export const E164 = /^\+[1-9][0-9]{7,14}$/;

/** Regex básico de email — idéntico al de src/lib/phone.ts (normalizeEmail). */
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function normalizeEmail(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const e = raw.trim().toLowerCase();
  return EMAIL.test(e) ? e : null;
}

/** Valida E.164 estricto (debe traer '+' y código de país). No adivina indicativo. */
export function normalizePhone(raw: string | null | undefined): string | null {
  if (!raw) return null;
  let p = raw.trim().replace(/[\s.()\-]/g, "");
  if (p.startsWith("00")) p = "+" + p.slice(2);
  return E164.test(p) ? p : null;
}

/** Genera template_key igual que src/app/templates/actions.ts: {slug}_{timestamp}. */
export function makeTemplateKey(name: string): string {
  const base = name
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "")
    .slice(0, 40);
  return `${base}_${Date.now()}`;
}

/** Extrae nombres de variables {{ var }} de los cuerpos (lo que el CRM hace a mano). */
export function extractVariables(...texts: (string | null | undefined)[]): string[] {
  const found = new Set<string>();
  const re = /\{\{\s*([\w.]+)\s*\}\}/g;
  for (const t of texts) {
    if (!t) continue;
    let m: RegExpExecArray | null;
    while ((m = re.exec(t)) !== null) found.add(m[1]);
  }
  return [...found];
}

export const SEGMENTS = ["SUPER_HOT", "HOT", "WARM", "COLD", "DO_NOT_EMAIL"] as const;

/**
 * Deriva el nombre de saludo, idéntico a lead_var_value(_, 'nombre') del CRM:
 * override first_name → primer token de full_name → 'Doctor(a)'.
 */
export function deriveNombre(firstName?: string | null, fullName?: string | null): string {
  const fn = (firstName ?? "").trim();
  if (fn) return fn;
  const tok = (fullName ?? "").trim().split(/\s+/)[0];
  return tok || "Doctor(a)";
}
