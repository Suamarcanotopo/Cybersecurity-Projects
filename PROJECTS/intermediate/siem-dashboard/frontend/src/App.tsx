// ===================
// ©AngelaMos | 2026
// App.tsx
//
// Root application component
//
// Wraps the app in QueryClientProvider and RouterProvider, mounts the
// Sonner toast container, and attaches React Query Devtools. Every
// authenticated page renders inside this component's tree.
//
// Key components:
//   App - Root component exported as default
//
// Connects to:
//   router.tsx - provides the browser router
//   query.ts - provides the queryClient singleton
// ===================

import { QueryClientProvider } from '@tanstack/react-query'
import { ReactQueryDevtools } from '@tanstack/react-query-devtools'
import { RouterProvider } from 'react-router-dom'
import { Toaster } from 'sonner'
import { router } from '@/core/app/router'
import { queryClient } from '@/core/lib'

export default function App(): React.ReactElement {
  return (
    <QueryClientProvider client={queryClient}>
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
      <ReactQueryDevtools initialIsOpen={false} />
    </QueryClientProvider>
  )
}
