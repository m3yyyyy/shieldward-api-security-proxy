import {
  createHash,
  createPublicKey,
} from 'node:crypto'

import type { TrustedKeyring } from './verify.js'

const ED25519_PUBLIC_KEY_BYTES = 32

export class TrustedKeyError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'TrustedKeyError'
  }
}

export function createTrustedKeyring(
  publicKeyPems: readonly string[],
): TrustedKeyring {
  if (publicKeyPems.length === 0) {
    throw new TrustedKeyError(
      'at least one trusted public key is required',
    )
  }

  const keyring = new Map<string, string>()

  for (const publicKeyPem of publicKeyPems) {
    const keyId =
      calculatePublicKeyId(publicKeyPem)

    if (keyring.has(keyId)) {
      throw new TrustedKeyError(
        `duplicate trusted public key ${keyId}`,
      )
    }

    keyring.set(keyId, publicKeyPem)
  }

  return keyring
}

export function calculatePublicKeyId(
  publicKeyPem: string,
): string {
  if (
    !/^-----BEGIN PUBLIC KEY-----[\s\S]+-----END PUBLIC KEY-----$/.test(
      publicKeyPem.trim(),
    )
  ) {
    throw new TrustedKeyError(
      'trusted key must contain one PUBLIC KEY PEM block',
    )
  }

  try {
    const publicKey = createPublicKey(
      publicKeyPem,
    )

    if (
      publicKey.asymmetricKeyType !== 'ed25519'
    ) {
      throw new TrustedKeyError(
        'trusted public key must use Ed25519',
      )
    }

    const jwk = publicKey.export({
      format: 'jwk',
    })

    if (typeof jwk.x !== 'string') {
      throw new TrustedKeyError(
        'trusted Ed25519 public key has no public value',
      )
    }

    const rawPublicKey = Buffer.from(
      jwk.x,
      'base64url',
    )

    if (
      rawPublicKey.byteLength !==
      ED25519_PUBLIC_KEY_BYTES
    ) {
      throw new TrustedKeyError(
        `trusted Ed25519 public key must contain ${ED25519_PUBLIC_KEY_BYTES} bytes`,
      )
    }

    const digest = createHash('sha256')
      .update(rawPublicKey)
      .digest('hex')

    return `sha256:${digest}`
  } catch (error) {
    if (error instanceof TrustedKeyError) {
      throw error
    }

    throw new TrustedKeyError(
      'trusted public key is invalid',
    )
  }
}