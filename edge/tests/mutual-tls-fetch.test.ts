import { EventEmitter } from 'node:events'
import type { IncomingMessage } from 'node:http'
import type { ClientRequest } from 'node:https'
import { PassThrough } from 'node:stream'

import { describe, expect, it, vi } from 'vitest'

import {
  createMutualTlsFetch,
  type HttpsRequester,
} from '../src/mutual-tls-fetch.js'

describe('mutual TLS fetch', () => {
  it('presents the current client identity and verifies the configured CA', async () => {
    const observed: unknown[] = []
    let certificate = 'client-certificate-one'
    const requester = ((
      _url: URL,
      options: unknown,
      callback: (response: IncomingMessage) => void,
    ) => {
      observed.push(options)
      const outgoing = new EventEmitter() as EventEmitter & {
        end(): void
      }

      outgoing.end = () => {
        const incoming = new PassThrough() as PassThrough & {
          statusCode: number
          statusMessage: string
          headers: Record<string, string>
        }
        incoming.statusCode = 200
        incoming.statusMessage = 'OK'
        incoming.headers = {
          'content-type': 'application/json',
        }
        callback(incoming as unknown as IncomingMessage)
        incoming.end('{"ok":true}')
      }

      return outgoing as unknown as ClientRequest
    }) as unknown as HttpsRequester

    const fetchImpl = createMutualTlsFetch(
      () => ({
        certificate,
        privateKey: 'client-private-key',
        certificateAuthority: 'control-plane-ca',
      }),
      requester,
    )

    const first = await fetchImpl(
      'https://control.example/v1/bundle',
      {
        redirect: 'error',
      },
    )
    await expect(first.json()).resolves.toEqual({
      ok: true,
    })

    certificate = 'client-certificate-two'
    await fetchImpl(
      'https://control.example/v1/bundle',
    )

    expect(observed).toHaveLength(2)
    expect(observed[0]).toMatchObject({
      ca: 'control-plane-ca',
      cert: 'client-certificate-one',
      key: 'client-private-key',
      minVersion: 'TLSv1.2',
      rejectUnauthorized: true,
      agent: false,
    })
    expect(observed[1]).toMatchObject({
      cert: 'client-certificate-two',
    })
  })

  it('rejects cleartext destinations before opening a connection', async () => {
    const requester = vi.fn()
    const fetchImpl = createMutualTlsFetch(
      () => ({
        certificate: 'client-certificate',
        privateKey: 'client-private-key',
        certificateAuthority: 'control-plane-ca',
      }),
      requester as unknown as HttpsRequester,
    )

    await expect(
      fetchImpl('http://control.example/v1/bundle'),
    ).rejects.toThrow(
      'mutual TLS fetch requires an HTTPS URL',
    )
    expect(requester).not.toHaveBeenCalled()
  })
})
