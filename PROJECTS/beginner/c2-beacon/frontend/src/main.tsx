// ===========================
// © AngelaMos | 2026
// main.tsx
//
// React entry point that mounts App into the DOM root
// ===========================

import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import './styles.scss'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>
)
