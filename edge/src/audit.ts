import { randomUUID } from 'node:crypto'

export type SecurityAuditOutcome =
  | 'allowed'
  | 'denied'
  | 'error'

export interface SecurityAuditRecord {
  readonly requestId: string
  readonly method: string
  readonly path: string
  readonly outcome: SecurityAuditOutcome
  readonly status: number
  readonly durationMs: number
  readonly policyVersion?: string
  readonly routeId?: string
  readonly reason?: string
  readonly upstreamStatus?: number
}

export interface SecurityAuditLogger {
  record(event: SecurityAuditRecord): void
}

export interface SecuritySystemAuditRecord {
  readonly component: 'configuration_sync'
  readonly outcome: 'error'
  readonly reason: 'configuration_sync_failed'
}

export interface JsonSecurityAuditLoggerOptions {
  readonly write?: (line: string) => void
  readonly now?: () => Date
}

export class JsonSecurityAuditLogger
  implements SecurityAuditLogger
{
  readonly #write: (line: string) => void
  readonly #now: () => Date

  constructor(
    options: JsonSecurityAuditLoggerOptions = {},
  ) {
    this.#write =
      options.write ?? ((line) => console.log(line))
    this.#now = options.now ?? (() => new Date())
  }

  record(event: SecurityAuditRecord): void {
    const output = {
      type: 'security_request',
      schemaVersion: 1,
      timestamp: this.#now().toISOString(),
      requestId: event.requestId,
      method: event.method,
      path: event.path,
      outcome: event.outcome,
      status: event.status,
      durationMs: event.durationMs,
      ...(event.policyVersion === undefined
        ? {}
        : {
            policyVersion: event.policyVersion,
          }),
      ...(event.routeId === undefined
        ? {}
        : {
            routeId: event.routeId,
          }),
      ...(event.reason === undefined
        ? {}
        : {
            reason: event.reason,
          }),
      ...(event.upstreamStatus === undefined
        ? {}
        : {
            upstreamStatus: event.upstreamStatus,
          }),
    }

    this.#write(JSON.stringify(output))
  }

  recordSystem(event: SecuritySystemAuditRecord): void {
    this.#write(
      JSON.stringify({
        type: 'security_system',
        schemaVersion: 1,
        timestamp: this.#now().toISOString(),
        component: event.component,
        outcome: event.outcome,
        reason: event.reason,
      }),
    )
  }
}

export function createRequestId(): string {
  return randomUUID()
}
