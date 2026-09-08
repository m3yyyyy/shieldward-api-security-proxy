import { readFile } from 'node:fs/promises'
import {
  createHash,
  createPrivateKey,
  X509Certificate,
} from 'node:crypto'
import { createSecureContext } from 'node:tls'

import type {
  MutualTlsRuntimeConfiguration,
  TlsRuntimeConfiguration,
} from './runtime-config.js'

const MAX_TLS_FILE_BYTES = 256 * 1024

export interface TlsMaterial {
  readonly certificate: string
  readonly privateKey: string
}

export interface MutualTlsMaterial
  extends TlsMaterial {
  readonly certificateAuthority: string
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

export async function loadMutualTlsMaterial(
  configuration: MutualTlsRuntimeConfiguration,
  fileReader: TlsFileReader = readFile,
): Promise<MutualTlsMaterial> {
  const [material, certificateAuthority] =
    await Promise.all([
      loadTlsMaterial(configuration, fileReader),
      readTlsFile(
        configuration.certificateAuthorityFile,
        'certificate authority',
        fileReader,
      ),
    ])

  if (
    !certificateAuthority.includes(
      '-----BEGIN CERTIFICATE-----',
    )
  ) {
    throw new Error(
      'TLS certificate authority file is not PEM encoded',
    )
  }

  return {
    ...material,
    certificateAuthority,
  }
}

export function validateTlsMaterial(
  material: TlsMaterial | MutualTlsMaterial,
  now: number = Date.now(),
): void {
  try {
    createSecureContext({
      cert: material.certificate,
      key: material.privateKey,
      ...('certificateAuthority' in material
        ? { ca: material.certificateAuthority }
        : {}),
      minVersion: 'TLSv1.2',
    })

    const certificate = new X509Certificate(
      material.certificate,
    )
    const privateKey = createPrivateKey(
      material.privateKey,
    )

    if (!certificate.checkPrivateKey(privateKey)) {
      throw new Error(
        'certificate and private key do not match',
      )
    }

    const validFrom = Date.parse(certificate.validFrom)
    const validTo = Date.parse(certificate.validTo)

    if (
      !Number.isFinite(validFrom) ||
      !Number.isFinite(validTo) ||
      now < validFrom ||
      now > validTo
    ) {
      throw new Error('certificate is not currently valid')
    }

    if ('certificateAuthority' in material) {
      // Parsing here catches malformed trust bundles before they
      // replace the last-known-good connection material.
      new X509Certificate(
        material.certificateAuthority,
      )
    }
  } catch (error) {
    throw new Error(
      `invalid TLS material: ${errorMessage(error)}`,
    )
  }
}

export type TlsReloadResult =
  | 'updated'
  | 'unchanged'

export interface TlsMaterialReloaderOptions<
  Material extends TlsMaterial,
> {
  readonly load: () => Promise<Material>
  readonly validate?: (material: Material) => void
  readonly apply?: (
    material: Material,
  ) => void | Promise<void>
  readonly intervalMs: number
  readonly onReload?: () => void
  readonly onError?: (error: unknown) => void
}

export class TlsMaterialReloader<
  Material extends TlsMaterial,
> {
  readonly #options: TlsMaterialReloaderOptions<Material>

  #current: Readonly<Material> | undefined
  #fingerprint: string | undefined
  #timer: ReturnType<typeof setInterval> | undefined
  #reloadInFlight:
    | Promise<TlsReloadResult>
    | undefined

  constructor(
    options: TlsMaterialReloaderOptions<Material>,
  ) {
    if (
      !Number.isSafeInteger(options.intervalMs) ||
      options.intervalMs <= 0
    ) {
      throw new Error(
        'TLS reload interval must be a positive integer',
      )
    }

    this.#options = options
  }

  async initialize(): Promise<Readonly<Material>> {
    if (this.#current !== undefined) {
      return this.#current
    }

    const material = await this.#options.load()
    this.#options.validate?.(material)
    this.#current = Object.freeze({ ...material })
    this.#fingerprint = fingerprintMaterial(material)
    return this.#current
  }

  current(): Readonly<Material> {
    if (this.#current === undefined) {
      throw new Error(
        'TLS material reloader is not initialized',
      )
    }

    return this.#current
  }

  reload(): Promise<TlsReloadResult> {
    if (this.#reloadInFlight !== undefined) {
      return this.#reloadInFlight
    }

    const operation = this.#reloadOnce()
    this.#reloadInFlight = operation

    void operation.then(
      () => {
        if (this.#reloadInFlight === operation) {
          this.#reloadInFlight = undefined
        }
      },
      () => {
        if (this.#reloadInFlight === operation) {
          this.#reloadInFlight = undefined
        }
      },
    )

    return operation
  }

  start(): void {
    if (this.#timer !== undefined) {
      return
    }

    this.current()

    this.#timer = setInterval(() => {
      void this.reload().catch((error) => {
        try {
          this.#options.onError?.(error)
        } catch {
          // Reload observers must not terminate the process.
        }
      })
    }, this.#options.intervalMs)

    this.#timer.unref()
  }

  stop(): void {
    if (this.#timer === undefined) {
      return
    }

    clearInterval(this.#timer)
    this.#timer = undefined
  }

  async #reloadOnce(): Promise<TlsReloadResult> {
    this.current()

    const material = await this.#options.load()
    this.#options.validate?.(material)
    const fingerprint = fingerprintMaterial(material)

    if (fingerprint === this.#fingerprint) {
      return 'unchanged'
    }

    await this.#options.apply?.(material)

    this.#current = Object.freeze({ ...material })
    this.#fingerprint = fingerprint

    try {
      this.#options.onReload?.()
    } catch {
      // Reload observers must not reject valid material.
    }

    return 'updated'
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

function fingerprintMaterial(
  material: TlsMaterial,
): string {
  const hash = createHash('sha256')

  for (const value of Object.values(material)) {
    hash.update(value, 'utf8')
    hash.update('\u0000', 'utf8')
  }

  return hash.digest('hex')
}
