use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{Lovelace, PolicyId}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use config
use crowdfunding/types.{
  MovieCampaignDatum,
  MovieBackerDatum,
  MovieCampaignAction, 
  MovieMintRedeemer,
  LaunchMovieCampaign,
  Contribute,
  FinishPhase,
  CancelCampaign,
  AdvancePhase,
  RefundBacker,
  ConcludeCampaign,
  DistributeRewards,
  // Production states are now defined with milestone info:
  PreProduction,
  Production,
  PostProduction,
  Distribution,
  Completed,
  Cancelled,
}
use crowdfunding/utils.{address_from_tuple}
use test_kit/time/unwrap

// -----------------------------------------------------------------------------
// NEW TYPE DEFINITIONS (Alternative Approach: Combining Milestones with States)
// -----------------------------------------------------------------------------

pub type MovieProductionState {
  PreProduction { goal: Lovelace, deadline: Int },
  Production { goal: Lovelace, deadline: Int },
  PostProduction { goal: Lovelace, deadline: Int },
  Distribution { goal: Lovelace, deadline: Int },
  Completed,
  Cancelled,
}

// The campaign datum now only holds the overall state, not an explicit phases list.
pub type MovieCampaignDatum {
  movie_title: ByteArray,
  director: ByteArray,
  creator: (VerificationKeyHash, VerificationKeyHash), // (payment key, stake key)
  total_budget: Lovelace,
  state: MovieProductionState,
}

// -----------------------------------------------------------------------------
// STATE ADVANCEMENT HELPER
// -----------------------------------------------------------------------------

// Defines how the campaign advances from one milestone state to the next.
// Note: In a real implementation, you would likely have external parameters
// to set the new goal/deadline. For illustration, we use dummy values.
fn advance_state(state: MovieProductionState) -> MovieProductionState {
  when state is {
    PreProduction { goal: _, deadline: _ } ->
      // Transition from PreProduction to Production; replace 0 with the actual new goal/deadline.
      Production { goal: 0, deadline: 0 },
    Production { goal: _, deadline: _ } ->
      PostProduction { goal: 0, deadline: 0 },
    PostProduction { goal: _, deadline: _ } ->
      Distribution { goal: 0, deadline: 0 },
    Distribution { goal: _, deadline: _ } ->
      Completed,
    _ -> state
  }
}

// -----------------------------------------------------------------------------
// MINT VALIDATION
// -----------------------------------------------------------------------------

pub fn validate_mint_movie_campaign(
  campaign_creator: VerificationKeyHash,
  nonce: OutputReference,
  redeemer: Option<Data>,
  self_script: PolicyId,
  tx: Transaction,
  platform: VerificationKeyHash,
) -> Bool {
  when redeemer is {
    Some(current_redeemer) ->
      if current_redeemer is LaunchMovieCampaign(campaign_datum): MovieMintRedeemer {
        tx |> validate_launch_movie_campaign(self_script, campaign_datum, nonce, campaign_creator)
      } else if current_redeemer is Contribute(backer_datum): MovieMintRedeemer {
        tx |> validate_contribution(self_script, backer_datum)
      } else if current_redeemer is FinishPhase(backer_datum): MovieMintRedeemer {
        tx |> validate_finish_phase(self_script, backer_datum)
      } else {
        False
      }

    None -> False
  }
}

// -----------------------------------------------------------------------------
// SPEND VALIDATION
// -----------------------------------------------------------------------------

