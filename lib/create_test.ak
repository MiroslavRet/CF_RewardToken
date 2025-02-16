use cardano/address
use cardano/assets
use cardano/transaction.{InlineDatum, OutputReference}
use crowdfunding
use crowdfunding/types.{CampaignDatum, Finished, Running, BackerDatum, InitCampaign}  
use test_kit/tx.{
  add_asset_to_tx_output, add_mint, add_tx_input, add_tx_output,
  set_datum_of_tx_output, set_validity_range, with_asset_of_tx_input,
}
use tests/constants.{
  after_now, campaign_address, campaign_nonce, campaign_script,
  campaign_state_token, creator_address, creator_address_from_tuple, creator_pkh,
}

pub type MintRedeemer {
  InitCampaign(CampaignDatum)
  SupportCampaign(BackerDatum)
  FinishCampaign(BackerDatum)
}

test create_campaign_positive_test() {
  let campaign_datum = CampaignDatum {
    name: "Campaign Name",
    goal: 9_000_000_000,
    deadline: 1928374650000,
    creator: creator_address,
    state: Running,
  }

  let initial_datum: Data = InitCampaign(campaign_datum)
  

  let tx_input =
    tx.new_tx_input(campaign_nonce, creator_address_from_tuple)
      |> with_asset_of_tx_input(assets.from_lovelace(2_000_000))

  let tx_output_1 =
    tx.new_tx_output(campaign_address)
      |> set_datum_of_tx_output(initial_datum |> InlineDatum)
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
      |> set_validity_range(after_now)

  crowdfunding.validate_mint_campaign(
    creator_pkh,
    campaign_nonce,
    Some(initial_datum),
    campaign_script,
    tx,
  )
}

