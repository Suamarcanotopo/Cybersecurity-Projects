/**
 * Date formatting utilities for chat timestamps
 */

const SECONDS_IN_MINUTE = 60
const SECONDS_IN_HOUR = 3600
const SECONDS_IN_DAY = 86400
const SECONDS_IN_WEEK = 604800

const SHORT_WEEKDAY_NAMES = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
const SHORT_MONTH_NAMES = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
]

export function formatMessageTime(dateString: string): string {
  const date = new Date(dateString)
  const hours = date.getHours()
  const minutes = date.getMinutes()
  const ampm = hours >= 12 ? 'PM' : 'AM'
  const hoursMod12 = hours % 12
  const displayHours = hoursMod12 === 0 ? 12 : hoursMod12
  const displayMinutes = minutes.toString().padStart(2, '0')

  return `${displayHours}:${displayMinutes} ${ampm}`
}

export function formatMessageDate(dateString: string): string {
  const date = new Date(dateString)
  const now = new Date()
  const diffSeconds = Math.floor((now.getTime() - date.getTime()) / 1000)

  if (diffSeconds < SECONDS_IN_DAY && date.getDate() === now.getDate()) {
    return 'Today'
  }

  const yesterday = new Date(now)
  yesterday.setDate(yesterday.getDate() - 1)
  if (
    date.getDate() === yesterday.getDate() &&
    date.getMonth() === yesterday.getMonth() &&
    date.getFullYear() === yesterday.getFullYear()
  ) {
    return 'Yesterday'
  }

  if (diffSeconds < SECONDS_IN_WEEK) {
    return SHORT_WEEKDAY_NAMES[date.getDay()]
  }

  const month = SHORT_MONTH_NAMES[date.getMonth()]
  const day = date.getDate()

  if (date.getFullYear() === now.getFullYear()) {
    return `${month} ${day}`
  }

  return `${month} ${day}, ${date.getFullYear()}`
}

export function formatRelativeTime(dateString: string): string {
  const date = new Date(dateString)
  const now = new Date()
  const diffSeconds = Math.floor((now.getTime() - date.getTime()) / 1000)

  if (diffSeconds < SECONDS_IN_MINUTE) {
    return 'Just now'
  }

  if (diffSeconds < SECONDS_IN_HOUR) {
    const minutes = Math.floor(diffSeconds / SECONDS_IN_MINUTE)
    return `${minutes}m ago`
  }

  if (diffSeconds < SECONDS_IN_DAY) {
    const hours = Math.floor(diffSeconds / SECONDS_IN_HOUR)
    return `${hours}h ago`
  }

  if (diffSeconds < SECONDS_IN_WEEK) {
    const days = Math.floor(diffSeconds / SECONDS_IN_DAY)
    return `${days}d ago`
  }

  return formatMessageDate(dateString)
}

export function formatLastSeen(dateString: string): string {
  const date = new Date(dateString)
  const now = new Date()
  const diffSeconds = Math.floor((now.getTime() - date.getTime()) / 1000)

  if (diffSeconds < SECONDS_IN_MINUTE) {
    return 'Active now'
  }

  if (diffSeconds < SECONDS_IN_HOUR) {
    const minutes = Math.floor(diffSeconds / SECONDS_IN_MINUTE)
    return `Active ${minutes}m ago`
  }

  if (diffSeconds < SECONDS_IN_DAY) {
    const hours = Math.floor(diffSeconds / SECONDS_IN_HOUR)
    return `Active ${hours}h ago`
  }

  return `Last seen ${formatMessageDate(dateString)}`
}

export function formatTimestamp(dateString: string): string {
  const date = new Date(dateString)
  return date.toISOString()
}

export function isToday(dateString: string): boolean {
  const date = new Date(dateString)
  const now = new Date()
  return (
    date.getDate() === now.getDate() &&
    date.getMonth() === now.getMonth() &&
    date.getFullYear() === now.getFullYear()
  )
}

export function isSameDay(dateString1: string, dateString2: string): boolean {
  const date1 = new Date(dateString1)
  const date2 = new Date(dateString2)
  return (
    date1.getDate() === date2.getDate() &&
    date1.getMonth() === date2.getMonth() &&
    date1.getFullYear() === date2.getFullYear()
  )
}

export function getCurrentTimestamp(): string {
  return new Date().toISOString()
}

export const formatTime = formatMessageTime
