// ©AngelaMos | 2026
// useCveData.ts

import { useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { type CveEvent, isValidCveEvent } from '@/api/types'
import { API_ENDPOINTS, QUERY_KEYS } from '@/config'
import { apiClient } from '@/core/api'
import { useCveStore } from '@/stores/cve'

interface CveData {
  items: CveEvent[]
}

const INTEL_LIMIT = 200
const STALE_MS = 5 * 60_000

const fetchRecentCVEs = async (): Promise<CveEvent[]> => {
  const res = await apiClient.get<unknown>(API_ENDPOINTS.INTEL.CVES, {
    params: { limit: INTEL_LIMIT },
  })
  if (!Array.isArray(res.data)) return []
  return res.data.filter(isValidCveEvent)
}

export function useCveData(): CveData {
  const items = useCveStore((s) => s.items)
  const push = useCveStore((s) => s.push)

  // /intel/cves backfills the panel on cold load. WS deltas (cve_new) layer
  // on top via the dashboard lifecycle. Snapshot's single-event slot is no
  // longer the source of truth here.
  const { data } = useQuery({
    queryKey: QUERY_KEYS.INTEL.CVES(),
    queryFn: fetchRecentCVEs,
    staleTime: STALE_MS,
  })

  useEffect(() => {
    if (!data) return
    for (const ev of data) push(ev)
  }, [data, push])

  return { items }
}
