import type { Bundle } from './bundle.js'
import type { ConfigurationSnapshot } from './config-client.js'
import type { PolicyEvaluator } from './gateway.js'
import { JwtVerifier } from './jwt.js'
import {
  PolicyEngine,
  type PolicyRequest,
  type PolicyDecision,
} from './policy-engine.js'
import {
  FixedWindowRateLimiter,
  type RateLimiter,
} from './rate-limit.js'

export interface ConfigurationSource {
  current(): ConfigurationSnapshot | undefined
}

export type PolicyEngineFactory = (
  bundle: Readonly<Bundle>,
) => PolicyEvaluator

export interface LivePolicyOptions {
  readonly configuration: ConfigurationSource
  readonly policyEngineFactory?: PolicyEngineFactory
  readonly rateLimiter?: RateLimiter
}

export class LivePolicyError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'LivePolicyError'
  }
}

export class LivePolicyEvaluator
  implements PolicyEvaluator
{
  readonly #configuration: ConfigurationSource
  readonly #policyEngineFactory: PolicyEngineFactory

  #activeVersion: string | undefined
  #activeEvaluator: PolicyEvaluator | undefined

  constructor(options: LivePolicyOptions) {
    this.#configuration = options.configuration

    if (options.policyEngineFactory !== undefined) {
      this.#policyEngineFactory =
        options.policyEngineFactory
      return
    }

    const jwtVerifier = new JwtVerifier()
    const rateLimiter =
      options.rateLimiter ??
      new FixedWindowRateLimiter()

    this.#policyEngineFactory = (bundle) =>
      new PolicyEngine(bundle, {
        jwtVerifier,
        rateLimiter,
      })
  }

  activeVersion(): string | undefined {
    return this.#activeVersion
  }

  async evaluate(
    request: PolicyRequest,
  ): Promise<PolicyDecision> {
    const snapshot = this.#configuration.current()

    if (snapshot === undefined) {
      throw new LivePolicyError(
        'no verified policy configuration is available',
      )
    }

    if (
      this.#activeEvaluator === undefined ||
      this.#activeVersion !== snapshot.bundle.version
    ) {
      const nextEvaluator =
        this.#policyEngineFactory(snapshot.bundle)

      this.#activeEvaluator = nextEvaluator
      this.#activeVersion = snapshot.bundle.version
    }

    return this.#activeEvaluator.evaluate(request)
  }
}
