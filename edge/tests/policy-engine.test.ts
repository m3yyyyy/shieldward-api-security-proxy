import { readFileSync } from 'node:fs'

import { describe, expect, it, vi } from 'vitest'

import {
  parseBundleEnvelope,
  type Bundle,
} from '../src/bundle.js'
import type { VerifiedJwt } from '../src/jwt.js'
import {
  PolicyEngine,
  type JwtVerifierContract,
  type PolicyRequest,
  type RateLimiterContract,
} from '../src/policy-engine.js'
import type { RateLimitResult } from '../src/rate-limit.js'

const envelopeText = readFileSync(
  new URL(
    './fixtures/go-signed-envelope.json',
    import.meta.url,
  ),
  'utf8',
)

const verifiedJwt: VerifiedJwt = {
  subject: 'user-123',
  payload: {
    sub: 'user-123',
  },
  protectedHeader: {
    alg: 'RS256',
  },
}

const allowedRateLimit: RateLimitResult = {
  allowed: true,
  limit: 120,
  remaining: 119,
  resetAt: 60_000,
  retryAfterSeconds: 60,
}

function readBundle(): Bundle {
  return parseBundleEnvelope(
    JSON.parse(envelopeText) as unknown,
  ).bundle
}

function createRequest(
  options: {
    readonly method?: string
    readonly path?: string
    readonly headers?: HeadersInit
  } = {},
): PolicyRequest {
  return {
    method: options.method ?? 'GET',
    url: new URL(
      options.path ?? '/v1/orders/42',
      'https://edge.test',
    ),
    headers: new Headers(
      options.headers ?? {
        authorization: 'Bearer aaa.bbb.ccc',
      },
    ),
    clientIp: '203.0.113.10',
  }
}

function createDependencies() {
  const verifyAuthorization = vi.fn<
    JwtVerifierContract['verifyAuthorization']
  >(async () => verifiedJwt)

  const check = vi.fn<
    RateLimiterContract['check']
  >(() => allowedRateLimit)

  const jwtVerifier: JwtVerifierContract = {
    verifyAuthorization,
  }

  const rateLimiter: RateLimiterContract = {
    check,
  }

  return {
    verifyAuthorization,
    check,
    jwtVerifier,
    rateLimiter,
  }
}

describe('policy engine', () => {
  it('applies the bundle default decision', async () => {
    const dependencies = createDependencies()
    const deniedEngine = new PolicyEngine(
      readBundle(),
      dependencies,
    )

    const deniedDecision =
      await deniedEngine.evaluate(
        createRequest({
          method: 'POST',
        }),
      )

    expect(deniedDecision).toMatchObject({
      allowed: false,
      status: 403,
      code: 'default_deny',
      route: undefined,
    })

    const allowBundle = readBundle()
    allowBundle.defaultDecision = 'allow'

    const allowedEngine = new PolicyEngine(
      allowBundle,
      dependencies,
    )

    const allowedDecision =
      await allowedEngine.evaluate(
        createRequest({
          method: 'POST',
        }),
      )

    expect(allowedDecision).toMatchObject({
      allowed: true,
      route: undefined,
    })

    expect(
      dependencies.verifyAuthorization,
    ).not.toHaveBeenCalled()
  })

  it('blocks WAF matches before authentication', async () => {
    const bundle = readBundle()
    const route = bundle.routes[0]!

    route.waf = [
      {
        id: 'block-attack-header',
        target: 'headers',
        pattern: 'x-attack: true',
        action: 'block',
      },
    ]

    const dependencies = createDependencies()
    const engine = new PolicyEngine(
      bundle,
      dependencies,
    )

    const decision = await engine.evaluate(
      createRequest({
        headers: {
          authorization: 'Bearer aaa.bbb.ccc',
          'x-attack': 'true',
        },
      }),
    )

    expect(decision).toMatchObject({
      allowed: false,
      status: 403,
      code: 'waf_blocked',
      wafMatches: [
        {
          ruleId: 'block-attack-header',
          action: 'block',
        },
      ],
    })

    expect(
      dependencies.verifyAuthorization,
    ).not.toHaveBeenCalled()

    expect(
      dependencies.check,
    ).not.toHaveBeenCalled()
  })

  it('denies requests when JWT verification fails', async () => {
    const dependencies = createDependencies()

    dependencies.verifyAuthorization.mockRejectedValue(
      new Error('invalid token'),
    )

    const engine = new PolicyEngine(
      readBundle(),
      dependencies,
    )

    const decision = await engine.evaluate(
      createRequest(),
    )

    expect(decision).toMatchObject({
      allowed: false,
      status: 401,
      code: 'jwt_invalid',
    })

    expect(
      dependencies.check,
    ).not.toHaveBeenCalled()
  })

  it('requires a JWT subject for subject rate limits', async () => {
    const dependencies = createDependencies()

    dependencies.verifyAuthorization.mockResolvedValue({
      subject: undefined,
      payload: {},
      protectedHeader: {
        alg: 'RS256',
      },
    })

    const engine = new PolicyEngine(
      readBundle(),
      dependencies,
    )

    const decision = await engine.evaluate(
      createRequest(),
    )

    expect(decision).toMatchObject({
      allowed: false,
      status: 401,
      code: 'jwt_subject_unavailable',
    })

    expect(
      dependencies.check,
    ).not.toHaveBeenCalled()
  })

  it('returns retry information when rate limited', async () => {
    const dependencies = createDependencies()

    dependencies.check.mockReturnValue({
      allowed: false,
      limit: 120,
      remaining: 0,
      resetAt: 42_000,
      retryAfterSeconds: 42,
    })

    const bundle = readBundle()
    const route = bundle.routes[0]!

    const engine = new PolicyEngine(
      bundle,
      dependencies,
    )

    const decision = await engine.evaluate(
      createRequest(),
    )

    expect(dependencies.check).toHaveBeenCalledWith(
      'orders-read',
      'user-123',
      route.rateLimit,
    )

    expect(decision).toMatchObject({
      allowed: false,
      status: 429,
      code: 'rate_limited',
      retryAfterSeconds: 42,
    })
  })

  it('allows a request after every control passes', async () => {
    const dependencies = createDependencies()
    const engine = new PolicyEngine(
      readBundle(),
      dependencies,
    )

    const decision = await engine.evaluate(
      createRequest(),
    )

    expect(decision.allowed).toBe(true)

    if (decision.allowed) {
      expect(decision.route?.id).toBe('orders-read')
      expect(decision.jwt?.subject).toBe('user-123')
      expect(decision.rateLimit).toEqual(
        allowedRateLimit,
      )
      expect(decision.wafMatches).toEqual([])
    }
  })
})