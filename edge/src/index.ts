import { readFile } from 'node:fs/promises'
import { createServer as createHttpsServer } from 'node:https'

import {
  serve,
  type ServerType,
} from '@hono/node-server'
import { getConnInfo } from '@hono/node-server/conninfo'

import { createApp } from './app.js'
import { JsonSecurityAuditLogger } from './audit.js'
import { ConfigurationClient } from './config-client.js'
import { ConfigurationSynchronizer } from './config-sync.js'
import { Gateway } from './gateway.js'
import { LivePolicyEvaluator } from './live-policy.js'
import { PrometheusMetrics } from './metrics.js'
import { MeasuredRateLimiter } from './rate-limit.js'
import {
  createRateLimitRuntime,
  type RateLimitRuntime,
} from './rate-limit-runtime.js'
import { readRuntimeConfiguration } from './runtime-config.js'
import { loadTlsMaterial } from './tls.js'
import { createTrustedKeyring } from './trusted-keys.js'

const MAX_PUBLIC_KEY_FILE_BYTES = 16 * 1024

async function main(): Promise<void> {
  const runtime = readRuntimeConfiguration()

  const publicKeyPem = await loadPublicKey(
    runtime.publicKeyFile,
  )
  const tlsMaterial =
    runtime.tls === undefined
      ? undefined
      : await loadTlsMaterial(runtime.tls)

  const trustedKeys = createTrustedKeyring([
    publicKeyPem,
  ])

  const configuration = new ConfigurationClient({
    baseUrl: runtime.controlPlaneUrl,
    trustedKeys,
  })
  const auditLogger = new JsonSecurityAuditLogger()
  const metrics = new PrometheusMetrics()
  const rateLimitRuntime =
    await createRateLimitRuntime(
      runtime.rateLimit,
    )

  const synchronizer =
    new ConfigurationSynchronizer({
      baseUrl: runtime.controlPlaneUrl,
      client: configuration,
      onError: (error) => {
        metrics.recordConfigurationSyncError()

        try {
          auditLogger.recordSystem({
            component: 'configuration_sync',
            outcome: 'error',
            reason: 'configuration_sync_failed',
          })
        } catch {
          // Audit failures must not stop synchronization.
        }

        console.error(
          `Configuration synchronization error: ${errorMessage(error)}`,
        )
      },
      onRefresh: (result) => {
        metrics.recordConfigurationRefresh(
          result.status,
        )
      },
    })

  let initial: Awaited<
    ReturnType<ConfigurationSynchronizer['start']>
  >

  try {
    initial = await synchronizer.start()
  } catch (error) {
    await rateLimitRuntime.close()
    throw error
  }

  const policyEvaluator = new LivePolicyEvaluator({
    configuration,
    rateLimiter: new MeasuredRateLimiter(
      rateLimitRuntime.limiter,
      rateLimitRuntime.backend,
      metrics,
    ),
  })

  const gateway = new Gateway({
    policyEvaluator,
    auditLogger,
    metrics,
    maxRequestBodyBytes:
      runtime.maxRequestBodyBytes,
    upstreamTimeoutMs:
      runtime.upstreamTimeoutMs,
    maxInFlightRequests:
      runtime.maxInFlightRequests,
  })

  const application = createApp({
    gateway,
    configuration,
    metrics,
    rateLimiter: rateLimitRuntime,
    secureTransport: tlsMaterial !== undefined,
    resolveClientIp: (context) =>
      getConnInfo(context).remote.address,
  })

  const server = serve(
    {
      fetch: application.fetch,
      hostname: runtime.hostname,
      port: runtime.port,
      ...(tlsMaterial === undefined
        ? {}
        : {
            createServer: createHttpsServer,
            serverOptions: {
              cert: tlsMaterial.certificate,
              key: tlsMaterial.privateKey,
              minVersion: 'TLSv1.2' as const,
            },
          }),
    },
    ({ port }) => {
      console.log(
        `ShieldWard edge listening on ${tlsMaterial === undefined ? 'http' : 'https'}://${runtime.hostname}:${port}`,
      )
      console.log(
        `Verified policy ${initial.snapshot.bundle.version}`,
      )
      console.log(
        `Trusted key ${Array.from(trustedKeys.keys()).join(', ')}`,
      )
      console.log(
        `Rate-limit backend ${rateLimitRuntime.backend}`,
      )
    },
  )

  installShutdownHandlers(
    server,
    synchronizer,
    rateLimitRuntime,
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
  rateLimitRuntime: RateLimitRuntime,
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

    await stopDependencies(
      synchronizer,
      rateLimitRuntime,
    )

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
    void stopDependencies(
      synchronizer,
      rateLimitRuntime,
    )
  })
}

async function stopDependencies(
  synchronizer: ConfigurationSynchronizer,
  rateLimitRuntime: RateLimitRuntime,
): Promise<void> {
  const results = await Promise.allSettled([
    synchronizer.stop(),
    rateLimitRuntime.close(),
  ])

  for (const result of results) {
    if (result.status === 'rejected') {
      console.error(errorMessage(result.reason))
      process.exitCode = 1
    }
  }
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
