// ===================
// ©AngelaMos | 2026
// common.types.ts
//
// Shared enum-like constants, Zod schemas, and types used across all API type modules
//
// Defines the core domain value sets (SourceType, Severity, AlertStatus,
// RuleType, RunStatus) as const objects with companion type aliases. Also
// exports the generic paginatedResponseSchema factory and PaginatedResponse<T>
// type used by every paginated API hook.
//
// Key exports:
//   Severity, AlertStatus, RuleType, SourceType, RunStatus - domain value sets
//   paginatedResponseSchema - generic Zod factory for paginated list responses
//   PaginatedResponse<T> - TypeScript type for paginated API responses
// ===================

import { z } from 'zod'

export const SourceType = {
  FIREWALL: 'firewall',
  IDS: 'ids',
  AUTH: 'auth',
  ENDPOINT: 'endpoint',
  DNS: 'dns',
  PROXY: 'proxy',
  GENERIC: 'generic',
} as const

export type SourceType = (typeof SourceType)[keyof typeof SourceType]

export const Severity = {
  CRITICAL: 'critical',
  HIGH: 'high',
  MEDIUM: 'medium',
  LOW: 'low',
  INFO: 'info',
} as const

export type Severity = (typeof Severity)[keyof typeof Severity]

export const AlertStatus = {
  NEW: 'new',
  ACKNOWLEDGED: 'acknowledged',
  INVESTIGATING: 'investigating',
  RESOLVED: 'resolved',
  FALSE_POSITIVE: 'false_positive',
} as const

export type AlertStatus = (typeof AlertStatus)[keyof typeof AlertStatus]

export const RuleType = {
  THRESHOLD: 'threshold',
  SEQUENCE: 'sequence',
  AGGREGATION: 'aggregation',
} as const

export type RuleType = (typeof RuleType)[keyof typeof RuleType]

export const RunStatus = {
  RUNNING: 'running',
  COMPLETED: 'completed',
  STOPPED: 'stopped',
  PAUSED: 'paused',
  ERROR: 'error',
} as const

export type RunStatus = (typeof RunStatus)[keyof typeof RunStatus]

export const paginatedResponseSchema = <T extends z.ZodTypeAny>(itemSchema: T) =>
  z.object({
    items: z.array(itemSchema),
    total: z.number(),
    page: z.number(),
    per_page: z.number(),
    pages: z.number(),
  })

export type PaginatedResponse<T> = {
  items: T[]
  total: number
  page: number
  per_page: number
  pages: number
}

export const deleteResponseSchema = z.object({
  deleted: z.boolean(),
})

export type DeleteResponse = z.infer<typeof deleteResponseSchema>

export const isValidDeleteResponse = (data: unknown): data is DeleteResponse => {
  return deleteResponseSchema.safeParse(data).success
}
