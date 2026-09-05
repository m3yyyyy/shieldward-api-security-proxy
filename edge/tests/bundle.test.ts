import { describe, expect, it } from 'vitest'

import {
  BundleValidationError,
  parseBundleEnvelope,
} from '../src/bundle.js'

function validEnvelope() {
  return {
    algorithm: 'Ed25519',
    keyId: `sha256:${'a'.repeat(64)}`,
    bundle: {
      schemaVersion: 'shieldward.bundle/v1alpha1',
      policyName: 'orders-api',
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
          upstream: 'http://127.0.0.1:9000',
          jwt: {
            required: true,
            issuer: 'https://identity.example.com',
            audience: ['orders-api'],
            jwksUrl:
              'https://identity.example.com/.well-known/jwks.json',
          },
          rateLimit: {
            requests: 120,
            window: '1m',
            key: 'jwt.sub',
          },
          waf: [
            {
              id: 'path-traversal',
              target: 'path',
              pattern: '(\\.\\./|%2e%2e)',
              flags: 'i',
              action: 'block',
            },
          ],
        },
      ],
      version: `sha256:${'b'.repeat(64)}`,
    },
    signature: 'A'.repeat(86),
  }
}

describe('bundle envelope parser', () => {
  it('accepts a valid signed bundle envelope', () => {
    const envelope = parseBundleEnvelope(validEnvelope())

    expect(envelope.algorithm).toBe('Ed25519')
    expect(envelope.bundle.policyName).toBe('orders-api')
    expect(envelope.bundle.routes).toHaveLength(1)
  })

  it('rejects unsupported envelope fields', () => {
    const envelope = {
      ...validEnvelope(),
      unexpected: true,
    }

    expect(() => parseBundleEnvelope(envelope)).toThrow(
      BundleValidationError,
    )

    expect(() => parseBundleEnvelope(envelope)).toThrow(
      'envelope.unexpected is not supported',
    )
  })

  it('rejects unsupported signature algorithms', () => {
    const envelope = {
      ...validEnvelope(),
      algorithm: 'RS256',
    }

    expect(() => parseBundleEnvelope(envelope)).toThrow(
      'envelope.algorithm must be one of: Ed25519',
    )
  })

  it('rejects insecure JWKS URLs', () => {
    const envelope = validEnvelope()

    envelope.bundle.routes[0]!.jwt.jwksUrl =
      'http://identity.example.com/jwks.json'

    expect(() => parseBundleEnvelope(envelope)).toThrow(
      'envelope.bundle.routes[0].jwt.jwksUrl must use HTTPS',
    )
  })

  it('rejects malformed signatures', () => {
    const envelope = {
      ...validEnvelope(),
      signature: 'not-a-valid-signature',
    }

    expect(() => parseBundleEnvelope(envelope)).toThrow(
      'envelope.signature has an invalid format',
    )
  })
})