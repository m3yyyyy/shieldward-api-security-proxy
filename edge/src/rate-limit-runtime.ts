import { readFile } from 'node:fs/promises'

import {
  createClient,
  type RedisClientOptions,
} from '@redis/client'

import {
  FixedWindowRateLimiter,
  type RateLimitBackend,
  type RateLimiter,
} from './rate-limit.js'
import {
  RedisFixedWindowRateLimiter,
  type RedisEvalClient,
} from './redis-rate-limit.js'
import type {
  RateLimitRuntimeConfiguration,
  RedisRateLimitRuntimeConfiguration,
} from './runtime-config.js'

const MAX_PASSWORD_FILE_BYTES = 64 * 1024
const MAX_CA_FILE_BYTES = 1024 * 1024

export interface RedisRuntimeClient
  extends RedisEvalClient {
  readonly isOpen: boolean
  readonly isReady: boolean
  on(
    event: 'error',
    listener: (error: Error) => void,
  ): unknown
  connect(): Promise<unknown>
  ping(): Promise<string>
  close(): Promise<unknown>
  destroy(): void
}

export type RedisRuntimeClientFactory = (
  options: RedisClientOptions,
) => RedisRuntimeClient

export interface RateLimitRuntimeOptions {
  readonly createRedisClient?: RedisRuntimeClientFactory
}

export interface RateLimitRuntime {
  readonly backend: RateLimitBackend
  readonly limiter: RateLimiter
  ready(): boolean
  close(): Promise<void>
}

export async function createRateLimitRuntime(
  configuration: RateLimitRuntimeConfiguration,
  options: RateLimitRuntimeOptions = {},
): Promise<RateLimitRuntime> {
  if (configuration.backend === 'memory') {
    return {
      backend: 'memory',
      limiter: new FixedWindowRateLimiter(),
      ready: () => true,
      close: async () => undefined,
    }
  }

  return createRedisRuntime(configuration, options)
}

async function createRedisRuntime(
  configuration: RedisRateLimitRuntimeConfiguration,
  options: RateLimitRuntimeOptions,
): Promise<RateLimitRuntime> {
  const password =
    configuration.passwordFile === undefined
      ? undefined
      : await loadPassword(
          configuration.passwordFile,
        )
  const certificateAuthority =
    configuration.certificateAuthorityFile === undefined
      ? undefined
      : await loadCertificateAuthority(
          configuration.certificateAuthorityFile,
        )
  const redisUrl = new URL(configuration.url)

  const clientOptions: RedisClientOptions = {
    url: configuration.url,
    name: 'shieldward-edge',
    disableOfflineQueue: true,
    commandsQueueMaxLength: 1_000,
    commandOptions: {
      timeout: configuration.commandTimeoutMs,
    },
    socket: {
      ...(redisUrl.protocol === 'rediss:'
        ? {
            tls: true as const,
            ...(certificateAuthority === undefined
              ? {}
              : {
                  ca: certificateAuthority,
                }),
          }
        : {}),
      connectTimeout:
        configuration.connectTimeoutMs,
      reconnectStrategy: (retries: number) =>
        Math.min(
          50 * 2 ** Math.min(retries, 5),
          1_000,
        ),
    },
    ...(configuration.username === undefined
      ? {}
      : {
          username: configuration.username,
        }),
    ...(password === undefined
      ? {}
      : {
          password,
        }),
  }

  const factory =
    options.createRedisClient ??
    ((redisOptions) =>
      createClient(redisOptions) as unknown as RedisRuntimeClient)
  const client = factory(clientOptions)

  client.on('error', () => {
    // The readiness endpoint and policy failure path expose state safely.
  })

  try {
    await client.connect()

    if ((await client.ping()) !== 'PONG') {
      throw new Error('Redis health check failed')
    }
  } catch {
    client.destroy()
    throw new Error(
      'connect distributed rate limiter: Redis is unavailable',
    )
  }

  return {
    backend: 'redis',
    limiter: new RedisFixedWindowRateLimiter({
      client,
      keyPrefix: configuration.keyPrefix,
    }),
    ready: () => client.isReady,
    close: async () => {
      if (!client.isOpen) {
        client.destroy()
        return
      }

      try {
        await client.close()
      } catch {
        client.destroy()
        throw new Error(
          'close distributed rate limiter: Redis shutdown failed',
        )
      }
    },
  }
}

async function loadPassword(path: string): Promise<string> {
  const contents = await readBoundedFile(
    path,
    MAX_PASSWORD_FILE_BYTES,
    'Redis password',
  )
  const password = contents.replace(/\r?\n$/, '')

  if (
    password === '' ||
    password.includes('\r') ||
    password.includes('\n')
  ) {
    throw new Error(
      'Redis password file must contain exactly one non-empty line',
    )
  }

  return password
}

async function loadCertificateAuthority(
  path: string,
): Promise<string> {
  const certificateAuthority = await readBoundedFile(
    path,
    MAX_CA_FILE_BYTES,
    'Redis certificate authority',
  )

  if (certificateAuthority.trim() === '') {
    throw new Error(
      'Redis certificate authority file must not be empty',
    )
  }

  return certificateAuthority
}

async function readBoundedFile(
  path: string,
  maximumBytes: number,
  description: string,
): Promise<string> {
  let contents: Buffer

  try {
    contents = await readFile(path)
  } catch {
    throw new Error(`load ${description} file failed`)
  }

  if (contents.byteLength > maximumBytes) {
    throw new Error(
      `${description} file exceeds ${maximumBytes} bytes`,
    )
  }

  return contents.toString('utf8')
}
