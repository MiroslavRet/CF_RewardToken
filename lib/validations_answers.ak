//// validator(creator: VerificationKeyHash, nonce: OutputReference, ..)
////
//// Token types:
//// - State token (must be named "STATE_TOKEN"; minted during campaign creation to authenticate a UTxO)
//// - Prize token (must be named after each backer PKH; minted when the campaign state changes to Finished and sent to the backers)

use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address, Inline, Script, VerificationKey}
use cardano/assets.{Lovelace, PolicyId}
use cardano/transaction.{InlineDatum, Input, OutputReference, Transaction}

pub type PaymentKeyHash =
  VerificationKeyHash

pub type StakeKeyHash =
  VerificationKeyHash

pub type CampaignState {
  Running
  Cancelled
  Finished
}

pub type CampaignDatum {
  name: ByteArray,
  goal: Lovelace,
  deadline: Int,
  creator: (PaymentKeyHash, StakeKeyHash),
  state: CampaignState,
}

pub type BackerDatum =
  (PaymentKeyHash, StakeKeyHash)

pub const state_token = "STATE_TOKEN"

/// There must be a transaction input from self contract address holding the state token.
pub fn must_consume_state_token(tx: Transaction, policy_id: PolicyId) -> Bool {
  let input <- list.any(tx.inputs)
  assets.quantity_of(input.output.value, policy_id, state_token) == 1
}

/// There must be a transaction output to self contract address holding the state token.
/// The datum must be as expected.
pub fn must_resend_state_token(
  tx: Transaction,
  policy_id: PolicyId,
  target_datum: CampaignDatum,
) -> Bool {
  let is_campaign_datum =
    fn(datum: Data) {
      if datum is CampaignDatum {
        datum == target_datum
      } else {
        False
      }
    }
  let is_inline_campaign_datum =
    fn(output_datum) {
      when output_datum is {
        InlineDatum(datum) -> datum |> is_campaign_datum
        _ -> False
      }
    }

  1 == {
    let output <- list.count(tx.outputs)
    and {
      output.address.payment_credential == Script(policy_id),
      output.address.stake_credential == None,
      assets.quantity_of(output.value, policy_id, state_token) == 1,
      output.datum |> is_inline_campaign_datum,
    }
  }
}

/// During campaign creation, a state token must be minted and sent to self contract address
/// along with the CampaignDatum specified in the minting redeemer.
/// The transaction must consume the nonce to ensure token uniqueness and is signed by the campaign creator.
pub fn must_mint_state_token(
  tx: Transaction,
  creator_pkh: VerificationKeyHash,
  nonce: OutputReference,
  policy_id: PolicyId,
  redeemer_datum: CampaignDatum,
) -> Bool {
  // must be signed by the campaign creator
  expect tx.extra_signatories |> list.has(creator_pkh)

  // must consume nonce
  expect {
    let input <- list.any(tx.inputs)
    input.output_reference == nonce
  }

  // must send 1 State Token to self contract address
  must_resend_state_token(tx, policy_id, redeemer_datum)?
}

/// When the campaign state changes from Running to Finished, prize tokens must be minted and distributed to all collected backers.
pub fn must_mint_prize_tokens(
  tx: Transaction,
  backer_inputs: List<Input>,
  policy_id: PolicyId,
) -> Bool {
  // must distribute prize tokens to all backers
  let input <- list.all(backer_inputs)
  expect InlineDatum(input_datum) = input.output.datum
  expect (backer_pkh, backer_skh): BackerDatum = input_datum

  // construct backer address
  let backer_payment_credential = backer_pkh |> VerificationKey
  let backer_stake_credential =
    when backer_skh is {
      "" -> None
      _ -> backer_skh |> VerificationKey |> Inline |> Some
    }
  let backer_address =
    Address(backer_payment_credential, backer_stake_credential)

  // must send 1 prize token to each backer address
  let output <- list.any(tx.outputs)
  and {
    output.address == backer_address,
    assets.quantity_of(output.value, policy_id, backer_pkh) == 1,
  }
}

