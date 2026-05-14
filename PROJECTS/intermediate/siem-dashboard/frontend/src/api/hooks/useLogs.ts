// ===================
// ©AngelaMos | 2026
// useLogs.ts
//
// React Query hooks for the logs API: list, detail, full-text search, and pivot
//
// useLogs returns a paginated, filterable event list polled on the frequent
// strategy. useLogSearch queries the full-text search endpoint and is only
// enabled when a query string is present. useLogPivot fetches all events
// matching a given IP, username, or hostname for alert investigation.
//
// Key exports:
//   useLogs - paginated log list with source/severity filtering
//   useLogDetail - single event by ID
//   useLogSearch - full-text search across log events
//   useLogPivot - cross-field pivot for forensic investigation
//
// Connects to:
//   api.ts, config.ts - HTTP client and endpoint/key constants
//   log.types.ts - LogEvent, LogQueryParams, LogSearchParams, PivotParams
// ===================

import type { UseQueryResult } from '@tanstack/react-query'
import { useQuery } from '@tanstack/react-query'
import type {
  LogEvent,
  LogQueryParams,
  LogSearchParams,
  PaginatedResponse,
  PivotParams,
} from '@/api/types'
import { API_ENDPOINTS, PAGINATION, QUERY_KEYS } from '@/config'
import { apiClient, QUERY_STRATEGIES } from '@/core/lib'

export const logQueries = {
  all: () => QUERY_KEYS.LOGS.ALL,
  list: (page: number, size: number) => QUERY_KEYS.LOGS.LIST(page, size),
  byId: (id: string) => QUERY_KEYS.LOGS.BY_ID(id),
  search: (query: string, page: number, size: number) =>
    QUERY_KEYS.LOGS.SEARCH(query, page, size),
  pivot: (params: PivotParams) => QUERY_KEYS.LOGS.PIVOT(params),
} as const

export const useLogs = (
  params: LogQueryParams = {}
): UseQueryResult<PaginatedResponse<LogEvent>, Error> => {
  const page = params.page ?? PAGINATION.DEFAULT_PAGE
  const perPage = params.per_page ?? PAGINATION.DEFAULT_SIZE

  return useQuery({
    queryKey: logQueries.list(page, perPage),
    queryFn: async () => {
      const response = await apiClient.get<PaginatedResponse<LogEvent>>(
        API_ENDPOINTS.LOGS.LIST,
        { params }
      )
      return response.data
    },
    ...QUERY_STRATEGIES.frequent,
  })
}

export const useLogDetail = (logId: string): UseQueryResult<LogEvent, Error> => {
  return useQuery({
    queryKey: logQueries.byId(logId),
    queryFn: async () => {
      const response = await apiClient.get<LogEvent>(
        API_ENDPOINTS.LOGS.BY_ID(logId)
      )
      return response.data
    },
    enabled: logId.length > 0,
  })
}

export const useLogSearch = (
  params: LogSearchParams
): UseQueryResult<PaginatedResponse<LogEvent>, Error> => {
  const page = params.page ?? PAGINATION.DEFAULT_PAGE
  const perPage = params.per_page ?? PAGINATION.DEFAULT_SIZE

  return useQuery({
    queryKey: logQueries.search(params.q, page, perPage),
    queryFn: async () => {
      const response = await apiClient.get<PaginatedResponse<LogEvent>>(
        API_ENDPOINTS.LOGS.SEARCH,
        { params }
      )
      return response.data
    },
    enabled: params.q.length > 0,
    ...QUERY_STRATEGIES.frequent,
  })
}

export const useLogPivot = (
  params: PivotParams
): UseQueryResult<LogEvent[], Error> => {
  return useQuery({
    queryKey: logQueries.pivot(params),
    queryFn: async () => {
      const response = await apiClient.get<LogEvent[]>(API_ENDPOINTS.LOGS.PIVOT, {
        params,
      })
      return response.data
    },
    enabled:
      params.ip !== undefined ||
      params.username !== undefined ||
      params.hostname !== undefined,
  })
}
