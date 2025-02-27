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
}
use crowdfunding/utils.{address_from_tuple}
use test_kit/time/unwrap



pub fn validate_mint_movie_campaign(
  campaign_creator: VerificationKeyHash,
  nonce: OutputReference,
  redeemer: Option<Data>,
  self_script: PolicyId,
  tx: Transaction,
  platform: VerificationKeyHash, // included if needed
) -> Bool {
  when redeemer is {
    Some(current_redeemer) -> {
      if current_redeemer is LaunchMovieCampaign(campaign_datum): MovieMintRedeemer {
        // e.g. Launch the entire multi-phase campaign
        tx |> validate_launch_movie_campaign(self_script, campaign_datum, nonce, campaign_creator)
      } else if current_redeemer is Contribute(backer_datum): MovieMintRedeemer {
        // e.g. Mint a support token for the contributor
        tx |> validate_contribution(self_script, backer_datum)
      } else if current_redeemer is FinishPhase(backer_datum): MovieMintRedeemer {
        // e.g. Mint a reward token for a completed phase, burn the support token, etc.
        tx |> validate_finish_phase(self_script, backer_datum)
      } else {
        False
      }
    }
    None -> False
  }
}

pub fn validate_spend_movie_campaign(
  platform: VerificationKeyHash,
  campaign_creator: VerificationKeyHash,
  nonce: OutputReference,
  datum: Option<Data>,
  action: MovieCampaignAction,
  o_ref: OutputReference,
  tx: Transaction,
) -> Bool {
  // This snippet finds the input being spent that references the script output
  expect Some(input) = tx.inputs |> find_input(o_ref)
  expect Script(self_script) = input.output.address.payment_credential

  when (datum, action) is {
    // Example: Cancel the entire campaign
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

    // Advance from one phase to the next
    (Some(current_datum), AdvancePhase) -> {
      if current_datum is campaign_datum: MovieCampaignDatum {
        tx |> validate_advance_phase(self_script, campaign_datum, platform)
      } else {
        fail @"Invalid datum type for AdvancePhase!"
      }
    }

    // Collect partial or final funds to the creator
    (Some(current_datum), CollectFunds) -> {
      if current_datum is campaign_datum: MovieCampaignDatum {
        tx |> validate_collect_phase_funds(self_script, campaign_datum)
      } else {
        fail @"Invalid datum type for CollectFunds!"
      }
    }

    // Conclude the entire campaign (e.g., after final phase)
    (Some(current_datum), ConcludeCampaign) -> {
      if current_datum is campaign_datum: MovieCampaignDatum {
        tx |> validate_conclude_campaign(self_script, campaign_datum, platform)
      } else {
        fail @"Invalid datum type for ConcludeCampaign!"
      }
    }

    // Otherwise, if no known action, or no datum
    _ ->  // NoDatum etc:
    _ -> {
      expect !is_running_campaign(tx.reference_inputs, self_script)
      tx |> must_be_signed_by(platform)
    }
  }
}

fn validate_launch_movie_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
  nonce: OutputReference,
  creator: VerificationKeyHash,
) -> Bool {

  expect MovieCampaignDatum { phases, current_phase_index, creator: (pkh, _), total_budget, state: PreProduction, .. } =
    campaign_datum
  expect creator == pkh
  expect total_budget > 0
  // Example checks:
  expect current_phase_index == 0
  expect phases != []

  // Ensure the transaction start time is before the first phase deadline
  let first_phase_deadline = campaign_datum.phases[0].phase_deadline
  expect unwrap.finite_start_of(tx.validity_range) < first_phase_deadline

  and {
    must_consume_creator_nonce(tx, creator, nonce)?,
    must_mint_state_token(tx, self_script)?,
    must_output_state_token_for_movie_campaign(tx, self_script, campaign_datum)?,
  }
}

fn validate_cancel_movie_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
  platform: VerificationKeyHash,
) -> Bool {
  let is_signed_by_platform = must_be_signed_by(tx, platform)

  // E.g., platform can only cancel after some global “last phase deadline” or certain conditions
  // while creator can cancel at any time
  and {
    if is_signed_by_platform? {
      must_be_after_deadline(tx, campaign_datum.phases.last.phase_deadline)?
    } else {
      must_be_signed_by(tx, campaign_datum.creator.0)?
    },

    is_running_campaign(tx.inputs, self_script)?,

    // Possibly check that the campaign is still “Running” (or not fully Completed)
    // Then produce an updated datum with state=Cancelled
    must_output_state_token_for_movie_campaign(
      tx,
      self_script,
      with_datum: MovieCampaignDatum { ..campaign_datum, state: Cancelled },
    )?,
  }
}



