// ===================
// ©AngelaMos | 2026
// alert.types.ts
//
// Zod schemas and types for alert list, detail, and SSE stream responses
//
// Exports the main alertSchema for paginated list data, alertDetailSchema
// that includes matched log events, and the lighter streamAlertEventSchema
// used by the SSE feed. Each schema has a companion type alias and runtime
// type guard.
//
// Key exports:
//   alertSchema, Alert - full alert document type
//   alertDetailSchema, AlertDetail - alert plus matched log events
//   streamAlertEventSchema, StreamAlertEvent - compact SSE payload type
//   AlertStatusUpdateRequest - mutation payload for status changes
//
// Connects to:
//   log.types.ts - imports logEventSchema for alertDetailSchema
//   useAlerts.ts, useEventStream.ts - consume these types
// ===================

import { z } from 'zod'
import { logEventSchema } from './log.types'

export const alertSchema = z.object({
  id: z.string(),
  rule_id: z.string(),
  rule_name: z.string(),
  severity: z.string(),
  title: z.string(),
  matched_event_ids: z.array(z.string()),
  matched_event_count: z.number(),
  group_value: z.string().nullable(),
  status: z.string(),
  mitre_tactic: z.string().nullable(),
  mitre_technique: z.string().nullable(),
  acknowledged_by: z.string().nullable(),
  acknowledged_at: z.string().nullable(),
  resolved_at: z.string().nullable(),
  notes: z.string().nullable(),
  created_at: z.string(),
  updated_at: z.string(),
})

export const alertDetailSchema = z.object({
  alert: alertSchema,
  matched_events: z.array(logEventSchema),
})

export const streamAlertEventSchema = z.object({
  id: z.string(),
  rule_name: z.string(),
  severity: z.string(),
  title: z.string(),
  group_value: z.string().nullable(),
  matched_event_count: z.number(),
  status: z.string(),
})

export type Alert = z.infer<typeof alertSchema>
export type AlertDetail = z.infer<typeof alertDetailSchema>
export type StreamAlertEvent = z.infer<typeof streamAlertEventSchema>

export interface AlertStatusUpdateRequest {
  status: string
  notes?: string
}

export interface AlertQueryParams {
  page?: number
  per_page?: number
  status?: string
  severity?: string
}

export const isValidAlert = (data: unknown): data is Alert => {
  return alertSchema.safeParse(data).success
}

export const isValidAlertDetail = (data: unknown): data is AlertDetail => {
  return alertDetailSchema.safeParse(data).success
}

export const isValidStreamAlertEvent = (
  data: unknown
): data is StreamAlertEvent => {
  return streamAlertEventSchema.safeParse(data).success
}
