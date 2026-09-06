import {
  createRemoteJWKSet,
  customFetch,
  jwtVerify,
  type FetchImplementation,
  type JWSAlgorithm,
  type JWTPayload,
  type JWTHeaderParameters,
  type RemoteJWKSet,
  type RemoteJWKSetOptions,
} from 'jose'

import type { JwtPolicy } from './bundle.js'

const MAX_TOKEN_LENGTH = 16_384

const SUPPORTED_JWT_ALGORITHMS:
  readonly JWSAlgorithm[] = [
    'RS256',
    'PS256',
    'ES256',
    'EdDSA',
  ]

export interface JwtVerifierOptions {
  readonly fetchImpl?: FetchImplementation
  readonly timeoutDurationMs?: number
  readonly clockToleranceSeconds?: number
}

export interface VerifiedJwt {
  readonly subject: string | undefined
  readonly payload: Readonly<JWTPayload>
  readonly protectedHeader:
    Readonly<JWTHeaderParameters>
}

export class JwtAuthenticationError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'JwtAuthenticationError'
  }
}

export class JwtVerifier {
  readonly #fetchImpl:
    | FetchImplementation
    | undefined

  readonly #timeoutDurationMs: number
  readonly #clockToleranceSeconds: number
  readonly #resolvers = new Map<
    string,
    RemoteJWKSet
  >()

  constructor(options: JwtVerifierOptions = {}) {
    this.#fetchImpl = options.fetchImpl
    this.#timeoutDurationMs =
      options.timeoutDurationMs ?? 5_000
    this.#clockToleranceSeconds =
      options.clockToleranceSeconds ?? 5

    if (
      !Number.isSafeInteger(
        this.#timeoutDurationMs,
      ) ||
      this.#timeoutDurationMs <= 0
    ) {
      throw new JwtAuthenticationError(
        'JWKS timeout must be a positive integer',
      )
    }

    if (
      !Number.isFinite(
        this.#clockToleranceSeconds,
      ) ||
      this.#clockToleranceSeconds < 0
    ) {
      throw new JwtAuthenticationError(
        'clock tolerance must be non-negative',
      )
    }
  }

  async verifyAuthorization(
    authorization: string | null,
    policy: Readonly<JwtPolicy>,
  ): Promise<VerifiedJwt> {
    const token = parseBearerToken(authorization)
    const resolver = this.#resolverFor(policy.jwksUrl)

    try {
      const result = await jwtVerify(
        token,
        resolver,
        {
          algorithms: [
            ...SUPPORTED_JWT_ALGORITHMS,
          ],
          issuer: policy.issuer,
          audience: policy.audience,
          requiredClaims: ['exp'],
          clockTolerance:
            this.#clockToleranceSeconds,
        },
      )

      return {
        subject: result.payload.sub,
        payload: result.payload,
        protectedHeader:
          result.protectedHeader,
      }
    } catch {
      throw new JwtAuthenticationError(
        'JWT verification failed',
      )
    }
  }

  #resolverFor(jwksUrl: string): RemoteJWKSet {
    const existing =
      this.#resolvers.get(jwksUrl)

    if (existing !== undefined) {
      return existing
    }

    const options: RemoteJWKSetOptions = {
      timeoutDuration:
        this.#timeoutDurationMs,
      cooldownDuration: 30_000,
      cacheMaxAge: 600_000,
    }

    if (this.#fetchImpl !== undefined) {
      options[customFetch] = this.#fetchImpl
    }

    const resolver = createRemoteJWKSet(
      new URL(jwksUrl),
      options,
    )

    this.#resolvers.set(jwksUrl, resolver)

    return resolver
  }
}

export function parseBearerToken(
  authorization: string | null,
): string {
  if (authorization === null) {
    throw new JwtAuthenticationError(
      'authorization header is required',
    )
  }

  const match = /^Bearer[ \t]+([^\s]+)$/i.exec(
    authorization.trim(),
  )

  if (match === null || match[1] === undefined) {
    throw new JwtAuthenticationError(
      'authorization header must contain a Bearer token',
    )
  }

  const token = match[1]

  if (
    token.length > MAX_TOKEN_LENGTH ||
    token.split('.').length !== 3
  ) {
    throw new JwtAuthenticationError(
      'Bearer token has an invalid format',
    )
  }

  return token
}