import { describe, expect, it, vi } from 'vitest'

import {
  loadTlsMaterial,
  type TlsFileReader,
} from '../src/tls.js'

const configuration = {
  certificateFile: 'tls/certificate.pem',
  privateKeyFile: 'tls/private-key.pem',
}

describe('TLS material loading', () => {
  it('loads a PEM certificate and private key', async () => {
    const read = vi.fn<TlsFileReader>(async (path) =>
      new TextEncoder().encode(
        path === configuration.certificateFile
          ? '-----BEGIN CERTIFICATE-----\ncertificate\n-----END CERTIFICATE-----\n'
          : '-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n',
      ),
    )

    const material = await loadTlsMaterial(
      configuration,
      read,
    )

    expect(material.certificate).toContain(
      'BEGIN CERTIFICATE',
    )
    expect(material.privateKey).toContain(
      'BEGIN PRIVATE KEY',
    )
    expect(read).toHaveBeenCalledTimes(2)
  })

  it('reports file loading failures without file contents', async () => {
    await expect(
      loadTlsMaterial(configuration, async () => {
        throw new Error('access denied')
      }),
    ).rejects.toThrow('access denied')
  })

  it('rejects oversized TLS files', async () => {
    await expect(
      loadTlsMaterial(
        configuration,
        async (path) =>
          path === configuration.certificateFile
            ? new Uint8Array(256 * 1024 + 1)
            : new TextEncoder().encode(
                '-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n',
              ),
      ),
    ).rejects.toThrow(
      'TLS certificate file exceeds 262144 bytes',
    )
  })

  it('rejects malformed certificate material', async () => {
    await expect(
      loadTlsMaterial(
        configuration,
        async (path) =>
          new TextEncoder().encode(
            path === configuration.certificateFile
              ? 'not a certificate'
              : '-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n',
          ),
      ),
    ).rejects.toThrow(
      'TLS certificate file is not PEM encoded',
    )
  })

  it('rejects encrypted private key material', async () => {
    await expect(
      loadTlsMaterial(
        configuration,
        async (path) =>
          new TextEncoder().encode(
            path === configuration.certificateFile
              ? '-----BEGIN CERTIFICATE-----\ncertificate\n-----END CERTIFICATE-----\n'
              : '-----BEGIN ENCRYPTED PRIVATE KEY-----\nkey\n-----END ENCRYPTED PRIVATE KEY-----\n',
          ),
      ),
    ).rejects.toThrow(
      'TLS private key file is not an unencrypted PEM key',
    )
  })
})
