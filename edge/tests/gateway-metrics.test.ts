import { describe, expect, it, vi } from 'vitest'

import type { SecurityAuditLogger } from '../src/audit.js'
import { Gateway } from '../src/gateway.js'
import type { OperationalMetrics } from '../src/metrics.js'

function createMetrics(
  recordGatewayRequest: OperationalMetrics['recordGatewayRequest'],
): OperationalMetrics {
  return {
    recordGatewayRequest,
    recordConfigurationRefresh: () => undefined,
    recordConfigurationSyncError: () => undefined,
    recordGatewayRequestStarted: () => undefined,
    recordGatewayRequestFinished: () => undefined,
    recordGatewayOverload: () => undefined,
    recordGatewayDrainStarted: () => undefined,
    recordGatewayDrainRejection: () => undefined,
    recordUpstreamCircuitRejection: () => undefined,
    recordUpstreamCircuitTransition: () => undefined,
    recordRateLimitCheck: () => undefined,
    render: () => '',
  }
}

describe('gateway operational metrics', () => {
  it('records bounded completion data independently of audit failures', async () => {
    const recordGatewayRequest = vi.fn<
      OperationalMetrics['recordGatewayRequest']
    >()
    const auditLogger: SecurityAuditLogger = {
      record: () => {
        throw new Error('audit sink failed')
      },
    }
    const times = [100, 117]

    const gateway = new Gateway({
      policyEvaluator: {
        evaluate: async () => ({
          allowed: false,
          status: 403,
          code: 'default_deny',
          route: undefined,
          wafMatches: [],
          retryAfterSeconds: undefined,
        }),
      },
      auditLogger,
      metrics: createMetrics(recordGatewayRequest),
      requestIdFactory: () => 'request-42',
      nowMilliseconds: () => times.shift()!,
    })

    const response = await gateway.handle(
      new Request('https://edge.example/private/path'),
    )

    expect(response.status).toBe(403)
    expect(recordGatewayRequest).toHaveBeenCalledWith({
      outcome: 'denied',
      status: 403,
      durationMs: 17,
    })

    const serialized = JSON.stringify(
      recordGatewayRequest.mock.calls,
    )
    expect(serialized).not.toContain('/private/path')
    expect(serialized).not.toContain('request-42')
  })

  it('does not change a response when the metrics sink fails', async () => {
    const gateway = new Gateway({
      policyEvaluator: {
        evaluate: async () => ({
          allowed: false,
          status: 401,
          code: 'jwt_missing',
          route: undefined,
          wafMatches: [],
          retryAfterSeconds: undefined,
        }),
      },
      metrics: createMetrics(() => {
        throw new Error('metrics sink failed')
      }),
    })

    const response = await gateway.handle(
      new Request('https://edge.example/private/path'),
    )

    expect(response.status).toBe(401)
    await expect(response.json()).resolves.toEqual({
      error: 'jwt_missing',
    })
  })
})
