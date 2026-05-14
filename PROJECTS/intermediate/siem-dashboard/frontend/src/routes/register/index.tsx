// ===================
// ©AngelaMos | 2026
// index.tsx
//
// Registration page with confirm-password validation and automatic login on success
//
// Extends registerRequestSchema locally with a confirmPassword field and a
// refine check that both passwords match. On success, useRegister stores the
// token and user profile then redirects to the dashboard. Both password
// fields have independent visibility toggles.
//
// Key components:
//   Component - lazy-loaded register page; displayName "Register"
//
// Connects to:
//   useAuth.ts - useRegister mutation
//   auth.types.ts - registerRequestSchema, PASSWORD_MIN constant
//   config.ts - ROUTES for navigation targets
// ===================

import { useState } from 'react'
import { LuArrowLeft, LuEye, LuEyeOff } from 'react-icons/lu'
import { Link, useNavigate } from 'react-router-dom'
import { toast } from 'sonner'
import { z } from 'zod'
import { useRegister } from '@/api/hooks'
import { PASSWORD_MIN, registerRequestSchema } from '@/api/types'
import { ROUTES } from '@/config'
import styles from './register.module.scss'

const registerFormSchema = registerRequestSchema
  .extend({
    confirmPassword: z
      .string()
      .min(PASSWORD_MIN, `Password must be at least ${PASSWORD_MIN} characters`),
  })
  .refine((data) => data.password === data.confirmPassword, {
    message: 'Passwords do not match',
    path: ['confirmPassword'],
  })

export function Component(): React.ReactElement {
  const navigate = useNavigate()
  const register = useRegister()

  const [username, setUsername] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [showPassword, setShowPassword] = useState(false)
  const [showConfirmPassword, setShowConfirmPassword] = useState(false)

  const handleSubmit = (e: React.FormEvent): void => {
    e.preventDefault()

    const result = registerFormSchema.safeParse({
      username,
      email,
      password,
      confirmPassword,
    })

    if (!result.success) {
      const firstError = result.error.issues[0]
      toast.error(firstError.message)
      return
    }

    register.mutate(
      {
        username: result.data.username,
        email: result.data.email,
        password: result.data.password,
      },
      {
        onSuccess: () => {
          navigate(ROUTES.DASHBOARD)
        },
      }
    )
  }

  return (
    <div className={styles.page}>
      <Link to={ROUTES.LANDING} className={styles.homeLink}>
        <LuArrowLeft />
        Home
      </Link>
      <div className={styles.card}>
        <div className={styles.header}>
          <h1 className={styles.title}>Sign up</h1>
          <p className={styles.subtitle}>Create a new account</p>
        </div>

        <form className={styles.form} onSubmit={handleSubmit}>
          <div className={styles.field}>
            <label className={styles.label} htmlFor="username">
              Username
            </label>
            <input
              id="username"
              type="text"
              className={styles.input}
              placeholder="xxx"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              autoComplete="username"
            />
          </div>

          <div className={styles.field}>
            <label className={styles.label} htmlFor="email">
              Email
            </label>
            <input
              id="email"
              type="email"
              className={styles.input}
              placeholder="xx@example.com"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoComplete="email"
            />
          </div>

          <div className={styles.field}>
            <label className={styles.label} htmlFor="password">
              Password
            </label>
            <div className={styles.inputWrapper}>
              <input
                id="password"
                type={showPassword ? 'text' : 'password'}
                className={styles.input}
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                autoComplete="new-password"
              />
              <button
                type="button"
                className={styles.eyeButton}
                onClick={() => setShowPassword(!showPassword)}
                aria-label={showPassword ? 'Hide password' : 'Show password'}
              >
                {showPassword ? <LuEyeOff /> : <LuEye />}
              </button>
            </div>
          </div>

          <div className={styles.field}>
            <label className={styles.label} htmlFor="confirmPassword">
              Repeat Password
            </label>
            <div className={styles.inputWrapper}>
              <input
                id="confirmPassword"
                type={showConfirmPassword ? 'text' : 'password'}
                className={styles.input}
                value={confirmPassword}
                onChange={(e) => setConfirmPassword(e.target.value)}
                autoComplete="new-password"
              />
              <button
                type="button"
                className={styles.eyeButton}
                onClick={() => setShowConfirmPassword(!showConfirmPassword)}
                aria-label={
                  showConfirmPassword ? 'Hide password' : 'Show password'
                }
              >
                {showConfirmPassword ? <LuEyeOff /> : <LuEye />}
              </button>
            </div>
          </div>

          <button
            type="submit"
            className={styles.submit}
            disabled={register.isPending}
          >
            {register.isPending ? 'Creating account...' : 'Sign up'}
          </button>
        </form>

        <p className={styles.footer}>
          Already have an account?{' '}
          <Link to={ROUTES.LOGIN} className={styles.link}>
            Login
          </Link>
        </p>
      </div>
    </div>
  )
}

Component.displayName = 'Register'