pub fn validate_spend_movie_campaign(
  platform: VerificationKeyHash,
  campaign_creator: VerificationKeyHash,
  nonce: OutputReference,
  datum: Option<Data>,
  action: MovieCampaignAction,
  o_ref: OutputReference,
  tx: Transaction,
) -> Bool {

  expect Some(Input { output: Output { address, .. }, .. }) =
    tx.inputs |> transaction.find_input(o_ref)
  expect Script(self_script) = address.payment_credential
  // This snippet finds the input being spent that references the script output

  when (datum, action) is {
    // Cancel the campaign
    (Some(current_datum), CancelCampaign) -> {
      if current_datum is campaign_datum: MovieCampaignDatum {
        tx |> validate_cancel_movie_campaign(self_script, campaign_datum, platform)
      } else {
        fail @"Invalid datum type for CancelCampaign!"
      }
    }

    // Refund the backer
    (Some(current_datum), RefundBacker) -> {
      if current_datum is backer_datum: MovieBackerDatum {
        tx |> validate_backer_refund(self_script, backer_datum)
      } else {
        fail @"Invalid datum type for RefundBacker!"
      }
    }

    // Advance to the next milestone (phase)
    (Some(current_datum), AdvancePhase) -> {
      if current_datum is campaign_datum: MovieCampaignDatum {
        tx |> validate_advance_phase(self_script, campaign_datum, platform)
      } else {
        fail @"Invalid datum type for AdvancePhase!"
      }
    }

    // Distribute rewards/funds to the creator
    (Some(current_datum), DistributeRewards) -> {
      if current_datum is campaign_datum: MovieCampaignDatum {
        tx |> validate_collect_phase_funds(self_script, campaign_datum)
      } else {
        fail @"Invalid datum type for CollectFunds!"
      }
    }

    // Conclude the entire campaign (e.g., after final milestone)
    (Some(current_datum), ConcludeCampaign) -> {
      if current_datum is campaign_datum: MovieCampaignDatum {
        tx |> validate_conclude_campaign(self_script, campaign_datum, platform)
      } else {
        fail @"Invalid datum type for ConcludeCampaign!"
      }
    }

    // Otherwise, if no known action or datum is provided:
    _ -> {
      expect !is_running_campaign(tx.reference_inputs, self_script)
      tx |> must_be_signed_by(platform)
    }
  }
}

// -----------------------------------------------------------------------------
// LAUNCH VALIDATION
// -----------------------------------------------------------------------------

fn validate_launch_movie_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
  nonce: OutputReference,
  creator: VerificationKeyHash,
) -> Bool {

  // The initial state must be PreProduction with its milestone info.
  expect campaign_datum.state is PreProduction { goal, deadline }
  // Ensure the transaction starts before the initial milestone's deadline.
  expect unwrap.finite_start_of(tx.validity_range) < deadline

  and {
    must_consume_creator_nonce(tx, creator, nonce)?,
    must_mint_state_token(tx, self_script)?,
    must_output_state_token_for_movie_campaign(tx, self_script, campaign_datum)?,
  }
}

// -----------------------------------------------------------------------------
// CANCEL VALIDATION
// -----------------------------------------------------------------------------

fn validate_cancel_movie_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
  platform: VerificationKeyHash,
) -> Bool {
  let is_signed_by_platform = must_be_signed_by(tx, platform)
  // For cancellation, if the platform signs then the transaction must occur after the current milestone's deadline.
  and {
    when campaign_datum.state is {
      PreProduction { deadline } ->
        if is_signed_by_platform? {
          must_be_after_deadline(tx, deadline)?
        } else {
          // If not platform-signed, require the creator’s signature.
          let (creator_pkh, _) = campaign_datum.creator
          must_be_signed_by(tx, creator_pkh)?
        },
      Production { deadline } ->
        if is_signed_by_platform? {
          must_be_after_deadline(tx, deadline)?
        } else {
          let (creator_pkh, _) = campaign_datum.creator
          must_be_signed_by(tx, creator_pkh)?
        },
      PostProduction { deadline } ->
        if is_signed_by_platform? {
          must_be_after_deadline(tx, deadline)?
        } else {
          let (creator_pkh, _) = campaign_datum.creator
          must_be_signed_by(tx, creator_pkh)?
        },
      Distribution { deadline } ->
        if is_signed_by_platform? {
          must_be_after_deadline(tx, deadline)?
        } else {
          let (creator_pkh, _) = campaign_datum.creator
          must_be_signed_by(tx, creator_pkh)?
        },
      _ -> False
    },
    
    is_running_campaign(tx.inputs, self_script)?,
    must_output_state_token_for_movie_campaign(
      tx,
      self_script,
      MovieCampaignDatum { ..campaign_datum, state: Cancelled },
    )?,
  }
}

