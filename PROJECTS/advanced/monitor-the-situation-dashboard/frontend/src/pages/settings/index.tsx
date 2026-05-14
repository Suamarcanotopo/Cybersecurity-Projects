// ===================
// © AngelaMos | 2026
// index.tsx
// ===================

import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  type AlertRule,
  useAlertRules,
  useChangePassword,
  useLogout,
  useDeleteAlertRule,
  useUpdateAlertRule,
  useUpdateEmail,
  useUpdateProfile,
} from '@/api/hooks'
import {
  useCreateChannel,
  useDeleteChannel,
  useNotificationChannels,
  useRegisterTelegram,
  useTestChannel,
  useTestTelegram,
  useUnlinkTelegram,
} from '@/api/hooks/useNotifications'
import {
  type ChannelType,
  createChannelRequestSchema,
  registerTelegramRequestSchema,
} from '@/api/types'
import { useUser } from '@/core/lib'
import styles from './settings.module.scss'

type AddingType = 'slack' | 'discord' | null

function ArrowLeft() {
  return (
    <svg
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      aria-hidden="true"
    >
      <path d="M10 3L5 8l5 5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

function TelegramLogo() {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z" />
    </svg>
  )
}

function SlackLogo() {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M5.042 15.165a2.528 2.528 0 0 1-2.52 2.523A2.528 2.528 0 0 1 0 15.165a2.527 2.527 0 0 1 2.522-2.52h2.52v2.52zm1.271 0a2.527 2.527 0 0 1 2.521-2.52 2.527 2.527 0 0 1 2.521 2.52v6.313A2.528 2.528 0 0 1 8.834 24a2.528 2.528 0 0 1-2.521-2.522v-6.313zM8.834 5.042a2.528 2.528 0 0 1-2.521-2.52A2.528 2.528 0 0 1 8.834 0a2.528 2.528 0 0 1 2.521 2.522v2.52H8.834zm0 1.271a2.528 2.528 0 0 1 2.521 2.521 2.528 2.528 0 0 1-2.521 2.521H2.522A2.528 2.528 0 0 1 0 8.834a2.528 2.528 0 0 1 2.522-2.521h6.312zm10.123 2.521a2.528 2.528 0 0 1 2.522-2.521A2.528 2.528 0 0 1 24 8.834a2.528 2.528 0 0 1-2.522 2.521h-2.522V8.834zm-1.268 0a2.528 2.528 0 0 1-2.523 2.521 2.527 2.527 0 0 1-2.52-2.521V2.522A2.527 2.527 0 0 1 15.165 0a2.528 2.528 0 0 1 2.523 2.522v6.312zm-2.523 10.123a2.528 2.528 0 0 1 2.523 2.522A2.528 2.528 0 0 1 15.165 24a2.527 2.527 0 0 1-2.52-2.522v-2.522h2.52zm0-1.268a2.527 2.527 0 0 1-2.52-2.523 2.526 2.526 0 0 1 2.52-2.52h6.313A2.527 2.527 0 0 1 24 15.165a2.528 2.528 0 0 1-2.522 2.523h-6.313z" />
    </svg>
  )
}

