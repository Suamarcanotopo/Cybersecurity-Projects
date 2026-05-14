// AngelaMos | 2026
// service.go

package user

import (
	"context"
	"fmt"
	"strings"

	"github.com/google/uuid"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/auth"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/core"
)

type Service struct {
	repo Repository
}

func NewService(repo Repository) *Service {
	return &Service{repo: repo}
}

func (s *Service) GetByID(
	ctx context.Context,
	id string,
) (*auth.UserInfo, error) {
	user, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}

	return toUserInfo(user), nil
}

func (s *Service) GetByEmail(
	ctx context.Context,
	email string,
) (*auth.UserInfo, error) {
	user, err := s.repo.GetByEmail(ctx, strings.ToLower(email))
	if err != nil {
		return nil, err
	}

	return toUserInfo(user), nil
}

func (s *Service) Create(
	ctx context.Context,
	email, passwordHash, name string,
) (*auth.UserInfo, error) {
	user := &User{
		ID:           uuid.New().String(),
		Email:        strings.ToLower(email),
		PasswordHash: passwordHash,
		Name:         name,
		Role:         RoleUser,
		Tier:         TierFree,
	}

	if err := s.repo.Create(ctx, user); err != nil {
		return nil, err
	}

	return toUserInfo(user), nil
}

func (s *Service) IncrementTokenVersion(
	ctx context.Context,
	userID string,
) error {
	return s.repo.IncrementTokenVersion(ctx, userID)
}

func (s *Service) UpdatePassword(
	ctx context.Context,
	userID, passwordHash string,
) error {
	return s.repo.UpdatePassword(ctx, userID, passwordHash)
}

// SetRole flips a user's role. Used by ADMIN_EMAIL bootstrapping in
// auth.Service: the configured email gets promoted to admin on every
// login/register so a fresh DB after env changes still has an admin.
func (s *Service) SetRole(ctx context.Context, userID, role string) error {
	if role != RoleUser && role != RoleAdmin {
		return fmt.Errorf(
			"set role: invalid role %q: %w",
			role,
			core.ErrInvalidInput,
		)
	}
	user, err := s.repo.GetByID(ctx, userID)
	if err != nil {
		return err
	}
	user.Role = role
	return s.repo.Update(ctx, user)
}

// UpdateEmail changes a user's email after re-verifying their password.
// Email is normalized to lowercase. Returns ErrDuplicateKey if the new
// email is already taken by another account.
func (s *Service) UpdateEmail(
	ctx context.Context,
	userID, currentPassword, newEmail string,
) (*User, error) {
	newEmail = strings.ToLower(strings.TrimSpace(newEmail))
	if newEmail == "" {
		return nil, fmt.Errorf("update email: empty: %w", core.ErrInvalidInput)
	}

	user, err := s.repo.GetByID(ctx, userID)
	if err != nil {
		return nil, err
	}

	valid, _, err := core.VerifyPasswordWithRehash(
		currentPassword,
		user.PasswordHash,
	)
	if err != nil {
		return nil, fmt.Errorf("verify password: %w", err)
	}
	if !valid {
		return nil, fmt.Errorf("update email: %w", core.ErrUnauthorized)
	}

	if user.Email == newEmail {
		return user, nil
	}

	if err := s.repo.UpdateEmail(ctx, userID, newEmail); err != nil {
		return nil, err
	}
	user.Email = newEmail
	return user, nil
}

func (s *Service) GetUser(ctx context.Context, id string) (*User, error) {
	return s.repo.GetByID(ctx, id)
}

func (s *Service) UpdateUser(
	ctx context.Context,
	id string,
	req UpdateUserRequest,
) (*User, error) {
	user, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}

	if req.Name != nil {
		user.Name = *req.Name
	}

	if err := s.repo.Update(ctx, user); err != nil {
		return nil, err
	}

	return user, nil
}

