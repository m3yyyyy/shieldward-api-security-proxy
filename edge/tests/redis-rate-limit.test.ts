import { describe, expect, it, vi } from 'vitest'

import type { RateLimitPolicy } from '../src/bundle.js'
import {
  RedisFixedWindowRateLimiter,
  type RedisEvalClient,
} from '../src/redis-rate-limit.js'

const policy: RateLimitPolicy = {
  requests: 2,
  window: '1m',
  key: 'client-ip',
}

describe('Redis fixed-window rate limiter', () => {
  it('uses one hashed key and parses the atomic script response', async () => {
    const evalScript = vi.fn<
      RedisEvalClient['eval']
    >(async () => [1, 2, 1, 60_000, 50])
    const limiter = new RedisFixedWindowRateLimiter({
      client: {
        eval: evalScript,
      },
      keyPrefix: 'shieldward:test',
    })

    await expect(
      limiter.check(
        'orders-read',
        'customer@example.test',
        policy,
      ),
    ).resolves.toEqual({
      allowed: true,
      limit: 2,
      remaining: 1,
      resetAt: 60_000,
      retryAfterSeconds: 50,
    })

    const [script, options] =
      evalScript.mock.calls[0]!

    expect(script).toContain("redis.call('TIME')")
    expect(script).toContain("redis.call('PEXPIRE'")
    expect(options.arguments).toEqual(['2', '60000'])
    expect(options.keys).toHaveLength(1)
    expect(options.keys[0]).toMatch(
      /^shieldward:test:[a-f0-9]{64}$/,
    )

    const serialized = JSON.stringify(options.keys)
    expect(serialized).not.toContain('orders-read')
    expect(serialized).not.toContain(
      'customer@example.test',
    )
  })

  it('fails closed on Redis and response errors', async () => {
    const unavailable = new RedisFixedWindowRateLimiter({
      client: {
        eval: async () => {
          throw new Error(
            'rediss://user:secret@redis.example',
          )
        },
      },
    })

    await expect(
      unavailable.check('orders-read', 'client-a', policy),
    ).rejects.toThrow(
      'distributed rate limiter request failed',
    )

    const invalid = new RedisFixedWindowRateLimiter({
      client: {
        eval: async () => ['unexpected'],
      },
    })

    await expect(
      invalid.check('orders-read', 'client-a', policy),
    ).rejects.toThrow(
      'distributed rate limiter returned an invalid response',
    )
  })

  it('requires millisecond-precision windows and safe prefixes', async () => {
    expect(
      () =>
        new RedisFixedWindowRateLimiter({
          client: {
            eval: async () => [],
          },
          keyPrefix: 'unsafe prefix',
        }),
    ).toThrow('Redis key prefix')

    const limiter = new RedisFixedWindowRateLimiter({
      client: {
        eval: async () => [],
      },
    })

    await expect(
      limiter.check('orders-read', 'client-a', {
        ...policy,
        window: '1.5ms',
      }),
    ).rejects.toThrow('whole milliseconds')
  })
})
