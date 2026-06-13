// Validación estricta de teléfonos: E.164 con indicativo obligatorio.
// Regla del CRM: NUNCA adivinar el país. Si el número no trae '+<indicativo>',
// no es un teléfono válido para WhatsApp.

import { parsePhoneNumberFromString } from 'libphonenumber-js';

// Regex que usan también las guardas SQL (campañas, calidad de datos)
export const E164_REGEX = /^\+[1-9][0-9]{7,14}$/;

export type PhoneResult =
  | { ok: true; e164: string; country?: string }
  | { ok: false; reason: 'vacío' | 'sin indicativo' | 'inválido' };

export function parsePhoneStrict(raw: unknown): PhoneResult {
  const cleaned = String(raw ?? '')
    .trim()
    .replace(/^00/, '+')          // 0057… → +57…
    .replace(/[\s().\- ‪-‮]/g, ''); // separadores y chars invisibles de excel

  if (!cleaned) return { ok: false, reason: 'vacío' };
  if (!cleaned.startsWith('+')) return { ok: false, reason: 'sin indicativo' };

  const parsed = parsePhoneNumberFromString(cleaned);
  if (!parsed || !parsed.isValid()) return { ok: false, reason: 'inválido' };

  return { ok: true, e164: parsed.number, country: parsed.country };
}

export function normalizeEmail(raw: unknown): string | null {
  const e = String(raw ?? '').trim().toLowerCase();
  if (!e || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) return null;
  return e;
}
