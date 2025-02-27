use aiken/crypto.{VerificationKeyHash}
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}
use crowdfunding
use crowdfunding/types.{MovieCampaignAction, MovieMintRedeemer}



// This validator is analogous to your original “campaign” validator,
// but adapted to handle multi-phase logic in the “mint” & “spend” functions.
validator movie_campaign(
  platform: VerificationKeyHash,
  creator: VerificationKeyHash,
  nonce: OutputReference,
) {
  // Handle minting transitions (launch campaign, contribute, finish phase).
  mint(
    redeemer: Option<Data>,
    policy_id self_script: PolicyId,
    tx: Transaction,
  ) {
    multi_movie_crowdfunding.validate_mint_movie_campaign(
      creator,
      nonce,
      redeemer,
      self_script,
      tx,
      platform, // optional if you need platform logic in mint
    )
  }

  // Handle spending transitions (e.g., cancel, refund, collect funds, finalize).
  spend(
    datum: Option<Data>,
    redeemer: MovieCampaignAction,
    o_ref: OutputReference,
    tx: Transaction,
  ) {
    multi_movie_crowdfunding.validate_spend_movie_campaign(
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
