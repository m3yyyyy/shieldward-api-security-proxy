import { describe, expect, it, vi } from 'vitest'

import type { CompiledRoute } from '../src/bundle.js'
import {
  Gateway,
  type PolicyEvaluator,
} from '../src/gateway.js'
import type { PolicyDecision } from '../src/policy-engine.js'
import type { UpstreamFetch } from '../src/proxy.js'

const route: CompiledRoute = {
  id: 'orders-write',
  match: {
    methods: ['POST'],
    path: '/v1/orders/:id',
  },
  upstream: 'http://127.0.0.1:9000',
}

function allowedDecision(
  selectedRoute: CompiledRoute | undefined = route,
): PolicyDecision {
  return {
    allowed: true,
    route: selectedRoute,
    jwt: undefined,
    rateLimit: undefined,
    wafMatches: [],
  }
}

function deniedDecision(
  status: 401 | 403 | 429 | 503,
  code:
    | 'default_deny'
    | 'waf_blocked'
    | 'jwt_invalid'
    | 'client_identity_unavailable'
    | 'jwt_subject_unavailable'
    | 'rate_limiter_unavailable'
    | 'rate_limited',
  retryAfterSeconds?: number,
): PolicyDecision {
  return {
    allowed: false,
    status,
    code,
    route,
    wafMatches: [],
    retryAfterSeconds,
  }
}

describe('gateway', () => {
  it('returns structured policy denials', async () => {
    const evaluate = vi.fn<
      PolicyEvaluator['evaluate']
    >(async () =>
      deniedDecision(401, 'jwt_invalid'),
    )

    const gateway = new Gateway({
      policyEvaluator: {
        evaluate,
      },
    })

    const response = await gateway.handle(
      new Request(
        'https://edge.example/v1/orders/42',
      ),
    )

    expect(response.status).toBe(401)
    expect(
      response.headers.get('www-authenticate'),
    ).toBe('Bearer')
    expect(
      response.headers.get('cache-control'),
    ).toBe('no-store')

    await expect(response.json()).resolves.toEqual({
      error: 'jwt_invalid',
    })
  })

  it('returns retry information when rate limited', async () => {
    const gateway = new Gateway({
      policyEvaluator: {
        evaluate: async () =>
          deniedDecision(
            429,
            'rate_limited',
            17,
          ),
      },
    })

    const response = await gateway.handle(
      new Request(
        'https://edge.example/v1/orders/42',
      ),
    )

    expect(response.status).toBe(429)
    expect(response.headers.get('retry-after')).toBe(
      '17',
    )

    await expect(response.json()).resolves.toEqual({
      error: 'rate_limited',
    })
  })

  it('does not proxy default-allowed unmatched routes', async () => {
    const fetcher = vi.fn<UpstreamFetch>()

    const gateway = new Gateway({
      policyEvaluator: {
        evaluate: async () => ({
  allowed: true,
  route: undefined,
  jwt: undefined,
  rateLimit: undefined,
  wafMatches: [],
}),
      },
      fetcher,
    })

    const response = await gateway.handle(
      new Request(
        'https://edge.example/unmatched',
      ),
    )

    expect(response.status).toBe(404)
    expect(fetcher).not.toHaveBeenCalled()

    await expect(response.json()).resolves.toEqual({
      error: 'route_not_found',
    })
  })

  it('buffers and forwards an allowed request', async () => {
    const evaluate = vi.fn<
      PolicyEvaluator['evaluate']
    >(async (request) => {
      expect(request.body).toBe('hello')
      expect(request.clientIp).toBe('203.0.113.10')

      return allowedDecision()
    })

    const fetcher = vi.fn<UpstreamFetch>(
      async (request) => {
        expect(request.url).toBe(
          'http://127.0.0.1:9000/v1/orders/42',
        )
        expect(request.method).toBe('POST')
        expect(await request.text()).toBe('hello')
        expect(
          request.headers.get('x-forwarded-for'),
        ).toBe('203.0.113.10')

        return new Response('created', {
          status: 201,
        })
      },
    )

    const gateway = new Gateway({
      policyEvaluator: {
        evaluate,
      },
      fetcher,
    })

    const response = await gateway.handle(
      new Request(
        'https://edge.example/v1/orders/42',
        {
          method: 'POST',
          body: 'hello',
        },
      ),
      '203.0.113.10',
    )

    expect(response.status).toBe(201)
    expect(await response.text()).toBe('created')
    expect(evaluate).toHaveBeenCalledOnce()
    expect(fetcher).toHaveBeenCalledOnce()
  })

  it('rejects bodies above the configured limit', async () => {
    const evaluate = vi.fn<
      PolicyEvaluator['evaluate']
    >()

    const gateway = new Gateway({
      policyEvaluator: {
        evaluate,
      },
      maxRequestBodyBytes: 5,
    })

    const response = await gateway.handle(
      new Request(
        'https://edge.example/v1/orders/42',
        {
          method: 'POST',
          body: '123456',
        },
      ),
    )

    expect(response.status).toBe(413)
    expect(evaluate).not.toHaveBeenCalled()

    await expect(response.json()).resolves.toEqual({
      error: 'request_body_too_large',
    })
  })

  it('rejects invalid content lengths', async () => {
    const evaluate = vi.fn<
      PolicyEvaluator['evaluate']
    >()

    const gateway = new Gateway({
      policyEvaluator: {
        evaluate,
      },
    })

    const response = await gateway.handle(
      new Request(
        'https://edge.example/v1/orders/42',
        {
          method: 'POST',
          headers: {
            'content-length': 'invalid',
          },
          body: 'hello',
        },
      ),
    )

    expect(response.status).toBe(400)
    expect(evaluate).not.toHaveBeenCalled()

    await expect(response.json()).resolves.toEqual({
      error: 'invalid_content_length',
    })
  })

  it('fails closed when policy evaluation fails', async () => {
    const gateway = new Gateway({
      policyEvaluator: {
        evaluate: async () => {
          throw new Error('policy failed')
        },
      },
    })

    const response = await gateway.handle(
      new Request(
        'https://edge.example/v1/orders/42',
      ),
    )

    expect(response.status).toBe(503)

    await expect(response.json()).resolves.toEqual({
      error: 'policy_evaluation_failed',
    })
  })

  it('returns a gateway error when the upstream fails', async () => {
    const gateway = new Gateway({
      policyEvaluator: {
        evaluate: async () => allowedDecision(),
      },
      fetcher: async () => {
        throw new Error('connection refused')
      },
    })

    const response = await gateway.handle(
      new Request(
        'https://edge.example/v1/orders/42',
        {
          method: 'POST',
          body: 'hello',
        },
      ),
    )

    expect(response.status).toBe(502)

    await expect(response.json()).resolves.toEqual({
      error: 'upstream_unavailable',
    })
  })
})