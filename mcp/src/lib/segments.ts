import { db, WORKSPACE_ID } from "../db.js";
import { SEGMENTS } from "./util.js";

async function count(build: (q: any) => any): Promise<number> {
  const base = db.from("leads_master").select("id", { count: "exact", head: true }).eq("workspace_id", WORKSPACE_ID);
  const { count, error } = await build(base);
  if (error) throw new Error(error.message);
  return count ?? 0;
}

/** Cada segmento con su audiencia total y elegibles por canal (snapshot en vivo). */
export async function listSegments() {
  const rows = await Promise.all(
    SEGMENTS.map(async (seg) => {
      const [total, email, wa] = await Promise.all([
        count((q) => q.eq("marketing_segment", seg)),
        count((q) => q.eq("marketing_segment", seg).eq("can_email", true).not("email", "is", null).like("email", "%@%")),
        count((q) => q.eq("marketing_segment", seg).eq("can_whatsapp", true).not("phone", "is", null)),
      ]);
      return { segment: seg, total, email_eligible: email, whatsapp_eligible: wa };
    }),
  );
  return rows;
}
