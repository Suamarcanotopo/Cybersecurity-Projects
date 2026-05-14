// ===================
// ©AngelaMos | 2026
// auth.types.ts
//
// Zod schemas, types, validation helpers, and error classes for the auth API
//
// Covers login, registration, and profile update flows. Includes both request
// and response schemas with field-level validation rules, runtime type guards,
// user-facing message constants, and AuthResponseError for signaling malformed
// server responses in hooks.
//
// Key exports:
//   userResponseSchema, tokenResponseSchema - response validators
//   loginRequestSchema, registerRequestSchema - form validation schemas
//   updateProfileRequestSchema - cross-field validation for profile form
//   AuthResponseError - typed error class for auth hook failures
//   AUTH_ERROR_MESSAGES, AUTH_SUCCESS_MESSAGES - toast message constants
//
// Connects to:
//   useAuth.ts - consumes schemas and error class
//   admin.types.ts - imports userResponseSchema
// ===================

import { z } from 'zod'

export const USERNAME_MIN = 3
export const USERNAME_MAX = 32
export const PASSWORD_MIN = 8

export const userResponseSchema = z.object({
  id: z.string(),
  username: z.string(),
  email: z.string(),
  role: z.string(),
  is_active: z.boolean(),
})

export const tokenResponseSchema = z.object({
  access_token: z.string(),
  token_type: z.string(),
})

export const loginRequestSchema = z.object({
  username: z.string().min(1, 'Username is required'),
  password: z.string().min(1, 'Password is required'),
})

export const registerRequestSchema = z.object({
  username: z
    .string()
    .min(USERNAME_MIN, `Username must be at least ${USERNAME_MIN} characters`)
    .max(USERNAME_MAX, `Username must be at most ${USERNAME_MAX} characters`),
  email: z.string().email('Invalid email address'),
  password: z
    .string()
    .min(PASSWORD_MIN, `Password must be at least ${PASSWORD_MIN} characters`),
})

export const updateProfileRequestSchema = z
  .object({
    current_password: z.string().min(1, 'Current password is required'),
    username: z
      .string()
      .min(USERNAME_MIN, `Username must be at least ${USERNAME_MIN} characters`)
      .max(USERNAME_MAX, `Username must be at most ${USERNAME_MAX} characters`)
      .optional(),
    email: z.string().email('Invalid email address').optional(),
    password: z
      .string()
      .min(PASSWORD_MIN, `Password must be at least ${PASSWORD_MIN} characters`)
      .optional(),
  })
  .refine(
    (data) =>
      data.username !== undefined ||
      data.email !== undefined ||
      data.password !== undefined,
    { message: 'At least one field to update is required' }
  )

export const updateProfileResponseSchema = z.object({
  user: userResponseSchema,
  access_token: z.string().optional(),
  token_type: z.string().optional(),
})

export type UserResponse = z.infer<typeof userResponseSchema>
export type TokenResponse = z.infer<typeof tokenResponseSchema>
export type LoginRequest = z.infer<typeof loginRequestSchema>
export type RegisterRequest = z.infer<typeof registerRequestSchema>
export type UpdateProfileRequest = z.infer<typeof updateProfileRequestSchema>
export type UpdateProfileResponse = z.infer<typeof updateProfileResponseSchema>

export const isValidUserResponse = (data: unknown): data is UserResponse => {
  return userResponseSchema.safeParse(data).success
}

export const isValidTokenResponse = (data: unknown): data is TokenResponse => {
  return tokenResponseSchema.safeParse(data).success
}

export const isValidUpdateProfileResponse = (
  data: unknown
): data is UpdateProfileResponse => {
  return updateProfileResponseSchema.safeParse(data).success
}

export const AUTH_ERROR_MESSAGES = {
  INVALID_USER_RESPONSE: 'Invalid user data from server',
  INVALID_LOGIN_RESPONSE: 'Invalid login response from server',
  INVALID_TOKEN_RESPONSE: 'Invalid token response from server',
  SESSION_EXPIRED: 'Session expired',
} as const

export const AUTH_SUCCESS_MESSAGES = {
  WELCOME_BACK: (name: string) => `Welcome back, ${name}!`,
  LOGOUT_SUCCESS: 'Logged out successfully',
  REGISTERED: 'Account created successfully!',
  PROFILE_UPDATED: 'Profile updated successfully',
} as const

export class AuthResponseError extends Error {
  readonly endpoint?: string

  constructor(message: string, endpoint?: string) {
    super(message)
    this.name = 'AuthResponseError'
    this.endpoint = endpoint
    Object.setPrototypeOf(this, AuthResponseError.prototype)
  }
}

export type AuthErrorMessage =
  (typeof AUTH_ERROR_MESSAGES)[keyof typeof AUTH_ERROR_MESSAGES]
export type AuthSuccessMessage = typeof AUTH_SUCCESS_MESSAGES