fn validate_backer_refund(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  expect !is_running_campaign(tx.reference_inputs, self_script)
  // Ensure the campaign or the relevant phase is cancelled/failed, etc.
  // Then give back the backer's lovelace from the script address to their address
  must_refund_backer(tx, self_script, backer_datum)?
}

// ## Helper Functions

fn is_running_campaign(tx_inputs: List<Input>, self_script: PolicyId) -> Bool {
  // must consume/refer state token UTxO
  expect Some(Input { output: Output { datum, .. }, .. }) = {
    let input <- list.find(tx_inputs)
    assets.quantity_of(input.output.value, self_script, config.state_token) == 1
  }

  // must be campaign inline datum
  expect InlineDatum(campaign_datum) = datum
  expect CampaignDatum { state, .. } = campaign_datum

  state == Running
}

fn must_be_signed_by(tx: Transaction, signer: VerificationKeyHash) -> Bool {
  // just expect 1 signer
  ([signer] == tx.extra_signatories)?
}

fn must_be_after_deadline(tx: Transaction, deadline: Int) -> Bool {
  // tx validFrom is after or at deadline
  (unwrap.finite_start_of(tx.validity_range) >= deadline)?
}

fn validate_advance_phase(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
  platform: VerificationKeyHash,
) -> Bool {

  
  // Check signature from either platform or creator
  must_be_signed_by(tx, platform)? // or campaign_datum.creator.0, or both

  // Ensure we have met the goal for the current phase
  let current_index = campaign_datum.current_phase_index
  expect let current_phase = campaign_datum.phases[current_index]
  must_reach_phase_goal(tx, self_script, current_phase.phase_goal)?

  // Possibly check time constraints
  must_be_before_or_at_deadline(tx, current_phase.phase_deadline)?

  // Bump the phase index
  let next_index = current_index + 1
  // If next_index >= number_of_phases, we might be done or in distribution state
  let updated_datum = if next_index < list.length(campaign_datum.phases) {
    MovieCampaignDatum { ..campaign_datum, current_phase_index: next_index }
  } else {
    // Optionally set the campaign state to Completed if we’ve run out of phases
    MovieCampaignDatum { ..campaign_datum, state: Completed }
  }

  must_output_state_token_for_movie_campaign(tx, self_script, updated_datum)?
}


// Example: Collect funds from the script for the current phase
fn validate_collect_phase_funds(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
) -> Bool {
  // Confirm the campaign is indeed in a “Running” or “Production” state
  // and the current phase is funded.
  let current_phase = campaign_datum.phases[campaign_datum.current_phase_index]
  must_reach_phase_goal(tx, self_script, current_phase.phase_goal)?

  // The transaction should pay out the locked script funds for this phase to the creator
  must_distribute_phase_funds(tx, self_script, campaign_datum.creator)
}

// Example: Conclude entire campaign after the final phase
fn validate_conclude_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
  platform: VerificationKeyHash,
) -> Bool {
  // Check signature from platform or from the campaign creator
  let is_signed_by_platform = must_be_signed_by(tx, platform)
  if !is_signed_by_platform? {
    must_be_signed_by(tx, campaign_datum.creator.0)?
  }

  // Possibly ensure we are at or beyond the last phase
  let last_phase = campaign_datum.phases.last
  must_be_after_deadline(tx, last_phase.phase_deadline)?

  // Produce an updated datum with state=Completed (or similar)
  must_output_state_token_for_movie_campaign(
    tx,
    self_script,
    MovieCampaignDatum { ..campaign_datum, state: Completed },
  )
}

fn must_reach_goal(
  tx: Transaction,
  self_script: PolicyId,
  goal: Lovelace,
  (creator_pkh, creator_skh),
) -> Bool {
  let self_address = Address(Script(self_script), None)

  // 1. Sum the lovelace from all script inputs
  let sum_support =
    fn(sum, Input { output: Output { address, datum, value, .. }, .. }) {
      if address == self_address {
        when datum is {
          InlineDatum(input_datum) ->
            if input_datum is BackerDatum {
              assets.lovelace_of(value) + sum
            } else {
              sum
            }
          _ -> sum
        }
      } else {
        sum
      }
    }
  let supports = tx.inputs |> list.reduce(0, sum_support)

  (supports >= goal)?
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

fn must_refund(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: BackerDatum,
) {
  let backer_datum_data: Data = backer_datum

  // collect input backer support lovelaces from self address
  let self_address = Address(Script(self_script), None)
  let sum_input =
    fn(sum, Input { output: Output { address, datum, value, .. }, .. }) {
      if address == self_address {
        when datum is {
          InlineDatum(input_datum) ->
            if input_datum == backer_datum_data {
              assets.lovelace_of(value) + sum
            } else {
              sum
            }
          _ -> sum
        }
      } else {
        sum
      }
    }
  let input_lovelace = list.reduce(tx.inputs, 0, sum_input)

  // collect output lovelaces to backer address
  let backer_address = utils.address_from_tuple(backer_datum)
  let sum_output =
    fn(sum, Output { address, value, .. }) {
      if address == backer_address {
        assets.lovelace_of(value) + sum
      } else {
        sum
      }
    }
  let output_lovelace = list.reduce(tx.outputs, 0, sum_output)

  (output_lovelace >= input_lovelace)?
}

fn must_output_state_token_for_movie_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
) -> Bool {
  let datum_data: Data = campaign_datum
  let movie_script_address = utils.address_from_script(self_script)

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

  // restrict minting to 1 quantity and 1 asset name with self Policy ID
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

  // the nonce utxo must come from the campaign creator
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
  let minted_qty =
    assets.quantity_of(tx.mint, self_script, config.support_token)
  minted_qty == 1
}

