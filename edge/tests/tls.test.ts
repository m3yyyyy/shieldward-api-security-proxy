import { describe, expect, it, vi } from 'vitest'

import {
  loadMutualTlsMaterial,
  loadTlsMaterial,
  TlsMaterialReloader,
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

  it('loads a mutual TLS trust bundle and client identity together', async () => {
    const material = await loadMutualTlsMaterial(
      {
        ...configuration,
        certificateAuthorityFile: 'tls/ca.pem',
      },
      async (path) =>
        new TextEncoder().encode(
          path === 'tls/ca.pem'
            ? '-----BEGIN CERTIFICATE-----\nauthority\n-----END CERTIFICATE-----\n'
            : path === configuration.certificateFile
              ? '-----BEGIN CERTIFICATE-----\ncertificate\n-----END CERTIFICATE-----\n'
              : '-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n',
        ),
    )

    expect(material.certificateAuthority).toContain(
      'authority',
    )
    expect(material.certificate).toContain(
      'certificate',
    )
  })

  it('atomically retains last-known-good material when rotation is rejected', async () => {
    const materials = [
      {
        certificate: 'certificate-one',
        privateKey: 'key-one',
      },
      {
        certificate: 'certificate-two',
        privateKey: 'key-two',
      },
      {
        certificate: 'invalid-certificate',
        privateKey: 'key-three',
      },
    ]
    const apply = vi.fn()
    const onReload = vi.fn()
    const reloader = new TlsMaterialReloader({
      load: async () => materials.shift()!,
      validate: (material) => {
        if (material.certificate.startsWith('invalid')) {
          throw new Error('rejected candidate')
        }
      },
      apply,
      intervalMs: 1_000,
      onReload,
    })

    await reloader.initialize()
    await expect(reloader.reload()).resolves.toBe(
      'updated',
    )
    expect(reloader.current().certificate).toBe(
      'certificate-two',
    )
    expect(apply).toHaveBeenCalledTimes(1)
    expect(onReload).toHaveBeenCalledTimes(1)

    await expect(reloader.reload()).rejects.toThrow(
      'rejected candidate',
    )
    expect(reloader.current().certificate).toBe(
      'certificate-two',
    )
    expect(apply).toHaveBeenCalledTimes(1)
  })
})
