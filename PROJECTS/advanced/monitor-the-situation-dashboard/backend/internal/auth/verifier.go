// ©AngelaMos | 2026
// verifier.go

package auth

import (
	"context"
	"errors"
	"fmt"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/core"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/middleware"
)

// Verifier composes JWT validation, token-version check, and JTI blacklist
// check into a single TokenVerifier the middleware can use. This is what
// wires the auth-service's revocation infrastructure (LogoutAll's
// IncrementTokenVersion, Logout's RevokeAccessToken) into the request
// path — without it, those calls were dead code.
type Verifier struct {
	jwt          *JWTManager
	service      *Service
	userProvider UserProvider
}

func NewVerifier(
	jwt *JWTManager,
	service *Service,
	userProvider UserProvider,
) *Verifier {
	return &Verifier{
		jwt:          jwt,
		service:      service,
		userProvider: userProvider,
	}
}

// VerifyAccessToken parses the JWT, then enforces:
//   - The user's current token_version is <= the version embedded in this
//     token. A LogoutAll bump invalidates every previously-issued access
//     token by raising the floor.
//   - The token's JTI is not in the Redis blacklist (Logout adds it there
//     to revoke a single session immediately, not just the refresh token).
func (v *Verifier) VerifyAccessToken(
	ctx context.Context,
	tokenString string,
) (*middleware.AccessTokenClaims, error) {
	claims, err := v.jwt.VerifyAccessToken(ctx, tokenString)
	if err != nil {
		return nil, err
	}

	if claims.JTI != "" {
		blacklisted, blErr := v.service.IsAccessTokenBlacklisted(
			ctx,
			claims.JTI,
		)
		if blErr != nil {
			return nil, fmt.Errorf("verify token: blacklist lookup: %w", blErr)
		}
		if blacklisted {
			return nil, fmt.Errorf("verify token: %w", core.ErrTokenRevoked)
		}
	}

	user, err := v.userProvider.GetByID(ctx, claims.UserID)
	if err != nil {
		if errors.Is(err, core.ErrNotFound) {
			return nil, fmt.Errorf("verify token: %w", core.ErrTokenInvalid)
		}
		return nil, fmt.Errorf("verify token: load user: %w", err)
	}
	if claims.TokenVersion < user.TokenVersion {
		return nil, fmt.Errorf(
			"verify token: version superseded: %w",
			core.ErrTokenRevoked,
		)
	}

	return claims, nil
}
