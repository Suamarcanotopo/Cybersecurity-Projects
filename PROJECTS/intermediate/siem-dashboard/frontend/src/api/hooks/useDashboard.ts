// ===================
// ©AngelaMos | 2026
// useDashboard.ts
//
// React Query hooks for the four dashboard data endpoints
//
// All four hooks use the dashboard query strategy (30s stale, 30s polling)
// so every panel refreshes together at the same cadence. useDashboardOverview
// fetches aggregate counts. useTimeline defaults to a 24h window with 15-minute
// buckets. useSeverityBreakdown returns per-severity alert counts.
// useTopSources returns the highest-volume source IPs by event count.
//
// Key exports:
//   useDashboardOverview - total events, alerts, open alerts, severity counts
//   useTimeline - time-bucketed event counts for the area chart
//   useSeverityBreakdown - per-severity counts for the donut chart
//   useTopSources - ranked source IPs for the bar list
//
// Connects to:
//   api.ts, config.ts - HTTP client and endpoint/key constants
//   dashboard.types.ts - DashboardOverview, TimelineBucket, TopSource
// ===================

import type { UseQueryResult } from '@tanstack/react-query'
import { useQuery } from '@tanstack/react-query'
import type {
  DashboardOverview,
  SeverityCount,
  TimelineBucket,
  TopSource,
} from '@/api/types'
import { API_ENDPOINTS, QUERY_KEYS } from '@/config'
import { apiClient, QUERY_STRATEGIES } from '@/core/lib'

export const dashboardQueries = {
  all: () => QUERY_KEYS.DASHBOARD.ALL,
  overview: () => QUERY_KEYS.DASHBOARD.OVERVIEW(),
  timeline: (hours: number, bucket: number) =>
    QUERY_KEYS.DASHBOARD.TIMELINE(hours, bucket),
  severity: () => QUERY_KEYS.DASHBOARD.SEVERITY(),
  topSources: (limit: number) => QUERY_KEYS.DASHBOARD.TOP_SOURCES(limit),
} as const

export const useDashboardOverview = (): UseQueryResult<
  DashboardOverview,
  Error
> => {
  return useQuery({
    queryKey: dashboardQueries.overview(),
    queryFn: async () => {
      const response = await apiClient.get<DashboardOverview>(
        API_ENDPOINTS.DASHBOARD.OVERVIEW
      )
      return response.data
    },
    ...QUERY_STRATEGIES.dashboard,
  })
}

export const useTimeline = (
  hours = 24,
  bucketMinutes = 15
): UseQueryResult<TimelineBucket[], Error> => {
  return useQuery({
    queryKey: dashboardQueries.timeline(hours, bucketMinutes),
    queryFn: async () => {
      const response = await apiClient.get<TimelineBucket[]>(
        API_ENDPOINTS.DASHBOARD.TIMELINE,
        { params: { hours, bucket_minutes: bucketMinutes } }
      )
      return response.data
    },
    ...QUERY_STRATEGIES.dashboard,
  })
}

export const useSeverityBreakdown = (): UseQueryResult<
  SeverityCount[],
  Error
> => {
  return useQuery({
    queryKey: dashboardQueries.severity(),
    queryFn: async () => {
      const response = await apiClient.get<SeverityCount[]>(
        API_ENDPOINTS.DASHBOARD.SEVERITY
      )
      return response.data
    },
    ...QUERY_STRATEGIES.dashboard,
  })
}

export const useTopSources = (limit = 10): UseQueryResult<TopSource[], Error> => {
  return useQuery({
    queryKey: dashboardQueries.topSources(limit),
    queryFn: async () => {
      const response = await apiClient.get<TopSource[]>(
        API_ENDPOINTS.DASHBOARD.TOP_SOURCES,
        { params: { limit } }
      )
      return response.data
    },
    ...QUERY_STRATEGIES.dashboard,
  })
}
