import { describe, expect, it, vi } from 'vitest'

import type { CompiledRoute } from '../src/bundle.js'
import {
  buildUpstreamUrl,
  proxyToUpstream,
  type UpstreamFetch,
} from '../src/proxy.js'

const route: CompiledRoute = {
  id: 'orders-write',
  match: {
    methods: ['POST'],
    path: '/v1/orders/:id',
  },
  upstream: 'http://127.0.0.1:9000/internal',
}

function encodeBody(value: string): ArrayBuffer {
  return new TextEncoder().encode(value)
    .buffer as ArrayBuffer
}

describe('upstream proxy', () => {
  it('combines the upstream path with the request path', () => {
    const result = buildUpstreamUrl(
      'https://api.internal/base/',
      new URL(
        'https://edge.example/v1/orders/42?expand=true',
      ),
    )

    expect(result.href).toBe(
      'https://api.internal/base/v1/orders/42?expand=true',
    )
  })

  it('forwards trusted request data to the upstream', async () => {
    const fetcher = vi.fn<UpstreamFetch>(
      async (request) => {
        expect(request.url).toBe(
          'http://127.0.0.1:9000/internal/v1/orders/42?expand=true',
        )
        expect(request.method).toBe('POST')
        expect(await request.text()).toBe('hello')

        expect(
          request.headers.get('authorization'),
        ).toBe('Bearer token')

        expect(
          request.headers.get('x-forwarded-host'),
        ).toBe('edge.example')

        expect(
          request.headers.get('x-forwarded-proto'),
        ).toBe('https')

        expect(
          request.headers.get('x-forwarded-for'),
        ).toBe('203.0.113.10')

        expect(
          request.headers.get('x-real-ip'),
        ).toBe('203.0.113.10')

        expect(
          request.headers.get('x-request-id'),
        ).toBe('trusted-request-id')

        expect(
          request.headers.get('connection'),
        ).toBeNull()

        expect(
          request.headers.get('x-remove'),
        ).toBeNull()

        expect(
          request.headers.get('keep-alive'),
        ).toBeNull()

        expect(
          request.headers.get('host'),
        ).toBeNull()

        return new Response('created', {
          status: 201,
        })
      },
    )

    const request = new Request(
      'https://edge.example/v1/orders/42?expand=true',
      {
        method: 'POST',
        headers: {
          authorization: 'Bearer token',
          connection: 'x-remove',
          'x-remove': 'secret',
          'keep-alive': 'timeout=5',
          'x-forwarded-for': 'spoofed',
          'x-forwarded-host': 'spoofed.example',
          'x-forwarded-proto': 'http',
          'x-real-ip': 'spoofed',
          'x-request-id': 'spoofed-request-id',
        },
        body: 'original',
      },
    )

    const response = await proxyToUpstream({
      request,
      route,
      body: encodeBody('hello'),
      clientIp: '203.0.113.10',
      requestId: 'trusted-request-id',
      fetcher,
    })

    expect(fetcher).toHaveBeenCalledOnce()
    expect(response.status).toBe(201)
    expect(await response.text()).toBe('created')
  })

  it('removes unsafe upstream response headers', async () => {
    const fetcher: UpstreamFetch = async () =>
      new Response('ok', {
        headers: {
          connection: 'x-response-only',
          'x-response-only': 'secret',
          'keep-alive': 'timeout=5',
          'content-encoding': 'gzip',
          'content-length': '2',
          'x-upstream': 'preserved',
        },
      })

    const response = await proxyToUpstream({
      request: new Request(
        'https://edge.example/v1/orders/42',
      ),
      route,
      body: undefined,
      fetcher,
    })

    expect(response.headers.get('connection')).toBeNull()
    expect(
      response.headers.get('x-response-only'),
    ).toBeNull()
    expect(response.headers.get('keep-alive')).toBeNull()
    expect(
      response.headers.get('content-encoding'),
    ).toBeNull()
    expect(
      response.headers.get('content-length'),
    ).toBeNull()
    expect(response.headers.get('x-upstream')).toBe(
      'preserved',
    )
  })

  it('rejects unsafe upstream URLs', () => {
    const incomingUrl = new URL(
      'https://edge.example/v1/orders/42',
    )

    expect(() =>
      buildUpstreamUrl('file:///tmp/data', incomingUrl),
    ).toThrow('upstream must use HTTP or HTTPS')

    expect(() =>
      buildUpstreamUrl(
        'https://user:password@api.internal',
        incomingUrl,
      ),
    ).toThrow('upstream must not contain credentials')

    expect(() =>
      buildUpstreamUrl(
        'http://api.internal',
        incomingUrl,
      ),
    ).toThrow(
      'upstream must use HTTPS unless it targets loopback',
    )
  })
})
