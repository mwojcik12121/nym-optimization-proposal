// Copyright 2023 - Nym Technologies SA <contact@nymtech.net>
// SPDX-License-Identifier: GPL-3.0-only

use crate::epoch_operations::error::RewardingError;
use crate::epoch_operations::helpers::stake_to_f64;
use crate::node_performance::evidence::{conservative_quality, evidence_guard, freshness};
use crate::EpochAdvancer;
use cosmwasm_std::Decimal;
use nym_api_requests::models::SelectionPerformanceSummary;
use nym_mixnet_contract_common::reward_params::{Performance, RewardedSetParams};
use nym_mixnet_contract_common::{
    EpochState, NodeId, NymNodeDetails, RewardedSet, RewardingParams,
};
use rand::prelude::SliceRandom;
use rand::rngs::OsRng;
use rand::{CryptoRng, Rng};
use std::collections::HashSet;
use tracing::{debug, error, info, warn};

#[derive(Debug, Clone, PartialEq)]
enum AvailableRole {
    // legacy mixnodes + nym-nodes in mixing mode
    Mix,

    // legacy gateways + nym-nodes in entry or exit mode
    EntryGateway,

    // nym-nodes in exit mode
    ExitGateway,
}

const PERFORMANCE_EXPONENT: i32 = 8;
const MIN_BOOTSTRAP_SAMPLES: u32 = 4;
const FULL_WEIGHT_SAMPLES: u32 = 8;
const PROVISIONAL_WEIGHT_FACTOR: f64 = 0.35;
const BOOTSTRAP_ROLE_FRACTION: f64 = 0.02;

#[derive(Debug, Clone)]
struct NodeWithSaturationAndPerformance {
    node_id: NodeId,
    available_roles: Vec<AvailableRole>,
    saturation: Decimal,
    current_performance: Performance,
    selection_evidence: Option<SelectionPerformanceSummary>,
}

impl NodeWithSaturationAndPerformance {
    fn to_selection_weight(&self, current_epoch: u32) -> f64 {
        let Some(summary) = self.selection_evidence.as_ref() else {
            info!(
                target: "nym_api::selection_scoring",
                node_id = self.node_id,
                current_performance = %self.current_performance,
                stake_saturation = %self.saturation,
                stake_saturation_factor = stake_to_f64(self.saturation),
                current_epoch = current_epoch,
                evidence_available = false,
                raw_selection_weight = 0.0,
                final_selection_weight = 0.0,
                decision = "bootstrap_pool",
                reason = "missing_selection_evidence",
                "rewarded-set selection weight decision"
            );
            return 0.0;
        };

        let stake_saturation_factor = stake_to_f64(self.saturation);
        let historical_mean_raw = summary.weighted_mean;
        let historical_mean_clamped = historical_mean_raw.clamp(0.0, 1.0);
        let historical_mean_power_factor = historical_mean_clamped.powi(PERFORMANCE_EXPONENT);
        let conservative_quality_factor = conservative_quality(summary);
        let evidence_guard_factor = evidence_guard(summary);
        let freshness_factor = freshness(current_epoch, summary.newest_epoch);
        let maturity_factor = if summary.effective_samples < FULL_WEIGHT_SAMPLES {
            PROVISIONAL_WEIGHT_FACTOR
        } else {
            1.0
        };
        let evidence_age_epochs = current_epoch.saturating_sub(summary.newest_epoch);
        let raw_weight = stake_saturation_factor
            * historical_mean_power_factor
            * evidence_guard_factor
            * freshness_factor
            * maturity_factor;

        let (final_weight, decision, reason) =
            if summary.effective_samples < MIN_BOOTSTRAP_SAMPLES {
                (0.0, "bootstrap_pool", "insufficient_effective_samples")
            } else if !raw_weight.is_finite() {
                (0.0, "excluded", "non_finite_weight")
            } else {
                let final_weight = raw_weight.max(0.0);
                if final_weight > 0.0 {
                    (final_weight, "weighted_pool", "evidence_sufficient")
                } else {
                    (final_weight, "excluded", "non_positive_weight")
                }
            };

        info!(
            target: "nym_api::selection_scoring",
            node_id = self.node_id,
            current_performance = %self.current_performance,
            stake_saturation = %self.saturation,
            stake_saturation_factor = stake_saturation_factor,
            historical_mean_raw = historical_mean_raw,
            historical_mean_clamped = historical_mean_clamped,
            historical_stddev = summary.weighted_stddev,
            performance_exponent = PERFORMANCE_EXPONENT,
            historical_mean_power_factor = historical_mean_power_factor,
            conservative_quality_factor = conservative_quality_factor,
            evidence_guard_factor = evidence_guard_factor,
            freshness_factor = freshness_factor,
            maturity_factor = maturity_factor,
            current_epoch = current_epoch,
            newest_evidence_epoch = summary.newest_epoch,
            evidence_age_epochs = evidence_age_epochs,
            evidence_available = true,
            effective_samples = summary.effective_samples,
            minimum_effective_samples = MIN_BOOTSTRAP_SAMPLES,
            full_weight_samples = FULL_WEIGHT_SAMPLES,
            raw_selection_weight = raw_weight,
            final_selection_weight = final_weight,
            decision = decision,
            reason = reason,
            "rewarded-set selection weight decision"
        );

        final_weight
    }

