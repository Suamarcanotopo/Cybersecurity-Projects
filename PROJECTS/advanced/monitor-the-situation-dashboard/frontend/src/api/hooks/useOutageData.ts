// ©AngelaMos | 2026
// useOutageData.ts

import { useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { type InternetOutage, isValidInternetOutage } from '@/api/types'
import { API_ENDPOINTS, QUERY_KEYS } from '@/config'
import { apiClient } from '@/core/api'
import { useOutageStore } from '@/stores/outage'

interface OutageData {
  items: InternetOutage[]
}

const INTEL_LIMIT = 100
const STALE_MS = 60_000

const fetchRecentOutages = async (): Promise<InternetOutage[]> => {
  const res = await apiClient.get<unknown>(API_ENDPOINTS.INTEL.OUTAGES, {
    params: { limit: INTEL_LIMIT },
  })
  if (!Array.isArray(res.data)) return []
  return res.data.filter(isValidInternetOutage)
}

export function useOutageData(): OutageData {
  const items = useOutageStore((s) => s.items)
  const push = useOutageStore((s) => s.push)

  const { data } = useQuery({
    queryKey: QUERY_KEYS.INTEL.OUTAGES(),
    queryFn: fetchRecentOutages,
    staleTime: STALE_MS,
  })

  useEffect(() => {
    if (!data) return
    for (const ev of data) push(ev)
  }, [data, push])

  return { items }
}
