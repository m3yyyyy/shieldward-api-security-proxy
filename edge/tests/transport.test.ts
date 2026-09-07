import { describe, expect, it } from 'vitest'

import {
  isLoopbackHostname,
  usesSecureTransport,
} from '../src/transport.js'

describe('transport security', () => {
  it('recognizes only explicit loopback hosts', () => {
    expect(isLoopbackHostname('localhost')).toBe(true)
    expect(isLoopbackHostname('LOCALHOST.')).toBe(true)
    expect(isLoopbackHostname('127.0.0.1')).toBe(true)
    expect(isLoopbackHostname('127.0.0.2')).toBe(true)
    expect(isLoopbackHostname('[::1]')).toBe(true)
    expect(
      isLoopbackHostname('::ffff:127.0.0.1'),
    ).toBe(true)

    expect(isLoopbackHostname('0.0.0.0')).toBe(false)
    expect(
      isLoopbackHostname('127.0.0.1.example.com'),
    ).toBe(false)
  })

  it('allows HTTPS and loopback HTTP transports', () => {
    expect(
      usesSecureTransport(
        new URL('https://control.example'),
      ),
    ).toBe(true)
    expect(
      usesSecureTransport(
        new URL('http://127.0.0.1:18080'),
      ),
    ).toBe(true)
    expect(
      usesSecureTransport(
        new URL('http://control.example'),
      ),
    ).toBe(false)
  })
})
