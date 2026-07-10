// Verificación criptográfica de mensajes SNS.
// El Lambda `appril-crm-webhook` NO validaba nada: aceptaba cualquier POST que
// dijera ser SNS (un Complaint/Bounce falso pone can_email=false en leads
// arbitrarios) y hacía fetch() a cualquier SubscribeURL (SSRF).

/** Campos firmados por SNS, en el orden exacto que exige AWS. */
const SIGNED_FIELDS: Record<string, string[]> = {
  Notification: ["Message", "MessageId", "Subject", "Timestamp", "TopicArn", "Type"],
  SubscriptionConfirmation: ["Message", "MessageId", "SubscribeURL", "Timestamp", "Token", "TopicArn", "Type"],
  UnsubscribeConfirmation: ["Message", "MessageId", "SubscribeURL", "Timestamp", "Token", "TopicArn", "Type"],
};

/** El certificado y la URL de confirmación SOLO pueden vivir en dominios de AWS. */
export function isAwsUrl(raw: string): boolean {
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return false;
  }
  return u.protocol === "https:" && /^sns\.[a-z0-9-]+\.amazonaws\.com$/.test(u.hostname);
}

function pemToDer(pem: string): Uint8Array {
  const b64 = pem.replace(/-----(BEGIN|END) CERTIFICATE-----/g, "").replace(/\s+/g, "");
  const bin = atob(b64);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

/** Lee un TLV DER en `pos`; devuelve tipo, rango del contenido y siguiente posición. */
function readTlv(der: Uint8Array, pos: number) {
  const tag = der[pos];
  let len = der[pos + 1];
  let headerLen = 2;
  if (len & 0x80) {
    const numBytes = len & 0x7f;
    len = 0;
    for (let i = 0; i < numBytes; i++) len = (len << 8) | der[pos + 2 + i];
    headerLen = 2 + numBytes;
  }
  const start = pos + headerLen;
  return { tag, start, end: start + len, next: start + len };
}

/**
 * Extrae el SubjectPublicKeyInfo (DER) de un certificado X.509.
 * Certificate ::= SEQ { tbsCertificate SEQ { [0] version?, serial, sigAlg,
 * issuer, validity, subject, spki, ... }, ... }
 */
function extractSpki(der: Uint8Array): ArrayBuffer {
  const cert = readTlv(der, 0);              // Certificate SEQUENCE
  const tbs = readTlv(der, cert.start);      // tbsCertificate SEQUENCE
  let pos = tbs.start;
  const first = readTlv(der, pos);
  if (first.tag === 0xa0) pos = first.next;  // [0] version explícito (opcional)
  for (let i = 0; i < 5; i++) pos = readTlv(der, pos).next; // serial, sigAlg, issuer, validity, subject
  const spki = readTlv(der, pos);            // subjectPublicKeyInfo
  const out = new Uint8Array(spki.end - pos);
  out.set(der.subarray(pos, spki.end));
  return out.buffer;
}

const certCache = new Map<string, CryptoKey>();

async function loadKey(certUrl: string, hash: "SHA-1" | "SHA-256"): Promise<CryptoKey> {
  const cacheKey = `${certUrl}|${hash}`;
  const cached = certCache.get(cacheKey);
  if (cached) return cached;
  const res = await fetch(certUrl);
  if (!res.ok) throw new Error(`No se pudo descargar el certificado SNS: HTTP ${res.status}`);
  const spki = extractSpki(pemToDer(await res.text()));
  const key = await crypto.subtle.importKey("spki", spki, { name: "RSASSA-PKCS1-v1_5", hash }, false, ["verify"]);
  certCache.set(cacheKey, key);
  return key;
}

/** true solo si la firma es válida y el certificado viene de AWS. */
export async function verifySnsSignature(msg: Record<string, unknown>): Promise<boolean> {
  const type = String(msg.Type ?? "");
  const fields = SIGNED_FIELDS[type];
  if (!fields) return false;

  const certUrl = String(msg.SigningCertURL ?? "");
  if (!isAwsUrl(certUrl)) return false;

  let canonical = "";
  for (const f of fields) {
    const v = msg[f];
    if (v === undefined || v === null) continue; // Subject es opcional
    canonical += `${f}\n${String(v)}\n`;
  }

  const hash = String(msg.SignatureVersion ?? "1") === "2" ? "SHA-256" : "SHA-1";
  const key = await loadKey(certUrl, hash);
  const sigBytes = Uint8Array.from(atob(String(msg.Signature ?? "")), (c) => c.charCodeAt(0));
  const sig = new Uint8Array(sigBytes.length);
  sig.set(sigBytes);
  const data = new TextEncoder().encode(canonical);
  const dataBuf = new Uint8Array(data.length);
  dataBuf.set(data);
  return await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, sig.buffer, dataBuf.buffer);
}
