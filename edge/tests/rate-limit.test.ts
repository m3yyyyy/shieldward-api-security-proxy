import { describe, expect, it } from 'vitest'

import type { RateLimitPolicy } from '../src/bundle.js'
import {
  FixedWindowRateLimiter,
  RateLimiterError,
  parseDurationMilliseconds,
} from '../src/rate-limit.js'

function createPolicy(
  requests: number,
  window = '1m',
): RateLimitPolicy {
  return {
    requests,
    window,
    key: 'client-ip',
  }
}

describe('fixed-window rate limiter', () => {
  it('parses Go-style duration values', () => {
    expect(parseDurationMilliseconds('1m')).toBe(
      60_000,
    )

    expect(
      parseDurationMilliseconds('1h30m'),
    ).toBe(5_400_000)

    expect(
      parseDurationMilliseconds('1.5s'),
    ).toBe(1_500)

    expect(
      parseDurationMilliseconds('500ms'),
    ).toBe(500)

    expect(
      parseDurationMilliseconds('.5s'),
    ).toBe(500)

    expect(() =>
      parseDurationMilliseconds('0s'),
    ).toThrow(RateLimiterError)

    expect(() =>
      parseDurationMilliseconds('-1s'),
    ).toThrow(RateLimiterError)

    expect(() =>
      parseDurationMilliseconds('1d'),
    ).toThrow(RateLimiterError)
  })

  it('allows requests up to the limit and then blocks', () => {
    let now = 10_000

    const limiter = new FixedWindowRateLimiter({
      now: () => now,
    })

    const policy = createPolicy(2)

    expect(
      limiter.check('orders-read', 'client-a', policy),
    ).toEqual({
      allowed: true,
      limit: 2,
      remaining: 1,
      resetAt: 60_000,
      retryAfterSeconds: 50,
    })

    expect(
      limiter.check('orders-read', 'client-a', policy),
    ).toEqual({
      allowed: true,
      limit: 2,
      remaining: 0,
      resetAt: 60_000,
      retryAfterSeconds: 50,
    })

    expect(
      limiter.check('orders-read', 'client-a', policy),
    ).toEqual({
      allowed: false,
      limit: 2,
      remaining: 0,
      resetAt: 60_000,
      retryAfterSeconds: 50,
    })

    now = 59_999

    expect(
      limiter.check('orders-read', 'client-a', policy)
        .allowed,
    ).toBe(false)
  })

  it('resets at the boundary and isolates identities', () => {
    let now = 59_999

    const limiter = new FixedWindowRateLimiter({
      now: () => now,
    })

    const policy = createPolicy(1)

    expect(
      limiter.check('orders-read', 'client-a', policy)
        .allowed,
    ).toBe(true)

    expect(
      limiter.check('orders-read', 'client-a', policy)
        .allowed,
    ).toBe(false)

    expect(
      limiter.check('orders-read', 'client-b', policy)
        .allowed,
    ).toBe(true)

    expect(
      limiter.check('orders-write', 'client-a', policy)
        .allowed,
    ).toBe(true)

    now = 60_000

    expect(
      limiter.check('orders-read', 'client-a', policy),
    ).toEqual({
      allowed: true,
      limit: 1,
      remaining: 0,
      resetAt: 120_000,
      retryAfterSeconds: 60,
    })
  })

  it('bounds storage and removes expired buckets', () => {
    let now = 0

    const limiter = new FixedWindowRateLimiter({
      now: () => now,
      maxBuckets: 2,
    })

    const policy = createPolicy(1)

    limiter.check('orders-read', 'client-a', policy)
    limiter.check('orders-read', 'client-b', policy)

    expect(() =>
      limiter.check(
        'orders-read',
        'client-c',
        policy,
      ),
    ).toThrow('rate limiter capacity is exhausted')

    now = 60_000

    expect(
      limiter.check('orders-read', 'client-c', policy)
        .allowed,
    ).toBe(true)
  })
})