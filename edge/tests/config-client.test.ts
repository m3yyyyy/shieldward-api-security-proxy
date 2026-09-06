import { readFileSync } from 'node:fs'

import { describe, expect, it } from 'vitest'

import {
  ConfigurationClient,
  ConfigurationClientError,
} from '../src/config-client.js'

const GO_KEY_ID =
  'sha256:3a6b314b1d7a43d763ff9e523e96f9af7de0863c02c75a1f4e486d1591a7841c'

const GO_BUNDLE_VERSION =
  'sha256:2a5975650cb5bb4f56929e5f47b3d5be6f912c9b1fe001cac52d7d0f8b603b42'

const GO_ETAG = `"${GO_BUNDLE_VERSION}"`

const envelopeText = readFileSync(
  new URL(
    './fixtures/go-signed-envelope.json',
    import.meta.url,
  ),
  'utf8',
)

const publicKeyPem = readFileSync(
  new URL('./fixtures/go-public.pem', import.meta.url),
  'utf8',
)

const trustedKeys = new Map([
  [GO_KEY_ID, publicKeyPem],
])

function readEnvelope(): unknown {
  return JSON.parse(envelopeText) as unknown
}

function createBundleResponse(
  body: unknown = readEnvelope(),
): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: {
      'content-type': 'application/json',
      etag: GO_ETAG,
    },
  })
}

function createTamperedEnvelope(): unknown {
  const envelope = JSON.parse(envelopeText) as {
    bundle: {
      routes: Array<{
        upstream: string
      }>
    }
  }

  envelope.bundle.routes[0]!.upstream =
    'https://attacker.example.com'

  return envelope
}

describe('configuration client', () => {
  it('loads and atomically publishes a verified bundle', async () => {
    let capturedRequest: Request | undefined

    const client = new ConfigurationClient({
      baseUrl: 'http://control-plane.test:18080',
      trustedKeys,
      now: () => 1234,
      fetchImpl: async (input, init) => {
        capturedRequest = new Request(input, init)
        return createBundleResponse()
      },
    })

    expect(client.current()).toBeUndefined()
    expect(() => client.requireCurrent()).toThrow(
      ConfigurationClientError,
    )

    const result = await client.refresh()

    expect(result.status).toBe('updated')
    expect(result.snapshot.loadedAt).toBe(1234)
    expect(result.snapshot.etag).toBe(GO_ETAG)
    expect(result.snapshot.bundle.version).toBe(
      GO_BUNDLE_VERSION,
    )
    expect(client.requireCurrent()).toBe(result.snapshot)

    expect(capturedRequest?.url).toBe(
      'http://control-plane.test:18080/v1/bundle',
    )
    expect(
      capturedRequest?.headers.get('if-none-match'),
    ).toBeNull()
  })

  it('uses the ETag and preserves its snapshot after 304', async () => {
    const ifNoneMatchValues: Array<string | null> = []
    let requestCount = 0

    const client = new ConfigurationClient({
      baseUrl: 'http://control-plane.test:18080',
      trustedKeys,
      fetchImpl: async (input, init) => {
        const request = new Request(input, init)

        ifNoneMatchValues.push(
          request.headers.get('if-none-match'),
        )

        requestCount += 1

        if (requestCount === 1) {
          return createBundleResponse()
        }

        return new Response(null, {
          status: 304,
        })
      },
    })

    await client.refresh()
    const originalSnapshot = client.requireCurrent()

    const result = await client.refresh()

    expect(result.status).toBe('unchanged')
    expect(result.snapshot).toBe(originalSnapshot)
    expect(client.requireCurrent()).toBe(originalSnapshot)
    expect(ifNoneMatchValues).toEqual([null, GO_ETAG])
  })

  it('keeps the last good bundle when an update fails verification', async () => {
    let requestCount = 0

    const client = new ConfigurationClient({
      baseUrl: 'http://control-plane.test:18080',
      trustedKeys,
      fetchImpl: async () => {
        requestCount += 1

        if (requestCount === 1) {
          return createBundleResponse()
        }

        return createBundleResponse(
          createTamperedEnvelope(),
        )
      },
    })

    await client.refresh()
    const originalSnapshot = client.requireCurrent()

    await expect(client.refresh()).rejects.toThrow(
      'bundle signature verification failed',
    )

    expect(client.requireCurrent()).toBe(originalSnapshot)
    expect(
      client.requireCurrent().bundle.version,
    ).toBe(GO_BUNDLE_VERSION)
  })
})