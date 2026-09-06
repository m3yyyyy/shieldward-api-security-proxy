import { readFile } from 'node:fs/promises'

import type { TlsRuntimeConfiguration } from './runtime-config.js'

const MAX_TLS_FILE_BYTES = 256 * 1024

export interface TlsMaterial {
  readonly certificate: string
  readonly privateKey: string
}

export type TlsFileReader = (
  path: string,
) => Promise<Uint8Array>

export async function loadTlsMaterial(
  configuration: TlsRuntimeConfiguration,
  fileReader: TlsFileReader = readFile,
): Promise<TlsMaterial> {
  const [certificate, privateKey] = await Promise.all([
    readTlsFile(
      configuration.certificateFile,
      'certificate',
      fileReader,
    ),
    readTlsFile(
      configuration.privateKeyFile,
      'private key',
      fileReader,
    ),
  ])

  if (
    !certificate.includes(
      '-----BEGIN CERTIFICATE-----',
    )
  ) {
    throw new Error(
      'TLS certificate file is not PEM encoded',
    )
  }

  if (
    !/-----BEGIN (?:RSA |EC )?PRIVATE KEY-----/.test(
      privateKey,
    )
  ) {
    throw new Error(
      'TLS private key file is not an unencrypted PEM key',
    )
  }

  return {
    certificate,
    privateKey,
  }
}

async function readTlsFile(
  path: string,
  description: string,
  fileReader: TlsFileReader,
): Promise<string> {
  let contents: Uint8Array

  try {
    contents = await fileReader(path)
  } catch (error) {
    throw new Error(
      `load TLS ${description} "${path}": ${errorMessage(error)}`,
    )
  }

  if (contents.byteLength === 0) {
    throw new Error(
      `TLS ${description} file must not be empty`,
    )
  }

  if (contents.byteLength > MAX_TLS_FILE_BYTES) {
    throw new Error(
      `TLS ${description} file exceeds ${MAX_TLS_FILE_BYTES} bytes`,
    )
  }

  return new TextDecoder().decode(contents)
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message
  }

  return String(error)
}
