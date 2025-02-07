use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{Lovelace, PolicyId}
use crowdfunding/utils.{address_from_tuple}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use config
use crowdfunding/types.{
  BackerDatum, CampaignAction, CampaignDatum, Cancel, Cancelled, Finish,
  Finished, Refund, Running, RewardNftAction, InitCampaign, SupportCampaign, FinishCampaign, CollectToCreator,
}
use crowdfunding/utils
use test_kit/time/unwrap

/// Validates the following action:
/// - Create campaign
pub fn validate_mint_campaign(
  platform: VerificationKeyHash,
  creator: VerificationKeyHash,
  nonce: OutputReference,
  campaign_action: RewardNftAction,
  datum: Option<Data>,
  self_script: PolicyId,
  tx: Transaction,
) -> Bool {
    when (datum, campaign_action) is {
    // Init campaign:
    (Some(current_datum), InitCampaign) ->
      if current_datum is campaign_datum: CampaignDatum {
        tx |> validate_create_campaign(self_script, campaign_datum, nonce, creator)
      } else {
        fail @"Invalid Create Datum Type! Must be CampaignDatum"
      }

    // Support campaign:
    (Some(current_datum), SupportCampaign) ->
      if current_datum is campaign_datum: CampaignDatum {
        tx |> validate_support_campaign(self_script, campaign_datum, backer_datum, nonce, creator)
      } else {
        fail @"Invalid Support Datum Type! Must be CampaignDatum"
      }

      // Finish campaign:
    (Some(current_datum), FinishCampaign) ->
      if current_datum is campaign_datum: CampaignDatum {
        tx |> finishcampaign(self_script, campaign_datum, backer_datum, platform)
      } else {
        fail @"Invalid Finish Datum Type! Must be CampaignDatum"
      }


    // NoDatum etc:
    _ -> {
      expect !is_running_campaign(tx.reference_inputs, self_script)
      tx |> must_be_signed_by(platform)
    }
  }
}

/// Validates the following actions:
/// - Cancel campaign
/// - Finish campaign
/// - Refund campaign
/// - When there is no datum
pub fn validate_spend_campaign(
  platform: VerificationKeyHash,
  creator _creator: VerificationKeyHash,
  nonce _nonce: OutputReference,
  datum: Option<Data>,
  campaign_action: CampaignAction,
  o_ref: OutputReference,
  tx: Transaction,
) -> Bool {
  expect Some(Input { output: Output { address, .. }, .. }) =
    tx.inputs |> transaction.find_input(o_ref)
  expect Script(self_script) = address.payment_credential

  when (datum, campaign_action) is {
    // Cancel campaign:
    (Some(current_datum), Cancel) ->
      if current_datum is campaign_datum: CampaignDatum {
        tx |> validate_cancel_campaign(self_script, campaign_datum, platform)
      } else {
        fail @"Invalid Cancel Datum Type! Must be CampaignDatum"
      }

    // Finish campaign:
    (Some(current_datum), Finish) ->
      tx |> validate_finish_campaign(self_script, current_datum, platform)

    // Refund campaign:
    (Some(current_datum), Refund) ->
      if current_datum is backer_datum: BackerDatum {
        tx |> validate_refund_support(self_script, backer_datum)
      } else {
        fail @"Invalid Refund Datum Type! Must be BackerDatum"
      }

      // Collect To Creator:
    (Some(current_datum), CollectToCreator) ->
      if current_datum is campaign_datum: CampaignDatum {
        tx |> validate_distribute_to_creator(self_script, campaign_datum)
      } else {
        fail @"Invalid Refund Datum Type! Must be BackerDatum"
      }

    // NoDatum etc:
    _ -> {
      expect !is_running_campaign(tx.reference_inputs, self_script)
      tx |> must_be_signed_by(platform)
    }
  }
}

// ## Validation Functions

