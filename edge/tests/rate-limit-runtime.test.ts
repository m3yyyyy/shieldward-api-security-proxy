import {
  mkdtemp,
  rm,
  writeFile,
} from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  describe,
  expect,
  it,
  vi,
} from 'vitest'

import {
  createRateLimitRuntime,
  type RedisRuntimeClient,
  type RedisRuntimeClientFactory,
} from '../src/rate-limit-runtime.js'
import type { RedisRateLimitRuntimeConfiguration } from '../src/runtime-config.js'

function createConfiguration(
  overrides: Partial<RedisRateLimitRuntimeConfiguration> = {},
): RedisRateLimitRuntimeConfiguration {
  return {
    backend: 'redis',
    url: 'rediss://redis.example:6380/',
    username: undefined,
    passwordFile: undefined,
    certificateAuthorityFile: undefined,
    keyPrefix: 'shieldward:test',
    connectTimeoutMs: 2_000,
    commandTimeoutMs: 500,
    ...overrides,
  }
}

function createClient(): RedisRuntimeClient {
  return {
    isOpen: true,
    isReady: true,
    on: vi.fn(),
    connect: vi.fn(async () => undefined),
    ping: vi.fn(async () => 'PONG'),
    eval: vi.fn(async () => [1, 1, 0, 60_000, 60]),
    close: vi.fn(async () => undefined),
    destroy: vi.fn(),
  }
}

describe('rate-limit runtime', () => {
  it('creates a ready in-memory backend without external resources', async () => {
    const runtime = await createRateLimitRuntime({
      backend: 'memory',
    })

    expect(runtime.backend).toBe('memory')
    expect(runtime.ready()).toBe(true)
    await expect(runtime.close()).resolves.toBeUndefined()
  })

  it('loads Redis secrets from files and configures bounded behavior', async () => {
    const directory = await mkdtemp(
      join(tmpdir(), 'shieldward-redis-'),
    )

    try {
      const passwordFile = join(directory, 'password')
      const caFile = join(directory, 'ca.pem')

      await writeFile(passwordFile, 'test-password\n')
      await writeFile(caFile, 'test certificate authority')

      const client = createClient()
      const factory = vi.fn<RedisRuntimeClientFactory>(
        () => client,
      )
      const runtime = await createRateLimitRuntime(
        createConfiguration({
          username: 'edge',
          passwordFile,
          certificateAuthorityFile: caFile,
        }),
        {
          createRedisClient: factory,
        },
      )

      expect(factory).toHaveBeenCalledOnce()

      const options = factory.mock.calls[0]![0]

      expect(options).toMatchObject({
        url: 'rediss://redis.example:6380/',
        username: 'edge',
        password: 'test-password',
        disableOfflineQueue: true,
        commandsQueueMaxLength: 1_000,
        commandOptions: {
          timeout: 500,
        },
        socket: {
          tls: true,
          connectTimeout: 2_000,
          ca: 'test certificate authority',
        },
      })
      expect(client.connect).toHaveBeenCalledOnce()
      expect(client.ping).toHaveBeenCalledOnce()
      expect(runtime.backend).toBe('redis')
      expect(runtime.ready()).toBe(true)

      await runtime.close()
      expect(client.close).toHaveBeenCalledOnce()
    } finally {
      await rm(directory, {
        recursive: true,
        force: true,
      })
    }
  })

  it('destroys failed clients and returns a secret-safe startup error', async () => {
    const client = createClient()

    vi.mocked(client.connect).mockRejectedValue(
      new Error(
        'rediss://edge:private-value@redis.example',
      ),
    )

    await expect(
      createRateLimitRuntime(
        createConfiguration(),
        {
          createRedisClient: () => client,
        },
      ),
    ).rejects.toThrow(
      'connect distributed rate limiter: Redis is unavailable',
    )

    expect(client.destroy).toHaveBeenCalledOnce()
  })
})
