// ©AngelaMos | 2026
// entity.go

package notifications

import "time"

const (
	ChannelTypeSlack    = "slack"
	ChannelTypeDiscord  = "discord"
	ChannelTypeTelegram = "telegram"
)

type Channel struct {
	ID        string    `db:"id"`
	UserID    string    `db:"user_id"`
	Type      string    `db:"type"`
	Label     string    `db:"label"`
	ConfigEnc []byte    `db:"config_enc"`
	Nonce     []byte    `db:"nonce"`
	Invalid   bool      `db:"invalid"`
	CreatedAt time.Time `db:"created_at"`
	UpdatedAt time.Time `db:"updated_at"`
}

type TelegramWebhook struct {
	UserID        string    `db:"user_id"`
	WebhookUUID   string    `db:"webhook_uuid"`
	SecretToken   string    `db:"secret_token"`
	BotTokenEnc   []byte    `db:"bot_token_enc"`
	BotTokenNonce []byte    `db:"bot_token_nonce"`
	ChatID        *int64    `db:"chat_id"`
	PendingLink   bool      `db:"pending_link"`
	CreatedAt     time.Time `db:"created_at"`
}

func (t *TelegramWebhook) IsLinked() bool {
	return !t.PendingLink && t.ChatID != nil
}
