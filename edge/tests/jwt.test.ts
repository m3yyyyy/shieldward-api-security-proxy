import {
  SignJWT,
  exportJWK,
  generateKeyPair,
  type CryptoKey,
  type FetchImplementation,
  type JWK,
} from 'jose'
import {
  beforeAll,
  describe,
  expect,
  it,
  vi,
} from 'vitest'

import type { JwtPolicy } from '../src/bundle.js'
import {
  JwtAuthenticationError,
  JwtVerifier,
  parseBearerToken,
} from '../src/jwt.js'

const ISSUER = 'https://identity.example.test/'
const AUDIENCE = 'orders-api'
const KEY_ID = 'test-signing-key'

const policy: JwtPolicy = {
  required: true,
  issuer: ISSUER,
  audience: [AUDIENCE],
  jwksUrl:
    'https://identity.example.test/.well-known/jwks.json',
}

let privateKey: CryptoKey
let publicJwk: JWK

beforeAll(async () => {
  const keyPair = await generateKeyPair('RS256')

  privateKey = keyPair.privateKey
  publicJwk = await exportJWK(keyPair.publicKey)
})

async function signToken(options?: {
  readonly issuer?: string
  readonly audience?: string
  readonly includeExpiration?: boolean
}): Promise<string> {
  let token = new SignJWT({
    sub: 'user-123',
  })
    .setProtectedHeader({
      alg: 'RS256',
      kid: KEY_ID,
      typ: 'JWT',
    })
    .setIssuer(options?.issuer ?? ISSUER)
    .setAudience(options?.audience ?? AUDIENCE)
    .setIssuedAt()

  if (options?.includeExpiration !== false) {
    token = token.setExpirationTime('5m')
  }

  return token.sign(privateKey)
}

function createVerifier() {
  const fetchImpl = vi.fn<FetchImplementation>(
    async () =>
      new Response(
        JSON.stringify({
          keys: [
            {
              ...publicJwk,
              kid: KEY_ID,
              alg: 'RS256',
              use: 'sig',
            },
          ],
        }),
        {
          status: 200,
          headers: {
            'content-type': 'application/json',
          },
        },
      ),
  )

  return {
    fetchImpl,
    verifier: new JwtVerifier({
      fetchImpl,
    }),
  }
}

describe('JWT verifier', () => {
  it('parses Bearer authorization headers', () => {
    expect(
      parseBearerToken('Bearer aaa.bbb.ccc'),
    ).toBe('aaa.bbb.ccc')

    expect(
      parseBearerToken('bearer   aaa.bbb.ccc'),
    ).toBe('aaa.bbb.ccc')

    expect(() =>
      parseBearerToken(null),
    ).toThrow('authorization header is required')

    expect(() =>
      parseBearerToken('Basic credentials'),
    ).toThrow(
      'authorization header must contain a Bearer token',
    )

    expect(() =>
      parseBearerToken('Bearer invalid'),
    ).toThrow('Bearer token has an invalid format')
  })

  it('verifies a signed token and returns its subject', async () => {
    const { fetchImpl, verifier } = createVerifier()
    const token = await signToken()

    const result =
      await verifier.verifyAuthorization(
        `Bearer ${token}`,
        policy,
      )

    expect(result.subject).toBe('user-123')
    expect(result.payload.iss).toBe(ISSUER)
    expect(result.payload.aud).toBe(AUDIENCE)
    expect(result.protectedHeader.alg).toBe('RS256')
    expect(fetchImpl).toHaveBeenCalledTimes(1)
  })

  it('reuses its cached remote JWKS', async () => {
    const { fetchImpl, verifier } = createVerifier()
    const token = await signToken()

    await verifier.verifyAuthorization(
      `Bearer ${token}`,
      policy,
    )

    await verifier.verifyAuthorization(
      `Bearer ${token}`,
      policy,
    )

    expect(fetchImpl).toHaveBeenCalledTimes(1)
  })

  it('rejects invalid claims and signatures', async () => {
    const { verifier } = createVerifier()

    const wrongAudience = await signToken({
      audience: 'different-api',
    })

    await expect(
      verifier.verifyAuthorization(
        `Bearer ${wrongAudience}`,
        policy,
      ),
    ).rejects.toThrow(JwtAuthenticationError)

    const missingExpiration = await signToken({
      includeExpiration: false,
    })

    await expect(
      verifier.verifyAuthorization(
        `Bearer ${missingExpiration}`,
        policy,
      ),
    ).rejects.toThrow('JWT verification failed')

    const validToken = await signToken()
    const parts = validToken.split('.')
    const signature = parts[2]!

    parts[2] =
      signature.at(-1) === 'A'
        ? `${signature.slice(0, -1)}B`
        : `${signature.slice(0, -1)}A`

    await expect(
      verifier.verifyAuthorization(
        `Bearer ${parts.join('.')}`,
        policy,
      ),
    ).rejects.toThrow('JWT verification failed')
  })
})