fn validate_create_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: CampaignDatum,
  nonce: OutputReference,
  creator: VerificationKeyHash,
) -> Bool {
  expect CampaignDatum { goal, deadline, creator: (pkh, _), state: Running, .. } =
    campaign_datum
  expect creator == pkh
  expect goal > 0
  expect unwrap.finite_start_of(tx.validity_range) < deadline
  and {
    must_consume_creator_nonce(tx, creator, nonce)?,
    must_mint_state_token(tx, self_script)?,
    must_send_state_token(tx, self_script, campaign_datum)?,
  }
}

fn validate_cancel_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: CampaignDatum,
  platform: VerificationKeyHash,
) -> Bool {
  // platform can only cancel after deadline, creator can cancel at anytime
  let is_signed_by_platform = tx |> must_be_signed_by(platform)
  and {
    if is_signed_by_platform? {
      must_be_after_deadline(tx, campaign_datum.deadline)?
    } else {
      must_be_signed_by(tx, campaign_datum.creator.1st)?
    },
    is_running_campaign(tx.inputs, self_script)?,
    must_send_state_token(
      tx,
      self_script,
      with_datum: CampaignDatum { ..campaign_datum, state: Cancelled },
    )?,
  }
}

fn validate_finish_campaign(
  tx: Transaction,
  self_script: PolicyId,
  current_datum: Data,
  platform: VerificationKeyHash,
) -> Bool {
  if current_datum is campaign_datum: CampaignDatum {
    // The platform can only finish after the deadline;
    // the creator can finish earlier if the goal is reached
    let is_signed_by_platform = tx |> must_be_signed_by(platform)

    and {
      // If platform is signing, ensure we passed the deadline
      if is_signed_by_platform? {
        must_be_after_deadline(tx, campaign_datum.deadline)?
      } else {
        // Otherwise, ensure the transaction is signed by the creator
        must_be_signed_by(tx, campaign_datum.creator.1st)?
      },

      // The campaign state token UTxO must still be in the Running state
      is_running_campaign(tx.inputs, self_script)?,

      // Move STATE_TOKEN to the same script address with `state = Finished`
      must_send_state_token(
        tx,
        self_script,
        with_datum: CampaignDatum { ..campaign_datum, state: Finished },
      )?,

      // Must confirm total backer supports >= goal
      must_reach_goal(
        tx,
        self_script,
        campaign_datum.goal,
        campaign_datum.creator,
      )?,
    }
  } else if current_datum is BackerDatum {
    // If the inline datum is BackerDatum, we only check the campaign is still running
    is_running_campaign(tx.inputs, self_script)?
  } else {
    fail @"Invalid Finish Datum Type!"
  }
}