    fn is_bootstrap_candidate(&self) -> bool {
        self.selection_evidence
            .as_ref()
            .map(|summary| summary.effective_samples < MIN_BOOTSTRAP_SAMPLES)
            .unwrap_or(true)
    }

    fn can_operate_mixnode(&self) -> bool {
        self.available_roles.contains(&AvailableRole::Mix)
    }

    fn can_operate_entry_gateway(&self) -> bool {
        self.available_roles.contains(&AvailableRole::EntryGateway)
    }

    fn can_operate_exit_gateway(&self) -> bool {
        self.available_roles.contains(&AvailableRole::ExitGateway)
    }
}

fn choose_role_with_bootstrap<R, F>(
    rng: &mut R,
    candidates: &[NodeWithSaturationAndPerformance],
    requested_count: usize,
    current_epoch: u32,
    eligible_for_role: F,
) -> Result<HashSet<NodeId>, RewardingError>
where
    R: Rng + CryptoRng,
    F: Fn(&NodeWithSaturationAndPerformance) -> bool,
{
    if requested_count == 0 {
        return Ok(HashSet::new());
    }

    // New and weakly observed nodes are kept in an explicit, bounded pool. The ceiling preserves
    // a bootstrap path for small role sets, while never allowing that path to consume more than
    // the requested role count.
    let bootstrap_limit = ((requested_count as f64 * BOOTSTRAP_ROLE_FRACTION).ceil() as usize)
        .min(requested_count);
    let bootstrap_candidates = candidates
        .iter()
        .filter(|candidate| eligible_for_role(candidate))
        .filter(|candidate| candidate.is_bootstrap_candidate())
        .collect::<Vec<_>>();

    // Bootstrap candidates bypass weighted selection, so evaluate their zero-weight decision here
    // to make missing or insufficient evidence visible alongside the weighted-pool decisions.
    for candidate in &bootstrap_candidates {
        candidate.to_selection_weight(current_epoch);
    }

    let bootstrap_count = bootstrap_limit.min(bootstrap_candidates.len());
    let mut selected = bootstrap_candidates
        .choose_multiple(rng, bootstrap_count)
        .map(|candidate| candidate.node_id)
        .collect::<HashSet<_>>();

    // If the bootstrap pool is short, its unused quota returns to the evidence-backed pool. It is
    // never filled with additional low-history nodes, keeping experimental exposure bounded.
    let main_count = requested_count.saturating_sub(selected.len());
    let main_candidates = candidates
        .iter()
        .filter(|candidate| eligible_for_role(candidate))
        .filter(|candidate| !candidate.is_bootstrap_candidate())
        .filter_map(|candidate| {
            let weight = candidate.to_selection_weight(current_epoch);
            (weight > 0.0).then_some((candidate, weight))
        })
        .collect::<Vec<_>>();

    let weighted_count = main_count.min(main_candidates.len());
    if weighted_count > 0 {
        selected.extend(
            main_candidates
                .choose_multiple_weighted(rng, weighted_count, |item| item.1)?
                .map(|item| item.0.node_id),
        );
    }

    if selected.len() < requested_count {
        warn!(
            selected = selected.len(),
            requested = requested_count,
            bootstrap_limit,
            "role assignment underfilled after evidence filtering"
        );
    }

    Ok(selected)
}

