import canonicalize from 'canonicalize'

import {
  parseBundleEnvelope,
  type Bundle,
  type SignedBundleEnvelope,
} from './bundle.js'

const ED25519_SIGNATURE_BYTES = 64

export type TrustedKeyring = ReadonlyMap<string, string>

export class BundleVerificationError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'BundleVerificationError'
  }
}

export async function verifyBundleEnvelope(
  value: unknown,
  trustedKeys: TrustedKeyring,
): Promise<SignedBundleEnvelope> {
  const envelope = parseBundleEnvelope(value)

  const publicKeyPem = trustedKeys.get(envelope.keyId)
  if (publicKeyPem === undefined) {
    throw new BundleVerificationError(
      `unknown signing key ${envelope.keyId}`,
    )
  }

  const publicKey = await importTrustedPublicKey(
    publicKeyPem,
    envelope.keyId,
  )

  const signature = decodeBase64Url(envelope.signature)

  if (signature.byteLength !== ED25519_SIGNATURE_BYTES) {
    throw new BundleVerificationError(
      `signature must contain ${ED25519_SIGNATURE_BYTES} bytes`,
    )
  }

  const canonicalBundle = canonicalBytes(envelope.bundle)

  let signatureValid: boolean

  try {
    signatureValid = await crypto.subtle.verify(
      {
        name: 'Ed25519',
      },
      publicKey,
      signature,
      canonicalBundle,
    )
  } catch {
    throw new BundleVerificationError(
      'Ed25519 signature verification could not be completed',
    )
  }

  if (!signatureValid) {
    throw new BundleVerificationError(
      'bundle signature verification failed',
    )
  }

  await verifyBundleVersion(envelope.bundle)

  return envelope
}

async function importTrustedPublicKey(
  pem: string,
  expectedKeyId: string,
): Promise<CryptoKey> {
  const spki = decodePublicKeyPem(pem)

  let publicKey: CryptoKey

  try {
    publicKey = await crypto.subtle.importKey(
      'spki',
      spki,
      {
        name: 'Ed25519',
      },
      true,
      ['verify'],
    )
  } catch {
    throw new BundleVerificationError(
      'trusted public key is not a valid Ed25519 SPKI key',
    )
  }

  let rawPublicKey: ArrayBuffer

  try {
    rawPublicKey = await crypto.subtle.exportKey(
      'raw',
      publicKey,
    )
  } catch {
    throw new BundleVerificationError(
      'trusted Ed25519 public key could not be exported',
    )
  }

  const digest = await crypto.subtle.digest(
    'SHA-256',
    rawPublicKey,
  )

  const actualKeyId = `sha256:${bytesToHex(
    new Uint8Array(digest),
  )}`

  if (!constantTimeEqual(actualKeyId, expectedKeyId)) {
    throw new BundleVerificationError(
      'trusted public key does not match the envelope key ID',
    )
  }

  return publicKey
}

async function verifyBundleVersion(
  bundle: Bundle,
): Promise<void> {
  const {
    version: actualVersion,
    ...unversionedBundle
  } = bundle

  const canonicalBundle = canonicalBytes(unversionedBundle)
  const digest = await crypto.subtle.digest(
    'SHA-256',
    canonicalBundle,
  )

  const expectedVersion = `sha256:${bytesToHex(
    new Uint8Array(digest),
  )}`

  if (!constantTimeEqual(actualVersion, expectedVersion)) {
    throw new BundleVerificationError(
      'bundle version does not match its content',
    )
  }
}

function canonicalBytes(
  value: unknown,
): Uint8Array<ArrayBuffer> {
  const serialized = canonicalize(value)

  if (serialized === undefined) {
    throw new BundleVerificationError(
      'bundle could not be canonicalized',
    )
  }

  return new TextEncoder().encode(serialized)
}

function decodePublicKeyPem(
  pem: string,
): Uint8Array<ArrayBuffer> {
  const match =
    /^-----BEGIN PUBLIC KEY-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END PUBLIC KEY-----$/.exec(
      pem.trim(),
    )

  if (match === null || match[1] === undefined) {
    throw new BundleVerificationError(
      'trusted public key must use PUBLIC KEY PEM format',
    )
  }

  return decodeBase64(match[1].replace(/\s/g, ''))
}

function decodeBase64Url(
  value: string,
): Uint8Array<ArrayBuffer> {
  const base64 = value
    .replace(/-/g, '+')
    .replace(/_/g, '/')
    .padEnd(Math.ceil(value.length / 4) * 4, '=')

  return decodeBase64(base64)
}

function decodeBase64(
  value: string,
): Uint8Array<ArrayBuffer> {
  let decoded: string

  try {
    decoded = atob(value)
  } catch {
    throw new BundleVerificationError(
      'value is not valid base64 data',
    )
  }

  const bytes = new Uint8Array(decoded.length)

  for (let index = 0; index < decoded.length; index += 1) {
    bytes[index] = decoded.charCodeAt(index)
  }

  return bytes
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) =>
    byte.toString(16).padStart(2, '0'),
  ).join('')
}

function constantTimeEqual(
  left: string,
  right: string,
): boolean {
  const leftBytes = new TextEncoder().encode(left)
  const rightBytes = new TextEncoder().encode(right)

  if (leftBytes.length !== rightBytes.length) {
    return false
  }

  let difference = 0

  for (
    let index = 0;
    index < leftBytes.length;
    index += 1
  ) {
    difference |= leftBytes[index]! ^ rightBytes[index]!
  }

  return difference === 0
}