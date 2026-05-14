// ===================
// © AngelaMos | 2026
// notification.types.ts
// ===================

import { z } from 'zod'

export const channelTypeSchema = z.enum(['slack', 'discord', 'telegram'])
export type ChannelType = z.infer<typeof channelTypeSchema>

export const channelResponseSchema = z.object({
  id: z.string(),
  type: channelTypeSchema,
  label: z.string(),
  invalid: z.boolean(),
  created_at: z.string(),
})

export const telegramStatusResponseSchema = z.object({
  configured: z.boolean(),
  linked: z.boolean(),
  pending_link: z.boolean(),
  webhook_url: z.string().optional(),
  webhook_registered: z.boolean().optional(),
  created_at: z.string().optional(),
})

export const channelListResponseSchema = z.object({
  channels: z.array(channelResponseSchema),
  telegram: telegramStatusResponseSchema,
})

export const registerTelegramResponseSchema = z.object({
  webhook_url: z.string(),
  webhook_registered: z.boolean(),
})

export const createChannelRequestSchema = z.object({
  type: z.enum(['slack', 'discord']),
  label: z.string().min(1).max(100),
  webhook_url: z.string().url().max(2048),
})

export const registerTelegramRequestSchema = z.object({
  bot_token: z.string().min(10).max(200),
})

export type ChannelResponse = z.infer<typeof channelResponseSchema>
export type TelegramStatusResponse = z.infer<typeof telegramStatusResponseSchema>
export type ChannelListResponse = z.infer<typeof channelListResponseSchema>
export type RegisterTelegramResponse = z.infer<
  typeof registerTelegramResponseSchema
>
export type CreateChannelRequest = z.infer<typeof createChannelRequestSchema>
export type RegisterTelegramRequest = z.infer<
  typeof registerTelegramRequestSchema
>

export const isValidChannelListResponse = (
  data: unknown
): data is ChannelListResponse => {
  if (data === null || data === undefined) return false
  return channelListResponseSchema.safeParse(data).success
}

export const isValidTelegramStatus = (
  data: unknown
): data is TelegramStatusResponse => {
  if (data === null || data === undefined) return false
  return telegramStatusResponseSchema.safeParse(data).success
}

export const NOTIFICATION_ERROR_MESSAGES = {
  LIST_FAILED: 'Failed to load notification channels',
  CREATE_FAILED: 'Failed to add notification channel',
  DELETE_FAILED: 'Failed to remove notification channel',
  TEST_FAILED: 'Test notification failed',
  REGISTER_TELEGRAM_FAILED: 'Failed to register Telegram bot',
  UNLINK_TELEGRAM_FAILED: 'Failed to unlink Telegram',
  INVALID_RESPONSE: 'Invalid response from server',
} as const

export const NOTIFICATION_SUCCESS_MESSAGES = {
  CHANNEL_ADDED: 'Notification channel added',
  CHANNEL_DELETED: 'Notification channel removed',
  TEST_SENT: 'Test notification sent',
  TELEGRAM_REGISTERED: 'Telegram bot registered',
  TELEGRAM_UNLINKED: 'Telegram unlinked',
} as const
