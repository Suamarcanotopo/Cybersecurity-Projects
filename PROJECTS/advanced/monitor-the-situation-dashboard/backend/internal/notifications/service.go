// ©AngelaMos | 2026
// service.go

package notifications

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"

	"github.com/google/uuid"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/core"
)

type Service struct {
	repo      Repository
	enc       *Encryptor
	sender    *Sender
	publicURL string
	logger    *slog.Logger
}

func NewService(
	repo Repository,
	enc *Encryptor,
	sender *Sender,
	publicURL string,
	logger *slog.Logger,
) *Service {
	return &Service{
		repo:      repo,
		enc:       enc,
		sender:    sender,
		publicURL: publicURL,
		logger:    logger,
	}
}

func (s *Service) ListChannels(
	ctx context.Context,
	userID string,
) (*ChannelListResponse, error) {
	channels, err := s.repo.ListChannels(ctx, userID)
	if err != nil {
		return nil, err
	}

	resp := &ChannelListResponse{
		Channels: make([]ChannelResponse, 0, len(channels)),
	}

	for _, ch := range channels {
		resp.Channels = append(resp.Channels, ChannelResponse{
			ID:        ch.ID,
			Type:      ch.Type,
			Label:     ch.Label,
			Invalid:   ch.Invalid,
			CreatedAt: ch.CreatedAt,
		})
	}

	tw, err := s.repo.GetTelegramWebhook(ctx, userID)
	if err != nil && !errors.Is(err, core.ErrNotFound) {
		return nil, err
	}

	if tw != nil {
		resp.Telegram = TelegramStatusResponse{
			Configured:  true,
			Linked:      tw.IsLinked(),
			PendingLink: tw.PendingLink,
			WebhookURL:  s.webhookURL(tw.WebhookUUID),
			CreatedAt:   tw.CreatedAt,
		}
	}

	return resp, nil
}

func (s *Service) CreateChannel(
	ctx context.Context,
	userID string,
	req CreateChannelRequest,
) (*ChannelResponse, error) {
	cfg := webhookChannelConfig{WebhookURL: req.WebhookURL}

	raw, err := json.Marshal(cfg)
	if err != nil {
		return nil, fmt.Errorf("marshal channel config: %w", err)
	}

	enc, nonce, err := s.enc.Encrypt(raw)
	if err != nil {
		return nil, fmt.Errorf("encrypt channel config: %w", err)
	}

	ch := &Channel{
		ID:        uuid.New().String(),
		UserID:    userID,
		Type:      req.Type,
		Label:     req.Label,
		ConfigEnc: enc,
		Nonce:     nonce,
	}

	if err := s.repo.CreateChannel(ctx, ch); err != nil {
		return nil, err
	}

	return &ChannelResponse{
		ID:        ch.ID,
		Type:      ch.Type,
		Label:     ch.Label,
		Invalid:   ch.Invalid,
		CreatedAt: ch.CreatedAt,
	}, nil
}

func (s *Service) DeleteChannel(
	ctx context.Context,
	id, userID string,
) error {
	return s.repo.DeleteChannel(ctx, id, userID)
}

func (s *Service) TestChannel(
	ctx context.Context,
	id, userID string,
) error {
	ch, err := s.repo.GetChannel(ctx, id, userID)
	if err != nil {
		return err
	}

	raw, err := s.enc.Decrypt(ch.ConfigEnc, ch.Nonce)
	if err != nil {
		return fmt.Errorf("decrypt channel config: %w", err)
	}

	var cfg webhookChannelConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return fmt.Errorf("unmarshal channel config: %w", err)
	}

	switch ch.Type {
	case ChannelTypeSlack:
		return s.sender.TestSlack(ctx, cfg.WebhookURL)
	case ChannelTypeDiscord:
		return s.sender.TestDiscord(ctx, cfg.WebhookURL)
	default:
		return fmt.Errorf("unsupported channel type: %s", ch.Type)
	}
}

