import {
  generateKeyPairSync,
} from 'node:crypto'
import { readFileSync } from 'node:fs'

import { describe, expect, it } from 'vitest'

import {
  calculatePublicKeyId,
  createTrustedKeyring,
  TrustedKeyError,
} from '../src/trusted-keys.js'

const GO_KEY_ID =
  'sha256:3a6b314b1d7a43d763ff9e523e96f9af7de0863c02c75a1f4e486d1591a7841c'

const publicKeyPem = readFileSync(
  new URL(
    './fixtures/go-public.pem',
    import.meta.url,
  ),
  'utf8',
)

describe('trusted public keys', () => {
  it('calculates the same key ID as Go', () => {
    expect(
      calculatePublicKeyId(publicKeyPem),
    ).toBe(GO_KEY_ID)
  })

  it('creates a keyring indexed by key ID', () => {
    const keyring = createTrustedKeyring([
      publicKeyPem,
    ])

    expect(keyring.size).toBe(1)
    expect(keyring.get(GO_KEY_ID)).toBe(
      publicKeyPem,
    )
  })

  it('rejects empty and duplicate key sets', () => {
    expect(() =>
      createTrustedKeyring([]),
    ).toThrow(TrustedKeyError)

    expect(() =>
      createTrustedKeyring([
        publicKeyPem,
        publicKeyPem,
      ]),
    ).toThrow(
      `duplicate trusted public key ${GO_KEY_ID}`,
    )
  })

  it('rejects malformed and non-Ed25519 keys', () => {
    expect(() =>
      calculatePublicKeyId('not a public key'),
    ).toThrow(
      'trusted key must contain one PUBLIC KEY PEM block',
    )

    const { publicKey } = generateKeyPairSync(
      'ec',
      {
        namedCurve: 'prime256v1',
      },
    )

    const ecPublicKeyPem = publicKey
      .export({
        type: 'spki',
        format: 'pem',
      })
      .toString()

    expect(() =>
      calculatePublicKeyId(ecPublicKeyPem),
    ).toThrow(
      'trusted public key must use Ed25519',
    )
  })
})