// -----------------------------------------------------------------------------
// BACKER REFUND VALIDATION
// -----------------------------------------------------------------------------

fn validate_backer_refund(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  expect !is_running_campaign(tx.reference_inputs, self_script)
  must_refund_backer(tx, self_script, backer_datum)?
}

// -----------------------------------------------------------------------------
// ADVANCE MILESTONE (PHASE) VALIDATION
// -----------------------------------------------------------------------------

fn validate_advance_phase(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
  platform: VerificationKeyHash,
) -> Bool {
  // Extract the current state's milestone info.
  and {
    // 1) If platform-signed, ensure the transaction is before (or at) the current milestone's deadline.
    when campaign_datum.state is {
      PreProduction { deadline } ->
        if must_be_signed_by(tx, platform)? {
          must_be_before_or_at_deadline(tx, deadline)?
        } else {
          let (creator_pkh, _) = campaign_datum.creator
          must_be_signed_by(tx, creator_pkh)?
        },
      Production { deadline } ->
        if must_be_signed_by(tx, platform)? {
          must_be_before_or_at_deadline(tx, deadline)?
        } else {
          let (creator_pkh, _) = campaign_datum.creator
          must_be_signed_by(tx, creator_pkh)?
        },
      PostProduction { deadline } ->
        if must_be_signed_by(tx, platform)? {
          must_be_before_or_at_deadline(tx, deadline)?
        } else {
          let (creator_pkh, _) = campaign_datum.creator
          must_be_signed_by(tx, creator_pkh)?
        },
      Distribution { deadline } ->
        if must_be_signed_by(tx, platform)? {
          must_be_before_or_at_deadline(tx, deadline)?
        } else {
          let (creator_pkh, _) = campaign_datum.creator
          must_be_signed_by(tx, creator_pkh)?
        },
      _ -> False
    },

    // 2) Check that the funding goal for the current milestone is reached.
    when campaign_datum.state is {
      PreProduction { goal } ->
        must_reach_phase_goal(tx, self_script, goal)?,
      Production { goal } ->
        must_reach_phase_goal(tx, self_script, goal)?,
      PostProduction { goal } ->
        must_reach_phase_goal(tx, self_script, goal)?,
      Distribution { goal } ->
        must_reach_phase_goal(tx, self_script, goal)?,
      _ -> False
    },

    // 3) The campaign must be running.
    is_running_campaign(tx.inputs, self_script)?,

    // 4) Update the campaign datum with the next state.
    must_output_state_token_for_movie_campaign(
      tx,
      self_script,
      MovieCampaignDatum { ..campaign_datum, state: advance_state(campaign_datum.state) },
    )?,
  }
}

// -----------------------------------------------------------------------------
// COLLECT FUNDS VALIDATION (For the current milestone)
// -----------------------------------------------------------------------------

fn validate_collect_phase_funds(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
) -> Bool {
  when campaign_datum.state is {
    PreProduction { goal } ->
      must_reach_phase_goal(tx, self_script, goal)?,
    Production { goal } ->
      must_reach_phase_goal(tx, self_script, goal)?,
    PostProduction { goal } ->
      must_reach_phase_goal(tx, self_script, goal)?,
    Distribution { goal } ->
      must_reach_phase_goal(tx, self_script, goal)?,
    _ -> False
  }
  must_distribute_phase_funds(tx, self_script, campaign_datum.creator)
}

// -----------------------------------------------------------------------------
// CONCLUDE CAMPAIGN VALIDATION
// -----------------------------------------------------------------------------

fn validate_conclude_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
  platform: VerificationKeyHash,
) -> Bool {
  and {
    if !must_be_signed_by(tx, platform)? {
      let (creator_pkh, _) = campaign_datum.creator
      must_be_signed_by(tx, creator_pkh)?
    } else {
      True
    },
    // For concluding, we expect the current state to be Distribution.
    when campaign_datum.state is {
      Distribution { deadline } -> must_be_after_deadline(tx, deadline)?
      _ -> False
    },
    must_output_state_token_for_movie_campaign(
      tx,
      self_script,
      MovieCampaignDatum { ..campaign_datum, state: Completed },
    )?,
  }
}

