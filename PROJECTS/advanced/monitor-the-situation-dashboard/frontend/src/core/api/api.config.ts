// ===================
// © AngelaMos | 2025
// api.config.ts
// ===================

import axios, {
  type AxiosError,
  type AxiosInstance,
  type InternalAxiosRequestConfig,
} from 'axios'
import { API_ENDPOINTS, HTTP_STATUS } from '@/config'
import { useAuthStore } from '@/core/lib'
import { ApiError, ApiErrorCode, transformAxiosError } from './errors'

interface RequestConfig extends InternalAxiosRequestConfig {
  _retry?: boolean
}

interface RefreshSubscriber {
  resolve: (token: string) => void
  reject: (error: Error) => void
}

interface GoEnvelope {
  success: boolean
  data?: unknown
  meta?: {
    page: number
    page_size: number
    total: number
    total_pages: number
  }
}

const getBaseURL = (): string => {
  return import.meta.env.VITE_API_URL ?? '/api'
}

export const apiClient: AxiosInstance = axios.create({
  baseURL: getBaseURL(),
  timeout: 15000,
  headers: { 'Content-Type': 'application/json' },
  withCredentials: true,
})

let isRefreshing = false
let refreshSubscribers: RefreshSubscriber[] = []

const processRefreshQueue = (error: Error | null, token: string | null): void => {
  refreshSubscribers.forEach((subscriber) => {
    if (error !== null) {
      subscriber.reject(error)
    } else if (token !== null) {
      subscriber.resolve(token)
    }
  })
  refreshSubscribers = []
}

const addRefreshSubscriber = (
  resolve: (token: string) => void,
  reject: (error: Error) => void
): void => {
  refreshSubscribers.push({ resolve, reject })
}

const handleTokenRefresh = async (): Promise<string> => {
  // Refresh token rides in the HttpOnly cookie set by the backend on login.
  // axios sends it automatically because the client is configured with
  // withCredentials: true. We don't read or send it from JS at all.
  const response = await apiClient.post<unknown>(API_ENDPOINTS.AUTH.REFRESH, {})

  if (
    response.data === null ||
    response.data === undefined ||
    typeof response.data !== 'object'
  ) {
    throw new ApiError(
      'Invalid refresh response',
      ApiErrorCode.AUTHENTICATION_ERROR,
      HTTP_STATUS.UNAUTHORIZED
    )
  }

  const payload = response.data as {
    tokens?: { access_token?: string }
  }
  const accessToken = payload.tokens?.access_token
  if (typeof accessToken !== 'string' || accessToken.length === 0) {
    throw new ApiError(
      'Invalid access token',
      ApiErrorCode.AUTHENTICATION_ERROR,
      HTTP_STATUS.UNAUTHORIZED
    )
  }

  return accessToken
}

const handleAuthFailure = (): void => {
  useAuthStore.getState().logout()
  window.location.href = '/login'
}

apiClient.interceptors.response.use(
  (response) => {
    if (
      response.status !== 204 &&
      response.data !== null &&
      response.data !== undefined &&
      typeof response.data === 'object' &&
      'success' in (response.data as object)
    ) {
      const envelope = response.data as GoEnvelope
      if (envelope.meta !== undefined && envelope.meta !== null) {
        response.data = {
          items: envelope.data,
          page: envelope.meta.page,
          page_size: envelope.meta.page_size,
          total: envelope.meta.total,
          total_pages: envelope.meta.total_pages,
        }
      } else {
        response.data = envelope.data
      }
    }
    return response
  },
  (error: unknown) => Promise.reject(error)
)

apiClient.interceptors.request.use(
  (config: InternalAxiosRequestConfig): InternalAxiosRequestConfig => {
    const token = useAuthStore.getState().accessToken
    if (token !== null && token.length > 0) {
      config.headers.Authorization = `Bearer ${token}`
    }
    return config
  },
  (error: unknown): Promise<never> => {
    return Promise.reject(error)
  }
)

apiClient.interceptors.response.use(
  (response) => response,
  async (error: AxiosError): Promise<unknown> => {
    const originalRequest = error.config as RequestConfig | undefined

    if (originalRequest === undefined) {
      return Promise.reject(transformAxiosError(error))
    }

    const isUnauthorized = error.response?.status === HTTP_STATUS.UNAUTHORIZED
    const isNotRetried = originalRequest._retry !== true
    const isNotRefreshEndpoint =
      originalRequest.url?.includes(API_ENDPOINTS.AUTH.REFRESH) !== true
    const hadBearerToken =
      typeof originalRequest.headers.Authorization === 'string' &&
      originalRequest.headers.Authorization.startsWith('Bearer ')
    // Cold-load hydration: persisted isAuthenticated=true but accessToken
    // is missing (it's not persisted across reloads). The first protected
    // call has no Bearer header, gets 401, and we should still try a
    // refresh via the HttpOnly cookie.
    const persistedAuth = useAuthStore.getState().isAuthenticated

    if (
      isUnauthorized &&
      isNotRetried &&
      isNotRefreshEndpoint &&
      (hadBearerToken || persistedAuth)
    ) {
      if (isRefreshing) {
        return new Promise<unknown>((resolve, reject) => {
          addRefreshSubscriber(
            (newToken: string): void => {
              originalRequest.headers.Authorization = `Bearer ${newToken}`
              resolve(apiClient(originalRequest))
            },
            (refreshError: Error): void => {
              reject(refreshError)
            }
          )
        })
      }

      originalRequest._retry = true
      isRefreshing = true

      try {
        const newToken = await handleTokenRefresh()
        useAuthStore.getState().setAccessToken(newToken)
        processRefreshQueue(null, newToken)
        originalRequest.headers.Authorization = `Bearer ${newToken}`
        return await apiClient(originalRequest)
      } catch (refreshError: unknown) {
        const apiError =
          refreshError instanceof ApiError
            ? refreshError
            : new ApiError(
                'Session expired',
                ApiErrorCode.AUTHENTICATION_ERROR,
                HTTP_STATUS.UNAUTHORIZED
              )
        processRefreshQueue(apiError, null)
        handleAuthFailure()
        return Promise.reject(apiError)
      } finally {
        isRefreshing = false
      }
    }

    return Promise.reject(transformAxiosError(error))
  }
)