func (s *Service) AdminUpdateUser(
	ctx context.Context,
	id string,
	req AdminUpdateUserRequest,
) (*User, error) {
	user, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}

	if req.Name != nil {
		user.Name = *req.Name
	}
	if req.Role != nil {
		if *req.Role != RoleUser && *req.Role != RoleAdmin {
			return nil, fmt.Errorf(
				"update role: invalid role %q: %w",
				*req.Role,
				core.ErrInvalidInput,
			)
		}
		user.Role = *req.Role
	}
	if req.Tier != nil {
		if *req.Tier != TierFree && *req.Tier != TierPro &&
			*req.Tier != TierEnterprise {
			return nil, fmt.Errorf(
				"update tier: invalid tier %q: %w",
				*req.Tier,
				core.ErrInvalidInput,
			)
		}
		user.Tier = *req.Tier
	}

	if err := s.repo.Update(ctx, user); err != nil {
		return nil, err
	}

	return user, nil
}

func (s *Service) AdminCreateUser(
	ctx context.Context,
	req AdminCreateUserRequest,
) (*User, error) {
	hash, err := core.HashPassword(req.Password)
	if err != nil {
		return nil, fmt.Errorf("hash password: %w", err)
	}

	user := &User{
		ID:           uuid.New().String(),
		Email:        strings.ToLower(req.Email),
		PasswordHash: hash,
		Name:         req.Name,
		Role:         RoleUser,
		Tier:         TierFree,
	}
	if req.Role != nil {
		if *req.Role != RoleUser && *req.Role != RoleAdmin {
			return nil, fmt.Errorf(
				"create user: invalid role %q: %w",
				*req.Role,
				core.ErrInvalidInput,
			)
		}
		user.Role = *req.Role
	}
	if req.Tier != nil {
		if *req.Tier != TierFree && *req.Tier != TierPro &&
			*req.Tier != TierEnterprise {
			return nil, fmt.Errorf(
				"create user: invalid tier %q: %w",
				*req.Tier,
				core.ErrInvalidInput,
			)
		}
		user.Tier = *req.Tier
	}

	if err := s.repo.Create(ctx, user); err != nil {
		return nil, err
	}

	return user, nil
}

func (s *Service) DeleteUser(ctx context.Context, id string) error {
	return s.repo.SoftDelete(ctx, id)
}

func (s *Service) ListUsers(
	ctx context.Context,
	params ListUsersParams,
) ([]User, int, error) {
	return s.repo.List(ctx, params)
}

func (s *Service) GetMe(ctx context.Context, userID string) (*User, error) {
	if userID == "" {
		return nil, fmt.Errorf("get me: %w", core.ErrUnauthorized)
	}

	user, err := s.repo.GetByID(ctx, userID)
	if err != nil {
		return nil, err
	}

	return user, nil
}

func (s *Service) UpdateMe(
	ctx context.Context,
	userID string,
	req UpdateUserRequest,
) (*User, error) {
	if userID == "" {
		return nil, fmt.Errorf("update me: %w", core.ErrUnauthorized)
	}

	return s.UpdateUser(ctx, userID, req)
}

func (s *Service) DeleteMe(ctx context.Context, userID string) error {
	if userID == "" {
		return fmt.Errorf("delete me: %w", core.ErrUnauthorized)
	}

	return s.repo.SoftDelete(ctx, userID)
}

func (s *Service) EmailExists(
	ctx context.Context,
	email string,
) (bool, error) {
	exists, err := s.repo.ExistsByEmail(ctx, email)
	if err != nil {
		return false, err
	}
	return exists, nil
}

func (s *Service) CanDeleteUser(
	ctx context.Context,
	requesterID, targetID string,
) error {
	if requesterID == targetID {
		return nil
	}

	requester, err := s.repo.GetByID(ctx, requesterID)
	if err != nil {
		return err
	}

	if !requester.IsAdmin() {
		return fmt.Errorf("delete user: %w", core.ErrForbidden)
	}

	target, err := s.repo.GetByID(ctx, targetID)
	if err != nil {
		return err
	}

	if target.IsAdmin() {
		return fmt.Errorf("cannot delete admin users: %w", core.ErrForbidden)
	}

	return nil
}

func toUserInfo(u *User) *auth.UserInfo {
	return &auth.UserInfo{
		ID:           u.ID,
		Email:        u.Email,
		Name:         u.Name,
		PasswordHash: u.PasswordHash,
		Role:         u.Role,
		Tier:         u.Tier,
		TokenVersion: u.TokenVersion,
	}
}

var _ auth.UserProvider = (*Service)(nil)