// -----------------------------------------------------------------------------
// HELPER FUNCTIONS (unchanged from your original script)
// -----------------------------------------------------------------------------

fn is_running_campaign(tx_inputs: List<Input>, self_script: PolicyId) -> Bool {
  // Must consume or reference the state token UTxO.
  expect Some(Input { output: Output { datum, .. }, .. }) = {
    let input <- list.find(tx_inputs)
    assets.quantity_of(input.output.value, self_script, config.state_token) == 1
  }

  expect InlineDatum(campaign_datum) = datum
  expect MovieCampaignDatum { state, .. } = campaign_datum

  // Campaign is running if the state is one of the active milestone states.
  when state is {
    PreProduction { .. } -> True,
    Production { .. } -> True,
    PostProduction { .. } -> True,
    Distribution { .. } -> True,
    _ -> False
  }
}

fn must_be_signed_by(tx: Transaction, signer: VerificationKeyHash) -> Bool {
  // Expect exactly the given signer.
  ([signer] == tx.extra_signatories)?
}

fn must_be_after_deadline(tx: Transaction, deadline: Int) -> Bool {
  (unwrap.finite_start_of(tx.validity_range) >= deadline)?
}

fn must_be_before_or_at_deadline(tx: Transaction, deadline: Int) -> Bool {
  (unwrap.finite_start_of(tx.validity_range) <= deadline)?
}

fn must_reach_phase_goal(
  tx: Transaction,
  self_script: PolicyId,
  phase_goal: Lovelace
) -> Bool {
  let script_address = Address(Script(self_script), None)

  let sum_support = fn(sum, Input { output, .. }) {
    if output.address == script_address {
      assets.lovelace_of(output.value) + sum
    } else {
      sum
    }
  }

  let total = list.reduce(tx.inputs, 0, sum_support)
  (total >= phase_goal)?
}

fn must_output_state_token_for_movie_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
) -> Bool {
  let datum_data: Data = campaign_datum
  let movie_script_address = Address(Script(self_script), None)

  let Output { address, datum, value, .. } <- list.any(tx.outputs)

  when datum is {
    InlineDatum(output_datum) ->
      and {
        address == movie_script_address,
        output_datum == datum_data,
        assets.quantity_of(value, self_script, config.state_token) == 1,
      }
    _ -> False
  }
}

fn must_send_support_token(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  let with_backer_datum_data: Data = backer_datum
  let self_address = address.from_script(self_script)
  let Output { address, datum, value, .. } <- list.any(tx.outputs)

  when datum is {
    InlineDatum(output_datum) -> and {
        address == self_address,
        output_datum == with_backer_datum_data,
        assets.quantity_of(value, self_script, config.support_token) == 1,
      }
    _ -> False
  }
}

fn must_mint_state_token(tx: Transaction, self_script: PolicyId) -> Bool {
  let minted_tokens = tx.mint |> assets.tokens(self_script) |> dict.to_pairs()
  ([Pair(config.state_token, 1)] == minted_tokens)?
}

fn must_consume_creator_nonce(
  tx: Transaction,
  creator: VerificationKeyHash,
  nonce: OutputReference,
) -> Bool {
  let Input(
    output_reference,
    Output { address: Address { payment_credential, .. }, .. },
  ) <- list.any(tx.inputs)

  and {
    output_reference == nonce,
    VerificationKey(creator) == payment_credential,
  }
}

fn validate_contribution(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  and {
    must_mint_support_token_1(tx, self_script)?,
    must_send_support_token(tx, self_script, backer_datum)?,
  }
}

fn must_mint_support_token_1(tx: Transaction, self_script: PolicyId) -> Bool {
  let minted_qty = assets.quantity_of(tx.mint, self_script, config.support_token)
  minted_qty == 1
}