function DiscordLogo() {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M20.317 4.492c-1.53-.69-3.17-1.2-4.885-1.49a.075.075 0 0 0-.079.036c-.21.369-.444.85-.608 1.23a18.566 18.566 0 0 0-5.487 0 12.36 12.36 0 0 0-.617-1.23A.077.077 0 0 0 8.562 3c-1.714.29-3.354.8-4.885 1.491a.07.07 0 0 0-.032.027C.533 9.093-.32 13.555.099 17.961a.08.08 0 0 0 .031.055 20.03 20.03 0 0 0 5.993 2.98.078.078 0 0 0 .084-.026c.462-.62.874-1.275 1.226-1.963.021-.04.001-.088-.041-.104a13.2 13.2 0 0 1-1.872-.878.075.075 0 0 1-.008-.125c.126-.093.252-.19.372-.287a.075.075 0 0 1 .078-.01c3.927 1.764 8.18 1.764 12.061 0a.075.075 0 0 1 .079.009c.12.098.245.195.372.288a.075.075 0 0 1-.006.125c-.598.344-1.22.635-1.873.877a.075.075 0 0 0-.041.105c.36.687.772 1.341 1.225 1.962a.077.077 0 0 0 .084.028 19.963 19.963 0 0 0 6.002-2.981.076.076 0 0 0 .032-.054c.5-5.094-.838-9.52-3.549-13.442a.06.06 0 0 0-.031-.028zM8.02 15.278c-1.182 0-2.157-1.069-2.157-2.38 0-1.312.956-2.38 2.157-2.38 1.21 0 2.176 1.077 2.157 2.38 0 1.312-.956 2.38-2.157 2.38zm7.975 0c-1.183 0-2.157-1.069-2.157-2.38 0-1.312.955-2.38 2.157-2.38 1.21 0 2.176 1.077 2.157 2.38 0 1.312-.946 2.38-2.157 2.38z" />
    </svg>
  )
}

const CHANNEL_ICON_CLASS: Record<ChannelType, string> = {
  slack: styles.channelIconSlack,
  discord: styles.channelIconDiscord,
  telegram: styles.channelIconTelegram,
}

function ChannelIcon({ type }: { type: ChannelType }) {
  return (
    <span className={`${styles.channelIcon} ${CHANNEL_ICON_CLASS[type]}`}>
      {type === 'slack' && <SlackLogo />}
      {type === 'discord' && <DiscordLogo />}
      {type === 'telegram' && <TelegramLogo />}
    </span>
  )
}

const CHANNEL_CARD_COLOR: Record<'slack' | 'discord', string> = {
  slack: styles.channelCardSlack,
  discord: styles.channelCardDiscord,
}

function WebhookChannelForm({
  type,
  onCancel,
}: {
  type: 'slack' | 'discord'
  onCancel: () => void
}) {
  const createChannel = useCreateChannel()
  const [label, setLabel] = useState('')
  const [webhookURL, setWebhookURL] = useState('')
  const [error, setError] = useState<string | null>(null)

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    const result = createChannelRequestSchema.safeParse({
      type,
      label,
      webhook_url: webhookURL,
    })
    if (!result.success) {
      setError(result.error.issues[0]?.message ?? 'Invalid input')
      return
    }
    setError(null)
    createChannel.mutate(result.data, { onSuccess: onCancel })
  }

  const typeName = type === 'slack' ? 'Slack' : 'Discord'
  const placeholder =
    type === 'slack'
      ? 'https://hooks.slack.com/services/...'
      : 'https://discord.com/api/webhooks/...'

  return (
    <form onSubmit={handleSubmit} className={styles.form}>
      <div className={styles.formRowHalf}>
        <div className={styles.formRow}>
          <label className={styles.label} htmlFor="webhookChannelLabel">
            Label
          </label>
          <input
            id="webhookChannelLabel"
            className={styles.input}
            placeholder={`My ${typeName} alerts`}
            value={label}
            onChange={(e) => setLabel(e.target.value)}
          />
        </div>
        <div className={styles.formRow}>
          <label className={styles.label} htmlFor="webhookChannelUrl">
            Incoming webhook URL
          </label>
          <input
            id="webhookChannelUrl"
            className={styles.input}
            placeholder={placeholder}
            value={webhookURL}
            onChange={(e) => setWebhookURL(e.target.value)}
          />
        </div>
      </div>
      {error != null && <span className={styles.fieldError}>{error}</span>}
      <div className={styles.formActions}>
        <button type="button" className={styles.cancelBtn} onClick={onCancel}>
          Cancel
        </button>
        <button
          type="submit"
          className={styles.submitBtn}
          disabled={createChannel.isPending}
        >
          {createChannel.isPending ? 'Adding...' : 'Add channel'}
        </button>
      </div>
    </form>
  )
}

