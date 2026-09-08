import type { CompiledRoute } from './bundle.js'
import { usesSecureTransport } from './transport.js'

const HOP_BY_HOP_HEADERS = [
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
] as const

const HEADER_NAME_PATTERN =
  /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/

const DEFAULT_UPSTREAM_TIMEOUT_MS = 10_000

export type UpstreamFetch = (
  request: Request,
) => Promise<Response>

export interface UpstreamProxyRequest {
  readonly request: Request
  readonly route: Readonly<CompiledRoute>
  readonly body: ArrayBuffer | undefined
  readonly clientIp?: string
  readonly requestId?: string
  readonly fetcher?: UpstreamFetch
  readonly timeoutMs?: number
}

export class UpstreamTimeoutError extends Error {
  constructor() {
    super('upstream request timed out')
    this.name = 'UpstreamTimeoutError'
  }
}

export async function proxyToUpstream(
  input: UpstreamProxyRequest,
): Promise<Response> {
  const incomingUrl = new URL(input.request.url)
  const targetUrl = buildUpstreamUrl(
    input.route.upstream,
    incomingUrl,
  )

  const headers = createUpstreamHeaders(
    input.request.headers,
    incomingUrl,
    input.clientIp,
    input.requestId,
  )
  const timeoutMs =
    input.timeoutMs ?? DEFAULT_UPSTREAM_TIMEOUT_MS

  if (
    !Number.isSafeInteger(timeoutMs) ||
    timeoutMs <= 0
  ) {
    throw new Error(
      'upstream timeout must be a positive integer',
    )
  }

  const timeoutSignal = AbortSignal.timeout(timeoutMs)
  const signal = AbortSignal.any([
    input.request.signal,
    timeoutSignal,
  ])

  const requestInit: RequestInit = {
    method: input.request.method,
    headers,
    redirect: 'manual',
    signal,
  }

  if (
    input.body !== undefined &&
    input.request.method !== 'GET' &&
    input.request.method !== 'HEAD'
  ) {
    requestInit.body = input.body
  }

  const upstreamRequest = new Request(
    targetUrl,
    requestInit,
  )

  const fetcher = input.fetcher ?? globalThis.fetch
  let upstreamResponse: Response

  try {
    upstreamResponse = await fetcher(upstreamRequest)
  } catch (error) {
    if (
      timeoutSignal.aborted &&
      !input.request.signal.aborted
    ) {
      throw new UpstreamTimeoutError()
    }

    throw error
  }

  return createClientResponse(upstreamResponse)
}

export function buildUpstreamUrl(
  upstream: string,
  incomingUrl: URL,
): URL {
  const targetUrl = new URL(upstream)

  if (
    targetUrl.protocol !== 'http:' &&
    targetUrl.protocol !== 'https:'
  ) {
    throw new Error(
      'upstream must use HTTP or HTTPS',
    )
  }

  if (
    targetUrl.username !== '' ||
    targetUrl.password !== ''
  ) {
    throw new Error(
      'upstream must not contain credentials',
    )
  }

  if (!usesSecureTransport(targetUrl)) {
    throw new Error(
      'upstream must use HTTPS unless it targets loopback',
    )
  }

  const upstreamPath =
    targetUrl.pathname === '/'
      ? ''
      : targetUrl.pathname.replace(/\/+$/, '')

  targetUrl.pathname =
    `${upstreamPath}${incomingUrl.pathname}` || '/'
  targetUrl.search = incomingUrl.search
  targetUrl.hash = ''

  return targetUrl
}

function createUpstreamHeaders(
  source: Headers,
  incomingUrl: URL,
  clientIp: string | undefined,
  requestId: string | undefined,
): Headers {
  const headers = sanitizeHeaders(source)

  headers.delete('host')
  headers.delete('content-length')
  headers.delete('accept-encoding')
  headers.delete('forwarded')
  headers.delete('x-forwarded-for')
  headers.delete('x-forwarded-host')
  headers.delete('x-forwarded-proto')
  headers.delete('x-real-ip')
  headers.delete('x-request-id')

  headers.set('x-forwarded-host', incomingUrl.host)
  headers.set(
    'x-forwarded-proto',
    incomingUrl.protocol.slice(0, -1),
  )

  if (
    clientIp !== undefined &&
    clientIp.trim() !== ''
  ) {
    headers.set('x-forwarded-for', clientIp)
    headers.set('x-real-ip', clientIp)
  }

  if (requestId !== undefined) {
    headers.set('x-request-id', requestId)
  }

  return headers
}

function createClientResponse(
  upstreamResponse: Response,
): Response {
  const headers = sanitizeHeaders(
    upstreamResponse.headers,
  )

  if (headers.has('content-encoding')) {
    headers.delete('content-encoding')
    headers.delete('content-length')
  }

  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    statusText: upstreamResponse.statusText,
    headers,
  })
}

function sanitizeHeaders(source: Headers): Headers {
  const headers = new Headers(source)
  const connection = headers.get('connection')

  if (connection !== null) {
    for (const value of connection.split(',')) {
      const name = value.trim()

      if (HEADER_NAME_PATTERN.test(name)) {
        headers.delete(name)
      }
    }
  }

  for (const name of HOP_BY_HOP_HEADERS) {
    headers.delete(name)
  }

  return headers
}
