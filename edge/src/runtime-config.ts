import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  isLoopbackHostname,
  usesSecureTransport,
} from './transport.js'

const DEFAULT_PUBLIC_KEY_FILE = fileURLToPath(
  new URL(
    '../../.shieldward/public.pem',
    import.meta.url,
  ),
)

const DEFAULT_MAX_REQUEST_BODY_BYTES =
  1024 * 1024

const DEFAULT_UPSTREAM_TIMEOUT_MS = 10_000
const DEFAULT_MAX_IN_FLIGHT_REQUESTS = 1_024
const DEFAULT_CIRCUIT_FAILURE_THRESHOLD = 5
const DEFAULT_CIRCUIT_OPEN_MS = 30_000
const DEFAULT_CIRCUIT_MAX_UPSTREAMS = 1_024
const DEFAULT_SHUTDOWN_GRACE_MS = 10_000
const DEFAULT_TLS_RELOAD_INTERVAL_MS = 30_000

const DEFAULT_REDIS_KEY_PREFIX =
  'shieldward:rate-limit:v1'

const REDIS_SETTING_NAMES = [
  'SHIELDWARD_REDIS_URL',
  'SHIELDWARD_REDIS_USERNAME',
  'SHIELDWARD_REDIS_PASSWORD_FILE',
  'SHIELDWARD_REDIS_CA_FILE',
  'SHIELDWARD_REDIS_PREFIX',
  'SHIELDWARD_REDIS_CONNECT_TIMEOUT_MS',
  'SHIELDWARD_REDIS_COMMAND_TIMEOUT_MS',
] as const

export type RuntimeEnvironment = Readonly<
  Record<string, string | undefined>
>

export interface RuntimeConfiguration {
  readonly hostname: string
  readonly port: number
  readonly controlPlaneUrl: string
  readonly publicKeyFile: string
  readonly maxRequestBodyBytes: number
  readonly upstreamTimeoutMs: number
  readonly maxInFlightRequests: number
  readonly circuitFailureThreshold: number
  readonly circuitOpenDurationMs: number
  readonly circuitMaximumUpstreams: number
  readonly shutdownGracePeriodMs: number
  readonly tls: TlsRuntimeConfiguration | undefined
  readonly controlPlaneTls:
    | MutualTlsRuntimeConfiguration
    | undefined
  readonly tlsReloadIntervalMs: number
  readonly rateLimit: RateLimitRuntimeConfiguration
}

export interface TlsRuntimeConfiguration {
  readonly certificateFile: string
  readonly privateKeyFile: string
}

export interface MutualTlsRuntimeConfiguration
  extends TlsRuntimeConfiguration {
  readonly certificateAuthorityFile: string
}

export type RateLimitRuntimeConfiguration =
  | {
      readonly backend: 'memory'
    }
  | RedisRateLimitRuntimeConfiguration

export interface RedisRateLimitRuntimeConfiguration {
  readonly backend: 'redis'
  readonly url: string
  readonly username: string | undefined
  readonly passwordFile: string | undefined
  readonly certificateAuthorityFile:
    | string
    | undefined
  readonly keyPrefix: string
  readonly connectTimeoutMs: number
  readonly commandTimeoutMs: number
}

export class RuntimeConfigurationError
  extends Error
{
  constructor(message: string) {
    super(message)
    this.name = 'RuntimeConfigurationError'
  }
}

