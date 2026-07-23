import { db } from "../db.js";

export type ReportKind = "funnel" | "channel_stats" | "activity_daily" | "quality_summary";

/** Reportes agregados del CRM (mismas RPCs del dashboard /reports y /quality).
 * Regla SEED (DEC-023 gate D): las RPCs excluyen marketing_segment='SEED' por
 * defecto; include_seed=true los reincorpora (evidencia histórica, no mezclar
 * jamás en lecturas de negocio). */
export async function getReport(input: { report: ReportKind; days?: number; include_seed?: boolean }) {
  const seed = input.include_seed ?? false;
  switch (input.report) {
    case "funnel": {
      const { data, error } = await db.rpc("report_funnel", { p_include_seed: seed });
      if (error) throw new Error(error.message);
      return data;
    }
    case "channel_stats": {
      const { data, error } = await db.rpc("report_channel_stats", { p_days: input.days ?? 30, p_include_seed: seed });
      if (error) throw new Error(error.message);
      return data;
    }
    case "activity_daily": {
      const { data, error } = await db.rpc("report_activity_daily", { p_days: input.days ?? 14, p_include_seed: seed });
      if (error) throw new Error(error.message);
      return data;
    }
    case "quality_summary": {
      const { data, error } = await db.rpc("lead_quality_summary", { p_include_seed: seed });
      if (error) throw new Error(error.message);
      return data;
    }
  }
}
