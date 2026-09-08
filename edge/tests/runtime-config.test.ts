import {
  isAbsolute,
  join,
  resolve,
} from 'node:path'

import { describe, expect, it } from 'vitest'

import {
  readRuntimeConfiguration,
  RuntimeConfigurationError,
} from '../src/runtime-config.js'

describe('runtime configuration', () => {
  it('uses safe local defaults', () => {
    const configuration =
      readRuntimeConfiguration({})

    expect(configuration.hostname).toBe(
      '127.0.0.1',
    )
    expect(configuration.port).toBe(8787)
    expect(configuration.controlPlaneUrl).toBe(
      'http://127.0.0.1:18080/',
    )
    expect(
      configuration.maxRequestBodyBytes,
    ).toBe(1024 * 1024)
    expect(configuration.upstreamTimeoutMs).toBe(
      10_000,
    )
    expect(
      configuration.maxInFlightRequests,
    ).toBe(1_024)
    expect(configuration.tls).toBeUndefined()
    expect(configuration.rateLimit).toEqual({
      backend: 'memory',
    })

    expect(
      isAbsolute(configuration.publicKeyFile),
    ).toBe(true)

    expect(
      configuration.publicKeyFile.endsWith(
        join('.shieldward', 'public.pem'),
      ),
    ).toBe(true)
  })

  it('accepts explicit settings', () => {
    const configuration =
      readRuntimeConfiguration({
        HOST: ' 0.0.0.0 ',
        PORT: '9090',
        CONTROL_PLANE_URL:
          'https://control.example/base#ignored',
        SHIELDWARD_PUBLIC_KEY_FILE:
          'keys/public.pem',
        MAX_REQUEST_BODY_BYTES: '2048',
        SHIELDWARD_UPSTREAM_TIMEOUT_MS: '25000',
        SHIELDWARD_MAX_IN_FLIGHT_REQUESTS: '200',
        SHIELDWARD_TLS_CERT_FILE:
          'keys/tls-cert.pem',
        SHIELDWARD_TLS_KEY_FILE:
          'keys/tls-key.pem',
      })

    expect(configuration).toEqual({
      hostname: '0.0.0.0',
      port: 9090,
      controlPlaneUrl:
        'https://control.example/base',
      publicKeyFile: resolve(
        'keys/public.pem',
      ),
      maxRequestBodyBytes: 2048,
      upstreamTimeoutMs: 25_000,
      maxInFlightRequests: 200,
      tls: {
        certificateFile: resolve(
          'keys/tls-cert.pem',
        ),
        privateKeyFile: resolve(
          'keys/tls-key.pem',
        ),
      },
      rateLimit: {
        backend: 'memory',
      },
    })
  })

  it('accepts secure Redis rate-limit settings', () => {
    const configuration =
      readRuntimeConfiguration({
        SHIELDWARD_RATE_LIMIT_BACKEND: 'redis',
        SHIELDWARD_REDIS_URL:
          'rediss://redis.example:6380/2',
        SHIELDWARD_REDIS_USERNAME: 'edge',
        SHIELDWARD_REDIS_PASSWORD_FILE:
          'secrets/redis-password',
        SHIELDWARD_REDIS_CA_FILE:
          'secrets/redis-ca.pem',
        SHIELDWARD_REDIS_PREFIX:
          'shieldward:test',
        SHIELDWARD_REDIS_CONNECT_TIMEOUT_MS:
          '2500',
        SHIELDWARD_REDIS_COMMAND_TIMEOUT_MS:
          '750',
      })

    expect(configuration.rateLimit).toEqual({
      backend: 'redis',
      url: 'rediss://redis.example:6380/2',
      username: 'edge',
      passwordFile: resolve(
        'secrets/redis-password',
      ),
      certificateAuthorityFile: resolve(
        'secrets/redis-ca.pem',
      ),
      keyPrefix: 'shieldward:test',
      connectTimeoutMs: 2500,
      commandTimeoutMs: 750,
    })
  })

  it('permits cleartext Redis only on loopback', () => {
    const configuration =
      readRuntimeConfiguration({
        SHIELDWARD_RATE_LIMIT_BACKEND: 'redis',
        SHIELDWARD_REDIS_URL:
          'redis://127.0.0.1:6379',
      })

    expect(configuration.rateLimit).toMatchObject({
      backend: 'redis',
      url: 'redis://127.0.0.1:6379',
    })

    expect(() =>
      readRuntimeConfiguration({
        SHIELDWARD_RATE_LIMIT_BACKEND: 'redis',
        SHIELDWARD_REDIS_URL:
          'redis://redis.internal:6379',
      }),
    ).toThrow(
      'SHIELDWARD_REDIS_URL must use rediss unless it targets loopback',
    )
  })

  it('rejects Redis credentials in URLs or plaintext environment values', () => {
    expect(() =>
      readRuntimeConfiguration({
        SHIELDWARD_RATE_LIMIT_BACKEND: 'redis',
        SHIELDWARD_REDIS_URL:
          'rediss://user:secret@redis.example',
      }),
    ).toThrow(
      'SHIELDWARD_REDIS_URL must not contain credentials',
    )

    expect(() =>
      readRuntimeConfiguration({
        SHIELDWARD_REDIS_PASSWORD: 'secret',
      }),
    ).toThrow(
      'SHIELDWARD_REDIS_PASSWORD is not supported',
    )
  })

  it('rejects inactive or incomplete Redis settings', () => {
    expect(() =>
      readRuntimeConfiguration({
        SHIELDWARD_REDIS_URL:
          'redis://127.0.0.1:6379',
      }),
    ).toThrow(
      'SHIELDWARD_REDIS_URL requires SHIELDWARD_RATE_LIMIT_BACKEND=redis',
    )

    expect(() =>
      readRuntimeConfiguration({
        SHIELDWARD_RATE_LIMIT_BACKEND: 'redis',
      }),
    ).toThrow(
      'SHIELDWARD_REDIS_URL is required',
    )
  })

  it('rejects invalid numeric settings', () => {
    expect(() =>
      readRuntimeConfiguration({
        PORT: '0',
      }),
    ).toThrow(RuntimeConfigurationError)

    expect(() =>
      readRuntimeConfiguration({
        PORT: '65536',
      }),
    ).toThrow(
      'PORT must be between 1 and 65535',
    )

    expect(() =>
      readRuntimeConfiguration({
        MAX_REQUEST_BODY_BYTES: '1.5',
      }),
    ).toThrow(
      'MAX_REQUEST_BODY_BYTES must be a positive integer',
    )

    expect(() =>
      readRuntimeConfiguration({
        SHIELDWARD_UPSTREAM_TIMEOUT_MS: '120001',
      }),
    ).toThrow(
      'SHIELDWARD_UPSTREAM_TIMEOUT_MS must be between 1 and 120000',
    )

    expect(() =>
      readRuntimeConfiguration({
        SHIELDWARD_MAX_IN_FLIGHT_REQUESTS: '0',
      }),
    ).toThrow(
      'SHIELDWARD_MAX_IN_FLIGHT_REQUESTS must be between 1 and 100000',
    )
  })

  it('rejects unsafe control-plane URLs', () => {
    expect(() =>
      readRuntimeConfiguration({
        CONTROL_PLANE_URL:
          'file:///tmp/control-plane',
      }),
    ).toThrow(
      'CONTROL_PLANE_URL must use HTTP or HTTPS',
    )

    expect(() =>
      readRuntimeConfiguration({
        CONTROL_PLANE_URL:
          'https://user:password@control.example',
      }),
    ).toThrow(
      'CONTROL_PLANE_URL must not contain credentials',
    )

    expect(() =>
      readRuntimeConfiguration({
        CONTROL_PLANE_URL:
          'http://control.example',
      }),
    ).toThrow(
      'CONTROL_PLANE_URL must use HTTPS unless it targets loopback',
    )
  })

  it('requires TLS when listening beyond loopback', () => {
    expect(() =>
      readRuntimeConfiguration({
        HOST: '0.0.0.0',
      }),
    ).toThrow(
      'TLS certificate and key are required when HOST is not loopback',
    )
  })

  it('requires both TLS files together', () => {
    expect(() =>
      readRuntimeConfiguration({
        SHIELDWARD_TLS_CERT_FILE:
          'keys/tls-cert.pem',
      }),
    ).toThrow(
      'SHIELDWARD_TLS_CERT_FILE and SHIELDWARD_TLS_KEY_FILE must be configured together',
    )

    expect(() =>
      readRuntimeConfiguration({
        SHIELDWARD_TLS_CERT_FILE: '   ',
        SHIELDWARD_TLS_KEY_FILE:
          'keys/tls-key.pem',
      }),
    ).toThrow(
      'SHIELDWARD_TLS_CERT_FILE must not be empty',
    )
  })

  it('rejects an explicitly empty key path', () => {
    expect(() =>
      readRuntimeConfiguration({
        SHIELDWARD_PUBLIC_KEY_FILE: '   ',
      }),
    ).toThrow(
      'SHIELDWARD_PUBLIC_KEY_FILE must not be empty',
    )
  })
})
