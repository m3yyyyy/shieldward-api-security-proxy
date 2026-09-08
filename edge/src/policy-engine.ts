import type {
  Bundle,
  CompiledRoute,
  JwtPolicy,
} from './bundle.js'
import {
  JwtVerifier,
  type VerifiedJwt,
} from './jwt.js'
import {
  FixedWindowRateLimiter,
  type RateLimiter,
  type RateLimitResult,
} from './rate-limit.js'
import { RouteMatcher } from './route-matcher.js'
import {
  WafEvaluator,
  type WafRuleMatch,
} from './waf.js'

export interface PolicyRequest {
  readonly method: string
  readonly url: URL
  readonly headers: Headers
  readonly body?: string
  readonly clientIp?: string
}

export interface JwtVerifierContract {
  verifyAuthorization(
    authorization: string | null,
    policy: Readonly<JwtPolicy>,
  ): Promise<VerifiedJwt>
}

export type RateLimiterContract = RateLimiter

export interface PolicyEngineOptions {
  readonly jwtVerifier?: JwtVerifierContract
  readonly rateLimiter?: RateLimiterContract
}

export interface AllowedPolicyDecision {
  readonly allowed: true
  readonly route:
    | Readonly<CompiledRoute>
    | undefined
  readonly jwt: VerifiedJwt | undefined
  readonly rateLimit: RateLimitResult | undefined
  readonly wafMatches: readonly WafRuleMatch[]
}

export interface DeniedPolicyDecision {
  readonly allowed: false
  readonly status: 401 | 403 | 429 | 503
  readonly code:
    | 'default_deny'
    | 'waf_blocked'
    | 'jwt_invalid'
    | 'client_identity_unavailable'
    | 'jwt_subject_unavailable'
    | 'rate_limiter_unavailable'
    | 'rate_limited'
  readonly route:
    | Readonly<CompiledRoute>
    | undefined
  readonly wafMatches: readonly WafRuleMatch[]
  readonly retryAfterSeconds: number | undefined
}

export type PolicyDecision =
  | AllowedPolicyDecision
  | DeniedPolicyDecision

export class PolicyEngine {
  readonly #matcher: RouteMatcher
  readonly #jwtVerifier: JwtVerifierContract
  readonly #rateLimiter: RateLimiterContract
  readonly #wafByRoute = new Map<
    string,
    WafEvaluator
  >()

  constructor(
    bundle: Readonly<Bundle>,
    options: PolicyEngineOptions = {},
  ) {
    this.#matcher = new RouteMatcher(bundle)
    this.#jwtVerifier =
      options.jwtVerifier ?? new JwtVerifier()
    this.#rateLimiter =
      options.rateLimiter ??
      new FixedWindowRateLimiter()

    for (const route of bundle.routes) {
      this.#wafByRoute.set(
        route.id,
        new WafEvaluator(route),
      )
    }
  }

  async evaluate(
    input: PolicyRequest,
  ): Promise<PolicyDecision> {
    const resolution = this.#matcher.resolve(
      input.method,
      input.url.pathname,
    )

    if (resolution.kind === 'default') {
      if (resolution.decision === 'allow') {
        return {
          allowed: true,
          route: undefined,
          jwt: undefined,
          rateLimit: undefined,
          wafMatches: [],
        }
      }

      return denied(
        403,
        'default_deny',
        undefined,
        [],
      )
    }

    const route = resolution.route
    const waf = this.#wafByRoute.get(route.id)

    if (waf === undefined) {
      return denied(
        503,
        'rate_limiter_unavailable',
        route,
        [],
      )
    }

    const wafResult = waf.evaluate({
      path: input.url.pathname,
      query: input.url.search.startsWith('?')
        ? input.url.search.slice(1)
        : input.url.search,
      headers: input.headers,
      ...(input.body === undefined
        ? {}
        : {
            body: input.body,
          }),
    })

    if (wafResult.blocked) {
      return denied(
        403,
        'waf_blocked',
        route,
        wafResult.matches,
      )
    }

    let verifiedJwt: VerifiedJwt | undefined

    if (route.jwt !== undefined) {
      try {
        verifiedJwt =
          await this.#jwtVerifier.verifyAuthorization(
            input.headers.get('authorization'),
            route.jwt,
          )
      } catch {
        return denied(
          401,
          'jwt_invalid',
          route,
          wafResult.matches,
        )
      }
    }

    let rateLimitResult:
      | RateLimitResult
      | undefined

    if (route.rateLimit !== undefined) {
      let identity: string | undefined

      if (route.rateLimit.key === 'jwt.sub') {
        identity = verifiedJwt?.subject

        if (
          identity === undefined ||
          identity.trim() === ''
        ) {
          return denied(
            401,
            'jwt_subject_unavailable',
            route,
            wafResult.matches,
          )
        }
      } else {
        identity = input.clientIp

        if (
          identity === undefined ||
          identity.trim() === ''
        ) {
          return denied(
            503,
            'client_identity_unavailable',
            route,
            wafResult.matches,
          )
        }
      }

      try {
        rateLimitResult =
          await this.#rateLimiter.check(
            route.id,
            identity,
            route.rateLimit,
          )
      } catch {
        return denied(
          503,
          'rate_limiter_unavailable',
          route,
          wafResult.matches,
        )
      }

      if (!rateLimitResult.allowed) {
        return denied(
          429,
          'rate_limited',
          route,
          wafResult.matches,
          rateLimitResult.retryAfterSeconds,
        )
      }
    }

    return {
      allowed: true,
      route,
      jwt: verifiedJwt,
      rateLimit: rateLimitResult,
      wafMatches: wafResult.matches,
    }
  }
}

function denied(
  status: DeniedPolicyDecision['status'],
  code: DeniedPolicyDecision['code'],
  route: Readonly<CompiledRoute> | undefined,
  wafMatches: readonly WafRuleMatch[],
  retryAfterSeconds?: number,
): DeniedPolicyDecision {
  return {
    allowed: false,
    status,
    code,
    route,
    wafMatches,
    retryAfterSeconds,
  }
}
