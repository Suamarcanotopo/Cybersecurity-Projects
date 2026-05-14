// ===================
// ©AngelaMos | 2026
// api.ts
//
// Configured Axios instance with auth injection and 401 auto-logout
//
// Creates the apiClient singleton with the VITE_API_URL base URL. The
// request interceptor reads the access token from auth store state and
// attaches it as a Bearer header. The response interceptor catches 401
// responses, calls logout(), and redirects to /login, then rethrows as
// an ApiError via transformAxiosError.
//
// Key exports:
//   apiClient - pre-configured Axios instance used by all hooks
//   getBaseURL - reads VITE_API_URL for use in SSE connection URLs
//
// Connects to:
//   errors.ts - transformAxiosError called in response interceptor
//   auth.store.ts - reads accessToken and calls logout()
// ===================

import axios, {
  type AxiosError,
  type AxiosInstance,
  type InternalAxiosRequestConfig,
} from 'axios'
import { HTTP_STATUS } from '@/config'
import { useAuthStore } from '@/core/stores'
import { transformAxiosError } from './errors'

export const getBaseURL = (): string => {
  return import.meta.env.VITE_API_URL ?? '/api'
}

export const apiClient: AxiosInstance = axios.create({
  baseURL: getBaseURL(),
  timeout: 15000,
  headers: { 'Content-Type': 'application/json' },
})

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
  (error: AxiosError): Promise<never> => {
    if (error.response?.status === HTTP_STATUS.UNAUTHORIZED) {
      useAuthStore.getState().logout()
      window.location.href = '/login'
    }
    return Promise.reject(transformAxiosError(error))
  }
)
