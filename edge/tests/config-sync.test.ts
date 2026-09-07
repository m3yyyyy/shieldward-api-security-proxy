import { describe, expect, it, vi } from 'vitest'

import {
  ConfigurationClient,
  type ConfigurationSnapshot,
} from '../src/config-client.js'
import {
  ConfigurationSynchronizer,
  ConfigurationSyncError,
} from '../src/config-sync.js'

const CURRENT_VERSION = `sha256:${'a'.repeat(64)}`
const NEXT_VERSION = `sha256:${'b'.repeat(64)}`

function createClient() {
  const snapshot = {
    bundle: {
      version: CURRENT_VERSION,
    },
    etag: `"${CURRENT_VERSION}"`,
    loadedAt: 1234,
  } as unknown as ConfigurationSnapshot

  const client = new ConfigurationClient({
    baseUrl: 'http://control-plane.test:18080',
    trustedKeys: new Map(),
    fetchImpl: async () => {
      throw new Error('unexpected bundle request')
    },
  })

  const refresh = vi
    .spyOn(client, 'refresh')
    .mockResolvedValue({
      status: 'unchanged',
      snapshot,
    })

  vi.spyOn(client, 'current').mockReturnValue(snapshot)

  return {
    client,
    refresh,
  }
}

function createEventStream() {
  let controller:
    | ReadableStreamDefaultController<Uint8Array>
    | undefined

  const fetchImpl = vi.fn<typeof fetch>(
    async (_input, init) => {
      const stream = new ReadableStream<Uint8Array>({
        start(value) {
          controller = value

          init?.signal?.addEventListener(
            'abort',
            () => {
              try {
                value.close()
              } catch {
                // The stream may already be closed.
              }
            },
            {
              once: true,
            },
          )
        },
      })

      return new Response(stream, {
        status: 200,
        headers: {
          'content-type': 'text/event-stream',
        },
      })
    },
  )

  return {
    fetchImpl,

    write(value: string): void {
      if (controller === undefined) {
        throw new Error('event stream is not connected')
      }

      controller.enqueue(
        new TextEncoder().encode(value),
      )
    },
  }
}

describe('configuration synchronizer', () => {
  it('rejects invalid URLs and intervals', () => {
    const { client } = createClient()

    expect(
      () =>
        new ConfigurationSynchronizer({
          baseUrl: 'file:///control-plane',
          client,
        }),
    ).toThrow(ConfigurationSyncError)

    expect(
      () =>
        new ConfigurationSynchronizer({
          baseUrl: 'http://control-plane.test',
          client,
          pollIntervalMs: 0,
        }),
    ).toThrow('poll interval must be a positive integer')

    expect(
      () =>
        new ConfigurationSynchronizer({
          baseUrl: 'http://control-plane.test',
          client,
          reconnectDelayMs: -1,
        }),
    ).toThrow(
      'reconnect delay must be a positive integer',
    )
  })

  it('refreshes when SSE announces a new bundle', async () => {
    const { client, refresh } = createClient()
    const events = createEventStream()
    const onRefresh = vi.fn()

    const synchronizer =
      new ConfigurationSynchronizer({
        baseUrl: 'http://control-plane.test:18080',
        client,
        fetchImpl: events.fetchImpl,
        pollIntervalMs: 60_000,
        reconnectDelayMs: 60_000,
        onRefresh,
      })

    await synchronizer.start()

    expect(synchronizer.running()).toBe(true)
    expect(refresh).toHaveBeenCalledTimes(1)
    expect(onRefresh).toHaveBeenCalledWith(
      expect.objectContaining({
        status: 'unchanged',
      }),
    )

    events.write(
      `event: bundle\ndata: {"version":"${NEXT_VERSION}"}\n\n`,
    )

    await vi.waitFor(() => {
      expect(refresh).toHaveBeenCalledTimes(2)
    })

    expect(events.fetchImpl).toHaveBeenCalledTimes(1)
    expect(onRefresh).toHaveBeenCalledTimes(2)

    await synchronizer.stop()

    expect(synchronizer.running()).toBe(false)
  })

  it('ignores the current version and reports invalid events', async () => {
    const { client, refresh } = createClient()
    const events = createEventStream()
    const onError = vi.fn()

    const synchronizer =
      new ConfigurationSynchronizer({
        baseUrl: 'http://control-plane.test:18080',
        client,
        fetchImpl: events.fetchImpl,
        pollIntervalMs: 60_000,
        reconnectDelayMs: 60_000,
        onError,
      })

    await synchronizer.start()

    events.write(
      `event: bundle\ndata: {"version":"${CURRENT_VERSION}"}\n\n` +
        'event: bundle\ndata: {"version":"invalid"}\n\n',
    )

    await vi.waitFor(() => {
      expect(onError).toHaveBeenCalledTimes(1)
    })

    expect(refresh).toHaveBeenCalledTimes(1)
    expect(onError).toHaveBeenCalledWith(
      expect.objectContaining({
        message:
          'bundle event version has an invalid format',
      }),
    )

    await synchronizer.stop()
  })

  it('polls as a fallback and stops cleanly', async () => {
    vi.useFakeTimers()

    try {
      const { client, refresh } = createClient()
      const events = createEventStream()

      const synchronizer =
        new ConfigurationSynchronizer({
          baseUrl:
            'http://control-plane.test:18080',
          client,
          fetchImpl: events.fetchImpl,
          pollIntervalMs: 1_000,
          reconnectDelayMs: 60_000,
        })

      await synchronizer.start()

      await vi.advanceTimersByTimeAsync(1_000)

      expect(refresh).toHaveBeenCalledTimes(2)

      await synchronizer.stop()

      expect(synchronizer.running()).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })

  it('contains failures from refresh observers', async () => {
    const { client } = createClient()
    const events = createEventStream()

    const synchronizer =
      new ConfigurationSynchronizer({
        baseUrl: 'http://control-plane.test:18080',
        client,
        fetchImpl: events.fetchImpl,
        pollIntervalMs: 60_000,
        reconnectDelayMs: 60_000,
        onRefresh: () => {
          throw new Error('observer failed')
        },
      })

    await expect(synchronizer.start()).resolves.toEqual(
      expect.objectContaining({
        status: 'unchanged',
      }),
    )

    await synchronizer.stop()
  })
})
