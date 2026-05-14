// ===================
// ©AngelaMos | 2026
// admin.types.ts
//
// Types, schemas, and message constants for the admin user management API
//
// Defines the UserRole const, role update request schema, paginated user
// list response schema, and toast message constants. Imports userResponseSchema
// from auth.types so admin lists use the same user shape.
//
// Key exports:
//   UserRole - admin and analyst role constants
//   adminUpdateRoleRequestSchema - Zod validation for role changes
//   adminUserListResponseSchema - paginated user list response type
//   ADMIN_SUCCESS_MESSAGES, ADMIN_ERROR_MESSAGES - toast message templates
//
// Connects to:
//   auth.types.ts - imports userResponseSchema
//   useAdmin.ts - consumes all admin types
// ===================

import { z } from 'zod'
import { userResponseSchema } from './auth.types'

export const UserRole = {
  ANALYST: 'analyst',
  ADMIN: 'admin',
} as const

export type UserRole = (typeof UserRole)[keyof typeof UserRole]

export const VALID_ROLES: UserRole[] = [UserRole.ANALYST, UserRole.ADMIN]

export const adminUpdateRoleRequestSchema = z.object({
  role: z.enum(['analyst', 'admin']),
})

export const adminUserListResponseSchema = z.object({
  items: z.array(userResponseSchema),
  total: z.number(),
  page: z.number(),
  per_page: z.number(),
  pages: z.number(),
})

export type AdminUpdateRoleRequest = z.infer<typeof adminUpdateRoleRequestSchema>
export type AdminUserListResponse = z.infer<typeof adminUserListResponseSchema>

export interface AdminUserListParams {
  page?: number
  per_page?: number
}

export const ADMIN_SUCCESS_MESSAGES = {
  ROLE_UPDATED: (username: string, role: string) => `${username} is now ${role}`,
  USER_DEACTIVATED: (username: string) => `${username} deactivated`,
  USER_ACTIVATED: (username: string) => `${username} activated`,
  USER_DELETED: 'User permanently deleted',
} as const

export const ADMIN_ERROR_MESSAGES = {
  SELF_ACTION: 'Cannot perform this action on your own account',
  LAST_ADMIN: 'Cannot demote the last admin',
} as const

export const ROLE_LABELS: Record<string, string> = {
  analyst: 'Analyst',
  admin: 'Admin',
}
