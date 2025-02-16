use cardano/address
use cardano/assets
use cardano/transaction.{InlineDatum, OutputReference}
use crowdfunding
use crowdfunding/utils
use crowdfunding/types.{CampaignDatum, Running, BackerDatum, SupportCampaign}
use test_kit/tx.{
  add_asset_to_tx_output, add_mint, add_tx_input, add_tx_output,
  set_datum_of_tx_output, set_validity_range, with_asset_of_tx_input,
}
use tests/constants.{
  after_now, campaign_address, campaign_nonce, campaign_script,
  campaign_state_token, campaign_support_token, creator_address, creator_address_from_tuple, creator_pkh,
}

pub type MintRedeemer {
  InitCampaign(CampaignDatum)
  SupportCampaign(BackerDatum)
  FinishCampaign(BackerDatum)
}

test support_campaign_positive_test() {
  // Define campaign state


    let backer_address_1 = (#"b1", #"b1")
  let backer_datum_1: BackerDatum = backer_address_1



  let initial_backer_datum_1: Data = SupportCampaign(backer_datum_1)

  // Backers' UTxO references
  let backer_support_o_ref_1 = OutputReference("A_SUPPORT_OREF_TxHash", 1)

  let backer_address_from_tuple_1 = utils.address_from_tuple(backer_address_1)


  // Backers send Lovelace to the campaign address
  let tx_input_support_1 =
      tx.new_tx_input(backer_support_o_ref_1, backer_address_from_tuple_1)

  // Funds are sent to the campaign address (recording backer contributions)
  let tx_output_campaign_1 =
      tx.new_tx_output(campaign_address)
        |> set_datum_of_tx_output(initial_backer_datum_1 |> InlineDatum)
        |> add_asset_to_tx_output(assets.from_lovelace(1_000_000_000))
        |> add_asset_to_tx_output(campaign_support_token)

  // Construct transaction
  let tx =
      transaction.placeholder
        |> add_tx_input(tx_input_support_1)
        |> add_mint(campaign_support_token)
        |> add_tx_output(tx_output_campaign_1)
        |> set_validity_range(after_now)

  // Debugging - Check Transaction Details
  trace @"Transaction Inputs": tx.inputs
  trace @"Transaction Outputs": tx.outputs
  trace @"Transaction Lovelace Sent to Campaign": [1_000_000_000, 2_000_000_000, 3_000_000_000, 4_000_000_000]
  trace @"Campaign Address": campaign_address
  trace @"Backer Inputs": [backer_support_o_ref_1]
  trace @"Backer Datums": [backer_datum_1]

  // Validate support campaign
  crowdfunding.validate_mint_campaign(
      creator_pkh,
      campaign_nonce,
      Some(initial_backer_datum_1),
      campaign_script,
      tx,
    )
}
