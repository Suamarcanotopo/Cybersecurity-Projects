// ©AngelaMos | 2026
// snapshot.ts

import { useQuery } from '@tanstack/react-query'
import { apiClient } from '@/core/api'

export type Snapshot = Record<string, unknown>

export const SNAPSHOT_KEY = ['snapshot'] as const

export function useSnapshot() {
  return useQuery({
    queryKey: SNAPSHOT_KEY,
    queryFn: async (): Promise<Snapshot> => {
      const res = await apiClient.get<Snapshot>('/v1/snapshot')
      return res.data
    },
    staleTime: Number.POSITIVE_INFINITY,
    gcTime: Number.POSITIVE_INFINITY,
  })
}