impl EpochAdvancer {
    fn determine_rewarded_set(
        &self,
        nodes: Vec<NodeWithSaturationAndPerformance>,
        spec: RewardedSetParams,
        current_epoch: u32,
    ) -> Result<RewardedSet, RewardingError> {
        if nodes.is_empty() {
            warn!("there are no nodes for assignment!");
            return Ok(RewardedSet::default());
        }

        let mut rng = OsRng;

        // 1. determine entry gateways
        let entry_gateways = choose_role_with_bootstrap(
            &mut rng,
            &nodes,
            spec.entry_gateways as usize,
            current_epoch,
            |node| node.can_operate_entry_gateway(),
        )?;

        // 2. determine exit gateways
        let exit_gateways = choose_role_with_bootstrap(
            &mut rng,
            &nodes,
            spec.exit_gateways as usize,
            current_epoch,
            |node| {
                node.can_operate_exit_gateway() && !entry_gateways.contains(&node.node_id)
            },
        )?;

        // 3. determine mixnodes
        let mixnodes = choose_role_with_bootstrap(
            &mut rng,
            &nodes,
            spec.mixnodes as usize,
            current_epoch,
            |node| {
                node.can_operate_mixnode()
                    && !exit_gateways.contains(&node.node_id)
                    && !entry_gateways.contains(&node.node_id)
            },
        )?;

        // 4. determine standby
        let standby = choose_role_with_bootstrap(
            &mut rng,
            &nodes,
            spec.standby as usize,
            current_epoch,
            |node| {
                !exit_gateways.contains(&node.node_id)
                    && !entry_gateways.contains(&node.node_id)
                    && !mixnodes.contains(&node.node_id)
            },
        )?
        .into_iter()
        .collect::<Vec<_>>();

        // 5. split mixnodes into the layers: just shuffle the selected nodes and select every 3rd into each layer
        let mut mixnodes_vec = mixnodes.into_iter().collect::<Vec<_>>();
        mixnodes_vec.shuffle(&mut rng);

        let mut layer1 = Vec::new();
        let mut layer2 = Vec::new();
        let mut layer3 = Vec::new();

        #[allow(clippy::panic)]
        for (i, mix) in mixnodes_vec.iter().enumerate() {
            match i % 3 {
                0 => layer1.push(*mix),
                1 => layer2.push(*mix),
                2 => layer3.push(*mix),
                n => panic!("we have broken maths! somehow {i} % 3 == {n}!"),
            }
        }

        if entry_gateways.len() != spec.entry_gateways as usize {
            warn!(
                "we didn't manage to select {} entry gateways. we only got {}",
                spec.entry_gateways,
                entry_gateways.len()
            )
        }

        if exit_gateways.len() != spec.exit_gateways as usize {
            warn!(
                "we didn't manage to select {} exit gateways. we only got {}",
                spec.exit_gateways,
                exit_gateways.len()
            )
        }

        if mixnodes_vec.len() != spec.mixnodes as usize {
            warn!(
                "we didn't manage to select {} mixnodes. we only got {}",
                spec.mixnodes,
                mixnodes_vec.len()
            )
        }

        if standby.len() != spec.standby as usize {
            warn!(
                "we didn't manage to select {} standby nodes. we only got {}",
                spec.standby,
                standby.len()
            )
        }

        let mut rewarded_set = RewardedSet {
            entry_gateways: entry_gateways.into_iter().collect(),
            exit_gateways: exit_gateways.into_iter().collect(),
            layer1,
            layer2,
            layer3,
            standby,
        };

        // make sure to sort the rewarded set values
        rewarded_set.entry_gateways.sort();
        rewarded_set.exit_gateways.sort();
        rewarded_set.layer1.sort();
        rewarded_set.layer2.sort();
        rewarded_set.layer3.sort();
        rewarded_set.standby.sort();

        Ok(rewarded_set)
    }

