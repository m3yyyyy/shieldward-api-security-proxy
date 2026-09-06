import type {
  CompiledRoute,
  WafAction,
  WafRule,
  WafTarget,
} from './bundle.js'

export interface WafRequestInput {
  readonly path: string
  readonly query: string
  readonly headers: Headers
  readonly body?: string
}

export interface WafRuleMatch {
  readonly ruleId: string
  readonly target: WafTarget
  readonly action: WafAction
}

export interface WafEvaluation {
  readonly blocked: boolean
  readonly matches: readonly WafRuleMatch[]
}

interface CompiledWafRule {
  readonly rule: Readonly<WafRule>
  readonly expression: RegExp
}

export class WafEvaluatorError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'WafEvaluatorError'
  }
}

export class WafEvaluator {
  readonly #rules: readonly CompiledWafRule[]

  constructor(route: Readonly<CompiledRoute>) {
    const seenIds = new Set<string>()

    this.#rules = (route.waf ?? []).map((rule) => {
      if (seenIds.has(rule.id)) {
        throw new WafEvaluatorError(
          `duplicate WAF rule ID: ${rule.id}`,
        )
      }

      seenIds.add(rule.id)

      let expression: RegExp

      try {
        expression = new RegExp(
          rule.pattern,
          rule.flags ?? '',
        )
      } catch {
        throw new WafEvaluatorError(
          `WAF rule ${rule.id} has an invalid pattern`,
        )
      }

      return {
        rule,
        expression,
      }
    })
  }

  evaluate(input: WafRequestInput): WafEvaluation {
    const matches: WafRuleMatch[] = []
    const headerText = serializeHeaders(input.headers)

    for (const compiled of this.#rules) {
      const value = targetValue(
        compiled.rule.target,
        input,
        headerText,
      )

      if (!compiled.expression.test(value)) {
        continue
      }

      matches.push({
        ruleId: compiled.rule.id,
        target: compiled.rule.target,
        action: compiled.rule.action,
      })
    }

    return {
      blocked: matches.some(
        (match) => match.action === 'block',
      ),
      matches,
    }
  }
}

function targetValue(
  target: WafTarget,
  input: WafRequestInput,
  headerText: string,
): string {
  switch (target) {
    case 'path':
      return input.path

    case 'query':
      return input.query

    case 'headers':
      return headerText

    case 'body':
      return input.body ?? ''
  }
}

function serializeHeaders(headers: Headers): string {
  const lines: string[] = []

  headers.forEach((value, name) => {
    lines.push(`${name}: ${value}`)
  })

  return lines.join('\n')
}