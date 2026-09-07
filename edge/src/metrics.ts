export type GatewayMetricOutcome =
  | 'allowed'
  | 'denied'
  | 'error'

export type ConfigurationRefreshOutcome =
  | 'updated'
  | 'unchanged'

export interface GatewayMetricRecord {
  readonly outcome: GatewayMetricOutcome
  readonly status: number
  readonly durationMs: number
}

export interface MetricsSnapshot {
  readonly ready: boolean
  readonly policyLoadedAtMilliseconds?: number
}

export interface OperationalMetrics {
  recordGatewayRequest(
    event: GatewayMetricRecord,
  ): void
  recordConfigurationRefresh(
    outcome: ConfigurationRefreshOutcome,
  ): void
  recordConfigurationSyncError(): void
  render(snapshot: MetricsSnapshot): string
}

export interface PrometheusMetricsOptions {
  readonly now?: () => number
}

interface DurationAggregate {
  count: number
  sumSeconds: number
}

const GATEWAY_OUTCOMES: readonly GatewayMetricOutcome[] = [
  'allowed',
  'denied',
  'error',
]

const REFRESH_OUTCOMES: readonly ConfigurationRefreshOutcome[] = [
  'updated',
  'unchanged',
]

export class PrometheusMetrics
  implements OperationalMetrics
{
  readonly #now: () => number
  readonly #startedAtMilliseconds: number
  readonly #gatewayRequests = new Map<string, number>()
  readonly #gatewayDurations = new Map<
    GatewayMetricOutcome,
    DurationAggregate
  >()
  readonly #configurationRefreshes = new Map<
    ConfigurationRefreshOutcome,
    number
  >()

  #scrapes = 0
  #configurationSyncErrors = 0

  constructor(
    options: PrometheusMetricsOptions = {},
  ) {
    this.#now = options.now ?? Date.now
    this.#startedAtMilliseconds = this.#now()

    for (const outcome of GATEWAY_OUTCOMES) {
      this.#gatewayDurations.set(outcome, {
        count: 0,
        sumSeconds: 0,
      })
    }

    for (const outcome of REFRESH_OUTCOMES) {
      this.#configurationRefreshes.set(outcome, 0)
    }
  }

  recordGatewayRequest(
    event: GatewayMetricRecord,
  ): void {
    const status = normalizeStatus(event.status)
    const key = `${event.outcome}\u0000${status}`

    this.#gatewayRequests.set(
      key,
      (this.#gatewayRequests.get(key) ?? 0) + 1,
    )

    const aggregate =
      this.#gatewayDurations.get(event.outcome)

    if (aggregate === undefined) {
      return
    }

    aggregate.count += 1
    aggregate.sumSeconds += normalizeDurationSeconds(
      event.durationMs,
    )
  }

  recordConfigurationRefresh(
    outcome: ConfigurationRefreshOutcome,
  ): void {
    this.#configurationRefreshes.set(
      outcome,
      (this.#configurationRefreshes.get(outcome) ?? 0) + 1,
    )
  }

  recordConfigurationSyncError(): void {
    this.#configurationSyncErrors += 1
  }

  render(snapshot: MetricsSnapshot): string {
    this.#scrapes += 1

    const now = this.#now()
    const lines: string[] = [
      '# HELP shieldward_edge_process_start_time_seconds Start time of the edge process.',
      '# TYPE shieldward_edge_process_start_time_seconds gauge',
      `shieldward_edge_process_start_time_seconds ${formatNumber(this.#startedAtMilliseconds / 1000)}`,
      '# HELP shieldward_edge_process_uptime_seconds Uptime of the edge process.',
      '# TYPE shieldward_edge_process_uptime_seconds gauge',
      `shieldward_edge_process_uptime_seconds ${formatNumber(Math.max(0, now - this.#startedAtMilliseconds) / 1000)}`,
      '# HELP shieldward_edge_ready Whether a verified policy is ready for evaluation.',
      '# TYPE shieldward_edge_ready gauge',
      `shieldward_edge_ready ${snapshot.ready ? 1 : 0}`,
      '# HELP shieldward_edge_policy_age_seconds Age of the active verified policy.',
      '# TYPE shieldward_edge_policy_age_seconds gauge',
      `shieldward_edge_policy_age_seconds ${formatNumber(policyAgeSeconds(snapshot, now))}`,
      '# HELP shieldward_edge_gateway_requests_total Gateway requests grouped by bounded outcome and status.',
      '# TYPE shieldward_edge_gateway_requests_total counter',
    ]

    for (const [key, count] of Array.from(
      this.#gatewayRequests.entries(),
    ).sort(([left], [right]) => left.localeCompare(right))) {
      const [outcome, status] = key.split('\u0000')

      lines.push(
        `shieldward_edge_gateway_requests_total{outcome="${outcome}",status="${status}"} ${count}`,
      )
    }

    lines.push(
      '# HELP shieldward_edge_gateway_request_duration_seconds Gateway request duration by outcome.',
      '# TYPE shieldward_edge_gateway_request_duration_seconds summary',
    )

    for (const outcome of GATEWAY_OUTCOMES) {
      const aggregate = this.#gatewayDurations.get(outcome)!

      lines.push(
        `shieldward_edge_gateway_request_duration_seconds_count{outcome="${outcome}"} ${aggregate.count}`,
        `shieldward_edge_gateway_request_duration_seconds_sum{outcome="${outcome}"} ${formatNumber(aggregate.sumSeconds)}`,
      )
    }

    lines.push(
      '# HELP shieldward_edge_configuration_refresh_total Configuration refresh attempts by result.',
      '# TYPE shieldward_edge_configuration_refresh_total counter',
    )

    for (const outcome of REFRESH_OUTCOMES) {
      lines.push(
        `shieldward_edge_configuration_refresh_total{result="${outcome}"} ${this.#configurationRefreshes.get(outcome) ?? 0}`,
      )
    }

    lines.push(
      '# HELP shieldward_edge_configuration_sync_errors_total Configuration synchronization errors.',
      '# TYPE shieldward_edge_configuration_sync_errors_total counter',
      `shieldward_edge_configuration_sync_errors_total ${this.#configurationSyncErrors}`,
    )

    lines.push(
      '# HELP shieldward_edge_metrics_scrapes_total Successful local metrics scrapes.',
      '# TYPE shieldward_edge_metrics_scrapes_total counter',
      `shieldward_edge_metrics_scrapes_total ${this.#scrapes}`,
      '',
    )

    return lines.join('\n')
  }
}

function normalizeStatus(status: number): string {
  if (
    Number.isSafeInteger(status) &&
    status >= 100 &&
    status <= 599
  ) {
    return String(status)
  }

  return 'unknown'
}

function normalizeDurationSeconds(
  durationMs: number,
): number {
  if (!Number.isFinite(durationMs)) {
    return 0
  }

  return Math.max(0, durationMs) / 1000
}

function policyAgeSeconds(
  snapshot: MetricsSnapshot,
  now: number,
): number {
  const loadedAt =
    snapshot.policyLoadedAtMilliseconds

  if (
    !snapshot.ready ||
    loadedAt === undefined ||
    !Number.isFinite(loadedAt)
  ) {
    return 0
  }

  return Math.max(0, now - loadedAt) / 1000
}

function formatNumber(value: number): string {
  if (!Number.isFinite(value)) {
    return '0'
  }

  return String(value)
}
