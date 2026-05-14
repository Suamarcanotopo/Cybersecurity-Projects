// ©AngelaMos | 2026
// intel.types.ts

import { z } from 'zod'

export const spaceWeatherDataSchema = z.object({
  kp: z.number().optional(),
  bz_gsm: z.number().optional(),
  speed_kms: z.number().optional(),
  density: z.number().optional(),
  xray_class: z.string().optional(),
  xray_flux: z.number().optional(),
  ts: z.string().optional(),
  pushed: z.number().optional(),
})

export type SpaceWeatherData = z.infer<typeof spaceWeatherDataSchema>

export const wikiItnSchema = z.object({
  slug: z.string(),
  text: z.string(),
})

export type WikiItn = z.infer<typeof wikiItnSchema>

export const gdeltSpikeSchema = z.object({
  theme: z.string(),
  time: z.string(),
  count: z.number(),
  zscore: z.number(),
})

export type GdeltSpike = z.infer<typeof gdeltSpikeSchema>

export const isValidSpaceWeatherData = (
  data: unknown
): data is SpaceWeatherData => {
  if (data === null || data === undefined || typeof data !== 'object')
    return false
  return spaceWeatherDataSchema.safeParse(data).success
}

export const isValidWikiItn = (data: unknown): data is WikiItn => {
  if (data === null || data === undefined || typeof data !== 'object')
    return false
  return wikiItnSchema.safeParse(data).success
}

export const isValidGdeltSpike = (data: unknown): data is GdeltSpike => {
  if (data === null || data === undefined || typeof data !== 'object')
    return false
  return gdeltSpikeSchema.safeParse(data).success
}
