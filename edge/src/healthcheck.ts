import { readFile } from 'node:fs/promises'
import { request as httpRequest } from 'node:http'
import { request as httpsRequest } from 'node:https'
import { isLoopbackHostname } from './transport.js'

const DEFAULT_HEALTHCHECK_URL =
  'http://127.0.0.1:8787/readyz'
const MAX_CA_FILE_BYTES = 1024 * 1024

async function main(): Promise<void> {
  const target = parseTarget(
    process.env.SHIELDWARD_HEALTHCHECK_URL ??
      DEFAULT_HEALTHCHECK_URL,
  )
  const caPath =
    process.env.SHIELDWARD_HEALTHCHECK_CA_FILE?.trim()
  const certificateAuthority =
    caPath === undefined || caPath === ''
      ? undefined
      : await loadCertificateAuthority(caPath)

  if (
    certificateAuthority !== undefined &&
    target.protocol !== 'https:'
  ) {
    throw new Error(
      'health-check CA requires an HTTPS URL',
    )
  }

  await new Promise<void>((resolve, reject) => {
    const request = (
      target.protocol === 'https:'
        ? httpsRequest
        : httpRequest
    )(
      target,
      {
        method: 'GET',
        headers: {
          Accept: 'application/json',
        },
        ...(certificateAuthority === undefined
          ? {}
          : {
              ca: certificateAuthority,
              minVersion: 'TLSv1.2' as const,
              rejectUnauthorized: true,
            }),
        agent: false,
        signal: AbortSignal.timeout(3_000),
      },
      (response) => {
        response.resume()

        const status = response.statusCode ?? 0
        if (status >= 200 && status < 300) {
          resolve()
          return
        }

        reject(
          new Error(
            `health check returned HTTP ${status}`,
          ),
        )
      },
    )

    request.once('error', reject)
    request.end()
  })
}

function parseTarget(value: string): URL {
  let target: URL

  try {
    target = new URL(value.trim())
  } catch {
    throw new Error(
      'health-check URL must be an absolute HTTP or HTTPS URL',
    )
  }

  if (
    target.protocol !== 'http:' &&
    target.protocol !== 'https:'
  ) {
    throw new Error(
      'health-check URL must use HTTP or HTTPS',
    )
  }

  if (
    target.protocol === 'http:' &&
    !isLoopbackHostname(target.hostname)
  ) {
    throw new Error(
      'health check must use HTTPS unless it targets loopback',
    )
  }

  if (
    target.username !== '' ||
    target.password !== '' ||
    target.hash !== ''
  ) {
    throw new Error(
      'health-check URL must not contain credentials or a fragment',
    )
  }

  return target
}

async function loadCertificateAuthority(
  path: string,
): Promise<Buffer> {
  let contents: Buffer

  try {
    contents = await readFile(path)
  } catch {
    throw new Error(
      'load health-check certificate authority failed',
    )
  }

  if (
    contents.byteLength === 0 ||
    contents.byteLength > MAX_CA_FILE_BYTES
  ) {
    throw new Error(
      'health-check certificate authority has an invalid size',
    )
  }

  return contents
}

void main().catch(() => {
  process.exitCode = 1
})
