import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const DEFAULT_PUBLIC_KEY_FILE = fileURLToPath(
  new URL(
    '../../.shieldward/public.pem',
    import.meta.url,
  ),
)

const DEFAULT_MAX_REQUEST_BODY_BYTES =
  1024 * 1024

export type RuntimeEnvironment = Readonly<
  Record<string, string | undefined>
>

export interface RuntimeConfiguration {
  readonly hostname: string
  readonly port: number
  readonly controlPlaneUrl: string
  readonly publicKeyFile: string
  readonly maxRequestBodyBytes: number
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

  const maxRequestBodyBytes =
    parsePositiveInteger(
      environment.MAX_REQUEST_BODY_BYTES,
      DEFAULT_MAX_REQUEST_BODY_BYTES,
      'MAX_REQUEST_BODY_BYTES',
      Number.MAX_SAFE_INTEGER,
    )

  return {
    hostname,
    port,
    controlPlaneUrl,
    publicKeyFile,
    maxRequestBodyBytes,
  }
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