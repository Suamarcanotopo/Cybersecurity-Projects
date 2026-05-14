// AngelaMos | 2026
// dto.go

package user

import (
	"time"
)

type CreateUserRequest struct {
	Email    string `json:"email"    validate:"required,email,max=255"`
	Password string `json:"password" validate:"required,min=8,max=128"`
	Name     string `json:"name"     validate:"required,min=1,max=100"`
}

type UpdateUserRequest struct {
	Name *string `json:"name,omitempty" validate:"omitempty,min=1,max=100"`
}

type UpdateEmailRequest struct {
	CurrentPassword string `json:"current_password" validate:"required"`
	NewEmail        string `json:"new_email"        validate:"required,email,max=255"`
}

type AdminUpdateUserRequest struct {
	Name *string `json:"name,omitempty" validate:"omitempty,min=1,max=100"`
	Role *string `json:"role,omitempty" validate:"omitempty,oneof=user admin"`
	Tier *string `json:"tier,omitempty" validate:"omitempty,oneof=free pro enterprise"`
}

type AdminCreateUserRequest struct {
	Email    string  `json:"email"          validate:"required,email,max=255"`
	Password string  `json:"password"       validate:"required,min=8,max=128"`
	Name     string  `json:"name"           validate:"required,min=1,max=100"`
	Role     *string `json:"role,omitempty" validate:"omitempty,oneof=user admin"`
	Tier     *string `json:"tier,omitempty" validate:"omitempty,oneof=free pro enterprise"`
}

type UserResponse struct {
	ID        string    `json:"id"`
	Email     string    `json:"email"`
	Name      string    `json:"name"`
	Role      string    `json:"role"`
	Tier      string    `json:"tier"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type UserListResponse struct {
	Users []UserResponse `json:"users"`
}

type ListUsersParams struct {
	Page     int    `json:"page"`
	PageSize int    `json:"page_size"`
	Search   string `json:"search"`
	Role     string `json:"role"`
	Tier     string `json:"tier"`
}

func (p *ListUsersParams) Normalize() {
	if p.Page < 1 {
		p.Page = 1
	}
	if p.PageSize < 1 {
		p.PageSize = 20
	}
	if p.PageSize > 100 {
		p.PageSize = 100
	}
}

func (p *ListUsersParams) Offset() int {
	return (p.Page - 1) * p.PageSize
}

func ToUserResponse(u *User) UserResponse {
	return UserResponse{
		ID:        u.ID,
		Email:     u.Email,
		Name:      u.Name,
		Role:      u.Role,
		Tier:      u.Tier,
		CreatedAt: u.CreatedAt,
		UpdatedAt: u.UpdatedAt,
	}
}

func ToUserResponseList(users []User) []UserResponse {
	responses := make([]UserResponse, 0, len(users))
	for _, u := range users {
		responses = append(responses, ToUserResponse(&u))
	}
	return responses
}
