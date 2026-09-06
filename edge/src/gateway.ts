import type {
  PolicyDecision,
  PolicyRequest,
} from './policy-engine.js'
import {
  proxyToUpstream,
  type UpstreamFetch,
} from './proxy.js'

const DEFAULT_MAX_REQUEST_BODY_BYTES =
  1024 * 1024

export interface PolicyEvaluator {
  evaluate(
    request: PolicyRequest,
  ): Promise<PolicyDecision>
}

export interface GatewayOptions {
  readonly policyEvaluator: PolicyEvaluator
  readonly fetcher?: UpstreamFetch
  readonly maxRequestBodyBytes?: number
}

interface BufferedBody {
  readonly bytes: ArrayBuffer | undefined
  readonly text: string | undefined
}

export class Gateway {
  readonly #policyEvaluator: PolicyEvaluator
  readonly #fetcher: UpstreamFetch | undefined
  readonly #maxRequestBodyBytes: number

  constructor(options: GatewayOptions) {
    this.#policyEvaluator = options.policyEvaluator
    this.#fetcher = options.fetcher
    this.#maxRequestBodyBytes =
      options.maxRequestBodyBytes ??
      DEFAULT_MAX_REQUEST_BODY_BYTES

    if (
      !Number.isSafeInteger(
        this.#maxRequestBodyBytes,
      ) ||
      this.#maxRequestBodyBytes <= 0
    ) {
      throw new Error(
        'maximum request body size must be a positive integer',
      )
    }
  }

  async handle(
    request: Request,
    clientIp?: string,
  ): Promise<Response> {
    let body: BufferedBody

    try {
      body = await readRequestBody(
        request,
        this.#maxRequestBodyBytes,
      )
    } catch (error) {
      if (error instanceof GatewayRequestError) {
        return errorResponse(
          error.status,
          error.code,
        )
      }

      return errorResponse(
        400,
        'request_body_unreadable',
      )
    }

    let decision: PolicyDecision

    try {
      decision =
        await this.#policyEvaluator.evaluate({
          method: request.method,
          url: new URL(request.url),
          headers: request.headers,
          ...(body.text === undefined
            ? {}
            : {
                body: body.text,
              }),
          ...(clientIp === undefined
            ? {}
            : {
                clientIp,
              }),
        })
    } catch {
      return errorResponse(
        503,
        'policy_evaluation_failed',
      )
    }

    if (!decision.allowed) {
      return deniedResponse(decision)
    }

    if (decision.route === undefined) {
      return errorResponse(
        404,
        'route_not_found',
      )
    }

    try {
      return await proxyToUpstream({
        request,
        route: decision.route,
        body: body.bytes,
        ...(clientIp === undefined
          ? {}
          : {
              clientIp,
            }),
        ...(this.#fetcher === undefined
          ? {}
          : {
              fetcher: this.#fetcher,
            }),
      })
    } catch {
      return errorResponse(
        502,
        'upstream_unavailable',
      )
    }
  }
}

class GatewayRequestError extends Error {
  readonly status: 400 | 413
  readonly code:
    | 'invalid_content_length'
    | 'request_body_too_large'

  constructor(
    status: 400 | 413,
    code:
      | 'invalid_content_length'
      | 'request_body_too_large',
  ) {
    super(code)
    this.name = 'GatewayRequestError'
    this.status = status
    this.code = code
  }
}

async function readRequestBody(
  request: Request,
  maximumBytes: number,
): Promise<BufferedBody> {
  const method = request.method.toUpperCase()

  if (method === 'GET' || method === 'HEAD') {
    return {
      bytes: undefined,
      text: undefined,
    }
  }

  validateDeclaredBodyLength(
    request.headers.get('content-length'),
    maximumBytes,
  )

  if (request.body === null) {
    return {
      bytes: undefined,
      text: undefined,
    }
  }

  const reader = request.body.getReader()
  const chunks: Uint8Array[] = []
  let totalBytes = 0

  try {
    while (true) {
      const result = await reader.read()

      if (result.done) {
        break
      }

      totalBytes += result.value.byteLength

      if (totalBytes > maximumBytes) {
        await reader.cancel().catch(() => undefined)

        throw new GatewayRequestError(
          413,
          'request_body_too_large',
        )
      }

      chunks.push(result.value)
    }
  } finally {
    reader.releaseLock()
  }

  const bytes = new Uint8Array(totalBytes)
  let offset = 0

  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }

  return {
    bytes: bytes.buffer as ArrayBuffer,
    text: new TextDecoder().decode(bytes),
  }
}

function validateDeclaredBodyLength(
  header: string | null,
  maximumBytes: number,
): void {
  if (header === null) {
    return
  }

  const value = header.trim()

  if (!/^\d+$/.test(value)) {
    throw new GatewayRequestError(
      400,
      'invalid_content_length',
    )
  }

  const length = Number(value)

  if (!Number.isSafeInteger(length)) {
    throw new GatewayRequestError(
      400,
      'invalid_content_length',
    )
  }

  if (length > maximumBytes) {
    throw new GatewayRequestError(
      413,
      'request_body_too_large',
    )
  }
}

function deniedResponse(
  decision: Extract<
    PolicyDecision,
    { readonly allowed: false }
  >,
): Response {
  const headers = new Headers()

  if (decision.status === 401) {
    headers.set('www-authenticate', 'Bearer')
  }

  if (
    decision.status === 429 &&
    decision.retryAfterSeconds !== undefined
  ) {
    headers.set(
      'retry-after',
      String(decision.retryAfterSeconds),
    )
  }

  return errorResponse(
    decision.status,
    decision.code,
    headers,
  )
}

function errorResponse(
  status: number,
  code: string,
  additionalHeaders?: HeadersInit,
): Response {
  const headers = new Headers(additionalHeaders)

  headers.set(
    'content-type',
    'application/json; charset=UTF-8',
  )
  headers.set('cache-control', 'no-store')

  return new Response(
    JSON.stringify({
      error: code,
    }),
    {
      status,
      headers,
    },
  )
}