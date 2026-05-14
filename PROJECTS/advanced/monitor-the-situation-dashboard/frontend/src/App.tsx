// ©AngelaMos | 2026
// App.tsx

import { QueryClientProvider } from '@tanstack/react-query'
import { ReactQueryDevtools } from '@tanstack/react-query-devtools'
import { RouterProvider } from 'react-router-dom'
import { Toaster } from 'sonner'

import { queryClient } from '@/core/api'
import { router } from '@/core/app/routers'

export default function App(): React.ReactElement {
  return (
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
      <Toaster
        position="top-right"
        duration={2500}
        theme="dark"
        toastOptions={{
          style: {
            background: 'var(--bg-panel)',
            border: '1px solid var(--fg-4)',
            color: 'var(--fg-1)',
            borderRadius: 0,
            fontFamily: 'var(--font-sans)',
            fontSize: 'var(--type-body)',
          },
        }}
      />
      <ReactQueryDevtools initialIsOpen={false} />
    </QueryClientProvider>
  )
}
