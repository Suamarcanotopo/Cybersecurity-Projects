// ©AngelaMos | 2026
// useDShieldData.ts

import { useSnapshot } from '@/api/snapshot'
import { type DShieldData, isValidDShieldData } from '@/api/types'

export function useDShieldData(): DShieldData {
  const { data } = useSnapshot()
  const raw = data?.scan_firehose
  return isValidDShieldData(raw) ? raw : {}
}
