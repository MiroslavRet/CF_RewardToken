use aiken/crypto.{VerificationKeyHash}
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}
use crowdfunding
use crowdfunding/types.{CampaignAction, CampaignDatum, RewardNftAction}

validator campaign(
  platform: VerificationKeyHash,
  creator: VerificationKeyHash,
  nonce: OutputReference,
) {
  mint(
    datum: Option<Data>,
    redeemer mint_action: RewardNftAction,
    policy_id self_script: PolicyId,
    tx: Transaction,
  ) {
    crowdfunding.validate_mint_campaign(
      platform,
      creator,
      nonce,
      datum,
      redeemer,
      self_script,
      tx,
    )
  }

  spend(
    datum: Option<Data>,
    redeemer: CampaignAction,
    o_ref: OutputReference,
    tx: Transaction,
  ) {
    crowdfunding.validate_spend_campaign(
      platform,
      creator,
      nonce,
      datum,
      redeemer,
      o_ref,
      tx,
    )
  }

  else(_) {
    fail
  }
}
