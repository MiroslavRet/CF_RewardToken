validator marketplace(
  platform: VerificationKeyHash,
  creator: VerificationKeyHash,
  nonce: OutputReference,
) {
  

  spend(
    datum: Option<Data>,
    redeemer: Redeemer,
    o_ref: OutputReference,
    ctx: Transaction,
  ) {
    crowdfunding.validate_spend_marketplace(
      platform,
      creator,
      nonce,
      datum,
      redeemer,
      o_ref,
      ctx,
    )
  }

  else(_) {
    fail
  }
}