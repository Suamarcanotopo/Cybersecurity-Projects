// ©AngelaMos | 2026
// dto.go

package notifications

import "time"

type ChannelResponse struct {
	ID        string    `json:"id"`
	Type      string    `json:"type"`
	Label     string    `json:"label"`
	Invalid   bool      `json:"invalid"`
	CreatedAt time.Time `json:"created_at"`
}

type TelegramStatusResponse struct {
	Configured        bool      `json:"configured"`
	Linked            bool      `json:"linked"`
	PendingLink       bool      `json:"pending_link"`
	WebhookURL        string    `json:"webhook_url,omitempty"`
	WebhookRegistered bool      `json:"webhook_registered"`
	CreatedAt         time.Time `json:"created_at,omitempty"`
}

type RegisterTelegramResponse struct {
	WebhookURL        string `json:"webhook_url"`
	WebhookRegistered bool   `json:"webhook_registered"`
}

type ChannelListResponse struct {
	Channels []ChannelResponse      `json:"channels"`
	Telegram TelegramStatusResponse `json:"telegram"`
}

type CreateChannelRequest struct {
	Type       string `json:"type"        validate:"required,oneof=slack discord"`
	Label      string `json:"label"       validate:"required,min=1,max=100"`
	WebhookURL string `json:"webhook_url" validate:"required,url,max=2048"`
}

type RegisterTelegramRequest struct {
	BotToken string `json:"bot_token" validate:"required,min=10,max=200"`
}

type webhookChannelConfig struct {
	WebhookURL string `json:"webhook_url"`
}

type telegramUpdate struct {
	UpdateID int64 `json:"update_id"`
	Message  *struct {
		Chat struct {
			ID int64 `json:"id"`
		} `json:"chat"`
	} `json:"message"`
}
