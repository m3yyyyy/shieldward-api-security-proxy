import { describe, expect, it, vi } from 'vitest'

import type { SecurityAuditLogger } from '../src/audit.js'
import type { CompiledRoute } from '../src/bundle.js'
import {
  Gateway,
  type GatewayOptions,
  type PolicyEvaluator,
} from '../src/gateway.js'
import type { PolicyDecision } from '../src/policy-engine.js'

const route: CompiledRoute = {
  id: 'orders-read',
  match: {
    methods: ['GET'],
    path: '/v1/orders/:id',
  },
  upstream: 'http://127.0.0.1:9000',
}

function evaluator(
  decision: PolicyDecision,
): PolicyEvaluator {
  return {
    evaluate: async () => decision,
    activeVersion: () => 'sha256:policy',
  }
}

function gatewayOptions(
  policyEvaluator: PolicyEvaluator,
  auditLogger: SecurityAuditLogger,
): GatewayOptions {
  const times = [100, 117]

  return {
    policyEvaluator,
    auditLogger,
    requestIdFactory: () => 'request-42',
    nowMilliseconds: () => times.shift()!,
  }
}

describe('gateway security auditing', () => {
  it('traces and audits an allowed upstream response', async () => {
    const record = vi.fn<
      SecurityAuditLogger['record']
    >()
    const gateway = new Gateway({
      ...gatewayOptions(
        evaluator({
          allowed: true,
          route,
          jwt: undefined,
          rateLimit: undefined,
          wafMatches: [],
        }),
        { record },
      ),
      fetcher: async (request) => {
        expect(
          request.headers.get('x-request-id'),
        ).toBe('request-42')

        return new Response('ok', {
          status: 201,
        })
      },
    })

    const response = await gateway.handle(
      new Request(
        'https://edge.example/v1/orders/42?secret=query',
      ),
    )

    expect(response.status).toBe(201)
    expect(response.headers.get('x-request-id')).toBe(
      'request-42',
    )
    expect(record).toHaveBeenCalledWith({
      requestId: 'request-42',
      method: 'GET',
      path: '/v1/orders/42',
      policyVersion: 'sha256:policy',
      routeId: 'orders-read',
      outcome: 'allowed',
      status: 201,
      upstreamStatus: 201,
      durationMs: 17,
    })
  })

  it('audits a policy denial', async () => {
    const record = vi.fn<
      SecurityAuditLogger['record']
    >()
    const gateway = new Gateway(
      gatewayOptions(
        evaluator({
          allowed: false,
          status: 401,
          code: 'jwt_invalid',
          route,
          wafMatches: [],
          retryAfterSeconds: undefined,
        }),
        { record },
      ),
    )

    const response = await gateway.handle(
      new Request(
        'https://edge.example/v1/orders/42',
      ),
    )

    expect(response.status).toBe(401)
    expect(record).toHaveBeenCalledWith(
      expect.objectContaining({
        outcome: 'denied',
        status: 401,
        reason: 'jwt_invalid',
        routeId: 'orders-read',
      }),
    )
  })

  it('audits a rate-limit denial', async () => {
    const record = vi.fn<
      SecurityAuditLogger['record']
    >()
    const gateway = new Gateway(
      gatewayOptions(
        evaluator({
          allowed: false,
          status: 429,
          code: 'rate_limited',
          route,
          wafMatches: [],
          retryAfterSeconds: 12,
        }),
        { record },
      ),
    )

    const response = await gateway.handle(
      new Request(
        'https://edge.example/v1/orders/42',
      ),
    )

    expect(response.status).toBe(429)
    expect(record).toHaveBeenCalledWith(
      expect.objectContaining({
        outcome: 'denied',
        status: 429,
        reason: 'rate_limited',
      }),
    )
  })

  it('audits policy evaluation failures', async () => {
    const record = vi.fn<
      SecurityAuditLogger['record']
    >()
    const gateway = new Gateway(
      gatewayOptions(
        {
          evaluate: async () => {
            throw new Error('evaluation failed')
          },
          activeVersion: () => 'sha256:policy',
        },
        { record },
      ),
    )

    const response = await gateway.handle(
      new Request(
        'https://edge.example/v1/orders/42',
      ),
    )

    expect(response.status).toBe(503)
    expect(record).toHaveBeenCalledWith(
      expect.objectContaining({
        outcome: 'error',
        status: 503,
        reason: 'policy_evaluation_failed',
      }),
    )
  })

  it('audits upstream failures', async () => {
    const record = vi.fn<
      SecurityAuditLogger['record']
    >()
    const gateway = new Gateway({
      ...gatewayOptions(
        evaluator({
          allowed: true,
          route,
          jwt: undefined,
          rateLimit: undefined,
          wafMatches: [],
        }),
        { record },
      ),
      fetcher: async () => {
        throw new Error('connection refused')
      },
    })

    const response = await gateway.handle(
      new Request(
        'https://edge.example/v1/orders/42',
      ),
    )

    expect(response.status).toBe(502)
    expect(record).toHaveBeenCalledWith(
      expect.objectContaining({
        outcome: 'error',
        status: 502,
        reason: 'upstream_unavailable',
        routeId: 'orders-read',
      }),
    )
  })

  it('audits upstream deadline expiration', async () => {
    const record = vi.fn<
      SecurityAuditLogger['record']
    >()
    const gateway = new Gateway({
      ...gatewayOptions(
        evaluator({
          allowed: true,
          route,
          jwt: undefined,
          rateLimit: undefined,
          wafMatches: [],
        }),
        { record },
      ),
      fetcher: (request) =>
        new Promise((_resolve, reject) => {
          request.signal.addEventListener(
            'abort',
            () => reject(request.signal.reason),
            { once: true },
          )
        }),
      upstreamTimeoutMs: 10,
    })

    const response = await gateway.handle(
      new Request(
        'https://edge.example/v1/orders/42',
      ),
    )

    expect(response.status).toBe(504)
    expect(record).toHaveBeenCalledWith(
      expect.objectContaining({
        outcome: 'error',
        status: 504,
        reason: 'upstream_timeout',
        routeId: 'orders-read',
      }),
    )
  })

  it('does not change responses when auditing fails', async () => {
    const gateway = new Gateway(
      gatewayOptions(
        evaluator({
          allowed: false,
          status: 403,
          code: 'default_deny',
          route: undefined,
          wafMatches: [],
          retryAfterSeconds: undefined,
        }),
        {
          record: () => {
            throw new Error('audit sink failed')
          },
        },
      ),
    )

    const response = await gateway.handle(
      new Request('https://edge.example/unknown'),
    )

    expect(response.status).toBe(403)
    expect(response.headers.get('x-request-id')).toBe(
      'request-42',
    )
  })
})
