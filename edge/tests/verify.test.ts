import { readFileSync } from 'node:fs'

import { describe, expect, it } from 'vitest'

import {
  BundleVerificationError,
  verifyBundleEnvelope,
} from '../src/verify.js'

const GO_KEY_ID =
  'sha256:3a6b314b1d7a43d763ff9e523e96f9af7de0863c02c75a1f4e486d1591a7841c'

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

describe('Go and TypeScript bundle verification', () => {
  it('verifies a bundle signed by the Go control plane', async () => {
    const verified = await verifyBundleEnvelope(
      readEnvelope(),
      trustedKeys,
    )

    expect(verified.keyId).toBe(GO_KEY_ID)
    expect(verified.bundle.policyName).toBe('orders-api')
    expect(
      verified.bundle.routes[0]?.rateLimit?.requests,
    ).toBe(120)
  })

  it('rejects a bundle modified after signing', async () => {
    const tampered = readEnvelope() as {
      bundle: {
        routes: Array<{
          upstream: string
        }>
      }
    }

    tampered.bundle.routes[0]!.upstream =
      'https://attacker.example.com'

    await expect(
      verifyBundleEnvelope(tampered, trustedKeys),
    ).rejects.toThrow('bundle signature verification failed')
  })

  it('rejects an untrusted signing key', async () => {
    await expect(
      verifyBundleEnvelope(readEnvelope(), new Map()),
    ).rejects.toThrow(BundleVerificationError)

    await expect(
      verifyBundleEnvelope(readEnvelope(), new Map()),
    ).rejects.toThrow(`unknown signing key ${GO_KEY_ID}`)
  })
})