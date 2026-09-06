import { describe, expect, it, vi } from 'vitest'

import {
  createRequestId,
  JsonSecurityAuditLogger,
  type SecurityAuditRecord,
} from '../src/audit.js'

describe('JSON security audit logger', () => {
  it('writes an allowlisted structured event', () => {
    const write = vi.fn<(line: string) => void>()
    const logger = new JsonSecurityAuditLogger({
      write,
      now: () =>
        new Date('2026-09-07T03:04:05.678Z'),
    })

    logger.record({
      requestId: 'request-42',
      method: 'GET',
      path: '/v1/orders/42',
      policyVersion: 'sha256:policy',
      routeId: 'orders-read',
      outcome: 'allowed',
      status: 200,
      upstreamStatus: 200,
      durationMs: 17,
    })

    expect(write).toHaveBeenCalledOnce()
    expect(JSON.parse(write.mock.calls[0]![0])).toEqual({
      type: 'security_request',
      schemaVersion: 1,
      timestamp: '2026-09-07T03:04:05.678Z',
      requestId: 'request-42',
      method: 'GET',
      path: '/v1/orders/42',
      outcome: 'allowed',
      status: 200,
      durationMs: 17,
      policyVersion: 'sha256:policy',
      routeId: 'orders-read',
      upstreamStatus: 200,
    })
  })

  it('does not serialize fields outside the audit contract', () => {
    const lines: string[] = []
    const logger = new JsonSecurityAuditLogger({
      write: (line) => lines.push(line),
    })
    const unsafeRecord = {
      requestId: 'request-43',
      method: 'POST',
      path: '/v1/orders',
      outcome: 'denied',
      status: 401,
      durationMs: 3,
      reason: 'jwt_invalid',
      authorization: 'Bearer secret-token',
      body: 'sensitive request body',
      jwt: 'secret-token',
    } as SecurityAuditRecord

    logger.record(unsafeRecord)

    expect(lines).toHaveLength(1)
    expect(lines[0]).not.toContain('secret-token')
    expect(lines[0]).not.toContain(
      'sensitive request body',
    )
    expect(JSON.parse(lines[0]!)).toMatchObject({
      outcome: 'denied',
      reason: 'jwt_invalid',
      status: 401,
    })
  })

  it('creates opaque UUID request identifiers', () => {
    const first = createRequestId()
    const second = createRequestId()

    expect(first).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    )
    expect(second).not.toBe(first)
  })

  it('writes policy synchronization failures without details', () => {
    const lines: string[] = []
    const logger = new JsonSecurityAuditLogger({
      write: (line) => lines.push(line),
      now: () =>
        new Date('2026-09-07T03:04:05.678Z'),
    })

    logger.recordSystem({
      component: 'configuration_sync',
      outcome: 'error',
      reason: 'configuration_sync_failed',
    })

    expect(JSON.parse(lines[0]!)).toEqual({
      type: 'security_system',
      schemaVersion: 1,
      timestamp: '2026-09-07T03:04:05.678Z',
      component: 'configuration_sync',
      outcome: 'error',
      reason: 'configuration_sync_failed',
    })
  })
})