fn validate_refund_support(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: BackerDatum,
) -> Bool {
  expect !is_running_campaign(tx.reference_inputs, self_script)
  must_refund(tx, self_script, backer_datum)?
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

fn must_reach_goal(
  tx: Transaction,
  self_script: PolicyId,
  goal: Lovelace,
  (creator_pkh, creator_skh),
) -> Bool {
  let self_address = Address(Script(self_script), None)

  // 1. Sum the lovelace from all script inputs
  let sum_support = fn(sum, Input { output: Output { address, datum, value, .. }, .. }) {
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

  // 2. Check that total support is >= goal
  //    The `?` operator short-circuits if false, otherwise returns `True`.
  (supports >= goal)?
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

pub fn must_mint_prize_tokens(
  tx: Transaction,
  backer_inputs: List<Input>,
  self_script: PolicyId,
) -> Bool {
  // must distribute prize tokens to all backers
  let input <- list.all(backer_inputs)
  expect InlineDatum(input_datum) = input.output.datum
  expect (payment_key_hash, stake_key_hash): BackerDatum = input_datum

  // construct backer address using the utility function
  let backer_address = address_from_tuple((payment_key_hash, stake_key_hash))

  // must send 1 prize token to each backer address
  let output <- list.any(tx.outputs)
  and {
    output.address == backer_address,
    assets.quantity_of(output.value, self_script, payment_key_hash) == 1,
  }
}

fn must_send_state_token(
  tx: Transaction,
  self_script: PolicyId,
  with_datum: CampaignDatum,
) -> Bool {
  let with_datum_data: Data = with_datum
  let self_address = address.from_script(self_script)
  let Output { address, datum, value, .. } <- list.any(tx.outputs)

  when datum is {
    // only handle inline datum
    InlineDatum(output_datum) -> and {
        address == self_address,
        output_datum == with_datum_data,
        assets.quantity_of(value, self_script, config.state_token) == 1,
      }

    // does not handle non-inline datum
    _ -> False
  }
}

// ### Campaign Creation: "STATE_TOKEN" NFT Minting

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


pub fn validate_support_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: CampaignDatum,
  backer_datum: BackerDatum,
  _nonce: OutputReference,
  _creator: VerificationKeyHash,
) -> Bool {
  // 1. Campaign must still be Running
  expect campaign_datum.state == Running
  

  and {
    // 3. Keep the campaign's state token & datum in place
    must_send_support_token(tx, self_script, backer_datum)?,

    must_mint_support_token(tx, self_script)?,
  }
}



fn must_mint_support_token(tx: Transaction, self_script: PolicyId) -> Bool {
  let minted_qty = assets.quantity_of(tx.mint, self_script, config.support_token)
  minted_qty == 1
}





fn must_send_support_token(
  tx: Transaction,
  self_script: PolicyId,
  with_backer_datum: BackerDatum,
) -> Bool {
  let with_backer_datum_data: Data = with_backer_datum
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



fn finishcampaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: CampaignDatum,
  backer_datum: BackerDatum,
  platform: VerificationKeyHash,
) -> Bool {
  expect CampaignDatum { goal, deadline, creator: (pkh, _), state: Running, .. } =
    campaign_datum

  let backer_datum_data: Data = backer_datum
  let is_signed_by_platform = tx |> must_be_signed_by(platform)

  let self_address = Address(Script(self_script), None)
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
  expect supports >= goal
  
  and {
    if is_signed_by_platform? {
        must_be_after_deadline(tx, campaign_datum.deadline)?
      } else {
        // destructure the campaign_datum.creator = (PaymentKeyHash, StakeKeyHash)
        let (creator_pkh, _creator_skh) = campaign_datum.creator
        must_be_signed_by(tx, creator_pkh)?
      },

      
     
      is_running_campaign(tx.inputs, self_script)?,
      must_burn_support_and_mint_reward(tx, self_script, backer_datum)?,

      
    }

  
}


fn must_burn_support_and_mint_reward(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: BackerDatum
) -> Bool {
  let backer_datum_data: Data = backer_datum

  let script_address = Address(Script(self_script), None)
  let backer_address = utils.address_from_tuple(backer_datum)

  let input_support_tokens =
    list.reduce(tx.inputs, 0, fn(sum, Input { output: Output { address, datum, value, .. }, .. }) {
      if address == script_address {
        when datum is {
          InlineDatum(d) -> 
            if d == backer_datum_data {
              assets.quantity_of(value, self_script, config.support_token) + sum
            } else {
              sum
            }
          _ -> sum
        }
      } else {
        sum
      }
    })

  let net_support_burn = assets.quantity_of(tx.mint, self_script, config.support_token)
  expect net_support_burn == -input_support_tokens

  let net_reward_mint = assets.quantity_of(tx.mint, self_script, config.reward_token)
  expect net_reward_mint == input_support_tokens

  let output_reward_tokens =
    list.reduce(tx.outputs, 0, fn(sum, Output { address, value, .. }) {
      if address == backer_address {
        assets.quantity_of(value, self_script, config.reward_token) + sum
      } else {
        sum
      }
    })

  output_reward_tokens >= input_support_tokens
}



fn validate_distribute_to_creator(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: CampaignDatum
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

  // 4. Check that the creator receives at least as much as came from the script
  (output_lovelace >= input_lovelace)?
}



