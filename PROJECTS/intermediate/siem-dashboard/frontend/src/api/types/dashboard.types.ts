// ===================
// ©AngelaMos | 2026
// dashboard.types.ts
//
// Zod schemas and types for all dashboard API responses
//
// Covers the overview stats block, timeline buckets, and top source IP
// entries. Each schema has a companion type alias, runtime type guard,
// and where applicable a request param interface for the hook layer.
//
// Key exports:
//   dashboardOverviewSchema, DashboardOverview - combined stats block
//   timelineBucketSchema, TimelineBucket - per-bucket event count
//   topSourceSchema, TopSource - source IP with event count
//   TimelineParams, TopSourcesParams - query param interfaces
//
// Connects to:
//   useDashboard.ts - consumes all these types
//   event-timeline.tsx, severity-chart.tsx, stat-cards.tsx, top-sources.tsx - render data
// ===================

import { z } from 'zod'

export const severityCountSchema = z.object({
  severity: z.string(),
  count: z.number(),
})

export const dashboardOverviewSchema = z.object({
  total_events: z.number(),
  total_alerts: z.number(),
  open_alerts: z.number(),
  alerts_by_status: z.record(z.string(), z.number()),
  severity_breakdown: z.array(severityCountSchema),
})

export const timelineBucketSchema = z.object({
  bucket: z.string(),
  count: z.number(),
})

export const topSourceSchema = z.object({
  source_ip: z.string(),
  count: z.number(),
})

export type SeverityCount = z.infer<typeof severityCountSchema>
export type DashboardOverview = z.infer<typeof dashboardOverviewSchema>
export type TimelineBucket = z.infer<typeof timelineBucketSchema>
export type TopSource = z.infer<typeof topSourceSchema>

export interface TimelineParams {
  hours?: number
  bucket_minutes?: number
}

export interface TopSourcesParams {
  limit?: number
}

export const isValidDashboardOverview = (
  data: unknown
): data is DashboardOverview => {
  return dashboardOverviewSchema.safeParse(data).success
}

export const isValidTimelineBucket = (data: unknown): data is TimelineBucket => {
  return timelineBucketSchema.safeParse(data).success
}

export const isValidTopSource = (data: unknown): data is TopSource => {
  return topSourceSchema.safeParse(data).success
}
