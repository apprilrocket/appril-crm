import { db, WORKSPACE_ID } from "../db.js";
import { config } from "../config.js";
import { GuardrailError } from "../guardrails.js";
import { extractVariables, makeTemplateKey } from "./util.js";

export async function listTemplates(args: { channel?: string; status?: string }) {
  let q = db
    .from("message_templates")
    .select("template_key, name, channel, status, subject, wa_template_name, wa_language, variables, updated_at")
    .eq("workspace_id", WORKSPACE_ID);
  if (args.channel) q = q.eq("channel", args.channel);
  if (args.status) q = q.eq("status", args.status);
  const { data, error } = await q.order("status").order("updated_at", { ascending: false });
  if (error) throw new Error(error.message);
  return data;
}

export async function getTemplate(template_key: string) {
  const { data, error } = await db
    .from("message_templates")
    .select("*")
    .eq("workspace_id", WORKSPACE_ID)
    .eq("template_key", template_key)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new Error(`No existe el template "${template_key}".`);
  return data;
}

/** Templates de WhatsApp aprobados por Meta (listos para usar). Sólo lectura. */
export async function listWaTemplates() {
  const { data, error } = await db
    .from("message_templates")
    .select("template_key, name, status, wa_template_name, wa_language, variables")
    .eq("workspace_id", WORKSPACE_ID)
    .eq("channel", "whatsapp")
    .not("wa_template_name", "is", null);
  if (error) throw new Error(error.message);
  return data;
}

/** Crea copy de EMAIL (la IA sí puede). WhatsApp NO se crea aquí: requiere aprobación de Meta. */
export async function createEmailTemplate(args: {
  name: string;
  subject: string;
  html_body: string;
  text_body?: string;
  description?: string;
  activate?: boolean;
}) {
  if (args.activate && (!args.subject?.trim() || !args.html_body?.trim())) {
    throw new GuardrailError("Para activar un template de email se requiere subject y html_body.");
  }
  const variables = extractVariables(args.subject, args.html_body, args.text_body);
  const template_key = makeTemplateKey(args.name);
  const { data, error } = await db
    .from("message_templates")
    .insert({
      workspace_id: WORKSPACE_ID,
      template_key,
      name: args.name.trim(),
      description: args.description?.trim() || null,
      channel: "email",
      subject: args.subject,
      html_body: args.html_body,
      text_body: args.text_body ?? null,
      variables,
      status: args.activate ? "active" : "draft",
      created_by: config.serviceUserId,
    })
    .select("template_key, name, status, variables")
    .single();
  if (error) throw new Error(error.message);
  return data;
}

export async function updateEmailTemplate(args: {
  template_key: string;
  name?: string;
  subject?: string;
  html_body?: string;
  text_body?: string;
  status?: "draft" | "active" | "archived";
}) {
  const current = await getTemplate(args.template_key);
  if (current.channel !== "email") throw new GuardrailError("Sólo se pueden editar templates de email desde el MCP.");

  const next = {
    name: args.name ?? current.name,
    subject: args.subject ?? current.subject,
    html_body: args.html_body ?? current.html_body,
    text_body: args.text_body ?? current.text_body,
    status: args.status ?? current.status,
  };
  if (next.status === "active" && (!next.subject?.trim() || !next.html_body?.trim())) {
    throw new GuardrailError("Para activar se requiere subject y html_body.");
  }
  const variables = extractVariables(next.subject, next.html_body, next.text_body);
  const { data, error } = await db
    .from("message_templates")
    .update({ ...next, variables, updated_at: new Date().toISOString() })
    .eq("workspace_id", WORKSPACE_ID)
    .eq("template_key", args.template_key)
    .select("template_key, name, status, variables")
    .single();
  if (error) throw new Error(error.message);
  return data;
}