fn validate_finish_phase(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  // Example: you might require that the current phase’s goal is reached
  // and we burn the support token(s) while minting reward tokens
  must_mint_reward_burn_support(tx, self_script, backer_datum)?
}

fn must_mint_reward_burn_support(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: BackerDatum,
) -> Bool {
  let backer_datum_data: Data = backer_datum

  let self_address = Address(Script(self_script), None)
  
  let input_support_token =
    list.reduce(
      tx.inputs,
      0,
      fn(sum, Input { output: Output { address, datum, value, .. }, .. }) {
        if address == self_address {
          when datum is {
            InlineDatum(input_datum) ->
              if input_datum == backer_datum_data {
                sum + assets.quantity_of(
                  value,
                  self_script,
                  config.support_token,
                )
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

  let minted_and_burned_tokens =
    tx.mint |> assets.tokens(self_script) |> dict.to_pairs()

  let mint_and_burn_valid =
    minted_and_burned_tokens == [
      Pair(config.reward_token, input_support_token),
      // Mint Reward Tokens
      Pair(config.support_token, -input_support_token),
    ]

  // Burn Support Tokens
  let backer_address = utils.address_from_tuple(backer_datum)
  let sum_output =
    fn(sum, Output { address, value, .. }) {
      if address == backer_address {
        assets.quantity_of(value, self_script, config.reward_token) + sum
      } else {
        sum
      }
    }
  let output_reward_token = list.reduce(tx.outputs, 0, sum_output)

  let reward_sent_valid = output_reward_token >= input_support_token

  (mint_and_burn_valid && reward_sent_valid)?
}

fn validate_distribute_to_creator(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: CampaignDatum,
) -> Bool {
  expect !is_running_campaign(tx.reference_inputs, self_script)
  must_distribute_to_creator(tx, self_script, campaign_datum.creator)?
}

fn must_distribute_to_creator(
  tx: Transaction,
  self_script: PolicyId,
  (creator_pkh, creator_skh),
) -> Bool {
  // 1. Compute how much Lovelace is coming from the script address
  let self_address = Address(Script(self_script), None)
  let sum_input =
    fn(sum, Input { output: Output { address, value, .. }, .. }) {
      if address == self_address {
        assets.lovelace_of(value) + sum
      } else {
        sum
      }
    }
  let input_lovelace = list.reduce(tx.inputs, 0, sum_input)

  // 2. Determine the creator’s Address
  let creator_address = utils.address_from_tuple((creator_pkh, creator_skh))

  // 3. Sum how much Lovelace is going to the creator in the outputs
  let sum_output =
    fn(sum, Output { address, value, .. }) {
      if address == creator_address {
        assets.lovelace_of(value) + sum
      } else {
        sum
      }
    }
  let output_lovelace = list.reduce(tx.outputs, 0, sum_output)

  (output_lovelace >= input_lovelace)?
}



// Refund logic for backer (if a phase fails or campaign is cancelled)
fn must_refund_backer(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  // Similar to your original must_refund logic, but referencing MovieBackerDatum
  let backer_datum_data: Data = backer_datum
  let script_address = Address(Script(self_script), None)

  // 1. Sum how much the backer contributed from script
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

  // 2. Check how much is returned to the backer's address
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

// Burn the support tokens and mint any reward tokens for finishing a phase
fn must_mint_reward_burn_support(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  let backer_datum_data: Data = backer_datum
  let script_address = Address(Script(self_script), None)

  // 1. Count how many support tokens are in the script inputs for this backer
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

  // 2. Check minted/burned tokens in this transaction
  let minted_burned_tokens = tx.mint |> assets.tokens(self_script) |> dict.to_pairs()
  let required_pattern = [
    Pair(config.reward_token, input_support_tokens),   // Mint reward
    Pair(config.support_token, -input_support_tokens), // Burn support
  ]
  let mint_burn_ok = minted_burned_tokens == required_pattern

  // 3. Ensure the new reward tokens end up at the backer’s address
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
