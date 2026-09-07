import { describe, expect, it } from 'vitest'

import { PrometheusMetrics } from '../src/metrics.js'

describe('Prometheus operational metrics', () => {
  it('renders bounded request, refresh, and readiness metrics', () => {
    let now = 1_000
    const metrics = new PrometheusMetrics({
      now: () => now,
    })

    metrics.recordGatewayRequest({
      outcome: 'allowed',
      status: 200,
      durationMs: 25,
    })
    metrics.recordGatewayRequest({
      outcome: 'denied',
      status: 403,
      durationMs: 5,
    })
    metrics.recordConfigurationRefresh('updated')
    metrics.recordConfigurationSyncError()

    now = 6_000

    const output = metrics.render({
      ready: true,
      policyLoadedAtMilliseconds: 4_000,
    })

    expect(output).toContain(
      'shieldward_edge_process_uptime_seconds 5',
    )
    expect(output).toContain(
      'shieldward_edge_ready 1',
    )
    expect(output).toContain(
      'shieldward_edge_policy_age_seconds 2',
    )
    expect(output).toContain(
      'shieldward_edge_gateway_requests_total{outcome="allowed",status="200"} 1',
    )
    expect(output).toContain(
      'shieldward_edge_gateway_requests_total{outcome="denied",status="403"} 1',
    )
    expect(output).toContain(
      'shieldward_edge_gateway_request_duration_seconds_sum{outcome="allowed"} 0.025',
    )
    expect(output).toContain(
      'shieldward_edge_configuration_refresh_total{result="updated"} 1',
    )
    expect(output).toContain(
      'shieldward_edge_configuration_sync_errors_total 1',
    )
    expect(output).toContain(
      'shieldward_edge_metrics_scrapes_total 1',
    )
  })

  it('normalizes invalid measurements without leaking arbitrary labels', () => {
    const metrics = new PrometheusMetrics({
      now: () => 1_000,
    })

    metrics.recordGatewayRequest({
      outcome: 'error',
      status: 999,
      durationMs: Number.NaN,
    })

    const output = metrics.render({
      ready: false,
    })

    expect(output).toContain(
      'shieldward_edge_gateway_requests_total{outcome="error",status="unknown"} 1',
    )
    expect(output).toContain(
      'shieldward_edge_gateway_request_duration_seconds_sum{outcome="error"} 0',
    )
    expect(output).toContain(
      'shieldward_edge_ready 0',
    )
    expect(output).not.toContain('NaN')
  })
})
