import { describe, expect, it } from 'vitest'

import { ServerSentEventDecoder } from '../src/sse.js'

describe('server-sent event decoder', () => {
  it('decodes an event split across network chunks', () => {
    const decoder = new ServerSentEventDecoder()

    expect(
      decoder.push('event: bundle\ndata: {"ver'),
    ).toEqual([])

    expect(
      decoder.push('sion":"sha256:test"}\n\n'),
    ).toEqual([
      {
        event: 'bundle',
        data: '{"version":"sha256:test"}',
      },
    ])
  })

  it('supports CRLF and ignores keepalive comments', () => {
    const decoder = new ServerSentEventDecoder()

    expect(
      decoder.push(
        ': keepalive\r\n\r\nevent: bundle\r\n',
      ),
    ).toEqual([])

    expect(
      decoder.push(
        'data: {"version":"v2"}\r\n\r\n',
      ),
    ).toEqual([
      {
        event: 'bundle',
        data: '{"version":"v2"}',
      },
    ])
  })

  it('joins multiple data lines and resets event state', () => {
    const decoder = new ServerSentEventDecoder()

    expect(
      decoder.push(
        'event: bundle\n' +
          'data: first\n' +
          'data: second\n\n' +
          'data: fallback\n\n',
      ),
    ).toEqual([
      {
        event: 'bundle',
        data: 'first\nsecond',
      },
      {
        event: 'message',
        data: 'fallback',
      },
    ])
  })

  it('discards an incomplete event when the stream ends', () => {
    const decoder = new ServerSentEventDecoder()

    expect(
      decoder.push('event: bundle\ndata: partial'),
    ).toEqual([])

    decoder.finish()

    expect(decoder.push('\n\n')).toEqual([])
  })
})