// ===================
// ©AngelaMos | 2026
// useScenarios.ts
//
// React Query hooks for scenario playbooks and running scenario lifecycle
//
// useAvailablePlaybooks fetches the static list of YAML playbooks from disk.
// useRunningScenarios polls every 10 seconds for active scenario runs.
// The five mutation hooks (start, stop, pause, resume, setSpeed) all
// invalidate the running scenarios query on success so the UI reflects
// the latest state immediately after each action.
//
// Key exports:
//   useAvailablePlaybooks - list of playbooks available to launch
//   useRunningScenarios - active scenario runs with status and progress
//   useStartScenario, useStopScenario - run lifecycle mutations
//   usePauseScenario, useResumeScenario - pause control mutations
//   useSetScenarioSpeed - playback speed mutation
//
// Connects to:
//   api.ts, config.ts - HTTP client and endpoint/key constants
//   scenario.types.ts - ScenarioRun, PlaybookInfo, ScenarioStartRequest
// ===================

import {
  type UseMutationResult,
  type UseQueryResult,
  useMutation,
  useQuery,
  useQueryClient,
} from '@tanstack/react-query'
import { toast } from 'sonner'
import type {
  PlaybookInfo,
  ScenarioRun,
  ScenarioStartRequest,
  SpeedRequest,
} from '@/api/types'
import { API_ENDPOINTS, QUERY_KEYS } from '@/config'
import { apiClient, QUERY_STRATEGIES } from '@/core/lib'

export const scenarioQueries = {
  all: () => QUERY_KEYS.SCENARIOS.ALL,
  available: () => QUERY_KEYS.SCENARIOS.AVAILABLE(),
  running: () => QUERY_KEYS.SCENARIOS.RUNNING(),
} as const

export const useAvailablePlaybooks = (): UseQueryResult<
  PlaybookInfo[],
  Error
> => {
  return useQuery({
    queryKey: scenarioQueries.available(),
    queryFn: async () => {
      const response = await apiClient.get<PlaybookInfo[]>(
        API_ENDPOINTS.SCENARIOS.AVAILABLE
      )
      return response.data
    },
  })
}

export const useRunningScenarios = (): UseQueryResult<ScenarioRun[], Error> => {
  return useQuery({
    queryKey: scenarioQueries.running(),
    queryFn: async () => {
      const response = await apiClient.get<ScenarioRun[]>(
        API_ENDPOINTS.SCENARIOS.RUNNING
      )
      return response.data
    },
    ...QUERY_STRATEGIES.frequent,
  })
}

export const useStartScenario = (): UseMutationResult<
  ScenarioRun,
  Error,
  ScenarioStartRequest
> => {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (payload: ScenarioStartRequest) => {
      const response = await apiClient.post<ScenarioRun>(
        API_ENDPOINTS.SCENARIOS.START,
        payload
      )
      return response.data
    },
    onSuccess: (data: ScenarioRun): void => {
      queryClient.invalidateQueries({ queryKey: scenarioQueries.running() })
      toast.success(`Scenario "${data.scenario_name}" started`)
    },
    onError: (error: Error): void => {
      toast.error(error.message)
    },
  })
}

export const useStopScenario = (): UseMutationResult<
  ScenarioRun,
  Error,
  string
> => {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (runId: string) => {
      const response = await apiClient.post<ScenarioRun>(
        API_ENDPOINTS.SCENARIOS.STOP(runId)
      )
      return response.data
    },
    onSuccess: (): void => {
      queryClient.invalidateQueries({ queryKey: scenarioQueries.running() })
      toast.success('Scenario stopped')
    },
    onError: (error: Error): void => {
      toast.error(error.message)
    },
  })
}

export const usePauseScenario = (): UseMutationResult<
  ScenarioRun,
  Error,
  string
> => {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (runId: string) => {
      const response = await apiClient.post<ScenarioRun>(
        API_ENDPOINTS.SCENARIOS.PAUSE(runId)
      )
      return response.data
    },
    onSuccess: (): void => {
      queryClient.invalidateQueries({ queryKey: scenarioQueries.running() })
      toast.success('Scenario paused')
    },
    onError: (error: Error): void => {
      toast.error(error.message)
    },
  })
}

export const useResumeScenario = (): UseMutationResult<
  ScenarioRun,
  Error,
  string
> => {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (runId: string) => {
      const response = await apiClient.post<ScenarioRun>(
        API_ENDPOINTS.SCENARIOS.RESUME(runId)
      )
      return response.data
    },
    onSuccess: (): void => {
      queryClient.invalidateQueries({ queryKey: scenarioQueries.running() })
      toast.success('Scenario resumed')
    },
    onError: (error: Error): void => {
      toast.error(error.message)
    },
  })
}

export const useSetScenarioSpeed = (
  runId: string
): UseMutationResult<ScenarioRun, Error, SpeedRequest> => {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (payload: SpeedRequest) => {
      const response = await apiClient.put<ScenarioRun>(
        API_ENDPOINTS.SCENARIOS.SPEED(runId),
        payload
      )
      return response.data
    },
    onSuccess: (data: ScenarioRun): void => {
      queryClient.invalidateQueries({ queryKey: scenarioQueries.running() })
      toast.success(`Speed set to ${data.speed}x`)
    },
    onError: (error: Error): void => {
      toast.error(error.message)
    },
  })
}
