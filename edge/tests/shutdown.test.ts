import {
  afterEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest'

import {
  performGracefulShutdown,
  type ShutdownServer,
} from '../src/shutdown.js'

afterEach(() => {
  vi.useRealTimers()
})

describe('graceful shutdown', () => {
  it('drains requests before stopping dependencies', async () => {
    const events: string[] = []
    const server: ShutdownServer = {
      close: (callback) => {
        events.push('server_close')
        callback()
      },
      closeAllConnections: () => {
        events.push('force_close')
      },
    }

    const result = await performGracefulShutdown({
      gateway: {
        beginDrain: () => events.push('begin_drain'),
        waitForIdle: async () => {
          events.push('idle')
        },
      },
      server,
      gracePeriodMs: 1_000,
      stopDependencies: async () => {
        events.push('stop_dependencies')
      },
    })

    expect(result).toEqual({
      forced: false,
    })
    expect(events).toEqual([
      'begin_drain',
      'server_close',
      'idle',
      'stop_dependencies',
    ])
  })

  it('force-closes connections after the deadline', async () => {
    vi.useFakeTimers()
    const closeAllConnections = vi.fn()
    const stopDependencies = vi.fn(async () => undefined)

    const resultPromise = performGracefulShutdown({
      gateway: {
        beginDrain: () => undefined,
        waitForIdle: () => new Promise(() => undefined),
      },
      server: {
        close: () => undefined,
        closeAllConnections,
      },
      gracePeriodMs: 500,
      stopDependencies,
    })

    await vi.advanceTimersByTimeAsync(500)

    await expect(resultPromise).resolves.toEqual({
      forced: true,
    })
    expect(closeAllConnections).toHaveBeenCalledOnce()
    expect(stopDependencies).toHaveBeenCalledOnce()
  })

  it('stops dependencies before reporting a server error', async () => {
    const stopDependencies = vi.fn(async () => undefined)
    const shutdown = performGracefulShutdown({
      gateway: {
        beginDrain: () => undefined,
        waitForIdle: async () => undefined,
      },
      server: {
        close: (callback) =>
          callback(new Error('close failed')),
        closeAllConnections: () => undefined,
      },
      gracePeriodMs: 1_000,
      stopDependencies,
    })

    await expect(shutdown).rejects.toBeInstanceOf(
      AggregateError,
    )
    expect(stopDependencies).toHaveBeenCalledOnce()
  })
})
