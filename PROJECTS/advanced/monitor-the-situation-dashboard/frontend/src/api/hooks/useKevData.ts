// ©AngelaMos | 2026
// useKevData.ts

import { useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { isValidKevEntry, type KevEntry } from '@/api/types'
import { API_ENDPOINTS, QUERY_KEYS } from '@/config'
import { apiClient } from '@/core/api'
import { useKevStore } from '@/stores/kev'

interface KevData {
  items: KevEntry[]
}

const INTEL_LIMIT = 100
const STALE_MS = 5 * 60_000

const fetchRecentKEV = async (): Promise<KevEntry[]> => {
  const res = await apiClient.get<unknown>(API_ENDPOINTS.INTEL.KEV, {
    params: { limit: INTEL_LIMIT },
  })
  if (!Array.isArray(res.data)) return []
  return res.data.filter(isValidKevEntry)
}

export function useKevData(): KevData {
  const items = useKevStore((s) => s.items)
  const push = useKevStore((s) => s.push)

  const { data } = useQuery({
    queryKey: QUERY_KEYS.INTEL.KEV(),
    queryFn: fetchRecentKEV,
    staleTime: STALE_MS,
  })

  useEffect(() => {
    if (!data) return
    for (const ev of data) push(ev)
  }, [data, push])

  return { items }
}