    async fn attach_performance_to_eligible_nodes(
        &self,
        nym_nodes: &[NymNodeDetails],
        reward_params: &RewardingParams,
    ) -> Vec<NodeWithSaturationAndPerformance> {
        let mut with_performance = Vec::new();

        // SAFETY: the cache MUST HAVE been initialised before now
        #[allow(clippy::unwrap_used)]
        let described_cache = self.described_cache.get().await.unwrap();

        let Ok(status_cache) = self.status_cache.node_annotations().await else {
            warn!("there are no node annotations available");
            return Vec::new();
        };

        for nym_node in nym_nodes {
            let node_id = nym_node.node_id();
            let saturation = nym_node.rewarding_details.bond_saturation(reward_params);

            let Some(self_described) = described_cache.get_description(&node_id) else {
                continue;
            };

            let Some(annotation) = status_cache.get(&node_id) else {
                debug!("couldn't find annotation for nym-node {node_id}");
                continue;
            };

            let performance = annotation.detailed_performance.to_rewarding_performance();
            let detailed_performance = &annotation.detailed_performance;
            info!(
                target: "nym_api::selection_scoring",
                node_id = node_id,
                candidate_identity = %nym_node.bond_information.identity(),
                candidate_host = %nym_node.bond_information.node.host.as_str(),
                stake_saturation = %saturation,
                routing_score = detailed_performance.routing_score.score,
                config_score = detailed_performance.config_score.score,
                stress_testing_score = detailed_performance.stress_testing_score.score,
                stress_testing_reachable = detailed_performance.stress_testing_score.was_reachable,
                combined_performance_score = detailed_performance.performance_score,
                current_performance = %performance,
                "received rewarded-set scoring inputs for candidate"
            );

            let mut available_roles = Vec::new();
            if self_described.declared_role.mixnode {
                available_roles.push(AvailableRole::Mix)
            }
            if self_described.declared_role.entry {
                available_roles.push(AvailableRole::EntryGateway)
            }
            if self_described.declared_role.can_operate_exit_gateway() {
                available_roles.push(AvailableRole::ExitGateway)
            }

            if available_roles.is_empty() {
                warn!("nym-node {node_id} can't operate under any mode!");
                continue;
            }

            with_performance.push(NodeWithSaturationAndPerformance {
                node_id: nym_node.node_id(),
                available_roles,
                saturation,
                current_performance: performance,
                selection_evidence: annotation.selection_evidence.clone(),
            })
        }

        with_performance
    }

