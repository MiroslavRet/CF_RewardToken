package crowdfunding

use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{Lovelace, PolicyId}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use test_kit/time/unwrap
use crowdfunding/types.{
  CampaignDatum, BackerDatum, CampaignAction, InitCampaign,
  SupportCampaign, FinishCampaign, Refund, Cancel, CollectToCreator,
  Running, Cancelled, Finished
}
use crowdfunding/utils


///////////
// POSITIVE TESTS
///////////

test cancel_campaign_positive_signed_by_creator() {
  let initial_state =
    CampaignDatum {
      name: "Campaign Name",
      goal: 9_000_000_000,
      deadline: 1928374650000,
      creator: creator_address,    // e.g. (creator_pkh, Some creator_stake)
      state: Running,
    }
  let target_state =
    CampaignDatum { ..initial_state, state: Cancelled }

  let initial_datum: Data = initial_state
  let target_datum: Data = target_state

  let tx_input =
    tx.new_tx_input(campaign_state_o_ref, campaign_address)
      |> set_datum_of_tx_input(initial_datum |> InlineDatum)
      |> with_asset_of_tx_input(campaign_state_token)

  let tx_output =
    tx.new_tx_output(campaign_address)
      |> set_datum_of_tx_output(target_datum |> InlineDatum)
      |> add_asset_to_tx_output(campaign_state_token)

  let tx =
    transaction.placeholder
      |> add_tx_input(tx_input)
      |> add_tx_output(tx_output)
      |> add_signatory(creator_pkh)

  crowdfunding.validate_spend_campaign(
    platform_pkh,
    creator_pkh,
    campaign_nonce,
    Some(initial_datum),
    Cancel,
    campaign_state_o_ref,
    tx,
  )
}

test cancel_campaign_positive_signed_by_platform() {
  let deadline = 1928374650000

  let initial_state =
    CampaignDatum {
      name: "Campaign Name",
      goal: 9_000_000_000,
      deadline,
      creator: creator_address,
      state: Running,
    }
  let target_state =
    CampaignDatum { ..initial_state, state: Cancelled }

  let initial_datum: Data = initial_state
  let target_datum: Data = target_state

  let tx_input =
    tx.new_tx_input(campaign_state_o_ref, campaign_address)
      |> set_datum_of_tx_input(initial_datum |> InlineDatum)
      |> with_asset_of_tx_input(campaign_state_token)

  let tx_output =
    tx.new_tx_output(campaign_address)
      |> set_datum_of_tx_output(target_datum |> InlineDatum)
      |> add_asset_to_tx_output(campaign_state_token)

  let tx =
    transaction.placeholder
      |> add_tx_input(tx_input)
      |> add_tx_output(tx_output)
      |> add_signatory(platform_pkh)
      |> set_validity_range(interval.after(deadline))

  crowdfunding.validate_spend_campaign(
    platform_pkh,
    creator_pkh,
    campaign_nonce,
    Some(initial_datum),
    Cancel,
    campaign_state_o_ref,
    tx,
  )
}

test create_campaign_positive_test() {
  let redeemer =
    CampaignDatum {
      name: "Campaign Name",
      goal: 9_000_000_000,
      deadline: 1928374650000,
      creator: creator_address,
      state: Running,
    }

  let tx_input =
    tx.new_tx_input(campaign_nonce, creator_address_from_tuple)
      |> with_asset_of_tx_input(assets.from_lovelace(2_000_000))

  let tx_output_1 =
    tx.new_tx_output(campaign_address)
      |> set_datum_of_tx_output(redeemer |> InlineDatum)
      |> add_asset_to_tx_output(campaign_state_token)

  let tx_output_2 =
    tx.new_tx_output(creator_address_from_tuple)
      |> add_asset_to_tx_output(assets.from_lovelace(2_000_000))

  let tx =
    transaction.placeholder
      |> add_tx_input(tx_input)
      |> add_mint(campaign_state_token)
      |> add_tx_output(tx_output_1)
      |> add_tx_output(tx_output_2)
      |> set_validity_range(after_now)   // e.g. a valid range in the future

  crowdfunding.validate_mint_campaign(
    platform_pkh,
    creator_pkh,
    campaign_nonce,
    redeemer,
    campaign_script,
    tx,
  )
}

