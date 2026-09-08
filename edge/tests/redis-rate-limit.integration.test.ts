import { randomUUID } from 'node:crypto'

import { createClient } from '@redis/client'
import {
  afterAll,
  beforeAll,
  describe,
  expect,
  it,
} from 'vitest'

import type { RateLimitPolicy } from '../src/bundle.js'
import {
  RedisFixedWindowRateLimiter,
  type RedisEvalClient,
} from '../src/redis-rate-limit.js'

const redisUrl = process.env.TEST_REDIS_URL

describe.skipIf(redisUrl === undefined)(
  'Redis distributed rate limiter integration',
  () => {
    const firstClient = createClient({
      url: redisUrl,
      disableOfflineQueue: true,
    })
    const secondClient = createClient({
      url: redisUrl,
      disableOfflineQueue: true,
    })
    const prefix = `shieldward:test:${randomUUID()}`
    const first = new RedisFixedWindowRateLimiter({
      client: firstClient as unknown as RedisEvalClient,
      keyPrefix: prefix,
    })
    const second = new RedisFixedWindowRateLimiter({
      client: secondClient as unknown as RedisEvalClient,
      keyPrefix: prefix,
    })
    const policy: RateLimitPolicy = {
      requests: 3,
      window: '1m',
      key: 'client-ip',
    }

    beforeAll(async () => {
      firstClient.on('error', () => undefined)
      secondClient.on('error', () => undefined)
      await Promise.all([
        firstClient.connect(),
        secondClient.connect(),
      ])
    })

    afterAll(async () => {
      await Promise.all([
        firstClient.close(),
        secondClient.close(),
      ])
    })

    it('enforces one counter across independent clients', async () => {
      const results = await Promise.all([
        first.check('orders-read', 'client-a', policy),
        second.check('orders-read', 'client-a', policy),
        first.check('orders-read', 'client-a', policy),
      ])

      expect(
        results.filter((result) => result.allowed),
      ).toHaveLength(3)

      await expect(
        second.check('orders-read', 'client-a', policy),
      ).resolves.toMatchObject({
        allowed: false,
        limit: 3,
        remaining: 0,
      })

      await expect(
        second.check('orders-read', 'client-b', policy),
      ).resolves.toMatchObject({
        allowed: true,
        remaining: 2,
      })
    })
  },
)