function TelegramRegisterForm({ onCancel }: { onCancel: () => void }) {
  const registerTelegram = useRegisterTelegram()
  const [botToken, setBotToken] = useState('')
  const [error, setError] = useState<string | null>(null)

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    const result = registerTelegramRequestSchema.safeParse({
      bot_token: botToken,
    })
    if (!result.success) {
      setError(result.error.issues[0]?.message ?? 'Invalid bot token')
      return
    }
    setError(null)
    registerTelegram.mutate(result.data, { onSuccess: onCancel })
  }

  return (
    <form onSubmit={handleSubmit} className={styles.form}>
      <div className={styles.formRow}>
        <label className={styles.label} htmlFor="telegramBotToken">
          Bot token
        </label>
        <input
          id="telegramBotToken"
          className={styles.input}
          placeholder="1234567890:ABCDEFabcdef..."
          value={botToken}
          onChange={(e) => setBotToken(e.target.value)}
        />
        {error != null && <span className={styles.fieldError}>{error}</span>}
      </div>
      <div className={styles.formActions}>
        <button type="button" className={styles.cancelBtn} onClick={onCancel}>
          Cancel
        </button>
        <button
          type="submit"
          className={styles.submitBtn}
          disabled={registerTelegram.isPending}
        >
          {registerTelegram.isPending ? 'Registering...' : 'Register bot'}
        </button>
      </div>
    </form>
  )
}

