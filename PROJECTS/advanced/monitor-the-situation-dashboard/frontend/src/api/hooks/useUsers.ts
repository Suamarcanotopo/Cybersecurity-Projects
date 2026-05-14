// ===================
// © AngelaMos | 2025
// useUsers.ts
// ===================

import {
  type UseMutationResult,
  useMutation,
  useQueryClient,
} from '@tanstack/react-query'
import { toast } from 'sonner'
import {
  isValidUserResponse,
  USER_ERROR_MESSAGES,
  USER_SUCCESS_MESSAGES,
  type UserCreateRequest,
  type UserResponse,
  UserResponseError,
  type UserUpdateRequest,
} from '@/api/types'
import { API_ENDPOINTS, QUERY_KEYS } from '@/config'
import { apiClient } from '@/core/api'
import { useAuthStore } from '@/core/lib'
import { authQueries } from './useAuth'

export const userQueries = {
  all: () => QUERY_KEYS.USERS.ALL,
  me: () => QUERY_KEYS.USERS.ME(),
} as const

const performRegister = async (data: UserCreateRequest): Promise<void> => {
  await apiClient.post(API_ENDPOINTS.AUTH.REGISTER, data)
}

export const useRegister = (): UseMutationResult<
  void,
  Error,
  UserCreateRequest
> => {
  return useMutation({
    mutationFn: performRegister,
    onSuccess: (): void => {
      toast.success(USER_SUCCESS_MESSAGES.REGISTERED)
    },
    onError: (error: Error): void => {
      const message =
        error instanceof UserResponseError
          ? error.message
          : USER_ERROR_MESSAGES.FAILED_TO_CREATE
      toast.error(message)
    },
  })
}

const performUpdateProfile = async (
  data: UserUpdateRequest
): Promise<UserResponse> => {
  const response = await apiClient.put<unknown>(API_ENDPOINTS.USERS.ME, data)
  const responseData: unknown = response.data

  if (!isValidUserResponse(responseData)) {
    throw new UserResponseError(
      USER_ERROR_MESSAGES.INVALID_USER_RESPONSE,
      API_ENDPOINTS.USERS.ME
    )
  }

  return responseData
}

export const useUpdateProfile = (): UseMutationResult<
  UserResponse,
  Error,
  UserUpdateRequest
> => {
  const queryClient = useQueryClient()
  const updateUser = useAuthStore((s) => s.updateUser)

  return useMutation({
    mutationFn: performUpdateProfile,
    onSuccess: (data: UserResponse): void => {
      updateUser(data)

      queryClient.setQueryData(authQueries.me(), data)
      queryClient.setQueryData(userQueries.me(), data)

      toast.success(USER_SUCCESS_MESSAGES.PROFILE_UPDATED)
    },
    onError: (error: Error): void => {
      const message =
        error instanceof UserResponseError
          ? error.message
          : USER_ERROR_MESSAGES.FAILED_TO_UPDATE
      toast.error(message)
    },
  })
}

interface UpdateEmailVars {
  current_password: string
  new_email: string
}

const performUpdateEmail = async (
  data: UpdateEmailVars
): Promise<UserResponse> => {
  const response = await apiClient.put<unknown>(API_ENDPOINTS.USERS.EMAIL, data)
  const responseData: unknown = response.data
  if (!isValidUserResponse(responseData)) {
    throw new UserResponseError(
      USER_ERROR_MESSAGES.INVALID_USER_RESPONSE,
      API_ENDPOINTS.USERS.EMAIL
    )
  }
  return responseData
}

export const useUpdateEmail = (): UseMutationResult<
  UserResponse,
  Error,
  UpdateEmailVars
> => {
  const queryClient = useQueryClient()
  const updateUser = useAuthStore((s) => s.updateUser)

  return useMutation({
    mutationFn: performUpdateEmail,
    onSuccess: (data: UserResponse): void => {
      updateUser(data)
      queryClient.setQueryData(authQueries.me(), data)
      queryClient.setQueryData(userQueries.me(), data)
      toast.success('Email updated')
    },
    onError: (error: Error): void => {
      const message =
        error instanceof UserResponseError
          ? error.message
          : 'Failed to update email'
      toast.error(message)
    },
  })
}
