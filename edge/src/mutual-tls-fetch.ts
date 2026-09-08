import type { IncomingHttpHeaders } from 'node:http'
import {
  request as httpsRequest,
  type RequestOptions,
} from 'node:https'
import { Readable } from 'node:stream'

import type { MutualTlsMaterial } from './tls.js'

export type MutualTlsMaterialProvider = () =>
  Readonly<MutualTlsMaterial>

export type HttpsRequester = typeof httpsRequest

export function createMutualTlsFetch(
  materialProvider: MutualTlsMaterialProvider,
  requester: HttpsRequester = httpsRequest,
): typeof fetch {
  return async (
    input: URL | RequestInfo,
    init?: RequestInit,
  ): Promise<Response> => {
    const request = new Request(input, init)
    const target = new URL(request.url)

    if (target.protocol !== 'https:') {
      throw new TypeError(
        'mutual TLS fetch requires an HTTPS URL',
      )
    }

    if (
      request.method !== 'GET' &&
      request.method !== 'HEAD'
    ) {
      throw new TypeError(
        'mutual TLS fetch supports only GET and HEAD requests',
      )
    }

    if (request.body !== null) {
      throw new TypeError(
        'mutual TLS fetch does not accept request bodies',
      )
    }

    const material = materialProvider()
    const options: RequestOptions = {
      method: request.method,
      headers: Object.fromEntries(
        request.headers.entries(),
      ),
      ca: material.certificateAuthority,
      cert: material.certificate,
      key: material.privateKey,
      minVersion: 'TLSv1.2',
      rejectUnauthorized: true,
      agent: false,
      signal: request.signal,
    }

    return new Promise<Response>((resolve, reject) => {
      const outgoing = requester(
        target,
        options,
        (incoming) => {
          const status = incoming.statusCode ?? 0

          if (
            status >= 300 &&
            status < 400 &&
            request.redirect === 'error'
          ) {
            incoming.resume()
            reject(
              new TypeError(
                'mutual TLS fetch rejected a redirect',
              ),
            )
            return
          }

          if (status < 100 || status > 599) {
            incoming.resume()
            reject(
              new TypeError(
                'mutual TLS server returned an invalid status',
              ),
            )
            return
          }

          const responseBody =
            request.method === 'HEAD' ||
            status === 204 ||
            status === 205 ||
            status === 304
              ? null
              : (Readable.toWeb(incoming) as ReadableStream<Uint8Array>)

          resolve(
            new Response(responseBody, {
              status,
              ...(incoming.statusMessage === undefined
                ? {}
                : {
                    statusText:
                      incoming.statusMessage,
                  }),
              headers: responseHeaders(incoming.headers),
            }),
          )
        },
      )

      outgoing.once('error', reject)
      outgoing.end()
    })
  }
}

function responseHeaders(
  source: IncomingHttpHeaders,
): Headers {
  const headers = new Headers()

  for (const [name, value] of Object.entries(source)) {
    if (value === undefined) {
      continue
    }

    if (Array.isArray(value)) {
      for (const item of value) {
        headers.append(name, item)
      }
      continue
    }

    headers.append(name, String(value))
  }

  return headers
}
