import {
  ConfigurationClient,
  type RefreshResult,
} from './config-client.js'
import {
  ServerSentEventDecoder,
  type ServerSentEvent,
} from './sse.js'

const DEFAULT_POLL_INTERVAL_MS = 30_000
const DEFAULT_RECONNECT_DELAY_MS = 2_000

export interface ConfigurationSyncOptions {
  readonly baseUrl: string
  readonly client: ConfigurationClient
  readonly fetchImpl?: typeof fetch
  readonly pollIntervalMs?: number
  readonly reconnectDelayMs?: number
  readonly onError?: (error: unknown) => void
}

export class ConfigurationSyncError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ConfigurationSyncError'
  }
}

export class ConfigurationSynchronizer {
  readonly #eventsUrl: URL
  readonly #client: ConfigurationClient
  readonly #fetchImpl: typeof fetch
  readonly #pollIntervalMs: number
  readonly #reconnectDelayMs: number
  readonly #onError:
    | ((error: unknown) => void)
    | undefined

  #controller: AbortController | undefined
  #streamTask: Promise<void> | undefined
  #pollTask: Promise<void> | undefined

  constructor(options: ConfigurationSyncOptions) {
    let baseUrl: URL

    try {
      baseUrl = new URL(options.baseUrl)
    } catch {
      throw new ConfigurationSyncError(
        'control-plane base URL is invalid',
      )
    }

    if (
      baseUrl.protocol !== 'http:' &&
      baseUrl.protocol !== 'https:'
    ) {
      throw new ConfigurationSyncError(
        'control-plane base URL must use HTTP or HTTPS',
      )
    }

    this.#pollIntervalMs = validateInterval(
      options.pollIntervalMs ??
        DEFAULT_POLL_INTERVAL_MS,
      'poll interval',
    )

    this.#reconnectDelayMs = validateInterval(
      options.reconnectDelayMs ??
        DEFAULT_RECONNECT_DELAY_MS,
      'reconnect delay',
    )

    this.#eventsUrl = new URL('/v1/events', baseUrl)
    this.#client = options.client
    this.#fetchImpl =
      options.fetchImpl ?? globalThis.fetch
    this.#onError = options.onError
  }

  running(): boolean {
    return this.#controller !== undefined
  }

  async start(): Promise<RefreshResult> {
    if (this.#controller !== undefined) {
      throw new ConfigurationSyncError(
        'configuration synchronization is already running',
      )
    }

    const controller = new AbortController()
    this.#controller = controller

    let initialResult: RefreshResult

    try {
      initialResult = await this.#client.refresh(
        controller.signal,
      )
    } catch (error) {
      controller.abort()

      if (this.#controller === controller) {
        this.#controller = undefined
      }

      throw error
    }

    if (
      controller.signal.aborted ||
      this.#controller !== controller
    ) {
      return initialResult
    }

    this.#streamTask = this.#runStreamLoop(
      controller.signal,
    )

    this.#pollTask = this.#runPollingLoop(
      controller.signal,
    )

    return initialResult
  }

  async stop(): Promise<void> {
    const controller = this.#controller

    if (controller === undefined) {
      return
    }

    controller.abort()

    const tasks: Promise<void>[] = []

    if (this.#streamTask !== undefined) {
      tasks.push(this.#streamTask)
    }

    if (this.#pollTask !== undefined) {
      tasks.push(this.#pollTask)
    }

    await Promise.allSettled(tasks)

    if (this.#controller === controller) {
      this.#controller = undefined
      this.#streamTask = undefined
      this.#pollTask = undefined
    }
  }

  async #runStreamLoop(
    signal: AbortSignal,
  ): Promise<void> {
    while (!signal.aborted) {
      try {
        await this.#consumeEventStream(signal)
      } catch (error) {
        if (!signal.aborted) {
          this.#report(error)
        }
      }

      if (!signal.aborted) {
        await waitForDelay(
          this.#reconnectDelayMs,
          signal,
        )
      }
    }
  }

  async #runPollingLoop(
    signal: AbortSignal,
  ): Promise<void> {
    while (!signal.aborted) {
      await waitForDelay(
        this.#pollIntervalMs,
        signal,
      )

      if (signal.aborted) {
        return
      }

      try {
        await this.#client.refresh(signal)
      } catch (error) {
        if (!signal.aborted) {
          this.#report(error)
        }
      }
    }
  }

  async #consumeEventStream(
    signal: AbortSignal,
  ): Promise<void> {
    let response: Response

    try {
      response = await this.#fetchImpl(this.#eventsUrl, {
        method: 'GET',
        headers: {
          Accept: 'text/event-stream',
        },
        cache: 'no-store',
        redirect: 'error',
        signal,
      })
    } catch (error) {
      throw new ConfigurationSyncError(
        `connect event stream: ${errorMessage(error)}`,
      )
    }

    if (!response.ok) {
      throw new ConfigurationSyncError(
        `event stream returned HTTP ${response.status}`,
      )
    }

    const contentType = response.headers
      .get('content-type')
      ?.split(';', 1)[0]
      ?.trim()
      .toLowerCase()

    if (contentType !== 'text/event-stream') {
      throw new ConfigurationSyncError(
        'control plane returned a non-SSE event stream',
      )
    }

    if (response.body === null) {
      throw new ConfigurationSyncError(
        'control-plane event stream has no body',
      )
    }

    const reader = response.body.getReader()
    const textDecoder = new TextDecoder()
    const eventDecoder = new ServerSentEventDecoder()

    try {
      while (!signal.aborted) {
        const result = await reader.read()

        if (result.done) {
          break
        }

        const text = textDecoder.decode(
          result.value,
          {
            stream: true,
          },
        )

        await this.#processEvents(
          eventDecoder.push(text),
          signal,
        )
      }

      const trailingText = textDecoder.decode()

      if (trailingText !== '') {
        await this.#processEvents(
          eventDecoder.push(trailingText),
          signal,
        )
      }
    } finally {
      eventDecoder.finish()
      reader.releaseLock()
    }
  }

  async #processEvents(
    events: readonly ServerSentEvent[],
    signal: AbortSignal,
  ): Promise<void> {
    for (const event of events) {
      if (signal.aborted || event.event !== 'bundle') {
        continue
      }

      try {
        const announcedVersion =
          parseBundleEventVersion(event.data)

        const currentVersion =
          this.#client.current()?.bundle.version

        if (announcedVersion !== currentVersion) {
          await this.#client.refresh(signal)
        }
      } catch (error) {
        if (!signal.aborted) {
          this.#report(error)
        }
      }
    }
  }

  #report(error: unknown): void {
    if (this.#onError === undefined) {
      return
    }

    try {
      this.#onError(error)
    } catch {
      // Error observers must never terminate synchronization.
    }
  }
}

