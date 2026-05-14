// ===================
// © AngelaMos | 2025
// useAuth.ts
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
  AUTH_ERROR_MESSAGES,
  AUTH_SUCCESS_MESSAGES,
  AuthResponseError,
  isValidTokenWithUserResponse,
  isValidUserResponse,
  type LoginRequest,
  type PasswordChangeRequest,
  type TokenWithUserResponse,
  type UserResponse,
} from '@/api/types'
import { API_ENDPOINTS, QUERY_KEYS, ROUTES } from '@/config'
import { apiClient, QUERY_STRATEGIES } from '@/core/api'
import { useAuthStore } from '@/core/lib'

export const authQueries = {
  all: () => QUERY_KEYS.AUTH.ALL,
  me: () => QUERY_KEYS.AUTH.ME(),
} as const

const fetchCurrentUser = async (): Promise<UserResponse> => {
  const response = await apiClient.get<unknown>(API_ENDPOINTS.AUTH.ME)
  const data: unknown = response.data

  if (!isValidUserResponse(data)) {
    throw new AuthResponseError(
      AUTH_ERROR_MESSAGES.INVALID_USER_RESPONSE,
      API_ENDPOINTS.AUTH.ME
    )
  }

  return data
}

export const useCurrentUser = (): UseQueryResult<UserResponse, Error> => {
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)

  return useQuery({
    queryKey: authQueries.me(),
    queryFn: fetchCurrentUser,
    enabled: isAuthenticated,
    ...QUERY_STRATEGIES.auth,
  })
}

const performLogin = async (
  credentials: LoginRequest
): Promise<TokenWithUserResponse> => {
  const response = await apiClient.post<unknown>(API_ENDPOINTS.AUTH.LOGIN, {
    email: credentials.email,
    password: credentials.password,
  })

  const data: unknown = response.data

  if (!isValidTokenWithUserResponse(data)) {
    throw new AuthResponseError(
      AUTH_ERROR_MESSAGES.INVALID_LOGIN_RESPONSE,
      API_ENDPOINTS.AUTH.LOGIN
    )
  }

  return data
}

export const useLogin = (): UseMutationResult<
  TokenWithUserResponse,
  Error,
  LoginRequest
> => {
  const queryClient = useQueryClient()
  const login = useAuthStore((s) => s.login)

  return useMutation({
    mutationFn: performLogin,
    onSuccess: (data: TokenWithUserResponse): void => {
      login(data.user, data.tokens.access_token)

      queryClient.setQueryData(authQueries.me(), data.user)

      toast.success(AUTH_SUCCESS_MESSAGES.WELCOME_BACK(data.user.name))
    },
    onError: (error: Error): void => {
      const message =
        error instanceof AuthResponseError ? error.message : 'Login failed'
      toast.error(message)
    },
  })
}

const performLogout = async (): Promise<void> => {
  // Refresh-token cookie is sent automatically by axios via withCredentials.
  await apiClient.post(API_ENDPOINTS.AUTH.LOGOUT, {})
}

export const useLogout = (): UseMutationResult<void, Error, void> => {
  const queryClient = useQueryClient()
  const logout = useAuthStore((s) => s.logout)

  return useMutation({
    mutationFn: performLogout,
    onSuccess: (): void => {
      logout()

      queryClient.removeQueries({ queryKey: authQueries.all() })

      toast.success(AUTH_SUCCESS_MESSAGES.LOGOUT_SUCCESS)

      window.location.href = ROUTES.LOGIN
    },
    onError: (): void => {
      logout()
      queryClient.removeQueries({ queryKey: authQueries.all() })
      window.location.href = ROUTES.LOGIN
    },
  })
}

const performLogoutAll = async (): Promise<void> => {
  await apiClient.post(API_ENDPOINTS.AUTH.LOGOUT_ALL)
}

export const useLogoutAll = (): UseMutationResult<void, Error, void> => {
  const queryClient = useQueryClient()
  const logout = useAuthStore((s) => s.logout)

  return useMutation({
    mutationFn: performLogoutAll,
    onSuccess: (): void => {
      logout()

      queryClient.removeQueries({ queryKey: authQueries.all() })

      toast.success('Logged out from all sessions')

      window.location.href = ROUTES.LOGIN
    },
    onError: (error: Error): void => {
      const message =
        error instanceof AuthResponseError
          ? error.message
          : 'Failed to logout all sessions'
      toast.error(message)
    },
  })
}

const performPasswordChange = async (
  data: PasswordChangeRequest
): Promise<void> => {
  await apiClient.post(API_ENDPOINTS.AUTH.CHANGE_PASSWORD, data)
}

export const useChangePassword = (): UseMutationResult<
  void,
  Error,
  PasswordChangeRequest
> => {
  return useMutation({
    mutationFn: performPasswordChange,
    onSuccess: (): void => {
      toast.success(AUTH_SUCCESS_MESSAGES.PASSWORD_CHANGED)
    },
    onError: (error: Error): void => {
      const message =
        error instanceof AuthResponseError
          ? error.message
          : 'Failed to change password'
      toast.error(message)
    },
  })
}

export const useRefreshAuth = (): (() => Promise<void>) => {
  const queryClient = useQueryClient()
  const { login, logout } = useAuthStore()

  return async (): Promise<void> => {
    try {
      const response = await apiClient.post<unknown>(
        API_ENDPOINTS.AUTH.REFRESH,
        {}
      )
      const data: unknown = response.data

      if (!isValidTokenWithUserResponse(data)) {
        throw new AuthResponseError(
          AUTH_ERROR_MESSAGES.INVALID_TOKEN_RESPONSE,
          API_ENDPOINTS.AUTH.REFRESH
        )
      }

      login(data.user, data.tokens.access_token)
      queryClient.setQueryData(authQueries.me(), data.user)
    } catch {
      logout()
      queryClient.removeQueries({ queryKey: authQueries.all() })
    }
  }
}