export function readRuntimeConfiguration(
  environment: RuntimeEnvironment = process.env,
): RuntimeConfiguration {
  const hostname =
    environment.HOST?.trim() || '127.0.0.1'

  const port = parsePositiveInteger(
    environment.PORT,
    8787,
    'PORT',
    65_535,
  )

  const controlPlaneUrl = parseControlPlaneUrl(
    environment.CONTROL_PLANE_URL ??
      'http://127.0.0.1:18080',
  )

  const publicKeyFile = parsePublicKeyFile(
    environment.SHIELDWARD_PUBLIC_KEY_FILE,
  )

  const tls = parseTlsConfiguration(environment)
  const controlPlaneTls =
    parseControlPlaneTlsConfiguration(
      environment,
      controlPlaneUrl,
    )

  if (
    tls === undefined &&
    !isLoopbackHostname(hostname)
  ) {
    throw new RuntimeConfigurationError(
      'TLS certificate and key are required when HOST is not loopback',
    )
  }

  const maxRequestBodyBytes =
    parsePositiveInteger(
      environment.MAX_REQUEST_BODY_BYTES,
      DEFAULT_MAX_REQUEST_BODY_BYTES,
      'MAX_REQUEST_BODY_BYTES',
      Number.MAX_SAFE_INTEGER,
    )

  const upstreamTimeoutMs = parsePositiveInteger(
    environment.SHIELDWARD_UPSTREAM_TIMEOUT_MS,
    DEFAULT_UPSTREAM_TIMEOUT_MS,
    'SHIELDWARD_UPSTREAM_TIMEOUT_MS',
    120_000,
  )

  const maxInFlightRequests = parsePositiveInteger(
    environment.SHIELDWARD_MAX_IN_FLIGHT_REQUESTS,
    DEFAULT_MAX_IN_FLIGHT_REQUESTS,
    'SHIELDWARD_MAX_IN_FLIGHT_REQUESTS',
    100_000,
  )

  const circuitFailureThreshold = parsePositiveInteger(
    environment.SHIELDWARD_CIRCUIT_FAILURE_THRESHOLD,
    DEFAULT_CIRCUIT_FAILURE_THRESHOLD,
    'SHIELDWARD_CIRCUIT_FAILURE_THRESHOLD',
    100,
  )

  const circuitOpenDurationMs = parsePositiveInteger(
    environment.SHIELDWARD_CIRCUIT_OPEN_MS,
    DEFAULT_CIRCUIT_OPEN_MS,
    'SHIELDWARD_CIRCUIT_OPEN_MS',
    300_000,
  )

  const circuitMaximumUpstreams = parsePositiveInteger(
    environment.SHIELDWARD_CIRCUIT_MAX_UPSTREAMS,
    DEFAULT_CIRCUIT_MAX_UPSTREAMS,
    'SHIELDWARD_CIRCUIT_MAX_UPSTREAMS',
    100_000,
  )

  const shutdownGracePeriodMs = parsePositiveInteger(
    environment.SHIELDWARD_SHUTDOWN_GRACE_MS,
    DEFAULT_SHUTDOWN_GRACE_MS,
    'SHIELDWARD_SHUTDOWN_GRACE_MS',
    120_000,
  )

  const tlsReloadIntervalMs = parsePositiveInteger(
    environment.SHIELDWARD_TLS_RELOAD_INTERVAL_MS,
    DEFAULT_TLS_RELOAD_INTERVAL_MS,
    'SHIELDWARD_TLS_RELOAD_INTERVAL_MS',
    300_000,
  )

  const rateLimit = parseRateLimitConfiguration(
    environment,
  )

  return {
    hostname,
    port,
    controlPlaneUrl,
    publicKeyFile,
    maxRequestBodyBytes,
    upstreamTimeoutMs,
    maxInFlightRequests,
    circuitFailureThreshold,
    circuitOpenDurationMs,
    circuitMaximumUpstreams,
    shutdownGracePeriodMs,
    tls,
    controlPlaneTls,
    tlsReloadIntervalMs,
    rateLimit,
  }
}

function parseControlPlaneTlsConfiguration(
  environment: RuntimeEnvironment,
  controlPlaneUrl: string,
): MutualTlsRuntimeConfiguration | undefined {
  const certificateAuthorityFile = parseOptionalPath(
    environment.SHIELDWARD_CONTROL_PLANE_CA_FILE,
    'SHIELDWARD_CONTROL_PLANE_CA_FILE',
  )
  const certificateFile = parseOptionalPath(
    environment.SHIELDWARD_CONTROL_PLANE_CLIENT_CERT_FILE,
    'SHIELDWARD_CONTROL_PLANE_CLIENT_CERT_FILE',
  )
  const privateKeyFile = parseOptionalPath(
    environment.SHIELDWARD_CONTROL_PLANE_CLIENT_KEY_FILE,
    'SHIELDWARD_CONTROL_PLANE_CLIENT_KEY_FILE',
  )
  const configured = [
    certificateAuthorityFile,
    certificateFile,
    privateKeyFile,
  ].filter((value) => value !== undefined).length
  const secure =
    new URL(controlPlaneUrl).protocol === 'https:'

  if (configured === 0) {
    if (secure) {
      throw new RuntimeConfigurationError(
        'control-plane mutual TLS files are required for HTTPS',
      )
    }

    return undefined
  }

  if (configured !== 3) {
    throw new RuntimeConfigurationError(
      'SHIELDWARD_CONTROL_PLANE_CA_FILE, SHIELDWARD_CONTROL_PLANE_CLIENT_CERT_FILE, and SHIELDWARD_CONTROL_PLANE_CLIENT_KEY_FILE must be configured together',
    )
  }

  if (!secure) {
    throw new RuntimeConfigurationError(
      'control-plane mutual TLS files require an HTTPS CONTROL_PLANE_URL',
    )
  }

  return {
    certificateAuthorityFile:
      certificateAuthorityFile!,
    certificateFile: certificateFile!,
    privateKeyFile: privateKeyFile!,
  }
}

