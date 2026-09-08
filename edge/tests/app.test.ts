import { describe, expect, it, vi } from 'vitest'

import {
  app,
  createApp,
  type GatewayHandler,
} from '../src/app.js'
import type { ConfigurationSnapshot } from '../src/config-client.js'
import { PrometheusMetrics } from '../src/metrics.js'

const POLICY_VERSION =
  `sha256:${'a'.repeat(64)}`

function createSnapshot(): ConfigurationSnapshot {
  return {
    bundle: {
      version: POLICY_VERSION,
    },
    etag: `"${POLICY_VERSION}"`,
    loadedAt: 1234,
  } as unknown as ConfigurationSnapshot
}

describe('ShieldWard edge application', () => {
  it('reports a healthy service', async () => {
    const response = await app.request('/healthz')

    expect(response.status).toBe(200)

    await expect(response.json()).resolves.toEqual({
      service: 'shieldward-edge',
      status: 'ok',
    })
    expect(
      response.headers.get('x-content-type-options'),
    ).toBe('nosniff')
    expect(
      response.headers.get('referrer-policy'),
    ).toBe('no-referrer')
    expect(
      response.headers.get('strict-transport-security'),
    ).toBeNull()
  })

  it('adds HSTS only on a TLS listener', async () => {
    const application = createApp({
      secureTransport: true,
    })

    const response =
      await application.request('/healthz')

    expect(
      response.headers.get('strict-transport-security'),
    ).toBe('max-age=31536000')
  })

  it('reports not ready without verified configuration', async () => {
    const response = await app.request('/readyz')

    expect(response.status).toBe(503)
    expect(
      response.headers.get('cache-control'),
    ).toBe('no-store')

    await expect(response.json()).resolves.toEqual({
      service: 'shieldward-edge',
      status: 'not_ready',
    })
  })

  it('reports the active verified policy version', async () => {
    const application = createApp({
      configuration: {
        current: () => createSnapshot(),
      },
    })

    const response =
      await application.request('/readyz')

    expect(response.status).toBe(200)

    await expect(response.json()).resolves.toEqual({
      service: 'shieldward-edge',
      status: 'ready',
      policyVersion: POLICY_VERSION,
    })
  })

  it('fails readiness when the configured rate limiter is unavailable', async () => {
    const application = createApp({
      configuration: {
        current: () => createSnapshot(),
      },
      rateLimiter: {
        ready: () => false,
      },
    })

    const response =
      await application.request('/readyz')

    expect(response.status).toBe(503)
    await expect(response.json()).resolves.toEqual({
      service: 'shieldward-edge',
      status: 'not_ready',
    })
  })

  it('serves privacy-safe metrics only to loopback clients', async () => {
    const metrics = new PrometheusMetrics({
      now: () => 2_000,
    })
    const configuration = {
      current: () => createSnapshot(),
    }

    const localApplication = createApp({
      configuration,
      metrics,
      resolveClientIp: () => '::ffff:127.0.0.1',
    })

    const localResponse =
      await localApplication.request('/metrics')

    expect(localResponse.status).toBe(200)
    expect(
      localResponse.headers.get('content-type'),
    ).toBe(
      'text/plain; version=0.0.4; charset=utf-8',
    )
    expect(
      localResponse.headers.get('cache-control'),
    ).toBe('no-store')
    expect(await localResponse.text()).toContain(
      'shieldward_edge_ready 1',
    )

    const remoteApplication = createApp({
      configuration,
      metrics,
      resolveClientIp: () => '203.0.113.10',
    })

    const remoteResponse =
      await remoteApplication.request('/metrics')

    expect(remoteResponse.status).toBe(404)
    await expect(remoteResponse.json()).resolves.toEqual({
      error: 'route_not_found',
    })
  })

  it('returns a structured response without a gateway', async () => {
    const response =
      await app.request('/unknown')

    expect(response.status).toBe(404)

    await expect(response.json()).resolves.toEqual({
      error: 'route_not_found',
    })
  })

  it('passes application requests to the gateway', async () => {
    const handle = vi.fn<
      GatewayHandler['handle']
    >(async (request, clientIp) => {
      expect(request.url).toBe(
        'http://localhost/v1/orders/42',
      )
      expect(request.method).toBe('POST')
      expect(clientIp).toBe('203.0.113.10')

      return new Response('proxied', {
        status: 201,
      })
    })

    const application = createApp({
      gateway: {
        handle,
      },
      resolveClientIp: () => '203.0.113.10',
    })

    const response = await application.request(
      '/v1/orders/42',
      {
        method: 'POST',
        body: 'hello',
      },
    )

    expect(handle).toHaveBeenCalledOnce()
    expect(response.status).toBe(201)
    expect(await response.text()).toBe('proxied')
  })

  it('returns a structured internal error', async () => {
    const application = createApp({
      gateway: {
        handle: async () => {
          throw new Error('unexpected failure')
        },
      },
    })

    const response =
      await application.request('/v1/orders/42')

    expect(response.status).toBe(500)
    expect(
      response.headers.get('cache-control'),
    ).toBe('no-store')

    await expect(response.json()).resolves.toEqual({
      error: 'internal_server_error',
    })
  })
})
