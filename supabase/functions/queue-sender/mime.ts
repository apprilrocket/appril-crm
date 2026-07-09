// MIME crudo byte-idéntico al de appril-sender/src/ses.ts (SendRawEmailCommand).
// Se replica al detalle porque el webhook de SES correlaciona por ses_message_id
// y los clientes de correo dependen de List-Unsubscribe / RFC 8058.

/** {{ var }} y {{ a.b.c }} — mismo motor que appril-sender/src/templates.ts. */
export function renderTemplate(tpl: string, payload: Record<string, unknown>): string {
  return tpl.replace(/\{\{\s*([\w.]+)\s*\}\}/g, (_m, path: string) => {
    const v = path.split(".").reduce<unknown>((acc, k) => (acc as Record<string, unknown>)?.[k], payload);
    return v === undefined || v === null ? "" : String(v);
  });
}

const enc = new TextEncoder();

function base64(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

/** base64 plegado a 76 chars (RFC 2045). */
function b64Folded(text: string): string {
  return (base64(enc.encode(text)).match(/.{1,76}/g) ?? []).join("\r\n");
}

/** Subject RFC 2047 en base64 si no es ASCII, en chunks de 39 bytes. */
function encodeSubject(subject: string): string {
  if (/^[\x20-\x7E]*$/.test(subject)) return subject;
  const bytes = enc.encode(subject);
  const chunks: string[] = [];
  for (let i = 0; i < bytes.length; i += 39) {
    chunks.push("=?UTF-8?B?" + base64(bytes.slice(i, i + 39)) + "?=");
  }
  return chunks.join("\r\n ");
}

export type RawEmailArgs = {
  from: string;
  to: string;
  replyTo?: string;
  subject: string;
  html?: string;
  text?: string;
  unsubscribeUrl?: string;
};

/** Espeja buildRawEmail de appril-sender/src/ses.ts. */
export function buildRawEmail(a: RawEmailArgs): Uint8Array {
  const boundary = `=_appril_${crypto.randomUUID()}`;
  const h: string[] = [
    `From: ${a.from}`,
    `To: ${a.to}`,
  ];
  if (a.replyTo) h.push(`Reply-To: ${a.replyTo}`);
  h.push(`Subject: ${encodeSubject(a.subject)}`);
  h.push("MIME-Version: 1.0");

  if (a.unsubscribeUrl) {
    const u = a.unsubscribeUrl.trim();
    if (u.startsWith("https://")) {
      h.push(`List-Unsubscribe: <${u}>`);
      h.push("List-Unsubscribe-Post: List-Unsubscribe=One-Click"); // RFC 8058
    } else if (u.startsWith("mailto:")) {
      h.push(`List-Unsubscribe: <${u}>`);
    }
  }

  const parts: string[] = [];
  if (a.text) {
    parts.push(
      `--${boundary}\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n${b64Folded(a.text)}`,
    );
  }
  if (a.html) {
    parts.push(
      `--${boundary}\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n${b64Folded(a.html)}`,
    );
  }

  let body: string;
  if (parts.length > 1) {
    h.push(`Content-Type: multipart/alternative; boundary="${boundary}"`);
    body = `\r\n${parts.join("\r\n")}\r\n--${boundary}--\r\n`;
  } else {
    // Single-part: el content-type va en la cabecera, sin boundary.
    const isHtml = !!a.html;
    h.push(`Content-Type: text/${isHtml ? "html" : "plain"}; charset=UTF-8`);
    h.push("Content-Transfer-Encoding: base64");
    body = `\r\n${b64Folded((isHtml ? a.html : a.text) ?? "")}\r\n`;
  }

  return enc.encode(h.join("\r\n") + "\r\n" + body);
}
