// ©AngelaMos | 2026
// repository.go

package notifications

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/core"
)

type Repository interface {
	ListChannels(ctx context.Context, userID string) ([]Channel, error)
	GetChannel(ctx context.Context, id, userID string) (*Channel, error)
	CreateChannel(ctx context.Context, ch *Channel) error
	DeleteChannel(ctx context.Context, id, userID string) error
	MarkChannelInvalid(ctx context.Context, id string) error

	GetTelegramWebhook(
		ctx context.Context,
		userID string,
	) (*TelegramWebhook, error)
	GetTelegramWebhookByUUID(
		ctx context.Context,
		uuid string,
	) (*TelegramWebhook, error)
	UpsertTelegramWebhook(ctx context.Context, tw *TelegramWebhook) error
	UpdateTelegramChatID(ctx context.Context, uuid string, chatID int64) error
	DeleteTelegramWebhook(ctx context.Context, userID string) error
}

type repository struct {
	db core.DBTX
}

func NewRepository(db core.DBTX) Repository {
	return &repository{db: db}
}

func (r *repository) ListChannels(
	ctx context.Context,
	userID string,
) ([]Channel, error) {
	query := `
		SELECT id, user_id, type, label, config_enc, nonce,
		       invalid, created_at, updated_at
		FROM alert_channels
		WHERE user_id = $1
		ORDER BY created_at DESC`

	var channels []Channel
	if err := r.db.SelectContext(ctx, &channels, query, userID); err != nil {
		return nil, fmt.Errorf("list channels: %w", err)
	}
	return channels, nil
}

func (r *repository) GetChannel(
	ctx context.Context,
	id, userID string,
) (*Channel, error) {
	query := `
		SELECT id, user_id, type, label, config_enc, nonce,
		       invalid, created_at, updated_at
		FROM alert_channels
		WHERE id = $1 AND user_id = $2`

	var ch Channel
	err := r.db.GetContext(ctx, &ch, query, id, userID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("get channel: %w", core.ErrNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("get channel: %w", err)
	}
	return &ch, nil
}

func (r *repository) CreateChannel(ctx context.Context, ch *Channel) error {
	query := `
		INSERT INTO alert_channels
		    (id, user_id, type, label, config_enc, nonce)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING created_at, updated_at`

	err := r.db.GetContext(ctx, ch, query,
		ch.ID,
		ch.UserID,
		ch.Type,
		ch.Label,
		ch.ConfigEnc,
		ch.Nonce,
	)
	if err != nil {
		return fmt.Errorf("create channel: %w", err)
	}
	return nil
}

func (r *repository) DeleteChannel(
	ctx context.Context,
	id, userID string,
) error {
	query := `DELETE FROM alert_channels WHERE id = $1 AND user_id = $2`

	result, err := r.db.ExecContext(ctx, query, id, userID)
	if err != nil {
		return fmt.Errorf("delete channel: %w", err)
	}

	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("delete channel: %w", err)
	}
	if rows == 0 {
		return fmt.Errorf("delete channel: %w", core.ErrNotFound)
	}
	return nil
}

func (r *repository) MarkChannelInvalid(ctx context.Context, id string) error {
	query := `
		UPDATE alert_channels
		SET invalid = true, updated_at = NOW()
		WHERE id = $1`

	_, err := r.db.ExecContext(ctx, query, id)
	if err != nil {
		return fmt.Errorf("mark channel invalid: %w", err)
	}
	return nil
}

func (r *repository) GetTelegramWebhook(
	ctx context.Context,
	userID string,
) (*TelegramWebhook, error) {
	query := `
		SELECT user_id, webhook_uuid, secret_token, bot_token_enc,
		       bot_token_nonce, chat_id, pending_link, created_at
		FROM telegram_webhooks
		WHERE user_id = $1`

	var tw TelegramWebhook
	err := r.db.GetContext(ctx, &tw, query, userID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("get telegram webhook: %w", core.ErrNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("get telegram webhook: %w", err)
	}
	return &tw, nil
}

func (r *repository) GetTelegramWebhookByUUID(
	ctx context.Context,
	uuid string,
) (*TelegramWebhook, error) {
	query := `
		SELECT user_id, webhook_uuid, secret_token, bot_token_enc,
		       bot_token_nonce, chat_id, pending_link, created_at
		FROM telegram_webhooks
		WHERE webhook_uuid = $1`

	var tw TelegramWebhook
	err := r.db.GetContext(ctx, &tw, query, uuid)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf(
			"get telegram webhook by uuid: %w",
			core.ErrNotFound,
		)
	}
	if err != nil {
		return nil, fmt.Errorf("get telegram webhook by uuid: %w", err)
	}
	return &tw, nil
}

func (r *repository) UpsertTelegramWebhook(
	ctx context.Context,
	tw *TelegramWebhook,
) error {
	query := `
		INSERT INTO telegram_webhooks
		    (user_id, webhook_uuid, secret_token,
		     bot_token_enc, bot_token_nonce, pending_link)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (user_id) DO UPDATE
		    SET webhook_uuid    = EXCLUDED.webhook_uuid,
		        secret_token    = EXCLUDED.secret_token,
		        bot_token_enc   = EXCLUDED.bot_token_enc,
		        bot_token_nonce = EXCLUDED.bot_token_nonce,
		        chat_id         = NULL,
		        pending_link    = true,
		        created_at      = now()
		RETURNING created_at`

	err := r.db.GetContext(ctx, &tw.CreatedAt, query,
		tw.UserID,
		tw.WebhookUUID,
		tw.SecretToken,
		tw.BotTokenEnc,
		tw.BotTokenNonce,
		tw.PendingLink,
	)
	if err != nil {
		return fmt.Errorf("upsert telegram webhook: %w", err)
	}
	return nil
}

func (r *repository) UpdateTelegramChatID(
	ctx context.Context,
	uuid string,
	chatID int64,
) error {
	query := `
		UPDATE telegram_webhooks
		SET chat_id = $2, pending_link = false
		WHERE webhook_uuid = $1`

	result, err := r.db.ExecContext(ctx, query, uuid, chatID)
	if err != nil {
		return fmt.Errorf("update telegram chat_id: %w", err)
	}

	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("update telegram chat_id: %w", err)
	}
	if rows == 0 {
		return fmt.Errorf("update telegram chat_id: %w", core.ErrNotFound)
	}
	return nil
}

func (r *repository) DeleteTelegramWebhook(
	ctx context.Context,
	userID string,
) error {
	query := `DELETE FROM telegram_webhooks WHERE user_id = $1`

	result, err := r.db.ExecContext(ctx, query, userID)
	if err != nil {
		return fmt.Errorf("delete telegram webhook: %w", err)
	}

	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("delete telegram webhook: %w", err)
	}
	if rows == 0 {
		return fmt.Errorf("delete telegram webhook: %w", core.ErrNotFound)
	}
	return nil
}