function TelegramSection() {
  const { data } = useNotificationChannels()
  const [showForm, setShowForm] = useState(false)
  const unlinkTelegram = useUnlinkTelegram()
  const testTelegram = useTestTelegram()

  const tg = data?.telegram

  const copyToClipboard = (text: string) => {
    void navigator.clipboard.writeText(text)
  }

  return (
    <div className={styles.section}>
      <div className={styles.sectionHeader}>
        <span className={styles.sectionTitle}>Telegram</span>
      </div>

      <div className={styles.telegramCard}>
        <div className={styles.telegramCardHeader}>
          <div className={styles.telegramIconWrap}>
            <TelegramLogo />
          </div>
          <div className={styles.telegramCardBody}>
            <div className={styles.telegramTitle}>
              Telegram bot
              {tg?.configured === true &&
                (tg.linked ? (
                  <span className={`${styles.badge} ${styles.badgeLinked}`}>
                    linked
                  </span>
                ) : (
                  <span className={`${styles.badge} ${styles.badgePending}`}>
                    pending link
                  </span>
                ))}
            </div>

            {tg?.configured !== true && !showForm && (
              <p className={styles.telegramDesc}>
                Create a bot via @BotFather and paste the token below. We&apos;ll
                register the webhook automatically.
              </p>
            )}

            {tg?.configured === true && (
              <div className={styles.telegramActions}>
                {tg.linked && (
                  <button
                    type="button"
                    className={styles.actionBtn}
                    disabled={testTelegram.isPending}
                    onClick={() => testTelegram.mutate()}
                  >
                    Send test
                  </button>
                )}
                <button
                  type="button"
                  className={styles.actionBtn}
                  onClick={() => setShowForm(true)}
                >
                  Re-register
                </button>
                <button
                  type="button"
                  className={`${styles.actionBtn} ${styles.actionBtnDanger}`}
                  disabled={unlinkTelegram.isPending}
                  onClick={() => unlinkTelegram.mutate()}
                >
                  Remove
                </button>
              </div>
            )}

            {tg?.configured !== true && !showForm && (
              <button
                type="button"
                className={styles.addBtn}
                onClick={() => setShowForm(true)}
              >
                Register bot
              </button>
            )}
          </div>
        </div>

        {showForm && <TelegramRegisterForm onCancel={() => setShowForm(false)} />}

        {!showForm && tg?.pending_link === true && (
          <div className={styles.linkInstructions}>
            <span className={styles.linkInstructionsTitle}>
              Action required — link your account
            </span>
            <p className={styles.linkStep}>
              Open your bot in Telegram and send any message (e.g.{' '}
              <code>/start</code>). It will capture your chat ID and activate
              automatically.
            </p>
            {tg.webhook_url != null && (
              <div>
                <p className={styles.linkStep}>
                  If the bot isn&apos;t responding, register the webhook manually
                  using your bot token:
                </p>
                <div className={styles.webhookURLRow}>
                  <span className={styles.webhookURL}>{tg.webhook_url}</span>
                  <button
                    className={styles.copyBtn}
                    type="button"
                    onClick={() => copyToClipboard(tg.webhook_url ?? '')}
                  >
                    Copy
                  </button>
                </div>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

function AccountSection() {
  const user = useUser()
  const updateProfile = useUpdateProfile()
  const updateEmail = useUpdateEmail()

  const [name, setName] = useState(user?.name ?? '')
  const [email, setEmail] = useState('')
  const [emailPassword, setEmailPassword] = useState('')

  useEffect(() => {
    if (user?.name) setName(user.name)
  }, [user?.name])

  const handleSaveName = (e: React.FormEvent) => {
    e.preventDefault()
    if (!name.trim()) return
    updateProfile.mutate({ name })
  }

  const handleChangeEmail = (e: React.FormEvent) => {
    e.preventDefault()
    if (!email.trim() || !emailPassword) return
    updateEmail.mutate(
      { current_password: emailPassword, new_email: email },
      {
        onSuccess: () => {
          setEmail('')
          setEmailPassword('')
        },
      }
    )
  }

  return (
    <div className={styles.section}>
      <div className={styles.sectionHeader}>
        <span className={styles.sectionTitle}>Account</span>
      </div>

      <form onSubmit={handleSaveName} className={styles.form}>
        <div className={styles.formRow}>
          <label className={styles.label} htmlFor="accountName">
            Name
          </label>
          <input
            id="accountName"
            className={styles.input}
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Your display name"
            autoComplete="name"
          />
        </div>
        <div className={styles.formActions}>
          <button
            type="submit"
            className={styles.submitBtn}
            disabled={updateProfile.isPending || name === (user?.name ?? '')}
          >
            {updateProfile.isPending ? 'Saving…' : 'Save name'}
          </button>
        </div>
      </form>

      <form onSubmit={handleChangeEmail} className={styles.form}>
        <div className={styles.formRow}>
          <label className={styles.label} htmlFor="accountCurrentEmail">
            Current email
          </label>
          <input
            id="accountCurrentEmail"
            className={styles.input}
            value={user?.email ?? ''}
            readOnly
            autoComplete="email"
          />
        </div>
        <div className={styles.formRowHalf}>
          <div className={styles.formRow}>
            <label className={styles.label} htmlFor="accountNewEmail">
              New email
            </label>
            <input
              id="accountNewEmail"
              type="email"
              className={styles.input}
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="new@example.com"
              autoComplete="email"
            />
          </div>
          <div className={styles.formRow}>
            <label className={styles.label} htmlFor="accountEmailPassword">
              Current password
            </label>
            <input
              id="accountEmailPassword"
              type="password"
              className={styles.input}
              value={emailPassword}
              onChange={(e) => setEmailPassword(e.target.value)}
              placeholder="••••••••"
              autoComplete="current-password"
            />
          </div>
        </div>
        <div className={styles.formActions}>
          <button
            type="submit"
            className={styles.submitBtn}
            disabled={
              updateEmail.isPending ||
              !email.trim() ||
              !emailPassword ||
              email.trim() === user?.email
            }
          >
            {updateEmail.isPending ? 'Updating…' : 'Change email'}
          </button>
        </div>
      </form>

      <SignOutRow />
    </div>
  )
}

function SignOutRow() {
  const logout = useLogout()
  return (
    <div className={styles.formActions} style={{ marginTop: '1.5rem' }}>
      <button
        type="button"
        className={`${styles.actionBtn} ${styles.actionBtnDanger}`}
        disabled={logout.isPending}
        onClick={() => logout.mutate()}
      >
        {logout.isPending ? 'Signing out…' : 'Sign out'}
      </button>
    </div>
  )
}

function PasswordSection() {
  const changePassword = useChangePassword()
  const [current, setCurrent] = useState('')
  const [next, setNext] = useState('')
  const [confirm, setConfirm] = useState('')
  const [error, setError] = useState<string | null>(null)

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    if (next.length < 8) {
      setError('New password must be at least 8 characters')
      return
    }
    if (next !== confirm) {
      setError('Passwords do not match')
      return
    }
    setError(null)
    changePassword.mutate(
      { current_password: current, new_password: next },
      {
        onSuccess: () => {
          setCurrent('')
          setNext('')
          setConfirm('')
        },
      }
    )
  }

  return (
    <div className={styles.section}>
      <div className={styles.sectionHeader}>
        <span className={styles.sectionTitle}>Password</span>
      </div>

      <form onSubmit={handleSubmit} className={styles.form}>
        <div className={styles.formRow}>
          <label className={styles.label} htmlFor="pwCurrent">
            Current password
          </label>
          <input
            id="pwCurrent"
            type="password"
            className={styles.input}
            value={current}
            onChange={(e) => setCurrent(e.target.value)}
            autoComplete="current-password"
          />
        </div>
        <div className={styles.formRowHalf}>
          <div className={styles.formRow}>
            <label className={styles.label} htmlFor="pwNew">
              New password
            </label>
            <input
              id="pwNew"
              type="password"
              className={styles.input}
              value={next}
              onChange={(e) => setNext(e.target.value)}
              autoComplete="new-password"
            />
          </div>
          <div className={styles.formRow}>
            <label className={styles.label} htmlFor="pwConfirm">
              Confirm new password
            </label>
            <input
              id="pwConfirm"
              type="password"
              className={styles.input}
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              autoComplete="new-password"
            />
          </div>
        </div>
        {error != null && <span className={styles.fieldError}>{error}</span>}
        <div className={styles.formActions}>
          <button
            type="submit"
            className={styles.submitBtn}
            disabled={changePassword.isPending || !current || !next || !confirm}
          >
            {changePassword.isPending ? 'Changing…' : 'Change password'}
          </button>
        </div>
      </form>
    </div>
  )
}

function AlertRulesSection() {
  const { data: rules, isLoading } = useAlertRules()
  const updateRule = useUpdateAlertRule()
  const deleteRule = useDeleteAlertRule()

  return (
    <div className={styles.section}>
      <div className={styles.sectionHeader}>
        <span className={styles.sectionTitle}>Alert rules</span>
      </div>
      {isLoading && <p className={styles.emptyText}>Loading rules…</p>}
      {!isLoading && (rules?.length ?? 0) === 0 && (
        <div className={styles.empty}>
          <p className={styles.emptyText}>
            No rules yet. Defaults are seeded on registration.
          </p>
        </div>
      )}
      <div className={styles.channelList}>
        {rules?.map((r: AlertRule) => (
          <div key={r.id} className={styles.channelCard}>
            <div className={styles.channelLeft}>
              <div className={styles.channelInfo}>
                <span className={styles.channelLabel}>{r.name}</span>
                <div className={styles.channelMeta}>
                  <span className={styles.channelType}>{r.topic}</span>
                  {r.cooldown_sec > 0 && (
                    <span className={styles.channelType}>
                      cooldown {r.cooldown_sec}s
                    </span>
                  )}
                  {!r.enabled && (
                    <span className={`${styles.badge} ${styles.badgeInvalid}`}>
                      disabled
                    </span>
                  )}
                </div>
              </div>
            </div>
            <div className={styles.channelActions}>
              <button
                type="button"
                className={styles.actionBtn}
                disabled={updateRule.isPending}
                onClick={() =>
                  updateRule.mutate({
                    id: r.id,
                    patch: { enabled: !r.enabled },
                  })
                }
              >
                {r.enabled ? 'Disable' : 'Enable'}
              </button>
              <button
                type="button"
                className={`${styles.actionBtn} ${styles.actionBtnDanger}`}
                disabled={deleteRule.isPending}
                onClick={() => deleteRule.mutate(r.id)}
              >
                Remove
              </button>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

function WebhookChannelsSection() {
  const { data, isLoading } = useNotificationChannels()
  const deleteChannel = useDeleteChannel()
  const testChannel = useTestChannel()
  const [addingType, setAddingType] = useState<AddingType>(null)

  const channels = (data?.channels ?? []).filter(
    (ch) => ch.type === 'slack' || ch.type === 'discord'
  )

  return (
    <div className={styles.section}>
      <div className={styles.sectionHeader}>
        <span className={styles.sectionTitle}>Slack & Discord</span>
        {addingType == null && (
          <div style={{ display: 'flex', gap: '0.5rem' }}>
            <button
              type="button"
              className={`${styles.addBtn} ${styles.addBtnSlack}`}
              onClick={() => setAddingType('slack')}
            >
              <SlackLogo />
              Slack
            </button>
            <button
              type="button"
              className={`${styles.addBtn} ${styles.addBtnDiscord}`}
              onClick={() => setAddingType('discord')}
            >
              <DiscordLogo />
              Discord
            </button>
          </div>
        )}
      </div>

      {addingType != null && (
        <WebhookChannelForm
          type={addingType}
          onCancel={() => setAddingType(null)}
        />
      )}

      <div
        className={styles.channelList}
        style={{ marginTop: addingType != null ? '1rem' : '0' }}
      >
        {isLoading && <p className={styles.emptyText}>Loading...</p>}
        {!isLoading && channels.length === 0 && addingType == null && (
          <div className={styles.empty}>
            <p className={styles.emptyText}>
              No channels configured. Add Slack or Discord to get started.
            </p>
          </div>
        )}
        {channels.map((ch) => {
          const colorClass =
            ch.type === 'slack' || ch.type === 'discord'
              ? CHANNEL_CARD_COLOR[ch.type]
              : ''
          return (
            <div
              key={ch.id}
              className={`${styles.channelCard} ${colorClass} ${ch.invalid ? styles.channelCardInvalid : ''}`}
            >
              <div className={styles.channelLeft}>
                <ChannelIcon type={ch.type} />
                <div className={styles.channelInfo}>
                  <span className={styles.channelLabel}>{ch.label}</span>
                  <div className={styles.channelMeta}>
                    <span className={styles.channelType}>{ch.type}</span>
                    {ch.invalid && (
                      <span className={`${styles.badge} ${styles.badgeInvalid}`}>
                        invalid
                      </span>
                    )}
                  </div>
                </div>
              </div>
              <div className={styles.channelActions}>
                <button
                  type="button"
                  className={styles.actionBtn}
                  disabled={testChannel.isPending}
                  onClick={() => testChannel.mutate(ch.id)}
                >
                  Send test
                </button>
                <button
                  type="button"
                  className={`${styles.actionBtn} ${styles.actionBtnDanger}`}
                  disabled={deleteChannel.isPending}
                  onClick={() => deleteChannel.mutate(ch.id)}
                >
                  Remove
                </button>
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}

export function Component(): React.ReactElement {
  const navigate = useNavigate()

  return (
    <div className={styles.page}>
      <div className={styles.container}>
        <button
          type="button"
          className={styles.backBtn}
          onClick={() => navigate(-1)}
        >
          <ArrowLeft />
          Back
        </button>

        <div className={styles.header}>
          <h1 className={styles.title}>Settings</h1>
          <p className={styles.subtitle}>
            Manage your account, password, and where alerts get delivered.
          </p>
        </div>

        <AccountSection />
        <PasswordSection />

        <div className={styles.header} style={{ marginTop: '2rem' }}>
          <h2 className={styles.title}>Notifications</h2>
          <p className={styles.subtitle}>
            Configure where alert notifications are delivered. Each channel can be
            tested after setup.
          </p>
        </div>

        <AlertRulesSection />
        <TelegramSection />
        <WebhookChannelsSection />
      </div>
    </div>
  )
}

Component.displayName = 'Settings'
