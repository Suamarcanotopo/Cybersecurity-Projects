// ©AngelaMos | 2026
// useIssPosition.ts

import { useSnapshot } from '@/api/snapshot'
import { type IssPosition, isValidIssPosition } from '@/api/types'

export function useIssPosition(): IssPosition | undefined {
  const { data } = useSnapshot()
  const raw = data?.iss_position
  return isValidIssPosition(raw) ? raw : undefined
}
