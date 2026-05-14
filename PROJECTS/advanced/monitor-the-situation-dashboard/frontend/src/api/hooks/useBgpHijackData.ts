// ©AngelaMos | 2026
// useBgpHijackData.ts

import { useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { type BgpHijack, isValidBgpHijack } from '@/api/types'
import { API_ENDPOINTS, QUERY_KEYS } from '@/config'
import { apiClient } from '@/core/api'
import { useBgpHijackStore } from '@/stores/bgpHijack'

interface BgpHijackData {
  items: BgpHijack[]
}

const INTEL_LIMIT = 100
const STALE_MS = 60_000

const fetchRecentHijacks = async (): Promise<BgpHijack[]> => {
  const res = await apiClient.get<unknown>(API_ENDPOINTS.INTEL.HIJACKS, {
    params: { limit: INTEL_LIMIT },
  })
  if (!Array.isArray(res.data)) return []
  return res.data.filter(isValidBgpHijack)
}

export function useBgpHijackData(): BgpHijackData {
  const items = useBgpHijackStore((s) => s.items)
  const push = useBgpHijackStore((s) => s.push)

  const { data } = useQuery({
    queryKey: QUERY_KEYS.INTEL.HIJACKS(),
    queryFn: fetchRecentHijacks,
    staleTime: STALE_MS,
  })

  useEffect(() => {
    if (!data) return
    for (const ev of data) push(ev)
  }, [data, push])

  return { items }
}
