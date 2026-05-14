// ©AngelaMos | 2026
// threat.types.ts

import { z } from 'zod'

export const ransomwareVictimSchema = z.object({
  post_title: z.string(),
  group_name: z.string(),
  discovered: z.string(),
  country: z.string().optional(),
  activity: z.string().optional(),
  website: z.string().optional(),
  description: z.string().optional(),
})

export type RansomwareVictim = z.infer<typeof ransomwareVictimSchema>

export const dshieldPortSchema = z.object({
  rank: z.number(),
  targetport: z.number(),
  records: z.number(),
  targets: z.number(),
  sources: z.number(),
})

export type DShieldPort = z.infer<typeof dshieldPortSchema>

export const dshieldSourceSchema = z.object({
  rank: z.number(),
  source: z.string(),
  reports: z.number(),
  targets: z.number(),
  country: z.string().optional(),
  classification: z.string().optional(),
  actor: z.string().optional(),
})

export type DShieldSource = z.infer<typeof dshieldSourceSchema>

export const dshieldDailySummarySchema = z.object({
  date: z.string(),
  records: z.number(),
  sources: z.number(),
  targets: z.number(),
})

export type DShieldDailySummary = z.infer<typeof dshieldDailySummarySchema>

export const dshieldDataSchema = z.object({
  topports: z
    .union([z.record(z.string(), z.unknown()), z.array(z.unknown())])
    .optional(),
  topips: z.array(dshieldSourceSchema).optional(),
  dailysummary: z.array(dshieldDailySummarySchema).optional(),
  ts: z.string().optional(),
})

export type DShieldData = z.infer<typeof dshieldDataSchema>

export const isValidRansomwareVictim = (
  data: unknown
): data is RansomwareVictim => {
  if (data === null || data === undefined || typeof data !== 'object')
    return false
  return ransomwareVictimSchema.safeParse(data).success
}

export const isValidDShieldData = (data: unknown): data is DShieldData => {
  if (data === null || data === undefined || typeof data !== 'object')
    return false
  return dshieldDataSchema.safeParse(data).success
}

const bgpHijackEnrichmentSchema = z.object({
  country: z.string().optional(),
  abuse_confidence: z.number().optional(),
  isp: z.string().optional(),
  checked_ip: z.string().optional(),
})

export const bgpHijackSchema = z.object({
  id: z.number(),
  detectedAt: z.string().optional(),
  startedAt: z.string().optional(),
  duration: z.number().optional(),
  confidenceScore: z.number().optional(),
  hijackerAsn: z.number().optional(),
  victimAsns: z.array(z.number()).nullable().optional(),
  prefixes: z.array(z.string()).optional(),
  enrichment: bgpHijackEnrichmentSchema.optional(),
})

export type BgpHijack = z.infer<typeof bgpHijackSchema>

export const isValidBgpHijack = (data: unknown): data is BgpHijack => {
  if (data === null || data === undefined || typeof data !== 'object')
    return false
  return bgpHijackSchema.safeParse(data).success
}
