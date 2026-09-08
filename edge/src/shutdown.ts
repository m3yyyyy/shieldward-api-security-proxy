export interface DrainableGateway {
  beginDrain(): void
  waitForIdle(): Promise<void>
}

export interface ShutdownServer {
  close(
    callback: (error?: Error) => void,
  ): unknown
  closeAllConnections(): void
}

export interface GracefulShutdownOptions {
  readonly gateway: DrainableGateway
  readonly server: ShutdownServer
  readonly gracePeriodMs: number
  readonly stopDependencies: () => Promise<void>
}

export interface GracefulShutdownResult {
  readonly forced: boolean
}

type ShutdownRaceResult =
  | {
      readonly status: 'completed'
      readonly serverError: Error | undefined
    }
  | {
      readonly status: 'failed'
      readonly error: unknown
    }
  | {
      readonly status: 'timed_out'
    }

export async function performGracefulShutdown(
  options: GracefulShutdownOptions,
): Promise<GracefulShutdownResult> {
  validateGracePeriod(options.gracePeriodMs)
  options.gateway.beginDrain()

  const serverClosed = closeServer(options.server)
  const completion: Promise<ShutdownRaceResult> =
    Promise.all([
      options.gateway.waitForIdle(),
      serverClosed,
    ]).then(
      ([, serverError]) => ({
        status: 'completed' as const,
        serverError,
      }),
      (error: unknown) => ({
        status: 'failed' as const,
        error,
      }),
    )

  let timeout:
    | ReturnType<typeof setTimeout>
    | undefined
  const timedOut = new Promise<ShutdownRaceResult>(
    (resolve) => {
      timeout = setTimeout(
        () => resolve({ status: 'timed_out' }),
        options.gracePeriodMs,
      )
    },
  )

  const result = await Promise.race([
    completion,
    timedOut,
  ])

  if (timeout !== undefined) {
    clearTimeout(timeout)
  }

  const errors: unknown[] = []
  let forced = false

  if (result.status === 'timed_out') {
    forced = true

    try {
      options.server.closeAllConnections()
    } catch (error) {
      errors.push(error)
    }
  } else if (result.status === 'failed') {
    errors.push(result.error)
  } else if (result.serverError !== undefined) {
    errors.push(result.serverError)
  }

  try {
    await options.stopDependencies()
  } catch (error) {
    errors.push(error)
  }

  if (errors.length > 0) {
    throw new AggregateError(
      errors,
      'graceful shutdown failed',
    )
  }

  return {
    forced,
  }
}

function closeServer(
  server: ShutdownServer,
): Promise<Error | undefined> {
  return new Promise((resolve) => {
    try {
      server.close((error) => resolve(error))
    } catch (error) {
      resolve(asError(error))
    }
  })
}

function validateGracePeriod(value: number): void {
  if (
    !Number.isSafeInteger(value) ||
    value <= 0
  ) {
    throw new Error(
      'shutdown grace period must be a positive integer',
    )
  }
}

function asError(value: unknown): Error {
  if (value instanceof Error) {
    return value
  }

  return new Error(String(value))
}
