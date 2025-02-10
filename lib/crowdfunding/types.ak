use aiken/crypto.{VerificationKeyHash}
use cardano/assets.{Lovelace}

pub type PaymentKeyHash =
  VerificationKeyHash

pub type StakeKeyHash =
  VerificationKeyHash

pub type CampaignState {
  Running
  Cancelled
  Finished
}

// ## Datum

pub type CampaignDatum {
  name: ByteArray,
  goal: Lovelace,
  deadline: Int,
  creator: (PaymentKeyHash, StakeKeyHash),
  state: CampaignState,
}

pub type BackerDatum =
  (PaymentKeyHash, StakeKeyHash)

// ## Redeemer

pub type CampaignAction {
  Cancel
  Finish
  Refund
  CollectToCreator
  
}

    /// Create a new redeemer type to support multiple actions,
    /// eg:
    /// - `InitCampaign`(`CampaignDatum`)
    /// - `SupportCampaign`
    /// - `FinishCampaign` (to burn support tokens and mint prize/reward tokens)

pub type RewardNftAction {
  InitCampaign(CampaignDatum)
  SupportCampaign
  FinishCampaign
}


