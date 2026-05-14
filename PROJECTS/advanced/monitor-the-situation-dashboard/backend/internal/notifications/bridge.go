// ©AngelaMos | 2026
// bridge.go

package notifications

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/alerts"
)

// Bridge wires the notifications module into the alerts engine. It loads
// a user's configured channels (decrypting webhook URLs / Telegram bot
// tokens on demand) and routes outbound alerts to the right transport.
//
// Without this seam, the alerts engine would have to know about
// encryption/repo specifics; with it, alerts.Engine treats every
// destination as the same interface (alerts.Channel + Notifier).
type Bridge struct {
	repo   Repository
	enc    *Encryptor
	sender *Sender
	logger *slog.Logger
}

func NewBridge(
	repo Repository,
	enc *Encryptor,
	sender *Sender,
	logger *slog.Logger,
) *Bridge {
	if logger == nil {
		logger = slog.Default()
	}
	return &Bridge{repo: repo, enc: enc, sender: sender, logger: logger}
}

// LoadChannels implements alerts.ChannelLoader. Returns every linked
// destination for the user — Slack/Discord webhook channels plus the
// Telegram bot if it's been linked. Decryption errors mark the channel
// invalid and skip it.
func (b *Bridge) LoadChannels(
	ctx context.Context,
	userID string,
) ([]alerts.Channel, error) {
	out := []alerts.Channel{}

	channels, err := b.repo.ListChannels(ctx, userID)
	if err != nil {
		return nil, fmt.Errorf("load webhook channels: %w", err)
	}
	for _, ch := range channels {
		if ch.Invalid {
			continue
		}
		raw, decErr := b.enc.Decrypt(ch.ConfigEnc, ch.Nonce)
		if decErr != nil {
			b.logger.Warn("alerts: channel decrypt failed",
				"channel_id", ch.ID, "type", ch.Type, "err", decErr)
			continue
		}
		var cfg webhookChannelConfig
		if jErr := json.Unmarshal(raw, &cfg); jErr != nil {
			b.logger.Warn("alerts: channel config unmarshal failed",
				"channel_id", ch.ID, "type", ch.Type, "err", jErr)
			continue
		}
		out = append(out, alerts.Channel{
			ID:         ch.ID,
			Type:       ch.Type,
			Label:      ch.Label,
			WebhookURL: cfg.WebhookURL,
		})
	}

	tw, err := b.repo.GetTelegramWebhook(ctx, userID)
	if err == nil && tw != nil && tw.IsLinked() {
		botToken, derr := b.enc.Decrypt(tw.BotTokenEnc, tw.BotTokenNonce)
		if derr == nil && tw.ChatID != nil {
			out = append(out, alerts.Channel{
				ID:       "telegram:" + userID,
				Type:     ChannelTypeTelegram,
				Label:    "Telegram",
				BotToken: string(botToken),
				ChatID:   *tw.ChatID,
			})
		}
	}

	return out, nil
}

// SendAlert implements alerts.Notifier. Routes by channel type to the
// matching transport on the Sender.
func (b *Bridge) SendAlert(
	ctx context.Context,
	ch alerts.Channel,
	message string,
) error {
	switch ch.Type {
	case ChannelTypeSlack:
		return b.sender.SendSlack(ctx, ch.WebhookURL, message)
	case ChannelTypeDiscord:
		return b.sender.SendDiscord(ctx, ch.WebhookURL, message)
	case ChannelTypeTelegram:
		return b.sender.SendTelegram(ctx, ch.BotToken, ch.ChatID, message)
	default:
		return fmt.Errorf("unsupported channel type: %s", ch.Type)
	}
}