function parseBundleEventVersion(data: string): string {
  let value: unknown

  try {
    value = JSON.parse(data) as unknown
  } catch {
    throw new ConfigurationSyncError(
      'bundle event contains invalid JSON',
    )
  }

  if (
    typeof value !== 'object' ||
    value === null ||
    Array.isArray(value)
  ) {
    throw new ConfigurationSyncError(
      'bundle event payload must be an object',
    )
  }

  const object = value as Record<string, unknown>
  const keys = Object.keys(object)

  if (
    keys.length !== 1 ||
    keys[0] !== 'version'
  ) {
    throw new ConfigurationSyncError(
      'bundle event payload has unsupported fields',
    )
  }

  const version = object.version

  if (
    typeof version !== 'string' ||
    !/^sha256:[0-9a-f]{64}$/.test(version)
  ) {
    throw new ConfigurationSyncError(
      'bundle event version has an invalid format',
    )
  }

  return version
}

function validateInterval(
  value: number,
  name: string,
): number {
  if (
    !Number.isSafeInteger(value) ||
    value <= 0
  ) {
    throw new ConfigurationSyncError(
      `${name} must be a positive integer`,
    )
  }

  return value
}

function waitForDelay(
  milliseconds: number,
  signal: AbortSignal,
): Promise<void> {
  if (signal.aborted) {
    return Promise.resolve()
  }

  return new Promise((resolve) => {
    let timeout:
      | ReturnType<typeof setTimeout>
      | undefined

    const finish = (): void => {
      if (timeout !== undefined) {
        clearTimeout(timeout)
      }

      signal.removeEventListener('abort', finish)
      resolve()
    }

    timeout = setTimeout(finish, milliseconds)
    signal.addEventListener('abort', finish, {
      once: true,
    })
  })
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message
  }

  return String(error)
}