// ===================
// ©AngelaMos | 2026
// log.types.ts
//
// Zod schemas and types for log event list, detail, and SSE stream responses
//
// Exports the full logEventSchema for detail and paginated views, and the
// slimmer streamLogEventSchema for the real-time SSE feed. Also exports
// query param interfaces for list, search, and forensic pivot requests.
//
// Key exports:
//   logEventSchema, LogEvent - complete log event document type
//   streamLogEventSchema, StreamLogEvent - compact SSE feed payload type
//   LogQueryParams, LogSearchParams, PivotParams - API request param types
//
// Connects to:
//   alert.types.ts - logEventSchema imported for alertDetailSchema
//   useLogs.ts, useEventStream.ts - consume these types
// ===================

import { z } from 'zod'

export const logEventSchema = z.object({
  id: z.string(),
  timestamp: z.string(),
  source_type: z.string(),
  source_ip: z.string().nullable(),
  dest_ip: z.string().nullable(),
  source_port: z.number().nullable(),
  dest_port: z.number().nullable(),
  severity: z.string(),
  event_type: z.string().nullable(),
  raw: z.record(z.string(), z.unknown()),
  normalized: z.record(z.string(), z.unknown()),
  metadata: z.record(z.string(), z.unknown()),
  hostname: z.string().nullable(),
  username: z.string().nullable(),
  mitre_tactic: z.string().nullable(),
  mitre_technique: z.string().nullable(),
  scenario_run_id: z.string().nullable(),
  matched_alert_ids: z.array(z.string()),
  created_at: z.string(),
  updated_at: z.string(),
})

export const streamLogEventSchema = z.object({
  id: z.string(),
  timestamp: z.string(),
  source_type: z.string(),
  severity: z.string(),
  event_type: z.string().nullable(),
  source_ip: z.string().nullable(),
  dest_ip: z.string().nullable(),
  hostname: z.string().nullable(),
  username: z.string().nullable(),
})

export type LogEvent = z.infer<typeof logEventSchema>
export type StreamLogEvent = z.infer<typeof streamLogEventSchema>

export interface LogQueryParams {
  page?: number
  per_page?: number
  source_type?: string
  severity?: string
  source_ip?: string
  event_type?: string
}

export interface LogSearchParams {
  q: string
  page?: number
  per_page?: number
}

export interface PivotParams {
  ip?: string
  username?: string
  hostname?: string
}

export const isValidLogEvent = (data: unknown): data is LogEvent => {
  return logEventSchema.safeParse(data).success
}

export const isValidStreamLogEvent = (data: unknown): data is StreamLogEvent => {
  return streamLogEventSchema.safeParse(data).success
}
