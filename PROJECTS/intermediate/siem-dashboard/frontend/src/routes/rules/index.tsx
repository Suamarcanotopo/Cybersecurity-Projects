// ===================
// ©AngelaMos | 2026
// index.tsx
//
// Correlation rules page with rule list, create form, test run, and delete actions
//
// The toolbar shows a rule count and a button to open the RuleForm overlay.
// RuleCard expands on click to show the raw conditions JSON and buttons to
// test or delete the rule. Test results show events evaluated and alert count.
// RuleForm pre-fills the conditions textarea from CONDITION_TEMPLATES when the
// rule type changes. RuleForm is an internal helper component.
//
// Key components:
//   Component - lazy-loaded rules page; displayName "Rules"
//
// Connects to:
//   useRules.ts - rule list, create, delete, and test mutations
//   rule.types.ts - CorrelationRule type
// ===================

import { useCallback, useState } from 'react'
import { LuFlaskConical, LuPlus, LuTrash2, LuX } from 'react-icons/lu'
import { useCreateRule, useDeleteRule, useRules, useTestRule } from '@/api/hooks'
import type { CorrelationRule } from '@/api/types'
import styles from './rules.module.scss'

export function Component(): React.ReactElement {
  const { data: rules, isLoading } = useRules()
  const [showForm, setShowForm] = useState(false)
  const [selectedId, setSelectedId] = useState<string | null>(null)

  return (
    <div className={styles.page}>
      <div className={styles.toolbar}>
        <span className={styles.count}>{rules?.length ?? 0} rules</span>
        <button
          type="button"
          className={styles.createBtn}
          onClick={() => setShowForm(true)}
        >
          <LuPlus />
          Create Rule
        </button>
      </div>

      {showForm && <RuleForm onClose={() => setShowForm(false)} />}

      <div className={styles.list}>
        {isLoading ? (
          Array.from({ length: 3 }, (_, i) => (
            <div key={`skel-${i}`} className={styles.cardSkeleton} />
          ))
        ) : rules?.length === 0 ? (
          <div className={styles.empty}>No correlation rules configured</div>
        ) : (
          rules?.map((rule) => (
            <RuleCard
              key={rule.id}
              rule={rule}
              isSelected={selectedId === rule.id}
              onSelect={() =>
                setSelectedId(selectedId === rule.id ? null : rule.id)
              }
            />
          ))
        )}
      </div>
    </div>
  )
}

Component.displayName = 'Rules'

function RuleCard({
  rule,
  isSelected,
  onSelect,
}: {
  rule: CorrelationRule
  isSelected: boolean
  onSelect: () => void
}): React.ReactElement {
  const deleteRule = useDeleteRule()
  const testRule = useTestRule(rule.id)

  return (
    <div className={`${styles.card} ${isSelected ? styles.selected : ''}`}>
      <button type="button" className={styles.cardMain} onClick={onSelect}>
        <div className={styles.cardHeader}>
          <span className={`${styles.badge} ${styles[rule.severity]}`}>
            {rule.severity}
          </span>
          <span className={styles.ruleType}>{rule.rule_type}</span>
          <span
            className={`${styles.enabledDot} ${rule.enabled ? styles.on : ''}`}
          />
        </div>
        <h3 className={styles.cardTitle}>{rule.name}</h3>
        {rule.description && (
          <p className={styles.cardDesc}>{rule.description}</p>
        )}
        {rule.mitre_technique && (
          <span className={styles.mitre}>{rule.mitre_technique}</span>
        )}
      </button>

      {isSelected && (
        <div className={styles.cardActions}>
          <div className={styles.conditions}>
            <h4 className={styles.conditionsTitle}>Conditions</h4>
            <pre className={styles.conditionsPre}>
              {JSON.stringify(rule.conditions, null, 2)}
            </pre>
          </div>
          <div className={styles.btnGroup}>
            <button
              type="button"
              className={styles.testBtn}
              disabled={testRule.isPending}
              onClick={() => testRule.mutate({ hours: 24 })}
            >
              <LuFlaskConical />
              {testRule.isPending ? 'Testing...' : 'Test'}
            </button>
            <button
              type="button"
              className={styles.deleteBtn}
              disabled={deleteRule.isPending}
              onClick={() => deleteRule.mutate(rule.id)}
            >
              <LuTrash2 />
            </button>
          </div>
          {testRule.data && (
            <div className={styles.testResults}>
              <span className={styles.testStat}>
                {testRule.data.events_evaluated.toLocaleString()} events evaluated
              </span>
              <span className={styles.testStat}>
                {testRule.data.alerts_would_fire} alerts would fire
              </span>
            </div>
          )}
        </div>
      )}
    </div>
  )
}

