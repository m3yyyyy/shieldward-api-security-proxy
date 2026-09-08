import { createHash } from 'node:crypto'

import type { RateLimitPolicy } from './bundle.js'
import {
  RateLimiterError,
  type RateLimiter,
  type RateLimitResult,
  validateRateLimitInput,
} from './rate-limit.js'

const FIXED_WINDOW_SCRIPT = `
local current = redis.call('TIME')
local now_ms = (tonumber(current[1]) * 1000) + math.floor(tonumber(current[2]) / 1000)
local requested_limit = tonumber(ARGV[1])
local window_ms = tonumber(ARGV[2])
local window_start = now_ms - (now_ms % window_ms)
local reset_at = window_start + window_ms

local existing = redis.call('HMGET', KEYS[1], 'start', 'count', 'limit', 'window')
local stored_start = tonumber(existing[1])
local count = tonumber(existing[2])
local stored_limit = tonumber(existing[3])
local stored_window = tonumber(existing[4])

if stored_start ~= window_start or stored_limit ~= requested_limit or stored_window ~= window_ms then
  count = 0
  redis.call('HSET', KEYS[1],
    'start', window_start,
    'count', count,
    'limit', requested_limit,
    'window', window_ms)
end

local allowed = 0
if count < requested_limit then
  count = redis.call('HINCRBY', KEYS[1], 'count', 1)
  allowed = 1
end

redis.call('PEXPIRE', KEYS[1], math.max(1, reset_at - now_ms))

local remaining = math.max(0, requested_limit - count)
local retry_after = math.max(1, math.ceil((reset_at - now_ms) / 1000))
return { allowed, requested_limit, remaining, reset_at, retry_after }
`

export interface RedisEvalClient {
  eval(
    script: string,
    options: {
      readonly keys: readonly string[]
      readonly arguments: readonly string[]
    },
  ): Promise<unknown>
}

export interface RedisRateLimiterOptions {
  readonly client: RedisEvalClient
  readonly keyPrefix?: string
}

export class RedisFixedWindowRateLimiter
  implements RateLimiter
{
  readonly #client: RedisEvalClient
  readonly #keyPrefix: string

  constructor(options: RedisRateLimiterOptions) {
    this.#client = options.client
    this.#keyPrefix =
      options.keyPrefix ??
      'shieldward:rate-limit:v1'

    if (
      !/^[A-Za-z0-9:_-]{1,128}$/.test(
        this.#keyPrefix,
      )
    ) {
      throw new RateLimiterError(
        'Redis key prefix must contain 1 to 128 safe characters',
      )
    }
  }

  async check(
    routeId: string,
    identity: string,
    policy: Readonly<RateLimitPolicy>,
  ): Promise<RateLimitResult> {
    const windowMs = validateRateLimitInput(
      routeId,
      identity,
      policy,
    )

    if (!Number.isSafeInteger(windowMs)) {
      throw new RateLimiterError(
        'Redis rate-limit windows must resolve to whole milliseconds',
      )
    }

    const key = `${this.#keyPrefix}:${hashIdentity(routeId, identity)}`

    let reply: unknown

    try {
      reply = await this.#client.eval(
        FIXED_WINDOW_SCRIPT,
        {
          keys: [key],
          arguments: [
            String(policy.requests),
            String(windowMs),
          ],
        },
      )
    } catch {
      throw new RateLimiterError(
        'distributed rate limiter request failed',
      )
    }

    return parseReply(reply)
  }
}

function hashIdentity(
  routeId: string,
  identity: string,
): string {
  return createHash('sha256')
    .update(routeId, 'utf8')
    .update('\u0000', 'utf8')
    .update(identity, 'utf8')
    .digest('hex')
}

function parseReply(reply: unknown): RateLimitResult {
  if (!Array.isArray(reply) || reply.length !== 5) {
    throw new RateLimiterError(
      'distributed rate limiter returned an invalid response',
    )
  }

  const values = reply.map(parseInteger)
  const [allowed, limit, remaining, resetAt, retryAfterSeconds] = values

  if (
    (allowed !== 0 && allowed !== 1) ||
    limit === undefined ||
    limit <= 0 ||
    remaining === undefined ||
    remaining < 0 ||
    remaining > limit ||
    resetAt === undefined ||
    resetAt < 0 ||
    retryAfterSeconds === undefined ||
    retryAfterSeconds <= 0
  ) {
    throw new RateLimiterError(
      'distributed rate limiter returned an invalid response',
    )
  }

  return {
    allowed: allowed === 1,
    limit,
    remaining,
    resetAt,
    retryAfterSeconds,
  }
}

function parseInteger(value: unknown): number | undefined {
  const parsed =
    typeof value === 'bigint'
      ? Number(value)
      : typeof value === 'number' ||
          typeof value === 'string'
        ? Number(value)
        : undefined

  return parsed !== undefined &&
    Number.isSafeInteger(parsed)
    ? parsed
    : undefined
}