function parseRateLimitConfiguration(
  environment: RuntimeEnvironment,
): RateLimitRuntimeConfiguration {
  if (
    environment.SHIELDWARD_REDIS_PASSWORD !==
    undefined
  ) {
    throw new RuntimeConfigurationError(
      'SHIELDWARD_REDIS_PASSWORD is not supported; use SHIELDWARD_REDIS_PASSWORD_FILE',
    )
  }

  const backend = (
    environment.SHIELDWARD_RATE_LIMIT_BACKEND ??
    'memory'
  )
    .trim()
    .toLowerCase()

  if (backend !== 'memory' && backend !== 'redis') {
    throw new RuntimeConfigurationError(
      'SHIELDWARD_RATE_LIMIT_BACKEND must be memory or redis',
    )
  }

  if (backend === 'memory') {
    const ignoredSetting = REDIS_SETTING_NAMES.find(
      (name) => environment[name] !== undefined,
    )

    if (ignoredSetting !== undefined) {
      throw new RuntimeConfigurationError(
        `${ignoredSetting} requires SHIELDWARD_RATE_LIMIT_BACKEND=redis`,
      )
    }

    return {
      backend: 'memory',
    }
  }

  const url = parseRedisUrl(
    environment.SHIELDWARD_REDIS_URL,
  )
  const certificateAuthorityFile =
    parseOptionalPath(
      environment.SHIELDWARD_REDIS_CA_FILE,
      'SHIELDWARD_REDIS_CA_FILE',
    )

  if (
    certificateAuthorityFile !== undefined &&
    new URL(url).protocol !== 'rediss:'
  ) {
    throw new RuntimeConfigurationError(
      'SHIELDWARD_REDIS_CA_FILE requires a rediss URL',
    )
  }

  return {
    backend: 'redis',
    url,
    username: parseOptionalText(
      environment.SHIELDWARD_REDIS_USERNAME,
      'SHIELDWARD_REDIS_USERNAME',
      256,
    ),
    passwordFile: parseOptionalPath(
      environment.SHIELDWARD_REDIS_PASSWORD_FILE,
      'SHIELDWARD_REDIS_PASSWORD_FILE',
    ),
    certificateAuthorityFile,
    keyPrefix: parseRedisKeyPrefix(
      environment.SHIELDWARD_REDIS_PREFIX,
    ),
    connectTimeoutMs: parsePositiveInteger(
      environment.SHIELDWARD_REDIS_CONNECT_TIMEOUT_MS,
      3_000,
      'SHIELDWARD_REDIS_CONNECT_TIMEOUT_MS',
      30_000,
    ),
    commandTimeoutMs: parsePositiveInteger(
      environment.SHIELDWARD_REDIS_COMMAND_TIMEOUT_MS,
      1_000,
      'SHIELDWARD_REDIS_COMMAND_TIMEOUT_MS',
      30_000,
    ),
  }
}

function parseRedisUrl(
  value: string | undefined,
): string {
  if (value === undefined || value.trim() === '') {
    throw new RuntimeConfigurationError(
      'SHIELDWARD_REDIS_URL is required for the Redis rate-limit backend',
    )
  }

  let url: URL

  try {
    url = new URL(value.trim())
  } catch {
    throw new RuntimeConfigurationError(
      'SHIELDWARD_REDIS_URL must be a valid URL',
    )
  }

  if (
    url.protocol !== 'redis:' &&
    url.protocol !== 'rediss:'
  ) {
    throw new RuntimeConfigurationError(
      'SHIELDWARD_REDIS_URL must use redis or rediss',
    )
  }

  if (url.username !== '' || url.password !== '') {
    throw new RuntimeConfigurationError(
      'SHIELDWARD_REDIS_URL must not contain credentials',
    )
  }

  if (url.search !== '' || url.hash !== '') {
    throw new RuntimeConfigurationError(
      'SHIELDWARD_REDIS_URL must not contain a query or fragment',
    )
  }

  if (
    url.protocol === 'redis:' &&
    !isLoopbackHostname(url.hostname)
  ) {
    throw new RuntimeConfigurationError(
      'SHIELDWARD_REDIS_URL must use rediss unless it targets loopback',
    )
  }

  return url.href
}

