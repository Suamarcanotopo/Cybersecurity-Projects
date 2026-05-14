// ©AngelaMos | 2026
// coinbase.types.ts

import { z } from 'zod'

export const coinbaseTickSchema = z.object({
  symbol: z.string(),
  ts: z.string(),
  price: z.string(),
  volume_24h: z.string().optional(),
})

export type CoinbaseTick = z.infer<typeof coinbaseTickSchema>

export const coinbasePriceMapSchema = z.record(z.string(), coinbaseTickSchema)

export type CoinbasePriceMap = z.infer<typeof coinbasePriceMapSchema>

export const isValidCoinbaseTick = (data: unknown): data is CoinbaseTick => {
  if (data === null || data === undefined || typeof data !== 'object')
    return false
  return coinbaseTickSchema.safeParse(data).success
}

export const isValidCoinbasePriceMap = (
  data: unknown
): data is CoinbasePriceMap => {
  if (data === null || data === undefined || typeof data !== 'object')
    return false
  if (Array.isArray(data)) return false
  return coinbasePriceMapSchema.safeParse(data).success
}