test finish_campaign_positive_signed_by_creator() {
  let initial_state =
    CampaignDatum {
      name: "Campaign Name",
      goal: 9_000_000_000,
      deadline: 1928374650000,
      creator: creator_address,
      state: Running,
    }
  let target_state = CampaignDatum { ..initial_state, state: Finished }

  let initial_datum: Data = initial_state
  let target_datum: Data = target_state

  let backer_datum_1: Data = (#"b1", #"")
  let backer_datum_2: Data = (#"b2", #"b2")

  let backer_support_o_ref_1 = OutputReference("A_SUPPORT_OREF_TxHash", 1)
  let backer_support_o_ref_2 = OutputReference("B_SUPPORT_OREF_TxHash", 2)

  let tx_input_goal =
    tx.new_tx_input(campaign_state_o_ref, campaign_address)
      |> set_datum_of_tx_input(initial_datum |> InlineDatum)
      |> with_asset_of_tx_input(campaign_state_token)

  let tx_input_support_1 =
    tx.new_tx_input(backer_support_o_ref_1, campaign_address)
      |> set_datum_of_tx_input(backer_datum_1 |> InlineDatum)
      |> with_asset_of_tx_input(assets.from_lovelace(3_000_000_000))

  let tx_input_support_2 =
    tx.new_tx_input(backer_support_o_ref_2, campaign_address)
      |> set_datum_of_tx_input(backer_datum_2 |> InlineDatum)
      |> with_asset_of_tx_input(assets.from_lovelace(6_000_000_000))

  let tx_output_campaign =
    tx.new_tx_output(campaign_address)
      |> set_datum_of_tx_output(target_datum |> InlineDatum)
      |> add_asset_to_tx_output(campaign_state_token)

  let tx_output_creator =
    tx.new_tx_output(creator_address_from_tuple)
      |> add_asset_to_tx_output(assets.from_lovelace(9_000_000_000))

  let tx =
    transaction.placeholder
      |> add_tx_input(tx_input_goal)
      |> add_tx_input(tx_input_support_1)
      |> add_tx_input(tx_input_support_2)
      |> add_tx_output(tx_output_campaign)
      |> add_tx_output(tx_output_creator)
      |> add_signatory(creator_pkh)

  and {
    // Validate finishing the "state" UTxO
    crowdfunding.validate_spend_campaign(
      platform_pkh,
      creator_pkh,
      campaign_nonce,
      Some(initial_datum),
      Finish,
      campaign_state_o_ref,
      tx,
    ),

    // Validate finishing each backer support UTxO
    crowdfunding.validate_spend_campaign(
      platform_pkh,
      creator_pkh,
      campaign_nonce,
      Some(backer_datum_1),
      Finish,
      backer_support_o_ref_1,
      tx,
    ),
    crowdfunding.validate_spend_campaign(
      platform_pkh,
      creator_pkh,
      campaign_nonce,
      Some(backer_datum_2),
      Finish,
      backer_support_o_ref_2,
      tx,
    ),
  }
}

test finish_campaign_positive_signed_by_platform() {
  let deadline = 1928374650000

  let initial_state =
    CampaignDatum {
      name: "Campaign Name",
      goal: 9_000_000_000,
      deadline,
      creator: creator_address,
      state: Running,
    }
  let target_state = CampaignDatum { ..initial_state, state: Finished }

  let initial_datum: Data = initial_state
  let target_datum: Data = target_state

  let backer_datum_1: Data = (#"b1", #"")
  let backer_datum_2: Data = (#"b2", #"b2")

  let backer_support_o_ref_1 = OutputReference("A_SUPPORT_OREF_TxHash", 1)
  let backer_support_o_ref_2 = OutputReference("B_SUPPORT_OREF_TxHash", 2)

  let tx_input_goal =
    tx.new_tx_input(campaign_state_o_ref, campaign_address)
      |> set_datum_of_tx_input(initial_datum |> InlineDatum)
      |> with_asset_of_tx_input(campaign_state_token)

  let tx_input_support_1 =
    tx.new_tx_input(backer_support_o_ref_1, campaign_address)
      |> set_datum_of_tx_input(backer_datum_1 |> InlineDatum)
      |> with_asset_of_tx_input(assets.from_lovelace(3_000_000_000))

  let tx_input_support_2 =
    tx.new_tx_input(backer_support_o_ref_2, campaign_address)
      |> set_datum_of_tx_input(backer_datum_2 |> InlineDatum)
      |> with_asset_of_tx_input(assets.from_lovelace(6_000_000_000))

  let tx_output_campaign =
    tx.new_tx_output(campaign_address)
      |> set_datum_of_tx_output(target_datum |> InlineDatum)
      |> add_asset_to_tx_output(campaign_state_token)

  let tx_output_creator =
    tx.new_tx_output(creator_address_from_tuple)
      |> add_asset_to_tx_output(assets.from_lovelace(9_000_000_000))

  let tx =
    transaction.placeholder
      |> add_tx_input(tx_input_goal)
      |> add_tx_input(tx_input_support_1)
      |> add_tx_input(tx_input_support_2)
      |> add_tx_output(tx_output_campaign)
      |> add_tx_output(tx_output_creator)
      |> add_signatory(platform_pkh)
      |> set_validity_range(interval.after(deadline))

  and {
    crowdfunding.validate_spend_campaign(
      platform_pkh,
      creator_pkh,
      campaign_nonce,
      Some(initial_datum),
      Finish,
      campaign_state_o_ref,
      tx,
    ),
    crowdfunding.validate_spend_campaign(
      platform_pkh,
      creator_pkh,
      campaign_nonce,
      Some(backer_datum_1),
      Finish,
      backer_support_o_ref_1,
      tx,
    ),
    crowdfunding.validate_spend_campaign(
      platform_pkh,
      creator_pkh,
      campaign_nonce,
      Some(backer_datum_2),
      Finish,
      backer_support_o_ref_2,
      tx,
    ),
  }
}

test no_datum_positive_cancelled_campaign() {
  let campaign_state =
    CampaignDatum {
      name: "Campaign Name",
      goal: 9_000_000_000,
      deadline: 1928374650000,
      creator: creator_address,
      state: Cancelled,
    }
  let campaign_datum: Data = campaign_state

  let no_datum_o_ref = OutputReference("NO_DATUM_OREF_TxHash", 0)

  let tx_ref_input =
    tx.new_tx_input(campaign_state_o_ref, campaign_address)
      |> set_datum_of_tx_input(campaign_datum |> InlineDatum)
      |> with_asset_of_tx_input(campaign_state_token)

  let tx_input =
    tx.new_tx_input(no_datum_o_ref, campaign_address)
      |> with_asset_of_tx_input(assets.from_lovelace(500_000_000))

  let tx_output =
    tx.new_tx_output(platform_address)
      |> add_asset_to_tx_output(assets.from_lovelace(500_000_000))

  let tx =
    transaction.placeholder
      |> add_tx_ref_input(tx_ref_input) 
      |> add_tx_input(tx_input)
      |> add_tx_output(tx_output)
      |> add_signatory(platform_pkh)

  // Try each possible redeemer for a no-datum UTxO
  let redeemer <- list.all([Cancel, Finish, Refund])

  crowdfunding.validate_spend_campaign(
    platform_pkh,
    creator_pkh,
    campaign_nonce,
    None,
    redeemer,
    no_datum_o_ref,
    tx,
  )
}

test no_datum_positive_finished_campaign() {
  let campaign_state =
    CampaignDatum {
      name: "Campaign Name",
      goal: 9_000_000_000,
      deadline: 1928374650000,
      creator: creator_address,
      state: Finished,
    }
  let campaign_datum: Data = campaign_state

  let no_datum_o_ref = OutputReference("NO_DATUM_OREF_TxHash", 0)

  let tx_ref_input =
    tx.new_tx_input(campaign_state_o_ref, campaign_address)
      |> set_datum_of_tx_input(campaign_datum |> InlineDatum)
      |> with_asset_of_tx_input(campaign_state_token)

  let tx_input =
    tx.new_tx_input(no_datum_o_ref, campaign_address)
      |> with_asset_of_tx_input(assets.from_lovelace(500_000_000))

  let tx_output =
    tx.new_tx_output(platform_address)
      |> add_asset_to_tx_output(assets.from_lovelace(500_000_000))

  let tx =
    transaction.placeholder
      |> add_tx_ref_input(tx_ref_input)
      |> add_tx_input(tx_input)
      |> add_tx_output(tx_output)
      |> add_signatory(platform_pkh)

  // Try each possible redeemer for a no-datum UTxO
  let redeemer <- list.all([Cancel, Finish, Refund])

  crowdfunding.validate_spend_campaign(
    platform_pkh,
    creator_pkh,
    campaign_nonce,
    None,
    redeemer,
    no_datum_o_ref,
    tx,
  )
}

test refund_campaign_positive_cancelled_campaign() {
  let campaign_state =
    CampaignDatum {
      name: "Campaign Name",
      goal: 9_000_000_000,
      deadline: 1928374650000,
      creator: creator_address,
      state: Cancelled,
    }
  let campaign_datum: Data = campaign_state

  let backer_address_1 = (#"b1", #"")
  let backer_datum_1: Data = backer_address_1

  let backer_address_2 = (#"b2", #"b2")
  let backer_datum_2: Data = backer_address_2

  let backer_address_3 = (#"b3", #"")
  let backer_datum_3: Data = backer_address_3

  let backer_address_4 = (#"b4", #"b4")
  let backer_datum_4: Data = backer_address_4

  let backer_support_o_ref_1 = OutputReference("A_SUPPORT_OREF_TxHash", 1)
  let backer_support_o_ref_2 = OutputReference("B_SUPPORT_OREF_TxHash", 2)
  let backer_support_o_ref_3 = OutputReference("C_SUPPORT_OREF_TxHash", 3)
  let backer_support_o_ref_4 = OutputReference("D_SUPPORT_OREF_TxHash", 4)

  let backer_address_from_tuple_1 = utils.address_from_tuple(backer_address_1)
  let backer_address_from_tuple_2 = utils.address_from_tuple(backer_address_2)
  let backer_address_from_tuple_3 = utils.address_from_tuple(backer_address_3)
  let backer_address_from_tuple_4 = utils.address_from_tuple(backer_address_4)

  let tx_ref_input_campaign =
    tx.new_tx_input(campaign_state_o_ref, campaign_address)
      |> set_datum_of_tx_input(campaign_datum |> InlineDatum)
      |> with_asset_of_tx_input(campaign_state_token)

  let tx_input_support_1 =
    tx.new_tx_input(backer_support_o_ref_1, campaign_address)
      |> set_datum_of_tx_input(backer_datum_1 |> InlineDatum)
      |> with_asset_of_tx_input(assets.from_lovelace(1_000_000_000))

  let tx_input_support_2 =
    tx.new_tx_input(backer_support_o_ref_2, campaign_address)
      |> set_datum_of_tx_input(backer_datum_2 |> InlineDatum)
      |> with_asset_of_tx_input(assets.from_lovelace(2_000_000_000))

  let tx_input_support_3 =
    tx.new_tx_input(backer_support_o_ref_3, campaign_address)
      |> set_datum_of_tx_input(backer_datum_3 |> InlineDatum)
      |> with_asset_of_tx_input(assets.from_lovelace(3_000_000_000))

  let tx_input_support_4 =
    tx.new_tx_input(backer_support_o_ref_4, campaign_address)
      |> set_datum_of_tx_input(backer_datum_4 |> InlineDatum)
      |> with_asset_of_tx_input(assets.from_lovelace(4_000_000_000))

  let tx_output_backer_1 =
    tx.new_tx_output(backer_address_from_tuple_1)
      |> add_asset_to_tx_output(assets.from_lovelace(1_000_000_000))
  let tx_output_backer_2 =
    tx.new_tx_output(backer_address_from_tuple_2)
      |> add_asset_to_tx_output(assets.from_lovelace(2_000_000_000))
  let tx_output_backer_3 =
    tx.new_tx_output(backer_address_from_tuple_3)
      |> add_asset_to_tx_output(assets.from_lovelace(3_000_000_000))
  let tx_output_backer_4 =
    tx.new_tx_output(backer_address_from_tuple_4)
      |> add_asset_to_tx_output(assets.from_lovelace(4_000_000_000))

  let tx =
    transaction.placeholder
      |> add_tx_ref_input(tx_ref_input_campaign)
      |> add_tx_input(tx_input_support_1)
      |> add_tx_input(tx_input_support_2)
      |> add_tx_input(tx_input_support_3)
      |> add_tx_input(tx_input_support_4)
      |> add_tx_output(tx_output_backer_1)
      |> add_tx_output(tx_output_backer_2)
      |> add_tx_output(tx_output_backer_3)
      |> add_tx_output(tx_output_backer_4)

  and {
    crowdfunding.validate_spend_campaign(
      platform_pkh,
      creator_pkh,
      campaign_nonce,
      Some(backer_datum_1),
      Refund,
      backer_support_o_ref_1,
      tx,
    ),
    crowdfunding.validate_spend_campaign(
      platform_pkh,
      creator_pkh,
      campaign_nonce,
      Some(backer_datum_2),
      Refund,
      backer_support_o_ref_2,
      tx,
    ),
    crowdfunding.validate_spend_campaign(
      platform_pkh,
      creator_pkh,
      campaign_nonce,
      Some(backer_datum_3),
      Refund,
      backer_support_o_ref_3,
      tx,
    ),
    crowdfunding.validate_spend_campaign(
      platform_pkh,
      creator_pkh,
      campaign_nonce,
      Some(backer_datum_4),
      Refund,
      backer_support_o_ref_4,
      tx,
    ),
  }
}

test refund_campaign_positive_finished_campaign() {
  let campaign_state =
    CampaignDatum {
      name: "Campaign Name",
      goal: 9_000_000_000,
      deadline: 1928374650000,
      creator: creator_address,
      state: Finished,
    }
  let campaign_datum: Data = campaign_state

  let backer_address_1 = (#"b1", #"")
  let backer_datum_1: Data = backer_address_1

  let backer_address_2 = (#"b2", #"b2")
  let backer_datum_2: Data = backer_address_2

  let backer_address_3 = (#"b3", #"")
  let backer_datum_3: Data = backer_address_3

  let backer_address_4 = (#"b4", #"b4")
  let backer_datum_4: Data = backer_address_4

  let backer_support_o_ref_1 = OutputReference("A_SUPPORT_OREF_TxHash", 1)
  let backer_support_o_ref_2 = OutputReference("B_SUPPORT_OREF_TxHash", 2)
  let backer_support_o_ref_3 = OutputReference("C_SUPPORT_OREF_TxHash", 3)
  let backer_support_o_ref_4 = OutputReference("D_SUPPORT_OREF_TxHash", 4)

  let backer_address_from_tuple_1 = utils.address_from_tuple(backer_address_1)
  let backer_address_from_tuple_2 = utils.address_from_tuple(backer_address_2)
  let backer_address_from_tuple_3 = utils.address_from_tuple(backer_address_3)
  let backer_address_from_tuple_4 = utils.address_from_tuple(backer_address_4)

  let tx_ref_input_campaign =
    tx.new_tx_input(campaign_state_o_ref, campaign_address)
      |> set_datum_of_tx_input(campaign_datum |> InlineDatum)
      |> with_asset_of_tx_input(campaign_state_token)

  let tx_input_support_1 =
    tx.new_tx_input(backer_support_o_ref_1, campaign_address)
      |> set_datum_of_tx_input(backer_datum_1 |> InlineDatum)
      |> with_asset_of_tx_input(assets.from_lovelace(1_000_000_000))

  let tx_input_support_2 =
    tx.new_tx_input(backer_support_o_ref_2, campaign_address)
      |> set_datum_of_tx_input(backer_datum_2 |> InlineDatum)
      |> with_asset_of_tx_input(assets.from_lovelace(2_000_000_000))

  let tx_input_support_3 =
    tx.new_tx_input(backer_support_o_ref_3, campaign_address)
      |> set_datum_of_tx_input(backer_datum_3 |> InlineDatum)
      |> with_asset_of_tx_input(assets.from_lovelace(3_000_000_000))

  let tx_input_support_4 =
    tx.new_tx_input(backer_support_o_ref_4, campaign_address)
      |> set_datum_of_tx_input(backer_datum_4 |> InlineDatum)
      |> with_asset_of_tx_input(assets.from_lovelace(4_000_000_000))

  let tx_output_backer_1 =
    tx.new_tx_output(backer_address_from_tuple_1)
      |> add_asset_to_tx_output(assets.from_lovelace(1_000_000_000))

  let tx_output_backer_2 =
    tx.new_tx_output(backer_address_from_tuple_2)
      |> add_asset_to_tx_output(assets.from_lovelace(2_000_000_000))

  let tx_output_backer_3 =
    tx.new_tx_output(backer_address_from_tuple_3)
      |> add_asset_to_tx_output(assets.from_lovelace(3_000_000_000))

  let tx_output_backer_4 =
    tx.new_tx_output(backer_address_from_tuple_4)
      |> add_asset_to_tx_output(assets.from_lovelace(4_000_000_000))

  let tx =
    transaction.placeholder
      |> add_tx_ref_input(tx_ref_input_campaign)
      |> add_tx_input(tx_input_support_1)
      |> add_tx_input(tx_input_support_2)
      |> add_tx_input(tx_input_support_3)
      |> add_tx_input(tx_input_support_4)
      |> add_tx_output(tx_output_backer_1)
      |> add_tx_output(tx_output_backer_2)
      |> add_tx_output(tx_output_backer_3)
      |> add_tx_output(tx_output_backer_4)

  and {
    crowdfunding.validate_spend_campaign(
      platform_pkh,
      creator_pkh,
      campaign_nonce,
      Some(backer_datum_1),
      Refund,
      backer_support_o_ref_1,
      tx,
    ),
    crowdfunding.validate_spend_campaign(
      platform_pkh,
      creator_pkh,
      campaign_nonce,
      Some(backer_datum_2),
      Refund,
      backer_support_o_ref_2,
      tx,
    ),
    crowdfunding.validate_spend_campaign(
      platform_pkh,
      creator_pkh,
      campaign_nonce,
      Some(backer_datum_3),
      Refund,
      backer_support_o_ref_3,
      tx,
    ),
    crowdfunding.validate_spend_campaign(
      platform_pkh,
      creator_pkh,
      campaign_nonce,
      Some(backer_datum_4),
      Refund,
      backer_support_o_ref_4,
      tx,
    ),
  }
}
