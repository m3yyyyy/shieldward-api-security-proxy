import { describe, expect, it, vi } from 'vitest'

import {
  BUNDLE_SCHEMA_VERSION,
  type Bundle,
} from '../src/bundle.js'
import type { ConfigurationSnapshot } from '../src/config-client.js'
import type { PolicyEvaluator } from '../src/gateway.js'
import {
  LivePolicyError,
  LivePolicyEvaluator,
  type PolicyEngineFactory,
} from '../src/live-policy.js'
import type {
  PolicyDecision,
  PolicyRequest,
} from '../src/policy-engine.js'

const request: PolicyRequest = {
  method: 'GET',
  url: new URL(
    'https://edge.example/v1/orders/42',
  ),
  headers: new Headers(),
}

const deniedDecision: PolicyDecision = {
  allowed: false,
  status: 403,
  code: 'default_deny',
  route: undefined,
  wafMatches: [],
  retryAfterSeconds: undefined,
}

function createBundle(character: string): Bundle {
  return {
    schemaVersion: BUNDLE_SCHEMA_VERSION,
    policyName: 'test-policy',
    defaultDecision: 'deny',
    matchers: [
      {
        method: 'GET',
        regex: '^(?:(/v1/orders/[^/]+))$',
        routeIds: ['orders-read'],
      },
    ],
    routes: [
      {
        id: 'orders-read',
        match: {
          methods: ['GET'],
          path: '/v1/orders/:id',
        },
        upstream: 'https://orders.internal',
      },
    ],
    version: `sha256:${character.repeat(64)}`,
  }
}

function createSnapshot(
  bundle: Bundle,
): ConfigurationSnapshot {
  return {
    bundle,
    etag: `"${bundle.version}"`,
    loadedAt: 1234,
  }
}

describe('live policy evaluator', () => {
  it('fails closed before verified configuration is available', async () => {
    const factory = vi.fn<PolicyEngineFactory>()

    const evaluator = new LivePolicyEvaluator({
      configuration: {
        current: () => undefined,
      },
      policyEngineFactory: factory,
    })

    await expect(
      evaluator.evaluate(request),
    ).rejects.toThrow(LivePolicyError)

    expect(factory).not.toHaveBeenCalled()
    expect(evaluator.activeVersion()).toBeUndefined()
  })

  it('creates one evaluator for the current bundle', async () => {
    const snapshot = createSnapshot(
      createBundle('a'),
    )

    const evaluate = vi.fn<
      PolicyEvaluator['evaluate']
    >(async () => deniedDecision)

    const factory = vi.fn<PolicyEngineFactory>(
      () => ({
        evaluate,
      }),
    )

    const evaluator = new LivePolicyEvaluator({
      configuration: {
        current: () => snapshot,
      },
      policyEngineFactory: factory,
    })

    await evaluator.evaluate(request)
    await evaluator.evaluate(request)

    expect(factory).toHaveBeenCalledOnce()
    expect(evaluate).toHaveBeenCalledTimes(2)
    expect(evaluator.activeVersion()).toBe(
      snapshot.bundle.version,
    )
  })

  it('switches evaluators when the verified bundle changes', async () => {
    const firstSnapshot = createSnapshot(
      createBundle('a'),
    )
    const secondSnapshot = createSnapshot(
      createBundle('b'),
    )

    let snapshot = firstSnapshot

    const firstEvaluate = vi.fn<
      PolicyEvaluator['evaluate']
    >(async () => deniedDecision)

    const secondEvaluate = vi.fn<
      PolicyEvaluator['evaluate']
    >(async () => deniedDecision)

    const factory = vi.fn<PolicyEngineFactory>()

    factory
      .mockReturnValueOnce({
        evaluate: firstEvaluate,
      })
      .mockReturnValueOnce({
        evaluate: secondEvaluate,
      })

    const evaluator = new LivePolicyEvaluator({
      configuration: {
        current: () => snapshot,
      },
      policyEngineFactory: factory,
    })

    await evaluator.evaluate(request)

    snapshot = secondSnapshot

    await evaluator.evaluate(request)

    expect(factory).toHaveBeenCalledTimes(2)
    expect(firstEvaluate).toHaveBeenCalledOnce()
    expect(secondEvaluate).toHaveBeenCalledOnce()
    expect(evaluator.activeVersion()).toBe(
      secondSnapshot.bundle.version,
    )
  })

  it('keeps the active policy if replacement construction fails', async () => {
    const firstSnapshot = createSnapshot(
      createBundle('a'),
    )
    const secondSnapshot = createSnapshot(
      createBundle('b'),
    )

    let snapshot = firstSnapshot

    const activeEvaluator: PolicyEvaluator = {
      evaluate: async () => deniedDecision,
    }

    const factory = vi.fn<PolicyEngineFactory>()

    factory
      .mockReturnValueOnce(activeEvaluator)
      .mockImplementationOnce(() => {
        throw new Error('invalid replacement')
      })

    const evaluator = new LivePolicyEvaluator({
      configuration: {
        current: () => snapshot,
      },
      policyEngineFactory: factory,
    })

    await evaluator.evaluate(request)

    snapshot = secondSnapshot

    await expect(
      evaluator.evaluate(request),
    ).rejects.toThrow('invalid replacement')

    expect(evaluator.activeVersion()).toBe(
      firstSnapshot.bundle.version,
    )
  })
})