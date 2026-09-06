import { readFileSync } from 'node:fs'

import { describe, expect, it } from 'vitest'

import {
  parseBundleEnvelope,
  type CompiledRoute,
} from '../src/bundle.js'
import {
  WafEvaluator,
  WafEvaluatorError,
} from '../src/waf.js'

const envelopeText = readFileSync(
  new URL(
    './fixtures/go-signed-envelope.json',
    import.meta.url,
  ),
  'utf8',
)

function readRoute(): CompiledRoute {
  const envelope = parseBundleEnvelope(
    JSON.parse(envelopeText) as unknown,
  )

  return envelope.bundle.routes[0]!
}

describe('WAF evaluator', () => {
  it('blocks the path traversal rule from the Go bundle', () => {
    const evaluator = new WafEvaluator(readRoute())

    const result = evaluator.evaluate({
      path: '/v1/orders/%2E%2E/secrets',
      query: '',
      headers: new Headers(),
    })

    expect(result).toEqual({
      blocked: true,
      matches: [
        {
          ruleId: 'block-path-traversal',
          target: 'path',
          action: 'block',
        },
      ],
    })

    expect(
      evaluator.evaluate({
        path: '/v1/orders/42',
        query: '',
        headers: new Headers(),
      }),
    ).toEqual({
      blocked: false,
      matches: [],
    })
  })

  it('records log rules without blocking', () => {
    const route = readRoute()

    route.waf = [
      {
        id: 'log-risky-header',
        target: 'headers',
        pattern: 'x-risk: suspicious',
        flags: 'i',
        action: 'log',
      },
    ]

    const evaluator = new WafEvaluator(route)

    const result = evaluator.evaluate({
      path: '/v1/orders/42',
      query: '',
      headers: new Headers({
        'X-Risk': 'Suspicious',
      }),
    })

    expect(result).toEqual({
      blocked: false,
      matches: [
        {
          ruleId: 'log-risky-header',
          target: 'headers',
          action: 'log',
        },
      ],
    })
  })

  it('evaluates query and body targets', () => {
    const route = readRoute()

    route.waf = [
      {
        id: 'block-debug-query',
        target: 'query',
        pattern: '(^|&)debug=true(&|$)',
        action: 'block',
      },
      {
        id: 'log-password-body',
        target: 'body',
        pattern: 'password',
        flags: 'i',
        action: 'log',
      },
    ]

    const evaluator = new WafEvaluator(route)

    const result = evaluator.evaluate({
      path: '/v1/orders/42',
      query: 'debug=true',
      headers: new Headers(),
      body: '{"password":"secret"}',
    })

    expect(result.blocked).toBe(true)
    expect(result.matches).toEqual([
      {
        ruleId: 'block-debug-query',
        target: 'query',
        action: 'block',
      },
      {
        ruleId: 'log-password-body',
        target: 'body',
        action: 'log',
      },
    ])
  })

  it('rejects invalid or duplicate rules', () => {
    const invalidRoute = readRoute()

    invalidRoute.waf = [
      {
        id: 'invalid-pattern',
        target: 'path',
        pattern: '[unclosed',
        action: 'block',
      },
    ]

    expect(
      () => new WafEvaluator(invalidRoute),
    ).toThrow(WafEvaluatorError)

    const duplicateRoute = readRoute()
    const rule = duplicateRoute.waf![0]!

    duplicateRoute.waf = [
      rule,
      {
        ...rule,
      },
    ]

    expect(
      () => new WafEvaluator(duplicateRoute),
    ).toThrow(
      'duplicate WAF rule ID: block-path-traversal',
    )
  })
})