// ===================
// © AngelaMos | 2026
// api-client.ts
// ===================

import { API_URL } from '../config'
import type {
  ApiErrorResponse,
  AuthenticationBeginRequest,
  AuthenticationCompleteRequest,
  PreKeyBundle,
  RegistrationBeginRequest,
  RegistrationCompleteRequest,
  Room,
  User,
} from '../types'
import { ApiError } from '../types'

type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'

interface RequestOptions {
  method?: HttpMethod
  body?: unknown
  headers?: Record<string, string>
  signal?: AbortSignal
}

interface ApiClientConfig {
  baseUrl: string
  defaultHeaders: Record<string, string>
}

const DEFAULT_CONFIG: ApiClientConfig = {
  baseUrl: API_URL,
  defaultHeaders: {
    'Content-Type': 'application/json',
    Accept: 'application/json',
  },
}

async function request<T>(
  endpoint: string,
  options: RequestOptions = {}
): Promise<T> {
  const { method = 'GET', body, headers = {}, signal } = options

  const url = `${DEFAULT_CONFIG.baseUrl}${endpoint}`

  const fetchOptions: RequestInit = {
    method,
    headers: {
      ...DEFAULT_CONFIG.defaultHeaders,
      ...headers,
    },
    signal,
    credentials: 'include',
  }

  if (body !== undefined && method !== 'GET') {
    fetchOptions.body = JSON.stringify(body)
  }

  const response = await fetch(url, fetchOptions)

  if (!response.ok) {
    let errorData: unknown

    try {
      errorData = await response.json()
    } catch {
      errorData = { detail: response.statusText }
    }

    const getErrorMessage = (): string => {
      if (
        typeof errorData === 'object' &&
        errorData !== null &&
        'detail' in errorData
      ) {
        const detail = (errorData as ApiErrorResponse).detail
        return typeof detail === 'string'
          ? detail
          : `HTTP ${response.status}: ${response.statusText}`
      }
      return `HTTP ${response.status}: ${response.statusText}`
    }

    throw new ApiError(response.status, errorData, getErrorMessage())
  }

  if (response.status === 204) {
    return undefined as T
  }

  return response.json() as Promise<T>
}

async function get<T>(endpoint: string, signal?: AbortSignal): Promise<T> {
  return request<T>(endpoint, { method: 'GET', signal })
}

async function post<T>(
  endpoint: string,
  body?: unknown,
  signal?: AbortSignal
): Promise<T> {
  return request<T>(endpoint, { method: 'POST', body, signal })
}

async function put<T>(
  endpoint: string,
  body?: unknown,
  signal?: AbortSignal
): Promise<T> {
  return request<T>(endpoint, { method: 'PUT', body, signal })
}

async function del<T>(endpoint: string, signal?: AbortSignal): Promise<T> {
  return request<T>(endpoint, { method: 'DELETE', signal })
}

export interface RootResponse {
  app: string
  version: string
  status: string
  environment: string
}

export interface HealthResponse {
  status: string
}

export interface WebAuthnOptionsResponse
  extends PublicKeyCredentialCreationOptions,
    PublicKeyCredentialRequestOptions {}

export interface UploadKeysRequest {
  identity_key: string
  identity_key_ed25519: string
  signed_prekey: string
  signed_prekey_signature: string
  one_time_prekeys: string[]
}

export interface UploadKeysResponse {
  status: string
  message: string
}

export interface CreateRoomRequest {
  participant_id: string
  room_type?: 'direct' | 'group' | 'ephemeral'
}

export interface RoomListResponse {
  rooms: Room[]
}

export interface UserSearchRequest {
  query: string
  limit?: number
}

export interface UserSearchResponse {
  users: User[]
}

export const api = {
  root: {
    getStatus: (): Promise<RootResponse> => get<RootResponse>('/'),

    getHealth: (): Promise<HealthResponse> => get<HealthResponse>('/health'),
  },

  users: {
    search: (
      data: UserSearchRequest,
      signal?: AbortSignal
    ): Promise<UserSearchResponse> =>
      post<UserSearchResponse>('/auth/users/search', data, signal),
  },

  auth: {
    beginRegistration: (
      data: RegistrationBeginRequest,
      signal?: AbortSignal
    ): Promise<WebAuthnOptionsResponse> =>
      post<WebAuthnOptionsResponse>('/auth/register/begin', data, signal),

    completeRegistration: (
      data: RegistrationCompleteRequest,
      signal?: AbortSignal
    ): Promise<User> => post<User>('/auth/register/complete', data, signal),

    beginAuthentication: (
      data: AuthenticationBeginRequest,
      signal?: AbortSignal
    ): Promise<WebAuthnOptionsResponse> =>
      post<WebAuthnOptionsResponse>('/auth/authenticate/begin', data, signal),

    completeAuthentication: (
      data: AuthenticationCompleteRequest,
      signal?: AbortSignal
    ): Promise<User> => post<User>('/auth/authenticate/complete', data, signal),

    me: (signal?: AbortSignal): Promise<User> => get<User>('/auth/me', signal),

    logout: (signal?: AbortSignal): Promise<undefined> =>
      post<undefined>('/auth/logout', undefined, signal),
  },

  encryption: {
    getPrekeyBundle: (
      userId: string,
      signal?: AbortSignal
    ): Promise<PreKeyBundle> =>
      get<PreKeyBundle>(`/encryption/prekey-bundle/${userId}`, signal),

    uploadKeys: (
      userId: string,
      keys: UploadKeysRequest,
      signal?: AbortSignal
    ): Promise<UploadKeysResponse> =>
      post<UploadKeysResponse>(`/encryption/upload-keys/${userId}`, keys, signal),
  },

  rooms: {
    list: (signal?: AbortSignal): Promise<RoomListResponse> =>
      get<RoomListResponse>('/rooms', signal),

    create: (data: CreateRoomRequest, signal?: AbortSignal): Promise<Room> =>
      post<Room>('/rooms', data, signal),

    get: (roomId: string, signal?: AbortSignal): Promise<Room> =>
      get<Room>(`/rooms/${encodeURIComponent(roomId)}`, signal),

    delete: (roomId: string, signal?: AbortSignal): Promise<undefined> =>
      del<undefined>(`/rooms/${encodeURIComponent(roomId)}`, signal),

    getMessages: (
      roomId: string,
      limit: number = 50,
      offset: number = 0,
      signal?: AbortSignal
    ): Promise<{
      messages: Array<{
        id: string
        room_id: string
        sender_id: string
        sender_username: string
        ciphertext: string
        nonce: string
        header: string
        created_at: string
      }>
      has_more: boolean
    }> =>
      get(
        `/rooms/${encodeURIComponent(roomId)}/messages?limit=${limit}&offset=${offset}`,
        signal
      ),
  },
}

export { request, get, post, put, del }
export type { RequestOptions, ApiClientConfig }