func (s *Service) RegisterTelegram(
	ctx context.Context,
	userID string,
	req RegisterTelegramRequest,
) (*RegisterTelegramResponse, error) {
	encToken, nonce, err := s.enc.Encrypt([]byte(req.BotToken))
	if err != nil {
		return nil, fmt.Errorf("encrypt bot token: %w", err)
	}

	webhookUUID := uuid.New().String()
	secretToken, err := randomHex(32)
	if err != nil {
		return nil, fmt.Errorf("generate secret token: %w", err)
	}

	tw := &TelegramWebhook{
		UserID:        userID,
		WebhookUUID:   webhookUUID,
		SecretToken:   secretToken,
		BotTokenEnc:   encToken,
		BotTokenNonce: nonce,
		PendingLink:   true,
	}

	if err := s.repo.UpsertTelegramWebhook(ctx, tw); err != nil {
		return nil, err
	}

	wURL := s.webhookURL(webhookUUID)

	webhookRegistered := true
	if err := s.sender.SetTelegramWebhook(
		ctx, req.BotToken, wURL, secretToken,
	); err != nil {
		webhookRegistered = false
		s.logger.Warn(
			"failed to auto-register telegram webhook",
			"error", err,
			"webhook_url", wURL,
		)
	}

	return &RegisterTelegramResponse{
		WebhookURL:        wURL,
		WebhookRegistered: webhookRegistered,
	}, nil
}

func (s *Service) GetTelegramStatus(
	ctx context.Context,
	userID string,
) (*TelegramStatusResponse, error) {
	tw, err := s.repo.GetTelegramWebhook(ctx, userID)
	if errors.Is(err, core.ErrNotFound) {
		return &TelegramStatusResponse{Configured: false}, nil
	}
	if err != nil {
		return nil, err
	}

	return &TelegramStatusResponse{
		Configured:  true,
		Linked:      tw.IsLinked(),
		PendingLink: tw.PendingLink,
		WebhookURL:  s.webhookURL(tw.WebhookUUID),
		CreatedAt:   tw.CreatedAt,
	}, nil
}

func (s *Service) UnlinkTelegram(ctx context.Context, userID string) error {
	tw, err := s.repo.GetTelegramWebhook(ctx, userID)
	if errors.Is(err, core.ErrNotFound) {
		return core.ErrNotFound
	}
	if err != nil {
		return err
	}

	botToken, err := s.enc.Decrypt(tw.BotTokenEnc, tw.BotTokenNonce)
	if err == nil {
		if delErr := s.sender.DeleteTelegramWebhook(
			ctx, string(botToken),
		); delErr != nil {
			s.logger.Warn(
				"failed to delete telegram webhook on unlink",
				"error", delErr,
			)
		}
	}

	return s.repo.DeleteTelegramWebhook(ctx, userID)
}

func (s *Service) TestTelegram(ctx context.Context, userID string) error {
	tw, err := s.repo.GetTelegramWebhook(ctx, userID)
	if errors.Is(err, core.ErrNotFound) {
		return fmt.Errorf(
			"no telegram channel configured: %w",
			core.ErrNotFound,
		)
	}
	if err != nil {
		return err
	}

	if !tw.IsLinked() {
		return fmt.Errorf(
			"telegram not linked yet: send any message to your bot first",
		)
	}

	botToken, err := s.enc.Decrypt(tw.BotTokenEnc, tw.BotTokenNonce)
	if err != nil {
		return fmt.Errorf("decrypt bot token: %w", err)
	}

	return s.sender.TestTelegram(ctx, string(botToken), *tw.ChatID)
}

func (s *Service) HandleTelegramUpdate(
	ctx context.Context,
	webhookUUID, secretToken string,
	update telegramUpdate,
) error {
	tw, err := s.repo.GetTelegramWebhookByUUID(ctx, webhookUUID)
	if errors.Is(err, core.ErrNotFound) {
		return core.ErrNotFound
	}
	if err != nil {
		return err
	}

	if subtle.ConstantTimeCompare(
		[]byte(tw.SecretToken),
		[]byte(secretToken),
	) != 1 {
		return core.ErrForbidden
	}

	if update.Message == nil {
		return nil
	}

	chatID := update.Message.Chat.ID
	if chatID == 0 {
		return nil
	}

	return s.repo.UpdateTelegramChatID(ctx, webhookUUID, chatID)
}

func (s *Service) webhookURL(webhookUUID string) string {
	return fmt.Sprintf(
		"%s/api/v1/notifications/telegram/webhook/%s",
		s.publicURL,
		webhookUUID,
	)
}

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
