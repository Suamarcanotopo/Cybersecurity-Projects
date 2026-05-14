// ===================
// ©AngelaMos | 2026
// useAdmin.ts
//
// React Query hooks for admin-only user management: list, role update, and lifecycle
//
// useAdminUsers fetches a paginated user list. useAdminUpdateRole patches a
// user's role and shows a message that includes the new role label.
// useAdminDeactivateUser and useAdminActivateUser toggle the is_active flag.
// useAdminDeleteUser permanently removes a user. All mutations invalidate the
// full admin cache.
//
// Key exports:
//   useAdminUsers - paginated user list
//   useAdminUser - single user by ID
//   useAdminUpdateRole - role change mutation
//   useAdminDeactivateUser, useAdminActivateUser - status toggle mutations
//   useAdminDeleteUser - permanent delete mutation
//
// Connects to:
//   api.ts, config.ts - HTTP client and endpoint/key constants
//   admin.types.ts - AdminUpdateRoleRequest, ADMIN_SUCCESS_MESSAGES
//   auth.types.ts - UserResponse
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
  AdminUpdateRoleRequest,
  AdminUserListParams,
  DeleteResponse,
  PaginatedResponse,
  UserResponse,
} from '@/api/types'
import { ADMIN_SUCCESS_MESSAGES } from '@/api/types/admin.types'
import { API_ENDPOINTS, PAGINATION, QUERY_KEYS } from '@/config'
import { apiClient } from '@/core/lib'

export const adminQueries = {
  all: () => QUERY_KEYS.ADMIN.ALL,
  users: (page: number, size: number) => QUERY_KEYS.ADMIN.USERS(page, size),
  userById: (id: string) => QUERY_KEYS.ADMIN.USER_BY_ID(id),
} as const

export const useAdminUsers = (
  params: AdminUserListParams = {}
): UseQueryResult<PaginatedResponse<UserResponse>, Error> => {
  const page = params.page ?? PAGINATION.DEFAULT_PAGE
  const perPage = params.per_page ?? PAGINATION.DEFAULT_SIZE

  return useQuery({
    queryKey: adminQueries.users(page, perPage),
    queryFn: async () => {
      const response = await apiClient.get<PaginatedResponse<UserResponse>>(
        API_ENDPOINTS.ADMIN.USERS,
        { params }
      )
      return response.data
    },
  })
}

export const useAdminUser = (
  userId: string
): UseQueryResult<UserResponse, Error> => {
  return useQuery({
    queryKey: adminQueries.userById(userId),
    queryFn: async () => {
      const response = await apiClient.get<UserResponse>(
        API_ENDPOINTS.ADMIN.USER_BY_ID(userId)
      )
      return response.data
    },
    enabled: userId.length > 0,
  })
}

export const useAdminUpdateRole = (): UseMutationResult<
  UserResponse,
  Error,
  { userId: string; payload: AdminUpdateRoleRequest }
> => {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async ({ userId, payload }) => {
      const response = await apiClient.patch<UserResponse>(
        API_ENDPOINTS.ADMIN.USER_ROLE(userId),
        payload
      )
      return response.data
    },
    onSuccess: (data: UserResponse): void => {
      queryClient.invalidateQueries({ queryKey: adminQueries.all() })
      toast.success(ADMIN_SUCCESS_MESSAGES.ROLE_UPDATED(data.username, data.role))
    },
    onError: (error: Error): void => {
      toast.error(error.message)
    },
  })
}

export const useAdminDeactivateUser = (): UseMutationResult<
  UserResponse,
  Error,
  string
> => {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (userId: string) => {
      const response = await apiClient.post<UserResponse>(
        API_ENDPOINTS.ADMIN.DEACTIVATE(userId)
      )
      return response.data
    },
    onSuccess: (data: UserResponse): void => {
      queryClient.invalidateQueries({ queryKey: adminQueries.all() })
      toast.success(ADMIN_SUCCESS_MESSAGES.USER_DEACTIVATED(data.username))
    },
    onError: (error: Error): void => {
      toast.error(error.message)
    },
  })
}

export const useAdminActivateUser = (): UseMutationResult<
  UserResponse,
  Error,
  string
> => {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (userId: string) => {
      const response = await apiClient.post<UserResponse>(
        API_ENDPOINTS.ADMIN.ACTIVATE(userId)
      )
      return response.data
    },
    onSuccess: (data: UserResponse): void => {
      queryClient.invalidateQueries({ queryKey: adminQueries.all() })
      toast.success(ADMIN_SUCCESS_MESSAGES.USER_ACTIVATED(data.username))
    },
    onError: (error: Error): void => {
      toast.error(error.message)
    },
  })
}

export const useAdminDeleteUser = (): UseMutationResult<
  DeleteResponse,
  Error,
  string
> => {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (userId: string) => {
      const response = await apiClient.delete<DeleteResponse>(
        API_ENDPOINTS.ADMIN.USER_BY_ID(userId)
      )
      return response.data
    },
    onSuccess: (): void => {
      queryClient.invalidateQueries({ queryKey: adminQueries.all() })
      toast.success(ADMIN_SUCCESS_MESSAGES.USER_DELETED)
    },
    onError: (error: Error): void => {
      toast.error(error.message)
    },
  })
}
