// ===========================
// © AngelaMos | 2026
// App.tsx
//
// Root application component wrapping the router and toast notifications
//
// Renders RouterProvider with the configured browser router and a
// Sonner Toaster styled to the dark C2 theme. This is the single
// component mounted by main.tsx.
//
// Connects to:
//   routers.tsx - provides the router instance
// ===========================

import { RouterProvider } from 'react-router-dom'
import { Toaster } from 'sonner'

import { router } from '@/core/app/routers'
import '@/core/app/toast.module.scss'

export default function App(): React.ReactElement {
  return (
    <div className="app">
      <RouterProvider router={router} />
      <Toaster
        position="top-right"
        duration={2000}
        theme="dark"
        toastOptions={{
          style: {
            background: 'hsl(0, 0%, 12.2%)',
            border: '1px solid hsl(0, 0%, 18%)',
            color: 'hsl(0, 0%, 98%)',
          },
        }}
      />
    </div>
  )
}
