import type { Bundle } from './bundle.js'
import {
  verifyBundleEnvelope,
  type TrustedKeyring,
} from './verify.js'

export interface ConfigurationClientOptions {
  readonly baseUrl: string
  readonly trustedKeys: TrustedKeyring
  readonly fetchImpl?: typeof fetch
  readonly now?: () => number
}

export interface ConfigurationSnapshot {
  readonly bundle: Readonly<Bundle>
  readonly etag: string
  readonly loadedAt: number
}

export type RefreshResult =
  | {
      readonly status: 'updated'
      readonly snapshot: ConfigurationSnapshot
    }
  | {
      readonly status: 'unchanged'
      readonly snapshot: ConfigurationSnapshot
    }

export class ConfigurationClientError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ConfigurationClientError'
  }
}

export class ConfigurationClient {
  readonly #bundleUrl: URL
  readonly #trustedKeys: TrustedKeyring
  readonly #fetchImpl: typeof fetch
  readonly #now: () => number

  #snapshot: ConfigurationSnapshot | undefined
  #refreshInFlight: Promise<RefreshResult> | undefined

  constructor(options: ConfigurationClientOptions) {
    let baseUrl: URL

    try {
      baseUrl = new URL(options.baseUrl)
    } catch {
      throw new ConfigurationClientError(
        'control-plane base URL is invalid',
      )
    }

    if (
      baseUrl.protocol !== 'http:' &&
      baseUrl.protocol !== 'https:'
    ) {
      throw new ConfigurationClientError(
        'control-plane base URL must use HTTP or HTTPS',
      )
    }

    this.#bundleUrl = new URL('/v1/bundle', baseUrl)
    this.#trustedKeys = options.trustedKeys
    this.#fetchImpl = options.fetchImpl ?? globalThis.fetch
    this.#now = options.now ?? Date.now
  }

  current(): ConfigurationSnapshot | undefined {
    return this.#snapshot
  }

  requireCurrent(): ConfigurationSnapshot {
    if (this.#snapshot === undefined) {
      throw new ConfigurationClientError(
        'no verified configuration is available',
      )
    }

    return this.#snapshot
  }

  refresh(signal?: AbortSignal): Promise<RefreshResult> {
    if (this.#refreshInFlight !== undefined) {
      return this.#refreshInFlight
    }

    const operation = this.#refreshOnce(signal)
    this.#refreshInFlight = operation

    void operation.then(
      () => {
        if (this.#refreshInFlight === operation) {
          this.#refreshInFlight = undefined
        }
      },
      () => {
        if (this.#refreshInFlight === operation) {
          this.#refreshInFlight = undefined
        }
      },
    )

    return operation
  }

  async #refreshOnce(
    signal?: AbortSignal,
  ): Promise<RefreshResult> {
    const headers = new Headers({
      Accept: 'application/json',
    })

    if (this.#snapshot !== undefined) {
      headers.set('If-None-Match', this.#snapshot.etag)
    }

    let response: Response

    try {
      response = await this.#fetchImpl(this.#bundleUrl, {
        method: 'GET',
        headers,
        cache: 'no-store',
        redirect: 'error',
        ...(signal === undefined ? {} : { signal }),
      })
    } catch (error) {
      throw new ConfigurationClientError(
        `fetch bundle: ${errorMessage(error)}`,
      )
    }

    if (response.status === 304) {
      if (this.#snapshot === undefined) {
        throw new ConfigurationClientError(
          'control plane returned 304 before a bundle was loaded',
        )
      }

      return {
        status: 'unchanged',
        snapshot: this.#snapshot,
      }
    }

    if (!response.ok) {
      throw new ConfigurationClientError(
        `control plane returned HTTP ${response.status}`,
      )
    }

    const contentType = response.headers
      .get('content-type')
      ?.split(';', 1)[0]
      ?.trim()
      .toLowerCase()

    if (contentType !== 'application/json') {
      throw new ConfigurationClientError(
        'control plane returned a non-JSON bundle',
      )
    }

    let body: unknown

    try {
      body = (await response.json()) as unknown
    } catch {
      throw new ConfigurationClientError(
        'control plane returned invalid JSON',
      )
    }

    const verified = await verifyBundleEnvelope(
      body,
      this.#trustedKeys,
    )

    const etag = response.headers.get('etag')

    if (etag === null || etag.trim() === '') {
      throw new ConfigurationClientError(
        'control plane response is missing an ETag',
      )
    }

    const expectedEtag = `"${verified.bundle.version}"`

    if (etag !== expectedEtag) {
      throw new ConfigurationClientError(
        'control-plane ETag does not match the bundle version',
      )
    }

    const snapshot: ConfigurationSnapshot = Object.freeze({
      bundle: deepFreeze(verified.bundle),
      etag,
      loadedAt: this.#now(),
    })

    // A single reference assignment makes the verified configuration
    // visible atomically to new requests. Existing requests retain the
    // previous snapshot until they finish.
    this.#snapshot = snapshot

    return {
      status: 'updated',
      snapshot,
    }
  }
}

function deepFreeze<T>(value: T): T {
  if (typeof value !== 'object' || value === null) {
    return value
  }

  for (const child of Object.values(
    value as Record<string, unknown>,
  )) {
    deepFreeze(child)
  }

  return Object.freeze(value) as T
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message
  }

  return String(error)
}