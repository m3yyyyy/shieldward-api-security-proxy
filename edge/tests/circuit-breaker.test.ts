import { describe, expect, it } from 'vitest'

import {
  UpstreamCircuitBreaker,
  type CircuitBreakerPermit,
  type CircuitBreakerAcquisition,
  type CircuitBreakerTransition,
} from '../src/circuit-breaker.js'

function expectPermit(
  acquisition: CircuitBreakerAcquisition,
): CircuitBreakerPermit {
  expect(acquisition.allowed).toBe(true)

  if (!acquisition.allowed) {
    throw new Error('expected circuit permit')
  }

  return acquisition
}

describe('upstream circuit breaker', () => {
  it('opens after consecutive failures and reports retry timing', () => {
    let now = 1_000
    const transitions: CircuitBreakerTransition[] = []
    const breaker = new UpstreamCircuitBreaker({
      failureThreshold: 2,
      openDurationMs: 5_000,
      nowMilliseconds: () => now,
      onTransition: (transition) =>
        transitions.push(transition),
    })

    expectPermit(
      breaker.acquire('https://orders.internal/a'),
    ).recordFailure()
    expectPermit(
      breaker.acquire('https://orders.internal/b'),
    ).recordFailure()

    now = 2_500
    const rejected = breaker.acquire(
      'https://orders.internal/c',
    )

    expect(rejected).toEqual({
      allowed: false,
      retryAfterSeconds: 4,
    })
    expect(transitions).toEqual([
      {
        previous: 'closed',
        next: 'open',
      },
    ])
  })

  it('allows one half-open probe and closes after recovery', () => {
    let now = 100
    const transitions: CircuitBreakerTransition[] = []
    const breaker = new UpstreamCircuitBreaker({
      failureThreshold: 1,
      openDurationMs: 3_000,
      nowMilliseconds: () => now,
      onTransition: (transition) =>
        transitions.push(transition),
    })

    expectPermit(
      breaker.acquire('https://orders.internal'),
    ).recordFailure()

    now = 3_100
    const probe = expectPermit(
      breaker.acquire('https://orders.internal'),
    )

    expect(
      breaker.acquire('https://orders.internal'),
    ).toEqual({
      allowed: false,
      retryAfterSeconds: 1,
    })

    probe.recordSuccess()

    expect(
      breaker.acquire('https://orders.internal'),
    ).toMatchObject({
      allowed: true,
    })
    expect(transitions).toEqual([
      {
        previous: 'closed',
        next: 'open',
      },
      {
        previous: 'open',
        next: 'half_open',
      },
      {
        previous: 'half_open',
        next: 'closed',
      },
    ])
  })

  it('resets consecutive failures after a success', () => {
    const breaker = new UpstreamCircuitBreaker({
      failureThreshold: 2,
    })

    expectPermit(
      breaker.acquire('https://orders.internal'),
    ).recordFailure()
    expectPermit(
      breaker.acquire('https://orders.internal'),
    ).recordSuccess()
    expectPermit(
      breaker.acquire('https://orders.internal'),
    ).recordFailure()

    const stillClosed = breaker.acquire(
      'https://orders.internal',
    )

    expect(stillClosed.allowed).toBe(true)
  })

  it('reopens for a full period after a failed recovery probe', () => {
    let now = 0
    const breaker = new UpstreamCircuitBreaker({
      failureThreshold: 1,
      openDurationMs: 2_000,
      nowMilliseconds: () => now,
    })

    expectPermit(
      breaker.acquire('https://orders.internal'),
    ).recordFailure()

    now = 2_000
    const probe = expectPermit(
      breaker.acquire('https://orders.internal'),
    )

    now = 2_500
    probe.recordFailure()

    expect(
      breaker.acquire('https://orders.internal'),
    ).toEqual({
      allowed: false,
      retryAfterSeconds: 2,
    })
  })

  it('bounds retained upstream state and recovers capacity', () => {
    let now = 0
    const breaker = new UpstreamCircuitBreaker({
      failureThreshold: 1,
      openDurationMs: 1_000,
      maximumUpstreams: 1,
      nowMilliseconds: () => now,
    })

    expectPermit(
      breaker.acquire('https://orders.internal'),
    ).recordFailure()

    expect(
      breaker.acquire('https://billing.internal'),
    ).toEqual({
      allowed: false,
      retryAfterSeconds: 1,
    })

    now = 1_000
    expectPermit(
      breaker.acquire('https://orders.internal'),
    ).recordSuccess()

    expect(
      breaker.acquire('https://billing.internal'),
    ).toMatchObject({
      allowed: true,
    })
  })

  it('does not count an abandoned request as a failure', () => {
    const breaker = new UpstreamCircuitBreaker({
      failureThreshold: 1,
    })

    expectPermit(
      breaker.acquire('https://orders.internal'),
    ).abandon()

    expect(
      breaker.acquire('https://orders.internal'),
    ).toMatchObject({
      allowed: true,
    })
  })

  it('allows another probe when a half-open probe is abandoned', () => {
    let now = 0
    const breaker = new UpstreamCircuitBreaker({
      failureThreshold: 1,
      openDurationMs: 1_000,
      nowMilliseconds: () => now,
    })

    expectPermit(
      breaker.acquire('https://orders.internal'),
    ).recordFailure()

    now = 1_000
    expectPermit(
      breaker.acquire('https://orders.internal'),
    ).abandon()

    expect(
      breaker.acquire('https://orders.internal'),
    ).toMatchObject({
      allowed: true,
    })
  })
})
