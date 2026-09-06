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
    })
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