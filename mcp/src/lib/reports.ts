import { db } from "../db.js";

export type ReportKind = "funnel" | "channel_stats" | "activity_daily" | "quality_summary";

/** Reportes agregados del CRM (mismas RPCs del dashboard /reports y /quality). */
export async function getReport(input: { report: ReportKind; days?: number }) {
  switch (input.report) {
    case "funnel": {
      const { data, error } = await db.rpc("report_funnel");
      if (error) throw new Error(error.message);
      return data;
    }
    case "channel_stats": {
      const { data, error } = await db.rpc("report_channel_stats", { p_days: input.days ?? 30 });
      if (error) throw new Error(error.message);
      return data;
    }
    case "activity_daily": {
      const { data, error } = await db.rpc("report_activity_daily", { p_days: input.days ?? 14 });
      if (error) throw new Error(error.message);
      return data;
    }
    case "quality_summary": {
      const { data, error } = await db.rpc("lead_quality_summary");
      if (error) throw new Error(error.message);
      return data;
    }
  }
}