function parseRedisKeyPrefix(
  value: string | undefined,
): string {
  const prefix =
    value?.trim() || DEFAULT_REDIS_KEY_PREFIX

  if (!/^[A-Za-z0-9:_-]{1,128}$/.test(prefix)) {
    throw new RuntimeConfigurationError(
      'SHIELDWARD_REDIS_PREFIX must contain 1 to 128 letters, numbers, colons, underscores, or hyphens',
    )
  }

  return prefix
}

function parseOptionalText(
  value: string | undefined,
  name: string,
  maximumLength: number,
): string | undefined {
  if (value === undefined) {
    return undefined
  }

  const trimmed = value.trim()

  if (
    trimmed === '' ||
    trimmed.length > maximumLength
  ) {
    throw new RuntimeConfigurationError(
      `${name} must contain 1 to ${maximumLength} characters`,
    )
  }

  return trimmed
}

function parseControlPlaneUrl(
  value: string,
): string {
  let url: URL

  try {
    url = new URL(value.trim())
  } catch {
    throw new RuntimeConfigurationError(
      'CONTROL_PLANE_URL must be a valid URL',
    )
  }

  if (
    url.protocol !== 'http:' &&
    url.protocol !== 'https:'
  ) {
    throw new RuntimeConfigurationError(
      'CONTROL_PLANE_URL must use HTTP or HTTPS',
    )
  }

  if (
    url.username !== '' ||
    url.password !== ''
  ) {
    throw new RuntimeConfigurationError(
      'CONTROL_PLANE_URL must not contain credentials',
    )
  }

  if (!usesSecureTransport(url)) {
    throw new RuntimeConfigurationError(
      'CONTROL_PLANE_URL must use HTTPS unless it targets loopback',
    )
  }

  url.hash = ''

  return url.href
}

function parsePublicKeyFile(
  value: string | undefined,
): string {
  if (value === undefined) {
    return DEFAULT_PUBLIC_KEY_FILE
  }

  const trimmed = value.trim()

  if (trimmed === '') {
    throw new RuntimeConfigurationError(
      'SHIELDWARD_PUBLIC_KEY_FILE must not be empty',
    )
  }

  return resolve(trimmed)
}

function parseTlsConfiguration(
  environment: RuntimeEnvironment,
): TlsRuntimeConfiguration | undefined {
  const certificateFile = parseOptionalPath(
    environment.SHIELDWARD_TLS_CERT_FILE,
    'SHIELDWARD_TLS_CERT_FILE',
  )
  const privateKeyFile = parseOptionalPath(
    environment.SHIELDWARD_TLS_KEY_FILE,
    'SHIELDWARD_TLS_KEY_FILE',
  )

  if (
    certificateFile === undefined &&
    privateKeyFile === undefined
  ) {
    return undefined
  }

  if (
    certificateFile === undefined ||
    privateKeyFile === undefined
  ) {
    throw new RuntimeConfigurationError(
      'SHIELDWARD_TLS_CERT_FILE and SHIELDWARD_TLS_KEY_FILE must be configured together',
    )
  }

  return {
    certificateFile,
    privateKeyFile,
  }
}

function parseOptionalPath(
  value: string | undefined,
  name: string,
): string | undefined {
  if (value === undefined) {
    return undefined
  }

  const trimmed = value.trim()

  if (trimmed === '') {
    throw new RuntimeConfigurationError(
      `${name} must not be empty`,
    )
  }

  return resolve(trimmed)
}

function parsePositiveInteger(
  value: string | undefined,
  fallback: number,
  name: string,
  maximum: number,
): number {
  if (value === undefined) {
    return fallback
  }

  const trimmed = value.trim()

  if (!/^\d+$/.test(trimmed)) {
    throw new RuntimeConfigurationError(
      `${name} must be a positive integer`,
    )
  }

  const parsed = Number(trimmed)

  if (
    !Number.isSafeInteger(parsed) ||
    parsed <= 0 ||
    parsed > maximum
  ) {
    throw new RuntimeConfigurationError(
      `${name} must be between 1 and ${maximum}`,
    )
  }

  return parsed
}
