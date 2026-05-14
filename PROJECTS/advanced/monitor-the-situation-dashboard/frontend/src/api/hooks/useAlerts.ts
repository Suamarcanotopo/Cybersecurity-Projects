// ===================
// © AngelaMos | 2026
// useAlerts.ts
// ===================

import {
  type UseMutationResult,
  type UseQueryResult,
  useMutation,
  useQuery,
  useQueryClient,
} from '@tanstack/react-query'
import { toast } from 'sonner'
import { apiClient } from '@/core/api'

export interface AlertRule {
  id: string
  name: string
  topic: string
  predicate: string
  cooldown_sec: number
  enabled: boolean
  created_at: string
  updated_at: string
}

const ALERT_RULES_KEY = ['me', 'alerts'] as const
const ALERT_HISTORY_KEY = ['me', 'alerts', 'history'] as const

const fetchRules = async (): Promise<AlertRule[]> => {
  const res = await apiClient.get<AlertRule[]>('/v1/me/alerts/')
  return Array.isArray(res.data) ? res.data : []
}

export const useAlertRules = (): UseQueryResult<AlertRule[], Error> =>
  useQuery({
    queryKey: ALERT_RULES_KEY,
    queryFn: fetchRules,
    staleTime: 30_000,
  })

interface UpdateRuleVars {
  id: string
  patch: Partial<
    Pick<AlertRule, 'name' | 'predicate' | 'cooldown_sec' | 'enabled'>
  >
}

const performUpdateRule = async ({
  id,
  patch,
}: UpdateRuleVars): Promise<AlertRule> => {
  const res = await apiClient.patch<AlertRule>(`/v1/me/alerts/${id}`, patch)
  return res.data
}

export const useUpdateAlertRule = (): UseMutationResult<
  AlertRule,
  Error,
  UpdateRuleVars
> => {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: performUpdateRule,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ALERT_RULES_KEY })
    },
    onError: () => {
      toast.error('Failed to update alert rule')
    },
  })
}

const performDeleteRule = async (id: string): Promise<void> => {
  await apiClient.delete(`/v1/me/alerts/${id}`)
}

export const useDeleteAlertRule = (): UseMutationResult<void, Error, string> => {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: performDeleteRule,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ALERT_RULES_KEY })
      toast.success('Rule removed')
    },
    onError: () => {
      toast.error('Failed to remove rule')
    },
  })
}

export interface AlertHistoryEntry {
  id: number
  rule_id: string
  fired_at: string
  delivered_to: string[] | null
}

const fetchHistory = async (): Promise<AlertHistoryEntry[]> => {
  const res = await apiClient.get<AlertHistoryEntry[]>(
    '/v1/me/alerts/history?limit=20'
  )
  return Array.isArray(res.data) ? res.data : []
}

export const useAlertHistory = (): UseQueryResult<AlertHistoryEntry[], Error> =>
  useQuery({
    queryKey: ALERT_HISTORY_KEY,
    queryFn: fetchHistory,
    staleTime: 15_000,
  })
