// /home/miro/cfcampaign2/crowdfunding_b/offchain/components/buttons/campaign/ButtonCollectSupportAndReward.tsx
import { useWallet } from "../../contexts/wallet/WalletContext";
import { CampaignUTxO } from "../../contexts/campaign/CampaignContext";
import { collectSupportAndReward } from "../../crowdfunding"; // Assuming this is where the function is exported
import ActionButton from "../base/ActionButton";
import { Platform } from "@/types/platform";

export default function ButtonCollectSupportAndReward(props: {
  platform?: Platform;
  campaign: CampaignUTxO;
  onSuccess: (campaign: CampaignUTxO) => void;
  onError?: (error: any) => void;
}) {
  const { platform, campaign, onSuccess, onError } = props;

  const [walletConnection] = useWallet();

  return (
    <ActionButton
      actionLabel="Collect & Reward"
      buttonColor="primary" // Using "primary" for a distinct action, adjust as needed
      buttonVariant="shadow"
      campaignAction={() =>
        collectSupportAndReward(walletConnection, campaign, platform)
      }
      onError={onError}
      onSuccess={onSuccess}
    />
  );
}
