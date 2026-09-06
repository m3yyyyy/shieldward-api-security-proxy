import type { RateLimitPolicy } from './bundle.js'

const DEFAULT_MAX_BUCKETS = 100_000
const CLEANUP_INTERVAL_MS = 60_000

interface RateLimitBucket {
  count: number
  readonly limit: number
  readonly windowMs: number
  readonly resetAt: number
}

export interface RateLimitResult {
  readonly allowed: boolean
  readonly limit: number
  readonly remaining: number
  readonly resetAt: number
  readonly retryAfterSeconds: number
}

export interface RateLimiterOptions {
  readonly now?: () => number
  readonly maxBuckets?: number
}

export class RateLimiterError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'RateLimiterError'
  }
}

export class FixedWindowRateLimiter {
  readonly #now: () => number
  readonly #maxBuckets: number
  readonly #buckets = new Map<
    string,
    RateLimitBucket
  >()

  #nextCleanupAt = 0

  constructor(options: RateLimiterOptions = {}) {
    this.#now = options.now ?? Date.now
    this.#maxBuckets =
      options.maxBuckets ?? DEFAULT_MAX_BUCKETS

    if (
      !Number.isSafeInteger(this.#maxBuckets) ||
      this.#maxBuckets <= 0
    ) {
      throw new RateLimiterError(
        'maximum bucket count must be a positive integer',
      )
    }
  }

  check(
    routeId: string,
    identity: string,
    policy: Readonly<RateLimitPolicy>,
  ): RateLimitResult {
    if (routeId.trim() === '') {
      throw new RateLimiterError(
        'route ID must not be empty',
      )
    }

    if (
      identity.trim() === '' ||
      identity.length > 512
    ) {
      throw new RateLimiterError(
        'rate-limit identity must contain 1 to 512 characters',
      )
    }

    if (
      !Number.isSafeInteger(policy.requests) ||
      policy.requests <= 0
    ) {
      throw new RateLimiterError(
        'rate-limit request count must be a positive integer',
      )
    }

    const now = this.#now()

    if (!Number.isFinite(now) || now < 0) {
      throw new RateLimiterError(
        'rate-limiter clock returned an invalid time',
      )
    }

    const windowMs = parseDurationMilliseconds(
      policy.window,
    )

    if (now >= this.#nextCleanupAt) {
      this.#removeExpired(now)
      this.#nextCleanupAt =
        now + CLEANUP_INTERVAL_MS
    }

    const key = `${routeId}\u0000${identity}`
    let bucket = this.#buckets.get(key)

    if (
      bucket === undefined ||
      now >= bucket.resetAt ||
      bucket.limit !== policy.requests ||
      bucket.windowMs !== windowMs
    ) {
      if (
        bucket === undefined &&
        this.#buckets.size >= this.#maxBuckets
      ) {
        this.#removeExpired(now)

        if (
          this.#buckets.size >= this.#maxBuckets
        ) {
          throw new RateLimiterError(
            'rate limiter capacity is exhausted',
          )
        }
      }

      const windowStart =
        Math.floor(now / windowMs) * windowMs

      bucket = {
        count: 0,
        limit: policy.requests,
        windowMs,
        resetAt: windowStart + windowMs,
      }

      this.#buckets.set(key, bucket)
    }

    const retryAfterSeconds = Math.max(
      1,
      Math.ceil((bucket.resetAt - now) / 1_000),
    )

    if (bucket.count >= bucket.limit) {
      return {
        allowed: false,
        limit: bucket.limit,
        remaining: 0,
        resetAt: bucket.resetAt,
        retryAfterSeconds,
      }
    }

    bucket.count += 1

    return {
      allowed: true,
      limit: bucket.limit,
      remaining: bucket.limit - bucket.count,
      resetAt: bucket.resetAt,
      retryAfterSeconds,
    }
  }

  #removeExpired(now: number): void {
    for (const [key, bucket] of this.#buckets) {
      if (now >= bucket.resetAt) {
        this.#buckets.delete(key)
      }
    }
  }
}

export function parseDurationMilliseconds(
  value: string,
): number {
  if (value === '') {
    throw new RateLimiterError(
      'rate-limit window must be a positive duration',
    )
  }

  const partPattern =
    /(?:\d+(?:\.\d*)?|\.\d+)(?:ns|us|µs|μs|ms|s|m|h)/y

  let totalMs = 0
  let offset = 0

  while (offset < value.length) {
    partPattern.lastIndex = offset

    const match = partPattern.exec(value)

    if (match === null) {
      throw new RateLimiterError(
        'rate-limit window must be a positive duration',
      )
    }

    const part = match[0]
    const amountText = part.match(
      /^(?:\d+(?:\.\d*)?|\.\d+)/,
    )?.[0]

    if (amountText === undefined) {
      throw new RateLimiterError(
        'rate-limit window must be a positive duration',
      )
    }

    const unit = part.slice(amountText.length)
    const amount = Number(amountText)

    totalMs +=
      amount * durationUnitMilliseconds(unit)

    offset = partPattern.lastIndex
  }

  if (
    !Number.isFinite(totalMs) ||
    totalMs <= 0 ||
    totalMs > Number.MAX_SAFE_INTEGER
  ) {
    throw new RateLimiterError(
      'rate-limit window must be a positive duration',
    )
  }

  return totalMs
}

function durationUnitMilliseconds(
  unit: string,
): number {
  switch (unit) {
    case 'ns':
      return 0.000001

    case 'us':
    case 'µs':
    case 'μs':
      return 0.001

    case 'ms':
      return 1

    case 's':
      return 1_000

    case 'm':
      return 60_000

    case 'h':
      return 3_600_000

    default:
      throw new RateLimiterError(
        'rate-limit window contains an unsupported unit',
      )
  }
}