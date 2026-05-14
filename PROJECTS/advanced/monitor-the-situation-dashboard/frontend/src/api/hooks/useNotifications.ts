// ===================
// © AngelaMos | 2026
// useNotifications.ts
// ===================

import {
  type UseMutationResult,
  type UseQueryResult,
  useMutation,
  useQuery,
  useQueryClient,
} from '@tanstack/react-query'
import { toast } from 'sonner'
import {
  type ChannelListResponse,
  type ChannelResponse,
  type CreateChannelRequest,
  isValidChannelListResponse,
  isValidTelegramStatus,
  NOTIFICATION_ERROR_MESSAGES,
  NOTIFICATION_SUCCESS_MESSAGES,
  type RegisterTelegramRequest,
  type RegisterTelegramResponse,
  type TelegramStatusResponse,
} from '@/api/types'
import { API_ENDPOINTS, QUERY_KEYS } from '@/config'
import { apiClient } from '@/core/api'

export const notificationQueries = {
  channels: () => QUERY_KEYS.NOTIFICATIONS.CHANNELS(),
  telegramStatus: () => QUERY_KEYS.NOTIFICATIONS.TELEGRAM_STATUS(),
} as const

const fetchChannels = async (): Promise<ChannelListResponse> => {
  const response = await apiClient.get<unknown>(
    API_ENDPOINTS.NOTIFICATIONS.CHANNELS
  )
  const data: unknown = response.data

  if (!isValidChannelListResponse(data)) {
    throw new Error(NOTIFICATION_ERROR_MESSAGES.INVALID_RESPONSE)
  }

  return data
}

export const useNotificationChannels = (): UseQueryResult<
  ChannelListResponse,
  Error
> => {
  return useQuery({
    queryKey: notificationQueries.channels(),
    queryFn: fetchChannels,
    staleTime: 1000 * 30,
  })
}

const fetchTelegramStatus = async (): Promise<TelegramStatusResponse> => {
  const response = await apiClient.get<unknown>(
    API_ENDPOINTS.NOTIFICATIONS.TELEGRAM_STATUS
  )
  const data: unknown = response.data

  if (!isValidTelegramStatus(data)) {
    throw new Error(NOTIFICATION_ERROR_MESSAGES.INVALID_RESPONSE)
  }

  return data
}

export const useTelegramStatus = (): UseQueryResult<
  TelegramStatusResponse,
  Error
> => {
  return useQuery({
    queryKey: notificationQueries.telegramStatus(),
    queryFn: fetchTelegramStatus,
    staleTime: 1000 * 15,
  })
}

const performCreateChannel = async (
  data: CreateChannelRequest
): Promise<ChannelResponse> => {
  const response = await apiClient.post<ChannelResponse>(
    API_ENDPOINTS.NOTIFICATIONS.CHANNELS,
    data
  )
  return response.data
}

export const useCreateChannel = (): UseMutationResult<
  ChannelResponse,
  Error,
  CreateChannelRequest
> => {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: performCreateChannel,
    onSuccess: (): void => {
      void queryClient.invalidateQueries({
        queryKey: notificationQueries.channels(),
      })
      toast.success(NOTIFICATION_SUCCESS_MESSAGES.CHANNEL_ADDED)
    },
    onError: (): void => {
      toast.error(NOTIFICATION_ERROR_MESSAGES.CREATE_FAILED)
    },
  })
}

const performDeleteChannel = async (id: string): Promise<void> => {
  await apiClient.delete(API_ENDPOINTS.NOTIFICATIONS.CHANNEL_BY_ID(id))
}

export const useDeleteChannel = (): UseMutationResult<void, Error, string> => {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: performDeleteChannel,
    onSuccess: (): void => {
      void queryClient.invalidateQueries({
        queryKey: notificationQueries.channels(),
      })
      toast.success(NOTIFICATION_SUCCESS_MESSAGES.CHANNEL_DELETED)
    },
    onError: (): void => {
      toast.error(NOTIFICATION_ERROR_MESSAGES.DELETE_FAILED)
    },
  })
}

const performTestChannel = async (id: string): Promise<void> => {
  await apiClient.post(API_ENDPOINTS.NOTIFICATIONS.CHANNEL_TEST(id))
}

export const useTestChannel = (): UseMutationResult<void, Error, string> => {
  return useMutation({
    mutationFn: performTestChannel,
    onSuccess: (): void => {
      toast.success(NOTIFICATION_SUCCESS_MESSAGES.TEST_SENT)
    },
    onError: (error: Error): void => {
      toast.error(`${NOTIFICATION_ERROR_MESSAGES.TEST_FAILED}: ${error.message}`)
    },
  })
}

const performRegisterTelegram = async (
  data: RegisterTelegramRequest
): Promise<RegisterTelegramResponse> => {
  const response = await apiClient.post<RegisterTelegramResponse>(
    API_ENDPOINTS.NOTIFICATIONS.TELEGRAM,
    data
  )
  return response.data
}

export const useRegisterTelegram = (): UseMutationResult<
  RegisterTelegramResponse,
  Error,
  RegisterTelegramRequest
> => {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: performRegisterTelegram,
    onSuccess: (): void => {
      void queryClient.invalidateQueries({
        queryKey: notificationQueries.channels(),
      })
      void queryClient.invalidateQueries({
        queryKey: notificationQueries.telegramStatus(),
      })
      toast.success(NOTIFICATION_SUCCESS_MESSAGES.TELEGRAM_REGISTERED)
    },
    onError: (): void => {
      toast.error(NOTIFICATION_ERROR_MESSAGES.REGISTER_TELEGRAM_FAILED)
    },
  })
}

const performUnlinkTelegram = async (): Promise<void> => {
  await apiClient.delete(API_ENDPOINTS.NOTIFICATIONS.TELEGRAM)
}

export const useUnlinkTelegram = (): UseMutationResult<void, Error, void> => {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: performUnlinkTelegram,
    onSuccess: (): void => {
      void queryClient.invalidateQueries({
        queryKey: notificationQueries.channels(),
      })
      void queryClient.invalidateQueries({
        queryKey: notificationQueries.telegramStatus(),
      })
      toast.success(NOTIFICATION_SUCCESS_MESSAGES.TELEGRAM_UNLINKED)
    },
    onError: (): void => {
      toast.error(NOTIFICATION_ERROR_MESSAGES.UNLINK_TELEGRAM_FAILED)
    },
  })
}

const performTestTelegram = async (): Promise<void> => {
  await apiClient.post(API_ENDPOINTS.NOTIFICATIONS.TELEGRAM_TEST)
}

export const useTestTelegram = (): UseMutationResult<void, Error, void> => {
  return useMutation({
    mutationFn: performTestTelegram,
    onSuccess: (): void => {
      toast.success(NOTIFICATION_SUCCESS_MESSAGES.TEST_SENT)
    },
    onError: (error: Error): void => {
      toast.error(`${NOTIFICATION_ERROR_MESSAGES.TEST_FAILED}: ${error.message}`)
    },
  })
}