/// The total lovelace value sum of transaction inputs from self contract address must be >= than the goal.
pub fn must_reach_goal(backer_inputs: List<Input>, goal: Lovelace) -> Bool {
  let input_lovelaces: List<Lovelace> = {
    let input <- list.map(backer_inputs)
    assets.lovelace_of(input.output.value)
  }
  list.reduce(input_lovelaces, 0, +) >= goal
}

/// When the campaign state is Running then it can be changed to Cancelled (spend) or Finished (mint)
pub fn must_update_campaign_state(
  tx: Transaction,
  policy_id: PolicyId,
  new_state: CampaignState,
) -> Bool {
  // get the state token tx input
  expect Some(input) = {
    let input <- list.find(tx.inputs)
    assets.quantity_of(input.output.value, policy_id, state_token) == 1
  }

  // tx input UTxO datum must be CampaignDatum, the state must be Running
  expect InlineDatum(datum) = input.output.datum
  expect campaign_datum: CampaignDatum = datum
  expect Running = campaign_datum.state

  // new datum with the new state
  let new_datum = CampaignDatum { ..campaign_datum, state: new_state }

  // only support changing state to Cancelled or Finished
  when new_state is {
    // spend: must resend the state token and the datum with the updated state, the backers can claim refunds inidivually
    Cancelled -> must_resend_state_token(tx, policy_id, new_datum)?

    // mint: must resend the state token and the datum with the updated state, the goal must be reached, and the prize tokens must be distributed
    Finished -> {
      let is_backer_datum =
        fn(datum: Data) {
          if datum is BackerDatum {
            True
          } else {
            False
          }
        }
      let is_inline_backer_datum =
        fn(output_datum) {
          when output_datum is {
            InlineDatum(datum) -> datum |> is_backer_datum
            _ -> False
          }
        }

      let backer_inputs = {
        let input <- list.filter(tx.inputs)
        and {
          input.output.address.payment_credential == Script(policy_id),
          input.output.address.stake_credential == None,
          input.output.datum |> is_inline_backer_datum,
          input.output.value |> assets.without_lovelace |> assets.is_zero,
        }
      }

      and {
        must_resend_state_token(tx, policy_id, new_datum)?,
        must_reach_goal(backer_inputs, campaign_datum.goal)?,
        must_mint_prize_tokens(tx, backer_inputs, policy_id)?,
      }
    }

    // invalid state change
    _ -> False
  }
}

// ## Refund (spend)

/// The transaction must be signed by the PKH specified in the datum.
pub fn must_spend_own_utxo(tx: Transaction, o_ref: OutputReference) -> Bool {
  // find the UTxO input by its OutputReference
  expect Some(input) = tx.inputs |> transaction.find_input(o_ref)

  // the datum must be BackerDatum
  expect InlineDatum(datum) = input.output.datum
  expect (backer_pkh, _): BackerDatum = datum

  // tx signer must only be [backer_pkh]
  tx.extra_signatories == [backer_pkh]
}

/// The campaign must have been cancelled
pub fn must_have_been_cancelled(tx: Transaction, policy_id: PolicyId) -> Bool {
  // get campaign UTxO from reference inputs
  expect Some(input) = {
    let input <- list.find(tx.reference_inputs)
    and {
      input.output.address.payment_credential == Script(policy_id),
      input.output.address.stake_credential == None,
    }
  }

  // the campaign UTxO must hold the state token
  expect 1 = input.output.value |> assets.quantity_of(policy_id, state_token)

  // extract inline campaign datum
  expect InlineDatum(datum) = input.output.datum
  expect campaign_datum: CampaignDatum = datum

  // is campaign cancelled?
  campaign_datum.state == Cancelled
}

/// A backer can spend their UTxO(s) by proving that the campaign has been Cancelled.
pub fn must_refund(
  tx: Transaction,
  policy_id: PolicyId,
  o_ref: OutputReference,
) -> Bool {
  and {
    must_spend_own_utxo(tx, o_ref)?,
    must_have_been_cancelled(tx, policy_id)?,
  }
}