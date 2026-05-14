// ©AngelaMos | 2026
// useEarthquakeData.ts

import { useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { type EarthquakePayload, isValidEarthquakePayload } from '@/api/types'
import { API_ENDPOINTS, QUERY_KEYS } from '@/config'
import { apiClient } from '@/core/api'
import { useEarthquakeStore } from '@/stores/earthquake'

interface EarthquakeData {
  items: EarthquakePayload[]
}

const INTEL_LIMIT = 100
const STALE_MS = 60_000

const fetchRecentQuakes = async (): Promise<EarthquakePayload[]> => {
  const res = await apiClient.get<unknown>(API_ENDPOINTS.INTEL.QUAKES, {
    params: { limit: INTEL_LIMIT },
  })
  if (!Array.isArray(res.data)) return []
  return res.data.filter(isValidEarthquakePayload)
}

export function useEarthquakeData(): EarthquakeData {
  const items = useEarthquakeStore((s) => s.items)
  const push = useEarthquakeStore((s) => s.push)

  const { data } = useQuery({
    queryKey: QUERY_KEYS.INTEL.QUAKES(),
    queryFn: fetchRecentQuakes,
    staleTime: STALE_MS,
  })

  useEffect(() => {
    if (!data) return
    for (const ev of data) push(ev)
  }, [data, push])

  return { items }
}
