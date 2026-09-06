import { readFile } from 'node:fs/promises'

import {
  serve,
  type ServerType,
} from '@hono/node-server'
import { getConnInfo } from '@hono/node-server/conninfo'

import { createApp } from './app.js'
import { ConfigurationClient } from './config-client.js'
import { ConfigurationSynchronizer } from './config-sync.js'
import { Gateway } from './gateway.js'
import { LivePolicyEvaluator } from './live-policy.js'
import { readRuntimeConfiguration } from './runtime-config.js'
import { createTrustedKeyring } from './trusted-keys.js'

const MAX_PUBLIC_KEY_FILE_BYTES = 16 * 1024

async function main(): Promise<void> {
  const runtime = readRuntimeConfiguration()

  const publicKeyPem = await loadPublicKey(
    runtime.publicKeyFile,
  )

  const trustedKeys = createTrustedKeyring([
    publicKeyPem,
  ])

  const configuration = new ConfigurationClient({
    baseUrl: runtime.controlPlaneUrl,
    trustedKeys,
  })

  const synchronizer =
    new ConfigurationSynchronizer({
      baseUrl: runtime.controlPlaneUrl,
      client: configuration,
      onError: (error) => {
        console.error(
          `Configuration synchronization error: ${errorMessage(error)}`,
        )
      },
    })

  const initial = await synchronizer.start()

  const policyEvaluator = new LivePolicyEvaluator({
    configuration,
  })

  const gateway = new Gateway({
    policyEvaluator,
    maxRequestBodyBytes:
      runtime.maxRequestBodyBytes,
  })

  const application = createApp({
    gateway,
    configuration,
    resolveClientIp: (context) =>
      getConnInfo(context).remote.address,
  })

  const server = serve(
    {
      fetch: application.fetch,
      hostname: runtime.hostname,
      port: runtime.port,
    },
    ({ port }) => {
      console.log(
        `ShieldWard edge listening on http://${runtime.hostname}:${port}`,
      )
      console.log(
        `Verified policy ${initial.snapshot.bundle.version}`,
      )
      console.log(
        `Trusted key ${Array.from(trustedKeys.keys()).join(', ')}`,
      )
    },
  )

  installShutdownHandlers(
    server,
    synchronizer,
  )
}

async function loadPublicKey(
  path: string,
): Promise<string> {
  let contents: Buffer

  try {
    contents = await readFile(path)
  } catch (error) {
    throw new Error(
      `load trusted public key "${path}": ${errorMessage(error)}`,
    )
  }

  if (
    contents.byteLength >
    MAX_PUBLIC_KEY_FILE_BYTES
  ) {
    throw new Error(
      `trusted public key file exceeds ${MAX_PUBLIC_KEY_FILE_BYTES} bytes`,
    )
  }

  return contents.toString('utf8')
}

function installShutdownHandlers(
  server: ServerType,
  synchronizer: ConfigurationSynchronizer,
): void {
  let shuttingDown = false

  const shutdown = async (
    signal: string,
  ): Promise<void> => {
    if (shuttingDown) {
      return
    }

    shuttingDown = true

    console.log(
      `Received ${signal}; shutting down`,
    )

    await synchronizer.stop()

    server.close((error) => {
      if (error !== undefined) {
        console.error(
          `Edge shutdown error: ${error.message}`,
        )
        process.exitCode = 1
        return
      }

      console.log('ShieldWard edge shutdown complete')
    })
  }

  process.once('SIGINT', () => {
    void shutdown('SIGINT').catch((error) => {
      console.error(errorMessage(error))
      process.exitCode = 1
    })
  })

  process.once('SIGTERM', () => {
    void shutdown('SIGTERM').catch((error) => {
      console.error(errorMessage(error))
      process.exitCode = 1
    })
  })

  server.once('error', (error) => {
    console.error(
      `ShieldWard edge server error: ${error.message}`,
    )
    process.exitCode = 1
    void synchronizer.stop()
  })
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message
  }

  return String(error)
}

void main().catch((error) => {
  console.error(
    `ShieldWard edge failed to start: ${errorMessage(error)}`,
  )
  process.exitCode = 1
})