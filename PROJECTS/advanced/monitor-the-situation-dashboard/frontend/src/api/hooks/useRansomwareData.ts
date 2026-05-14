// ©AngelaMos | 2026
// useRansomwareData.ts

import { useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { isValidRansomwareVictim, type RansomwareVictim } from '@/api/types'
import { API_ENDPOINTS, QUERY_KEYS } from '@/config'
import { apiClient } from '@/core/api'
import { useRansomwareStore } from '@/stores/ransomware'

interface RansomwareData {
  items: RansomwareVictim[]
}

const INTEL_LIMIT = 100
const STALE_MS = 60_000

const fetchRecentRansomware = async (): Promise<RansomwareVictim[]> => {
  const res = await apiClient.get<unknown>(API_ENDPOINTS.INTEL.RANSOMWARE, {
    params: { limit: INTEL_LIMIT },
  })
  if (!Array.isArray(res.data)) return []
  return res.data.filter(isValidRansomwareVictim)
}

export function useRansomwareData(): RansomwareData {
  const items = useRansomwareStore((s) => s.items)
  const push = useRansomwareStore((s) => s.push)

  const { data } = useQuery({
    queryKey: QUERY_KEYS.INTEL.RANSOMWARE(),
    queryFn: fetchRecentRansomware,
    staleTime: STALE_MS,
  })

  useEffect(() => {
    if (!data) return
    for (const ev of data) push(ev)
  }, [data, push])

  return { items }
}
