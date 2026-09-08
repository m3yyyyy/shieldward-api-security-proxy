const DEFAULT_FAILURE_THRESHOLD = 5
const DEFAULT_OPEN_DURATION_MS = 30_000
const DEFAULT_MAXIMUM_UPSTREAMS = 1_024

export type UpstreamCircuitState =
  | 'closed'
  | 'open'
  | 'half_open'

export interface CircuitBreakerTransition {
  readonly previous: UpstreamCircuitState
  readonly next: UpstreamCircuitState
}

export interface UpstreamCircuitBreakerOptions {
  readonly failureThreshold?: number
  readonly openDurationMs?: number
  readonly maximumUpstreams?: number
  readonly nowMilliseconds?: () => number
  readonly onTransition?: (
    transition: CircuitBreakerTransition,
  ) => void
}

export interface CircuitBreakerPermit {
  readonly allowed: true
  recordSuccess(): void
  recordFailure(): void
  abandon(): void
}

export interface CircuitBreakerRejection {
  readonly allowed: false
  readonly retryAfterSeconds: number
}

export type CircuitBreakerAcquisition =
  | CircuitBreakerPermit
  | CircuitBreakerRejection

interface Circuit {
  state: UpstreamCircuitState
  consecutiveFailures: number
  openedUntil: number
  lastTouched: number
}

export class UpstreamCircuitBreaker {
  readonly #failureThreshold: number
  readonly #openDurationMs: number
  readonly #maximumUpstreams: number
  readonly #nowMilliseconds: () => number
  readonly #onTransition:
    | ((transition: CircuitBreakerTransition) => void)
    | undefined
  readonly #circuits = new Map<string, Circuit>()

  constructor(
    options: UpstreamCircuitBreakerOptions = {},
  ) {
    this.#failureThreshold = validatePositiveInteger(
      options.failureThreshold ??
        DEFAULT_FAILURE_THRESHOLD,
      'circuit failure threshold',
    )
    this.#openDurationMs = validatePositiveInteger(
      options.openDurationMs ??
        DEFAULT_OPEN_DURATION_MS,
      'circuit open duration',
    )
    this.#maximumUpstreams = validatePositiveInteger(
      options.maximumUpstreams ??
        DEFAULT_MAXIMUM_UPSTREAMS,
      'maximum upstream circuit count',
    )
    this.#nowMilliseconds =
      options.nowMilliseconds ?? Date.now
    this.#onTransition = options.onTransition
  }

  acquire(upstream: string): CircuitBreakerAcquisition {
    const key = upstreamOrigin(upstream)
    const now = this.#nowMilliseconds()
    const circuit = this.#findOrCreate(key, now)

    if (circuit === undefined) {
      return {
        allowed: false,
        retryAfterSeconds: 1,
      }
    }

    circuit.lastTouched = now

    if (circuit.state === 'open') {
      if (now < circuit.openedUntil) {
        return rejection(circuit.openedUntil - now)
      }

      this.#transition(circuit, 'half_open')

      return this.#permit(key, true)
    }

    if (circuit.state === 'half_open') {
      return {
        allowed: false,
        retryAfterSeconds: 1,
      }
    }

    return this.#permit(key, false)
  }

  #permit(
    key: string,
    halfOpenProbe: boolean,
  ): CircuitBreakerPermit {
    let completed = false

    const finish = (action: () => void): void => {
      if (completed) {
        return
      }

      completed = true
      action()
    }

    return {
      allowed: true,
      recordSuccess: () =>
        finish(() => this.#recordSuccess(key)),
      recordFailure: () =>
        finish(() => this.#recordFailure(key)),
      abandon: () =>
        finish(() =>
          this.#abandon(key, halfOpenProbe),
        ),
    }
  }

  #findOrCreate(
    key: string,
    now: number,
  ): Circuit | undefined {
    const existing = this.#circuits.get(key)

    if (existing !== undefined) {
      return existing
    }

    if (
      this.#circuits.size >= this.#maximumUpstreams &&
      !this.#evictClosedCircuit()
    ) {
      return undefined
    }

    const circuit: Circuit = {
      state: 'closed',
      consecutiveFailures: 0,
      openedUntil: 0,
      lastTouched: now,
    }

    this.#circuits.set(key, circuit)
    return circuit
  }

  #evictClosedCircuit(): boolean {
    let candidateKey: string | undefined
    let oldestTouch = Number.POSITIVE_INFINITY

    for (const [key, circuit] of this.#circuits) {
      if (
        circuit.state === 'closed' &&
        circuit.lastTouched < oldestTouch
      ) {
        candidateKey = key
        oldestTouch = circuit.lastTouched
      }
    }

    if (candidateKey === undefined) {
      return false
    }

    this.#circuits.delete(candidateKey)
    return true
  }

  #recordSuccess(key: string): void {
    const circuit = this.#circuits.get(key)

    if (circuit === undefined) {
      return
    }

    if (circuit.state !== 'closed') {
      this.#transition(circuit, 'closed')
    }

    this.#circuits.delete(key)
  }

  #recordFailure(key: string): void {
    const now = this.#nowMilliseconds()
    const circuit = this.#findOrCreate(key, now)

    if (circuit === undefined) {
      return
    }

    circuit.lastTouched = now

    if (circuit.state === 'half_open') {
      circuit.openedUntil = now + this.#openDurationMs
      this.#transition(circuit, 'open')
      return
    }

    if (circuit.state === 'open') {
      circuit.openedUntil = Math.max(
        circuit.openedUntil,
        now + this.#openDurationMs,
      )
      return
    }

    circuit.consecutiveFailures += 1

    if (
      circuit.consecutiveFailures >=
      this.#failureThreshold
    ) {
      circuit.openedUntil = now + this.#openDurationMs
      this.#transition(circuit, 'open')
    }
  }

  #abandon(
    key: string,
    halfOpenProbe: boolean,
  ): void {
    const circuit = this.#circuits.get(key)

    if (circuit === undefined) {
      return
    }

    if (
      halfOpenProbe &&
      circuit.state === 'half_open'
    ) {
      circuit.openedUntil = this.#nowMilliseconds()
      this.#transition(circuit, 'open')
      return
    }

    if (
      circuit.state === 'closed' &&
      circuit.consecutiveFailures === 0
    ) {
      this.#circuits.delete(key)
    }
  }

  #transition(
    circuit: Circuit,
    next: UpstreamCircuitState,
  ): void {
    const previous = circuit.state

    if (previous === next) {
      return
    }

    circuit.state = next

    try {
      this.#onTransition?.({
        previous,
        next,
      })
    } catch {
      // Observers must not alter circuit behavior.
    }
  }
}

function upstreamOrigin(upstream: string): string {
  try {
    return new URL(upstream).origin
  } catch {
    return upstream
  }
}

function rejection(
  remainingMilliseconds: number,
): CircuitBreakerRejection {
  return {
    allowed: false,
    retryAfterSeconds: Math.max(
      1,
      Math.ceil(remainingMilliseconds / 1000),
    ),
  }
}

function validatePositiveInteger(
  value: number,
  name: string,
): number {
  if (
    !Number.isSafeInteger(value) ||
    value <= 0
  ) {
    throw new Error(
      `${name} must be a positive integer`,
    )
  }

  return value
}
