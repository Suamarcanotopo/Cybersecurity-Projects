// ©AngelaMos | 2026
// cve.types.ts

import { z } from 'zod'

export const cveEventSchema = z.object({
  CveID: z.string(),
  Published: z.string(),
  LastModified: z.string(),
  Severity: z.string(),
  CVSS: z.number().nullable(),
  EPSSScore: z.number().nullable(),
  EPSSPercentile: z.number().nullable(),
  InKEV: z.boolean().optional(),
})

export type CveEvent = z.infer<typeof cveEventSchema>

export const kevEntrySchema = z.object({
  cveID: z.string(),
  vendorProject: z.string(),
  product: z.string(),
  vulnerabilityName: z.string(),
  dateAdded: z.string(),
  dueDate: z.string().optional(),
  knownRansomwareCampaignUse: z.string().optional(),
  shortDescription: z.string().optional(),
  requiredAction: z.string().optional(),
})

export type KevEntry = z.infer<typeof kevEntrySchema>

export const isValidCveEvent = (data: unknown): data is CveEvent => {
  if (data === null || data === undefined || typeof data !== 'object')
    return false
  return cveEventSchema.safeParse(data).success
}

export const isValidKevEntry = (data: unknown): data is KevEntry => {
  if (data === null || data === undefined || typeof data !== 'object')
    return false
  return kevEntrySchema.safeParse(data).success
}
