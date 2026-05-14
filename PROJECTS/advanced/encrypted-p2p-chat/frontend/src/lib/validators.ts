/**
 * Input validation utilities
 */

import {
  DISPLAY_NAME_MAX_LENGTH,
  DISPLAY_NAME_MIN_LENGTH,
  MESSAGE_MAX_LENGTH,
  USERNAME_MAX_LENGTH,
  USERNAME_MIN_LENGTH,
} from '../config'

export interface ValidationResult {
  valid: boolean
  error?: string
}

const USERNAME_PATTERN = /^[a-zA-Z0-9_-]+$/
const DISPLAY_NAME_PATTERN = /^[\p{L}\p{N}\s\-_.]+$/u

export function validateUsername(username: string): ValidationResult {
  const trimmed = username.trim()

  if (trimmed.length === 0) {
    return { valid: false, error: 'Username is required' }
  }

  if (trimmed.length < USERNAME_MIN_LENGTH) {
    return {
      valid: false,
      error: `Username must be at least ${USERNAME_MIN_LENGTH} characters`,
    }
  }

  if (trimmed.length > USERNAME_MAX_LENGTH) {
    return {
      valid: false,
      error: `Username must be at most ${USERNAME_MAX_LENGTH} characters`,
    }
  }

  if (!USERNAME_PATTERN.test(trimmed)) {
    return {
      valid: false,
      error:
        'Username can only contain letters, numbers, underscores, and hyphens',
    }
  }

  return { valid: true }
}

export function validateDisplayName(displayName: string): ValidationResult {
  const trimmed = displayName.trim()

  if (trimmed.length === 0) {
    return { valid: false, error: 'Display name is required' }
  }

  if (trimmed.length < DISPLAY_NAME_MIN_LENGTH) {
    return {
      valid: false,
      error: `Display name must be at least ${DISPLAY_NAME_MIN_LENGTH} character`,
    }
  }

  if (trimmed.length > DISPLAY_NAME_MAX_LENGTH) {
    return {
      valid: false,
      error: `Display name must be at most ${DISPLAY_NAME_MAX_LENGTH} characters`,
    }
  }

  if (!DISPLAY_NAME_PATTERN.test(trimmed)) {
    return {
      valid: false,
      error: 'Display name contains invalid characters',
    }
  }

  return { valid: true }
}

export function validateMessageContent(content: string): ValidationResult {
  if (content.length === 0) {
    return { valid: false, error: 'Message cannot be empty' }
  }

  if (content.length > MESSAGE_MAX_LENGTH) {
    return {
      valid: false,
      error: `Message must be at most ${MESSAGE_MAX_LENGTH} characters`,
    }
  }

  return { valid: true }
}

export function validateUUID(id: string): ValidationResult {
  const uuidPattern =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  if (!uuidPattern.test(id)) {
    return { valid: false, error: 'Invalid ID format' }
  }

  return { valid: true }
}

export function sanitizeInput(input: string): string {
  return input
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;')
}

export function truncate(str: string, maxLength: number): string {
  if (str.length <= maxLength) {
    return str
  }
  return `${str.slice(0, maxLength - 3)}...`
}

export function normalizeWhitespace(str: string): string {
  return str.replace(/\s+/g, ' ').trim()
}

export function isValidUrl(str: string): boolean {
  try {
    const url = new URL(str)
    return url.protocol === 'http:' || url.protocol === 'https:'
  } catch {
    return false
  }
}
