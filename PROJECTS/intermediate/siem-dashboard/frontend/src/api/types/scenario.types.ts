// ===================
// ©AngelaMos | 2026
// scenario.types.ts
//
// Zod schemas and types for scenario runs and playbook metadata
//
// Exports the full ScenarioRun document type and the PlaybookInfo type that
// describes available YAML playbooks. Also exports plain interfaces for
// start and speed mutation payloads.
//
// Key exports:
//   scenarioRunSchema, ScenarioRun - active or completed scenario run
//   playbookInfoSchema, PlaybookInfo - available playbook metadata
//   ScenarioStartRequest, SpeedRequest - mutation payloads
//
// Connects to:
//   useScenarios.ts - consumes all scenario types
//   scenarios/index.tsx - renders ScenarioRun and PlaybookInfo data
// ===================

import { z } from 'zod'

export const scenarioRunSchema = z.object({
  id: z.string(),
  scenario_name: z.string(),
  status: z.string(),
  started_at: z.string(),
  completed_at: z.string().nullable(),
  events_generated: z.number(),
  speed: z.number(),
  error_message: z.string().nullable(),
  created_at: z.string(),
  updated_at: z.string(),
})

export const playbookInfoSchema = z.object({
  filename: z.string(),
  name: z.string(),
  description: z.string(),
  mitre_tactics: z.array(z.string()),
  mitre_techniques: z.array(z.string()),
  event_count: z.number(),
})

export type ScenarioRun = z.infer<typeof scenarioRunSchema>
export type PlaybookInfo = z.infer<typeof playbookInfoSchema>

export interface ScenarioStartRequest {
  filename: string
}

export interface SpeedRequest {
  speed: number
}

export const isValidScenarioRun = (data: unknown): data is ScenarioRun => {
  return scenarioRunSchema.safeParse(data).success
}

export const isValidPlaybookInfo = (data: unknown): data is PlaybookInfo => {
  return playbookInfoSchema.safeParse(data).success
}