    pub(super) async fn update_rewarded_set_and_advance_epoch(
        &self,
        nym_nodes: &[NymNodeDetails],
    ) -> Result<(), RewardingError> {
        let epoch_status = self.nyxd_client.get_current_epoch_status().await?;
        match epoch_status.state {
            EpochState::RoleAssignment { next } => {
                // with how the nym-api is currently coded, this should never happen as we're always
                // assigning roles to ALL nodes at once, but who knows what we might decide to do in the future...
                if !next.is_first() {
                    return Err(RewardingError::MidRoleAssignment { next });
                }

                info!("attempting to assign the rewarded set for the upcoming epoch...");

                if let Err(err) = self._update_rewarded_set_and_advance_epoch(nym_nodes).await {
                    error!("FAILED to assign the rewarded set... - {err}");
                    Err(err)
                } else {
                    info!("Advanced the epoch and updated the rewarded set... SUCCESS");
                    Ok(())
                }
            }
            state => {
                // hard error, this shouldn't have happened!
                error!("tried to perform node rewarded set assignment while in {state} state!");
                Err(RewardingError::InvalidEpochState {
                    current_state: state,
                    operation: "assigning rewarded set".to_string(),
                })
            }
        }
    }

    async fn _update_rewarded_set_and_advance_epoch(
        &self,
        nym_nodes: &[NymNodeDetails],
    ) -> Result<(), RewardingError> {
        // we grab rewarding parameters here as they might have gotten updated when performing epoch actions
        let rewarding_parameters = self.nyxd_client.get_current_rewarding_parameters().await?;
        let current_epoch = self
            .current_interval_details()
            .await?
            .interval
            .current_epoch_absolute_id();

        debug!("Rewarding parameters: {rewarding_parameters:?}");

        let nodes_with_performance = self
            .attach_performance_to_eligible_nodes(nym_nodes, &rewarding_parameters)
            .await;

        let new_rewarded_set = self.determine_rewarded_set(
            nodes_with_performance,
            rewarding_parameters.rewarded_set,
            current_epoch,
        )?;

        debug!("New rewarded set: {:?}", new_rewarded_set);

        self.nyxd_client
            .send_role_assignment_messages(new_rewarded_set)
            .await?;
        Ok(())
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use rand::SeedableRng;
    use rand_chacha::ChaCha20Rng;

    fn candidate(
        node_id: NodeId,
        selection_evidence: Option<SelectionPerformanceSummary>,
    ) -> NodeWithSaturationAndPerformance {
        NodeWithSaturationAndPerformance {
            node_id,
            available_roles: vec![AvailableRole::Mix],
            saturation: Decimal::percent(100),
            current_performance: Performance::from_percentage_value(90).unwrap(),
            selection_evidence,
        }
    }

    fn mature_evidence() -> SelectionPerformanceSummary {
        SelectionPerformanceSummary {
            weighted_mean: 0.9,
            weighted_stddev: 0.02,
            effective_samples: FULL_WEIGHT_SAMPLES,
            newest_epoch: 100,
        }
    }

    #[test]
    fn bootstrap_selection_never_exceeds_its_quota() {
        let mut candidates = (0..100)
            .map(|node_id| candidate(node_id, Some(mature_evidence())))
            .collect::<Vec<_>>();
        candidates.extend((100..120).map(|node_id| candidate(node_id, None)));

        let mut rng = ChaCha20Rng::seed_from_u64(42);
        let selected = choose_role_with_bootstrap(&mut rng, &candidates, 100, 100, |_| true)
            .unwrap();
        let selected_bootstrap = selected.iter().filter(|node_id| **node_id >= 100).count();

        assert_eq!(selected.len(), 100);
        assert!(selected_bootstrap <= 2);
    }

    #[test]
    fn missing_evidence_never_enters_the_main_pool() {
        let candidate = candidate(1, None);
        assert!(candidate.is_bootstrap_candidate());
        assert_eq!(candidate.to_selection_weight(100), 0.0);
    }

    #[test]
    fn stale_or_provisional_evidence_reduces_weight() {
        let mature = candidate(1, Some(mature_evidence()));
        let mut provisional_summary = mature_evidence();
        provisional_summary.effective_samples = MIN_BOOTSTRAP_SAMPLES;
        let provisional = candidate(2, Some(provisional_summary));

        assert!(mature.to_selection_weight(100) > mature.to_selection_weight(104));
        assert!(mature.to_selection_weight(100) > provisional.to_selection_weight(100));
    }
}
