import { db, WORKSPACE_ID } from "../db.js";
import { config } from "../config.js";
import { normalizeEmail, normalizePhone } from "./util.js";

/** Listas con conteo de miembros. */
export async function listLeadLists() {
  const { data, error } = await db
    .from("lead_lists")
    .select("id, name, description, source_type, created_at")
    .eq("workspace_id", WORKSPACE_ID)
    .order("created_at", { ascending: false });
  if (error) throw new Error(error.message);

  const lists = data ?? [];
  const withCounts = await Promise.all(
    lists.map(async (l) => {
      const { count } = await db
        .from("lead_list_members")
        .select("lead_id", { count: "exact", head: true })
        .eq("list_id", l.id);
      return { ...l, members: count ?? 0 };
    }),
  );
  return withCounts;
}

export async function createList(args: { name: string; description?: string; source_type?: string }) {
  const { data, error } = await db
    .from("lead_lists")
    .insert({
      workspace_id: WORKSPACE_ID,
      name: args.name.trim(),
      description: args.description?.trim() || null,
      source_type: args.source_type ?? "manual",
      created_by: config.serviceUserId,
    })
    .select("id, name")
    .single();
  if (error) {
    if ((error as any).code === "23505") throw new Error(`Ya existe una lista con el nombre "${args.name}".`);
    throw new Error(error.message);
  }
  return data;
}

type ContactIn = {
  full_name?: string;
  first_name?: string;
  email?: string;
  phone?: string;
  city?: string;
  specialization?: string;
  country?: string;
  whatsapp_opted_in?: boolean;
};

/**
 * Ingesta de contactos a una lista (crea la lista si no existe).
 * Dedupe en-archivo + contra BD por email_normalized y phone (E.164).
 * Espejo del flujo de ImportWizard, pero corrige el bug de email_normalized.
 */
export async function importContacts(args: {
  list_name: string;
  contacts: ContactIn[];
  segment?: string;
  source?: string;
}) {
  const segment = args.segment ?? "COLD";
  const report = { total: args.contacts.length, nuevos: 0, existentes: 0, invalidos: 0, duplicados_archivo: 0 };

  // 1) Lista (crear o reusar)
  let listId: string;
  const existing = await db
    .from("lead_lists")
    .select("id")
    .eq("workspace_id", WORKSPACE_ID)
    .eq("name", args.list_name.trim())
    .maybeSingle();
  if (existing.data) listId = existing.data.id;
  else listId = (await createList({ name: args.list_name, source_type: "csv_import" })).id;

  // 2) Normalizar + dedupe en-archivo
  const seenEmail = new Set<string>();
  const seenPhone = new Set<string>();
  type Clean = { full_name: string; first_name: string | null; email: string | null; phone: string | null; city?: string; specialization?: string; country?: string; whatsapp_opted_in: boolean };
  const clean: Clean[] = [];
  for (const c of args.contacts) {
    const email = normalizeEmail(c.email);
    const phone = normalizePhone(c.phone);
    if (!email && !phone) { report.invalidos++; continue; }
    if (email && seenEmail.has(email)) { report.duplicados_archivo++; continue; }
    if (phone && seenPhone.has(phone)) { report.duplicados_archivo++; continue; }
    if (email) seenEmail.add(email);
    if (phone) seenPhone.add(phone);
    clean.push({ full_name: (c.full_name ?? "").trim() || "Desconocido", first_name: c.first_name?.trim() || null, email, phone, city: c.city, specialization: c.specialization, country: c.country, whatsapp_opted_in: c.whatsapp_opted_in ?? false });
  }

  // 3) Dedupe contra BD
  const emails = clean.map((c) => c.email).filter(Boolean) as string[];
  const phones = clean.map((c) => c.phone).filter(Boolean) as string[];
  const byEmail = new Map<string, string>();
  const byPhone = new Map<string, string>();
  if (emails.length) {
    const { data } = await db.from("leads_master").select("id, email_normalized").eq("workspace_id", WORKSPACE_ID).in("email_normalized", emails);
    for (const r of data ?? []) if (r.email_normalized) byEmail.set(r.email_normalized, r.id);
  }
  if (phones.length) {
    const { data } = await db.from("leads_master").select("id, phone").eq("workspace_id", WORKSPACE_ID).in("phone", phones);
    for (const r of data ?? []) if (r.phone) byPhone.set(r.phone, r.id);
  }

  // 4) Crear nuevos / resolver existentes
  const memberIds = new Set<string>();
  const toCreate: Clean[] = [];
  for (const c of clean) {
    const hit = (c.email && byEmail.get(c.email)) || (c.phone && byPhone.get(c.phone));
    if (hit) { memberIds.add(hit); report.existentes++; }
    else toCreate.push(c);
  }

  const BATCH = 300;
  for (let i = 0; i < toCreate.length; i += BATCH) {
    const chunk = toCreate.slice(i, i + BATCH).map((c) => ({
      workspace_id: WORKSPACE_ID,
      full_name: c.full_name,
      first_name: c.first_name,
      email: c.email,
      email_normalized: c.email, // corrige el bug de ImportWizard (no lo setea)
      phone: c.phone,
      city: c.city ?? null,
      specialization: c.specialization ?? null,
      country: c.country ?? null,
      source: `lista:${args.list_name}`,
      marketing_segment: segment,
      pipeline_stage: "new",
      can_email: !!c.email,
      can_whatsapp: !!c.phone,
      whatsapp_opted_in: c.whatsapp_opted_in,
    }));
    const { data, error } = await db.from("leads_master").insert(chunk).select("id");
    if (error) throw new Error(`Error creando leads: ${error.message}`);
    for (const r of data ?? []) { memberIds.add(r.id); report.nuevos++; }
  }

  // 5) Miembros (idempotente)
  const members = [...memberIds].map((lead_id) => ({ list_id: listId, lead_id }));
  for (let i = 0; i < members.length; i += BATCH) {
    const { error } = await db.from("lead_list_members").upsert(members.slice(i, i + BATCH), { onConflict: "list_id,lead_id", ignoreDuplicates: true });
    if (error) throw new Error(`Error agregando miembros: ${error.message}`);
  }

  return { list_id: listId, ...report };
}
