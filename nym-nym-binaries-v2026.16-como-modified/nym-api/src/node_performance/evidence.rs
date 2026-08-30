// Copyright 2026 - Nym Technologies SA <contact@nymtech.net>
// SPDX-License-Identifier: GPL-3.0-only

use nym_api_requests::models::SelectionPerformanceSummary;

pub(crate) const HISTORY_EPOCHS: u32 = 16;
const HISTORY_HALF_LIFE_EPOCHS: f64 = 4.0;
const FRESHNESS_HALF_LIFE_EPOCHS: f64 = 2.0;

#[derive(Debug, Clone, Copy)]
pub(crate) struct PerformanceSample {
    pub(crate) epoch_id: u32,
    pub(crate) performance: f64,
}

pub(crate) fn first_history_epoch(current_epoch: u32) -> u32 {
    current_epoch.saturating_sub(HISTORY_EPOCHS - 1)
}

pub(crate) fn summarise_performance(
    current_epoch: u32,
    samples: &[PerformanceSample],
) -> Option<SelectionPerformanceSummary> {
    let valid_samples = samples
        .iter()
        .filter(|sample| sample.epoch_id <= current_epoch && sample.performance.is_finite())
        .map(|sample| {
            let age = current_epoch - sample.epoch_id;
            let weight = 2.0_f64.powf(-(age as f64) / HISTORY_HALF_LIFE_EPOCHS);
            (sample, weight, sample.performance.clamp(0.0, 1.0))
        })
        .collect::<Vec<_>>();

    if valid_samples.is_empty() {
        return None;
    }

    let sum_w = valid_samples.iter().map(|(_, weight, _)| weight).sum::<f64>();
    let sum_w2 = valid_samples
        .iter()
        .map(|(_, weight, _)| weight * weight)
        .sum::<f64>();
    let sum_wx = valid_samples
        .iter()
        .map(|(_, weight, value)| weight * value)
        .sum::<f64>();

    if sum_w <= 0.0 || !sum_w.is_finite() || !sum_w2.is_finite() || !sum_wx.is_finite() {
        return None;
    }

    let mean = sum_wx / sum_w;
    let weighted_squared_deviation = valid_samples
        .iter()
        .map(|(_, weight, value)| {
            let difference = value - mean;
            weight * difference * difference
        })
        .sum::<f64>();
    let variance = weighted_squared_deviation / sum_w;
    let weighted_stddev = variance.max(0.0).sqrt();
    let effective_samples = ((sum_w * sum_w) / sum_w2.max(f64::EPSILON))
        .floor()
        .max(1.0) as u32;
    let newest_epoch = valid_samples
        .iter()
        .map(|(sample, _, _)| sample.epoch_id)
        .max()?;

    Some(SelectionPerformanceSummary {
        weighted_mean: mean.clamp(0.0, 1.0),
        weighted_stddev: weighted_stddev.clamp(0.0, 1.0),
        effective_samples,
        newest_epoch,
    })
}

pub(crate) fn conservative_quality(summary: &SelectionPerformanceSummary) -> f64 {
    if !summary.weighted_mean.is_finite() || !summary.weighted_stddev.is_finite() {
        return 0.0;
    }

    let sample_count = summary.effective_samples.max(1) as f64;
    (summary.weighted_mean - 1.645 * summary.weighted_stddev / sample_count.sqrt()).clamp(0.0, 1.0)
}

pub(crate) fn evidence_guard(summary: &SelectionPerformanceSummary) -> f64 {
    let quality = conservative_quality(summary);
    if quality <= 0.70 {
        0.05
    } else if quality >= 0.90 {
        1.0
    } else {
        0.05 + 0.95 * (quality - 0.70) / 0.20
    }
}

pub(crate) fn freshness(current_epoch: u32, newest_epoch: u32) -> f64 {
    let age = current_epoch.saturating_sub(newest_epoch);
    2.0_f64.powf(-(age as f64) / FRESHNESS_HALF_LIFE_EPOCHS)
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn unstable_node_has_lower_conservative_quality() {
        let stable = SelectionPerformanceSummary {
            weighted_mean: 0.90,
            weighted_stddev: 0.02,
            effective_samples: 30,
            newest_epoch: 100,
        };
        let unstable = SelectionPerformanceSummary {
            weighted_mean: 0.90,
            weighted_stddev: 0.15,
            effective_samples: 4,
            newest_epoch: 100,
        };

        assert!(conservative_quality(&stable) > conservative_quality(&unstable));
        assert!(evidence_guard(&stable) > evidence_guard(&unstable));
    }

    #[test]
    fn stale_evidence_decays_monotonically() {
        assert!(freshness(100, 100) > freshness(104, 100));
        assert!(freshness(u32::MAX, u32::MAX) > freshness(u32::MAX, 0));
    }

    #[test]
    fn summary_rejects_future_and_non_finite_samples() {
        let samples = [
            PerformanceSample {
                epoch_id: 10,
                performance: 0.8,
            },
            PerformanceSample {
                epoch_id: 11,
                performance: 1.0,
            },
            PerformanceSample {
                epoch_id: 9,
                performance: f64::NAN,
            },
        ];

        let summary = summarise_performance(10, &samples).unwrap();
        assert_eq!(summary.weighted_mean, 0.8);
        assert_eq!(summary.effective_samples, 1);
        assert_eq!(summary.newest_epoch, 10);
    }

    #[test]
    fn history_window_saturates_near_genesis() {
        assert_eq!(first_history_epoch(0), 0);
        assert_eq!(first_history_epoch(HISTORY_EPOCHS), 1);
    }
}