const CONDITION_TEMPLATES: Record<string, string> = {
  threshold:
    '{\n  "event_filter": {},\n  "threshold": 5,\n  "window_seconds": 300,\n  "group_by": "source_ip"\n}',
  sequence:
    '{\n  "steps": [\n    { "event_filter": { "event_type": "login_failure" }, "count": 5 },\n    { "event_filter": { "event_type": "login_success" }, "count": 1 }\n  ],\n  "window_seconds": 300,\n  "group_by": "source_ip"\n}',
  aggregation:
    '{\n  "event_filter": {},\n  "aggregation": "count_distinct",\n  "aggregation_field": "dest_ip",\n  "threshold": 5,\n  "window_seconds": 300,\n  "group_by": "source_ip"\n}',
}

function RuleForm({ onClose }: { onClose: () => void }): React.ReactElement {
  const createRule = useCreateRule()
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [ruleType, setRuleType] = useState('threshold')
  const [severity, setSeverity] = useState('medium')

  const [conditions, setConditions] = useState(CONDITION_TEMPLATES.threshold)

  const handleTypeChange = useCallback((type: string) => {
    setRuleType(type)
    setConditions(CONDITION_TEMPLATES[type] ?? CONDITION_TEMPLATES.threshold)
  }, [])

  const handleSubmit = (e: React.FormEvent): void => {
    e.preventDefault()
    let parsed: Record<string, unknown>
    try {
      parsed = JSON.parse(conditions)
    } catch {
      return
    }

    createRule.mutate(
      {
        name,
        description,
        rule_type: ruleType,
        severity,
        conditions: parsed,
      },
      { onSuccess: onClose }
    )
  }

  return (
    <form className={styles.form} onSubmit={handleSubmit}>
      <div className={styles.formHeader}>
        <h3 className={styles.formTitle}>Create Rule</h3>
        <button type="button" className={styles.closeBtn} onClick={onClose}>
          <LuX />
        </button>
      </div>
      <div className={styles.formGrid}>
        <div className={styles.field}>
          <label className={styles.label} htmlFor="ruleName">
            Name
          </label>
          <input
            id="ruleName"
            className={styles.input}
            value={name}
            onChange={(e) => setName(e.target.value)}
          />
        </div>
        <div className={styles.field}>
          <label className={styles.label} htmlFor="ruleDesc">
            Description
          </label>
          <input
            id="ruleDesc"
            className={styles.input}
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
        </div>
        <div className={styles.field}>
          <label className={styles.label} htmlFor="ruleType">
            Type
          </label>
          <select
            id="ruleType"
            className={styles.select}
            value={ruleType}
            onChange={(e) => handleTypeChange(e.target.value)}
          >
            <option value="threshold">Threshold</option>
            <option value="sequence">Sequence</option>
            <option value="aggregation">Aggregation</option>
          </select>
        </div>
        <div className={styles.field}>
          <label className={styles.label} htmlFor="ruleSeverity">
            Severity
          </label>
          <select
            id="ruleSeverity"
            className={styles.select}
            value={severity}
            onChange={(e) => setSeverity(e.target.value)}
          >
            <option value="critical">Critical</option>
            <option value="high">High</option>
            <option value="medium">Medium</option>
            <option value="low">Low</option>
            <option value="info">Info</option>
          </select>
        </div>
      </div>
      <div className={styles.field}>
        <label className={styles.label} htmlFor="ruleConditions">
          Conditions (JSON)
        </label>
        <textarea
          id="ruleConditions"
          className={styles.textarea}
          rows={6}
          value={conditions}
          onChange={(e) => setConditions(e.target.value)}
        />
      </div>
      <div className={styles.formActions}>
        <button type="button" className={styles.cancelBtn} onClick={onClose}>
          Cancel
        </button>
        <button
          type="submit"
          className={styles.submitBtn}
          disabled={createRule.isPending}
        >
          {createRule.isPending ? 'Creating...' : 'Create'}
        </button>
      </div>
    </form>
  )
}