fn validate_finish_phase(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  must_mint_reward_burn_support(tx, self_script, backer_datum)?
}

fn must_distribute_phase_funds(
  tx: Transaction,
  self_script: PolicyId,
  (creator_pkh, creator_skh),
) -> Bool {
  let script_address = Address(Script(self_script), None)

  let sum_input = fn(sum, Input { output, .. }) {
    if output.address == script_address {
      assets.lovelace_of(output.value) + sum
    } else {
      sum
    }
  }
  let input_lovelace = list.reduce(tx.inputs, 0, sum_input)

  let creator_address = utils.address_from_tuple((creator_pkh, creator_skh))
  let sum_output = fn(sum, Output { address, value, .. }) {
    if address == creator_address {
      assets.lovelace_of(value) + sum
    } else {
      sum
    }
  }
  let output_lovelace = list.reduce(tx.outputs, 0, sum_output)

  (output_lovelace >= input_lovelace)?
}

fn must_refund_backer(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  let backer_datum_data: Data = backer_datum
  let script_address = Address(Script(self_script), None)

  let input_sum = fn(sum, Input { output, .. }) {
    if output.address == script_address {
      when output.datum is {
        InlineDatum(inline_datum) ->
          if inline_datum == backer_datum_data {
            assets.lovelace_of(output.value) + sum
          } else {
            sum
          }
        _ -> sum
      }
    } else {
      sum
    }
  }
  let input_lovelace = list.reduce(tx.inputs, 0, input_sum)

  let backer_address = utils.address_from_tuple((backer_datum.backer_pkh, backer_datum.backer_skh))
  let output_sum = fn(sum, Output { address, value, .. }) {
    if address == backer_address {
      assets.lovelace_of(value) + sum
    } else {
      sum
    }
  }
  let returned_lovelace = list.reduce(tx.outputs, 0, output_sum)

  (returned_lovelace >= input_lovelace)?
}

fn must_mint_reward_burn_support(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  let backer_datum_data: Data = backer_datum
  let script_address = Address(Script(self_script), None)

  let input_support_tokens = list.reduce(
    tx.inputs,
    0,
    fn(sum, Input { output, .. }) {
      if output.address == script_address {
        when output.datum is {
          InlineDatum(inline_datum) ->
            if inline_datum == backer_datum_data {
              sum + assets.quantity_of(output.value, self_script, config.support_token)
            } else {
              sum
            }
          _ -> sum
        }
      } else {
        sum
      }
    },
  )

  let minted_burned_tokens = tx.mint |> assets.tokens(self_script) |> dict.to_pairs()
  let required_pattern = [
    Pair(config.reward_token, input_support_tokens),
    Pair(config.support_token, -input_support_tokens),
  ]
  let mint_burn_ok = minted_burned_tokens == required_pattern

  let backer_address = utils.address_from_tuple((backer_datum.backer_pkh, backer_datum.backer_skh))
  let sum_rewards = fn(sum, Output { address, value, .. }) {
    if address == backer_address {
      assets.quantity_of(value, self_script, config.reward_token) + sum
    } else {
      sum
    }
  }
  let reward_tokens_out = list.reduce(tx.outputs, 0, sum_rewards)
  let reward_ok = reward_tokens_out >= input_support_tokens

  (mint_burn_ok && reward_ok)?
}

fn must_be_before_or_at_deadline(tx: Transaction, deadline: Int) -> Bool {
  (unwrap.finite_start_of(tx.validity_range) <= deadline)?
}

// -----------------------------------------------------------------------------
// (Optional) Utility functions to retrieve milestone deadlines (if needed)
// -----------------------------------------------------------------------------

fn get_phase_deadline_by_state(campaign: MovieCampaignDatum) -> Option<Int> {
  when campaign.state is {
    PreProduction { deadline } -> Some(deadline),
    Production { deadline } -> Some(deadline),
    PostProduction { deadline } -> Some(deadline),
    Distribution { deadline } -> Some(deadline),
    _ -> None,
  }
}
